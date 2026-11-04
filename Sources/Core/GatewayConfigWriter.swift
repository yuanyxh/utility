import Foundation
import Yams

/// Writes the gateway-native `agent-gateway.yaml` beside the user-facing config.
///
/// The payload is JSON, which is valid YAML; this avoids a second hand-written
/// serializer while keeping one file the gateway can parse with PyYAML.
enum GatewayConfigWriter {
    static var fileURL: URL {
        AppPaths.configDir.appendingPathComponent("agent-gateway.yaml")
    }

    /// The generated file when present; the legacy `config.yaml` otherwise.
    static var activeConfigFile: URL {
        FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : AppPaths.configFile
    }

    static func write(_ config: AppConfig) throws {
        var root = existing()
        root["llm"] = [
            "apiKey": config.ai.apiKey,
            "baseURL": config.ai.baseURL,
            "model": config.ai.model,
            "timeout": config.ai.llmTimeout,
        ]
        root["language"] = config.general.language
        root["logging"] = [
            "maxSize": config.general.logMaxSize,
            "backupCount": config.general.logBackupCount,
        ]
        root["server"] = server(config)
        root["knowledge"] = knowledge(config.knowledge)
        root["graph"] = graph(config.graph, existing: root["graph"] as? [String: Any])
        if let search = legacySearch() {
            root["search"] = search
        }
        if let mcp = config.mcp {
            root["memory"] = memory(mcp)
            root["notes"] = notes(mcp)
            root["summary"] = [
                "enabled": mcp.summaryEnabled,
                "hour": mcp.summaryHour,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys],
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func existing() -> [String: Any] {
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let loaded = try? Yams.load(yaml: text) as? [String: Any]
        else { return [:] }
        return loaded
    }

    /// `search` is still owned by the host config; the native schema has no Swift model for it.
    private static func legacySearch() -> Any? {
        guard let text = try? String(contentsOf: AppPaths.configFile, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any]
        else { return nil }
        return root["search"]
    }

    private static func server(_ config: AppConfig) -> [String: Any] {
        var server: [String: Any] = [:]
        let mcp = config.mcp
        server["mcp"] = [
            "enabled": mcp?.enabled ?? false,
            "port": mcp?.port ?? 0,
            "synonyms": mcp?.synonyms ?? [:],
            "toolDefaults": mcp?.toolDefaults ?? [:],
        ]
        guard let proxy = config.modelProxy else {
            server["proxy"] = ["enabled": false]
            return server
        }
        server["proxy"] = [
            "enabled": proxy.enabled,
            "url": proxy.url,
            "port": proxy.port,
            "providers": object(proxy.providers) ?? [],
            "clientAccel": object(proxy.clientAccel) ?? NSNull(),
            "clientText": object(proxy.clientText) ?? NSNull(),
            "toolOutputDedup": proxy.toolOutputDedup,
            "responseAnnotationEnabled": proxy.responseAnnotationEnabled,
            "contextWarnTokens": proxy.contextWarnTokens,
            "outputFilter": object(proxy.outputFilter) ?? [:],
        ]
        return server
    }

    private static func memory(_ mcp: MCPConfig) -> [String: Any] {
        [
            "qdrantPath": mcp.qdrantPath,
            "protectImportance": mcp.memoryProtectImportance,
            "maxContentChars": mcp.memoryMaxContentChars,
            "maxSummaries": mcp.memoryMaxSummaries,
            "maxSummariesPerEpisode": mcp.memoryMaxSummariesPerEpisode,
            "rankSignal": [
                "recency": mcp.rankSignalRecency,
                "access": mcp.rankSignalAccess,
                "quality": mcp.rankSignalQuality,
            ],
            "embedder": [
                "model": mcp.embedderModel,
                "cacheDir": mcp.fastembedCacheDir,
                "idleUnloadSeconds": mcp.embedderIdleUnloadSeconds,
            ],
        ]
    }

    private static func notes(_ mcp: MCPConfig) -> [String: Any] {
        [
            "dir": mcp.knowledgeBasePath,
            "excludeDirs": mcp.noteExcludeDirs,
            "extensions": mcp.noteExtensions,
            "excludeTags": mcp.excludeTags,
        ]
    }

    private static func knowledge(_ knowledge: KnowledgeConfig) -> [String: Any] {
        [
            "enabled": knowledge.enabled,
            "topicTarget": knowledge.poolTargetTopic,
            "maxFailStreak": knowledge.maxFailStreak,
            "retentionDays": knowledge.retentionDays,
            "topics": object(knowledge.topics) ?? [],
        ]
    }

    private static func graph(
        _ graph: GraphConfig,
        existing: [String: Any]?,
    ) -> [String: Any] {
        var payload = existing ?? [:]
        payload["enabled"] = graph.enabled
        payload["languages"] = graph.languages
        if payload["stateDir"] == nil {
            payload["stateDir"] = ".agent-gateway"
        }
        return payload
    }

    private static func object<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
