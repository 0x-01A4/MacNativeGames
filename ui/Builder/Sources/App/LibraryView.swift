import AppKit
import SwiftUI

/// The game apps on this Mac: what each was built from, whether the checkout would build it differently now, and the
/// shader list contributions their games noted.
struct LibraryView: View {
    @EnvironmentObject var wizard: Wizard
    @State private var apps: [BuiltApp] = []
    @State private var freshness: [String: Freshness] = [:]
    @State private var contributions: [Contribution] = []
    @State private var loading = true
    @State private var trash: BuiltApp?
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
                Contributions(items: $contributions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task { await load() }
        .confirmationDialog(Text("Move \(trash?.name ?? "") to the Trash?"), isPresented: Binding(get: { trash != nil }, set: { if !$0 { trash = nil } }),
                            presenting: trash) { app in
            Button("Move to Trash", role: .destructive) { moveToTrash(app) }
        } message: { app in
            Text("\(app.url.path)\n\n\(savesText(app)) You can put the app back from the Trash.")
        }
    }

    private func load() async {
        loading = true
        let remembered = wizard.rememberedApps
        let repo = wizard.preflight.repo
        let games = wizard.preflight.games
        let found = await Task.detached { () -> ([BuiltApp], [String: Freshness], [Contribution]) in
            let apps = BuiltApp.find(remembered: remembered, games: games)
            var fresh: [String: Freshness] = [:]
            for app in apps { fresh[app.id] = Freshness.of(app.info, repo: repo, games: games) }
            return (apps, fresh, Contribution.all(games: games))
        }.value
        (apps, freshness, contributions) = found
        loading = false
    }

    private func savesText(_ app: BuiltApp) -> String {
        if let beside = wizard.preflight.games.named(app.game)?.dataBesideApp {
            return String(localized: "Your saves, settings and shader cache stay in “\(beside)” next to it.")
        }
        return String(localized: "Your saves, settings and shader cache stay in ~/Library/Application Support/MacNativeGames.")
    }

    private func moveToTrash(_ app: BuiltApp) {
        NSWorkspace.shared.recycle([app.url]) { _, error in
            DispatchQueue.main.async {
                if let error {
                    problem = String(localized: "\(app.name) was not moved to the Trash: \(error.localizedDescription)")
                } else {
                    wizard.forget(app.url)
                    apps.removeAll { $0 == app }
                }
            }
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var wizard: Wizard
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
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Built before apps recorded what they were built from: rebuild it on the Build page once, and it will.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Open") { NSWorkspace.shared.open(app.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                Button(freshness == .changed ? "Rebuild with This Checkout" : "Rebuild") { wizard.rebuild(app) }
                    .disabled(info == nil || !missing.isEmpty || wizard.running)
                    .help(wizard.running ? String(localized: "A build is running") : "")
                Spacer()
                Button("Move to Trash…", role: .destructive, action: trash)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        switch freshness {
        case .current:
            Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .changed:
            Label("The checkout has changed since", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                .help(String(localized: "The files this game is built from changed after this app was built: a rebuild picks up the changes."))
        case .unknown:
            EmptyView()
        }
    }
}

/// The shader list contribution files, with what the game's own reminder would offer: send, or stop the reminders.
struct Contributions: View {
    @Binding var items: [Contribution]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shader contributions").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text("While you play, the game notes the shaders and render pipelines the shared list doesn't have yet: identifiers only, no game data, saves or personal information. Sent to GitHub, they come with everyone's next build. Nothing is sent unless you send it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                Text("Nothing noted yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(item.game.name): \(item.rows) rows, \(item.unsent) new since the last reminder")
                    Text(item.never ? String(localized: "Reminders are off: the game no longer asks before it starts.")
                                    : String(localized: "The game asks before it starts once there are \(item.step) new rows."))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Send…") {
                            NSWorkspace.shared.open(item.form)
                            NSWorkspace.shared.activateFileViewerSelecting([item.file])
                            update(index) { try $0.markSent() }
                        }
                        .help(String(localized: "Opens the GitHub form and shows the file in Finder: drag it into the form."))
                        if item.never {
                            Button("Turn Reminders On") { update(index) { try $0.resumeReminders() } }
                        } else {
                            Button("Don't Remind Me Again") { update(index) { try $0.stopReminders() } }
                        }
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
    }

    private func update(_ index: Int, _ change: (Contribution) throws -> Void) {
        let item = items[index]
        do {
            try change(item)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        if let fresh = Contribution.read(game: item.game, file: item.file) { items[index] = fresh }
    }
}

