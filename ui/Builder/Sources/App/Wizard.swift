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
        case failed(code: String?, message: String)
        case cancelled
    }

    private enum Defaults {
        static let repo = "repoPath"
        static let keys = "keysPath"   // only the location, and only when the player asks; never the keys themselves
    }

    @Published var step = Step.keys
    @Published var preflight: Preflight
    @Published var keys: URL?
    @Published var rememberKeys: Bool
    @Published var game: URL?
    @Published var update: URL?
    @Published var fonts: URL?
    @Published var fontsAreFirmware = true
    @Published var report: BuildEvent?
    @Published var inspectFailure: Outcome?
    @Published var inspecting = false
    @Published var out: URL?
    @Published var platform = "macos" { didSet { if platform != oldValue { matchOutToPlatform() } } }
    @Published var dlc: [URL] = []      // Breath of the Wild 1.9.0: up to the two add-on content packs
    @Published var mod: URL?             // Tears of the Kingdom: a mod folder with exefs/ and/or romfs/ (docs/mods.md)
    @Published var installModRomfs = false
    @Published var shaderReminder = true
    @Published var notices: [BuildEvent] = []   // inputs accepted by another rule than the exact reference hash
    @Published var running = false
    @Published var progress: BuildEvent?
    @Published var reached = 0          // the highest of build_app.py's steps (1-4) this build has reached
    @Published var outcome: Outcome?
    @Published var lines: [String] = []

    private var runner: BuildRunner?
    private var generation = 0   // a newer --inspect or build makes the events of an older one stale
    private var schemaChecked = false
    private var rejected = false   // the script writes another event schema: what it sends after that is not read

    init() {
        let defaults = UserDefaults.standard
        preflight = Preflight.check(repo: Preflight.findRepo(chosen: defaults.string(forKey: Defaults.repo)))
        let saved = defaults.string(forKey: Defaults.keys)
        rememberKeys = saved != nil
        if let saved, FileManager.default.fileExists(atPath: saved) { keys = URL(fileURLWithPath: saved) }
    }

    // MARK: setup

    func recheck() {
        preflight = Preflight.check(repo: preflight.repo ?? Preflight.findRepo(chosen: nil))
    }

    func chooseRepo(_ url: URL) {
        guard Preflight.isRepo(url) else { return }
        UserDefaults.standard.set(url.path, forKey: Defaults.repo)
        preflight = Preflight.check(repo: url)
    }

    func setKeys(_ url: URL) {
        keys = url
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

    func setGame(_ url: URL) {
        game = url
        update = nil
        dlc = []
        mod = nil
        installModRomfs = false
        out = nil
        platform = "macos"
        inspect()
    }

    func addDLC(_ url: URL) {
        guard !dlc.contains(url), dlc.count < 2 else { return }
        dlc.append(url)
        inspect()   // the packs are checked against the version before the build (build_app.py check_dlc)
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

    /// The platforms the found game builds for (inspect); iPhone/iPad also needs an Xcode on this Mac.
    var platforms: [String] { report?.platforms ?? ["macos"] }

    /// .app for the Mac, .ipa for iPhone/iPad, in the same folder and with the same name.
    private func matchOutToPlatform() {
        guard let current = out ?? report?.defaultOut.map({ URL(fileURLWithPath: $0) }) else { return }
        out = current.deletingPathExtension().appendingPathExtension(platform == "ios" ? "ipa" : "app")
        if platform == "ios" { installModRomfs = false }
    }

    func setUpdate(_ url: URL?) {
        update = url
        inspect()
    }

    var fontsSatisfied: Bool { report?.needsFonts != true || fonts != nil }

    var canContinue: Bool {
        switch step {
        case .keys: ready && keys != nil
        case .game: report != nil && !inspecting && fontsSatisfied
        case .target: out != nil && (platform != "ios" || preflight.iosMissing.isEmpty)
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
        if platform == "ios" && !shaderReminder { args.append("--no-shader-reminder") }
        return args
    }

    /// build_app.py, or a stand-in for trying the Builder without game files (BUILDER_SCRIPT, ui/README.md).
    private var script: String? {
        ProcessInfo.processInfo.environment["BUILDER_SCRIPT"] ?? preflight.repo?.appendingPathComponent("build_app.py").path
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
                if !(event.platforms ?? ["macos"]).contains(self.platform) { self.platform = "macos" }
                if self.out == nil, let path = event.defaultOut {
                    let url = URL(fileURLWithPath: path)
                    self.out = self.platform == "ios" ? url.deletingPathExtension().appendingPathExtension("ipa") : url
                }
            case "error": self.inspectFailure = .failed(code: event.code, message: event.message ?? "")
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
        lines = []
        notices = []
        running = true
        start(inputs() + buildOptions(out)) { [weak self] event in
            guard let self else { return }
            switch event.type {
            case "progress", "heartbeat":
                self.progress = event
                self.reached = max(self.reached, event.step ?? 0)
            case "notice": self.notices.append(event)
            case "done": self.outcome = .done(URL(fileURLWithPath: event.out ?? out.path))
            case "error": self.outcome = .failed(code: event.code, message: event.message ?? "")
            case "cancelled": self.outcome = .cancelled
            default: break
            }
        } finished: { [weak self] status, failure in
            guard let self else { return }
            self.running = false
            if self.outcome == nil {
                self.outcome = failure ?? (status == 130 ? .cancelled : status == 0 ? .done(out)
                    : .failed(code: nil, message: String(localized: "build_app.py ended with exit status \(status).")))
            }
            self.step = .result
        }
    }

    func cancel() { runner?.cancel() }

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
}
