import Foundation

enum StorageLocation {
    static let historyFolderName = "Clipboard History"

    /// The folder that holds the history for a location the user picked.
    /// A picked folder that already holds history, or is itself named "Clipboard History", is used as is.
    /// Any other location gets a "Clipboard History" folder inside it.
    static func historyFolder(for picked: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        if picked.lastPathComponent == historyFolderName
            || fileExists(picked.appendingPathComponent(Store.databaseFileName).path) {
            return picked
        }
        return picked.appendingPathComponent(historyFolderName, isDirectory: true)
    }

    /// Inside the sandbox container: ~/Library/Containers/<bundle id>/Data/Library/Application Support/Clipboard
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    /// The real home folder. Inside the sandbox, NSHomeDirectory() returns the container.
    static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = realHome
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The sync service that uploads this folder, or nil when it looks local.
    static func syncProvider(for url: URL) -> String? {
        let path = url.standardizedFileURL.path + "/"
        let rules: [(needle: String, name: String)] = [
            ("/Library/Mobile Documents/", "iCloud Drive"),
            ("/Library/CloudStorage/Dropbox", "Dropbox"),
            ("/Library/CloudStorage/GoogleDrive", "Google Drive"),
            ("/Library/CloudStorage/OneDrive", "OneDrive"),
            ("/Library/CloudStorage/Box", "Box"),
            ("/Library/CloudStorage/", "a cloud storage provider"),
            ("/Seafile/", "Seafile"),
            ("/Dropbox/", "Dropbox"),
            ("/Google Drive/", "Google Drive"),
            ("/OneDrive", "OneDrive"),
            ("/Nextcloud/", "Nextcloud"),
            ("/ownCloud/", "ownCloud"),
            ("/pCloud Drive/", "pCloud"),
            ("/Box/", "Box"),
        ]
        return rules.first { path.contains($0.needle) }?.name
    }
}
