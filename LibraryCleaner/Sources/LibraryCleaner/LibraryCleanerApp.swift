import SwiftUI
import Foundation

// MARK: - Model

struct DirEntry: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let sizeKB: Double

    var sizeGB: Double { sizeKB / 1_048_576 }
    var name: String { (path as NSString).lastPathComponent }
}

private let oneGB: Double = 1_048_576
private let fiveGB: Double = 5_242_880
private let tenGB: Double = 10_485_760

func sizeColor(for kb: Double) -> Color {
    if kb >= tenGB { return .red }
    if kb >= fiveGB { return .yellow }
    return .green
}

// Small heads-up for well-known directories whose contents are easy to
// mistake for junk but actually back real, hard-to-regenerate data.
private let knownWarnings: [(keyword: String, message: String)] = [
    ("docker", "This may delete Docker images, containers, and volumes."),
    ("com.docker", "This may delete Docker images, containers, and volumes."),
    ("mobilesync", "This may delete iOS/iPadOS device backups."),
    ("backup", "This may delete backup data."),
    ("cloudkit", "This may delete iCloud-synced app data."),
    ("com.apple.mail", "This may delete Mail messages/attachments."),
    ("messages", "This may delete Messages history/attachments."),
    ("photos", "This may delete Photos library data."),
    ("derived", "Xcode build cache. Safe to delete, Xcode will rebuild it."),
    ("caches", "This is a cache folder. Usually safe, the app will rebuild it."),
]

func warningMessage(for path: String) -> String? {
    let lower = path.lowercased()
    for (keyword, message) in knownWarnings where lower.contains(keyword) {
        return message
    }
    return nil
}

// MARK: - Scanning

func scanDir(_ root: String) -> [DirEntry] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    process.arguments = ["-kd", "1", root]

    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return []
    }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var entries: [DirEntry] = []
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2, let kb = Double(parts[0]) else { continue }
        let path = String(parts[1])
        if path == root { continue }
        if kb <= oneGB { continue }
        entries.append(DirEntry(path: path, sizeKB: kb))
    }
    return entries.sorted { $0.sizeKB > $1.sizeKB }
}

// MARK: - Row

struct DirRow: View {
    let entry: DirEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.path)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let warning = warningMessage(for: entry.path) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            Text(String(format: "%.2f GB", entry.sizeGB))
                .font(.system(.body, design: .monospaced).bold())
                .foregroundColor(sizeColor(for: entry.sizeKB))
                .frame(width: 90, alignment: .trailing)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Content View

struct ContentView: View {
    @State private var libraryEntries: [DirEntry] = []
    @State private var appSupportEntries: [DirEntry] = []
    @State private var isScanning = false

    @State private var entryPendingDelete: DirEntry?
    @State private var showConfirm = false

    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library Cleanup")
                    .font(.title2.bold())
                Spacer()
                Button(action: scan) {
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)
            }
            .padding()

            List {
                Section("Library (> 1 GB)") {
                    section(libraryEntries)
                }
                Section("Application Support (> 1 GB)") {
                    section(appSupportEntries)
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 680, minHeight: 500)
        .onAppear(perform: scan)
        .alert(
            "Delete this folder?",
            isPresented: $showConfirm,
            presenting: entryPendingDelete
        ) { entry in
            Button("Delete", role: .destructive) { performDelete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(confirmMessage(for: entry))
        }
        .alert("Delete Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error.")
        }
    }

    @ViewBuilder
    private func section(_ entries: [DirEntry]) -> some View {
        if entries.isEmpty {
            Text("No directories larger than 1 GB.")
                .foregroundColor(.secondary)
        } else {
            ForEach(entries) { entry in
                DirRow(entry: entry) {
                    entryPendingDelete = entry
                    showConfirm = true
                }
            }
        }
    }

    private func scan() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let home = NSHomeDirectory()
            let lib = scanDir(home + "/Library")
            let appSupport = scanDir(home + "/Library/Application Support")
            DispatchQueue.main.async {
                self.libraryEntries = lib
                self.appSupportEntries = appSupport
                self.isScanning = false
            }
        }
    }

    private func confirmMessage(for entry: DirEntry) -> String {
        var message = "\(entry.path)\n\nSize: \(String(format: "%.2f", entry.sizeGB)) GB\n\nThis cannot be undone."
        if let warning = warningMessage(for: entry.path) {
            message += "\n\n⚠️ \(warning)"
        }
        return message
    }

    private func performDelete(_ entry: DirEntry) {
        do {
            try FileManager.default.removeItem(atPath: entry.path)
            removeEntry(entry)
        } catch {
            attemptPrivilegedDelete(entry)
        }
    }

    private func removeEntry(_ entry: DirEntry) {
        libraryEntries.removeAll { $0.id == entry.id }
        appSupportEntries.removeAll { $0.id == entry.id }
    }

    private func attemptPrivilegedDelete(_ entry: DirEntry) {
        let escaped = entry.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        do shell script "rm -rf " & quoted form of "\(escaped)" with administrator privileges
        """

        guard let script = NSAppleScript(source: source) else {
            errorMessage = "Could not build the delete command for \(entry.name)."
            showError = true
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -128 { return } // user cancelled the admin prompt
            let description = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            errorMessage = "Failed to delete \(entry.name): \(description)"
            showError = true
        } else {
            removeEntry(entry)
        }
    }
}

// MARK: - App

@main
struct LibraryCleanerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
