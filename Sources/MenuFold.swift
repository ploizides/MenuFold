import Cocoa
import SwiftUI
import Combine
import ServiceManagement
import Carbon.HIToolbox

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
    /// On macOS 27 the menu bar (MenuBarAgent) *hides an item that is absurdly wide* rather than
    /// letting it push its neighbours away, so the classic "length = 10_000" trick only makes the
    /// divider vanish. Instead we size the divider to fill exactly from its right edge to the left
    /// limit of the status-item area (the notch's right edge on notched Macs). Everything left of
    /// the divider then no longer fits and macOS hides it, just like its own notch overflow.
    private func foldedLength() -> CGFloat {
        guard let w = divider.button?.window, let screen = w.screen ?? NSScreen.main else { return 10_000 }
        let rightEdge = w.frame.maxX
        // Notched screens: status items can't go left of the notch.
        // Other screens: no system-provided limit, so use the middle of the screen (heuristic).
        let leftLimit = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let buttonPadding: CGFloat = 16   // the item's window is `length + 16` wide
        let margin: CGFloat = 2           // too thin for any icon to squeeze in
        return max(rightEdge - leftLimit - buttonPadding - margin, 40)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        makeItems()
        installHotKeyHandler()

        prefs.$hotKey.receive(on: RunLoop.main)
            .sink { [weak self] in self?.registerHotKey($0) }.store(in: &bag)
        prefs.$toggleIcon.map { _ in () }.merge(with: prefs.$dividerStyle.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }.store(in: &bag)

        // Display plugged in/out or resolution change: recompute how wide the divider must be.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.folded else { return }
                self.divider.length = NSStatusItem.variableLength
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
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
        refresh()

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
        divider.length = folded ? foldedLength() : NSStatusItem.variableLength

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
            controller.checkLayout()
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
                permRow("Accessibility", ok: true, detail: "Not needed. MenuFold only uses public menu bar APIs.")
                permRow("Screen Recording", ok: true, detail: "Not needed. MenuFold never captures the screen.")
                permRow("Keyboard shortcut", ok: true, detail: "Not needed. Global shortcuts use the system hot-key API.")
            } header: {
                Text("macOS permissions")
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
