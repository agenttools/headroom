// The `headroom` CLI (docs/DECISIONS.md "CLI", docs/cli.md).
// Built on the same composition root as the app (Headroom.context → WorldProvider + ActionExecutor),
// so there is no second copy of the collection, planning or signalling logic.
//
// Exit codes: 0 ok, 1 error, 2 needs confirmation / refused.

import Foundation
import HeadroomContracts
import HeadroomActions
import HeadroomCore

enum HeadroomCLI {
    static let usage = """
    usage: headroom [--mock] <command> [options]

      list     [--json] [--kind tabs|sessions|leftovers|all]
               Chrome tabs, Claude sessions and leftovers by memory, with stable ids.
      suggest  [--json] [--min-mb N] [--ask [--model M] [--timeout S]]
               Close candidates from the rules (instant); --ask also asks `claude -p` (never closes anything).
      close    <ids…> [--dry-run] [--yes] [--force-confirm [--include-busy]] [--keep-background] [--json]
               Close through the app's Planner and CloseCoordinator. Refuses locked items, and items the
               app would confirm unless --force-confirm. Busy sessions also need --include-busy.
               Asks y/N on a terminal; otherwise needs --yes.
      undo     [--last | <id>] [--list] [--dry-run] [--json]
               Restore from Recently Closed (reopen tab / claude --resume in tmux or Rex).
      selftest [sys|ownership|claude|chrome]
               Read-only checks of the process scan, ownership, Claude sessions and Chrome.

    --mock (or HEADROOM_MOCK=1) uses the built-in MockWorld and touches nothing.
    HEADROOM_DRY_RUN=1 makes every close and signal a logged no-op.
    Exit codes: 0 ok, 1 error, 2 needs confirmation or refused.  Docs: docs/cli.md
    """

    /// `makeContext` is the seam tests use to share one mock context between runs.
    static func run(_ argv: [String], io: CLIIO = .standard,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    makeContext: (HeadroomEnv) -> HeadroomContext = { Headroom.context(env: $0) }) async -> Int32 {
        var args = argv
        var env = HeadroomEnv(environment: environment)
        if let i = args.firstIndex(of: "--mock") { args.remove(at: i); env.mock = true }
        guard let cmd = args.first else { io.err(usage); return Exit.error }
        let rest = Array(args.dropFirst())
        do throws(CLIError) {
            switch cmd {
            case "list":
                let a = try ParsedArgs.parse(rest, flags: ["json"], options: ["kind"])
                try noPositionals(a, "list", hint: "use --kind tabs|sessions|leftovers")
                return await list(a, makeContext(env), io)
            case "suggest":
                let a = try ParsedArgs.parse(rest, flags: ["json", "ask"], options: ["min-mb", "model", "timeout"])
                try noPositionals(a, "suggest", hint: "use --min-mb N for a size filter")
                return await suggest(a, makeContext(env), io, environment: environment)
            case "close":
                let a = try ParsedArgs.parse(rest, flags: ["json", "dry-run", "yes", "force-confirm", "include-busy",
                                                           "keep-background"],
                                             short: ["-y": "yes", "-n": "dry-run"])
                if a.has("dry-run") { env.dryRun = true }
                return await CloseCommand.run(a, makeContext(env), io)
            case "undo":
                let a = try ParsedArgs.parse(rest, flags: ["json", "last", "list", "dry-run"])
                if a.has("dry-run") { env.dryRun = true }
                return await UndoCommand.run(a, makeContext(env), io)
            case "selftest", "--selftest":
                return await selftest(rest, env, io)
            case "-h", "--help", "help":
                io.out(usage); return Exit.ok
            case "--version", "version":
                io.out("headroom \(HeadroomIDs.version)"); return Exit.ok
            default:
                throw CLIError("unknown command \(cmd)")
            }
        } catch {
            io.err("headroom: \(error.message)")
            if error.code == Exit.error { io.err("run `headroom --help` for usage") }
            return error.code
        }
    }

    /// `list` and `suggest` take no positional arguments; a stray one is usually a forgotten flag name.
    static func noPositionals(_ a: ParsedArgs, _ cmd: String, hint: String) throws(CLIError) {
        if let x = a.positionals.first { throw CLIError("\(cmd): unexpected argument \(x) (\(hint))") }
    }

    // MARK: list

    static func list(_ a: ParsedArgs, _ ctx: HeadroomContext, _ io: CLIIO) async -> Int32 {
        var kind = ListKind.all
        if let k = a.options["kind"] {
            guard let v = ListKind(rawValue: k) else {
                io.err("headroom list: --kind must be tabs, sessions, leftovers or all")
                return Exit.error
            }
            kind = v
        }
        let world = await ctx.world.snapshot()
        let snap = ListSnapshot(world: world, protections: ctx.executor.protections(world), kind: kind,
                                dryRun: ctx.env.dryRun)
        if a.has("json") { return JSONOut.write(snap, io) }
        ListTable.render(snap, kind: kind, env: ctx.env, io: io)
        return Exit.ok
    }

    // MARK: suggest

    static func suggest(_ a: ParsedArgs, _ ctx: HeadroomContext, _ io: CLIIO,
                        environment: [String: String]) async -> Int32 {
        var minBytes: Bytes = 0
        if let m = a.options["min-mb"] {
            guard let v = Double(m), v >= 0 else { io.err("headroom suggest: --min-mb needs a number"); return Exit.error }
            minBytes = .mb(v)
        }
        var timeout = SuggestTuning.askTimeout
        if let t = a.options["timeout"] {
            guard let v = Double(t), v > 0 else { io.err("headroom suggest: --timeout needs seconds"); return Exit.error }
            timeout = v
        }
        let world = await ctx.world.snapshot()
        let prot = ctx.executor.protections(world)
        let executor = ctx.executor
        let plan: SuggestRules.PlanFn = { executor.plan($0, $1) }
        let now = Date()
        let rules = SuggestRules().suggest(world, protections: prot, plan: plan, minBytes: minBytes, now: now)
        let skipped = SuggestRules.skipped(world)
        let rulesReport = SuggestReport(generatedAt: world.at, source: "rules", suggestions: rules,
                                        chromeSource: world.chrome.source.name, skipped: skipped.isEmpty ? nil : skipped)

        guard a.has("ask") else {
            if a.has("json") { return JSONOut.write(rulesReport, io) }
            SuggestText.render(rulesReport, world: world, header: "Suggestions (rules)", warnings: [], io: io,
                               safeEstimate: safeEstimate(rulesReport, world, plan))
            return Exit.ok
        }

        // --ask
        guard let claude = AskClaude.locate(environment: environment, home: ctx.env.home) else {
            io.err("headroom suggest --ask: `claude` not found on PATH (set HEADROOM_ASK_CLAUDE to its path)")
            return Exit.error
        }
        let list = ListSnapshot(world: world, protections: prot, kind: .all, dryRun: ctx.env.dryRun, now: now)
        let git = ctx.isMock ? [:] : await AskClaude.gitState(world)
        let asker = AskClaude(claudePath: claude, model: a.options["model"], timeout: timeout)
        if !a.has("json") { io.err("Asking claude -p (up to \(Int(timeout)) s; nothing will be closed)…") }
        let started = Date()
        do throws(CLIError) {
            let answer = try await asker.run(prompt: AskClaude.prompt(list: list, rules: rulesReport, git: git))
            let checked = try AskParser.validate(answer, list: list, world: world, protections: prot, plan: plan)
            var notes = checked.prose
            if !checked.warnings.isEmpty {
                notes += (notes.isEmpty ? "" : "\n\n") + checked.warnings.map { "[headroom] " + $0 }.joined(separator: "\n")
            }
            let report = SuggestReport(generatedAt: world.at, source: "claude", suggestions: checked.suggestions,
                                       notes: notes.isEmpty ? nil : notes, chromeSource: world.chrome.source.name,
                                       skipped: skipped.isEmpty ? nil : skipped)
            if a.has("json") { return JSONOut.write(report, io) }
            let secs = Int(Date().timeIntervalSince(started).rounded())
            SuggestText.render(report, world: world, header: "Suggestions (claude -p, \(secs) s)", warnings: checked.warnings,
                               io: io, prose: checked.prose, safeEstimate: safeEstimate(report, world, plan))
            return Exit.ok
        } catch {
            io.err("headroom suggest --ask: \(error.message)")
            io.err("Run `headroom suggest` without --ask for the rules result.")
            return error.code
        }
    }

    /// The Planner's freed() estimate for closing every "safe" suggestion together (shared renderers counted once).
    static func safeEstimate(_ r: SuggestReport, _ w: WorldSnapshot, _ plan: SuggestRules.PlanFn) -> Bytes? {
        let ids = Set(r.suggestions.filter { $0.verdict == .safe }.map(\.id))
        return ids.isEmpty ? nil : plan(ids, w).estimate
    }

    // MARK: selftest

    static func selftest(_ groups: [String], _ env: HeadroomEnv, _ io: CLIIO) async -> Int32 {
        let known = Set(HeadroomSelfTest.groups)
        if let bad = groups.first(where: { !known.contains($0) }) {
            io.err("headroom selftest: unknown group \(bad) (known: \(HeadroomSelfTest.groups.joined(separator: ", ")))")
            return Exit.error
        }
        let s = LiveServices(env: env)
        let r = await HeadroomSelfTest.run(groups, services: s)
        s.chrome.stop()
        io.out(r.render())
        return r.passed ? Exit.ok : Exit.error
    }
}
