import AppKit
import IOKit.hid

// MARK: - Config

/// Accepts 7504, "7504", or "0x1D50".
struct FlexibleInt: Decodable {
    let value: Int
    init(_ value: Int) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
            return
        }
        let text = try container.decode(String.self).trimmingCharacters(in: .whitespaces)
        let isHex = text.lowercased().hasPrefix("0x")
        let digits = isHex ? String(text.dropFirst(2)) : text
        guard let parsed = Int(digits, radix: isHex ? 16 : 10) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number: \(text)")
        }
        value = parsed
    }
}

struct ConfigFile: Decodable {
    var vendorId: FlexibleInt?
    var productId: FlexibleInt?
    var usagePage: FlexibleInt?
    var usage: FlexibleInt?
    var prefix: String?
    var disconnectedText: String?
    var layers: [String]?
}

struct Settings {
    var vendorId = 0x1D50   // ZMK Project
    var productId = 0x615E  // Planck V6
    var usagePage = 0xFF60  // raw HID (zmk-feature-appcompanion)
    var usage = 0x61
    var prefix = "⌨\u{2009}"
    var disconnectedText = "–"
    // miryoku layer order (miryoku_layer_list.h)
    var layers = ["Base", "QWERTY", "Tap", "Button", "Nav", "Mouse", "Media", "Num", "Sym", "Fun"]

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/layerbar/config.json")

    static let defaultJSON = """
    {
        "vendorId": "0x1D50",
        "productId": "0x615E",
        "usagePage": "0xFF60",
        "usage": "0x61",
        "prefix": "⌨ ",
        "disconnectedText": "–",
        "layers": ["Base", "QWERTY", "Tap", "Button", "Nav", "Mouse", "Media", "Num", "Sym", "Fun"]
    }
    """

    static func load() -> Settings {
        var settings = Settings()
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? defaultJSON.write(to: url, atomically: true, encoding: .utf8)
            return settings
        }
        guard let data = try? Data(contentsOf: url) else { return settings }
        do {
            let file = try JSONDecoder().decode(ConfigFile.self, from: data)
            if let v = file.vendorId { settings.vendorId = v.value }
            if let v = file.productId { settings.productId = v.value }
            if let v = file.usagePage { settings.usagePage = v.value }
            if let v = file.usage { settings.usage = v.value }
            if let v = file.prefix { settings.prefix = v }
            if let v = file.disconnectedText { settings.disconnectedText = v }
            if let v = file.layers, !v.isEmpty { settings.layers = v }
        } catch {
            NSLog("config parse error, using defaults: %@", "\(error)")
        }
        return settings
    }

    func name(forLayer index: Int) -> String {
        index < layers.count ? layers[index] : "L\(index)"
    }
}

// MARK: - App

let marker: UInt8 = 0x90

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var manager: IOHIDManager?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var settings = Settings.load()
    private var currentLayer: Int?   // nil = disconnected

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LayerBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.items.last?.target = nil
        statusItem.menu = menu

        render()
        startHID()
    }

    @objc private func openConfig() {
        _ = Settings.load() // ensure the file exists
        NSWorkspace.shared.open(Settings.fileURL)
    }

    @objc private func reloadConfig() {
        let old = settings
        settings = Settings.load()
        let deviceChanged = old.vendorId != settings.vendorId || old.productId != settings.productId
            || old.usagePage != settings.usagePage || old.usage != settings.usage
        if deviceChanged {
            stopHID()
            currentLayer = nil
            startHID()
        }
        render()
    }

    private func render() {
        DispatchQueue.main.async {
            let text = self.currentLayer.map { self.settings.name(forLayer: $0) } ?? self.settings.disconnectedText
            self.statusItem.button?.title = self.settings.prefix + text
        }
    }

    private func startHID() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: settings.vendorId,
            kIOHIDProductIDKey: settings.productId,
            kIOHIDDeviceUsagePageKey: settings.usagePage,
            kIOHIDDeviceUsageKey: settings.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue().deviceConnected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            let me = Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue()
            me.currentLayer = nil
            me.render()
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            NSLog("IOHIDManagerOpen failed: 0x%08x", result)
        }
    }

    private func stopHID() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func deviceConnected(_ device: IOHIDDevice) {
        currentLayer = 0 // keyboard boots into layer 0
        render()
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, report, length in
            Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue().handleReport(report, length)
        }, context)
    }

    fileprivate func handleReport(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        // 32-byte report: byte 24 = 0x90 marker, byte 25 = active layer.
        // Tolerate a leading report-id byte shifting everything by one.
        var layer = -1
        if length >= 26, report[24] == marker {
            layer = Int(report[25])
        } else if length >= 27, report[25] == marker {
            layer = Int(report[26])
        }
        guard layer >= 0 else { return }
        currentLayer = layer
        render()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
