import AppKit
import Foundation

// Claude Menu Bar Buddy — hardware-free stand-in for the M5Stick Hardware
// Buddy. A PreToolUse hook (~/.config/claude-menubar-buddy/hook.sh) writes
// pending_request.json when Claude Code needs a permission decision; this
// app polls for it, shows Approve/Deny in the menu bar, and writes back
// response_<id>.json for the hook to pick up.

let dirURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/claude-menubar-buddy")
let requestURL = dirURL.appendingPathComponent("pending_request.json")

struct PendingRequest: Decodable {
    let id: String
    let tool: String
    let hint: String
}

func gifMenuItem(named name: String) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let size = NSSize(width: 220, height: 90)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    let imageView = NSImageView(frame: NSRect(x: (size.width - 128) / 2, y: 5, width: 128, height: 64))
    if let url = Bundle.module.url(forResource: name, withExtension: "gif", subdirectory: "Resources"),
       let image = NSImage(contentsOf: url) {
        image.size = NSSize(width: 128, height: 64)
        imageView.image = image
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
    }
    container.addSubview(imageView)
    item.view = container
    return item
}

func statusMenuItem(_ text: String) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.attributedTitle = NSAttributedString(
        string: text,
        attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
    )
    return item
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

func availableSpecies() -> [String] {
    guard let url = Bundle.module.url(forResource: "species", withExtension: "txt", subdirectory: "Resources"),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
        return ["buddy"]
    }
    let names = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    return names.isEmpty ? ["buddy"] : names
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var currentRequestId: String?
    var usage = UsageSnapshot()
    // Belt-and-suspenders against the same request file being seen twice
    // (e.g. the hook writes it again, or a filesystem event fires twice)
    // right after we've already answered it.
    var respondedIds = Set<String>()

    // Built once and reused — menuWillOpen updates these items' text in
    // place rather than swapping statusItem.menu out from under an
    // already-opening menu (which is unsafe / can glitch mid-open).
    var idleMenu: NSMenu!
    var statusLineItem: NSMenuItem!
    var tokensLineItem: NSMenuItem!
    var activityLineItem: NSMenuItem!
    var fiveHourLineItem: NSMenuItem!
    var weeklyLineItem: NSMenuItem!

    var selectedSpecies: String {
        get { UserDefaults.standard.string(forKey: "selectedSpecies") ?? "buddy" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedSpecies") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildIdleMenu()
        setIdle()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func buildIdleMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(gifMenuItem(named: "\(selectedSpecies)_idle"))
        menu.addItem(withTitle: "No pending requests", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        statusLineItem = statusMenuItem("○ Idle")
        tokensLineItem = statusMenuItem("Tokens today: —")
        activityLineItem = statusMenuItem("Last activity: —")
        fiveHourLineItem = statusMenuItem("5-hour limit: —")
        weeklyLineItem = statusMenuItem("Weekly limit: —")
        menu.addItem(statusLineItem)
        menu.addItem(tokensLineItem)
        menu.addItem(activityLineItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(fiveHourLineItem)
        menu.addItem(weeklyLineItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(buildSpeciesSubmenuItem())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        idleMenu = menu
    }

    func buildSpeciesSubmenuItem() -> NSMenuItem {
        let top = NSMenuItem(title: "Choose Buddy", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for species in availableSpecies() {
            let item = NSMenuItem(title: species.capitalized, action: #selector(chooseSpecies(_:)), keyEquivalent: "")
            item.representedObject = species
            item.target = self
            item.state = (species == selectedSpecies) ? .on : .off
            sub.addItem(item)
        }
        top.submenu = sub
        return top
    }

    @objc func chooseSpecies(_ sender: NSMenuItem) {
        guard let species = sender.representedObject as? String else { return }
        selectedSpecies = species
        buildIdleMenu()
        setIdle()
    }

    // Fires right before the dropdown is shown to the user — usage/status
    // is computed fresh at that moment instead of on a background timer.
    // Updates item text in place; never reassigns statusItem.menu here.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === idleMenu else { return }
        usage = UsageReader.snapshot()
        updateUsageLabels()
    }

    func updateUsageLabels() {
        let statusText = usage.activeSessions > 0
            ? "● Active — \(usage.activeSessions) session\(usage.activeSessions == 1 ? "" : "s")"
            : "○ Idle"
        statusLineItem.attributedTitle = NSAttributedString(
            string: statusText,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
        )
        tokensLineItem.attributedTitle = NSAttributedString(
            string: "Tokens today: \(formatTokens(usage.tokensToday))",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
        )
        if let last = usage.lastActivity {
            let mins = max(0, Int(Date().timeIntervalSince(last) / 60))
            activityLineItem.attributedTitle = NSAttributedString(
                string: "Last activity: \(mins)m ago",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
            )
        }
        if let fh = usage.fiveHourPct {
            fiveHourLineItem.attributedTitle = NSAttributedString(
                string: "5-hour limit: \(bar(fh)) \(fh)%",
                attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
            )
        }
        if let sd = usage.weeklyPct {
            weeklyLineItem.attributedTitle = NSAttributedString(
                string: "Weekly limit: \(bar(sd)) \(sd)%",
                attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
            )
        }
    }

    func bar(_ pct: Int, width: Int = 10) -> String {
        let filled = min(width, max(0, pct * width / 100))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    func setIdle() {
        statusItem.button?.title = "🐼"
        currentRequestId = nil
        statusItem.menu = idleMenu
    }

    func setPending(_ req: PendingRequest) {
        statusItem.button?.title = "🐼❗"
        currentRequestId = req.id

        let menu = NSMenu()
        menu.addItem(gifMenuItem(named: "\(selectedSpecies)_pending"))

        let toolItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        toolItem.attributedTitle = NSAttributedString(
            string: req.tool,
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(toolItem)

        let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.attributedTitle = NSAttributedString(
            string: String(req.hint.prefix(80)),
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]
        )
        menu.addItem(hintItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Allow", action: #selector(allow), keyEquivalent: "a")
        menu.addItem(withTitle: "Deny", action: #selector(deny), keyEquivalent: "d")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu

        NSSound(named: "Ping")?.play()
    }

    func poll() {
        guard FileManager.default.fileExists(atPath: requestURL.path) else {
            if currentRequestId != nil { setIdle() }
            return
        }
        guard let data = try? Data(contentsOf: requestURL),
              let req = try? JSONDecoder().decode(PendingRequest.self, from: data) else {
            return
        }
        if req.id != currentRequestId && !respondedIds.contains(req.id) {
            setPending(req)
        }
    }

    func respond(_ decision: String) {
        guard let id = currentRequestId else { return }
        let responseURL = dirURL.appendingPathComponent("response_\(id).json")
        let payload = "{\"decision\":\"\(decision)\"}"
        try? payload.write(to: responseURL, atomically: true, encoding: .utf8)
        // Remove the request file ourselves right away — don't wait for
        // hook.sh's own poll loop to notice and delete it. Otherwise our
        // poll() can see the still-there (already-answered) request on its
        // next tick, treat it as new (currentRequestId was just reset to
        // nil by setIdle()), and re-trigger setPending() — including a
        // second, spurious Ping sound.
        try? FileManager.default.removeItem(at: requestURL)
        respondedIds.insert(id)
        setIdle()
    }

    @objc func allow() { respond("allow") }
    @objc func deny() { respond("deny") }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
