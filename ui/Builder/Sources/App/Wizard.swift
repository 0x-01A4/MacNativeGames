import AppKit
import Foundation

/// The Builder's state: the files the player picked, what --inspect found, and the running build. Every build step is
/// build_app.py's; this only collects its arguments and reads its events.
@MainActor
final class Wizard: ObservableObject {
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
    @Published var mode = Mode.build

    @Published var step = Step.keys
    @Published var preflight: Preflight
    @Published var keys: URL?
    @Published var rememberKeys: Bool
    @Published var keysMoved: String?   // the remembered prod.keys location, when nothing is there any more
    @Published var game: URL?
    @Published var update: URL?
    @Published var fonts: URL?
    @Published var fontsAreFirmware = true
    @Published var report: BuildEvent?
    // what the last --inspect of this game file said, kept while a re-inspect runs (report is nil then)
    @Published var identified: String?   // the game's id
    @Published var fontsNeeded: Bool?
    @Published var inspectFailure: Outcome?
    @Published var inspecting = false
    @Published var out: URL?
    @Published var platform = "macos" { didSet { if platform != oldValue { matchOutToPlatform() } } }
    @Published var dlc: [URL] = []      // when inspect says the game takes them: up to two add-on content packs
    @Published var mod: URL?             // when inspect says the game takes one: a folder with exefs/ and/or romfs/ (docs/mods.md)
    @Published var installModRomfs = false
    @Published var shaderReminder = true
    @Published var notices: [BuildEvent] = []   // inputs accepted by another rule than the exact reference hash
    @Published var running = false
    @Published var cancelling = false   // Cancel was pressed and the build hasn't ended yet
    @Published var progress: BuildEvent?
    @Published var reached = 0          // the highest of the build's steps (1-n) it has reached
    @Published var steps = BuildSteps()
    @Published var outcome: Outcome?
    @Published var lines: [String] = []

    private var runner: BuildRunner?
    private var generation = 0   // a newer --inspect or build makes the events of an older one stale
    private var schemaChecked = false
    private var rejected = false   // the script writes another event schema: what it sends after that is not read
    private var awake: NSObjectProtocol?   // keeps the Mac from idle sleep while a build runs
    /// Called once when the running build has ended (the app delegate waits on it to quit).
    var onBuildEnded: (() -> Void)?

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
        game = url
        identified = nil
        fontsNeeded = nil
        update = nil
        dlc = []
        mod = nil
        installModRomfs = false
        out = nil
        platform = "macos"
    }

    /// Files and folders dropped on the Game page (Array<Game>.route), read again in one --inspect.
    func drop(_ urls: [URL]) -> Bool {
        guard !inspecting else { return false }
        let d = preflight.games.route(urls, game: game, identified: identified, takesMod: report?.mod == true,
                                      isFolder: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true },
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
        ["exefs", "romfs"].contains { name in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &folder) && folder.boolValue
        }
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

    var modHasRomfs: Bool {
        guard let mod else { return false }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: mod.appendingPathComponent("romfs").path, isDirectory: &folder) && folder.boolValue
    }

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
        case .target: out != nil && (!isDevice || preflight.iosMissing.isEmpty) && gameMissing.isEmpty
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
        start(inputs() + buildOptions(out)) { [weak self] event in
            guard let self else { return }
            switch event.type {
            case "progress", "heartbeat":
                self.progress = event
                self.reached = max(self.reached, event.step ?? 0)
                self.steps.see(event)
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
            self.step = .result
        }
    }

    func cancel() {
        if running { cancelling = true }
        runner?.cancel()
    }

    private func start(_ arguments: [String], event: @escaping (BuildEvent) -> Void,
                       finished: @escaping (Int32, Outcome?) -> Void) {
        runner?.cancel()
        guard let python = preflight.python, let script else {
            finished(-1, .failed(code: "toolchain", message: String(localized: "Python 3.14 or the MacNativeGames folder was not found.")))
            return
        }
        generation += 1
        let mine = generation
        let runner = BuildRunner()
        self.runner = runner
        schemaChecked = false
        rejected = false
        // The main queue keeps the lines in the order they were read; the result comes after the last of them.
        let deliver: @Sendable (String, Bool) -> Void = { line, isStdout in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == mine else { return }
                if self.rejected { return self.lines.append(line) }
                guard isStdout, let e = BuildEvent.parse(line) else { return self.lines.append(line) }
                if e.type == "hello" {
                    self.schemaChecked = true
                    if e.schema != BuildEvent.schema {   // a Builder from another revision of the repository
                        self.lines.append(e.logText)
                        self.rejected = true
                        runner.cancel()
                        return event(BuildEvent(type: "error", message: String(localized: "This Builder reads event schema \(BuildEvent.schema), but build_app.py writes \(e.schema ?? 0): build the Builder from the same checkout."), code: "build"))
                    }
                }
                if e.type != "heartbeat" { self.lines.append(e.logText) }
                event(e)
            } }
        }
        Thread.detachNewThread {
            var failure: Outcome?
            var status: Int32 = -1
            do {
                status = try runner.run(python, [script] + arguments, stdout: { deliver($0, true) }, stderr: { deliver($0, false) })
            } catch {
                failure = .failed(code: nil, message: String(localized: "build_app.py could not be started: \(error.localizedDescription)"))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == mine else { return }
                if failure == nil && !self.schemaChecked && status != 130 {
                    failure = .failed(code: "build", message: String(localized: "build_app.py did not send its event header: it may be older than this Builder."))
                }
                finished(status, status == 0 ? nil : failure)
            } }
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
        game = URL(fileURLWithPath: gamePath)
        identified = nil
        fontsNeeded = nil
        update = path(info.inputs.update)
        dlc = (info.inputs.dlc ?? []).map { URL(fileURLWithPath: $0) }
        mod = path(info.inputs.mod)
        installModRomfs = info.inputs.installModRomfs ?? false
        fonts = path(info.inputs.firmware ?? info.inputs.sharedFonts)
        fontsAreFirmware = info.inputs.sharedFonts == nil
        platform = "macos"
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
        generation += 1    // and its events are stale now
        game = nil
        update = nil
        dlc = []
        mod = nil
        installModRomfs = false
        report = nil
        identified = nil
        fontsNeeded = nil
        inspectFailure = nil
        inspecting = false
        out = nil
        platform = "macos"
        outcome = nil
        step = .game
    }
}
