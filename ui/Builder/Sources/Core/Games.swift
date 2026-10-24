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

    private enum CodingKeys: String, CodingKey {
        case schema, id, name, titleId, bundleId, dataFolder, dataBesideApp, build, sources, files, versions, shaderContribution
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
    }

    /// The checkout has its build script (game.json "build").
    var builds: Bool { build != nil }

    /// The games of a checkout, by name; a game.json of another schema, or one that doesn't parse, is left out.
    static func load(repo: URL?, fileManager: FileManager = .default) -> [Game] {
        guard let repo else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let folders = (try? fileManager.contentsOfDirectory(atPath: repo.appendingPathComponent("games").path)) ?? []
        return folders.sorted().compactMap { folder -> Game? in
            let dir = repo.appendingPathComponent("games/\(folder)")
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("game.json")),
                  var game = try? decoder.decode(Game.self, from: data), game.schema == schema else { return nil }
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
}
