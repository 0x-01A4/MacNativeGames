import AppKit
import SwiftUI

/// The game apps on this Mac: what each was built from, whether the checkout would build it differently now, and the
/// shader list contributions their games noted.
struct LibraryView: View {
    @Environment(Wizard.self) private var wizard
    @State private var apps: [BuiltApp] = []
    @State private var freshness: [String: Freshness] = [:]
    @State private var contributions: [Contribution] = []
    @State private var works: [WorkFolder] = []
    @State private var sizes: [String: Int64] = [:]   // by path, measured after the list shows
    @State private var loading = true
    @State private var trash: BuiltApp?
    @State private var deleting: WorkFolder?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(title: "Your apps", detail: "The game apps on this Mac, newest build first.")
                    Spacer()
                    Button("Refresh") { Task { await load() } }.disabled(loading)
                }
                if loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for apps…") }
                } else if apps.isEmpty {
                    Text("No game apps found yet. Build one on the Build page.").foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    AppRow(app: app, freshness: freshness[app.id] ?? .unknown, trash: { trash = app })
                }
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
                if !works.isEmpty { workFolders }
                Contributions(items: $contributions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task { await load() }
        .confirmationDialog(Text("Move \(trash?.name ?? "") to the Trash?"), isPresented: Binding(presenting: $trash),
                            presenting: trash) { app in
            Button("Move to Trash", role: .destructive) { moveToTrash(app) }
        } message: { app in
            Text("\(app.url.path)\n\n\(savesText(app)) You can put the app back from the Trash.")
        }
        .confirmationDialog(Text("Move the work folder to the Trash?"), isPresented: Binding(presenting: $deleting),
                            presenting: deleting) { work in
            Button("Move to Trash", role: .destructive) { moveToTrash(work) }
        } message: { work in
            Text("\(work.url.path)\n\nThe apps keep working. The next build of this game starts from the beginning, which takes much longer.")
        }
    }

    /// The build scripts' work folders: big, reused by the next build, and safe to delete unless the app reads from one.
    private var workFolders: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Work folders").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text("What each build extracted and compiled. The next build reuses it, so deleting one only makes that build start from the beginning.")
                .note()
            ForEach(works) { work in
                let busy = wizard.running && wizard.report?.work.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == work.url.path
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(work.url.path).lineLimit(1).truncationMode(.middle).help(work.url.path)
                        Text(sizes[work.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Measuring…"))
                            .font(.callout).foregroundStyle(.secondary)
                        if let keep = work.keep {
                            Text("Kept: \(keep)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([work.url]) }
                    Button("Move to Trash…", role: .destructive) { deleting = work }
                        .disabled(work.keep != nil || busy)
                        .help(busy ? String(localized: "A build is using it") : work.keep ?? "")
                }
                .card()
            }
        }
    }

    private func load() async {
        loading = true
        let remembered = wizard.rememberedApps
        let repo = wizard.preflight.repo
        let release = wizard.preflight.release
        let games = wizard.preflight.games
        let current = wizard.report?.work.map { (work: $0, game: wizard.report?.game) }
        let found = await Task.detached { () -> ([BuiltApp], [String: Freshness], [Contribution], [WorkFolder]) in
            let apps = BuiltApp.find(remembered: remembered, games: games)
            var fresh: [String: Freshness] = [:]
            for app in apps { fresh[app.id] = Freshness.of(app.info, repo: repo, release: release, games: games) }
            return (apps, fresh, Contribution.all(games: games), WorkFolder.all(apps: apps, current: current, games: games))
        }.value
        (apps, freshness, contributions, works) = found
        loading = false
        for work in works where sizes[work.id] == nil {   // tens of GB in many files: after the list, one at a time
            sizes[work.id] = await Task.detached { WorkFolder.size(work.url) }.value
        }
    }

    private func savesText(_ app: BuiltApp) -> String {
        String(localized: "Your saves, settings and shader cache stay in \(wizard.preflight.games.dataLocation(app.game)).")
    }

    private func moveToTrash(_ work: WorkFolder) {
        recycle(work.url, name: work.url.lastPathComponent) { works.removeAll { $0 == work } }
    }

    private func moveToTrash(_ app: BuiltApp) {
        if AppRow.isRunning(app) {
            problem = String(localized: "\(app.name) is open: quit it first, then move it to the Trash.")
            return
        }
        recycle(app.url, name: app.name) {
            wizard.forget(app.url)
            apps.removeAll { $0 == app }
        }
    }

    /// `moved` runs once `url` is in the Trash; a failure is shown under the list instead.
    private func recycle(_ url: URL, name: String, moved: @escaping @MainActor () -> Void) {
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                if let error {
                    problem = String(localized: "\(name) was not moved to the Trash: \(error.localizedDescription)")
                } else {
                    moved()
                }
            } }
        }
    }
}

struct AppRow: View {
    @Environment(Wizard.self) private var wizard
    var app: BuiltApp
    var freshness: Freshness
    var trash: () -> Void

    var body: some View {
        let info = app.info
        let missing = info.map(wizard.missingInputs) ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(app.name) \(info?.displayVersion ?? app.version)").font(.headline)
                Spacer()
                status
            }
            Text(app.url.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(app.url.path)
            if let info {
                let date = info.builtDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? info.built
                Text("Built \(date) from \(info.commit.map { String($0.prefix(8)) } ?? String(localized: "a folder that is not a git checkout"))\(info.dirty == true ? String(localized: " (with local changes)") : "")")
                    .font(.callout).foregroundStyle(.secondary)
                if info.inputs.mod != nil {
                    Text("With the mod \(URL(fileURLWithPath: info.inputs.mod!).lastPathComponent)").font(.callout).foregroundStyle(.secondary)
                }
                if !missing.isEmpty {
                    Text("Can't rebuild as it was: \(missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")) is no longer where it was.")
                        .font(.callout).foregroundStyle(.orange).wrapping()
                }
            } else {
                Text("Built before apps recorded what they were built from: rebuild it on the Build page once, and it will.")
                    .font(.callout).note()
            }
            HStack {
                Button("Open") { NSWorkspace.shared.open(app.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                Button(freshness == .changed ? "Rebuild with This Checkout" : freshness == .otherRelease ? "Rebuild with This Builder" : "Rebuild") { wizard.rebuild(app) }
                    .disabled(info == nil || !missing.isEmpty || wizard.running)
                    .help(wizard.running ? String(localized: "A build is running") : "")
                if let data = dataFolder, FileManager.default.fileExists(atPath: data.path) {
                    Button("Show Saves") { NSWorkspace.shared.activateFileViewerSelecting([data]) }
                        .help(String(localized: "Saves, settings and the shader cache: \(data.path)"))
                }
                Spacer()
                Button("Move to Trash…", role: .destructive, action: trash)
            }
        }
        .card(padding: 14)
        .accessibilityElement(children: .contain)
    }

    /// Where this app keeps its saves (game.json data_folder, or data_beside_app next to the app).
    private var dataFolder: URL? {
        let game = wizard.preflight.games.named(app.game)
        if let beside = game?.dataBesideApp { return app.url.deletingLastPathComponent().appendingPathComponent(beside) }
        return game?.dataFolder.map(Contribution.data)
    }

    static func isRunning(_ app: BuiltApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
    }

    @ViewBuilder private var status: some View {
        switch freshness {
        case .current:
            Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .changed:
            Label("The checkout has changed since", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                .help(String(localized: "The files this game is built from changed after this app was built: a rebuild picks up the changes."))
        case .otherRelease:
            Label("Built with another Builder version", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                .help(String(localized: "This app was built from other sources than the ones this Builder carries: a rebuild builds it with this Builder's."))
        case .unknown:
            Label("Can't tell", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                .help(String(localized: "There is no build record with a commit of this checkout, or the app was built with local changes: a rebuild is the way to be sure."))
        }
    }
}

/// The shader list contribution files, with what the game's own reminder would offer: send, or stop the reminders.
struct Contributions: View {
    @Binding var items: [Contribution]
    @State private var problem: String?
    @State private var sending: Contribution?   // the form is open: did the player send the file?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shader contributions").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text("While you play, the game notes the shaders and render pipelines the shared list doesn't have yet: identifiers only, no game data, saves or personal information. Sent to GitHub, they come with everyone's next build. Nothing is sent unless you send it.")
                .note()
            if items.isEmpty {
                Text("Nothing noted yet.").foregroundStyle(.secondary)
            }
            ForEach(items, id: \.game.id) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(item.game.name): \(item.rows) rows, \(item.unsent) new since the last reminder")
                    Text(item.never ? String(localized: "Reminders are off: the game no longer asks before it starts.")
                                    : String(localized: "The game asks before it starts once there are \(item.step) new rows."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Send…") {
                            NSWorkspace.shared.open(item.form)
                            NSWorkspace.shared.activateFileViewerSelecting([item.file])
                            sending = item
                        }
                        .help(String(localized: "Opens the GitHub form and shows the file in Finder: drag it into the form."))
                        if item.never {
                            Button("Turn Reminders On") { update(item) { try $0.resumeReminders() } }
                        } else {
                            Button("Don't Remind Me Again") { update(item) { try $0.stopReminders() } }
                        }
                    }
                }
                .card()
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        // presenting: the dialog clears `sending` before a button's action runs, so the action gets the item from it
        .confirmationDialog(Text("Did you send the file?"), isPresented: Binding(presenting: $sending), presenting: sending) { item in
            Button("Sent") { update(item) { try $0.markSent() } }
            Button("Not Yet", role: .cancel) {}
        } message: { _ in
            Text("Once it's sent, the game reminds you again only after new rows.")
        }
    }

    private func update(_ item: Contribution, _ change: (Contribution) throws -> Void) {
        do {
            try change(item)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        if let fresh = Contribution.read(game: item.game, file: item.file),
           let index = items.firstIndex(where: { $0.game.id == item.game.id }) { items[index] = fresh }
    }
}

