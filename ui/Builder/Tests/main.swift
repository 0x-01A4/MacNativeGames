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
var steps = BuildSteps()
expect(steps.count == 4 && steps.title(1) == BuildSteps().title(1) && steps.name(3) == "shaders", "build_app.py's four before any event")
events.compactMap { $0 }.forEach { steps.see($0) }
expect(steps.name(1) == "code" && steps.name(2) == "update", "each step's stage from its events")
expect(steps.title(2) == BuildSteps().title(2), "update reads as the data step")
expect(steps.names[0] == nil, "step 0 (prepare) is before the steps")
var five = BuildSteps()
five.see(BuildEvent(type: "progress", stage: "romfs_merge", step: 2, of: 5, message: "x"))
expect(BuildSteps(count: 8, names: [6: "runtime"]).title(6) == "Compile the runtime", "Odyssey's step names have titles")
expect(five.count == 5 && five.title(2) == "Romfs Merge" && five.title(5) == "Step 5" && five.name(1) == nil, "another script's steps")
var timed = BuildSteps()
for (step, time) in [(0, 100.0), (1, 130), (1, 160), (2, 400)] {
    timed.see(BuildEvent(type: "progress", time: time, stage: step == 0 ? "prepare" : "code", step: step, of: 4, message: "x"))
}
expect(timed.duration(0, now: 999) == 30 && timed.duration(1, now: 999) == 270, "a step lasts until the next one starts")
expect(timed.duration(2, now: 450) == 50 && timed.duration(3, now: 450) == nil, "the running step until now; one not reached")
timed.see(BuildEvent(type: "done", time: 500))
expect(timed.duration(2, now: 9999) == 100 && timed.elapsed(now: 9999) == 400, "the last step and the build end with done")
expect(BuildSteps.clock(42) == "0:42" && BuildSteps.clock(723) == "12:03" && BuildSteps.clock(3723) == "1:02:03", "clock text")
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
expect(BuildEvent.parse(#"{"type": "inspect", "dlc": true, "dlc_max": 2}"#)?.dlcMax == 2, "inspect says how many packs")
expect(inspect?.dlcMax == nil, "an inspect event from before dlc_max still reads")
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
    expect(got.events.filter { $0.type == "progress" }.compactMap(\.step).filter { $0 > 0 } == [1, 1, 2, 3, 4, 4], "the steps in order")
    expect(got.err.contains("a line that is not an event"), "stderr arrives as text")
    expect(got.events.contains { $0.type == "notice" && $0.code == "npdm_signed" }, "notices arrive during the build")

    let (_, ipa) = try fakeRun("ok", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "--platform", "ios", "-o", "/Out/TOTK.ipa", "--json-progress"])
    expect(ipa.events.last?.platform == "ios" && ipa.events.last?.out == "/Out/TOTK.ipa", "an iPhone / iPad build ends with the IPA")

    setenv("FAKE_GAME", "botw", 1)
    let (_, botw) = try fakeRun("ok", ["/Games/botw.nsp", "-k", "/Keys/prod.keys", "--update", "/Games/u.nsp", "--inspect", "--json-progress"])
    expect(botw.events.last?.dlc == true && botw.events.last?.platforms == ["macos", "ios"], "Breath of the Wild 1.9.0 takes DLC, Mac and iPhone / iPad")
    let (refused, mod) = try fakeRun("ok", ["/Games/botw.xci", "-k", "/Keys/prod.keys", "--mod", "/Mods/x", "--inspect", "--json-progress"])
    expect(refused == 1 && mod.events.last?.code == "input", "a mod for Breath of the Wild is refused at inspect")
    setenv("FAKE_GAME", "by3", 1)
    let (_, base) = try fakeRun("ok", ["/Games/by3.nsp", "-k", "/Keys/prod.keys", "--inspect", "--json-progress"])
    expect(base.events.last?.needsUpdate == true && base.events.last?.displayVersion == nil, "a base game that needs its update")
    expect(base.events.last?.mod == false && base.events.last?.spaceGb == ["macos": 20], "what the game takes and needs comes from inspect")
    setenv("FAKE_GAME", "odyssey", 1)
    let (_, smo) = try fakeRun("ok", ["/Games/smo.xci", "-k", "/Keys/prod.keys", "--json-progress"])
    var smoSteps = BuildSteps()
    smo.events.forEach { smoSteps.see($0) }
    expect(smoSteps.count == 8 && smoSteps.name(5) == "tables" && smo.events.last?.game == "odyssey", "a build of eight steps")
    unsetenv("FAKE_GAME")

    let (inspected, report) = try fakeRun("ok", ["/Games/totk.nsp", "-k", "/Keys/prod.keys", "--inspect", "--json-progress"])
    expect(inspected == 0 && report.events.last?.needsFonts == true, "inspect of an NSP asks for fonts")
    expect(report.events.last?.mod == true && report.events.last?.needsUpdate == false, "a game that takes a mod")
    expect(report.events.last?.spaceGb?["ios"] == 45, "space per platform")

    let (failed, error) = try fakeRun("fail", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "--json-progress"])
    expect(failed == 1, "a failed build exits 1 (got \(failed))")
    expect(error.events.last?.type == "error" && error.events.last?.code == "hash_mismatch", "the error event carries its code")
    expect(error.events.last?.log.map { FileManager.default.fileExists(atPath: $0) } == true, "the error event names the failed tool's log")

    let start = Date()
    let (stopped, cancelled) = try fakeRun("slow", ["/Games/totk.xci", "-k", "/Keys/prod.keys", "--json-progress"], cancelAfter: 0.15)
    expect(stopped == 130, "cancel ends the build as Ctrl-C does (got \(stopped))")
    expect(cancelled.events.last?.type == "cancelled", "the build says it was cancelled")
    expect(Date().timeIntervalSince(start) < 5, "cancel does not wait for the slow step")
} catch {
    expect(false, "the runner started python: \(error)")
}

// the environment the Builder adds reaches the script, next to this process's own
do {
    let got = Collected()
    setenv("BUILDER_TEST_OWN", "kept", 1)
    let status = try BuildRunner().run(python, ["-c", "import os, sys; print(os.environ['BUILDER_TEST_OWN'], sys.dont_write_bytecode)"],
                                       environment: ["PYTHONDONTWRITEBYTECODE": "1"], stdout: { got.add($0, stdout: true) },
                                       stderr: { got.add($0, stdout: false) })
    expect(status == 0 && got.out == ["kept True"], "the added environment and this app's own (got \(got.out), \(got.err))")
} catch {
    expect(false, "the runner started python: \(error)")
}

// games: this checkout's games/*/game.json, and the versions from their assets
let checkout = fixtures.appendingPathComponent("../../../..").standardizedFileURL
let games = Game.load(repo: checkout)
expect(Preflight.isRepo(checkout), "the checkout is found by build_app.py and its game manifests")
expect(Set(games.map(\.id)) == ["totk", "botw", "by3", "odyssey", "dread"], "every game folder with a game.json (got \(games.map(\.id)))")
let dread = games.named("dread")
expect(dread?.versions == ["1.0.0"] && dread?.files.game == ["xci", "nsp"] && dread?.files.update == [] && dread?.build == "games/dread/build.py", "a game with one base file and its own build")
let odyssey = games.named("odyssey")
expect(odyssey?.versions == ["1.3.0"] && odyssey?.dataBesideApp == "Odyssey Data" && odyssey?.dataFolder == nil, "versions and data from the manifest")
expect(odyssey?.files.update == [] && games.updateExtensions == ["nsp", "nsz"], "a game whose one file holds its update")
let totk = games.named("totk")
expect(totk?.versions == ["1.0.0", "1.1.2", "1.2.1", "1.4.3"], "versions from the expected-*.json files (got \(totk?.versions ?? []))")
expect(totk?.bundleId == "org.macnativegames.totk" && totk?.shaderContribution?.step == 100, "the manifest's fields")
expect(games.named("by3")?.shaderContribution == nil && games.named("by3")?.build == "games/by3/build.py", "a game with its own build")
expect(ErrorText(code: "unsupported_version", games: games).next.contains("Bayonetta 3 1.2.0"), "the versions in the error text")
expect(Game.load(repo: nil).isEmpty && !Preflight.isRepo(fixtures), "no checkout, no games")
expect(games.script(for: URL(fileURLWithPath: "/g/x.nsp")) == "build_app.py", "an NSP goes to build_app.py, which hands Bayonetta 3 on")
expect(games.gameExtensions == ["nsp", "xci"] && games.updateExtensions == ["nsp", "nsz"], "the file types from the manifests")

// another game's manifest: its own file types; a folder without a build script yet; one that doesn't parse
let kinds = FileManager.default.temporaryDirectory.appendingPathComponent("builder-kinds-\(getpid())")
for (folder, json) in [
    ("next", #"{"schema": 1, "id": "next", "name": "Next", "title_id": "0100000000010000", "build": "games/next/build.py", "files": {"game": ["xci"]}}"#),
    ("planned", #"{"schema": 1, "id": "planned", "name": "Planned", "title_id": "0100000000020000"}"#),
    ("broken", #"{"schema": 1, "id": "broken"}"#),
] {
    let dir = kinds.appendingPathComponent("games/\(folder)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! json.write(to: dir.appendingPathComponent("game.json"), atomically: true, encoding: .utf8)
}
let other = Game.load(repo: kinds)
expect(other.map(\.id) == ["next", "planned"], "a manifest that doesn't parse is left out (got \(other.map(\.id)))")
expect(other.named("next")?.files.update == nil && other.named("planned")?.files.game == ["xci", "nsp"], "file types, and the default")
let mixed = games + other
expect(Set(mixed.accepting(URL(fileURLWithPath: "/g/x.XCI")).map(\.id)) == ["botw", "totk", "odyssey", "dread", "next"], "by3 takes NSPs only; a game without its build script yet is not offered")
expect(mixed.script(for: URL(fileURLWithPath: "/g/x.xci")) == "build_app.py", "several builds take an XCI: build_app.py hands it on")
try? FileManager.default.removeItem(at: kinds)

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
let built = BuiltApp(scratch.appendingPathComponent("TOTK.app"), games: games)
expect(built?.info?.displayVersion == "1.4.3" && built?.info?.inputs.sharedFonts == "/Fonts", "the build record is read")
expect(built?.info?.inputs.installModRomfs == true && built?.info?.inputs.firmware == nil, "the record's inputs")
expect(built?.info?.builtDate != nil, "the build date parses")
expect(built?.game == "totk", "the game from the bundle identifier")
expect(BuiltApp(scratch.appendingPathComponent("Other.app"), games: games) == nil, "another app is not a game app")
expect(BuiltApp(scratch.appendingPathComponent("TOTK.app"), games: []) == nil, "a checkout without games knows no apps")
expect(BuiltApp(scratch.appendingPathComponent("Old.app"), games: games).map { $0.info == nil } == true, "an app without a record is still listed")
expect(Freshness.of(built?.info, repo: scratch, games: games) == .unknown, "no commit in the record: unknown")
expect(built?.info?.work == nil, "a record from before the work folder was recorded still reads")
write("""
{"schema": 1, "game": "odyssey", "app_name": "Super Mario Odyssey", "version": "v130", "display_version": "1.3.0",
 "platform": "macos", "built": "2026-10-23T18:00:00Z", "commit": null, "dirty": null, "work": "/Games/Odyssey_build",
 "inputs": {"game": "/Games/smo.xci"}}
""", "SMO.app/Contents/Resources/build-info.json")
expect(BuildInfo.read(scratch.appendingPathComponent("SMO.app"))?.work == "/Games/Odyssey_build", "the record names the work folder")
expect(games.named("odyssey")?.needs == ["xcode"] && games.named("totk")?.needs == [], "game.json needs")
expect(games.named("totk")?.installTool == "games/totk/ios/tools/install_device.py" && games.named("by3")?.installTool == nil,
       "game.json install_tool")
expect(games.named("by3")?.workHoldsGameData == true && games.named("totk")?.workHoldsGameData == false, "game.json work_holds_game_data")

// work folders: the ones the records name, once each, and why one stays
func app(_ path: String, game: String, work: String?) -> BuiltApp {
    var a = built!
    a.url = scratch.appendingPathComponent(path)
    a.game = game
    a.info?.work = work.map { scratch.appendingPathComponent($0).path }
    return a
}
for folder in ["TOTK_build", "BY3_build", "Odyssey_build/Odyssey.app"] {
    try! FileManager.default.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
}
write(String(repeating: "x", count: 10_000), "TOTK_build/romfs.bin")
let works = WorkFolder.all(apps: [app("TOTK.app", game: "totk", work: "TOTK_build"), app("Two.app", game: "totk", work: "TOTK_build"),
                                  app("BY3.app", game: "by3", work: "BY3_build"),
                                  app("Odyssey_build/Odyssey.app", game: "odyssey", work: "Odyssey_build"),
                                  app("Gone.app", game: "totk", work: "Gone_build"), app("Old.app", game: "totk", work: nil)],
                           current: nil, games: games)
expect(works.map { $0.url.lastPathComponent } == ["TOTK_build", "BY3_build", "Odyssey_build"], "each folder once, only those there (got \(works.map(\.url.lastPathComponent)))")
expect(works[0].keep == nil && works[1].keep != nil && works[2].keep?.contains("inside") == true, "Bayonetta 3's data and an app inside stay")
expect(WorkFolder.all(apps: [], current: (scratch.appendingPathComponent("TOTK_build").path, "totk"), games: games).count == 1,
       "the folder of the game being built, before it has an app")
expect(WorkFolder.size(scratch.appendingPathComponent("TOTK_build")) >= 10_000, "a folder's size")
expect(Disk.existing(scratch.appendingPathComponent("TOTK_build/not/yet")) == scratch.appendingPathComponent("TOTK_build").standardizedFileURL,
       "the nearest folder that exists")
expect(Disk.canWrite(scratch.appendingPathComponent("new/App.app")) && !Disk.canWrite(URL(fileURLWithPath: "/System/App.app")), "where the build can write")
expect((Disk.freeBytes(scratch) ?? 0) > 0, "free space of a folder's drive")

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
expect(Freshness.of(record(first), repo: repo, games: games) == .current, "built from HEAD: current")
write("z2\n", "repo/docs/b.md"); _ = git("commit", "-qam", "docs")
expect(Freshness.of(record(first), repo: repo, games: games) == .current, "a change outside the build's folders keeps it current")
write("y2\n", "repo/games/totk/a.txt"); _ = git("commit", "-qam", "game")
expect(Freshness.of(record(first), repo: repo, games: games) == .changed, "a change in games/totk: changed")
expect(Freshness.of(record(String(repeating: "0", count: 40)), repo: repo, games: games) == .unknown, "a commit the checkout lacks: unknown")
let second = git("rev-parse", "HEAD")
expect(Freshness.of(record(second), repo: repo, games: games) == .current, "built from HEAD again: current")
write("y3\n", "repo/games/totk/a.txt")
expect(Freshness.of(record(second), repo: repo, games: games) == .changed, "an edit not committed yet: changed")
_ = git("checkout", "-q", "--", ".")
var dirty = record(second)
dirty.dirty = true
expect(Freshness.of(dirty, repo: repo, games: games) == .unknown, "built with local changes: unknown")

// a release's sources (make_dmg.sh): no git to compare, only the commit in their release.json
let release = Release(schema: Release.schema, commit: second, version: "0.2")
expect(Freshness.of(record(second), repo: repo, release: release, games: games) == .current, "a release: built from its commit")
expect(Freshness.of(record(first), repo: repo, release: release, games: games) == .otherRelease, "a release: built from another commit")
expect(Freshness.of(dirty, repo: repo, release: release, games: games) == .unknown, "a release: built with local changes")
expect(Freshness.of(built?.info, repo: repo, release: release, games: games) == .unknown, "a release: no commit in the record")
write("{\"schema\": 1, \"commit\": \"\(second)\", \"version\": \"0.2\"}\n", "repo/release.json")
expect(Release.read(repo) == release && Release.read(scratch) == nil && Release.read(nil) == nil, "release.json is read")
write("{\"schema\": 2, \"commit\": \"\(second)\", \"version\": \"0.2\"}\n", "repo/release.json")
expect(Release.read(repo) == nil, "a release.json of another schema is not")
let carried = "Release.app/Contents/Resources/checkout"
write("x\n", "\(carried)/build_app.py")
write(try! String(contentsOf: checkout.appendingPathComponent("games/totk/game.json"), encoding: .utf8), "\(carried)/games/totk/game.json")
let releaseApp = scratch.appendingPathComponent("Release.app")
expect(Preflight.findRepo(chosen: nil, bundle: releaseApp)?.path == scratch.appendingPathComponent(carried).path,
       "a release app's sources are found inside it")
expect(Preflight.findRepo(chosen: checkout.path, bundle: releaseApp)?.path == checkout.path, "a chosen checkout comes first")

let contrib = scratch.appendingPathComponent("TOTK/shader-list-contribution.txt")
write("# rows\nV\ta\t{}\nV\ta\t{}\nR\tk\nB\tk\tv\tf\nnoise\n", "TOTK/shader-list-contribution.txt")
var c = Contribution.read(game: totk!, file: contrib)!
expect(c.rows == 3 && c.remindedAt == nil && !c.never && c.unsent == 3, "distinct V, R and B rows count, as the game counts them")
try? c.markSent()
c = Contribution.read(game: totk!, file: contrib)!
expect(c.remindedAt == 3 && c.unsent == 0, "sending moves the reminder on")
try? c.stopReminders()
expect(Contribution.read(game: totk!, file: contrib)!.never, "don't remind me again writes never, as the launcher does")
expect((try? String(contentsOf: Contribution.remindedFile(contrib), encoding: .utf8)) == "never\n", "the launcher's own format")
try? c.resumeReminders()
expect(Contribution.read(game: totk!, file: contrib)!.never == false, "reminders back on")
expect(Contribution.all(games: games, base: { scratch.appendingPathComponent($0) }).map(\.game.id) == ["totk"], "only the games with a file")
expect(c.step == 100 && Contribution.read(game: games.named("botw")!, file: contrib)!.step == 500, "each game's reminder step")
expect(Contribution.read(game: games.named("by3")!, file: contrib) == nil, "a game without a shared shader list has no contribution")
try? FileManager.default.removeItem(at: scratch)

// a command for Terminal, and where an app keeps its saves
expect(Shell.quote("/Users/j/Jae's Games/TOTK.ipa") == "'/Users/j/Jae'\\''s Games/TOTK.ipa'", "a quote in a path")
expect(Shell.run("/bin/sh", ["-c", "printf %s " + Shell.quote("a 'b' $c")]).output == "a 'b' $c", "the shell reads it back as it was")
expect(games.dataLocation("totk") == "~/Library/Application Support/MacNativeGames/TOTK", "a game's data folder")
expect(games.dataLocation("odyssey").contains("Odyssey Data"), "a game that keeps its data next to the app")

// drops on the Game page
let sizes: [String: Int64] = ["/d/base.nsp": 16_000, "/d/upd.nsp": 900, "/d/card.xci": 100, "/d/upd.nsz": 2000]
func drop(_ paths: [String], game: String? = nil, identified: String? = nil, takesMod: Bool = false) -> Dropped {
    games.route(paths.map { URL(fileURLWithPath: $0) }, game: game.map { URL(fileURLWithPath: $0) }, identified: identified,
                takesMod: takesMod, isFolder: { !$0.path.contains(".") }, isMod: { $0.lastPathComponent == "mod" },
                size: { sizes[$0.path] ?? 0 })
}
let u = { (p: String) in URL(fileURLWithPath: p) }
expect(drop(["/d/base.nsp"]) == Dropped(game: u("/d/base.nsp")), "the first file is the game")
expect(drop(["/d/upd.nsp"], game: "/d/base.nsp", identified: "totk") == Dropped(update: u("/d/upd.nsp")), "an NSP onto a known game is its update")
expect(drop(["/d/other.xci"], game: "/d/base.nsp", identified: "odyssey") == Dropped(game: u("/d/other.xci")), "a game without updates: replaced")
expect(drop(["/d/upd.nsp"], game: "/d/base.nsp") == Dropped(game: u("/d/upd.nsp")), "before the game is known: replaced")
expect(drop(["/d/upd.nsp", "/d/base.nsp"]) == Dropped(game: u("/d/base.nsp"), update: u("/d/upd.nsp")), "two NSPs: the larger is the game")
expect(drop(["/d/upd.nsz", "/d/card.xci"]) == Dropped(game: u("/d/card.xci"), update: u("/d/upd.nsz")), "a card image is the game, however small")
expect(drop(["/d/notes.txt"]) == Dropped(), "a file no game takes is ignored")
expect(drop(["/d/fonts"]) == Dropped(), "a folder alone, before a game file, is ignored")
expect(drop(["/d/fonts"], game: "/d/base.nsp") == Dropped(fonts: u("/d/fonts")), "a folder is the fonts")
expect(drop(["/d/mod"], game: "/d/base.nsp", takesMod: true) == Dropped(mod: u("/d/mod")), "a folder with exefs/ or romfs/ is the mod")
expect(drop(["/d/mod"], game: "/d/base.nsp") == Dropped(), "a mod for a game that takes none is ignored")
expect(drop(["/d/base.nsp", "/d/mod"]) == Dropped(game: u("/d/base.nsp"), mod: u("/d/mod")), "a mod with a new game file is kept for it")
expect(drop(["/d/mod"]) == Dropped(), "a mod alone, before a game file, is ignored")

print(failures == 0 ? "builder tests: all passed" : "builder tests: \(failures) failed")
exit(failures == 0 ? 0 : 1)
