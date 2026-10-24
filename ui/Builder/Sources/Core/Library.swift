import Foundation

/// Contents/Resources/build-info.json, which build_app.py writes into every Mac app it builds (build_info, schema 1).
struct BuildInfo: Decodable, Equatable {
    struct Inputs: Decodable, Equatable {
        var game: String?
        var update: String?
        var dlc: [String]?
        var mod: String?
        var installModRomfs: Bool?
        var firmware: String?
        var sharedFonts: String?
    }

    static let schema = 1

    var schema: Int
    var game: String
    var appName: String
    var version: String
    var displayVersion: String
    var platform: String
    var built: String
    var commit: String?
    var dirty: Bool?
    var inputs: Inputs

    static func read(_ app: URL) -> BuildInfo? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/build-info.json")),
              let info = try? decoder.decode(BuildInfo.self, from: data), info.schema == schema else { return nil }
        return info
    }

    var builtDate: Date? { ISO8601DateFormatter().date(from: built) }
}

/// One built game app, found by its bundle identifier or because this Builder built it.
struct BuiltApp: Identifiable, Equatable {
    /// build_app.py APPS: the identifiers its apps carry.
    static let bundleIDs = ["org.macnativegames.totk", "org.macnativegames.botw"]

    var url: URL
    var name: String
    var version: String
    var info: BuildInfo?
    var id: String { url.path }

    init?(_ url: URL) {
        guard let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let bundleID = plist["CFBundleIdentifier"] as? String, Self.bundleIDs.contains(bundleID) else { return nil }
        self.url = url
        name = plist["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        version = plist["CFBundleShortVersionString"] as? String ?? ""
        info = BuildInfo.read(url)
    }

    /// Spotlight's list of the game apps, plus the ones this Builder made (Spotlight may not index every volume). The
    /// folders build_app.py replaces or is still writing (".partial", ".replaced-<pid>") are not apps.
    static func find(remembered: [String]) -> [BuiltApp] {
        let query = bundleIDs.map { "kMDItemCFBundleIdentifier == '\($0)'" }.joined(separator: " || ")
        let spotlight = Shell.run("/usr/bin/mdfind", [query]).output.split(separator: "\n").map(String.init)
        var seen = Set<String>()
        return (remembered + spotlight)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { $0.pathExtension == "app" && seen.insert($0.path).inserted }
            .compactMap(BuiltApp.init)
            .sorted { ($0.info?.built ?? "") > ($1.info?.built ?? "") }
    }
}

/// Whether the checkout has changed what an app was built from: build_app.py and the game folders it builds from.
enum Freshness: Equatable {
    case current        // built from this commit, or nothing that goes into the app changed since
    case changed        // a newer checkout builds a different app
    case unknown        // no build record, no commit in it, or a commit this checkout does not have

    static let paths = ["build_app.py", "games/totk", "games/botw"]

    static func of(_ info: BuildInfo?, repo: URL?) -> Freshness {
        guard let commit = info?.commit, let repo else { return .unknown }
        let r = Shell.run("/usr/bin/git", ["-C", repo.path, "diff", "--quiet", commit, "HEAD", "--"] + paths)
        switch r.status {
        case 0: return .current
        case 1: return .changed
        default: return .unknown   // 128: the commit is not in this checkout
        }
    }
}

/// The shader list contribution file a game keeps in its data folder, and its reminder state (<file>.reminded), read and
/// written the way the game's launcher does (third_party/d2r_gfx/gfx/nvn/totk_shader_contrib.h), so both agree.
struct Contribution: Equatable {
    var game: String           // build_app.py's name: totk, botw
    var file: URL
    var rows: Int
    var remindedAt: Int?       // rows at the last reminder (or send); nil before the first
    var never: Bool            // "Don't remind me again"

    /// games/totk/runtime/game_version.h: GAME_FOLDER and TOTK_CONTRIB_STEP; the issue forms in docs/shader-list.md.
    static let games: [(game: String, folder: String, step: Int, form: String)] = [
        ("totk", "TOTK", 100, "https://github.com/ly05010419/MacNativeGames/issues/new?template=shader-list.yml"),
        ("botw", "BotW", 500, "https://github.com/ly05010419/MacNativeGames/issues/new?template=shader-list-botw.yml"),
    ]

    static func data(_ folder: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacNativeGames/\(folder)")
    }

    static func all(base: (String) -> URL = data) -> [Contribution] {
        games.compactMap { read(game: $0.game, file: base($0.folder).appendingPathComponent("shader-list-contribution.txt")) }
    }

    static func read(game: String, file: URL) -> Contribution? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let rows = Set(text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("V\t") || $0.hasPrefix("R\t") || $0.hasPrefix("B\t") }).count
        let reminded = (try? String(contentsOf: remindedFile(file), encoding: .utf8)) ?? ""
        return Contribution(game: game, file: file, rows: rows,
                            remindedAt: Int(reminded.trimmingCharacters(in: .whitespacesAndNewlines)),
                            never: reminded.hasPrefix("never"))
    }

    static func remindedFile(_ file: URL) -> URL { URL(fileURLWithPath: file.path + ".reminded") }

    var form: URL { URL(string: Self.games.first { $0.game == game }!.form)! }
    var step: Int { Self.games.first { $0.game == game }!.step }
    /// New rows since the last reminder or send: what sending now would add for the first time.
    var unsent: Int { max(0, rows - (remindedAt ?? 0)) }

    /// After sending: the launcher's next reminder comes `step` rows later, as after its own "Send".
    func markSent() throws { try "\(rows)\n".write(to: Self.remindedFile(file), atomically: true, encoding: .utf8) }
    func stopReminders() throws { try "never\n".write(to: Self.remindedFile(file), atomically: true, encoding: .utf8) }
    func resumeReminders() throws { try markSent() }
}

/// A short command's exit status and output (git, mdfind); never for build_app.py, which BuildRunner runs.
enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
