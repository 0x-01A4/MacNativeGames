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
    var work: String?   // the work folder (nil in a record from before this field)
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

/// One built game app, found by its bundle identifier (a game.json's bundle_id) or because this Builder built it.
struct BuiltApp: Identifiable, Equatable {
    var url: URL
    var name: String
    var version: String
    var game: String          // the game's id (game.json)
    var info: BuildInfo?
    var id: String { url.path }

    init?(_ url: URL, games: [Game]) {
        guard let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let game = games.first(where: { $0.bundleId == bundleID }) else { return nil }
        self.url = url
        self.game = game.id
        name = plist["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        version = plist["CFBundleShortVersionString"] as? String ?? ""
        info = BuildInfo.read(url)
    }

    /// Spotlight's list of the game apps, plus the ones this Builder made (Spotlight may not index every volume). The
    /// folders build_app.py replaces or is still writing (".partial", ".replaced-<pid>") are not apps.
    static func find(remembered: [String], games: [Game]) -> [BuiltApp] {
        guard !games.isEmpty else { return [] }
        let query = games.compactMap(\.bundleId).map { "kMDItemCFBundleIdentifier == '\($0)'" }.joined(separator: " || ")
        let spotlight = Shell.run("/usr/bin/mdfind", [query]).output.split(separator: "\n").map(String.init)
        var seen = Set<String>()
        return (remembered + spotlight)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { $0.pathExtension == "app" && seen.insert($0.path).inserted }
            .compactMap { BuiltApp($0, games: games) }
            .sorted { ($0.info?.built ?? "") > ($1.info?.built ?? "") }
    }
}

/// A build's work folder (build-info.json "work", or the one --inspect named): what it holds on the disk, and why it
/// has to stay, when it does. Deleting it only makes the next build start from the beginning.
struct WorkFolder: Identifiable, Equatable {
    var url: URL
    var game: String
    var keep: String?   // why it can't be deleted
    var id: String { url.path }

    static func all(apps: [BuiltApp], current: (work: String, game: String?)?, games: [Game],
                    fileManager: FileManager = .default) -> [WorkFolder] {
        var seen = Set<String>()
        let found: [(String, String?)] = apps.compactMap { app in app.info?.work.map { ($0, app.game) } }
            + [current].compactMap { $0.map { ($0.work, $0.game) } }
        return found.compactMap { path, game -> WorkFolder? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var folder: ObjCBool = false
            guard seen.insert(url.path).inserted, fileManager.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue
            else { return nil }
            let known = games.named(game)
            var keep: String?
            if known?.workHoldsGameData == true {
                keep = String(localized: "\(known?.name ?? "The game")'s app reads its game data from it.")
            } else if let inside = apps.first(where: { $0.url.standardizedFileURL.path.hasPrefix(url.path + "/") }) {
                keep = String(localized: "\(inside.name) is inside it.")
            }
            return WorkFolder(url: url, game: game ?? "", keep: keep)
        }
    }

    /// The bytes its files take on the disk (a clone shares them with the app, so this is at most what deleting frees).
    static func size(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Room on the disk before a build: build_app.py checks it too, once it has identified the game; this only warns early.
enum Disk {
    /// The folder itself, or the nearest one above it that exists (an output or work folder the build will make).
    static func existing(_ url: URL) -> URL {
        var dir = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: dir.path) && dir.path != "/" { dir.deleteLastPathComponent() }
        return dir
    }

    static func freeBytes(_ url: URL) -> Int64? {
        (try? existing(url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// The build can make `url`: the nearest folder that exists is writable.
    static func canWrite(_ url: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: existing(url.deletingLastPathComponent()).path)
    }
}

/// Whether the checkout has changed what an app was built from: its game's sources (game.json), e.g. build_app.py and
/// the game folders it builds from.
enum Freshness: Equatable {
    case current        // built from this commit, or nothing that goes into the app changed since
    case changed        // the checkout as it is now (local changes too) builds a different app
    case unknown        // no build record, no commit in it, built with local changes, a game this checkout doesn't
                        // have, or a commit it lacks

    static func of(_ info: BuildInfo?, repo: URL?, games: [Game]) -> Freshness {
        guard let commit = info?.commit, info?.dirty != true,   // what the local changes were is not recorded
              let repo, let paths = games.named(info?.game)?.sources, !paths.isEmpty else { return .unknown }
        // against the working tree, not HEAD: an edit not committed yet changes the next build too
        let r = Shell.run("/usr/bin/git", ["-C", repo.path, "diff", "--quiet", commit, "--"] + paths)
        switch r.status {
        case 0: return .current
        case 1: return .changed
        default: return .unknown   // 128: the commit is not in this checkout
        }
    }
}

/// The shader list contribution file a game keeps in its data folder, and its reminder state (<file>.reminded), read and
/// written the way the game's launcher does (third_party/d2r_gfx/gfx/nvn/totk_shader_contrib.h), so both agree. Only the
/// games whose game.json has a shader_contribution keep one.
struct Contribution: Equatable {
    var game: Game
    var file: URL
    var rows: Int
    var remindedAt: Int?       // rows at the last reminder (or send); nil before the first
    var never: Bool            // "Don't remind me again"

    static func data(_ folder: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacNativeGames/\(folder)")
    }

    static func all(games: [Game], base: (String) -> URL = data) -> [Contribution] {
        games.compactMap { game in
            game.dataFolder.flatMap { read(game: game, file: base($0).appendingPathComponent("shader-list-contribution.txt")) }
        }
    }

    static func read(game: Game, file: URL) -> Contribution? {
        guard game.shaderContribution != nil else { return nil }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let rows = Set(text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("V\t") || $0.hasPrefix("R\t") || $0.hasPrefix("B\t") }).count
        let reminded = (try? String(contentsOf: remindedFile(file), encoding: .utf8)) ?? ""
        return Contribution(game: game, file: file, rows: rows,
                            remindedAt: Int(reminded.trimmingCharacters(in: .whitespacesAndNewlines)),
                            never: reminded.hasPrefix("never"))
    }

    static func remindedFile(_ file: URL) -> URL { URL(fileURLWithPath: file.path + ".reminded") }

    var form: URL { URL(string: game.shaderContribution!.form)! }
    var step: Int { game.shaderContribution!.step }
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

    /// `text` as one word for zsh or sh, for a command the player pastes into Terminal.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
