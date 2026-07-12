import Foundation

/// HTTP client for the local MCP project tool server.
final class MCPClient {
    static let shared = MCPClient()

    private let baseURL: String
    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    private init() {
        let port = ConfigManager.shared.config.mcp?.port ?? 9001
        baseURL = "http://127.0.0.1:\(port)"
    }

    // MARK: - Tools

    /// Search project symbols via FTS5 + synonym expansion.
    func search(query: String, dbPath: String) async throws -> SearchResult {
        let body = RequestBody(dbPath: dbPath, query: query)
        return try await post("/api/project/search", body: body)
    }

    /// Get directory/file tree structure.
    func structure(dbPath: String, subpath: String = "") async throws -> StructureResult {
        let body = RequestBody(dbPath: dbPath, path: subpath)
        return try await post("/api/project/structure", body: body)
    }

    /// List third-party packages.
    func packages(dbPath: String, type: String = "") async throws -> PackagesResult {
        let body = RequestBody(dbPath: dbPath, type: type)
        return try await post("/api/project/packages", body: body)
    }

    /// Get exported symbols for a file or directory.
    func exports(dbPath: String, path: String) async throws -> ExportsResult {
        let body = RequestBody(dbPath: dbPath, path: path)
        return try await post("/api/project/exports", body: body)
    }

    // MARK: - Internal

    private func post<T: Decodable>(_ endpoint: String, body: RequestBody) async throws -> T {
        guard let url = URL(string: baseURL + endpoint) else {
            throw MCPError.invalidURL(endpoint)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 5

        let (data, response) = try await session.data(for: req)

        guard let httpResp = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse
        }

        guard httpResp.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "unknown"
            throw MCPError.serverError(httpResp.statusCode, msg)
        }

        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Request body

private struct RequestBody: Codable {
    var dbPath: String = ""
    var query: String = ""
    var path: String = ""
    var type: String = ""
}

// MARK: - Response types

struct SearchResult: Decodable {
    let query: String
    let expandedQuery: String
    let results: [SearchHit]
    let total: Int
}

struct SearchHit: Decodable {
    let name: String
    let kind: String
    let signature: String?
    let file: String
    let visibility: String?
}

struct StructureResult: Decodable {
    let directories: [DirectoryNode]
    let files: [FileNode]
    let totalDirs: Int

    struct DirectoryNode: Decodable {
        let path: String
        let name: String?
        let fileCount: Int
        let isManifest: Bool
    }

    struct FileNode: Decodable {
        let path: String
        let ext: String
    }
}

struct PackagesResult: Decodable {
    let packages: [PackageInfo]
    let total: Int

    struct PackageInfo: Decodable {
        let name: String
        let version: String?
        let type: String
        let description: String?
        let sourceUrl: String?
    }
}

struct ExportsResult: Decodable {
    let path: String
    let isDirectory: Bool
    let symbols: [ExportSymbol]?
    let files: [ExportFile]?
    let total: Int?

    struct ExportSymbol: Decodable {
        let name: String
        let kind: String
        let signature: String?
        let visibility: String?
    }

    struct ExportFile: Decodable {
        let path: String
        let symbols: [ExportSymbol]
    }
}

// MARK: - Errors

enum MCPError: Error, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(e):
            return "Invalid URL: \(e)"
        case .invalidResponse:
            return "Invalid server response"
        case let .serverError(code, msg):
            return "Server \(code): \(msg)"
        }
    }
}

private struct ErrorBody: Decodable {
    let error: String
}
