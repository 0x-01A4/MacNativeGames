import AppKit
import Foundation
import Observation
import UserNotifications

/// The Builder's state: the files the player picked, what --inspect found, and the running build. Every build step is
/// build_app.py's; this only collects its arguments and reads its events.
@MainActor @Observable
final class Wizard {
    enum Step: Int, CaseIterable {
        case keys, game, target, build, result

        var title: String {
            switch self {
            case .keys: String(localized: "Keys")
            case .game: String(localized: "Game")
            case .target: String(localized: "Output")
            case .build: String(localized: "Build")
            case .result: String(localized: "Done")
            }
        }
    }

    enum Outcome: Equatable {
        case done(URL)
        case failed(code: String?, message: String, log: String? = nil)   // log: the failed tool's own log file
        case cancelled
    }

    private enum Defaults {
        static let repo = "repoPath"
        static let keys = "keysPath"   // only the location, and only when the player asks; never the keys themselves
        static let built = "builtApps"   // the Mac apps this Builder made, for the library (Spotlight finds the others)
    }

    enum Mode: Hashable { case build, library }
    var mode = Mode.build

    var step = Step.keys
    var preflight: Preflight
    var keys: URL?
    var rememberKeys: Bool
    var keysMoved: String?   // the remembered prod.keys location, when nothing is there any more
    var game: URL?
    var update: URL?
    var fonts: URL?
    var fontsAreFirmware = true
    var report: BuildEvent?
    // what the last --inspect of this game file said, kept while a re-inspect runs (report is nil then)
    var identified: String?   // the game's id
    var fontsNeeded: Bool?
    var inspectFailure: Outcome?
    var inspecting = false
    var out: URL?
    var platform = "macos" { didSet { if platform != oldValue { matchOutToPlatform() } } }
    var dlc: [URL] = []      // when inspect says the game takes them: up to two add-on content packs
    var mod: URL?             // when inspect says the game takes one: a folder with exefs/ and/or romfs/ (docs/mods.md)
    var installModRomfs = false
    var shaderReminder = true
    var notices: [BuildEvent] = []   // inputs accepted by another rule than the exact reference hash
    var running = false
    var cancelling = false   // Cancel was pressed and the build hasn't ended yet
    var progress: BuildEvent?
    var reached = 0          // the highest of the build's steps (1-n) it has reached
    var steps = BuildSteps()
    var outcome: Outcome?
    var lines: [String] = []

    @ObservationIgnored private var runner: BuildRunner?
    @ObservationIgnored private var job: Task<Void, Never>?   // reads the running script's output (start)
    @ObservationIgnored private var awake: NSObjectProtocol?   // keeps the Mac from idle sleep while a build runs
    /// Called once when the running build has ended (the app delegate waits on it to quit).
    @ObservationIgnored var onBuildEnded: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        preflight = Preflight.check(repo: Preflight.findRepo(chosen: defaults.string(forKey: Defaults.repo)))
        let saved = defaults.string(forKey: Defaults.keys)
        rememberKeys = saved != nil
        if let saved {
            if FileManager.default.fileExists(atPath: saved) { keys = URL(fileURLWithPath: saved) } else { keysMoved = saved }
        }
    }

    // MARK: setup

    func recheck() {
        preflight = Preflight.check(repo: preflight.repo ?? Preflight.findRepo(chosen: nil))
    }

    /// false when the folder isn't a checkout (no build_app.py, or no games/*/game.json).
    @discardableResult func chooseRepo(_ url: URL) -> Bool {
        guard Preflight.isRepo(url) else { return false }
        UserDefaults.standard.set(url.path, forKey: Defaults.repo)
        preflight = Preflight.check(repo: url)
        return true
    }

    func setKeys(_ url: URL) {
        keys = url
        keysMoved = nil
        saveKeysChoice()
    }

    func saveKeysChoice() {
        if rememberKeys, let keys {
            UserDefaults.standard.set(keys.path, forKey: Defaults.keys)
        } else {
            UserDefaults.standard.removeObject(forKey: Defaults.keys)
        }
    }

    var ready: Bool { preflight.python != nil && preflight.repo != nil }

    /// The game --inspect named takes an update file; until it has, a game its extension can be does.
    var takesUpdate: Bool {
        guard let game else { return false }
        if let found = preflight.games.named(identified) { return !(found.files.update ?? []).isEmpty }
        let candidates = preflight.games.accepting(game)
        return candidates.isEmpty || candidates.contains { !($0.files.update ?? []).isEmpty }
    }

    func setGame(_ url: URL) {
        choose(game: url)
        inspect()
    }

    /// A new game file: what was chosen for the one before goes, except the fonts folder.
    private func choose(game url: URL) {
        clearChoices()
        game = url
    }

    /// What belongs to one game file: the file, what --inspect named in it, and the choices made for it. The keys and
    /// the fonts folder stay, since another game can use them too.
    private func clearChoices() {
        platform = "macos"   // first: its didSet would make an output from the old report's default
        game = nil
        identified = nil
        fontsNeeded = nil
        update = nil
        dlc = []
        mod = nil
        installModRomfs = false
        out = nil
    }

    /// Files and folders dropped on the Game page (Array<Game>.route), read again in one --inspect, which replaces one
    /// still running. A mod is taken while --inspect hasn't said: if the game takes none, the next one says so.
    func drop(_ urls: [URL]) -> Bool {
        let d = preflight.games.route(urls, game: game, identified: identified, takesMod: report.map { $0.mod == true } ?? true,
                                      isFolder: \.isFolder,
                                      isMod: Self.isMod,
                                      size: { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) })
        guard d != Dropped() else { return false }
        if let g = d.game { choose(game: g) }
        if let u = d.update { update = u }
        if let f = d.fonts { fonts = f }
        if let m = d.mod { mod = m }
        inspect()
        return true
    }

    /// A folder with exefs/ or romfs/ in it is a mod (docs/mods.md).
    static func isMod(_ url: URL) -> Bool {
        ["exefs", "romfs"].contains { url.appendingPathComponent($0).isFolder }
    }

    func setFonts(_ url: URL?) {
        fonts = url
        inspect()   // build_app.py checks the folder before the build
    }

    /// Firmware or extracted shared fonts: a folder chosen as the other kind is not this one.
    func setFontsAreFirmware(_ firmware: Bool) {
        guard firmware != fontsAreFirmware else { return }
        fontsAreFirmware = firmware
        if fonts != nil { setFonts(nil) }
    }

    func addDLC(_ url: URL) {
        guard !dlc.contains(url), dlc.count < dlcMax else { return }
        dlc.append(url)
        inspect()   // the packs are checked against the version before the build (build_app.py check_dlc)
    }

    /// How many add-on packs the version takes (inspect's dlc_max; 2 from a script before that field).
    var dlcMax: Int { report?.dlcMax ?? 2 }

    /// The identified game's own game.json.
    var identifiedGame: Game? { preflight.games.named(identified) }

    /// What the identified game's Mac build needs that this Mac lacks (game.json "needs").
    var gameMissing: [Preflight.Missing] {
        !isDevice && identifiedGame?.needs.contains("xcode") == true ? preflight.xcodeMissing : []
    }

    func removeDLC(_ url: URL) {
        dlc.removeAll { $0 == url }
        inspect()
    }

    func setMod(_ url: URL?) {
        mod = url
        if url == nil { installModRomfs = false }
        inspect()   // build_app.py checks the folder's layout and the game before the build
    }

    var modHasRomfs: Bool { mod?.appendingPathComponent("romfs").isFolder == true }

    /// The platforms the found game builds for (inspect); iPhone/iPad and Vision Pro also need an Xcode on this Mac.
    var platforms: [String] { report?.platforms ?? ["macos"] }

    /// An iPhone / iPad or Vision Pro build: an IPA made with ios/tools/build_ipa.py, with no mod folder.
    var isDevice: Bool { platform != "macos" }

    static func platformName(_ platform: String) -> String {
        switch platform {
        case "macos": String(localized: "Mac")
        case "ios": String(localized: "iPhone / iPad")
        case "visionos": String(localized: "Apple Vision Pro")
        default: platform
        }
    }

    /// .app for the Mac, .ipa for iPhone/iPad, in the same folder and with the same name.
    private func matchOutToPlatform() {
        guard let current = out ?? report?.defaultOut.map({ URL(fileURLWithPath: $0) }) else { return }
        out = current.deletingPathExtension().appendingPathExtension(isDevice ? "ipa" : "app")
        if isDevice { installModRomfs = false }
    }

    func setUpdate(_ url: URL?) {
        update = url
        inspect()
    }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
        // a rebuild that had to ask for the keys first reads the game file now
        if step == .game, game != nil, report == nil, !inspecting { inspect() }
    }

    var fontsSatisfied: Bool { report?.needsFonts != true || fonts != nil }

    var canContinue: Bool {
        switch step {
        case .keys: ready && keys != nil
        case .game: report != nil && !inspecting && fontsSatisfied && (report?.needsUpdate != true || update != nil)
        case .target: out.map(Disk.canWrite) == true && (!isDevice || preflight.iosMissing.isEmpty) && gameMissing.isEmpty
        case .build, .result: false
        }
    }

    // MARK: build_app.py

    /// The arguments every run shares: the files, never their contents.
    private func inputs() -> [String] {
        guard let game, let keys else { return [] }
        var args = [game.path, "-k", keys.path]
        if let update { args += ["--update", update.path] }
        if let fonts { args += [fontsAreFirmware ? "--firmware" : "--shared-fonts", fonts.path] }
        for pack in dlc { args += ["--dlc", pack.path] }
        if let mod { args += ["--mod", mod.path] }
        return args + ["--json-progress"]
    }

    /// What only a build takes: the platform, the output and the options that act when it ends.
    private func buildOptions(_ out: URL) -> [String] {
        var args = ["--platform", platform, "-o", out.path]
        if installModRomfs && platform == "macos" && mod != nil { args.append("--install-mod-romfs") }
        if isDevice && !shaderReminder { args.append("--no-shader-reminder") }
        return args
    }

    /// The game's build script (build_app.py, or the one build of the games its extension can be: game.json "build"), or
    /// a stand-in for trying the Builder without game files (BUILDER_SCRIPT, ui/README.md).
    private var script: String? {
        ProcessInfo.processInfo.environment["BUILDER_SCRIPT"]
            ?? preflight.repo?.appendingPathComponent(game.map(preflight.games.script(for:)) ?? "build_app.py").path
    }

    func inspect() {
        guard game != nil, keys != nil else { return }
        report = nil
        inspectFailure = nil
        inspecting = true
        start(inputs() + ["--inspect"]) { [weak self] event in
            guard let self else { return }
            switch event.type {
            case "inspect":
                self.report = event
                self.identified = event.game
                self.fontsNeeded = event.needsFonts
                if !(event.platforms ?? ["macos"]).contains(self.platform) { self.platform = "macos" }
                if self.out == nil, let path = event.defaultOut {
                    let url = URL(fileURLWithPath: path)
                    self.out = self.isDevice ? url.deletingPathExtension().appendingPathExtension("ipa") : url
                }
            case "error": self.inspectFailure = .failed(code: event.code, message: event.message ?? "", log: event.log)
            default: break
            }
        } finished: { [weak self] status, failure in
            guard let self else { return }
            self.inspecting = false
            if self.report == nil && self.inspectFailure == nil {
                self.inspectFailure = failure ?? .failed(code: nil, message: String(localized: "build_app.py ended (exit \(status)) without saying what it found."))
            }
        }
    }

    func build() {
        guard let out else { return }
        step = .build
        outcome = nil
        progress = nil
        reached = 0
        steps = BuildSteps()
        lines = []
        notices = []
        running = true
        cancelling = false
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                      reason: String(localized: "Building a game app"))
        badge(nil)
        // asked once, before the first build, so the build's end can say so when the Builder is in the background
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        start(inputs() + buildOptions(out)) { [weak self] event in
            guard let self else { return }
            self.steps.see(event)
            switch event.type {
            case "progress", "heartbeat":
                self.progress = event
                self.reached = max(self.reached, event.step ?? 0)
                self.badge("\(self.reached)/\(self.steps.count)")
            case "notice": self.notices.append(event)
            case "done":
                let app = URL(fileURLWithPath: event.out ?? out.path)
                self.outcome = .done(app)
                if (event.platform ?? "macos") == "macos" { self.remember(app) }
            case "error": self.outcome = .failed(code: event.code, message: event.message ?? "", log: event.log)
            case "cancelled": self.outcome = .cancelled
            default: break
            }
        } finished: { [weak self] status, failure in
            guard let self else { return }
            self.running = false
            self.cancelling = false
            if let awake = self.awake { ProcessInfo.processInfo.endActivity(awake) }
            self.awake = nil
            defer { self.onBuildEnded?(); self.onBuildEnded = nil }
            if self.outcome == nil {
                self.outcome = failure ?? (status == 130 ? .cancelled : status == 0 ? .done(out)
                    : .failed(code: nil, message: String(localized: "build_app.py ended with exit status \(status).")))
            }
            if self.steps.ended == nil { self.steps.ended = Date().timeIntervalSince1970 }
            self.step = .result
            self.announce()
        }
    }

    /// The Dock icon's badge: the step while building, then ✓ or ! until the Builder is in front again.
    private func badge(_ text: String?) { NSApp.dockTile.badgeLabel = text }

    /// The build's end, on the Dock icon and, when the Builder is in the background, as a notification.
    private func announce() {
        let content = UNMutableNotificationContent()
        switch outcome {
        case .done(let app):
            badge("✓")
            content.title = String(localized: "\(report?.appName ?? app.deletingPathExtension().lastPathComponent) is ready")
            content.body = app.path
        case .failed(let code, _, _):
            badge("!")
            content.title = String(localized: "The build stopped")
            content.body = ErrorText(code: code, games: preflight.games).title
        case .cancelled, nil:
            return badge(nil)
        }
        if NSApp.isActive { return badge(nil) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "build", content: content, trigger: nil))
    }

    /// The Builder is in front: a finished build's badge has been seen.
    func activated() { if !running { badge(nil) } }

    /// Game files opened from Finder or with File > Open: the Game page, as if they were dropped there.
    func open(_ urls: [URL]) {
        guard !running, drop(urls) else { return }
        mode = .build
        if step != .keys { step = .game }
        outcome = nil
        if keys != nil && ready { step = .game }   // without the keys the Keys page asks first; the file is read after
    }

    func cancel() {
        if running { cancelling = true }
        runner?.cancel()
    }

    /// What the script's run sends: its output, line by line, and then how it ended.
    private enum Output: Sendable {
        case line(String, stdout: Bool)
        case ended(Result<Int32, Error>)
    }

    /// Runs the script with `arguments`, ending the run before it: `event` gets its events and `finished` its exit status
    /// (with the failure to show when it ended without saying why), both on the main actor. A newer run, or newBuild(),
    /// cancels this one's task, so nothing of it arrives after that.
    private func start(_ arguments: [String], event: @escaping (BuildEvent) -> Void,
                       finished: @escaping (Int32, Outcome?) -> Void) {
        runner?.cancel()
        job?.cancel()
        guard let python = preflight.python, let script else {
            finished(-1, .failed(code: "toolchain", message: String(localized: "Python 3.14 or the MacNativeGames folder was not found.")))
            return
        }
        let runner = BuildRunner()
        self.runner = runner
        let (output, send) = AsyncStream.makeStream(of: Output.self)
        // its own thread, not a task: a build blocks in waitpid for up to an hour
        Thread.detachNewThread {
            // no __pycache__ beside the scripts: a release's sources are sealed inside this app (make_dmg.sh)
            let ended = Result { try runner.run(python, [script] + arguments, environment: ["PYTHONDONTWRITEBYTECODE": "1"],
                                                stdout: { send.yield(.line($0, stdout: true)) },
                                                stderr: { send.yield(.line($0, stdout: false)) }) }
            send.yield(.ended(ended))   // after every line: run() returns once both pipes are read to the end
            send.finish()
        }
        // One loop on the main actor keeps the lines in the order they were read.
        job = Task {
            var schemaChecked = false
            var rejected = false   // the script writes another event schema: what it sends after that is not read
            for await item in output {
                guard !Task.isCancelled else { break }   // a cancelled stream still hands over what it had buffered
                switch item {
                case .line(let line, let isStdout):
                    if rejected { lines.append(line); continue }
                    guard isStdout, let e = BuildEvent.parse(line) else { lines.append(line); continue }
                    if e.type == "hello" {
                        schemaChecked = true
                        if e.schema != BuildEvent.schema {   // a Builder from another revision of the repository
                            lines.append(e.logText)
                            rejected = true
                            runner.cancel()
                            event(BuildEvent(type: "error", message: String(localized: "This Builder reads event schema \(BuildEvent.schema), but build_app.py writes \(e.schema ?? 0): build the Builder from the same checkout."), code: "build"))
                            continue
                        }
                    }
                    if e.type != "heartbeat" { lines.append(e.logText) }
                    event(e)
                case .ended(let ended):
                    var failure: Outcome?
                    var status: Int32 = -1
                    switch ended {
                    case .success(let code): status = code
                    case .failure(let error):
                        failure = .failed(code: nil, message: String(localized: "build_app.py could not be started: \(error.localizedDescription)"))
                    }
                    if failure == nil && !schemaChecked && status != 130 {
                        failure = .failed(code: "build", message: String(localized: "build_app.py did not send its event header: it may be older than this Builder."))
                    }
                    finished(status, status == 0 ? nil : failure)
                }
            }
        }
    }

    // MARK: library

    var rememberedApps: [String] { UserDefaults.standard.stringArray(forKey: Defaults.built) ?? [] }

    private func remember(_ app: URL) {
        UserDefaults.standard.set([app.path] + rememberedApps.filter { $0 != app.path }, forKey: Defaults.built)
    }

    func forget(_ app: URL) {
        UserDefaults.standard.set(rememberedApps.filter { $0 != app.path }, forKey: Defaults.built)
    }

    /// The wizard filled in with what `app` was built from (its build-info.json), writing over the same app. The keys
    /// are never in it: the remembered location is used, or the Keys page asks.
    func rebuild(_ app: BuiltApp) {
        guard let info = app.info, let gamePath = info.inputs.game else { return }
        let path = { (p: String?) in p.map { URL(fileURLWithPath: $0) } }
        choose(game: URL(fileURLWithPath: gamePath))
        update = path(info.inputs.update)
        dlc = (info.inputs.dlc ?? []).map { URL(fileURLWithPath: $0) }
        mod = path(info.inputs.mod)
        installModRomfs = info.inputs.installModRomfs ?? false
        fonts = path(info.inputs.firmware ?? info.inputs.sharedFonts)
        fontsAreFirmware = info.inputs.sharedFonts == nil
        out = app.url
        outcome = nil
        mode = .build
        step = keys == nil ? .keys : .game
        inspect()
    }

    /// Files the build record names that are not there any more (a moved game file, an unplugged drive).
    func missingInputs(_ info: BuildInfo) -> [String] {
        let i = info.inputs
        return ([i.game, i.update, i.mod, i.firmware, i.sharedFonts].compactMap { $0 } + (i.dlc ?? []))
            .filter { !FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: result

    var fullLog: String { lines.joined(separator: "\n") + "\n" }

    /// The build's own logs (<work>/logs), once there are any.
    var logsFolder: URL? {
        guard let work = report?.work else { return nil }
        let logs = URL(fileURLWithPath: work).appendingPathComponent("logs")
        return FileManager.default.fileExists(atPath: logs.path) ? logs : nil
    }

    /// The free space of the work folder's drive, when it's less than a first build needs (no work folder there yet:
    /// one that is reuses what it holds).
    var spaceShort: (free: Int64, needed: Int)? {
        guard let needed = report?.spaceGb?[platform], let work = report?.work,
              !FileManager.default.fileExists(atPath: work),
              let free = Disk.freeBytes(URL(fileURLWithPath: work)) else { return nil }
        let gb = free / 1_000_000_000
        return gb < Int64(needed) ? (gb, needed) : nil
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullLog, forType: .string)
    }

    func startOver() {
        step = .game
        outcome = nil
    }

    /// After a finished build: the Game page with nothing chosen but the keys and the fonts folder, which another game
    /// can use too.
    func newBuild() {
        guard !running else { return }
        runner?.cancel()   // an inspect still running for the old game
        job?.cancel()      // and its events are stale now
        clearChoices()
        report = nil
        inspectFailure = nil
        inspecting = false
        outcome = nil
        step = .game
    }
}
