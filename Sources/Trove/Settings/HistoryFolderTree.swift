import SwiftUI

/// What Trove writes in the chosen location, as a small folder tree:
///
///     📁 Notes                ~/Seafile/Notes
///        └ 📁 Trove History   Trove creates it
///             └ encrypted database · Images · key file
///
/// With "own folder" off, the files sit directly in the chosen location. Shown in onboarding and
/// in Settings › Storage, so nobody is surprised by a folder inside their folder.
struct HistoryFolderTree: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings

    private var chosen: Bool { app.store != nil }
    private var ownFolder: Bool { app.usesHistoryFolder }
    private var location: URL { StorageLocation.location(of: app.storageDirectory) }
    /// The real folder name: histories made before the rename use "Clipboard History".
    private var folderName: String {
        chosen && ownFolder ? app.storageDirectory.lastPathComponent : StorageLocation.historyFolderName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: chosen ? "folder.fill" : "folder.badge.questionmark")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(verbatim: chosen ? location.lastPathComponent : L("The folder you choose"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if chosen {
                    Text(verbatim: StorageLocation.displayPath(location))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if ownFolder {
                branch(level: 1) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).frame(width: 18)
                    Text(verbatim: folderName).font(.system(size: 12.5, weight: .medium))
                    Text("Trove creates it")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            branch(level: ownFolder ? 2 : 1) {
                Image(systemName: "lock.doc").foregroundStyle(.secondary).frame(width: 18)
                Text("Encrypted database · encrypted images · key file")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: ownFolder)
    }

    /// One row of the tree, indented with a └ line.
    private func branch<Content: View>(level: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            Text(verbatim: "└")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, CGFloat(level - 1) * 25 + 6)
            content()
        }
    }
}

/// The "own folder" switch under the tree, with what each choice means.
struct HistoryFolderToggle: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: Binding(get: { app.usesHistoryFolder }, set: { app.setUsesHistoryFolder($0) })) {
                Text("Keep the history in its own “\(StorageLocation.historyFolderName)” folder")
            }
            .toggleStyle(.checkbox)
            Text(verbatim: app.usesHistoryFolder
                 ? L("Trove’s files stay together, apart from your own files.")
                 : L("Trove’s files go directly into the chosen folder, next to your own files."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
