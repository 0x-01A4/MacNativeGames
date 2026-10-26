import Foundation

/// What the Mac needs before build_app.py can run, checked the way its prerequisites() checks it. build_app.py stays the
/// authority: a "toolchain" error from it is shown too; this only lets the first screen say what to install.
struct Preflight {
    struct Missing: Equatable {
        var what: String
        var command: String
    }

    /// The same folders build_app.py searches (TOOL_PATHS), and the same Python versions.
    static let toolPaths = ["/opt/homebrew/bin", "/usr/local/bin"]

    var python: String?
    var repo: URL?
    var release: Release?            // the repo is the sources a Builder release carries, not a git checkout
    var games: [Game] = []           // the checkout's games/*/game.json
    var missing: [Missing] = []
    var iosMissing: [Missing] = []   // only for an iPhone/iPad build (build_app.py ios_prerequisites)
    var xcodeMissing: [Missing] = [] // only for a game whose game.json "needs" the full Xcode

    static func check(repo: URL?, fileManager: FileManager = .default) -> Preflight {
        var p = Preflight()
        p.repo = repo
        p.release = Release.read(repo)
        p.games = Game.load(repo: repo, fileManager: fileManager)
        p.python = toolPaths.flatMap { dir in ["python3.14", "python3.15"].map { "\(dir)/\($0)" } }
            .first { fileManager.isExecutableFile(atPath: $0) }
        if !fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/clang")
            && !fileManager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer") {
            p.missing.append(Missing(what: String(localized: "Xcode command line tools"), command: "xcode-select --install"))
        }
        let brew = ["python@3.14": p.python != nil,
                    "opus": fileManager.fileExists(atPath: "/opt/homebrew/opt/opus/lib"),
                    "libvpx": fileManager.fileExists(atPath: "/opt/homebrew/opt/libvpx/lib")]
        let packages = ["python@3.14", "opus", "libvpx"].filter { !brew[$0]! }
        if !packages.isEmpty {
            p.missing.append(Missing(what: String(localized: "Homebrew packages: \(packages.joined(separator: ", "))"),
                                     command: "brew install \(packages.joined(separator: " "))"))
        }
        p.iosMissing = iosCheck(fileManager)
        if !developerDirs(fileManager).contains(where: { fileManager.fileExists(atPath: "\($0)/usr/bin/xcodebuild") }) {
            p.xcodeMissing = [xcode]
        }
        return p
    }

    static let xcode = Missing(what: String(localized: "Xcode 26 or later (the command line tools are not enough)"),
                               command: "open 'macappstore://apps.apple.com/app/xcode/id497799835'")

    /// The Xcodes on this Mac: DEVELOPER_DIR, the selected developer folder, and every /Applications/Xcode*.app.
    static func developerDirs(_ fileManager: FileManager) -> [String] {
        let apps = (try? fileManager.contentsOfDirectory(atPath: "/Applications")) ?? []
        let selected = Shell.run("/usr/bin/xcode-select", ["-p"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return [ProcessInfo.processInfo.environment["DEVELOPER_DIR"], selected.isEmpty ? nil : selected].compactMap { $0 }
            + apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.map { "/Applications/\($0)/Contents/Developer" }
    }

    /// An Xcode with the iOS SDK (games/totk/ios/tools/xcode_dir.py looks in the same places, and more), and the
    /// Homebrew tools the device libraries and the project need.
    static func iosCheck(_ fileManager: FileManager) -> [Missing] {
        var missing: [Missing] = []
        if !developerDirs(fileManager).contains(where: { fileManager.fileExists(atPath: "\($0)/Platforms/iPhoneOS.platform") }) {
            missing.append(Missing(what: String(localized: "Xcode 26 or later with the iOS SDK (the command line tools are not enough)"),
                                   command: "open 'macappstore://apps.apple.com/app/xcode/id497799835'"))
        }
        let tools = ["xcodegen", "cmake", "ninja"].filter { tool in
            !toolPaths.contains { fileManager.isExecutableFile(atPath: "\($0)/\(tool)") }
        }
        if !tools.isEmpty {
            missing.append(Missing(what: String(localized: "Homebrew packages: \(tools.joined(separator: ", "))"),
                                   command: "brew install \(tools.joined(separator: " "))"))
        }
        return missing
    }

    /// The MacNativeGames checkout: the folder the user chose, the sources a release carries (Contents/Resources/checkout,
    /// make_dmg.sh), or the checkout this app was built in (ui/Builder/build/...).
    static func findRepo(chosen: String?, bundle: URL = Bundle.main.bundleURL) -> URL? {
        if let chosen, isRepo(URL(fileURLWithPath: chosen)) { return URL(fileURLWithPath: chosen) }
        let carried = bundle.appendingPathComponent("Contents/Resources/checkout")
        if isRepo(carried) { return carried }
        var dir = bundle.deletingLastPathComponent()
        while dir.path != "/" {
            if isRepo(dir) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func isRepo(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("build_app.py").path) && !Game.load(repo: url, fileManager: fm).isEmpty
    }
}

/// release.json in the sources a Builder release carries (make_dmg.sh): their commit, which build_app.py records in each
/// app it builds since there is no git, and the release's version.
struct Release: Decodable, Equatable {
    static let schema = 1

    var schema: Int
    var commit: String
    var version: String

    static func read(_ repo: URL?) -> Release? {
        guard let repo, let data = try? Data(contentsOf: repo.appendingPathComponent("release.json")),
              let release = try? JSONDecoder().decode(Release.self, from: data), release.schema == schema else { return nil }
        return release
    }
}
