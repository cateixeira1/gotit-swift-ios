import Foundation

/// Keeps what the user wrote encrypted with a key iOS throws away while the device is locked.
///
/// Left alone, an app's files are protected "until first unlock": readable from the first time
/// the device is unlocked after a restart until the next restart, so also while it is locked and
/// out of its owner's hands. "Complete unless open" closes that: a file can only be opened with
/// the device unlocked, and one already open stays usable (the database, while a save finishes
/// just after the screen locks; a new file can still be created). A file takes the protection of
/// the folder it is created in; one copied in from elsewhere keeps its own, so it is set again.
///
/// Nothing here can fail an edit: where a protection cannot be set, the file stays as it was.
/// No effect in the Simulator or on the Mac, which do not have this kind of protection.
enum DataProtection {
    /// A folder (new files in it are protected from then on) or a file.
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
    }

    /// The notes' folder: itself, the assets folder, and the files directly in it (the database
    /// and its journal files, the recovery queue). Quick enough to run at every start.
    static func protectNotes(at root: URL) {
        protect(root)
        protect(root.appendingPathComponent("assets"))
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] { protect(file) }
    }

    static let sweptKey = "dataProtectionApplied"
    /// Raised when the protection changes, so files written before it are gone over once more.
    static let version = 1

    /// Files that were already there before this protection existed (every stored picture, audio,
    /// video and drawing): gone over once, away from the main thread.
    static func protectExistingFiles(in folders: [URL]) {
        guard UserDefaults.standard.integer(forKey: sweptKey) < version else { return }
        Task.detached(priority: .utility) {
            for folder in folders {
                guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
                while let file = files.nextObject() as? URL { Self.protect(file) }
            }
            UserDefaults.standard.set(Self.version, forKey: Self.sweptKey)
        }
    }
}

/// Temporary files the app makes for itself: a recording in progress, the copy of a video or an
/// audio being imported, reduced or transcribed, an export of strokes, the performance
/// measurement. Each is removed when its work ends; one left behind because the app was closed
/// in the middle would stay (with what was recorded in it) until iOS decided to clear the
/// folder. Nothing of the app's uses these files across launches, so at start the ones made
/// before this launch go. Files made by iOS itself (a model download in progress, which it
/// continues from here) are not touched.
enum TemporaryFiles {
    /// When this run of the app began (read as the app starts, see `GotItAppApp.init`).
    static let launch = Date()

    static func isOurs(_ name: String) -> Bool {
        if ["gravacao-", "GotIt-tracos-", "gotit-medicao-"].contains(where: { name.hasPrefix($0) }) { return true }
        // Copies named by a UUID, with or without an extension.
        return UUID(uuidString: String(name.prefix(36))) != nil && (name.count == 36 || name.dropFirst(36).first == ".")
    }

    static func removeLeftovers(in folder: URL = FileManager.default.temporaryDirectory) {
        // Listed now, while nothing has started yet, and only what was made before this launch:
        // a file of this run is never in the list.
        let start = Self.launch
        let leftovers = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { file in
            guard isOurs(file.lastPathComponent), let made = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return false }
            return made < start
        }
        guard !leftovers.isEmpty else { return }
        Task.detached(priority: .utility) {
            for file in leftovers { try? FileManager.default.removeItem(at: file) }
        }
    }
}
