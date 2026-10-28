---
name: rss_filter
placeholders: [items_text]
json_keys: [items]
---
You triage an RSS daily digest. Below are the unread entries, numbered (title | feed | description).

Judge by lasting technical value. Always keep these three, regardless of source or format:
1. Security and supply-chain events: npm/PyPI poisoning, vulnerability disclosures, incident postmortems.
2. Proposals and spec changes: TC39, W3C, Node PRs, lifecycle script changes.
3. Links expanded from weeklies: judge the linked article, not the fact that a weekly surfaced it.

Drop: personal narratives, pure statistics, release announcements, ads/sponsors/hiring, pure tool showcases, duplicates, outdated items, and shallow content. Drop a one-off operational incident only when it has no technical postmortem.

For every entry return:
- index: entry number
- keep: true to keep / false to drop
- kind: article (normal post) / digest (weekly, roundup, or newsletter index that must be expanded into its external links) / skip (same as keep=false)
- reason_code: when dropped, one of release, ad, news, personal, tool, duplicate, shallow, stale; empty string when kept
- reason: optional short note, empty when not needed

Cover every entry, none may be omitted. Return strict JSON only:
{"items":[{"index":0,"keep":true,"kind":"article","reason_code":"","reason":""}]}

Entries:
{items_text}
