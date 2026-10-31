// Menu-bar app that mirrors the MacBook's brightness onto external monitors over DDC.
// Build with ./build.sh (needs `brew install m1ddc`). The app's name is set once, in build.sh.
//
// Per-monitor settings live in ~/Library/Application Support/<name>/config.json, keyed by display UUID.
import AppKit
import ColorSync
import ServiceManagement

let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Brightlink"

// MARK: - Config

struct MonitorConfig: Codable, Equatable {
    var sync = true
    var offset = 0.0              // percentage points added to the mirrored brightness
    var minB = 10.0, maxB = 100.0 // monitor brightness at built-in 0% / 100%
    var minC = 60.0, maxC = 80.0  // monitor contrast at built-in 0% / 100%
    var volume = 50.0

    init() {}

    // Tolerate missing keys so a config written by an older version keeps the settings it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        sync = try c.decodeIfPresent(Bool.self, forKey: .sync) ?? sync
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? offset
        minB = try c.decodeIfPresent(Double.self, forKey: .minB) ?? minB
        maxB = try c.decodeIfPresent(Double.self, forKey: .maxB) ?? maxB
        minC = try c.decodeIfPresent(Double.self, forKey: .minC) ?? minC
        maxC = try c.decodeIfPresent(Double.self, forKey: .maxC) ?? maxC
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? volume
    }
}

struct Config: Codable {
    var paused = false
    var monitors: [String: MonitorConfig] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? paused
        monitors = try c.decodeIfPresent([String: MonitorConfig].self, forKey: .monitors) ?? monitors
    }
}

let configURL: URL = {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = support.appendingPathComponent(appName)
    // Carry settings over from the app's earlier name.
    let old = support.appendingPathComponent("DellSync")
    if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
        try? fm.moveItem(at: old, to: dir)
    }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.json")
}()

func loadConfig() -> Config {
    guard let data = try? Data(contentsOf: configURL) else { return Config() }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        // Keep the unreadable file instead of overwriting it with defaults on the next save.
        try? FileManager.default.moveItem(at: configURL, to: configURL.appendingPathExtension("bad"))
        return Config()
    }
}

func saveConfig(_ cfg: Config) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(cfg).write(to: configURL, options: .atomic)
}

// MARK: - DDC and display discovery

/// Only the Homebrew install locations are used, never the current folder or PATH.
let m1ddcPath: String? = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Set BRIGHTLINK_DEBUG=1 and run the binary from a terminal to see each DDC command.
let debugEnabled = ProcessInfo.processInfo.environment["BRIGHTLINK_DEBUG"] != nil
func debug(_ message: @autoclosure () -> String) {
    if debugEnabled { FileHandle.standardError.write((message() + "\n").data(using: .utf8)!) }
}

/// Runs m1ddc and reports whether it succeeded. A call that hangs (some docks and monitors stall
/// DDC) is killed after the timeout so it cannot block later writes.
@discardableResult
func ddc(_ args: [String], timeout: TimeInterval = 3) -> Bool {
    debug("ddc \(args.joined(separator: " "))")
    guard let path = m1ddcPath else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return false }
    if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return false }
    return p.terminationStatus == 0
}

/// Rounds to a 0-100 percentage; non-finite input (from a hand-edited config) becomes 0.
func percent(_ x: Double) -> Int { x.isFinite ? Int(min(100, max(0, x)).rounded()) : 0 }

typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
let getBrightness: GetBrightness? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
          let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightness.self)
}()

/// The built-in display's brightness (0-1) and UUID. Nil while the lid is closed, because macOS
/// drops the built-in from the online display list then.
func builtin() -> (brightness: Double, uuid: String)? {
    guard let getBrightness else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    for id in ids.prefix(Int(n)) where CGDisplayIsBuiltin(id) != 0 {
        var b: Float = 0
        guard getBrightness(id, &b) == 0,
              let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, cf) as String? else { continue }
        return (Double(b), s.uppercased())
    }
    return nil
}

struct External { let uuid: String; let name: String }

/// Awake external displays, from macOS rather than `m1ddc display list`, which can crash on some
/// display setups. m1ddc accepts the UUID as its display argument, and unlike a display number a
/// UUID stays valid across reboots and replugs. Call on the main thread (NSScreen).
func listExternals() -> [External] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).compactMap { id in
        guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsAsleep(id) == 0,
              let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, cf) as String? else { return nil }
        let name = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName ?? "External display"
        return External(uuid: s.uppercased(), name: name)
    }
}

// MARK: - Menu slider

final class SliderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let title: String
    private let format: String
    private let onChange: (Double) -> Void

    init(title: String, min: Double, max: Double, value: Double, format: String, onChange: @escaping (Double) -> Void) {
        self.title = title; self.format = format; self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        label.frame = NSRect(x: 16, y: 26, width: 208, height: 16)
        label.font = .menuFont(ofSize: 12)
        slider.frame = NSRect(x: 14, y: 5, width: 212, height: 20)
        slider.minValue = min; slider.maxValue = max; slider.doubleValue = value
        slider.isContinuous = true; slider.target = self; slider.action = #selector(changed)
        addSubview(label); addSubview(slider)
        refreshLabel()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refreshLabel() {
        label.stringValue = "\(title): " + String(format: format, slider.doubleValue)
    }

    @objc private func changed() {
        refreshLabel()
        onChange(slider.doubleValue)
    }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = loadConfig()
    private var externals: [External] = []
    private var lastSent: [String: Int] = [:]   // per monitor, so a newly plugged-in one is always synced
    private var lastContrast: [String: Int] = [:]
    private var invalidated = Set<String>()     // monitors changed while a sync was in flight
    private var builtinPct: Double?
    private var busy = false
    private var resyncPending = false           // a resync was requested while a sync was in flight
    private var saveWork: DispatchWorkItem?
    private var firstSeen: [String: Date] = [:]  // when each monitor last appeared awake
    private let queue = DispatchQueue(label: "ddc")
    private var volumeWork: [String: DispatchWorkItem] = [:]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(self, selector: #selector(didWake), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Common modes keep the timer firing while a menu is open, so slider changes apply live.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    // MARK: Sync

    /// Mirrors the built-in brightness onto each synced monitor. DDC calls run off the main thread.
    private func tick() {
        guard !busy else { return }
        // Refresh before the lid and pause checks so the menu stays accurate in clamshell mode.
        let mons = listExternals()   // sleeping displays are omitted, so none are written to while asleep
        externals = mons

        // A monitor that has just woken or been plugged in needs a moment before it accepts DDC.
        let now = Date()
        firstSeen = firstSeen.filter { key, _ in mons.contains { $0.uuid == key } }
        for m in mons where firstSeen[m.uuid] == nil { firstSeen[m.uuid] = now }
        let ready = mons.filter { now.timeIntervalSince(firstSeen[$0.uuid] ?? now) >= 3 }

        // Lid closed: the built-in's brightness is meaningless, so leave monitors where they are.
        guard let b = builtin() else { builtinPct = nil; updateIcon(); return }
        builtinPct = b.brightness
        guard !config.paused else { updateIcon(); return }
        debug("tick: builtin \(b.brightness), externals \(mons.map { $0.name }), ready \(ready.count)")

        invalidated.removeAll()
        resyncPending = false
        let cfg = config, sent = lastSent, sentContrast = lastContrast

        busy = true
        queue.async {
            var newSent = sent.filter { key, _ in mons.contains { $0.uuid == key } }
            var newContrast = sentContrast.filter { key, _ in mons.contains { $0.uuid == key } }
            for m in ready {
                let c = cfg.monitors[m.uuid] ?? MonitorConfig()
                guard c.sync else { continue }
                let target = percent(c.minB + b.brightness * (c.maxB - c.minB) + c.offset)
                if abs(target - (newSent[m.uuid] ?? -100)) < 2 { continue }   // ignore auto-brightness jitter
                // Record a value as sent only if the write succeeded, so a failed one is retried.
                guard ddc(["display", m.uuid, "set", "luminance", String(target)]) else { continue }
                newSent[m.uuid] = target
                // Raising contrast with brightness keeps the image from looking washed out when bright.
                let contrast = percent(c.minC + b.brightness * (c.maxC - c.minC))
                if contrast != newContrast[m.uuid],
                   ddc(["display", m.uuid, "set", "contrast", String(contrast)]) {
                    newContrast[m.uuid] = contrast
                }
            }
            DispatchQueue.main.async {
                // Settings changed or a resync was requested while this sync ran: discard what it recorded.
                let changedMidSync = !self.invalidated.isEmpty || self.resyncPending
                if self.resyncPending { newSent.removeAll(); newContrast.removeAll() }
                for u in self.invalidated { newSent.removeValue(forKey: u); newContrast.removeValue(forKey: u) }
                self.lastSent = newSent
                self.lastContrast = newContrast
                self.busy = false
                self.updateIcon()
                if changedMidSync { self.tick() }
            }
        }
    }

    private func resyncAll() { resyncPending = true; lastSent.removeAll(); lastContrast.removeAll() }

    private func updateIcon() {
        let symbol = config.paused ? "sun.min" : "sun.max"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: appName)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = config.paused ? "\(appName) (paused)"
            : builtinPct.map { "\(appName): MacBook at \(Int($0 * 100))%" } ?? "\(appName): lid closed, holding monitors"
    }

    // MARK: Sleep, wake, hotplug

    /// Monitors may have reset their settings while asleep, so resend everything. The wait before
    /// writing comes from `firstSeen` in `tick`.
    @objc private func didWake() { firstSeen.removeAll(); resyncAll() }

    @objc private func screensChanged() { resyncAll() }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = config.paused ? "Paused"
            : builtinPct.map { "MacBook brightness \(Int($0 * 100))%" } ?? "Lid closed: holding monitors"
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        if m1ddcPath == nil {
            let missing = NSMenuItem(title: "m1ddc not found: brew install m1ddc", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        }
        menu.addItem(item("Sync brightness", #selector(toggleSync), on: !config.paused))
        menu.addItem(.separator())

        if externals.isEmpty {
            let none = NSMenuItem(title: "No external monitors found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for m in externals { menu.addItem(monitorItem(m)) }

        menu.addItem(.separator())
        menu.addItem(item("Sync now", #selector(syncNow)))
        menu.addItem(item("Launch at login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("Quit \(appName)", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self; i.state = on ? .on : .off
        return i
    }

    private func monitorItem(_ m: External) -> NSMenuItem {
        let c = config.monitors[m.uuid] ?? MonitorConfig()
        let parent = NSMenuItem(title: m.name, action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let toggle = item("Sync with MacBook", #selector(toggleMonitor(_:)), on: c.sync)
        toggle.representedObject = m.uuid
        sub.addItem(toggle)
        if let sent = lastSent[m.uuid] {
            let now = NSMenuItem(title: "Brightness now \(sent)", action: nil, keyEquivalent: ""); now.isEnabled = false
            sub.addItem(now)
        }
        sub.addItem(.separator())

        sub.addItem(sliderItem("Offset", -30, 30, c.offset, "%+.0f") { [unowned self] v in
            self.update(m.uuid) { $0.offset = v.rounded() }
        })
        sub.addItem(sliderItem("Max brightness", 30, 100, c.maxB, "%.0f") { [unowned self] v in
            self.update(m.uuid) { $0.maxB = v.rounded() }
        })
        sub.addItem(sliderItem("Volume", 0, 100, c.volume, "%.0f") { [unowned self] v in
            self.update(m.uuid, resync: false) { $0.volume = v.rounded() }
            self.setVolume(m.uuid, v.rounded())
        })
        sub.addItem(.separator())

        let inputs = NSMenu()
        for (name, code) in [("DisplayPort 1", 15), ("DisplayPort 2", 16), ("HDMI 1", 17), ("HDMI 2", 18), ("USB-C", 27)] {
            let i = item(name, #selector(switchInput(_:)))
            i.representedObject = [m.uuid, name, String(code)]
            inputs.addItem(i)
        }
        let inputItem = NSMenuItem(title: "Switch input", action: nil, keyEquivalent: "")
        inputItem.submenu = inputs
        sub.addItem(inputItem)

        let reset = item("Reset this monitor", #selector(resetMonitor(_:)))
        reset.representedObject = m.uuid
        sub.addItem(reset)

        parent.submenu = sub
        return parent
    }

    private func sliderItem(_ title: String, _ lo: Double, _ hi: Double, _ value: Double, _ format: String,
                            _ onChange: @escaping (Double) -> Void) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = SliderView(title: title, min: lo, max: hi, value: value, format: format, onChange: onChange)
        return i
    }

    private func update(_ uuid: String, resync: Bool = true, _ change: (inout MonitorConfig) -> Void) {
        let old = config.monitors[uuid] ?? MonitorConfig()
        var c = old
        change(&c)
        guard c != old else { return }   // slider events that don't change the rounded value
        config.monitors[uuid] = c
        scheduleSave()
        if resync {
            lastSent.removeValue(forKey: uuid)
            lastContrast.removeValue(forKey: uuid)
            invalidated.insert(uuid)
            tick()   // apply immediately so a slider shows its effect while being dragged
        }
    }

    /// Coalesces slider drags into one disk write.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            saveConfig(self.config)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Coalesces slider drags into one DDC write.
    private func setVolume(_ uuid: String, _ value: Double) {
        volumeWork[uuid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async { ddc(["display", uuid, "set", "volume", String(Int(value))]) }
        }
        volumeWork[uuid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Actions

    @objc private func toggleSync() {
        config.paused.toggle()
        scheduleSave(); resyncAll(); updateIcon()
    }

    @objc private func toggleMonitor(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        update(uuid) { $0.sync.toggle() }
    }

    @objc private func resetMonitor(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        update(uuid) { $0 = MonitorConfig() }
        setVolume(uuid, MonitorConfig().volume)
    }

    @objc private func syncNow() { resyncAll(); tick() }

    @objc private func switchInput(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 3 else { return }
        let alert = NSAlert()
        alert.messageText = "Switch to \(parts[1])?"
        alert.informativeText = "The monitor will stop showing this Mac unless this Mac is connected to that input. "
            + "Use the monitor's own menu to switch back."
        alert.addButton(withTitle: "Switch"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        queue.async { ddc(["display", parts[0], "set", "input", parts[2]]) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change launch at login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        saveWork?.cancel(); saveConfig(config)   // flush a pending debounced save
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
