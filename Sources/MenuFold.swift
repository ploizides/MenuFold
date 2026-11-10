import Cocoa
import SwiftUI
import Combine
import ServiceManagement
import Carbon.HIToolbox
import os

// MARK: - Preferences (persisted in UserDefaults)

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case off, optCmdB, ctrlOptCmdM, ctrlOptSpace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:          return "None"
        case .optCmdB:      return "⌥⌘B"
        case .ctrlOptCmdM:  return "⌃⌥⌘M"
        case .ctrlOptSpace: return "⌃⌥Space"
        }
    }
    /// (virtual key code, Carbon modifier mask)
    var combo: (UInt32, UInt32)? {
        switch self {
        case .off:          return nil
        case .optCmdB:      return (UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey))
        case .ctrlOptCmdM:  return (UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey | controlKey))
        case .ctrlOptSpace: return (UInt32(kVK_Space),  UInt32(controlKey | optionKey))
        }
    }
}

enum ToggleIcon: String, CaseIterable, Identifiable {
    case chevron, circle, ellipsis
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    func symbol(folded: Bool) -> String {
        switch self {
        case .chevron:  return folded ? "chevron.left" : "chevron.right"
        case .circle:   return folded ? "circle.fill" : "circle"
        case .ellipsis: return folded ? "ellipsis.circle.fill" : "ellipsis.circle"
        }
    }
}

enum DividerStyle: String, CaseIterable, Identifiable {
    case line, dot
    var id: String { rawValue }
    var label: String { self == .line ? "Line │" : "Dot •" }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var foldAtLaunch: Bool   { didSet { d.set(foldAtLaunch, forKey: "foldAtLaunch") } }
    @Published var refoldSeconds: Int   { didSet { d.set(refoldSeconds, forKey: "refoldSeconds") } }
    @Published var hotKey: HotKeyPreset { didSet { d.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var toggleIcon: ToggleIcon     { didSet { d.set(toggleIcon.rawValue, forKey: "toggleIcon") } }
    @Published var dividerStyle: DividerStyle { didSet { d.set(dividerStyle.rawValue, forKey: "dividerStyle") } }

    private init() {
        d.register(defaults: [
            "foldAtLaunch": true,
            "refoldSeconds": 0,
            "hotKey": HotKeyPreset.off.rawValue,
            "toggleIcon": ToggleIcon.chevron.rawValue,
            "dividerStyle": DividerStyle.line.rawValue,
        ])
        foldAtLaunch  = d.bool(forKey: "foldAtLaunch")
        refoldSeconds = d.integer(forKey: "refoldSeconds")
        hotKey        = HotKeyPreset(rawValue: d.string(forKey: "hotKey") ?? "") ?? .off
        toggleIcon    = ToggleIcon(rawValue: d.string(forKey: "toggleIcon") ?? "") ?? .chevron
        dividerStyle  = DividerStyle(rawValue: d.string(forKey: "dividerStyle") ?? "") ?? .line
    }
}

// MARK: - Launch at login (SMAppService; shows up under System Settings → General → Login Items)

final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    var statusText: String {
        switch status {
        case .enabled:          return "Enabled"
        case .requiresApproval: return "Waiting for your approval in Login Items"
        case .notRegistered:    return "Off"
        case .notFound:         return "Not available (move MenuFold.app into an Applications folder)"
        @unknown default:       return "Unknown"
        }
    }
}

// MARK: - Controller: owns the two status items and does the folding

@MainActor
final class Controller: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    @Published private(set) var folded = false
    @Published private(set) var layoutOK: Bool?

    let prefs = Prefs.shared
    let loginItem = LoginItem()

    private var toggle: NSStatusItem!
    private var divider: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var refoldTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var settingsWindow: NSWindow?

    private static let toggleName  = "MenuFold.Toggle"
    private static let dividerName = "MenuFold.Divider"
    private let log = Logger(subsystem: "com.ploizides.menufold", category: "fold")
    private var foldGeneration = 0          // cancels stale measurements
    private var lastScreenID: CGDirectDisplayID?
    private var watchTimer: Timer?

    // MARK: Fold sizing
    //
    // On macOS 27 the menu bar (MenuBarAgent) *hides an item that is absurdly wide* rather than
    // letting it push its neighbours away, so the classic "length = 10_000" trick only makes the
    // divider vanish. Instead the divider must fill exactly the free space between the left limit
    // of the status-item area and the toggle. Everything left of the divider then no longer fits
    // and macOS hides it (its own overflow behaviour).
    //
    // The free space ends at the notch on a notched display, and where the frontmost app's menus
    // (File, Edit, View…) end on a display without one. One status item has one length on every
    // display, so we size it for the display whose menu bar is active and recompute whenever that
    // display or the frontmost app changes.
    //
    // How we find the right length:
    //   1. Make a guess: remembered result for this display+app > notch > Accessibility (where the
    //      app's menus end; optional permission).
    //   2. Verify it: when an item fits, macOS moves its window to the new spot within ~0.1 s;
    //      when it doesn't fit, macOS hides it and leaves the window where it was.
    //   3. If the guess fails (or there is none), binary-search the widest length that still fits.
    //      Each failing try briefly hides the divider, so icons flash visible for ~1 s.

    private static let buttonPadding: CGFloat = 16   // an item's window is `length + 16` wide
    private static let margin: CGFloat = 2           // too thin for any icon to squeeze in
    private static let minLength: CGFloat = 40
    private var fitCache: [String: CGFloat] = [:]   // "displayID|bundleID" -> length that fit

    private func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private var menuBarScreen: NSScreen? { toggle.button?.window?.screen ?? NSScreen.main }

    private func recomputeFold(_ reason: String) {
        guard folded, let tw = toggle.button?.window, let screen = tw.screen ?? NSScreen.main else { return }
        foldGeneration += 1
        let gen = foldGeneration
        let toggleX = tw.frame.minX   // the toggle doesn't move when the divider resizes
        lastScreenID = displayID(screen)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let key = "\(lastScreenID ?? 0)|\(app)"
        let lengthTo = { (limit: CGFloat) in max(toggleX - limit - Self.buttonPadding - Self.margin, Self.minLength) }

        var guess: CGFloat?
        var how = "search"
        if let cached = fitCache[key] {
            guess = cached; how = "remembered"
        } else if let notch = screen.auxiliaryTopRightArea, ProcessInfo.processInfo.environment["MENUFOLD_IGNORE_NOTCH"] == nil {
            guess = lengthTo(notch.minX); how = "notch"
        } else if let menuEnd = appMenuEnd(on: screen) {
            guess = lengthTo(menuEnd); how = "accessibility"
        }

        let finish = { [weak self] (length: CGFloat, how: String) in
            guard let self, self.folded, gen == self.foldGeneration else { return }
            self.divider.length = length
            self.fitCache[key] = length
            self.log.notice("""
                fold [\(reason, privacy: .public)] screen=\(screen.localizedName, privacy: .public) \
                app=\(app, privacy: .public) toggleX=\(toggleX, privacy: .public) \
                length=\(length, privacy: .public) via \(how, privacy: .public)
                """)
        }
        let search = { [weak self] (hi: CGFloat) in
            self?.searchFit(lo: Self.minLength, hi: hi, toggleX: toggleX, gen: gen) { finish($0, how == "search" ? "search" : "\(how)+search") }
        }

        if let g = guess {
            tryLength(g, toggleX: toggleX, gen: gen) { fits in fits ? finish(g, how) : search(g) }
        } else {
            search(toggleX - screen.frame.minX - Self.buttonPadding)
        }
    }

    /// An item that fits is laid out ending just left of the toggle, at the requested width.
    private func dividerFits(_ length: CGFloat, toggleX: CGFloat) -> Bool {
        guard let f = divider.button?.window?.frame else { return false }
        return abs(f.width - (length + Self.buttonPadding)) < 1 && f.maxX > toggleX - 12 && f.maxX <= toggleX + 1
    }

    private func tryLength(_ length: CGFloat, toggleX: CGFloat, gen: Int, _ done: @escaping (Bool) -> Void) {
        divider.length = length
        let start = Date()
        func poll() {
            guard folded, gen == foldGeneration else { return }   // superseded: drop silently
            let elapsed = Date().timeIntervalSince(start)
            if dividerFits(length, toggleX: toggleX) {
                log.debug("try \(length, privacy: .public) fits after \(elapsed, privacy: .public)s")
                return done(true)
            }
            if elapsed > 0.5 {
                let f = divider.button?.window?.frame ?? .zero
                log.debug("try \(length, privacy: .public) hidden; frame \(f.minX, privacy: .public)..\(f.maxX, privacy: .public) w=\(f.width, privacy: .public)")
                return done(false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { MainActor.assumeIsolated { poll() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { MainActor.assumeIsolated { poll() } }
    }

    /// Binary search for the widest divider that still fits. `lo` is assumed to fit, `hi` not.
    private func searchFit(lo: CGFloat, hi: CGFloat, toggleX: CGFloat, gen: Int, _ done: @escaping (CGFloat) -> Void) {
        if hi - lo <= 2 { return done(lo) }
        let mid = ((lo + hi) / 2).rounded()
        tryLength(mid, toggleX: toggleX, gen: gen) { [weak self] fits in
            self?.searchFit(lo: fits ? mid : lo, hi: fits ? hi : mid, toggleX: toggleX, gen: gen, done)
        }
    }

    /// Right edge of the frontmost app's menus (File, Edit, View…) on `screen`, via Accessibility.
    /// Returns nil when the permission isn't granted or the menus can't be read.
    private func appMenuEnd(on screen: NSScreen) -> CGFloat? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var menuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let menuBar, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        var end: CGFloat?
        for item in items {
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let pos, let size else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            // AX uses top-left origin, but x is the same as Cocoa's; keep items on this screen.
            guard p.x >= screen.frame.minX, p.x < screen.frame.maxX else { continue }
            end = max(end ?? 0, p.x + s.width)
        }
        return end
    }

    // MARK: Permissions status (for the Settings window)

    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    func refreshStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        checkLayout()
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// After an update macOS sees a "new" app (it isn't signed with a paid developer ID), so the old
    /// entry no longer applies. Remove MenuFold's own entry, then ask again.
    func resetAndRequestAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.ploizides.menufold"]
        try? p.run()
        p.waitUntilExit()
        log.notice("tccutil reset exit=\(p.terminationStatus, privacy: .public)")
        requestAccessibility()
    }

    /// A running app may keep seeing the old Accessibility answer until it restarts.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// While folded, notice when the active menu bar moves to another display.
    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.folded, let s = self.menuBarScreen else { return }
                if self.displayID(s) != self.lastScreenID { self.recomputeFold("display changed") }
            }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        makeItems()
        installHotKeyHandler()

        prefs.$hotKey.receive(on: RunLoop.main)
            .sink { [weak self] in self?.registerHotKey($0) }.store(in: &bag)
        prefs.$toggleIcon.map { _ in () }.merge(with: prefs.$dividerStyle.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }.store(in: &bag)

        // Display plugged in/out or resolution change: recompute once things settle.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .delay(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeFold("displays reconfigured") }.store(in: &bag)

        // Switched Space: the active menu bar may now be on another display.
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .delay(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeFold("space changed") }.store(in: &bag)

        // Switched app: on displays without a notch the free space ends where that app's menus end.
        // (On notched displays this is just a quick check that the current length still fits.)
        ws.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .delay(for: .seconds(0.2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeFold("app switched") }.store(in: &bag)

        startWatching()

        // macOS posts this when any app's Accessibility permission changes.
        log.notice("launch: accessibility granted=\(AXIsProcessTrusted(), privacy: .public)")
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))
            .delay(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatus()
                self?.log.notice("accessibility changed: granted=\(AXIsProcessTrusted(), privacy: .public)")
            }.store(in: &bag)

        // Fold shortly after launch, once the menu bar has settled.
        if prefs.foldAtLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.setFolded(true) }
        }
    }

    // MARK: Status items

    private func makeItems() {
        // Created first → sits to the right by default. Divider created second → sits to its left.
        toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = Self.toggleName   // macOS remembers where you ⌘-drag it
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle.button?.toolTip = "Click to fold/unfold · Right-click for options"

        divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider.autosaveName = Self.dividerName
        divider.button?.appearsDisabled = true
        divider.button?.toolTip = "MenuFold divider: icons to the LEFT of this fold away (⌘-drag to arrange)"

        refresh()
    }

    func resetPositions() {
        setFolded(false)
        NSStatusBar.system.removeStatusItem(toggle)
        NSStatusBar.system.removeStatusItem(divider)
        for name in [Self.toggleName, Self.dividerName] {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(name)")
        }
        makeItems()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkLayout() }
    }

    private func screenX(_ item: NSStatusItem) -> CGFloat? {
        guard let w = item.button?.window else { return nil }
        return w.frame.minX
    }

    @discardableResult
    func checkLayout() -> Bool {
        guard let d = screenX(divider), let t = screenX(toggle) else { layoutOK = nil; return false }
        layoutOK = d < t
        return d < t
    }

    // MARK: Folding

    func toggleFold() { setFolded(!folded) }

    func setFolded(_ f: Bool) {
        // Safety: never fold if the divider sits right of the toggle, or the toggle itself
        // would be pushed off-screen and you'd have no way to unfold.
        if f && !checkLayout() {
            NSSound.beep()
            return
        }
        folded = f
        foldGeneration += 1   // cancel any in-flight measurement
        refresh()
        if f { recomputeFold("fold") }

        refoldTimer?.invalidate()
        refoldTimer = nil
        if !f && prefs.refoldSeconds > 0 {
            refoldTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(prefs.refoldSeconds), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.setFolded(true) }
            }
        }
    }

    private func refresh() {
        guard toggle != nil, divider != nil else { return }
        if !folded { divider.length = NSStatusItem.variableLength }   // folded length: see recomputeFold

        switch prefs.dividerStyle {
        case .line:
            divider.button?.image = nil
            divider.button?.title = "│"
        case .dot:
            divider.button?.title = ""
            let cfg = NSImage.SymbolConfiguration(pointSize: 5, weight: .regular)
            divider.button?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Divider")?
                .withSymbolConfiguration(cfg)
        }

        toggle.button?.image = NSImage(systemSymbolName: prefs.toggleIcon.symbol(folded: folded),
                                       accessibilityDescription: folded ? "Unfold menu bar" : "Fold menu bar")
    }

    // MARK: Clicks & menu

    @objc private func toggleClicked() {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.option) == true || ev?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggleFold()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: folded ? "Unfold" : "Fold", action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MenuFold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        toggle.menu = menu
        toggle.button?.performClick(nil)
        toggle.menu = nil
    }

    @objc private func menuToggle() { toggleFold() }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(controller: self, prefs: prefs, loginItem: loginItem))
            let w = NSWindow(contentViewController: host)
            w.title = "MenuFold Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        loginItem.refresh()
        checkLayout()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Global hotkey (Carbon RegisterEventHotKey: needs no Accessibility permission)

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<Controller>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.toggleFold() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotKey(_ preset: HotKeyPreset) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        guard let (code, mods) = preset.combo else { return }
        let id = EventHotKeyID(signature: OSType(0x4D464C44) /* 'MFLD' */, id: 1)
        RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var prefs: Prefs
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 500, height: 440)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            controller.refreshStatus()
            loginItem.refresh()
        }
    }

    // General

    private var general: some View {
        Form {
            Section("Status") {
                HStack {
                    Label(controller.folded ? "Folded" : "Unfolded",
                          systemImage: controller.folded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    Spacer()
                    Button(controller.folded ? "Unfold now" : "Fold now") { controller.toggleFold() }
                        .disabled(!controller.folded && controller.layoutOK != true)
                }
                layoutRow
            }
            Section("Behavior") {
                Toggle("Fold automatically when MenuFold starts", isOn: $prefs.foldAtLaunch)
                Picker("Re-fold after unfolding", selection: $prefs.refoldSeconds) {
                    Text("Never").tag(0)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                }
                Picker("Keyboard shortcut", selection: $prefs.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
            }
            Section("Troubleshooting") {
                HStack {
                    Text("Put the chevron and divider back in their default places")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset positions") { controller.resetPositions() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var layoutRow: some View {
        switch controller.layoutOK {
        case .some(true):
            Label("Layout OK: the divider is left of the toggle", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .some(false):
            Label("The divider is RIGHT of the toggle. ⌘-drag it to the left, or click Reset positions. Folding is blocked until you do.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .none:
            Label("Can't read item positions yet", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // Appearance

    private var appearance: some View {
        Form {
            Section("Menu bar items") {
                Picker("Toggle icon", selection: $prefs.toggleIcon) {
                    ForEach(ToggleIcon.allCases) { icon in
                        Label(icon.label, systemImage: icon.symbol(folded: false)).tag(icon)
                    }
                }
                Picker("Divider", selection: $prefs.dividerStyle) {
                    ForEach(DividerStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("How to arrange") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Unfold, then hold **⌘** and drag menu bar icons.")
                    Text("2. Icons **left** of the divider are hidden when folded.")
                    Text("3. Icons **right** of the divider always stay visible.")
                    Text("4. Keep the toggle icon right of the divider.")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    // Permissions

    private var permissions: some View {
        Form {
            Section {
                permRow("Screen Recording", ok: true, detail: "Not needed. MenuFold never captures the screen.")
                permRow("Keyboard shortcut", ok: true, detail: "Not needed. Global shortcuts use the system hot-key API.")
            } header: {
                Text("Not needed")
            }

            Section("Optional: external monitors") {
                HStack {
                    Image(systemName: controller.accessibilityGranted ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(controller.accessibilityGranted ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device Control and Data Access")
                        Text(controller.accessibilityGranted
                             ? "Granted. On monitors without a notch, folding is instant."
                             : "Called Accessibility on older macOS. Only helps on monitors without a notch: it lets MenuFold read where the app's menus end, so folding there is instant instead of flickering for about a second. Your laptop screen never needs it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !controller.accessibilityGranted {
                        Button("Grant…") { controller.requestAccessibility() }
                    }
                }
                if !controller.accessibilityGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Already switched on in System Settings → Privacy & Security → Device Control and Data Access, but still shows off here? After every update macOS treats MenuFold as a new app, so the old switch no longer applies. Click **Reset & Grant again**. If that doesn't help, **Relaunch**.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Reset & Grant again") { controller.resetAndRequestAccessibility() }
                            Button("Relaunch") { controller.relaunch() }
                        }
                    }
                }
            }

            Section("Launch at login") {
                HStack {
                    permRow("Login item", ok: loginItem.status == .enabled, detail: loginItem.statusText)
                    Spacer()
                    Toggle("", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) }))
                        .labelsHidden()
                }
                if let err = loginItem.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
            }

            Section("Menu bar visibility") {
                Text("macOS lets you hide any app's menu bar icons in System Settings → Menu Bar. If MenuFold's toggle disappears, make sure MenuFold is allowed there. If you use Ice, Bartender or Hidden Bar, quit them first so they don't fight over the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Menu Bar Settings…") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
                    if !NSWorkspace.shared.open(url) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = MainActor.assumeIsolated { Controller() }
app.delegate = controller
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
