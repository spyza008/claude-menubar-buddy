import AppKit
import Foundation

// Claude Menu Bar Buddy — hardware-free stand-in for the M5Stick Hardware
// Buddy. A PreToolUse hook (~/.config/claude-menubar-buddy/hook.sh) writes
// pending_request.json when Claude Code needs a permission decision; this
// app polls for it, shows Approve/Deny in the menu bar, and writes back
// response_<id>.json for the hook to pick up.

// UNUserNotificationCenter requires a real .app bundle (mainBundle must have
// a valid bundleProxyForCurrentProcess) — this runs as a raw SPM binary from
// .build/debug, which crashes on launch if UserNotifications is touched at
// all. osascript's "display notification" has no such requirement.
func sendNotification(title: String, body: String) {
    let script = "display notification \"\(body.replacingOccurrences(of: "\"", with: "'"))\" with title \"\(title.replacingOccurrences(of: "\"", with: "'"))\""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try? task.run()
}

let dirURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/claude-menubar-buddy")
let requestURL = dirURL.appendingPathComponent("pending_request.json")

struct PendingRequest: Decodable {
    let id: String
    let tool: String
    let hint: String
}

// Returns the menu item plus the NSImageView inside it, so callers that need
// to swap the GIF later (e.g. mood changes) don't have to rebuild the item.
// If target/action are given, a transparent NSButton is layered over the
// GIF so clicking the pet (even mid-menu-tracking) fires the action —
// AppKit only reliably delivers clicks to real controls inside a custom
// NSMenuItem view, not to plain NSViews/NSImageViews via gesture recognizers.
func gifMenuItem(named name: String, target: AnyObject? = nil, action: Selector? = nil) -> (NSMenuItem, NSImageView) {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let size = NSSize(width: 220, height: 90)
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    // Square frame, not 128x64 — the GIFs aren't 2:1 (buddy is 128x128,
    // species art varies per pet), so a non-square box forced a squash.
    // scaleProportionallyUpOrDown then letterboxes each pet's real aspect
    // ratio inside this square instead of distorting it.
    let side: CGFloat = 80
    let frame = NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    let imageView = NSImageView(frame: frame)
    setGif(on: imageView, named: name)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    container.addSubview(imageView)
    if let target = target, let action = action {
        let button = NSButton(frame: frame)
        button.title = ""
        button.isBordered = false
        button.target = target
        button.action = action
        button.toolTip = "Pet the buddy"
        container.addSubview(button)
    }
    item.view = container
    return (item, imageView)
}

func setGif(on imageView: NSImageView, named name: String) {
    guard let url = Bundle.module.url(forResource: name, withExtension: "gif", subdirectory: "Resources"),
          let image = NSImage(contentsOf: url) else { return }
    // Leave image.size at its native pixel dimensions (each GIF has its own
    // aspect ratio) so .scaleProportionallyUpOrDown on the view fits it
    // without distortion, instead of stretching everything to one fixed box.
    imageView.image = image
    imageView.animates = true
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
    var sessionsSubmenuTop: NSMenuItem!
    var petImageView: NSImageView!
    var petMoodLineItem: NSMenuItem!
    // Tracks the last mood actually computed from usage, separate from
    // whatever GIF is on screen right now — a "heart" or "celebrate" flash
    // temporarily overrides the displayed GIF without losing track of what
    // to revert to.
    var lastComputedMood = "idle"
    var flashWorkItem: DispatchWorkItem?

    // Thresholds match ClaudeBar's scheme (see the community-project survey):
    // <50% used = healthy, 50-80% = warning, >80% = critical. Persist the
    // highest threshold already notified-for per limit so we don't re-fire
    // the same notification every time the menu happens to be opened.
    var notifiedFiveHour: Int {
        get { UserDefaults.standard.integer(forKey: "notifiedFiveHour") }
        set { UserDefaults.standard.set(newValue, forKey: "notifiedFiveHour") }
    }
    var notifiedWeekly: Int {
        get { UserDefaults.standard.integer(forKey: "notifiedWeekly") }
        set { UserDefaults.standard.set(newValue, forKey: "notifiedWeekly") }
    }

    var selectedSpecies: String {
        get { UserDefaults.standard.string(forKey: "selectedSpecies") ?? "buddy" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedSpecies") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildIdleMenu()
        setIdle()

        // .common (not just .default) so this keeps firing while an NSMenu
        // dropdown is open — AppKit switches the run loop to .eventTracking
        // mode during that time, and a plain scheduledTimer would go silent
        // until the menu closes, delaying pending-request detection.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    func buildIdleMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let (petItem, imageView) = gifMenuItem(named: "\(selectedSpecies)_idle", target: self, action: #selector(petClicked))
        petImageView = imageView
        menu.addItem(petItem)
        petMoodLineItem = statusMenuItem("🐼 Active and happy")
        menu.addItem(petMoodLineItem)
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
        sessionsSubmenuTop = NSMenuItem(title: "Active Sessions", action: nil, keyEquivalent: "")
        sessionsSubmenuTop.submenu = NSMenu()
        menu.addItem(sessionsSubmenuTop)
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
        updatePetMood(usage.fiveHourPct)
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
        let count = usage.activeSessions.count
        let statusText = count > 0
            ? "● Active — \(count) session\(count == 1 ? "" : "s")"
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
                attributes: [.foregroundColor: thresholdColor(fh), .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
            )
            checkThreshold(pct: fh, label: "5-hour limit", lastNotified: notifiedFiveHour) { self.notifiedFiveHour = $0 }
            updatePetMood(fh)
        }
        if let sd = usage.weeklyPct {
            weeklyLineItem.attributedTitle = NSAttributedString(
                string: "Weekly limit: \(bar(sd)) \(sd)%",
                attributes: [.foregroundColor: thresholdColor(sd), .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]
            )
            checkThreshold(pct: sd, label: "Weekly limit", lastNotified: notifiedWeekly) { self.notifiedWeekly = $0 }
        }
        updateSessionsSubmenu()
    }

    func bar(_ pct: Int, width: Int = 10) -> String {
        let filled = min(width, max(0, pct * width / 100))
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }

    // <50% used = healthy, 50-80% = warning, >80% = critical.
    func thresholdColor(_ pct: Int) -> NSColor {
        if pct >= 80 { return .systemRed }
        if pct >= 50 { return .systemOrange }
        return .systemGreen
    }

    func thresholdLevel(_ pct: Int) -> Int {
        if pct >= 80 { return 80 }
        if pct >= 50 { return 50 }
        return 0
    }

    // Fires a system notification the first time a limit crosses into a new,
    // higher threshold band. `lastNotified` guards against re-firing every
    // time the menu is opened while still in the same band.
    func checkThreshold(pct: Int, label: String, lastNotified: Int, setNotified: @escaping (Int) -> Void) {
        let level = thresholdLevel(pct)
        guard level > lastNotified else { return }
        setNotified(level)
        guard level > 0 else { return }
        let title = level >= 80 ? "Claude \(label) critical" : "Claude \(label) warning"
        sendNotification(title: title, body: "\(label) usage is at \(pct)%.")
    }

    // Rebuilds the "Active Sessions" submenu in place — one item per session
    // showing its project path + minutes since last activity, clicking it
    // reveals the project folder in Finder.
    func updateSessionsSubmenu() {
        guard let submenu = sessionsSubmenuTop.submenu else { return }
        submenu.removeAllItems()
        if usage.activeSessions.isEmpty {
            submenu.addItem(withTitle: "No active sessions", action: nil, keyEquivalent: "")
            sessionsSubmenuTop.title = "Active Sessions"
            return
        }
        sessionsSubmenuTop.title = "Active Sessions (\(usage.activeSessions.count))"
        for session in usage.activeSessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let mins = max(0, Int(Date().timeIntervalSince(session.lastActivity) / 60))
            let item = NSMenuItem(
                title: "\(session.projectPath) — \(mins)m ago",
                action: #selector(revealSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = session.projectPath
            submenu.addItem(item)
        }
    }

    // The pet's mood follows the 5-hour limit, not the weekly one — it's
    // the one that actually blocks you mid-session, so it's the one worth
    // dramatizing. <50% used = active, 50-79% = tired, 80-99% = sleepy,
    // 100% = asleep.
    func petMood(for pct: Int?) -> String {
        guard let pct = pct else { return "idle" }
        if pct >= 100 { return "asleep" }
        if pct >= 80 { return "sleepy" }
        if pct >= 50 { return "tired" }
        return "idle"
    }

    func petMoodText(_ mood: String) -> String {
        switch mood {
        case "tired": return "😅 Getting tired..."
        case "sleepy": return "😴 Getting sleepy..."
        case "asleep": return "💤 Fast asleep (5h limit reached)"
        default: return "🐼 Active and happy"
        }
    }

    func updatePetMood(_ fiveHourPct: Int?) {
        let mood = petMood(for: fiveHourPct)
        // Was tired/sleepy/asleep last time we checked, and just dropped
        // back to healthy — the 5-hour window rolled over. Worth a little
        // fanfare instead of silently snapping back to the idle GIF.
        if lastComputedMood != "idle" && mood == "idle" {
            sendNotification(title: "Claude 5-hour limit refreshed", body: "Buddy is back and ready to go!")
            flashMood("celebrate", for: 4.0)
        }
        lastComputedMood = mood
        applyMoodGif(mood)
    }

    func applyMoodGif(_ mood: String) {
        setGif(on: petImageView, named: "\(selectedSpecies)_\(mood)")
        petMoodLineItem.attributedTitle = NSAttributedString(
            string: petMoodText(mood),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
        )
    }

    // Shows a mood GIF ("heart" on click, "celebrate" on limit reset) for a
    // few seconds, then reverts to whatever the current real mood is.
    func flashMood(_ mood: String, for seconds: Double) {
        flashWorkItem?.cancel()
        applyMoodGif(mood)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.applyMoodGif(self.lastComputedMood)
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc func petClicked() {
        NSSound(named: "Tink")?.play()
        flashMood("heart", for: 2.0)
    }

    @objc func revealSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
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
        menu.addItem(gifMenuItem(named: "\(selectedSpecies)_pending").0)

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
