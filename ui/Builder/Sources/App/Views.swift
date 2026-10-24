import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BuilderApp: App {
    @StateObject private var wizard = Wizard()

    var body: some Scene {
        Window("MacNativeGames Builder", id: "builder") {
            Root().environmentObject(wizard)
                .frame(minWidth: 760, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
    }
}

struct Root: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        Group {
            switch wizard.mode {
            case .build: WizardView()
            case .library: LibraryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $wizard.mode) {
                    Text("Build").tag(Wizard.Mode.build)
                    Text("Library").tag(Wizard.Mode.library)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Build a new app, or the apps already built"))
            }
        }
    }
}

struct WizardView: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        HStack(spacing: 0) {
            StepList()
                .frame(width: 170)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let standIn = ProcessInfo.processInfo.environment["BUILDER_SCRIPT"] {
                    Label("Test mode: builds run \((standIn as NSString).lastPathComponent) instead of build_app.py, and no app is written. Quit and open the Builder from Finder for a real build.",
                          systemImage: "testtube.2")
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.25))
                    Divider()
                }
                ScrollView {
                    page
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                Divider()
                Navigation()
                    .padding(16)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch wizard.step {
        case .keys: KeysPage()
        case .game: GamePage()
        case .target: TargetPage()
        case .build: BuildPage()
        case .result: ResultPage()
        }
    }
}

struct StepList: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Wizard.Step.allCases, id: \.self) { step in
                let state = step.rawValue < wizard.step.rawValue ? "checkmark.circle.fill"
                    : step == wizard.step ? "circle.inset.filled" : "circle"
                Label(step.title, systemImage: state)
                    .foregroundStyle(step == wizard.step ? .primary : .secondary)
                    .accessibilityLabel(step == wizard.step ? Text("\(step.title), current step") : Text(step.title))
            }
            Spacer()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
    }
}

struct Navigation: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        HStack {
            if [.game, .target].contains(wizard.step) {
                Button("Back") { wizard.step = Wizard.Step(rawValue: wizard.step.rawValue - 1)! }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            switch wizard.step {
            case .keys, .game:
                Button("Continue") { wizard.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!wizard.canContinue)
            case .target:
                Button("Build") { wizard.build() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!wizard.canContinue)
            case .build:
                Button("Cancel", role: .cancel) { wizard.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .result:
                EmptyView()
            }
        }
    }
}

// MARK: pages

struct PageTitle: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }
}

/// A file or folder chosen with an open panel; the Builder is not sandboxed, so the path is all it keeps.
func choose(_ types: [UTType], folder: Bool = false, message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !folder
    panel.canChooseDirectories = folder
    panel.allowsMultipleSelection = false
    if !folder { panel.allowedContentTypes = types }
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
}

/// The file types the checkout's games are built from (game.json "files").
func types(_ extensions: [String]) -> [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }

struct FileRow: View {
    var label: LocalizedStringKey
    var url: URL?
    var placeholder: LocalizedStringKey
    var choose: () -> Void

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(url.map { $0.lastPathComponent } ?? "")
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(url?.path ?? "")
                if url == nil { Text(placeholder).foregroundStyle(.secondary) }
                Spacer()
                Button("Choose…", action: choose).accessibilityLabel(Text("Choose \(Text(label))"))
            }
        }
    }
}

struct KeysPage: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Your keys",
                      detail: "The build decrypts your own game dump with the prod.keys from your own console. Nothing is downloaded, and the keys stay where they are.")
            SetupStatus()
            Form {
                FileRow(label: "prod.keys", url: wizard.keys, placeholder: "not chosen") {
                    if let url = choose([.data], message: String(localized: "Choose your prod.keys")) { wizard.setKeys(url) }
                }
                Toggle("Remember this location", isOn: $wizard.rememberKeys)
                    .onChange(of: wizard.rememberKeys) { wizard.saveKeysChoice() }
                    .help("Only the path is kept, in this app's preferences; the keys themselves are never copied or read by the Builder.")
            }
            .formStyle(.grouped)
        }
    }
}

/// What build_app.py needs on this Mac; the commands to run when something is missing.
struct SetupStatus: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        let p = wizard.preflight
        if p.repo == nil || !p.missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("This Mac needs a few things first", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                if p.repo == nil {
                    HStack {
                        Text("The MacNativeGames folder (the one with build_app.py) was not found.")
                        Button("Choose Folder…") {
                            if let url = choose([], folder: true, message: String(localized: "Choose the MacNativeGames folder")) { wizard.chooseRepo(url) }
                        }
                    }
                }
                Commands(items: p.missing)
            }
            .padding(14)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Missing tools with the command that installs each, and a way to look again after running them.
struct Commands: View {
    @EnvironmentObject var wizard: Wizard
    var items: [Preflight.Missing]

    var body: some View {
        ForEach(items, id: \.what) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.what)
                HStack {
                    Text(item.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.command, forType: .string)
                    }
                    .accessibilityLabel(Text("Copy the command \(item.command)"))
                }
            }
        }
        Text("Run the commands in Terminal, then check again.").foregroundStyle(.secondary)
        Button("Check Again") { wizard.recheck() }
    }
}

struct Missing: View {
    var items: [Preflight.Missing]
    var title: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Commands(items: items)
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GamePage: View {
    @EnvironmentObject var wizard: Wizard
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Your game",
                      detail: "Choose or drop the base game file (XCI or NSP). The Builder reads which game and version it is; the file name doesn't matter.")
            Form {
                FileRow(label: "Game file", url: wizard.game, placeholder: "drop it here") {
                    if let url = choose(types(wizard.preflight.games.gameExtensions), message: String(localized: "Choose the base game (\(wizard.preflight.games.gameExtensions.map { $0.uppercased() }.joined(separator: ", ")))")) { wizard.setGame(url) }
                }
                if wizard.game != nil && wizard.takesUpdate {
                    HStack {
                        FileRow(label: wizard.report?.needsUpdate == true ? "Update (needed)" : "Update (optional)", url: wizard.update,
                                placeholder: wizard.report?.needsUpdate == true ? "needed: the game's code is in it" : "none") {
                            if let url = choose(types(wizard.preflight.games.updateExtensions), message: String(localized: "Choose the update (\(wizard.preflight.games.updateExtensions.map { $0.uppercased() }.joined(separator: ", ")))")) { wizard.setUpdate(url) }
                        }
                        if wizard.update != nil {
                            Button("Remove") { wizard.setUpdate(nil) }
                        }
                    }
                }
                // Shown as soon as there is a game file, not only once --inspect asks for fonts: the folder can be
                // chosen while the game file is still being read, and an XCI simply doesn't need it.
                if wizard.game != nil {
                    Picker("System fonts from", selection: $wizard.fontsAreFirmware) {
                        Text("Unpacked firmware folder").tag(true)
                        Text("Extracted shared fonts").tag(false)
                    }
                    HStack {
                        FileRow(label: "Fonts folder", url: wizard.fonts,
                                placeholder: wizard.report?.needsFonts == true ? "needed for this game file" : "only for NSP files") {
                            if let url = choose([], folder: true, message: wizard.fontsAreFirmware
                                ? String(localized: "Choose the folder with the firmware's .nca files")
                                : String(localized: "Choose the folder with the six .bfttf shared fonts")) { wizard.fonts = url }
                        }
                        if wizard.fonts != nil {
                            Button("Remove") { wizard.fonts = nil }
                        }
                    }
                }
                // Kept while a re-inspect runs (the report is cleared then), so the rows don't jump
                if wizard.report?.dlc == true || !wizard.dlc.isEmpty {
                    Section("Add-on content (optional)") {
                        ForEach(wizard.dlc, id: \.self) { pack in
                            HStack {
                                Text(pack.lastPathComponent).lineLimit(1).truncationMode(.middle).help(pack.path)
                                Spacer()
                                Button("Remove") { wizard.removeDLC(pack) }
                                    .accessibilityLabel(Text("Remove \(pack.lastPathComponent)"))
                            }
                        }
                        if wizard.dlc.count < 2 {
                            Button("Add Pack…") {
                                if let url = choose(types(["nsp"]), message: String(localized: "Choose an add-on content NSP")) { wizard.addDLC(url) }
                            }
                        }
                        Text("Each pack is its own NSP. A pack you leave out is not in the app.").foregroundStyle(.secondary)
                    }
                }
                if wizard.report?.mod == true || wizard.mod != nil {
                    Section("Mod (optional)") {
                        HStack {
                            FileRow(label: "Mod folder", url: wizard.mod, placeholder: "none") {
                                if let url = choose([], folder: true, message: String(localized: "Choose a mod folder (with exefs/ and/or romfs/)")) { wizard.setMod(url) }
                            }
                            if wizard.mod != nil {
                                Button("Remove") { wizard.setMod(nil) }
                            }
                        }
                        Text("Code patches (exefs/) are merged into the app. RomFS files (romfs/) are installed on the Output page or by hand; see docs/mods.md.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // a folder is never a game file: it's the firmware or the extracted fonts
                    guard wizard.game != nil else { return false }
                    wizard.fonts = url
                } else if wizard.game != nil, url.pathExtension.lowercased() == "nsz" || wizard.report?.needsUpdate == true {
                    wizard.setUpdate(url)
                } else {
                    wizard.setGame(url)
                }
                return true
            } isTargeted: { targeted = $0 }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3) } }
            Found()
        }
    }
}

/// What --inspect found, or why it couldn't tell.
struct Found: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        if wizard.inspecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(wizard.update == nil ? "Reading the game file…" : "Reading the game file and checking the update (up to a minute)…")
            }
        } else if let r = wizard.report, r.needsUpdate == true {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(r.appName ?? ""): the base game", systemImage: "plus.circle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("This game is built from the base game and its update together. Add the update to continue.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if let r = wizard.report {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(r.appName ?? "") \(r.displayVersion ?? "")", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Identified from the game data (\((r.kind ?? "").uppercased())). Builds for: \((r.platforms ?? []).map(Wizard.platformName).joined(separator: ", ")).")
                    .foregroundStyle(.secondary)
            }
        } else if case .failed(let code, let message) = wizard.inspectFailure {
            Failure(code: code, message: message)
        }
    }
}

struct TargetPage: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "What to build",
                      detail: wizard.isDevice
                        ? "An unsigned IPA for \(Wizard.platformName(wizard.platform)) (iOS/iPadOS 26 or visionOS 26), which you sign and install from this Mac."
                        : "Pick the app's final place now: moving it later makes the first start compile the startup shaders again (a few minutes).")
            Form {
                if wizard.platforms.count > 1 {
                    Picker("Build for", selection: $wizard.platform) {
                        ForEach(wizard.platforms, id: \.self) { Text(Wizard.platformName($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Build for") { Text("Mac") }
                }
                LabeledContent("Save as") {
                    HStack {
                        Text(wizard.out?.path ?? "").lineLimit(1).truncationMode(.middle).help(wizard.out?.path ?? "")
                        Spacer()
                        Button("Change…") {
                            let panel = NSSavePanel()
                            let ext = wizard.isDevice ? "ipa" : "app"
                            panel.allowedContentTypes = ext == "app" ? [.applicationBundle] : [UTType(filenameExtension: "ipa") ?? .data]
                            panel.nameFieldStringValue = wizard.out?.lastPathComponent ?? "\(wizard.report?.appName ?? "Game").\(ext)"
                            panel.directoryURL = wizard.out?.deletingLastPathComponent()
                            if panel.runModal() == .OK, let url = panel.url {
                                wizard.out = url.pathExtension == ext ? url : url.appendingPathExtension(ext)
                            }
                        }
                    }
                }
                if let work = wizard.report?.work {
                    LabeledContent("Work folder") {
                        Text(work).lineLimit(1).truncationMode(.middle).help(work).foregroundStyle(.secondary)
                    }
                }
                if wizard.mod != nil && wizard.platform == "macos" && wizard.modHasRomfs {
                    Toggle("Install the mod's RomFS files into the game's mod folder", isOn: $wizard.installModRomfs)
                    if wizard.installModRomfs {
                        Text("When the build ends, the mod folder for this game version is replaced by the mod's romfs/ files and their manifest. What it holds now is moved next to it as a dated backup, not deleted.")
                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Off: the build leaves your mod folder alone and says how to fill it by hand.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if wizard.mod != nil && wizard.isDevice {
                    Text("An iPhone / iPad or Vision Pro app loads no mod folder: only the mod's code patches go in.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if wizard.isDevice {
                    Toggle("Remind me on this Mac to send missing shaders", isOn: $wizard.shaderReminder)
                    Text("While the device with the game is connected, this Mac asks whether to send the shaders the shared list lacks (keys and bind states only, never game files). Nothing is sent without asking.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            if wizard.isDevice && !wizard.preflight.iosMissing.isEmpty {
                Missing(items: wizard.preflight.iosMissing, title: "An iPhone / iPad or Vision Pro build needs these on this Mac")
            }
            Group {
                if let space = wizard.report?.spaceGb?[wizard.platform] {
                    Text(wizard.isDevice
                         ? "The first device build downloads and compiles device libraries and needs about \(space) GB free."
                         : "The first build takes a while and needs about \(space) GB free.")
                }
                Text("The work folder is kept, so a later build, or one that was stopped, reuses what is already done.")
            }
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BuildPage: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Building", detail: "You can keep using the Mac. Cancel stops at once; the next build continues from the finished steps.")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(1...max(wizard.steps.count, 1), id: \.self) { step in
                    let done = wizard.reached > step || (wizard.outcome.map { if case .done = $0 { true } else { false } } ?? false)
                    let current = wizard.reached == step && !done
                    HStack(spacing: 10) {
                        Group {
                            if current { ProgressView().controlSize(.small) }
                            else { Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary) }
                        }
                        .frame(width: 18)
                        Text(wizard.steps.title(step)).foregroundStyle(current || done ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(done ? "done" : current ? "in progress" : "waiting"))
                }
            }
            if let p = wizard.progress {
                Text(p.message ?? "").foregroundStyle(.secondary).lineLimit(2)
            }
            LogView()
        }
    }
}

struct LogView: View {
    @EnvironmentObject var wizard: Wizard
    @State private var shown = false

    var body: some View {
        DisclosureGroup("Log", isExpanded: $shown) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(wizard.lines.suffix(400).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 200)
                .onChange(of: wizard.lines.count) { proxy.scrollTo("end") }
            }
            HStack {
                Spacer()
                Button("Copy Full Log") { wizard.copyLog() }
            }
        }
    }
}

struct Failure: View {
    @EnvironmentObject var wizard: Wizard
    var code: String?
    var message: String

    var body: some View {
        let text = ErrorText(code: code, games: wizard.preflight.games)
        VStack(alignment: .leading, spacing: 8) {
            Label(text.title, systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(.red)
            Text(text.next).fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Inputs the build accepted by another rule than the exact reference hash: worth knowing, not a problem.
struct Notices: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        if !wizard.notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Good to know", systemImage: "info.circle").font(.headline)
                ForEach(Array(wizard.notices.enumerated()), id: \.offset) { _, notice in
                    Text(Notices.text(notice.code) ?? notice.message ?? "").fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    static func text(_ code: String?) -> String? {
        switch code {
        case "npdm_signed": String(localized: "Your dump differs from the reference one only in main.npdm, which carries Nintendo's signature: it was accepted as another genuine dump of this version. The game code itself matched exactly.")
        case "npdm_resigned": String(localized: "Your dump's main.npdm was signed again by a dump tool. The game doesn't use that file and the game code matched exactly, so it was accepted.")
        case "fonts_other_firmware": String(localized: "Some system fonts come from another firmware version than the reference. They were checked as valid fonts and bound by their own bytes.")
        case "sdk_fallback": String(localized: "This Mac's newest macOS SDK doesn't work with its developer tools, so the build used an older one. Updating the command line tools (Software Update) fixes the default.")
        default: nil
        }
    }
}

struct ResultPage: View {
    @EnvironmentObject var wizard: Wizard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch wizard.outcome {
            case .done(let app) where wizard.isDevice:
                PageTitle(title: "Your \(Wizard.platformName(wizard.platform)) app is ready",
                          detail: "It is unsigned: install_device.py signs it with your own Xcode team and installs it. A free Apple ID signs for 7 days; run it again to renew, and the saves stay.")
                Text(app.path).textSelection(.enabled)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Add your Apple ID in Xcode (Xcode > Settings > Accounts), and connect the device.")
                    Text("2. Run this in Terminal from the MacNativeGames folder:")
                    Commands(items: [Preflight.Missing(what: String(localized: "Sign and install"),
                                                       command: "python3.14 games/totk/ios/tools/install_device.py '\(app.path)'")])
                    Text("3. Pair a supported game controller, then start the game. Verify gameplay on your device.")
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }.keyboardShortcut(.defaultAction)
                Notices()
            case .done(let app):
                PageTitle(title: "Your app is ready",
                          detail: "The first start verifies the game data once. Saves, the shader cache and the log are kept in ~/Library/Application Support/MacNativeGames.")
                Text(app.path).textSelection(.enabled)
                HStack {
                    Button("Open") { NSWorkspace.shared.open(app) }.keyboardShortcut(.defaultAction)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                }
                Notices()
            case .failed(let code, let message):
                PageTitle(title: "The build stopped", detail: "Nothing was installed; an app built before is unchanged.")
                Failure(code: code, message: message)
                resultButtons
            case .cancelled:
                PageTitle(title: "Build cancelled", detail: "Building again reuses the steps that finished.")
                resultButtons
            case nil:
                EmptyView()
            }
            LogView()
        }
    }

    private var resultButtons: some View {
        HStack {
            Button("Build Again") { wizard.build() }.keyboardShortcut(.defaultAction)
            Button("Change Files") { wizard.startOver() }
            Button("Copy Full Log") { wizard.copyLog() }
        }
    }
}
