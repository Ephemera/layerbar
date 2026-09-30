import AppKit
import Carbon.HIToolbox
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
    var inputSourceColors: [String: String]?
}

/// Accepts "#RRGGBB" or "#RRGGBBAA".
func parseHexColor(_ hex: String) -> NSColor? {
    var text = hex.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6 || text.count == 8, var value = UInt32(text, radix: 16) else { return nil }
    if text.count == 6 { value = value << 8 | 0xFF }
    func channel(_ shift: UInt32) -> CGFloat { CGFloat(value >> shift & 0xFF) / 255 }
    return NSColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
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
    // input source ID prefix -> pill background; unlisted sources render as plain text
    var inputSourceColors: [String: NSColor] = [
        "org.youknowone.inputmethod.Gureum": NSColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 1),
        "com.apple.inputmethod.Korean": NSColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 1),
    ]

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
        "layers": ["Base", "QWERTY", "Tap", "Button", "Nav", "Mouse", "Media", "Num", "Sym", "Fun"],
        "inputSourceColors": {
            "org.youknowone.inputmethod.Gureum": "#FF8C00",
            "com.apple.inputmethod.Korean": "#FF8C00"
        }
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
            if let v = file.inputSourceColors {
                settings.inputSourceColors = v.compactMapValues { hex in
                    let color = parseHexColor(hex)
                    if color == nil { NSLog("invalid color, ignored: %@", hex) }
                    return color
                }
            }
        } catch {
            NSLog("config parse error, using defaults: %@", "\(error)")
        }
        return settings
    }

    func name(forLayer index: Int) -> String {
        index < layers.count ? layers[index] : "L\(index)"
    }

    /// Longest matching prefix wins, so a bundle ID covers all of its input modes.
    func color(forInputSource id: String?) -> NSColor? {
        guard let id else { return nil }
        return inputSourceColors.filter { id.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }
}

// MARK: - Input source

func currentInputSourceID() -> String? {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func pillImage(text: String, color: NSColor) -> NSImage {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.menuBarFont(ofSize: 0),
        .foregroundColor: NSColor.white,
    ]
    let textSize = (text as NSString).size(withAttributes: attributes)
    let padding: CGFloat = 6
    let size = NSSize(width: ceil(textSize.width) + padding * 2, height: ceil(textSize.height) + 2)
    return NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: padding, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
        return true
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
    private var inputSource = currentInputSourceID()
    private let inputSourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.addItem(inputSourceItem) // shows the ID to use in inputSourceColors
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LayerBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.items.last?.target = nil
        statusItem.menu = menu

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)

        render()
        startHID()
    }

    @objc private func inputSourceChanged() {
        inputSource = currentInputSourceID()
        render()
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
            let text = self.settings.prefix
                + (self.currentLayer.map { self.settings.name(forLayer: $0) } ?? self.settings.disconnectedText)
            self.inputSourceItem.title = "Input: \(self.inputSource ?? "unknown")"
            guard let button = self.statusItem.button else { return }
            if let color = self.settings.color(forInputSource: self.inputSource) {
                button.title = ""
                button.image = pillImage(text: text, color: color)
            } else {
                button.image = nil
                button.title = text
            }
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
