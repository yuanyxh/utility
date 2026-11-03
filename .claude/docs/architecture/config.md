# 配置加载（ConfigTypes / ConfigManager）

> 从 `AGENTS.md` 分层迁出（2026-11-03），内容逐字保留。
> 修改配置模型前先读本文件。

- 所有字段 `decodeIfPresent`（避免缺少 key 导致 crash）
- YAML key 必须与 struct property 名完全相同
  - ⚠️ **Yams 的 `YAMLDecoder` 不做键名转换**（源码核实：无 `keyDecodingStrategy`，`_KeyedDecodingContainer` 直接用 `key.stringValue` 查表）。写成 snake_case 的 key **不会报错，只会静默回退到默认值**——历史上 `max_retries`/`retry_delay_ms`/`timeout_ms`/`default_tier` 四个键因此从未生效（默认值恰好相同所以没暴露）。新增配置项后要确认它真的进了二进制：`strings .build/debug/utility | grep <propertyName>`
  - `modelProxy.clientAccel` / `clientText` 段例外：解码走 `ConfigTypes.decodeAny`（用 `Decoder.container(keyedBy: AnyKey.self)` 另开任意键名容器），每个键**同时登记 camelCase 与 snake_case 两种拼写**（修复上述历史失效且不破坏既有配置）
    - ⚠️ 不要用 `K(stringValue:)` 去试探键名：合成 CodingKeys 的 `init?(stringValue:)` 只认 case 名，传 snake_case 恒返回 nil，回退分支会变成死代码（实测过）
- 默认值唯一来源是 `Sources/Resources/default-config.yaml`；用户配置只做覆盖，新增键先加默认段再改解码
