import Foundation

struct PatchStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    var messageArgument: String?

    init(titleKey: String, messageKey: String, messageArgument: String? = nil) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.messageArgument = messageArgument
    }

    func message(language: AppLanguage) -> String {
        if let messageArgument {
            return language.text(messageKey, messageArgument)
        }
        return language.text(messageKey)
    }
}

@MainActor
final class PatchProjectStore: ObservableObject {
    @Published private(set) var items: [PatchLibraryItem] = []
    @Published private(set) var isBusy = false
    @Published var passwordRequest: PatchPasswordRequest?
    @Published var alert: PatchStoreAlert?
    @Published var unlockErrorKey: String?

    private struct PendingUnlock {
        let data: Data
        let summary: PatchPackageSummary
        let existingURL: URL?
        let origin: PatchPackageOrigin?
    }

    private var pendingUnlock: PendingUnlock?

    init() {
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            Self.importBundledPackagesIfNeeded()
            let loadedItems = PatchProjectLibrary.load()
            await self?.finishInitialLoad(loadedItems)
            await Self.syncPackagesFromGitHub()
            await self?.reload()
        }
    }

    /// MATINO X: switch for the live repository sync. When enabled the app
    /// mirrors BundledFiles/ from GitHub on launch, so files added or removed
    /// through the site show up in Installed without reinstalling the IPA.
    private static let remoteSyncEnabled = true
    private static let remoteRepo = "tff68484-lab/matino-x"
    private static let remoteDirectory = "BundledFiles"
    private static let remoteTrackedKey = "patch.remote_bundled_files"

    private struct RemotePackage: Decodable {
        let name: String
        let type: String
        let size: Int
        let downloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name, type, size
            case downloadURL = "download_url"
        }
    }

    private nonisolated static func remotePackageList() async -> [RemotePackage]? {
        guard remoteSyncEnabled,
              let url = URL(string: "https://api.github.com/repos/\(remoteRepo)/contents/\(remoteDirectory)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode([RemotePackage].self, from: data)
    }

    /// Downloads every .3105 currently held in the repository and drops the
    /// ones the repository no longer holds. Packages that ship inside the app
    /// bundle win over the remote copy, and packages the user imported by hand
    /// are never tracked here, so they are never deleted.
    private nonisolated static func syncPackagesFromGitHub() async {
        guard remoteSyncEnabled else { return }
        guard let listing = await remotePackageList() else { return }
        guard let root = try? PatchProjectLibrary.packageRootURL() else { return }

        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let previouslyTracked = Set(defaults.stringArray(forKey: remoteTrackedKey) ?? [])
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bundled = Set(((try? fm.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".3105") })

        var current = Set<String>()
        for package in listing
        where package.type == "file", package.name.lowercased().hasSuffix(".3105") {
            current.insert(package.name)
            // The bundle already carries this file: the local sync owns it.
            guard !bundled.contains(package.name) else { continue }
            guard let source = package.downloadURL else { continue }

            let destination = root.appendingPathComponent(package.name)
            let localSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard !fm.fileExists(atPath: destination.path) || localSize != package.size else { continue }

            guard let (data, response) = try? await URLSession.shared.data(from: source),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count == package.size else { continue }

            try? fm.removeItem(at: destination)
            try? data.write(to: destination, options: .atomic)
        }

        // Mirror deletions: anything we synced before that the repository (and
        // the app bundle) no longer holds is removed from Installed.
        for name in previouslyTracked.subtracting(current).subtracting(bundled) {
            let stale = root.appendingPathComponent(name)
            if fm.fileExists(atPath: stale.path) {
                try? fm.removeItem(at: stale)
            }
        }

        defaults.set(Array(current), forKey: remoteTrackedKey)
    }

    /// MATINO X: files placed in BundledFiles/ end up in the app bundle.
    /// Sync every bundled .3105 package into the library on launch so files
    /// added later (via the site/bot) show up in Installed without a manual
    /// import step. Existing copies are refreshed when the bundle is newer.
    private nonisolated static func importBundledPackagesIfNeeded() {
        let fm = FileManager.default
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let names = (try? fm.contentsOfDirectory(atPath: resources.path)) ?? []
        guard let root = try? PatchProjectLibrary.packageRootURL(fileManager: fm) else { return }

        let defaults = UserDefaults.standard
        let trackedKey = "patch.imported_bundled_files"
        let previouslyTracked = Set(defaults.stringArray(forKey: trackedKey) ?? [])
        let bundled = Set(names.filter { $0.lowercased().hasSuffix(".3105") })

        func modificationDate(_ url: URL) -> Date {
            (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }

        for name in bundled {
            let source = resources.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = root.appendingPathComponent(name)
            let shouldCopy = !fm.fileExists(atPath: destination.path)
                || modificationDate(source) > modificationDate(destination)
            if shouldCopy {
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                try? fm.copyItem(at: source, to: destination)
            }
        }

        // Drop copies that we imported earlier but that are no longer bundled.
        // Only files we tracked as bundle-sourced are removed, so packages the
        // user imported by hand are left alone.
        for name in previouslyTracked.subtracting(bundled) {
            let stale = root.appendingPathComponent(name)
            if fm.fileExists(atPath: stale.path) {
                try? fm.removeItem(at: stale)
            }
        }

        defaults.set(Array(bundled), forKey: trackedKey)
    }

    func reload() {
        items = PatchProjectLibrary.load()
    }

    private func finishInitialLoad(_ loadedItems: [PatchLibraryItem]) {
        items = loadedItems
        isBusy = false
    }

    func create(project: PatchProject, password: String?) {
        runOperation(successMessageKey: "patch.created_message") {
            let encoded = try PatchPackageCodec.encodeNew(project: project, password: password)
            let summary = try PatchPackageCodec.inspect(encoded.data)
            let workspace = try PatchWorkspaceService.createWorkspace(for: project)
            var savedURL: URL?
            do {
                if summary.isPasswordProtected {
                    try PatchKeyStore.store(encoded.contentKey, for: summary)
                }
                savedURL = try PatchProjectLibrary.save(
                    data: encoded.data,
                    projectName: project.name
                )
                try PatchProjectLibrary.markAsAuthorCopy(packageID: project.id)
            } catch {
                try? FileManager.default.removeItem(at: workspace)
                if let savedURL {
                    try? FileManager.default.removeItem(at: savedURL)
                }
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
        }
    }

    func update(project: PatchProject) {
        guard let item = items.first(where: { $0.id == project.id }),
              let contentKey = item.contentKey else {
            present(.invalidProject)
            return
        }
        runOperation(successMessageKey: "patch.updated_message") {
            let original = try PatchProjectLibrary.readPackage(at: item.packageURL)
            let updated = try PatchPackageCodec.update(
                original,
                project: project,
                contentKey: contentKey,
                schemaVersion: PatchPackageCodec.latestSchemaVersion
            )
            _ = try PatchProjectLibrary.save(
                data: updated,
                projectName: project.name,
                existingURL: item.packageURL
            )
        }
    }

    func importPackage(at sourceURL: URL) {
        guard !isBusy else { return }
        isBusy = true
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try PatchProjectLibrary.readPackage(at: sourceURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.unsupportedFormat)
            }
        }
    }

    @discardableResult
    func importPackage(
        data: Data,
        password: String? = nil,
        origin: PatchPackageOrigin? = nil
    ) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL,
                    password: password,
                    origin: origin
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.unsupportedFormat)
            }
        }
        return true
    }

    func presentImportError(_ error: PatchPackageError) {
        present(error)
    }

    func importPackage(from source: PatchImportSource) {
        switch source {
        case .file(let url):
            importPackage(at: url)
        case .remote(let url):
            importPackage(fromRemoteURL: url)
        case .invalid:
            present(.invalidImportLink)
        }
    }

    private func importPackage(fromRemoteURL remoteURL: URL) {
        guard !isBusy,
              PatchImportRoute.validatedRemoteURL(remoteURL) != nil else {
            if !isBusy { present(.invalidImportLink) }
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }

                let (temporaryURL, response) = try await session.download(from: remoteURL)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let finalURL = response.url,
                      PatchImportRoute.validatedRemoteURL(finalURL) != nil else {
                    throw PatchPackageError.remoteImportFailed
                }

                let data = try PatchProjectLibrary.readPackage(at: temporaryURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.remoteImportFailed)
            }
        }
    }

    func requestUnlock(for item: PatchLibraryItem) {
        guard item.isLocked, !isBusy else { return }
        do {
            let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
            pendingUnlock = PendingUnlock(
                data: data,
                summary: item.summary,
                existingURL: item.packageURL,
                origin: item.origin
            )
            passwordRequest = PatchPasswordRequest(
                summary: item.summary,
                origin: item.origin
            )
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.unsupportedFormat)
        }
    }

    func unlock(password: String) {
        guard let pending = pendingUnlock, !isBusy else { return }
        isBusy = true
        unlockErrorKey = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let decoded = try PatchPackageCodec.decode(pending.data, password: password)
                try PatchKeyStore.store(decoded.contentKey, for: pending.summary)
                do {
                    try PatchProjectLibrary.installImportedPackage(
                        data: pending.data,
                        decoded: decoded,
                        summary: pending.summary,
                        existingURL: pending.existingURL,
                        origin: pending.origin
                    )
                } catch {
                    try? PatchKeyStore.delete(for: pending.summary)
                    throw error
                }
                await self?.clearPendingUnlock()
                await self?.finishOperation(successMessageKey: "patch.unlocked_message")
            } catch let error as PatchPackageError {
                await self?.failUnlock(error)
            } catch {
                await self?.failUnlock(.invalidPasswordOrCorruptedPackage)
            }
        }
    }

    func cancelUnlock() {
        clearPendingUnlock()
        isBusy = false
    }

    func clearUnlockError() {
        unlockErrorKey = nil
    }

    func delete(_ item: PatchLibraryItem) {
        do {
            try PatchProjectLibrary.delete(item)
            reload()
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.invalidProject)
        }
    }

    func synchronizeWorkspace(projectID: UUID, reportsSuccess: Bool = false) {
        guard let item = items.first(where: { $0.id == projectID }),
              item.summary.schemaVersion >= 2,
              !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                await self?.finishWorkspaceSynchronization(reportsSuccess: reportsSuccess)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.invalidProject)
            }
        }
    }

    private func finishWorkspaceSynchronization(reportsSuccess: Bool) {
        reload()
        isBusy = false
        if reportsSuccess {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.workspace_synced_message"
            )
        }
    }

    private func runOperation(
        successMessageKey: String,
        operation: @escaping () throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try operation()
                await self?.finishOperation(successMessageKey: successMessageKey)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.invalidProject)
            }
        }
    }

    private func requestPassword(pending: PendingUnlock) {
        pendingUnlock = pending
        passwordRequest = PatchPasswordRequest(
            summary: pending.summary,
            origin: pending.origin
        )
        isBusy = false
    }

    private func existingPackageURL(for packageID: UUID) -> URL? {
        items.first(where: { $0.id == packageID })?.packageURL
    }

    private nonisolated static func persistImportedPackage(
        data: Data,
        summary: PatchPackageSummary,
        existingURL: URL?,
        password: String? = nil,
        origin: PatchPackageOrigin? = nil
    ) throws -> PendingUnlock? {
        if let key = try PatchKeyStore.load(for: summary) {
            let decoded = try PatchPackageCodec.decode(data, contentKey: key)
            try PatchProjectLibrary.installImportedPackage(
                data: data,
                decoded: decoded,
                summary: summary,
                existingURL: existingURL,
                origin: origin
            )
            return nil
        }
        if summary.isPasswordProtected {
            guard let password else {
                return PendingUnlock(
                    data: data,
                    summary: summary,
                    existingURL: existingURL,
                    origin: origin
                )
            }
            let decoded = try PatchPackageCodec.decode(data, password: password)
            try PatchKeyStore.store(decoded.contentKey, for: summary)
            do {
                try PatchProjectLibrary.installImportedPackage(
                    data: data,
                    decoded: decoded,
                    summary: summary,
                    existingURL: existingURL,
                    origin: origin
                )
            } catch {
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
            return nil
        }
        let decoded = try PatchPackageCodec.decode(data, password: nil)
        try PatchProjectLibrary.installImportedPackage(
            data: data,
            decoded: decoded,
            summary: summary,
            existingURL: existingURL,
            origin: origin
        )
        return nil
    }

    private func clearPendingUnlock() {
        pendingUnlock = nil
        passwordRequest = nil
        unlockErrorKey = nil
    }

    private func finishOperation(successMessageKey: String) {
        reload()
        isBusy = false
        alert = PatchStoreAlert(titleKey: "common.done", messageKey: successMessageKey)
    }

    private func failOperation(_ error: PatchPackageError) {
        isBusy = false
        present(error)
    }

    private func failUnlock(_ error: PatchPackageError) {
        isBusy = false
        // Keep the password sheet open so the user can retry.
        // Presenting an alert while dismissing the sheet swallows the message.
        if case .invalidPasswordOrCorruptedPackage = error {
            unlockErrorKey = "patch.error.wrong_password"
        } else {
            unlockErrorKey = error.localizationKey
        }
    }

    private func present(_ error: PatchPackageError) {
        alert = PatchStoreAlert(
            titleKey: "common.failed",
            messageKey: error.localizationKey,
            messageArgument: error.localizationArgument
        )
    }
}
