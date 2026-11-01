import AppKit
import FileProvider
import ImmichCore
import ServiceManagement
import SwiftUI

@main
struct ImmichSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Label("OpenCloud Sync", systemImage: model.account?.paused == true ? "pause.circle" : "cloud")
        }
        .menuBarExtraStyle(.window)

    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppModel.shared.start() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await AppModel.shared.refreshProvider() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showSettings()
        return true
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var account: Account?
    @Published var status = SyncStatus()
    @Published var error: String?
    @Published var busy = false
    @Published var immichAccount: Account?
    @Published var discovery: ImmichDiscovery?
    @Published var mappings: [MediaMapping] = []
    @Published var actionResult: ActionResult?
    @Published var recoveryCount = 0
    @Published var recoveryEntries: [PendingEdit] = []
    private var browserAnchor: SyncAnchor?
    @Published var items: [ItemRecord] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var transferText: String?
    @Published var transferFraction: Double = 0
    @Published var providerState = ProviderRegistration.State.signInRequired
    @Published var providerError: String?
    @Published var showEnablementPrompt = false
    private let browser = BrowserSignIn()
    private let registration = ProviderRegistration()
    private var registering = false
    private var disconnecting = false
    private var promptedForEnablement = false
    private var providerObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var statusCatalog: (accountID: String, catalog: Catalog)?
    private var monitor: Task<Void, Never>?
    private var lastSignal = Date.distantPast

    init() {
        do {
            account = try SharedStore.account()
            immichAccount = try SharedStore.immichAccount()
            if let account { _ = try CredentialStore.read(for: account) }
        } catch { self.error = error.localizedDescription }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshProvider()
                self.readStatus()
                if self.account != nil, self.account?.paused == false, Date().timeIntervalSince(self.lastSignal) >= SyncContract.interval {
                    self.signal(force: false)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--integration-smoke") {
            Task { await IntegrationSmoke.run(model: self) }
        }
        #endif
    }

    var isInstalled: Bool {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        var applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
        // User-domain search paths point into the app container under App Sandbox.
        if let user = getpwuid(getuid()) {
            applications.append(URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true))
        }
        return bundle.pathExtension == "app" && applications.contains {
            bundle.deletingLastPathComponent().pathComponents == $0.standardizedFileURL.pathComponents
        }
    }
    private var isIntegrationRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--integration-smoke")
        #else
        return false
        #endif
    }
    func start() async {
        guard !isIntegrationRun else { return }
        providerObserver = NotificationCenter.default.addObserver(forName: .fileProviderDomainDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshProvider() }
        }
        await refreshProvider()
        if account == nil || providerState != .ready || providerError != nil { showSettings() }
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "OpenCloud Sync Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func refreshProvider(allowIntegration: Bool = false) async {
        guard (!isIntegrationRun || allowIntegration), !registering, !disconnecting else { return }
        guard isInstalled else {
            providerError = "Drag OpenCloud Sync into Applications, then launch the installed copy to set up Finder."
            return
        }
        registering = true
        defer { registering = false }
        let expectedID = account?.id
        do {
            let next = try await registration.reconcile(account: account)
            guard account?.id == expectedID else { return }
            let previouslyReady = providerState == .ready
            providerState = next; providerError = nil
            if next == .ready, !previouslyReady { signal(force: true) }
            if next == .needsEnablement, !promptedForEnablement, !isIntegrationRun {
                promptedForEnablement = true
                showSettings()
                showEnablementPrompt = true
            }
        } catch {
            guard account?.id == expectedID else { return }
            // LaunchServices may still be discovering the embedded extension. Domain-change
            // notifications and the periodic check retry registration without shell utilities.
            providerState = account == nil ? .signInRequired : .registering
            providerError = "Finder setup: \(error.localizedDescription)"
        }
    }
    func openProviderSettings() {
        let pane: String
        if #available(macOS 15, *) { pane = "com.apple.LoginItems-Settings.extension" }
        else { pane = "com.apple.ExtensionsPreferences" }
        if let url = URL(string: "x-apple.systempreferences:\(pane)?extensionPointIdentifier=com.apple.fileprovider-nonui"),
           NSWorkspace.shared.open(url) { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
    var providerInstructions: String {
        if #available(macOS 15, *) {
            return "In System Settings → General → Login Items & Extensions → File Providers, turn on OpenCloud Sync."
        }
        return "In System Settings → Privacy & Security → Extensions → File Providers, turn on OpenCloud Sync."
    }
    var stateTitle: String {
        if account == nil { return "Not connected" }
        if providerState == .needsEnablement { return "Enable Finder integration" }
        if providerError != nil { return "Finder setup error" }
        if account?.paused == true { return "Sync paused" }
        if status.message != nil { return "Sync error" }
        if error != nil { return "Action needs attention" }
        if transferText != nil { return "Transferring files…" }
        if status.syncing { return "Checking for changes…" }
        return status.lastSync == nil ? "Connecting to OpenCloud…" : "Sync complete"
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
            actionResult = try catalog.state("actionResult",as: ActionResult.self)
            mappings = try immichAccount.map { try catalog.mediaMappings(for: $0) } ?? []
            recoveryEntries = try catalog.recoveryOperations(); recoveryCount = recoveryEntries.count
            let anchor = try catalog.anchor()
            if browserAnchor != anchor {
                items = try catalog.descendants([ItemRecord.rootID]).filter { $0.kind != .root }.sorted {
                    let left = ($0.remote?.space.name ?? "") + "/" + ($0.remote?.path.joined(separator: "/") ?? "")
                    let right = ($1.remote?.space.name ?? "") + "/" + ($1.remote?.path.joined(separator: "/") ?? "")
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                browserAnchor = anchor
            }
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
    func signIn(server: String, username: String, appToken: String, allowHTTP: Bool) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard isInstalled else { throw SyncError.unsupportedLocation }
            let address = try ServerAddress(server,allowHTTP: allowHTTP)
            let api = OpenCloudAPI(serverURL: address.apiURL,username: username,token: { appToken })
            let user = try await api.user()
            _ = try await api.spaces()
            if let existing = account, existing.serverURL != address.apiURL || existing.userID != user.id {
                throw NSError(domain: "OpenCloudSync",code: 1,userInfo: [NSLocalizedDescriptionKey:"Disconnect the current account before connecting another server or user."])
            }
            let previous = account
            var connected = Account(id: previous?.id ?? UUID().uuidString,serverURL: address.apiURL,userID: user.id,
                displayName: user.displayName ?? username,email: username,sessionID: UUID().uuidString,allowHTTP: allowHTTP)
            connected.paused = previous?.paused ?? false
            try CredentialStore.save(appToken,for: connected)
            do { try SharedStore.save(connected) }
            catch { try? CredentialStore.delete(for: connected); throw error }
            account = connected
            if let previous { try? CredentialStore.delete(for: previous) }
            await refreshProvider(allowIntegration: true)
            signal(force: true)
        } catch { self.error = error.localizedDescription }
    }
    private func catalog() throws -> Catalog {
        guard let account else { throw SyncError.missingAccount }
        if let cached = statusCatalog, cached.accountID == account.id { return cached.catalog }
        let catalog = try Catalog(url: SharedStore.catalogURL(accountID: account.id))
        statusCatalog = (account.id,catalog); return catalog
    }
    func openRecovery(allAccounts: Bool = false) {
        do {
            guard account != nil && !allAccounts else {
                let directories = try FileManager.default.contentsOfDirectory(at: SharedStore.directory,includingPropertiesForKeys: nil)
                    .filter { UUID(uuidString: $0.lastPathComponent) != nil }
                    .map { $0.appendingPathComponent("Recovery",isDirectory: true) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                if !directories.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(directories) }
                return
            }
            let folder = try catalog().localDirectory
            try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { self.error = error.localizedDescription }
    }
    func markRecovered(_ id: String) {
        do { try catalog().finishOperation(id); readStatus() }
        catch { self.error = error.localizedDescription }
    }
    func copyResults() {
        guard let result = actionResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.urls.map(\.absoluteString).joined(separator: "\n"),forType: .string)
    }
    func performAction(_ action: String, ids: Set<String>, albumName: String = "") async {
        busy = true; error = nil
        defer { busy = false; readStatus() }
        do {
            let catalog = try catalog()
            if action == "link" || action == "sharing" {
                guard let account else { throw SyncError.missingAccount }
                let api = OpenCloudAPI(serverURL: account.serverURL,username: account.email,token: { try CredentialStore.read(for: account) })
                var urls: [URL] = []
                for id in ids.sorted() {
                    guard let known = try catalog.item(id).remote else { throw SyncError.unsupported }
                    let file = try await api.properties(space: known.space,path: known.path)
                    guard file.id == known.id else { throw SyncError.conflict }
                    let url = try await action == "link" ? api.createLink(file) : api.webURL(file)
                    urls.append(url)
                    try catalog.setState("actionResult",value: ActionResult(title: "OpenCloud sharing",urls: urls))
                }
            } else {
                guard let optional = immichAccount else { throw SyncError.mediaMappingRequired }
                let api = ImmichAPI(serverURL: optional.serverURL,token: { try CredentialStore.read(for: optional) },apiKey: optional.credentialKind == "apiKey")
                let result = try await MediaActions(remote: api).perform(itemIDs: ids.sorted(),catalog: catalog,mappings: mappings,
                    albumName: action == "album" ? albumName : nil)
                try catalog.setState("actionResult",value: result)
            }
        } catch { self.error = error.localizedDescription }
    }
    func connectImmich(server: String,email: String,password: String,apiKey: String,allowHTTP: Bool,browserSignIn: Bool = false) async {
        busy = true; error = nil
        defer { busy = false }
        var pending: ImmichAPI?
        var adopted = false
        do {
            let address = try ServerAddress(server,allowHTTP: allowHTTP)
            let api = ImmichAPI(serverURL: address.apiURL)
            let token: String, userID: String, name: String, userEmail: String, sessionID: String
            if !apiKey.isEmpty {
                let authenticated = ImmichAPI(serverURL: address.apiURL,token: { apiKey },apiKey: true)
                let user = try await authenticated.identity()
                token = apiKey; userID = user.id; name = user.name; userEmail = user.email; sessionID = UUID().uuidString
            } else {
                let login: SessionLogin
                if browserSignIn {
                    let challenge = try OAuthChallenge()
                    let url = try await api.authorizeOAuth(challenge)
                    let callback = try await browser.authenticate(url)
                    login = try await api.finishOAuth(callback: callback,challenge: challenge)
                } else { login = try await api.login(email: email,password: password) }
                let authenticated = ImmichAPI(serverURL: address.apiURL,token: { login.accessToken })
                pending = authenticated
                guard !login.shouldChangePassword else { throw SyncError.passwordChangeRequired }
                token = login.accessToken; userID = login.userId; name = login.name; userEmail = login.userEmail
                sessionID = try await authenticated.currentSessionID()
            }
            var optional = Account(serverURL: address.apiURL,userID: userID,displayName: name,email: userEmail,sessionID: sessionID,allowHTTP: allowHTTP)
            optional.credentialKind = apiKey.isEmpty ? "session" : "apiKey"
            let previous = immichAccount
            try CredentialStore.save(token,for: optional)
            do { try SharedStore.saveImmich(optional) }
            catch { try? CredentialStore.delete(for: optional); throw error }
            adopted = true; immichAccount = optional
            if previous?.serverURL != optional.serverURL || previous?.userID != optional.userID {
                try catalog().saveMediaMappings([],for: optional); mappings = []
            }
            if let previous {
                if let token = try? CredentialStore.read(for: previous) {
                    try? await ImmichAPI(serverURL: previous.serverURL,token: { token },apiKey: previous.credentialKind == "apiKey").logout()
                }
                try? CredentialStore.delete(for: previous)
            }
            await discoverImmich()
        } catch is CancellationError { if !adopted { try? await pending?.logout() } }
        catch { if !adopted { try? await pending?.logout() }; self.error = error.localizedDescription }
    }
    func disconnectImmich() async {
        guard let optional = immichAccount else { return }
        do {
            try SharedStore.clearImmich(); immichAccount = nil; discovery = nil
            if let token = try? CredentialStore.read(for: optional) {
                try? await ImmichAPI(serverURL: optional.serverURL,token: { token },apiKey: optional.credentialKind == "apiKey").logout()
            }
            try CredentialStore.delete(for: optional)
            try catalog().saveMediaMappings([],for: optional); mappings = []
        } catch { self.error = error.localizedDescription }
    }
    func discoverImmich() async {
        guard let optional = immichAccount else { return }
        do {
            discovery = try await ImmichAPI(serverURL: optional.serverURL,token: { try CredentialStore.read(for: optional) },apiKey: optional.credentialKind == "apiKey").discover()
        } catch { self.error = error.localizedDescription }
    }
    func addMapping(rootID: String, serverPath: String, libraryID: String) {
        do {
            let catalog = try catalog()
            guard let root = try catalog.item(rootID).remote, root.isDirectory else { throw SyncError.mediaMappingRequired }
            let mapping = try MediaMapping(spaceID: root.space.id,cloudRoot: root.path,immichRoot: serverPath,libraryID: libraryID)
            guard let optional = immichAccount else { throw SyncError.mediaMappingRequired }
            let updated = mappings + [mapping]
            try catalog.saveMediaMappings(updated,for: optional); mappings = updated
        } catch { self.error = error.localizedDescription }
    }
    func removeMapping(_ id: String) {
        do {
            guard let optional = immichAccount else { throw SyncError.mediaMappingRequired }
            let updated = mappings.filter { $0.id != id }
            try catalog().saveMediaMappings(updated,for: optional); mappings = updated
        }
        catch { self.error = error.localizedDescription }
    }
    func domain(for account: Account) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(account.id), displayName: "OpenCloud — \(account.displayName)")
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
        guard providerState == .ready else { showSettings(); return }
        guard let account, let manager = NSFileProviderManager(for: domain(for: account)) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            Task { @MainActor [weak self] in
                guard let url else {
                    self?.error = error?.localizedDescription ?? "The Finder location is not ready. Check the extension is enabled in System Settings."
                    return
                }
                guard url.startAccessingSecurityScopedResource() else {
                    self?.error = "The Finder location could not be opened. Open Finder and select OpenCloud under Locations."
                    return
                }
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    url.stopAccessingSecurityScopedResource()
                    if let error {
                        Task { @MainActor [weak self] in self?.error = error.localizedDescription }
                    }
                }
            }
        }
    }
    func openWeb() {
        guard let server = account?.serverURL else { return }
        NSWorkspace.shared.open(server)
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
        busy = true; disconnecting = true
        defer { busy = false; disconnecting = false }
        // Finish any in-flight registration before removal, so a delayed add cannot
        // recreate the location after credentials have been deleted.
        while registering { try? await Task.sleep(for: .milliseconds(50)) }
        do {
            let keptURL: URL? = try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.remove(domain(for: account), mode: .preserveDownloadedUserData) { url, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
                }
            }
            try CredentialStore.delete(for: account)
            try SharedStore.clearAccount()
            self.account = nil; statusCatalog = nil; browserAnchor = nil; items = []; actionResult = nil; status = SyncStatus(); error = nil
            providerState = .signInRequired; providerError = nil; promptedForEnablement = false
            if let keptURL { NSWorkspace.shared.activateFileViewerSelecting([keptURL]) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack {
                Label("OpenCloud Sync",systemImage: "cloud.fill").font(.headline)
                Spacer()
                Button(action: model.showSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain)
            }
            Label(model.stateTitle,systemImage: model.stateSymbol)
            if model.account != nil {
                Text("\(model.status.fileCount) files · \(model.status.folderCount) folders").font(.caption).foregroundStyle(.secondary)
                if let date = model.status.lastSync { Text("Last checked \(date.formatted(.relative(presentation: .named)))").font(.caption) }
            }
            if let error = model.error ?? model.status.message { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let transfer = model.transferText { ProgressView(value: model.transferFraction); Text(transfer).font(.caption) }
            if let result = model.actionResult {
                Text(result.title).font(.caption)
                HStack {
                    Button("Copy links",action: model.copyResults)
                    if let url = result.urls.first { Link("Open result",destination: url) }
                }
            }
            if model.recoveryCount > 0 { Button("Recovery: \(model.recoveryCount) pending operations",action: { model.openRecovery() }) }
            if model.account != nil {
                Button("Open in Finder",action: model.openFinder).buttonStyle(.borderedProminent)
                HStack {
                    Button("Sync now") { model.signal(force: true) }.disabled(model.account?.paused == true)
                    Button(model.account?.paused == true ? "Resume" : "Pause",action: model.togglePause)
                }
                Button("Sharing and media actions…",action: model.showSettings)
            } else { Button("Connect to OpenCloud",action: model.showSettings).buttonStyle(.borderedProminent) }
            if model.account == nil { Button("Open retained Recovery folders",action: { model.openRecovery() }) }
            Divider()
            HStack {
                if model.account != nil { Button("OpenCloud on the web",action: model.openWeb) }
                Spacer(); Button("Quit") { NSApplication.shared.terminate(nil) }
            }.font(.caption)
        }.padding(20).frame(width: 380).task { model.readStatus() }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var server = ""
    @State private var username = ""
    @State private var appToken = ""
    @State private var allowHTTP = false
    @State private var confirmDisconnect = false
    @State private var immichServer = ""
    @State private var immichEmail = ""
    @State private var immichPassword = ""
    @State private var immichKey = ""
    @State private var immichHTTP = false
    @State private var rootID = ""
    @State private var serverPath = ""
    @State private var libraryID = ""
    @State private var selection: Set<String> = []
    @State private var albumName = "Finder selection"
    @State private var search = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 20) {
                Label("OpenCloud Sync Settings",systemImage: "cloud.fill").font(.title2.bold())
                if model.providerState != .ready {
                    GroupBox("Finder integration") {
                        VStack(alignment: .leading,spacing: 8) {
                            Text(model.providerInstructions)
                            if let error = model.providerError { Text(error).foregroundStyle(.orange) }
                            HStack {
                                Button("Open System Settings",action: model.openProviderSettings)
                                Button("Check again") { Task { await model.refreshProvider() } }
                            }
                        }.padding(8)
                    }
                }
                GroupBox("OpenCloud connection") {
                    VStack(alignment: .leading,spacing: 10) {
                        TextField("https://cloud.example.com",text: $server)
                        TextField("Username (or identity-provider UUID)",text: $username)
                        SecureField("OpenCloud app token",text: $appToken)
                        Toggle("Allow HTTP for this server",isOn: $allowHTTP)
                        Text("Create a dedicated app token in OpenCloud → Settings → App Tokens. The token is saved with owner-only permissions on this Mac.").font(.caption).foregroundStyle(.secondary)
                        Button(model.account == nil ? "Connect" : "Reconnect") {
                            Task { await model.signIn(server: server,username: username,appToken: appToken,allowHTTP: allowHTTP); appToken = "" }
                        }.disabled(model.busy || server.isEmpty || username.isEmpty || appToken.isEmpty).buttonStyle(.borderedProminent)
                    }.padding(8)
                }
                if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if model.account != nil {
                    GroupBox("Files and sharing") {
                        VStack(alignment: .leading,spacing: 10) {
                            Text("Select files or folders. OpenCloud links are read-only. Sharing permissions can be managed on the server. Finder offers the same actions; results appear in the menu bar app.").font(.caption)
                            TextField("Filter server paths",text: $search)
                            List(selection: $selection) {
                                ForEach(model.items.filter { search.isEmpty || label($0).localizedCaseInsensitiveContains(search) },id: \.id) { item in
                                    Label(label(item),systemImage: item.isFolder ? "folder" : "doc").tag(item.id)
                                }
                            }.frame(height: 180)
                            HStack {
                                Button("Create OpenCloud links") { Task { await model.performAction("link",ids: selection) } }
                                Button("Manage sharing") { Task { await model.performAction("sharing",ids: selection) } }
                            }.disabled(selection.isEmpty || model.busy)
                            if let result = model.actionResult {
                                Text(result.title).font(.caption)
                                ForEach(result.urls,id: \.self) { url in Link(url.absoluteString,destination: url).font(.caption).textSelection(.enabled) }
                                Button("Copy links",action: model.copyResults)
                            }
                        }.padding(8)
                    }
                    GroupBox("Immich media actions (optional)") {
                        VStack(alignment: .leading,spacing: 10) {
                            Text("Immich supplies albums and media sharing for existing indexed assets. Files continue to sync through OpenCloud when Immich is disconnected. No native Immich copies are uploaded.").font(.caption)
                            if let optional = model.immichAccount {
                                Text("Connected: \(optional.displayName)")
                                HStack {
                                    Button("Discover libraries and paths") { Task { await model.discoverImmich() } }
                                    Button("Disconnect Immich") { Task { await model.disconnectImmich() } }
                                }
                            } else {
                                TextField("Immich server URL",text: $immichServer)
                                TextField("Immich email",text: $immichEmail)
                                SecureField("Immich password",text: $immichPassword)
                                SecureField("Or Immich API key",text: $immichKey)
                                Toggle("Allow HTTP for Immich",isOn: $immichHTTP)
                                HStack {
                                    Button("Connect Immich") {
                                        Task { await model.connectImmich(server: immichServer,email: immichEmail,password: immichPassword,apiKey: immichKey,allowHTTP: immichHTTP); immichPassword = ""; immichKey = "" }
                                    }.disabled(model.busy || immichServer.isEmpty || (immichKey.isEmpty && (immichEmail.isEmpty || immichPassword.isEmpty)))
                                    Button("Immich browser sign-in") {
                                        Task { await model.connectImmich(server: immichServer,email: "",password: "",apiKey: "",allowHTTP: immichHTTP,browserSignIn: true) }
                                    }.disabled(model.busy || immichServer.isEmpty)
                                }
                            }
                            if let discovery = model.discovery {
                                Text(discovery.explanation).font(.caption)
                                ForEach(discovery.libraries,id: \.id) { library in
                                    Text("\(library.name) [\(library.id)]\nImport roots: \(library.importPaths.joined(separator: ", "))\nExclusions: \(library.exclusionPatterns.joined(separator: ", "))").font(.caption).textSelection(.enabled)
                                }
                                if !discovery.samplePaths.isEmpty {
                                    DisclosureGroup("Sample indexed paths") { Text(discovery.samplePaths.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                                }
                            }
                            if model.immichAccount != nil {
                                Text("Media root mappings").font(.headline)
                                ForEach(model.mappings) { mapping in
                                    HStack {
                                        Text("\(spaceName(mapping.spaceID))/\(mapping.cloudRoot.joined(separator: "/")) → \(mapping.immichRoot)\nLibrary: \(mapping.libraryID ?? "any accessible library")").font(.caption).textSelection(.enabled)
                                        Spacer(); Button("Remove") { model.removeMapping(mapping.id) }
                                    }
                                }
                                Picker("OpenCloud media folder",selection: $rootID) {
                                    Text("Choose a folder…").tag("")
                                    ForEach(model.items.filter(\.isFolder),id: \.id) { item in Text(label(item)).tag(item.id) }
                                }
                                TextField("Exact server/container path corresponding to this folder",text: $serverPath)
                                TextField("Immich library ID (optional)",text: $libraryID)
                                Button("Add confirmed mapping") { model.addMapping(rootID: rootID,serverPath: serverPath,libraryID: libraryID) }.disabled(rootID.isEmpty || serverPath.isEmpty)
                                Text("Add one mapping per indexed subtree or container mount. Paths are matched exactly and case-sensitively. No suffix matching is used. Folder actions include indexed descendants and report skipped files; explicitly selected unindexed files produce an error.").font(.caption).foregroundStyle(.secondary)
                                TextField("New Immich album name",text: $albumName)
                                HStack {
                                    Button("Create Immich album from selection") { Task { await model.performAction("album",ids: selection,albumName: albumName) } }.disabled(albumName.isEmpty)
                                    Button("Create Immich sharing link") { Task { await model.performAction("immichLink",ids: selection) } }
                                }.disabled(selection.isEmpty || model.busy)
                            }
                        }.padding(8)
                    }
                    GroupBox("Availability and recovery") {
                        VStack(alignment: .leading,spacing: 8) {
                            Text("Finder downloads files when opened. Use Always keep available on a file or folder to keep it offline, Make available on demand to allow eviction, or inherit the parent folder’s policy.")
                            Text("OpenCloud owns files, revisions, and conflicts. Rejected or interrupted edits remain in Finder and in Recovery. Copy recovered files to a new name to resolve a conflict. Recovery manifests describe pending operations.").font(.caption)
                            Button("Open Recovery (\(model.recoveryCount) pending operations)",action: { model.openRecovery() })
                            Button("Open all retained Recovery folders") { model.openRecovery(allAccounts: true) }
                            ForEach(model.recoveryEntries,id: \.id) { entry in
                                HStack {
                                    Text(entry.filename).font(.caption)
                                    Spacer()
                                    Button("Mark resolved; keep recovery files") { model.markRecovered(entry.id) }
                                }
                            }
                        }.padding(8)
                    }
                    Toggle("Open OpenCloud Sync at login",isOn: Binding(get: { model.launchAtLogin },set: { enabled in model.setLogin(enabled) }))
                    Button("Disconnect OpenCloud…",role: .destructive) { confirmDisconnect = true }.disabled(model.busy)
                    Text("Downloaded and unsynced files are kept on this Mac. Recovery is retained. Revoke this app token separately in OpenCloud Settings.").font(.caption).foregroundStyle(.secondary)
                }
                if model.busy { ProgressView() }
            }.textFieldStyle(.roundedBorder).padding(24)
        }.frame(width: 720,height: 780)
            .onAppear { server = model.account?.serverURL.absoluteString ?? ""; username = model.account?.email ?? ""; allowHTTP = model.account?.allowHTTP ?? false; model.readStatus() }
            .alert("Enable OpenCloud Sync in Finder",isPresented: $model.showEnablementPrompt) {
                Button("Open System Settings",action: model.openProviderSettings); Button("Not now",role: .cancel) {}
            } message: { Text(model.providerInstructions) }
            .confirmationDialog("Disconnect OpenCloud? Downloaded and unsynced files will be kept on this Mac.",isPresented: $confirmDisconnect) {
                Button("Disconnect",role: .destructive) { Task { await model.disconnect() } }
            }
    }
    private func spaceName(_ id: String) -> String { model.items.first { $0.kind == .space && $0.remote?.space.id == id }?.filename ?? id }
    private func label(_ item: ItemRecord) -> String {
        guard let remote = item.remote else { return item.filename }
        return remote.space.name + (remote.path.isEmpty ? "" : "/" + remote.path.joined(separator: "/"))
    }
}
