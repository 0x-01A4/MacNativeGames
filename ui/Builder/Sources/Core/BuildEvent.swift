import Foundation

/// One line of `build_app.py --json-progress` (schema 2, ui/README.md); a game's own build script (game.json "build")
/// writes the same. The fields a type does not carry are nil.
struct BuildEvent: Decodable, Equatable {
    static let schema = 2

    var type: String
    var time: Double?
    // hello
    var schema: Int?
    // progress, heartbeat
    var stage: String?
    var step: Int?
    var of: Int?
    var message: String?
    // error, notice
    var code: String?
    var log: String?
    // done
    var out: String?
    var game: String?
    var version: String?
    var platform: String?
    // inspect
    var appName: String?
    var displayVersion: String?
    var kind: String?
    var needsFonts: Bool?
    var needsUpdate: Bool?             // the base game alone isn't enough: the build needs its update too
    var platforms: [String]?
    var dlc: Bool?
    var dlcMax: Int?                   // how many add-on packs the version takes (nil from a script before this field)
    var mod: Bool?                     // the game takes --mod
    var spaceGb: [String: Int]?        // what a first build needs free, per platform
    var work: String?
    var defaultOut: String?

    /// The event on a line of the script's stdout, or nil for anything else (it then belongs to the log as text).
    static func parse(_ line: String) -> BuildEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder.snakeCase.decode(BuildEvent.self, from: data)
    }

    /// How the event reads in the full log a player copies for a bug report.
    var logText: String {
        switch type {
        case "progress", "heartbeat":
            return (step ?? 0) > 0 ? "\(step!)/\(of ?? 4) \(stage ?? ""): \(message ?? "")" : (message ?? "")
        case "error": return "ERROR (\(code ?? "build")): \(message ?? "")"
        case "notice": return "NOTE (\(code ?? "")): \(message ?? "")"
        case "done": return "done: \(out ?? "")"
        case "cancelled": return "cancelled"
        case "inspect": return "found: \(appName ?? game ?? "?") \(displayVersion ?? version ?? "") (\(kind ?? ""))"
        case "hello": return "build_app.py event schema \(schema ?? 0)"
        default: return message ?? type
        }
    }
}

extension JSONDecoder {
    /// What the build scripts write: build_app.py events, game.json and build-info.json all use snake_case keys.
    static let snakeCase: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// A build's steps as its script numbers them ("1/4 code" ... "4/4 app"): how many there are and what each is, learnt
/// from its progress events, since every game's build script has its own. Before the first event, build_app.py's four.
struct BuildSteps: Equatable {
    static let usual = ["code", "data", "shaders", "app"]

    var count = 4
    var names: [Int: String] = [:]
    var started: [Int: Double] = [:]   // when each step's first event came (Unix seconds; step 0: prepare)
    var ended: Double?                 // the build's done, error or cancelled event

    mutating func see(_ event: BuildEvent) {
        if ["done", "error", "cancelled"].contains(event.type) { ended = event.time ?? ended }
        guard event.type == "progress" || event.type == "heartbeat" || event.type == "notice" else { return }
        if let of = event.of, of > 0 { count = of }
        if let step = event.step, step > 0, let stage = event.stage { names[step] = stage }
        if let step = event.step, let time = event.time, started[step] == nil { started[step] = time }
    }

    /// How long the step took, or has taken until `now`: to the next step's start, or the build's end.
    func duration(_ step: Int, now: Double) -> Double? {
        guard let start = started[step] else { return nil }
        let end = started.filter { $0.key > step }.map(\.value).min() ?? ended ?? now
        return max(0, end - start)
    }

    /// The whole build so far, from its first step event.
    func elapsed(now: Double) -> Double? {
        started.values.min().map { max(0, (ended ?? now) - $0) }
    }

    /// 0:42, 12:03 or 1:02:03.
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The step's stage name: the one its events gave, or build_app.py's while a build of four hasn't reached it.
    func name(_ step: Int) -> String? {
        names[step] ?? (count == Self.usual.count && step >= 1 && step <= count ? Self.usual[step - 1] : nil)
    }

    func title(_ step: Int) -> String {
        switch name(step) {
        case "check": String(localized: "Check the game file")
        case "code": String(localized: "Rewrite the game code")
        case "data", "update": String(localized: "Extract and verify the game data")   // "update": the data step of an update
        case "fonts": String(localized: "Extract the system fonts")
        case "tables": String(localized: "Verify and bind the game to the runtime")
        case "runtime": String(localized: "Compile the runtime")
        case "shaders": String(localized: "Prepare the shaders")
        case "app": String(localized: "Build and check the app")
        case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: String(localized: "Step \(step)")
        }
    }
}
