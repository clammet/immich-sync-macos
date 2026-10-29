import AppKit
import FileProvider
import ImmichCore
import ServiceManagement
import SwiftUI

@main
struct ImmichSyncApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Label("Immich Sync", systemImage: model.account?.paused == true ? "pause.circle" : "photo.stack")
        }
        .menuBarExtraStyle(.window)

        Window("Immich Sync Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 560, height: 650)
        .windowResizability(.contentSize)
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var account: Account?
    @Published var status = SyncStatus()
    @Published var error: String?
    @Published var busy = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var transferText: String?
    @Published var transferFraction: Double = 0
    private var monitor: Task<Void, Never>?
    private var lastSignal = Date.distantPast

    init() {
        do { account = try SharedStore.account() } catch { self.error = error.localizedDescription }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readStatus()
                if self.account != nil, self.account?.paused == false, Date().timeIntervalSince(self.lastSignal) >= 300 {
                    self.signal(force: false)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    var stateTitle: String {
        if account == nil { return "Your library, in Finder" }
        if account?.paused == true { return "Sync paused" }
        if error != nil || status.message != nil { return "Sync needs attention" }
        if transferText != nil { return "Syncing your library…" }
        if status.refreshing { return "Checking your library…" }
        return status.lastRefresh == nil ? "Connecting to Immich…" : "Library is up to date"
    }
    var stateSymbol: String {
        if account?.paused == true { return "pause.circle.fill" }
        if error != nil || status.message != nil { return "exclamationmark.triangle.fill" }
        return transferText != nil || status.refreshing || status.lastRefresh == nil ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
    func readStatus() {
        guard let account else { return }
        do {
            let catalog = try Catalog(url: SharedStore.catalogURL(accountID: account.id))
            status = try catalog.state("status", as: SyncStatus.self) ?? SyncStatus()
            transferText = nil
            if let manager = NSFileProviderManager(for: domain(for: account)) {
                let uploads = manager.globalProgress(for: .uploading)
                let downloads = manager.globalProgress(for: .downloading)
                if !uploads.isFinished || !downloads.isFinished {
                    let progress = !uploads.isFinished ? uploads : downloads
                    let verb = !uploads.isFinished ? "Uploading" : "Downloading"
                    transferText = "\(verb) \(ByteCountFormatter.string(fromByteCount: progress.completedUnitCount, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalUnitCount, countStyle: .file))"
                    transferFraction = progress.fractionCompleted
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func connect(server: String, key: String, allowHTTP: Bool) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let address = try ServerAddress(server, allowHTTP: allowHTTP)
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw SyncError.missingAccount }
            let provisional = Account(serverURL: address.apiURL, userID: "", displayName: "", serverMajor: 2, serverMinor: 5, allowHTTP: allowHTTP)
            let api = ImmichAPI(account: provisional, apiKey: key)
            async let fetchedVersion = api.version()
            async let fetchedUser = api.currentUser()
            let (version, user) = try await (fetchedVersion, fetchedUser)
            guard version.major > 2 || (version.major == 2 && version.minor >= 5) else { throw SyncError.incompatibleServer }
            if let existing = account, existing.serverURL != address.apiURL || existing.userID != user.id {
                throw NSError(domain: "ImmichSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnect the current account before connecting a different server or user. Downloaded and unsynced files are kept when disconnecting."])
            }
            var connected = Account(id: account?.id ?? UUID().uuidString, serverURL: address.apiURL, userID: user.id,
                displayName: user.name, serverMajor: version.major, serverMinor: version.minor, allowHTTP: allowHTTP)
            connected.paused = account?.paused ?? false
            _ = try await api.mediaTypes()
            try CredentialStore.save(key, accountID: connected.id)
            try SharedStore.save(connected)
            // Keep recoverable configuration if domain registration fails; the user can retry setup.
            account = connected
            let domain = domain(for: connected)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSFileProviderManager.add(domain) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            signal(force: true)
        } catch { self.error = error.localizedDescription }
    }
    func domain(for account: Account) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(account.id), displayName: "Immich — \(account.displayName)")
    }
    func signal(force: Bool) {
        guard let account else { return }
        lastSignal = Date()
        if force {
            error = nil
            UserDefaults(suiteName: SharedStore.groupID)?.set(Date().timeIntervalSince1970, forKey: "refreshRequestedAt")
        }
        guard let manager = NSFileProviderManager(for: domain(for: account)) else { return }
        if force {
            for code: NSFileProviderError.Code in [.notAuthenticated, .serverUnreachable, .insufficientQuota, .excludedFromSync, .cannotSynchronize] {
                manager.signalErrorResolved(NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)) { _ in }
            }
        }
        manager.signalEnumerator(for: .workingSet) { _ in }
        manager.signalEnumerator(for: .rootContainer) { _ in }
    }
    func togglePause() {
        guard var updated = account else { return }
        updated.paused.toggle()
        do { try SharedStore.save(updated); account = updated; if !updated.paused { signal(force: true) } }
        catch { self.error = error.localizedDescription }
    }
    func openFinder() {
        guard let account, let manager = NSFileProviderManager(for: domain(for: account)) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            Task { @MainActor in
                if let url { NSWorkspace.shared.open(url) }
                else { self?.error = error?.localizedDescription ?? "The Finder location is not ready. Check the extension is enabled in System Settings." }
            }
        }
    }
    func openWeb() {
        guard let server = account?.serverURL else { return }
        NSWorkspace.shared.open(server.deletingLastPathComponent())
    }
    func setLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            } catch { self.error = error.localizedDescription }
        }
    }
    func disconnect() async {
        guard let account else { return }
        busy = true; defer { busy = false }
        do {
            let keptURL: URL? = try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.remove(domain(for: account), mode: .preserveDownloadedUserData) { url, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
                }
            }
            try CredentialStore.delete(accountID: account.id)
            try SharedStore.clearAccount()
            self.account = nil; status = SyncStatus(); error = nil
            if let keptURL { NSWorkspace.shared.activateFileViewerSelecting([keptURL]) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct MenuPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "photo.stack.fill").font(.system(size: 25)).foregroundStyle(.indigo)
                    .frame(width: 48, height: 48).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Immich Sync").font(.headline)
                    Text(model.account?.displayName ?? "A home for your memories").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { settings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
            }
            VStack(alignment: .leading, spacing: 12) {
                Label(model.stateTitle, systemImage: model.stateSymbol).font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(model.status.message != nil || model.error != nil ? .orange : .primary)
                if model.account != nil {
                    HStack(spacing: 20) {
                        stat("\(model.status.assetCount.formatted())", label: "photos & videos")
                        stat("\(model.status.albumCount.formatted())", label: "albums")
                    }
                    if let date = model.status.lastRefresh {
                        Text("Last checked \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Connect your server to browse photos and videos, sync changes, and keep favorites available offline.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            if let error = model.error ?? model.status.message {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let transfer = model.transferText {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.transferFraction).tint(.indigo)
                    Text(transfer).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.account != nil {
                Button(action: model.openFinder) { Label("Open in Finder", systemImage: "folder").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.indigo)
                HStack {
                    Button { model.signal(force: true) } label: { Label("Sync now", systemImage: "arrow.clockwise") }.disabled(model.account?.paused == true)
                    Spacer()
                    Button(action: model.togglePause) { Label(model.account?.paused == true ? "Resume" : "Pause", systemImage: model.account?.paused == true ? "play" : "pause") }
                }.buttonStyle(.plain).font(.subheadline)
            } else {
                Button { settings() } label: { Text("Connect to Immich").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.indigo)
            }
            Divider()
            HStack {
                if model.account != nil { Button("Immich on the web", action: model.openWeb) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(20).frame(width: 360).task { model.readStatus() }
    }
    private func stat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value).font(.title3.weight(.semibold)); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
    private func settings() { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
}

@MainActor private final class SetupFields: ObservableObject {
    @Published var server = ""
    @Published var apiKey = ""
    @Published var allowHTTP = false
    @Published var confirmDisconnect = false
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var fields = SetupFields()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: "photo.stack.fill").font(.largeTitle).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your memories. On your Mac.").font(.title2.bold())
                        Text("Connect Immich to Finder").foregroundStyle(.secondary)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Server connection").font(.headline)
                        TextField("https://photos.example.com", text: $fields.server).textContentType(.URL)
                        SecureField(model.account == nil ? "Immich API key" : "New or existing API key", text: $fields.apiKey)
                        Toggle("Allow HTTP on my trusted local network", isOn: $fields.allowHTTP).font(.caption)
                        Text("Create an API key in Immich → Account settings → API keys. The key is stored in your login Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Required API key permissions") {
                            Text("user.read, asset.read, asset.view, asset.download, asset.upload, asset.copy, asset.delete, album.read, album.create, album.update, album.delete, albumAsset.create, albumAsset.delete")
                                .font(.caption.monospaced()).textSelection(.enabled).padding(.top, 4)
                        }.font(.caption)
                        Button(model.account == nil ? "Connect & add Finder location" : "Update connection") {
                            Task { await model.connect(server: fields.server, key: fields.apiKey, allowHTTP: fields.allowHTTP); if model.error == nil { fields.apiKey = "" } }
                        }.buttonStyle(.borderedProminent).tint(.indigo).disabled(model.busy || fields.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.busy { ProgressView().controlSize(.small) }
                    }.textFieldStyle(.roundedBorder).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("How your library syncs").font(.headline)
                    rule("photo.on.rectangle", "All Photos", "Drop images or videos here to upload. Deleting here moves the asset to Immich trash, including its album appearances.")
                    rule("rectangle.stack", "Albums", "Create and rename album folders. Deleting a photo here removes it from the album; deleting an album keeps its photos. Albums cannot be nested.")
                    rule("pencil", "Edits preserve the old original", "Edited media becomes a new asset with copied album associations. The previous asset goes to Immich trash. Original filenames cannot be renamed through the current Immich API.")
                    rule("pin", "Always keep available", "Use Finder’s context menu to keep a file or folder downloaded. Unsupported files show a grey ignored badge, stay on this Mac, and are never uploaded.")
                }
                Toggle("Open Immich Sync at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
                if model.account != nil {
                    Divider()
                    Button("Disconnect account…", role: .destructive) { fields.confirmDisconnect = true }.disabled(model.busy)
                    Text("Downloaded and unsynced files are kept on this Mac. Online-only items remain on Immich.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
        .frame(width: 560, height: 700)
        .onAppear { fields.server = model.account?.serverURL.absoluteString ?? ""; fields.allowHTTP = model.account?.allowHTTP ?? false }
        .confirmationDialog("Disconnect Immich? Downloaded and unsynced files will be kept on this Mac.", isPresented: $fields.confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
        }
    }
    private func rule(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
