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
    private let browser = BrowserSignIn()
    private var statusCatalog: (accountID: String, catalog: Catalog)?
    private var monitor: Task<Void, Never>?
    private var lastSignal = Date.distantPast

    init() {
        do {
            account = try SharedStore.account()
            if let account { _ = try CredentialStore.read(for: account) }
        } catch { self.error = error.localizedDescription }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.readStatus()
                if self.account != nil, self.account?.paused == false, Date().timeIntervalSince(self.lastSignal) >= SyncContract.interval {
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
        if status.syncing { return "Checking your library…" }
        return status.lastSync == nil ? "Connecting to Immich…" : "Library is up to date"
    }
    var stateSymbol: String {
        if account?.paused == true { return "pause.circle.fill" }
        if error != nil || status.message != nil { return "exclamationmark.triangle.fill" }
        return transferText != nil || status.syncing || status.lastSync == nil ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
    func readStatus() {
        guard let account else { return }
        do {
            let catalog: Catalog
            if let cached = statusCatalog, cached.accountID == account.id { catalog = cached.catalog }
            else {
                catalog = try Catalog(url: SharedStore.catalogURL(accountID: account.id))
                statusCatalog = (account.id,catalog)
            }
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
    func signIn(server: String, email: String, password: String, allowHTTP: Bool) async {
        await connect(server: server, allowHTTP: allowHTTP) { api in
            try await api.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        }
    }
    func signInWithBrowser(server: String, allowHTTP: Bool) async {
        await connect(server: server, allowHTTP: allowHTTP) { api in
            let challenge = try OAuthChallenge()
            let url = try await api.authorizeOAuth(challenge)
            let callback = try await self.browser.authenticate(url)
            return try await api.finishOAuth(callback: callback, challenge: challenge)
        }
    }
    private func connect(server: String, allowHTTP: Bool,
                         authenticate: (ImmichAPI) async throws -> SessionLogin) async {
        busy = true; error = nil
        defer { busy = false }
        var pending: ImmichAPI?
        var pendingAccount: Account?
        var adopted = false
        do {
            let address = try ServerAddress(server, allowHTTP: allowHTTP)
            let publicAPI = ImmichAPI(serverURL: address.apiURL)
            try await publicAPI.version().requireSupported()
            let login = try await authenticate(publicAPI)
            let authenticated = ImmichAPI(serverURL: address.apiURL, token: { login.accessToken })
            pending = authenticated
            guard !login.shouldChangePassword else { throw SyncError.passwordChangeRequired }
            if let existing = account, existing.serverURL != address.apiURL || existing.userID != login.userId {
                throw NSError(domain: "ImmichSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnect the current account before signing in to a different server or user."])
            }
            let sessionID = try await authenticated.currentSessionID()
            var connected = Account(id: account?.id ?? UUID().uuidString, serverURL: address.apiURL,
                userID: login.userId, displayName: login.name, email: login.userEmail,
                sessionID: sessionID, allowHTTP: allowHTTP)
            connected.paused = account?.paused ?? false
            pendingAccount = connected
            let previous = account
            try CredentialStore.save(login.accessToken, for: connected)
            try SharedStore.save(connected)
            account = connected; adopted = true
            if let previous, previous.sessionID != connected.sessionID {
                if let token = try? CredentialStore.read(for: previous) {
                    try? await ImmichAPI(serverURL: previous.serverURL, token: { token }).logout()
                }
                try? CredentialStore.delete(for: previous)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSFileProviderManager.add(domain(for: connected)) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            signal(force: true)
        } catch is CancellationError {
            if !adopted {
                try? await pending?.logout()
                if let pendingAccount { try? CredentialStore.delete(for: pendingAccount) }
            }
        } catch {
            if !adopted {
                try? await pending?.logout()
                if let pendingAccount { try? CredentialStore.delete(for: pendingAccount) }
            }
            self.error = error.localizedDescription
        }
    }
    func domain(for account: Account) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(account.id), displayName: "Immich — \(account.displayName)")
    }
    func signal(force: Bool) {
        guard let account else { return }
        lastSignal = Date()
        if force {
            error = nil
            UserDefaults(suiteName: SharedStore.groupID)?.set(Date().timeIntervalSince1970, forKey: "syncRequestedAt")
        }
        guard let manager = NSFileProviderManager(for: domain(for: account)) else { return }
        if force {
            for code: NSFileProviderError.Code in [.notAuthenticated, .serverUnreachable, .insufficientQuota, .excludedFromSync, .cannotSynchronize] {
                manager.signalErrorResolved(NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)) { _ in }
            }
        }
        manager.signalEnumerator(for: .workingSet) { _ in }
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
            if let token = try? CredentialStore.read(for: account) {
                try? await ImmichAPI(serverURL: account.serverURL, token: { token }).logout()
            }
            try CredentialStore.delete(for: account)
            try SharedStore.clearAccount()
            self.account = nil; statusCatalog = nil; status = SyncStatus(); error = nil
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
                    if let date = model.status.lastSync {
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
    @Published var email = ""
    @Published var password = ""
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
                        TextField("Email address", text: $fields.email).textContentType(.username)
                        SecureField("Password", text: $fields.password).textContentType(.password)
                        Toggle("Allow HTTP on my trusted local network", isOn: $fields.allowHTTP).font(.caption)
                        Text("Your session is stored in a protected file on this Mac. Your password is never saved. This build connects to Immich \(SyncContract.serverVersion).")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.account == nil ? "Sign in & add Finder location" : "Sign in again") {
                            Task {
                                await model.signIn(server: fields.server, email: fields.email, password: fields.password, allowHTTP: fields.allowHTTP)
                                fields.password = ""
                            }
                        }.buttonStyle(.borderedProminent).tint(.indigo)
                            .disabled(model.busy || fields.email.isEmpty || fields.password.isEmpty || fields.server.isEmpty)
                        Button("Sign in with browser") {
                            Task { await model.signInWithBrowser(server: fields.server, allowHTTP: fields.allowHTTP) }
                        }.disabled(model.busy || fields.server.isEmpty)
                        Text("Browser sign-in uses your server’s OAuth provider.").font(.caption).foregroundStyle(.secondary)
                        if model.busy { ProgressView().controlSize(.small) }
                    }.textFieldStyle(.roundedBorder).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("How your library syncs").font(.headline)
                    rule("photo.on.rectangle", "Folder View", "Drop images or videos into Folder View to upload. Immich’s storage template chooses their folders. Server folders cannot be renamed or moved here. Deleting media here moves it to Immich trash, including its album appearances.")
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
        .onAppear { fields.server = model.account?.serverURL.absoluteString ?? ""; fields.allowHTTP = model.account?.allowHTTP ?? false; fields.email = model.account?.email ?? "" }
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
