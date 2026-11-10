// `headroom suggest --ask`: sends the snapshot and the rules result to `claude -p` (headless, no tools,
// fixed prompt), then validates Claude's JSON against the snapshot. It never closes anything.
//
// Validation (Headroom has the last word, Claude only advises):
//   - ids must parse and be in the snapshot; others are dropped with a warning;
//   - verdict must be safe|confirm|keep;
//   - a locked item is forced to "keep";
//   - "safe" on an item the Planner wants confirmed becomes "confirm";
//   - the "safe" set is re-planned as one close, exactly as for the rules (SuggestRules.enforceBatch);
//   - bytes and titles always come from the snapshot, never from Claude.
//
// Test seam: HEADROOM_ASK_CLAUDE=<path> replaces the `claude` binary (tests use a fake script).

import Foundation
import HeadroomContracts
import HeadroomCore

struct AskClaude {
    var claudePath: String
    var model: String?
    var timeout: TimeInterval = SuggestTuning.askTimeout

    /// Flags for a headless, tool-less, non-persistent run. The prompt goes in on stdin.
    var arguments: [String] {
        var a = ["-p", "--output-format", "text", "--tools", "", "--strict-mcp-config", "--no-session-persistence"]
        if let m = model { a += ["--model", m] }
        return a
    }

    /// HEADROOM_ASK_CLAUDE, else `claude` on PATH (plus the usual install locations).
    static func locate(environment e: [String: String], home: String) -> String? {
        if let p = e["HEADROOM_ASK_CLAUDE"], !p.isEmpty { return p }
        var dirs = (e["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        let fm = FileManager.default
        return dirs.map { $0 + "/claude" }.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs `claude -p` in a temporary directory (so no project CLAUDE.md is picked up).
    func run(prompt: String) async throws(CLIError) -> String {
        let r = await Shell.run(claudePath, arguments, timeout: timeout, stdin: Data(prompt.utf8),
                                cwd: NSTemporaryDirectory())
        if r.timedOut { throw CLIError("claude -p timed out after \(Int(timeout)) s (nothing was closed)") }
        if r.status != 0 {
            let tail = Text.trunc(Text.oneLine(r.stderr.isEmpty ? r.stdout : r.stderr), 300)
            throw CLIError("claude -p failed (exit \(r.status)): \(tail)")
        }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { throw CLIError("claude -p returned nothing") }
        return out
    }

    // MARK: Prompt

    static let instructions = """
    You are advising the user of Headroom, a macOS tool that lists Chrome tabs, Claude Code sessions and \
    leftover dev servers by memory footprint. Headroom's built-in rules have already picked candidates. \
    Decide what is safe to close to free memory, and why. You only advise: Headroom closes nothing on your word.

    Verdicts:
    - "safe": closing loses nothing that matters, and Headroom's Undo can bring it back (tabs reopen; \
    sessions resume with `claude --resume` in a new tmux window).
    - "confirm": probably worth closing, but the user should look first (uncommitted git changes, a last \
    prompt that looks unfinished, a leftover dev server, which cannot be undone).
    - "keep": do not close.

    Rules:
    - Use only ids that appear in SNAPSHOT.items. Never invent or modify ids.
    - An item with "protection": "locked" is always "keep".
    - An item with "protection": "confirm" is "confirm" or "keep", never "safe".
    - Busy sessions and active, audible or pinned tabs are "keep" unless there is a strong reason.
    - Weigh idle time (idleSeconds), memory (bytes), git state (GIT), the last prompt, background \
    processes (backgroundBytes), and tab titles and URLs.
    - Leaving an item out means no opinion. Do not use tools; answer from the data below only.

    Answer format (strict):
    1. First, one fenced code block tagged json that contains exactly one object:
       {"suggestions":[{"id":"<id>","verdict":"safe|confirm|keep","reason":"<one short sentence>"}]}
       Put the items that free the most memory first.
    2. Then, after the code block, at most 8 short lines of plain prose: what to close first and what to check.
    """

    /// The fixed prompt plus the data. Incognito tab titles are redacted (their URLs are never in the list).
    static func prompt(list: ListSnapshot, rules: SuggestReport, git: [String: GitDirty]) -> String {
        let enc = HeadroomJSON.encoder(pretty: false)
        var snapshot = (try? enc.encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if var obj = (try? JSONSerialization.jsonObject(with: Data(snapshot.utf8))) as? [String: Any],
           var items = obj["items"] as? [[String: Any]] {
            for i in items.indices where (items[i]["incognito"] as? Bool) == true { items[i]["title"] = "(incognito tab)" }
            obj["items"] = items
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) {
                snapshot = String(decoding: d, as: UTF8.self)
            }
        }
        let rulesJSON = (try? enc.encode(rules)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let gitJSON = (try? enc.encode(git)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        \(instructions)

        SNAPSHOT (headroom list --json):
        \(snapshot)

        RULES (headroom suggest --json, the built-in rules' result):
        \(rulesJSON)

        GIT (keyed by session item id: dirtyFiles = uncommitted tracked files, ahead = commits not pushed; \
        a missing session means unknown):
        \(gitJSON)
        """
    }

    /// Uncommitted-change counts for live sessions whose cwd exists (read-only, 2 s timeout each, at most 4 at once).
    static func gitState(_ w: WorldSnapshot) async -> [String: GitDirty] {
        await withTaskGroup(of: (String, GitDirty?).self) { g in
            for s in w.claude.sessions where s.cwdExists && !s.unregistered {
                let id = s.itemID.stringValue, cwd = s.cwd
                g.addTask { (id, await GitInfo.dirty(cwd: cwd)) }
            }
            var out: [String: GitDirty] = [:]
            for await (id, d) in g { if let d { out[id] = d } }
            return out
        }
    }
}

// MARK: - Parsing and validation

struct AskResult {
    var suggestions: [Suggestion]
    var prose: String
    var warnings: [String]
}

enum AskParser {
    /// Splits Claude's answer into the JSON object and the prose around it.
    static func split(_ text: String) -> (json: String?, prose: String) {
        // 1. A ```json fence (or a bare ``` fence whose body starts with "{").
        var search = text.startIndex
        while let open = text.range(of: "```", range: search..<text.endIndex) {
            let lineEnd = text[open.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let tag = text[open.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces).lowercased()
            guard lineEnd < text.endIndex,
                  let close = text.range(of: "```", range: text.index(after: lineEnd)..<text.endIndex) else { break }
            let body = text[text.index(after: lineEnd)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if tag == "json" || (tag.isEmpty && body.hasPrefix("{")) {
                return (body, joinProse(text[..<open.lowerBound], text[close.upperBound...]))
            }
            search = close.upperBound
        }
        // 2. The first balanced {...} (string-aware).
        guard let start = text.firstIndex(of: "{") else { return (nil, text) }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: i)
                    return (String(text[start..<end]), joinProse(text[..<start], text[end...]))
                }
            }
            i = text.index(after: i)
        }
        return (nil, text)
    }

    /// The text before and after the JSON, trimmed, separated by one blank line.
    static func joinProse(_ before: Substring, _ after: Substring) -> String {
        [before, after].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Validates Claude's answer against the snapshot and the Planner (see the header comment).
    static func validate(_ text: String, list: ListSnapshot, world: WorldSnapshot,
                         protections: [ItemID: Protection], plan: SuggestRules.PlanFn) throws(CLIError) -> AskResult {
        let (jsonText, prose) = split(text)
        guard let jsonText, let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw CLIError("claude's answer has no valid JSON block:\n" + Text.trunc(text, 800))
        }
        let raw: [Any]
        if let obj = root as? [String: Any], let s = obj["suggestions"] as? [Any] { raw = s }
        else if let arr = root as? [Any] { raw = arr }
        else { throw CLIError("claude's JSON has no \"suggestions\" array:\n" + Text.trunc(jsonText, 800)) }

        let byId = Dictionary(list.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var warnings: [String] = []
        var seen: Set<ItemID> = []
        var out: [Suggestion] = []
        for entry in raw {
            guard let e = entry as? [String: Any], let idStr = e["id"] as? String else {
                warnings.append("ignored an entry without an id"); continue
            }
            guard let id = ItemID(string: idStr), let item = byId[id.stringValue] else {
                warnings.append("ignored \(idStr): not an item in the snapshot"); continue
            }
            let vStr = (e["verdict"] as? String)?.lowercased() ?? ""
            guard var verdict = Verdict(rawValue: vStr) else {
                warnings.append("ignored \(idStr): unknown verdict \"\(vStr)\""); continue
            }
            guard seen.insert(id).inserted else { warnings.append("ignored a duplicate of \(idStr)"); continue }
            var reason = (e["reason"] as? String).map(Text.oneLine) ?? ""
            if reason.isEmpty { reason = "(no reason given)" }
            let p = protections[id] ?? .none
            if case .locked(let r) = p, verdict != .keep {
                warnings.append("\(idStr) is locked (\(r.text)): \(verdict.rawValue) → keep")
                verdict = .keep
                reason += " [Headroom: locked, \(r.text)]"
            } else if case .confirm(let rs) = p, verdict == .safe {
                let why = rs.map(\.text).joined(separator: "; ")
                warnings.append("\(idStr) needs confirmation (\(why)): safe → confirm")
                verdict = .confirm
                reason += " [Headroom asks first: \(why)]"
            }
            out.append(Suggestion(id: id, verdict: verdict, reason: reason, bytes: item.bytes ?? 0, title: item.title))
        }
        let before = Dictionary(out.map { ($0.id, $0.verdict) }, uniquingKeysWith: { a, _ in a })
        let checked = SuggestRules.enforceBatch(out, world, plan: plan)
        for s in checked where before[s.id] == .safe && s.verdict != .safe {
            warnings.append("\(s.id.stringValue): safe → \(s.verdict.rawValue) when closed together with the other safe items")
        }
        return AskResult(suggestions: checked, prose: prose, warnings: warnings)
    }
}
