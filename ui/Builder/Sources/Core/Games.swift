import Foundation

/// A game the checkout builds from the player's own Switch or Switch 2 dump and prod.keys: games/<name>/game.json
/// (schema 1), which build_app.py reads too. The Builder knows no game by name; everything it says about one comes from
/// this file, from the game's assets, or from --inspect.
struct Game: Decodable, Equatable, Identifiable {
    struct ShaderContribution: Decodable, Equatable {
        var step: Int      // the launcher's reminder comes every `step` new rows (TOTK_CONTRIB_STEP)
        var form: String   // the GitHub issue form for the list (docs/shader-list.md)
    }

    struct Files: Decodable, Equatable {
        var game: [String]
        var update: [String]?
    }

    static let schema = 1

    var schema: Int
    var id: String                 // build_app.py's name for it: build-info.json "game", the inspect event's "game"
    var name: String
    var titleId: String
    var bundleId: String?          // what its app carries, to find it on the Mac
    var dataFolder: String?        // ~/Library/Application Support/MacNativeGames/<dataFolder>
    var dataBesideApp: String?     // or a folder of this name next to the app (Super Mario Odyssey: "Odyssey Data")
    var build: String?             // the script that builds it, relative to the checkout
    var sources: [String]          // what goes into its app: a change there since an app's commit makes it out of date
    var files: Files               // the file extensions it is built from (lowercase, no dot)
    var shaderContribution: ShaderContribution?
    var versions: [String] = []    // the versions it builds: game.json "versions", or each assets/expected-*.json's display_version
    var needs: [String] = []       // what its Mac build needs besides build_app.py's own tools: "xcode" (the full Xcode)
    var installTool: String?       // the script that signs and installs its iPhone / iPad or Vision Pro IPA
    var workHoldsGameData = false  // its app reads the game data from the work folder (Bayonetta 3), so that stays

    private enum CodingKeys: String, CodingKey {
        case schema, id, name, titleId, bundleId, dataFolder, dataBesideApp, build, sources, files, versions, shaderContribution
        case needs, installTool, workHoldsGameData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        titleId = try c.decode(String.self, forKey: .titleId)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        dataFolder = try c.decodeIfPresent(String.self, forKey: .dataFolder)
        dataBesideApp = try c.decodeIfPresent(String.self, forKey: .dataBesideApp)
        build = try c.decodeIfPresent(String.self, forKey: .build)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        files = try c.decodeIfPresent(Files.self, forKey: .files) ?? Files(game: ["xci", "nsp"], update: ["nsp", "nsz"])
        shaderContribution = try c.decodeIfPresent(ShaderContribution.self, forKey: .shaderContribution)
        versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        needs = try c.decodeIfPresent([String].self, forKey: .needs) ?? []
        installTool = try c.decodeIfPresent(String.self, forKey: .installTool)
        workHoldsGameData = try c.decodeIfPresent(Bool.self, forKey: .workHoldsGameData) ?? false
    }

    /// The checkout has its build script (game.json "build").
    var builds: Bool { build != nil }

    /// The games of a checkout, by name; a game.json of another schema, or one that doesn't parse, is left out.
    static func load(repo: URL?, fileManager: FileManager = .default) -> [Game] {
        guard let repo else { return [] }
        let folders = (try? fileManager.contentsOfDirectory(atPath: repo.appendingPathComponent("games").path)) ?? []
        return folders.sorted().compactMap { folder -> Game? in
            let dir = repo.appendingPathComponent("games/\(folder)")
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("game.json")),
                  var game = try? JSONDecoder.snakeCase.decode(Game.self, from: data), game.schema == schema else { return nil }
            if game.versions.isEmpty { game.versions = versions(dir.appendingPathComponent("assets"), fileManager) }
            return game
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func versions(_ assets: URL, _ fileManager: FileManager) -> [String] {
        let files = ((try? fileManager.contentsOfDirectory(atPath: assets.path)) ?? [])
            .filter { $0.hasPrefix("expected-") && $0.hasSuffix(".json") }
        let found = files.compactMap { file -> String? in
            guard let data = try? Data(contentsOf: assets.appendingPathComponent(file)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["display_version"] as? String
        }
        return Array(Set(found)).sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
}

extension Array where Element == Game {
    func named(_ id: String?) -> Game? { first { $0.id == id } }

    /// The games a file of this extension can be the base game of.
    func accepting(_ file: URL) -> [Game] {
        let ext = file.pathExtension.lowercased()
        return filter { $0.builds && $0.files.game.contains(ext) }
    }

    /// The script to run for a game file: the one build of the games that take its extension, or build_app.py, the
    /// repository's entry point, which hands a game with its own script over to it (build_app.hand_off).
    func script(for file: URL) -> String {
        let builds = Set(accepting(file).compactMap(\.build))
        return builds.count == 1 ? builds.first! : "build_app.py"
    }

    var gameExtensions: [String] { [String](Set(filter(\.builds).flatMap(\.files.game))).sorted() }
    var updateExtensions: [String] { [String](Set(filter(\.builds).flatMap { $0.files.update ?? [] })).sorted() }

    /// Where the app of the game `id` keeps its saves, settings and shader cache, as the player reads it.
    func dataLocation(_ id: String?) -> String {
        let game = named(id)
        if let beside = game?.dataBesideApp { return String(localized: "“\(beside)” next to the app") }
        return "~/Library/Application Support/MacNativeGames" + (game?.dataFolder.map { "/" + $0 } ?? "")
    }

    /// Where files dropped on the Game page go. `game` is the game file chosen so far and `identified` the game
    /// --inspect named in it (nil while it hasn't); `takesMod` says whether that game takes a mod; `isMod` tells a mod
    /// folder (exefs/ or romfs/ in it) from a fonts one. A `.keys` file is the player's keys (`make KEYS=…` hands them over
    /// this way), except title.keys, which no build takes.
    func route(_ urls: [URL], game: URL?, identified: String?, takesMod: Bool,
               isFolder: (URL) -> Bool, isMod: (URL) -> Bool, size: (URL) -> Int64) -> Dropped {
        var dropped = Dropped()
        dropped.keys = urls.first { !isFolder($0) && $0.pathExtension.lowercased() == "keys"
            && $0.lastPathComponent.lowercased() != "title.keys" }
        let known = Set(gameExtensions + updateExtensions)
        let files = urls.filter { !isFolder($0) && known.contains($0.pathExtension.lowercased()) }
        if files.count > 1 {
            // a base game and its update together: an extension only a game file has decides, or else the larger file
            let gameOnly = Set(gameExtensions).subtracting(updateExtensions)
            let ordered = files.sorted { size($0) > size($1) }
            let base = ordered.first { gameOnly.contains($0.pathExtension.lowercased()) } ?? ordered[0]
            dropped.game = base
            dropped.update = ordered.first { $0 != base }
        } else if let file = files.first {
            let updates = named(identified)?.files.update ?? []
            if game != nil, updates.contains(file.pathExtension.lowercased()) { dropped.update = file } else { dropped.game = file }
        }
        for folder in urls.filter(isFolder) where game != nil || !files.isEmpty {
            if isMod(folder) {
                // a mod dropped with a new game file is kept for it: that game's --inspect says whether it takes one
                if takesMod || dropped.game != nil, dropped.mod == nil { dropped.mod = folder }
            } else if dropped.fonts == nil {
                dropped.fonts = folder   // a folder is never a game file: it's the firmware or the extracted fonts
            }
        }
        return dropped
    }
}

/// What a drop on the Game page sets (Array<Game>.route); nil leaves that choice as it is.
struct Dropped: Equatable {
    var keys: URL?
    var game: URL?
    var update: URL?
    var fonts: URL?
    var mod: URL?
}
