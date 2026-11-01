import Foundation

/// Builds and maintains `.utility/graph.sqlite` through the gateway `graphIndexer` service.
///
/// Full scans collect all files first and replace the graph in one transaction. Incremental
/// updates replace a single file's symbols/out-edges and mark incoming edges stale.
final class GraphScanner {
    struct Summary {
        var stats: GraphStats
        var elapsedMs: Int
    }

    let projectPath: String
    private let database: GraphDatabase
    private let scannerConfig: ScannerConfig
    private let allowedLanguages: Set<String>
    private let maxRestarts: Int
    private let stateLock = NSLock()
    private var stopped = false
    private var prepared = false
    private var client: GraphIndexerClient?

    /// Receives the indexer PID whenever the child starts or exits.
    var onIndexerPIDChange: ((Int32) -> Void)?

    init(projectPath: String, languages: [String] = [], maxRestarts: Int = 3) throws {
        let root = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        self.projectPath = root
        database = try GraphDatabase(projectPath: root)
        scannerConfig = ScannerConfig(projectPath: root)
        allowedLanguages = languages.isEmpty
            ? GraphProtocol.defaultLanguages
            : Set(languages.map { $0.lowercased() })
        self.maxRestarts = maxRestarts
    }

    deinit {
        client?.stop()
    }

    func isUpToDate() throws -> Bool {
        guard try database.isUpToDate(root: projectPath) else { return false }
        guard let ping = try indexer().ping(),
              ping.engineVersion == GraphProtocol.engineVersion,
              ping.schemaVersion == GraphProtocol.schemaVersion
        else { return false }
        return true
    }

    /// Reconciles files changed or deleted while no watcher was running.
    func syncScan() throws -> Summary {
        let started = Date()
        let collected = try collectSourceFiles()
        let known = try database.allFileMeta()
        var changed: [SourceFile] = []
        var hashes: [String: String] = [:]
        var sizes: [String: Int] = [:]
        var seen = Set<String>()
        for item in collected {
            seen.insert(item.path)
            if let meta = known[item.path],
               meta.size == item.size,
               abs(meta.mtime - item.mtime) < 0.001 {
                continue
            }
            guard let data = try? Data(contentsOf: fileURL(item.path)) else {
                recordIncrementalFailure(item.path, "unreadable")
                continue
            }
            let hash = GraphKey.sha1Hex(data: data)
            if let meta = known[item.path], meta.contentHash == hash {
                // Stat-only change (touch): refresh metadata instead of re-parsing.
                try database.updateFileMeta(
                    path: item.path, size: data.count, mtime: item.mtime)
                continue
            }
            changed.append(item)
            hashes[item.path] = hash
            sizes[item.path] = data.count
        }
        let removed = Set(known.keys).subtracting(seen)
        try database.deleteDanglingStaleEdges()
        // No changes: do not start the indexer or parse the project again.
        if changed.isEmpty, removed.isEmpty {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return Summary(stats: try stats(), elapsedMs: elapsed)
        }
        _ = try indexer().prepare(paths: collected.map(\.path))
        markPrepared()
        for path in removed.sorted() {
            try removeFile(relPath: path)
        }
        let batch = try indexBatchFiles(changed, hashes: hashes, sizes: sizes)
        // A new symbol can resolve references unresolved in unchanged files.
        if !batch.addedNames.isEmpty {
            let dependents = try database.unresolvedPaths(named: batch.addedNames)
                .subtracting(batch.reindexed)
            for path in dependents.sorted() {
                _ = try indexFile(relPath: path, force: true)
            }
        }
        // Drop edges made dangling by this reconciliation.
        try database.deleteDanglingStaleEdges()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return Summary(stats: try stats(), elapsedMs: elapsed)
    }

    func stats() throws -> GraphStats {
        try database.stats()
    }

    /// PID of the resident indexer, when one has been launched.
    var indexerProcessIdentifier: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return client?.processIdentifier
    }

    func stop() {
        stateLock.lock()
        stopped = true
        let existing = client
        client = nil
        stateLock.unlock()
        existing?.stop()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private var isPrepared: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return prepared
    }

    private func markPrepared() {
        stateLock.lock()
        prepared = true
        stateLock.unlock()
    }

    /// A watcher update may arrive before any scan; prepare the host file set first.
    private func ensurePrepared() throws {
        guard !isPrepared else { return }
        let collected = try collectSourceFiles()
        _ = try indexer().prepare(paths: collected.map(\.path))
        markPrepared()
    }

    /// Parses changed files in chunks, then resolves them against one symbol index.
    private func indexBatchFiles(
        _ items: [SourceFile],
        hashes: [String: String],
        sizes: [String: Int]
    ) throws -> (reindexed: Set<String>, addedNames: Set<String>) {
        guard !items.isEmpty else { return ([], []) }
        let client = try indexer()
        var responses: [String: GraphIndexResponse] = [:]
        let chunkSize = 50
        for start in stride(from: 0, to: items.count, by: chunkSize) {
            let chunk = items[start ..< min(start + chunkSize, items.count)]
            let batch = chunk.compactMap { item -> GraphBatchFile? in
                guard let hash = hashes[item.path] else { return nil }
                return GraphBatchFile(path: item.path, contentHash: hash, lang: item.lang)
            }
            for response in try client.indexBatch(files: batch) {
                guard let path = response.path else { continue }
                responses[path] = response
            }
        }

        var parsed: [
            (item: SourceFile, response: GraphIndexResponse, symbols: [GraphDatabase.SymbolRow])
        ] = []
        var candidateNames = Set<String>()
        for item in items {
            guard let response = responses[item.path] else {
                recordIncrementalFailure(item.path, "no_response")
                continue
            }
            guard response.ok else {
                recordIncrementalFailure(
                    item.path, response.error ?? response.reason ?? "parse_failed")
                continue
            }
            let symbols = dedupe(makeSymbols(response.symbols, path: item.path))
            parsed.append((item, response, symbols))
            candidateNames.formUnion(symbols.map(\.name))
            for edge in response.edges {
                for name in [edge.rawName, edge.toName, edge.fromName].compactMap({ $0 }) {
                    candidateNames.insert(name)
                }
            }
        }
        let changedPaths = Set(parsed.map(\.item.path))
        let existing = try database.symbols(named: Array(candidateNames))
            .filter { !changedPaths.contains($0.path) }
        var nameIndex = buildNameIndex(existing)
        for entry in parsed {
            for symbol in entry.symbols {
                nameIndex[symbol.name, default: []].append(symbol)
            }
        }

        var reindexed = Set<String>()
        var addedNames = Set<String>()
        for entry in parsed {
            let built = buildEdges(entry.response, path: entry.item.path, nameIndex: nameIndex)
            let unresolved = built.unresolved + entry.response.unresolved.map {
                GraphDatabase.UnresolvedRow(
                    path: entry.item.path,
                    rawName: $0.rawName,
                    kind: $0.kind,
                    line: $0.line,
                    reason: $0.reason,
                )
            }
            let file = GraphDatabase.FileRow(
                path: entry.item.path,
                lang: entry.item.lang,
                size: sizes[entry.item.path] ?? entry.item.size,
                mtime: entry.item.mtime,
                contentHash: hashes[entry.item.path] ?? "",
            )
            try database.replaceFile(
                file: file,
                symbols: entry.symbols,
                edges: built.edges,
                unresolved: unresolved,
            )
            reindexed.insert(entry.item.path)
            addedNames.formUnion(entry.symbols.map(\.name))
        }
        return (reindexed, addedNames)
    }

    private func recordIncrementalFailure(_ path: String, _ reason: String) {
        try? database.recordDiagnostic(
            key: "last_incremental_error", value: "\(path): \(reason)")
        try? database.recordDiagnostic(
            key: "last_incremental_error_at",
            value: ISO8601DateFormatter().string(from: Date()),
        )
    }

    // MARK: - Full scan

    func fullScan() throws -> Summary {
        let started = Date()
        let traceID = GraphLog.traceID(prefix: "gf")
        var files: [GraphDatabase.FileRow] = []
        var batch: [GraphBatchFile] = []
        var failedFiles: [String] = []

        for item in try collectSourceFiles() {
            guard let data = try? Data(contentsOf: fileURL(item.path)) else {
                failedFiles.append("\(item.path): unreadable")
                continue
            }
            let file = GraphDatabase.FileRow(
                path: item.path,
                lang: item.lang,
                size: data.count,
                mtime: item.mtime,
                contentHash: GraphKey.sha1Hex(data: data),
            )
            files.append(file)
            batch.append(GraphBatchFile(
                path: file.path, contentHash: file.contentHash, lang: file.lang))
        }

        // Large repos overflow one response; index in bounded chunks.
        let batchSize = 50
        let client = try indexer()
        _ = try client.prepare(paths: files.map(\.path))
        markPrepared()
        var responses: [GraphIndexResponse] = []
        var offset = 0
        while offset < batch.count {
            let end = min(offset + batchSize, batch.count)
            responses.append(contentsOf: try client.indexBatch(files: Array(batch[offset ..< end])))
            offset = end
        }
        var byPath: [String: GraphIndexResponse] = [:]
        for response in responses {
            guard let path = response.path, byPath[path] == nil else { continue }
            byPath[path] = response
        }

        var storedFiles: [GraphDatabase.FileRow] = []
        var symbols: [GraphDatabase.SymbolRow] = []
        var parsed: [(path: String, response: GraphIndexResponse)] = []

        for file in files {
            guard let response = byPath[file.path] else {
                failedFiles.append("\(file.path): no_response")
                continue
            }
            guard response.ok else {
                failedFiles.append("\(file.path): \(response.error ?? response.reason ?? "parse_failed")")
                continue
            }
            storedFiles.append(file)
            symbols.append(contentsOf: makeSymbols(response.symbols, path: file.path))
            parsed.append((file.path, response))
        }

        symbols = dedupe(symbols)
        let nameIndex = buildNameIndex(symbols)
        var edges: [GraphDatabase.EdgeRow] = []
        var unresolved: [GraphDatabase.UnresolvedRow] = []
        for entry in parsed {
            let built = buildEdges(
                entry.response,
                path: entry.path,
                nameIndex: nameIndex,
            )
            edges.append(contentsOf: built.edges)
            unresolved.append(contentsOf: built.unresolved)
            unresolved.append(contentsOf: entry.response.unresolved.map {
                GraphDatabase.UnresolvedRow(
                    path: entry.path,
                    rawName: $0.rawName,
                    kind: $0.kind,
                    line: $0.line,
                    reason: $0.reason,
                )
            })
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let meta = [
            "engine_version": GraphProtocol.engineVersion,
            "schema_version": GraphProtocol.schemaVersion,
            "root": projectPath,
            "built_at": ISO8601DateFormatter().string(from: Date()),
            "full_build_elapsed_ms": String(elapsedMs),
        ]
        let diagnostics = makeDiagnostics(
            elapsedMs: elapsedMs,
            failedFiles: failedFiles,
            unresolved: unresolved,
        )
        try database.replaceGraph(
            meta: meta,
            files: storedFiles,
            symbols: symbols,
            edges: edges,
            unresolved: unresolved,
            diagnostics: diagnostics,
        )

        let stats = try database.stats()
        GraphLog.log(
            traceID: traceID,
            op: "full_scan",
            project: projectPath,
            elapsedMs: elapsedMs,
            edgeCount: stats.edges,
            unresolvedCount: stats.unresolved,
        )
        return Summary(stats: stats, elapsedMs: elapsedMs)
    }

    // MARK: - Incremental

    /// Re-indexes one file. Returns false when the content hash did not change.
    @discardableResult
    func indexFile(relPath: String, force: Bool = false) throws -> Bool {
        do {
            return try indexFileImpl(relPath: relPath, force: force)
        } catch {
            if case GraphScannerError.stopped = error { throw error }
            recordIncrementalFailure(relPath, error.localizedDescription)
            throw error
        }
    }

    private func indexFileImpl(relPath: String, force: Bool) throws -> Bool {
        if isStopped { throw GraphScannerError.stopped }
        try ensurePrepared()
        let fullPath = (projectPath as NSString).appendingPathComponent(relPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) else {
            try removeFile(relPath: relPath)
            return true
        }
        // Directory events describe a container, not a file; never delete its children.
        guard !isDir.boolValue else { return false }
        guard scannerConfig.shouldInclude(relPath) else { return false }
        let ext = (relPath as NSString).pathExtension
        guard let lang = GraphProtocol.language(forExtension: ext),
              allowedLanguages.contains(lang)
        else { return false }

        let started = Date()
        let content = try Data(contentsOf: URL(fileURLWithPath: fullPath))
        let hash = GraphKey.sha1Hex(data: content)
        if !force, try database.fileHash(path: relPath) == hash { return false }

        let response = try indexer().indexFile(path: relPath, contentHash: hash, lang: lang)
        guard response.ok else {
            throw GraphScannerError.indexFailed(
                path: relPath,
                reason: response.error ?? response.reason ?? "parse_failed",
            )
        }

        var symbols = makeSymbols(response.symbols, path: relPath)
        let names = Set(
            symbols.map(\.name)
                + response.edges.flatMap {
                    [$0.rawName, $0.toName, $0.fromName].compactMap { $0 }
                },
        )
        let existing = try database.symbols(named: Array(names)).filter { $0.path != relPath }
        var index = buildNameIndex(existing)
        for symbol in symbols {
            index[symbol.name, default: []].append(symbol)
        }

        let built = buildEdges(response, path: relPath, nameIndex: index)
        let unresolved = built.unresolved + response.unresolved.map {
            GraphDatabase.UnresolvedRow(
                path: relPath,
                rawName: $0.rawName,
                kind: $0.kind,
                line: $0.line,
                reason: $0.reason,
            )
        }
        let file = GraphDatabase.FileRow(
            path: relPath,
            lang: lang,
            size: content.count,
            mtime: modificationTime(fullPath),
            contentHash: hash,
        )
        symbols = dedupe(symbols)
        try database.replaceFile(file: file, symbols: symbols, edges: built.edges, unresolved: unresolved)

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        GraphLog.log(
            traceID: GraphLog.traceID(prefix: "gu"),
            op: "incremental",
            project: projectPath,
            file: relPath,
            elapsedMs: elapsedMs,
            edgeCount: built.edges.count,
            unresolvedCount: unresolved.count,
        )
        return true
    }

    func removeFile(relPath: String) throws {
        do {
            try removeFileImpl(relPath: relPath)
        } catch {
            if case GraphScannerError.stopped = error { throw error }
            recordIncrementalFailure(relPath, error.localizedDescription)
            throw error
        }
    }

    private func removeFileImpl(relPath: String) throws {
        if isStopped { throw GraphScannerError.stopped }
        let started = Date()
        try database.deletePathSubtree(path: relPath)
        stateLock.lock()
        let active = client
        stateLock.unlock()
        if let active {
            _ = try? active.removeFile(path: relPath)
        }
        GraphLog.log(
            traceID: GraphLog.traceID(prefix: "gd"),
            op: "delete",
            project: projectPath,
            file: relPath,
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            edgeCount: 0,
            unresolvedCount: 0,
        )
    }

    // MARK: - File collection

    private struct SourceFile {
        var path: String
        var lang: String
        var size: Int
        var mtime: Double
    }

    private func collectSourceFiles() throws -> [SourceFile] {
        let rootURL = URL(fileURLWithPath: projectPath)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else {
            throw GraphScannerError.cannotEnumerate(projectPath)
        }

        var result: [SourceFile] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let isDir = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if scannerConfig.shouldSkipDirectory(standardized.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let relPath = relativePath(of: standardized),
                  scannerConfig.shouldInclude(relPath)
            else { continue }
            let ext = standardized.pathExtension
            guard let lang = GraphProtocol.language(forExtension: ext),
                  allowedLanguages.contains(lang)
            else { continue }
            let values = try? standardized.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey])
            result.append(SourceFile(
                path: relPath,
                lang: lang,
                size: values?.fileSize ?? 0,
                mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            ))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func relativePath(of url: URL) -> String? {
        let prefix = projectPath + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return String(url.path.dropFirst(prefix.count))
    }

    private func fileURL(_ relPath: String) -> URL {
        URL(fileURLWithPath: (projectPath as NSString).appendingPathComponent(relPath))
    }

    private func modificationTime(_ path: String) -> Double {
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    // MARK: - Parsing results

    private func makeSymbols(
        _ raw: [GraphRawSymbol],
        path: String
    ) -> [GraphDatabase.SymbolRow] {
        raw.map { item in
            GraphDatabase.SymbolRow(
                symKey: GraphKey.symbolKey(
                    path: path,
                    name: item.name,
                    kind: item.kind,
                    signature: item.signature,
                    startLine: item.startLine,
                ),
                path: path,
                name: item.name,
                kind: item.kind,
                signature: item.signature,
                startLine: item.startLine,
                endLine: item.endLine,
            )
        }
    }

    private func dedupe(_ symbols: [GraphDatabase.SymbolRow]) -> [GraphDatabase.SymbolRow] {
        var seen = Set<String>()
        return symbols.filter { seen.insert($0.symKey).inserted }
    }

    private func buildNameIndex(
        _ symbols: [GraphDatabase.SymbolRow]
    ) -> [String: [GraphDatabase.SymbolRow]] {
        var index: [String: [GraphDatabase.SymbolRow]] = [:]
        for symbol in symbols {
            index[symbol.name, default: []].append(symbol)
        }
        return index
    }

    private func buildEdges(
        _ response: GraphIndexResponse,
        path: String,
        nameIndex: [String: [GraphDatabase.SymbolRow]]
    ) -> (edges: [GraphDatabase.EdgeRow], unresolved: [GraphDatabase.UnresolvedRow]) {
        var edges: [GraphDatabase.EdgeRow] = []
        var unresolved: [GraphDatabase.UnresolvedRow] = []

        for raw in response.edges {
            guard !raw.rawName.isEmpty else { continue }
            guard let targetKey = resolveTargetKey(raw, path: path, nameIndex: nameIndex) else {
                unresolved.append(GraphDatabase.UnresolvedRow(
                    path: path,
                    rawName: raw.rawName,
                    kind: raw.kind,
                    line: raw.line,
                    reason: "ambiguous",
                ))
                continue
            }
            let fromKey = resolveSourceKey(raw, path: path, nameIndex: nameIndex)
            let line = raw.line ?? raw.fromLine
            edges.append(GraphDatabase.EdgeRow(
                fromKey: fromKey,
                toKey: targetKey,
                kind: raw.kind,
                path: path,
                startLine: line,
                endLine: line,
                confidence: raw.confidence,
                resolver: raw.resolver,
                status: "ok",
            ))
        }
        return (edges, unresolved)
    }

    private func resolveTargetKey(
        _ edge: GraphRawEdge,
        path: String,
        nameIndex: [String: [GraphDatabase.SymbolRow]]
    ) -> String? {
        if let key = edge.toKey, !key.isEmpty {
            if key.hasPrefix("sym:") || key.hasPrefix("file:") { return key }
            return GraphKey.symbol(key)
        }

        let name = edge.toName ?? edge.rawName
        let candidates = nameIndex[name] ?? []

        if let toPath = edge.toPath {
            if edge.toName == nil { return GraphKey.file(toPath) }
            let scoped = candidates.filter { $0.path == toPath }
            if let match = scoped.first(where: { symbol in
                (edge.toKind == nil || symbol.kind == edge.toKind)
                    && (edge.toSignature == nil || symbol.signature == edge.toSignature)
            }) {
                return GraphKey.symbol(match.symKey)
            }
            return nil
        }

        let sameFile = candidates.filter { $0.path == path }
        if sameFile.count == 1 { return GraphKey.symbol(sameFile[0].symKey) }
        if candidates.count == 1 { return GraphKey.symbol(candidates[0].symKey) }
        return nil
    }

    private func resolveSourceKey(
        _ edge: GraphRawEdge,
        path: String,
        nameIndex: [String: [GraphDatabase.SymbolRow]]
    ) -> String {
        guard let fromName = edge.fromName else { return GraphKey.file(path) }
        let candidates = (nameIndex[fromName] ?? []).filter { $0.path == path }
        if let line = edge.fromLine {
            if let hit = candidates.first(where: { $0.startLine <= line && line <= $0.endLine }) {
                return GraphKey.symbol(hit.symKey)
            }
        }
        if let first = candidates.first {
            return GraphKey.symbol(first.symKey)
        }
        return GraphKey.file(path)
    }

    // MARK: - Diagnostics

    private func makeDiagnostics(
        elapsedMs: Int,
        failedFiles: [String],
        unresolved: [GraphDatabase.UnresolvedRow]
    ) -> [String: String] {
        let top = unresolved.prefix(20).map {
            "\($0.path):\($0.line ?? 0) \($0.rawName) \($0.kind) \($0.reason)"
        }
        return [
            "engine_version": GraphProtocol.engineVersion,
            "schema_version": GraphProtocol.schemaVersion,
            "last_full_elapsed_ms": String(elapsedMs),
            "failed_files": Self.encodeJSON(failedFiles.prefix(50).map { $0 }),
            "unresolved_top": Self.encodeJSON(Array(top)),
        ]
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys],
        ), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    // MARK: - Client

    private func indexer() throws -> GraphIndexerClient {
        stateLock.lock()
        defer { stateLock.unlock() }
        if stopped { throw GraphScannerError.stopped }
        if let client { return client }
        let created = GraphIndexerClient(config: GraphIndexerClient.Config(
            root: projectPath,
            maxRestarts: maxRestarts,
        ))
        created.onProcessChange = { [weak self] pid in
            self?.onIndexerPIDChange?(pid)
        }
        client = created
        return created
    }
}

enum GraphScannerError: LocalizedError {
    case cannotEnumerate(String)
    case indexFailed(path: String, reason: String)
    case stopped

    var errorDescription: String? {
        switch self {
        case let .cannotEnumerate(path):
            "cannot enumerate project at \(path)"
        case let .indexFailed(path, reason):
            "graph index failed for \(path): \(reason)"
        case .stopped:
            "graph scanner stopped"
        }
    }
}
