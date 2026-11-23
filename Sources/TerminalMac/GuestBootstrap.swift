import AppKit
import Darwin
import ServiceManagement
import TerminalMacCore

@MainActor
enum GuestBootstrap {
    /// Kernel-level single-instance fence for the installed guest helper.
    ///
    /// Helpers can start twice in the same login: the SMAppService login item and macOS session
    /// restoration launch copies milliseconds-to-seconds apart, and the self-update path launches a
    /// copy from the shared-tools path. The existing `replaceRunningInstances` deduplicates only
    /// same-path twins and races at startup, so duplicate helpers survive and double-answer the
    /// mailbox (every key press types twice).
    ///
    /// Called after `installAndRelaunchIfNeeded`, so only the installed copy at
    /// `~/Applications/TerminalMacGuest.app` ever holds this lock; the shared-tools updater exits
    /// before reaching it. An instance that cannot acquire the lock within `timeout` exits quietly:
    /// its launch source fired once, so it will not be restarted.
    ///
    /// The retry window covers the self-update handoff, where the previous holder is terminated
    /// (graceful wait ~10s, then SIGKILL) before this copy needs to win the lock.
    static func acquireSingleInstanceLock(timeout: TimeInterval = 15) async throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TerminalMacGuest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("helper.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("Cannot open helper singleton lock: \(String(cString: strerror(errno)))") }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else {
                close(fd)
                throw Failure("Cannot lock helper singleton: \(String(cString: strerror(errno)))")
            }
            guard Date() < deadline else {
                close(fd)
                stderr("Another guest helper already holds the singleton lock; exiting.")
                exit(0)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        // The descriptor is deliberately never closed: the kernel holds the flock for this
        // process's lifetime and releases it on exit, however the helper terminates.
    }

    static func installAndRelaunchIfNeeded() async throws -> Bool {
        try GuestGuard.requireVirtualMac()
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return false }
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let identity = try CodeIdentity()
        try identity.validate(source)
        let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let destination = applications.appendingPathComponent("TerminalMacGuest.app")
        if source == destination.resolvingSymlinksInPath() { return false }
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let installed = Bundle(url: destination)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists, installed?.bundleIdentifier != "dev.terminal-mac.guest" {
            throw Failure("The guest install location is occupied by a different app: \(destination.path)")
        }
        let keys = ["CFBundleVersion", "CFBundleShortVersionString"]
        let needsUpdate = keys.contains { installed?.object(forInfoDictionaryKey: $0) as? String != Bundle.main.object(forInfoDictionaryKey: $0) as? String }
        if !exists || needsUpdate {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.terminal-mac.guest")
                .filter { $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }
            await terminate(running)
            guard running.allSatisfy({ hasExited($0) }) else { throw Failure("Quit the installed guest helper, then reopen this copy to update it") }
            let staging = applications.appendingPathComponent(".TerminalMacGuest-\(UUID().uuidString).app")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            try identity.validate(staging)
            let backup = applications.appendingPathComponent(".TerminalMacGuest-backup-\(UUID().uuidString).app")
            if exists { try FileManager.default.moveItem(at: destination, to: backup) }
            do { try FileManager.default.moveItem(at: staging, to: destination) }
            catch {
                if exists { try? FileManager.default.moveItem(at: backup, to: destination) }
                throw error
            }
            if exists { try? FileManager.default.removeItem(at: backup) }
        }
        // The launched copy replaces any installed helper that is already running (see replaceRunningInstances):
        // two helpers answer every mailbox request twice, so each key press would type two characters.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        return true
    }
    /// Running helpers launched from `bundle`, other than this process.
    static func runningInstalledHelpers(at bundle: URL) -> [NSRunningApplication] {
        let location = bundle.resolvingSymlinksInPath()
        return NSRunningApplication.runningApplications(withBundleIdentifier: "dev.terminal-mac.guest").filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !hasExited($0)
                && $0.bundleURL?.resolvingSymlinksInPath() == location
        }
    }
    /// The installed helper is single-instance, and the newest launch wins: reopening it is how macOS asks users to
    /// pick up a fresh Screen Recording grant, and the helper has no menu bar, so Cmd+Q cannot quit the old one.
    static func replaceRunningInstances() async {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return }
        let twins = runningInstalledHelpers(at: Bundle.main.bundleURL)
        guard !twins.isEmpty else { return }
        await terminate(twins)
    }
    /// `NSRunningApplication.isTerminated` only updates when this process's run loop observes the exit, which
    /// the setup flow cannot rely on, so the kernel is asked directly whether the process still exists.
    static func hasExited(_ application: NSRunningApplication) -> Bool {
        kill(application.processIdentifier, 0) != 0 && errno == ESRCH
    }
    /// Asks the helpers to quit, then kills any that are still around after ten seconds; they hold no unsaved state.
    static func terminate(_ applications: [NSRunningApplication]) async {
        for application in applications { _ = application.terminate() }
        for _ in 0..<200 {
            if applications.allSatisfy({ hasExited($0) }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for application in applications where !hasExited(application) { kill(application.processIdentifier, SIGKILL) }
        for _ in 0..<60 {
            if applications.allSatisfy({ hasExited($0) }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    /// Reads a bundle's version without `Bundle(url:)`, whose per-URL cache keeps returning the Info.plist it saw first.
    static func bundleVersion(at bundle: URL) -> Int? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleVersion"] as? String else { return nil }
        return Int(version)
    }
    /// The installed helper hands over to a newer copy in the shared tools folder, which installs
    /// itself over this one and relaunches. Rebuilding terminal-mac on the host is enough to update the guest.
    static func updateFromSharedTools(_ tools: URL) {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return }
        let shared = tools.appendingPathComponent("TerminalMacGuest.app")
        guard Bundle.main.bundleURL.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath(),
              let newer = bundleVersion(at: shared),
              let running = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""), newer > running else { return }
        do { try CodeIdentity().validate(shared) }
        catch { stderr("Guest helper update refused: \(error.localizedDescription)"); return }
        stderr("Updating the guest helper from build \(running) to \(newer)…")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: shared, configuration: configuration) { _, error in
            if let error { stderr("Guest helper update: \(error.localizedDescription)") }
        }
    }
    static func registerForGuestLogin() {
        guard Bundle.main.bundleIdentifier == "dev.terminal-mac.guest" else { return }
        // Register the login item only from the installed copy. Guided setup has the user open
        // TerminalMacGuest.app from the shared tools volume first; registering from that path
        // pins the login item there, so every login the shared copy re-installs itself over
        // ~/Applications (clobbering any newer installed helper) and launches beside the
        // destination copy — duplicate instances. Registration from any other path is skipped;
        // the installed copy registers itself on its next start.
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/TerminalMacGuest.app")
        guard Bundle.main.bundleURL.resolvingSymlinksInPath() == installed.resolvingSymlinksInPath() else { return }
        let preferences = UserDefaults.standard
        guard !preferences.bool(forKey: "requestedGuestLoginItem") else { return }
        do {
            try SMAppService.mainApp.register()
            preferences.set(true, forKey: "requestedGuestLoginItem")
        } catch { stderr("Guest login item: \(error.localizedDescription). You can enable it in the guest's Login Items settings.") }
    }
}
