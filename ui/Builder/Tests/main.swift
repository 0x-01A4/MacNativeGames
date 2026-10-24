import Foundation

// The Builder's core without the app: event parsing (Fixtures/totk-build.jsonl), error text, and BuildRunner against
// Fixtures/fake_build.py (the events, an error, cancel). usage: builder-tests <Fixtures folder>

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok {
        failures += 1
        print("FAIL line \(line): \(what)")
    }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures")

// events
let lines = try String(contentsOf: fixtures.appendingPathComponent("totk-build.jsonl"), encoding: .utf8)
    .split(separator: "\n").map(String.init)
let events = lines.map(BuildEvent.parse)
expect(events.count == 12, "12 fixture lines")
expect(events[0]?.type == "hello" && events[0]?.schema == BuildEvent.schema, "hello carries the schema")
expect(events[2].flatMap(BuildStage.init(event:)) == .code, "step 1 is the code stage")
expect(events[4]?.stage == "update" && events[4].flatMap(BuildStage.init(event:)) == .data, "update counts as the data step")
expect(events[1].flatMap(BuildStage.init(event:)) == nil, "step 0 (prepare) is before the four steps")
expect(events[3]?.type == "heartbeat", "heartbeat")
expect(events[7]?.out == "/Games/Tears of the Kingdom.app" && events[7]?.version == "v143", "done names the app")
expect(events[8] == nil, "a line that is not an event stays text")
expect(events[9]?.code == "fonts" && events[9]?.log == nil, "error code; null log")
let inspect = events[10]
expect(inspect?.appName == "Breath of the Wild" && inspect?.displayVersion == "1.9.0", "inspect names the game")
expect(inspect?.needsFonts == true && inspect?.platforms == ["macos"] && inspect?.dlc == true, "inspect needs")
expect(inspect?.defaultOut == "/Games/Breath of the Wild.app" && inspect?.work == "/Games/BotW_build", "inspect paths")
expect(events[2]?.logText == "1/4 code: rewriting main for Apple silicon (the big one: about a minute)", "log text keeps the step")
expect(BuildEvent.parse("{not json") == nil, "broken JSON stays text")
expect(events[11]?.type == "notice" && events[11]?.code == "npdm_signed" && events[11]?.step == 1, "a notice keeps its code and step")
expect(events[11]?.logText.hasPrefix("NOTE (npdm_signed): ") == true, "a notice reads as a note in the log")

// error text
for code in ["mod", "toolchain", "input", "keys_or_dump", "wrong_game", "unsupported_version", "hash_mismatch", "fonts", "disk_space", "platform"] {
    expect(ErrorText(code: code) != ErrorText(code: "build"), "\(code) has its own text")
}
expect(ErrorText(code: "something new") == ErrorText(code: nil), "unknown codes read as a failed build")

// runner
let python = ["/opt/homebrew/bin/python3.14", "/usr/local/bin/python3.14", "/usr/bin/python3"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }!
let fake = fixtures.appendingPathComponent("fake_build.py").path

final class Collected: @unchecked Sendable {
    let lock = NSLock()
    var out: [String] = [], err: [String] = []
    func add(_ line: String, stdout: Bool) {
        lock.lock()
        if stdout { out.append(line) } else { err.append(line) }
        lock.unlock()
    }
    var events: [BuildEvent] { lock.lock(); defer { lock.unlock() }; return out.compactMap(BuildEvent.parse) }
}

func fakeRun(_ mode: String, _ arguments: [String], cancelAfter: TimeInterval? = nil) throws -> (Int32, Collected) {
    setenv("FAKE_BUILD", mode, 1)
    setenv("FAKE_DELAY", "0.02", 1)
    let runner = BuildRunner()
    let got = Collected()
    if let cancelAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) { runner.cancel() }
    }
    let status = try runner.run(python, [fake] + arguments, stdout: { got.add($0, stdout: true) },
                                stderr: { got.add($0, stdout: false) })
    return (status, got)
}

do {
    let (status, got) = try fakeRun("ok", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "-o", "/Out/TOTK.app", "--json-progress"])
    expect(status == 0, "a finished build exits 0 (got \(status))")
    expect(got.events.first?.type == "hello", "the header comes first")
    expect(got.events.last?.type == "done" && got.events.last?.out == "/Out/TOTK.app", "done names the -o app")
    expect(got.events.filter { $0.type != "notice" }.compactMap(BuildStage.init(event:)).map(\.rawValue) == [1, 1, 2, 2, 3, 4, 4], "the steps in order")
    expect(got.err.contains("a line that is not an event"), "stderr arrives as text")
    expect(got.events.contains { $0.type == "notice" && $0.code == "npdm_signed" }, "notices arrive during the build")

    let (_, ipa) = try fakeRun("ok", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "--platform", "ios", "-o", "/Out/TOTK.ipa", "--json-progress"])
    expect(ipa.events.last?.platform == "ios" && ipa.events.last?.out == "/Out/TOTK.ipa", "an iPhone / iPad build ends with the IPA")

    setenv("FAKE_GAME", "botw", 1)
    let (_, botw) = try fakeRun("ok", ["/Games/botw.nsp", "-k", "/Keys/prod.keys", "--update", "/Games/u.nsp", "--inspect", "--json-progress"])
    expect(botw.events.last?.dlc == true && botw.events.last?.platforms == ["macos"], "Breath of the Wild 1.9.0 takes DLC, Mac only")
    let (refused, mod) = try fakeRun("ok", ["/Games/botw.xci", "-k", "/Keys/prod.keys", "--mod", "/Mods/x", "--inspect", "--json-progress"])
    expect(refused == 1 && mod.events.last?.code == "input", "a mod for Breath of the Wild is refused at inspect")
    unsetenv("FAKE_GAME")

    let (inspected, report) = try fakeRun("ok", ["/Games/totk.nsp", "-k", "/Keys/prod.keys", "--inspect", "--json-progress"])
    expect(inspected == 0 && report.events.last?.needsFonts == true, "inspect of an NSP asks for fonts")

    let (failed, error) = try fakeRun("fail", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "--json-progress"])
    expect(failed == 1, "a failed build exits 1 (got \(failed))")
    expect(error.events.last?.type == "error" && error.events.last?.code == "hash_mismatch", "the error event carries its code")

    let start = Date()
    let (stopped, cancelled) = try fakeRun("slow", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "--json-progress"], cancelAfter: 0.15)
    expect(stopped == 130, "cancel ends the build as Ctrl-C does (got \(stopped))")
    expect(cancelled.events.last?.type == "cancelled", "the build says it was cancelled")
    expect(Date().timeIntervalSince(start) < 5, "cancel does not wait for the slow step")
} catch {
    expect(false, "the runner started python: \(error)")
}

// library: a built app's record, the checkout comparison, the contribution file
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("builder-tests-\(getpid())")
try? FileManager.default.removeItem(at: scratch)
func write(_ text: String, _ path: String) {
    let url = scratch.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
func plist(_ id: String) -> String {
    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>\(id)</string>" +
    "<key>CFBundleName</key><string>Tears of the Kingdom</string><key>CFBundleShortVersionString</key><string>1.4.3</string></dict></plist>"
}
write(plist("org.macnativegames.totk"), "TOTK.app/Contents/Info.plist")
write("""
{"schema": 1, "game": "totk", "app_name": "Tears of the Kingdom", "version": "v143", "display_version": "1.4.3",
 "platform": "macos", "built": "2026-10-23T18:00:00Z", "commit": null, "dirty": null,
 "inputs": {"game": "/Games/totk.nsp", "update": "/Games/1.4.3.nsz", "shared_fonts": "/Fonts", "install_mod_romfs": true}}
""", "TOTK.app/Contents/Resources/build-info.json")
write(plist("com.example.other"), "Other.app/Contents/Info.plist")
write(plist("org.macnativegames.totk"), "Old.app/Contents/Info.plist")   // built before build-info.json
let built = BuiltApp(scratch.appendingPathComponent("TOTK.app"))
expect(built?.info?.displayVersion == "1.4.3" && built?.info?.inputs.sharedFonts == "/Fonts", "the build record is read")
expect(built?.info?.inputs.installModRomfs == true && built?.info?.inputs.firmware == nil, "the record's inputs")
expect(built?.info?.builtDate != nil, "the build date parses")
expect(BuiltApp(scratch.appendingPathComponent("Other.app")) == nil, "another app is not a game app")
expect(BuiltApp(scratch.appendingPathComponent("Old.app")).map { $0.info == nil } == true, "an app without a record is still listed")
expect(Freshness.of(built?.info, repo: scratch) == .unknown, "no commit in the record: unknown")

let repo = scratch.appendingPathComponent("repo")
write("x\n", "repo/build_app.py")
write("y\n", "repo/games/totk/a.txt")
write("z\n", "repo/docs/b.md")
func git(_ args: String...) -> String {
    Shell.run("/usr/bin/git", ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)
        .output.trimmingCharacters(in: .whitespacesAndNewlines)
}
_ = git("init", "-q"); _ = git("add", "-A"); _ = git("commit", "-qm", "one")
let first = git("rev-parse", "HEAD")
func record(_ commit: String) -> BuildInfo {
    var info = built!.info!
    info.commit = commit
    return info
}
expect(Freshness.of(record(first), repo: repo) == .current, "built from HEAD: current")
write("z2\n", "repo/docs/b.md"); _ = git("commit", "-qam", "docs")
expect(Freshness.of(record(first), repo: repo) == .current, "a change outside the build's folders keeps it current")
write("y2\n", "repo/games/totk/a.txt"); _ = git("commit", "-qam", "game")
expect(Freshness.of(record(first), repo: repo) == .changed, "a change in games/totk: changed")
expect(Freshness.of(record(String(repeating: "0", count: 40)), repo: repo) == .unknown, "a commit the checkout lacks: unknown")

let contrib = scratch.appendingPathComponent("TOTK/shader-list-contribution.txt")
write("# rows\nV\ta\t{}\nV\ta\t{}\nR\tk\nB\tk\tv\tf\nnoise\n", "TOTK/shader-list-contribution.txt")
var c = Contribution.read(game: "totk", file: contrib)!
expect(c.rows == 3 && c.remindedAt == nil && !c.never && c.unsent == 3, "distinct V, R and B rows count, as the game counts them")
try? c.markSent()
c = Contribution.read(game: "totk", file: contrib)!
expect(c.remindedAt == 3 && c.unsent == 0, "sending moves the reminder on")
try? c.stopReminders()
expect(Contribution.read(game: "totk", file: contrib)!.never, "don't remind me again writes never, as the launcher does")
expect((try? String(contentsOf: Contribution.remindedFile(contrib), encoding: .utf8)) == "never\n", "the launcher's own format")
try? c.resumeReminders()
expect(Contribution.read(game: "totk", file: contrib)!.never == false, "reminders back on")
expect(Contribution.all(base: { scratch.appendingPathComponent($0) }).map(\.game) == ["totk"], "only the games with a file")
expect(c.step == 100 && Contribution.read(game: "botw", file: contrib)!.step == 500, "each game's reminder step")
try? FileManager.default.removeItem(at: scratch)

print(failures == 0 ? "builder tests: all passed" : "builder tests: \(failures) failed")
exit(failures == 0 ? 0 : 1)
