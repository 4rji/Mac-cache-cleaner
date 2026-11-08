import Cocoa

// MARK: - Model

struct DirEntry {
    let path: String
    let sizeKB: Double

    var sizeGB: Double { sizeKB / 1_048_576 }
    var name: String { (path as NSString).lastPathComponent }
}

private let oneGB: Double = 1_048_576
private let fiveGB: Double = 5_242_880
private let tenGB: Double = 10_485_760

func sizeColor(for kb: Double) -> NSColor {
    if kb >= tenGB { return .systemRed }
    if kb >= fiveGB { return .systemOrange }
    return .systemGreen
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
        if kb <= 0 { continue }
        entries.append(DirEntry(path: path, sizeKB: kb))
    }
    return entries.sorted { $0.sizeKB > $1.sizeKB }
}

// Size filter options shown in the threshold picker.
let sizeThresholds: [(title: String, minKB: Double)] = [
    ("> 1 GB", oneGB),
    ("> 500 MB", 512_000),
    ("Show All", 0),
]

// MARK: - Action button (carries its own closure, no tag/row bookkeeping)

final class ActionButton: NSButton {
    var handler: (() -> Void)?

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        self.target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}

// MARK: - App Delegate / Window / Table handling

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let libraryTable = NSTableView()
    private let appSupportTable = NSTableView()
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let thresholdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let libraryEmptyLabel = NSTextField(labelWithString: "")
    private let appSupportEmptyLabel = NSTextField(labelWithString: "")

    private var libraryEntriesAll: [DirEntry] = []
    private var appSupportEntriesAll: [DirEntry] = []
    private var minSizeKB: Double = oneGB

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        scan()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: UI construction

    private func buildUI() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library Cleanup"
        window.minSize = NSSize(width: 560, height: 420)
        window.center()

        let content = NSView()
        window.contentView = content

        let titleLabel = NSTextField(labelWithString: "Library Cleanup")
        titleLabel.font = .boldSystemFont(ofSize: 18)

        rescanButton.bezelStyle = .rounded
        rescanButton.target = self
        rescanButton.action = #selector(rescanTapped)

        thresholdPopup.addItems(withTitles: sizeThresholds.map(\.title))
        thresholdPopup.target = self
        thresholdPopup.action = #selector(thresholdChanged)

        let libraryLabel = sectionLabel("Library")
        let appSupportLabel = sectionLabel("Application Support")

        libraryEmptyLabel.textColor = .secondaryLabelColor
        appSupportEmptyLabel.textColor = .secondaryLabelColor

        let librarySection = buildTableSection(table: libraryTable, emptyLabel: libraryEmptyLabel)
        let appSupportSection = buildTableSection(table: appSupportTable, emptyLabel: appSupportEmptyLabel)

        for view in [titleLabel, thresholdPopup, rescanButton, libraryLabel, librarySection, appSupportLabel, appSupportSection] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let pad: CGFloat = 16

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),

            rescanButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            rescanButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            thresholdPopup.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            thresholdPopup.trailingAnchor.constraint(equalTo: rescanButton.leadingAnchor, constant: -8),
            thresholdPopup.widthAnchor.constraint(equalToConstant: 110),

            libraryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            libraryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),

            librarySection.topAnchor.constraint(equalTo: libraryLabel.bottomAnchor, constant: 6),
            librarySection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            librarySection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            appSupportLabel.topAnchor.constraint(equalTo: librarySection.bottomAnchor, constant: 14),
            appSupportLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),

            appSupportSection.topAnchor.constraint(equalTo: appSupportLabel.bottomAnchor, constant: 6),
            appSupportSection.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            appSupportSection.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            appSupportSection.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),

            librarySection.heightAnchor.constraint(equalTo: appSupportSection.heightAnchor),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func buildTableSection(table: NSTableView, emptyLabel: NSTextField) -> NSView {
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.selectionHighlightStyle = .none
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 8, height: 4)

        let pathCol = NSTableColumn(identifier: .init("path"))
        pathCol.title = "Path"
        pathCol.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(pathCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"
        sizeCol.width = 90
        sizeCol.minWidth = 90
        sizeCol.maxWidth = 90
        sizeCol.resizingMask = []
        table.addTableColumn(sizeCol)

        let actionCol = NSTableColumn(identifier: .init("action"))
        actionCol.title = ""
        actionCol.width = 90
        actionCol.minWidth = 90
        actionCol.maxWidth = 90
        actionCol.resizingMask = []
        table.addTableColumn(actionCol)

        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
        ])

        return scroll
    }

    // MARK: Data access helpers

    private func entries(for tableView: NSTableView) -> [DirEntry] {
        let all = tableView === libraryTable ? libraryEntriesAll : appSupportEntriesAll
        return all.filter { $0.sizeKB > minSizeKB }
    }

    private func emptyStateText() -> String {
        let title = sizeThresholds[thresholdPopup.indexOfSelectedItem].title
        return "No directories matching \"\(title)\"."
    }

    private func reloadFiltered() {
        libraryEmptyLabel.stringValue = emptyStateText()
        appSupportEmptyLabel.stringValue = emptyStateText()
        libraryEmptyLabel.isHidden = !entries(for: libraryTable).isEmpty
        appSupportEmptyLabel.isHidden = !entries(for: appSupportTable).isEmpty
        libraryTable.reloadData()
        appSupportTable.reloadData()
    }

    // MARK: Scanning

    @objc private func rescanTapped() { scan() }

    @objc private func thresholdChanged() {
        minSizeKB = sizeThresholds[thresholdPopup.indexOfSelectedItem].minKB
        reloadFiltered()
    }

    private func scan() {
        rescanButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let home = NSHomeDirectory()
            let lib = scanDir(home + "/Library")
            let appSupport = scanDir(home + "/Library/Application Support")
            DispatchQueue.main.async {
                guard let self else { return }
                self.libraryEntriesAll = lib
                self.appSupportEntriesAll = appSupport
                self.reloadFiltered()
                self.rescanButton.isEnabled = true
            }
        }
    }

    // MARK: Delete flow

    private func requestDelete(_ entry: DirEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete this folder?"
        var info = "\(entry.path)\n\nSize: \(String(format: "%.2f", entry.sizeGB)) GB\n\nThis cannot be undone."
        if let warning = warningMessage(for: entry.path) {
            info += "\n\n⚠️ \(warning)"
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(entry)
        }
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
        libraryEntriesAll.removeAll { $0.path == entry.path }
        appSupportEntriesAll.removeAll { $0.path == entry.path }
        reloadFiltered()
    }

    private func attemptPrivilegedDelete(_ entry: DirEntry) {
        let escaped = entry.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        do shell script "rm -rf " & quoted form of "\(escaped)" with administrator privileges
        """

        guard let script = NSAppleScript(source: source) else {
            showError("Could not build the delete command for \(entry.name).")
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -128 { return } // user cancelled the admin prompt
            let description = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            showError("Failed to delete \(entry.name): \(description)")
        } else {
            removeEntry(entry)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Delete Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries(for: tableView).count
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let entry = entries(for: tableView)[row]
        return warningMessage(for: entry.path) != nil ? 40 : 24
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries(for: tableView)[row]
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }

        switch identifier {
        case "path":
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false

            let pathLabel = NSTextField(labelWithString: entry.path)
            pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(pathLabel)
            pathLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            pathLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

            if let warning = warningMessage(for: entry.path) {
                let warnLabel = NSTextField(labelWithString: "⚠️ " + warning)
                warnLabel.font = .systemFont(ofSize: 10)
                warnLabel.textColor = .systemOrange
                warnLabel.lineBreakMode = .byTruncatingTail
                warnLabel.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(warnLabel)
                warnLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                warnLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            return stack

        case "size":
            let label = NSTextField(labelWithString: String(format: "%.2f GB", entry.sizeGB))
            label.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
            label.textColor = sizeColor(for: entry.sizeKB)
            label.alignment = .right
            return label

        case "action":
            let button = ActionButton(title: "Delete")
            button.bezelStyle = .rounded
            button.contentTintColor = .systemRed
            button.handler = { [weak self] in self?.requestDelete(entry) }
            return button

        default:
            return nil
        }
    }
}

// MARK: - Entry point

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
