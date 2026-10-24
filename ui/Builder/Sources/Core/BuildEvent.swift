import Foundation

/// One line of `build_app.py --json-progress` (schema 1, ui/README.md). The fields a type does not carry are nil.
struct BuildEvent: Decodable, Equatable {
    static let schema = 1

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
    var platforms: [String]?
    var dlc: Bool?
    var work: String?
    var defaultOut: String?

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// The event on a line of the script's stdout, or nil for anything else (it then belongs to the log as text).
    static func parse(_ line: String) -> BuildEvent? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(BuildEvent.self, from: data)
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

/// The build's four steps, as build_app.py numbers them ("1/4 code" ... "4/4 app"); "update" is the data step of an update.
enum BuildStage: Int, CaseIterable {
    case code = 1, data, shaders, app

    init?(event: BuildEvent) {
        guard let step = event.step, let stage = BuildStage(rawValue: step) else { return nil }
        self = stage
    }

    var title: String {
        switch self {
        case .code: String(localized: "Rewrite the game code")
        case .data: String(localized: "Extract and verify the game data")
        case .shaders: String(localized: "Prepare the startup shaders")
        case .app: String(localized: "Build and check the app")
        }
    }
}
