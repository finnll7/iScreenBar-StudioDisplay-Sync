import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid
import ObjectiveC.runtime
import SwiftUI
import UniformTypeIdentifiers

private let benqVendorID = 0x04A5
private let iScreenBarProductID = 0x2501
private let appleDisplayVendorID: UInt32 = 0x0610
private let studioDisplayProductID: UInt32 = 0xAE46
private let pollInterval: TimeInterval = 0.25

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

/// 版本与构建时间（从 bundle 读取，发版时只改 Info.plist）。
private func appVersionText() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    var stamp = "—"
    if let url = Bundle.main.executableURL,
       let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        stamp = formatter.string(from: date)
    }
    return "v\(short) (\(build)) · 构建 \(stamp)"
}

/// 两个实例同时写同一个灯体会造成开关抖动，因此只保留先启动的实例。
/// 重装时旧进程可能尚未回收，先短暂等待，避免把刚启动的新实例误杀。
private func enforceSingleInstance() {
    let me = ProcessInfo.processInfo.processIdentifier
    let identifier = Bundle.main.bundleIdentifier ?? "local.qiu.iScreenBarStudioSync"
    func otherInstance() -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }
    for attempt in 0..<80 {
        guard let other = otherInstance() else { return }
        if attempt == 0 {
            log("检测到已有实例在运行：pid \(other.processIdentifier) 路径 \(other.bundleURL?.path ?? "未知")，等待其退出")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if let other = otherInstance() {
        log("已有实例持续运行中（pid \(other.processIdentifier) 路径 \(other.bundleURL?.path ?? "未知")），本实例退出以免重复写灯体")
        exit(0)
    }
}

enforceSingleInstance()

private let activeControlColor = NSColor.controlAccentColor

private func requestSystemDisplaySleep() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["displaysleepnow"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        log("无法请求系统关闭显示器：\(error.localizedDescription)")
        return false
    }
}

private func requestSystemDisplayWake() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    // -u 只在断言存续期内阻止熄屏。实测 -t 2 的断言一过期，powerd 会因
    // “距上次键鼠活动过久”立即重新变暗并熄屏（屏幕只亮约 12 秒），
    // 刚入座还没碰到键盘的人就会遇到“解锁→又锁屏”。给 90 秒落座缓冲。
    process.arguments = ["-u", "-t", "90"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        return true
    } catch {
        log("无法请求系统点亮显示器：\(error.localizedDescription)")
        return false
    }
}

private enum UIStyle {
    static let panelWidth: CGFloat = 344
    static let contentWidth: CGFloat = 312
    static let outerInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 8
    static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let controlFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let iconSize: CGFloat = 15
}

private final class HighlightSliderCell: NSSliderCell {
    let activeColor: NSColor
    var isInteracting = false

    init(activeColor: NSColor) {
        self.activeColor = activeColor
        super.init()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard isInteracting else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        activeColor.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
    }
}

private final class InteractiveSlider: NSSlider {
    private let activeColor: NSColor
    private let highlightCell: HighlightSliderCell
    /// 拖动开始/结束回调，用于在拖动期间实显数值与限速下发。
    var onTrackingChanged: ((Bool) -> Void)?

    init(value: Double, minValue: Double, maxValue: Double, activeColor: NSColor) {
        self.activeColor = activeColor
        highlightCell = HighlightSliderCell(activeColor: activeColor)
        super.init(frame: .zero)
        cell = highlightCell
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onTrackingChanged?(true)
        highlightCell.isInteracting = true
        needsDisplay = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            layer?.backgroundColor = activeColor.withAlphaComponent(0.14).cgColor
        }
        super.mouseDown(with: event)
        highlightCell.isInteracting = false
        needsDisplay = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        onTrackingChanged?(false)
    }
}

private func displayPowerIcon() -> NSImage {
    let size = NSSize(width: 21, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        let displayConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let powerConfig = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        let display = NSImage(systemSymbolName: "display", accessibilityDescription: "内屏开关")?
            .withSymbolConfiguration(displayConfig)
        let power = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?
            .withSymbolConfiguration(powerConfig)
        display?.draw(in: rect)
        power?.draw(in: NSRect(x: 7, y: 6, width: 7, height: 7))
        return true
    }
    image.isTemplate = true
    return image
}

private final class FeatureButton: NSButton {
    private let accentColor: NSColor

    init(title: String, symbol: String, accentColor: NSColor) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageLeading
        imageHugsTitle = true
        font = UIStyle.controlFont
        alignment = .center
        setButtonType(.toggle)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        layer?.shadowRadius = 6
        focusRingType = .none
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue {
        didSet {
            guard oldValue != state else { return }
            updateAppearance()
        }
    }

    override func updateLayer() {
        super.updateLayer()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        let foregroundColor: NSColor = state == .on ? .white : .black
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIStyle.controlFont,
            .foregroundColor: foregroundColor
        ]
        attributedTitle = NSAttributedString(string: title, attributes: titleAttributes)
        if state == .on {
            layer.backgroundColor = accentColor.withAlphaComponent(0.88).cgColor
            layer.borderColor = accentColor.cgColor
            layer.shadowColor = accentColor.withAlphaComponent(0.18).cgColor
            layer.shadowOpacity = 1
            contentTintColor = .white
        } else {
            layer.backgroundColor = NSColor.black.withAlphaComponent(0.045).cgColor
            layer.borderColor = NSColor.black.withAlphaComponent(0.09).cgColor
            layer.shadowColor = NSColor.clear.cgColor
            layer.shadowOpacity = 0
            contentTintColor = .black
        }
        layer.borderWidth = 0.5
    }
}

/// 复刻 NotchNotes 的双层防休眠：caffeinate 负责空闲断言，
/// pmset disablesleep 负责合盖等强制休眠路径。两者都绑定当前 App PID。
private final class KeepAwakeController {
    private var caffeinateProcess: Process?
    private var sleepGuardProcess: Process?
    private var readyFileURL: URL?
    private var stopFileURL: URL?

    var isActive: Bool {
        caffeinateProcess?.isRunning == true &&
            (sleepGuardProcess?.isRunning == true || readyFileURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } == true)
    }

    @discardableResult
    func setActive(_ active: Bool) -> Bool {
        if active {
            guard !isActive else { return true }
            setActive(false)

            let token = UUID().uuidString
            let base = "iScreenBar-KeepAwake-\(ProcessInfo.processInfo.processIdentifier)-\(token)"
            let temporaryDirectory = FileManager.default.temporaryDirectory
            let ready = temporaryDirectory.appendingPathComponent(base).appendingPathExtension("ready")
            let stop = temporaryDirectory.appendingPathComponent(base).appendingPathExtension("stop")
            let pid = ProcessInfo.processInfo.processIdentifier
            let readyPath = Self.shellQuote(ready.path)
            let stopPath = Self.shellQuote(stop.path)
            let command = [
                "owned=0",
                "cleanup() { if [ \"$owned\" = 1 ]; then /usr/bin/pmset -a disablesleep 0; fi; /bin/rm -f \(readyPath) \(stopPath); }",
                "trap cleanup 0",
                "trap 'exit 1' 1 2 15",
                "if ! /usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1'; then /usr/bin/pmset -a disablesleep 1 || exit 1; owned=1; fi",
                "/usr/bin/pmset -g | /usr/bin/grep -Eq 'SleepDisabled[[:space:]]+1' || exit 1",
                "/usr/bin/touch \(readyPath) || exit 1",
                "while /bin/kill -0 \(pid) 2>/dev/null && [ ! -e \(stopPath) ]; do /bin/sleep 1; done"
            ].joined(separator: "; ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "with timeout of 2147483647 seconds\n do shell script \"\(escaped)\" with administrator privileges\nend timeout"

            let guardProcess = Process()
            guardProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            guardProcess.arguments = ["-e", appleScript]
            guardProcess.standardOutput = FileHandle.nullDevice
            guardProcess.standardError = FileHandle.nullDevice

            let caffeinate = Process()
            caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            // 阻止系统、磁盘和空闲休眠，但允许显示器正常熄灭。
            caffeinate.arguments = ["-ims", "-w", String(pid)]
            do {
                try guardProcess.run()
                try caffeinate.run()
                sleepGuardProcess = guardProcess
                caffeinateProcess = caffeinate
                readyFileURL = ready
                stopFileURL = stop
                guardProcess.terminationHandler = { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self,
                              self.readyFileURL == ready,
                              !FileManager.default.fileExists(atPath: ready.path) else { return }
                        if let caffeinate = self.caffeinateProcess, caffeinate.isRunning {
                            caffeinate.terminate()
                        }
                        self.caffeinateProcess = nil
                        self.sleepGuardProcess = nil
                        self.readyFileURL = nil
                        self.stopFileURL = nil
                        log("防止休眠授权被取消或启动失败")
                    }
                }
                return true
            } catch {
                if guardProcess.isRunning { guardProcess.terminate() }
                if caffeinate.isRunning { caffeinate.terminate() }
                try? FileManager.default.removeItem(at: ready)
                try? FileManager.default.removeItem(at: stop)
                log("无法启动防止休眠：\(error.localizedDescription)")
                return false
            }
        }

        if let stopFileURL {
            FileManager.default.createFile(atPath: stopFileURL.path, contents: Data())
        }
        if let caffeinateProcess, caffeinateProcess.isRunning { caffeinateProcess.terminate() }
        caffeinateProcess = nil
        sleepGuardProcess = nil
        readyFileURL = nil
        stopFileURL = nil
        return true
    }

    deinit { _ = setActive(false) }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// 保留 macOS 开关的尺寸与滑块形态，只固定开启态的高亮颜色。
private final class AccentSwitch: NSButton {
    private let accentColor: NSColor
    private let knobLayer = CALayer()

    init(accentColor: NSColor = .systemBlue) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        title = ""
        setButtonType(.toggle)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.18
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = NSSize(width: 0, height: -0.5)
        layer?.addSublayer(knobLayer)
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }

    override var state: NSControl.StateValue {
        didSet {
            // 面板每 250ms 刷新一次状态；值未变时不重启动画，否则会持续闪炼。
            guard oldValue != state else { return }
            updateAppearance(animated: window != nil)
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            updateAppearance(animated: false)
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        guard let layer else { return }
        let knobSize = max(0, bounds.height - 4)
        let knobX = state == .on ? max(2, bounds.width - knobSize - 2) : 2
        let changes = {
            layer.backgroundColor = (self.state == .on
                ? self.accentColor
                : NSColor.systemGray.withAlphaComponent(0.34)).cgColor
            layer.opacity = self.isEnabled ? 1 : 0.45
            self.knobLayer.cornerRadius = knobSize / 2
            self.knobLayer.frame = NSRect(x: knobX, y: 2, width: knobSize, height: knobSize)
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            changes()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }
}

private struct SavedMode: Codable {
    let name: String
    let brightness: Int
    let temperature: Int
    let videoMode: Bool
}

private struct DisplayPreset: Codable {
    var name: String
    var builtinEnabled: Bool
    var rotation: Int
    var builtinPrimary: Bool
}

private final class BlackDisplayView: NSView {
    var restore: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { restore?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }
}

private final class DisplayController {
    private var studioCover: NSWindow?
    var isStudioCovered: Bool { studioCover != nil }

    func studioTarget() -> CGDirectDisplayID? {
        return NSScreen.screens.first {
            $0.localizedName.replacingOccurrences(of: " ", with: "").lowercased().contains("studiodisplay")
        }.flatMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    }

    func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return true }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? true
    }

    func setStudioEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            studioCover?.orderOut(nil)
            studioCover = nil
            return true
        }
        guard let id = studioTarget(), let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return false }
        if studioCover != nil { return true }
        // 仅绘制遮罩，不更改显示器电源、亮度、分辨率、主屏和窗口布局。
        let cover = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.hasShadow = false
        cover.isReleasedWhenClosed = false
        cover.level = .statusBar
        cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = BlackDisplayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.restore = { [weak self] in _ = self?.setStudioEnabled(true) }
        cover.contentView = view
        studioCover = cover
        cover.orderFrontRegardless()
        return true
    }
    private typealias GetDisplayList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private let skyLightHandle: UnsafeMutableRawPointer?
    private let monitorPanelHandle: UnsafeMutableRawPointer?
    private let getDisplayList: GetDisplayList?
    private let configureEnabled: ConfigureEnabled?
    private var lastKnownBuiltinDisplayID: CGDirectDisplayID?

    init() {
        skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        monitorPanelHandle = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
        if let handle = skyLightHandle, let symbol = dlsym(handle, "CGSGetDisplayList") {
            getDisplayList = unsafeBitCast(symbol, to: GetDisplayList.self)
        } else { getDisplayList = nil }
        if let handle = skyLightHandle, let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
            configureEnabled = unsafeBitCast(symbol, to: ConfigureEnabled.self)
        } else { configureEnabled = nil }
        _ = builtinDisplay()
    }

    deinit {
        if let skyLightHandle { dlclose(skyLightHandle) }
        if let monitorPanelHandle { dlclose(monitorPanelHandle) }
    }

    var isAvailable: Bool { getDisplayList != nil && configureEnabled != nil && monitorPanelHandle != nil }

    private func displays() -> [CGDirectDisplayID] {
        guard let getDisplayList else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard getDisplayList(32, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func isGhost(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) == 0 && CGDisplayVendorNumber(id) == 0 &&
            CGDisplayModelNumber(id) == 0 && CGDisplaySerialNumber(id) == 0
    }

    func builtinDisplay() -> CGDirectDisplayID? {
        if let builtin = displays().first(where: { CGDisplayIsBuiltin($0) != 0 && !isGhost($0) }) {
            lastKnownBuiltinDisplayID = builtin
            return builtin
        }
        if let cached = lastKnownBuiltinDisplayID, CGDisplayIsBuiltin(cached) != 0 {
            return cached
        }
        return nil
    }

    func externalDisplays() -> [CGDirectDisplayID] {
        displays().filter {
            CGDisplayIsBuiltin($0) == 0 && !isGhost($0) && CGDisplayIsOnline($0) != 0 &&
                CGDisplayIsActive($0) != 0 && (CGDisplayVendorNumber($0) != 0 || CGDisplayModelNumber($0) != 0)
        }
    }

    func currentPreset(name: String) -> DisplayPreset? {
        guard let builtin = builtinDisplay() else { return nil }
        return DisplayPreset(name: name,
                             builtinEnabled: CGDisplayIsOnline(builtin) != 0,
                             rotation: Int(CGDisplayRotation(builtin).rounded()),
                             builtinPrimary: CGMainDisplayID() == builtin)
    }

    private func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool, temporary: Bool = false) -> Bool {
        guard let configureEnabled else {
            log("显示器切换失败：CGSConfigureDisplayEnabled 不可用")
            return false
        }
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success, let config else {
            log("显示器 \(id) 切换失败：CGBeginDisplayConfiguration=\(beginResult.rawValue)")
            return false
        }
        if !enabled, CGDisplayIsInMirrorSet(id) != 0,
           CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay) != .success {
            CGCancelDisplayConfiguration(config); return false
        }
        let configureResult = configureEnabled(config, id, enabled)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(config)
            log("显示器 \(id) 切换失败：CGSConfigureDisplayEnabled=\(configureResult.rawValue)，目标状态=\(enabled)")
            return false
        }
        let completeResult = CGCompleteDisplayConfiguration(config, temporary ? .forSession : .permanently)
        if completeResult != .success {
            log("显示器 \(id) 切换失败：CGCompleteDisplayConfiguration=\(completeResult.rawValue)，目标状态=\(enabled)")
        }
        return completeResult == .success
    }

    func enableBuiltin(force: Bool = false) -> Bool {
        for attempt in 0..<3 {
            guard let builtin = builtinDisplay() else {
                log("内屏启用失败：当前无法解析内屏 ID")
                return false
            }
            // Online 只表示显示器被枚举到，禁用后的面板仍可能 Online 但不 Active。
            if !force, CGDisplayIsOnline(builtin) != 0, CGDisplayIsActive(builtin) != 0 { return true }
            let submitted = setEnabled(builtin, true)
            log("内屏启用请求：ID=\(builtin)，提交=\(submitted)，online=\(CGDisplayIsOnline(builtin))，active=\(CGDisplayIsActive(builtin))，asleep=\(CGDisplayIsAsleep(builtin))")
            if submitted, CGDisplayIsOnline(builtin) != 0, CGDisplayIsActive(builtin) != 0 { return true }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.4) }
        }
        return false
    }

    func builtinIsAwake() -> Bool {
        guard let builtin = builtinDisplay() else { return false }
        return CGDisplayIsOnline(builtin) != 0 && CGDisplayIsActive(builtin) != 0 && CGDisplayIsAsleep(builtin) == 0
    }

    func disableBuiltin() -> Bool {
        guard !externalDisplays().isEmpty, let builtin = builtinDisplay() else { return false }
        if CGDisplayIsOnline(builtin) == 0 { return true }
        return setEnabled(builtin, false) && CGDisplayIsOnline(builtin) == 0
    }

    func restoreBuiltinDefault() -> Bool {
        guard enableBuiltin(),
              let builtin = builtinDisplay(),
              CGDisplayIsOnline(builtin) != 0 else { return false }
        let rotationRestored = Int(CGDisplayRotation(builtin).rounded()) == 0 || rotateBuiltin(to: 0)
        let primaryRestored = CGMainDisplayID() == builtin || makePrimary(builtin)
        return rotationRestored && primaryRestored
    }

    func rotateBuiltin(to degrees: Int) -> Bool {
        guard let builtin = builtinDisplay(), CGDisplayIsOnline(builtin) != 0,
              let cls: AnyClass = NSClassFromString("MPDisplay"),
              let rawObject = class_createInstance(cls, 0) else { return false }
        let object = rawObject as AnyObject
        let initSelector = NSSelectorFromString("initWithCGSDisplayID:")
        let setSelector = NSSelectorFromString("setOrientation:")
        guard let initMethod = class_getInstanceMethod(cls, initSelector),
              let setMethod = class_getInstanceMethod(cls, setSelector) else { return false }
        typealias InitFunction = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>
        typealias SetFunction = @convention(c) (AnyObject, Selector, Int32) -> Void
        // class_createInstance 已持有对象；init 返回同一实例，不能再次按 retained 接管，
        // 否则函数结束时会重复 release，并在启用旋转预设时触发 EXC_BAD_ACCESS。
        let initialized = unsafeBitCast(method_getImplementation(initMethod), to: InitFunction.self)(object, initSelector, builtin).takeUnretainedValue()
        unsafeBitCast(method_getImplementation(setMethod), to: SetFunction.self)(initialized, setSelector, Int32(degrees))
        return true
    }

    func makePrimary(_ target: CGDirectDisplayID) -> Bool {
        let targetBounds = CGDisplayBounds(target)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for display in displays() where CGDisplayIsOnline(display) != 0 && !isGhost(display) {
            let bounds = CGDisplayBounds(display)
            let error = CGConfigureDisplayOrigin(config, display,
                Int32(bounds.origin.x - targetBounds.origin.x), Int32(bounds.origin.y - targetBounds.origin.y))
            if error != .success { CGCancelDisplayConfiguration(config); return false }
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    func apply(_ preset: DisplayPreset) -> Bool {
        if preset.builtinEnabled {
            guard enableBuiltin(), let builtin = builtinDisplay() else { return false }
            _ = rotateBuiltin(to: preset.rotation)
            let primary = preset.builtinPrimary ? builtin : (externalDisplays().first ?? builtin)
            if CGMainDisplayID() != primary { _ = makePrimary(primary) }
            return true
        }
        guard let external = externalDisplays().first else { return false }
        if let builtin = builtinDisplay(), CGDisplayIsOnline(builtin) != 0 {
            _ = rotateBuiltin(to: preset.rotation)
            _ = makePrimary(external)
        }
        return disableBuiltin()
    }
}

private final class StatusIndicator: NSObject {
    private let presenceDelayOptions = [180, 300, 600]
    private let readingModeBrightness = 70
    private let readingModeTemperature = 4200
    private let item: NSStatusItem
    private let lamp: LampController
    private let popover = NSPopover()
    private let powerSwitch = FeatureButton(title: "灯光", symbol: "power", accentColor: activeControlColor)
    private let brightnessSlider = InteractiveSlider(value: 50, minValue: 1, maxValue: 100, activeColor: .systemBlue)
    private let brightnessValueLabel = NSTextField(labelWithString: "50%")
    private let temperatureSlider = InteractiveSlider(value: 5000, minValue: 2700, maxValue: 6500, activeColor: .systemYellow)
    private let temperatureValueLabel = NSTextField(labelWithString: "5000K")
    private let timeTemperatureSwitch = FeatureButton(title: "自动色温", symbol: "circle.lefthalf.filled", accentColor: activeControlColor)
    private let autoLightSwitch = FeatureButton(title: "自动感光", symbol: "sun.max", accentColor: activeControlColor)
    private let presenceSwitch = FeatureButton(title: "入座检测", symbol: "figure.seated.side", accentColor: activeControlColor)
    private let presenceDelayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presenceSensitivityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var presenceDelaySeconds = 180
    private var presenceSensitivity = 2
    private let videoModeSwitch = FeatureButton(title: "视频模式", symbol: "video", accentColor: activeControlColor)
    private let modeButton = NSButton(title: "我的最爱", target: nil, action: nil)
    private let rotationModeButton = NSButton(title: "竖屏双屏", target: nil, action: nil)
    private var modeCenterWindow: NSWindow?
    private let bindAppButton = NSButton(title: "绑定应用", target: nil, action: nil)
    private let brightnessFollowSwitch = FeatureButton(title: "亮度跟随", symbol: "display", accentColor: activeControlColor)
    private let displayBrightnessLockSwitch = FeatureButton(title: "双屏亮度", symbol: "rectangle.on.rectangle", accentColor: activeControlColor)
    private let powerSyncSwitch = FeatureButton(title: "熄屏同步", symbol: "moon.zzz", accentColor: activeControlColor)
    private let keepAwakeSwitch = FeatureButton(title: "防止休眠", symbol: "cup.and.saucer", accentColor: activeControlColor)
    private let readingModeSwitch = FeatureButton(title: "阅读模式", symbol: "book", accentColor: .systemGreen)
    private let comboPolicySwitch = FeatureButton(title: "智能组合", symbol: "wand.and.stars", accentColor: .systemPurple)
    private let comboStatusLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let keepAwakeController = KeepAwakeController()
    private let captureBrightButton = FeatureButton(title: "明亮关灯", symbol: "sun.max.fill", accentColor: .systemOrange)
    private let captureDarkButton = FeatureButton(title: "昏暗开灯", symbol: "moon.fill", accentColor: .systemBlue)
    private let ambientEnableSwitch = AccentSwitch()
    private let brightThresholdField = StatusIndicator.thresholdField()
    private let darkThresholdField = StatusIndicator.thresholdField()
    private let ambientStatusLabel = NSTextField(labelWithString: "尚未完成环境标定")
    private let displayPowerSwitch: FeatureButton = {
        let button = FeatureButton(title: "内屏", symbol: "display", accentColor: activeControlColor)
        button.image = displayPowerIcon()
        return button
    }()
    private let displayRotateButton = FeatureButton(title: "旋转 0°", symbol: "arrow.clockwise", accentColor: activeControlColor)
    private let studioPowerSwitch = FeatureButton(title: "Studio Display", symbol: "display", accentColor: activeControlColor)
    private let displayAutoPresetSwitch = AccentSwitch()
    private let displayController = DisplayController()
    private(set) var isBrightnessFollowEnabled: Bool
    private(set) var isDisplayBrightnessLockEnabled: Bool
    private(set) var isPowerSyncEnabled: Bool
    private(set) var isTimeTemperatureEnabled: Bool
    private(set) var isReadingModeEnabled: Bool
    private(set) var isComboPolicyEnabled: Bool
    /// 手动调过灯后的一段时间内，策略引擎不覆写用户设置。
    var comboManualOverrideUntil = Date.distantPast
    private(set) var ambientCloseThreshold: Int?
    private(set) var ambientOpenThreshold: Int?
    private(set) var currentDisplayAmbientProxy: Int?
    private var currentAmbientSourceName = "显示器"
    private var ambientThresholdSource: String?
    private var areAmbientRulesEnabled: Bool
    private var isDisplayAutoPresetEnabled: Bool
    private var didSyncPresenceSettings = false
    /// 入座检测是否被策略临时停用（面板需要提示，避免看起来像故障）。
    private(set) var isPresenceSuspendedByPolicy = false
    private let panelModel = PanelModel()
    private var glassHostController: NSViewController?
    private var isHealthy = true
    private var isStudioDisplayAvailable = false
    private let standbyLabel = NSTextField(labelWithString: "未检测到 Studio Display，功能待机")
    private var isAsleep: Bool
    private var autoLightChangePendingUntil: Date?
    private var pendingAutoLightState: Bool?
    private var lastScheduledTemperature: Int?
    private var lastScheduledTemperatureChangeAt = Date.distantPast
    private var lastFrontmostBundleID: String?
    private var isAmbientPresenceLockActive = false
    private var presenceWasEnabledBeforeAmbientLock = false
    private var autoLightWasEnabledBeforeAmbientLock = false
    private var isScreenSleepPresenceLockActive = false
    private var presenceWasEnabledBeforeScreenSleep = false
    private var isDisplaySessionSafe = false
    private var pendingDisplayConnectionState: Bool?
    private var pendingDisplayPolicyWorkItem: DispatchWorkItem?
    private var pendingBuiltinWakeWorkItems: [DispatchWorkItem] = []
    private var didRequestDisplaySleepForCurrentLidClosure = false
    /// 点采集按钮后短暂忽略输入框结束编辑的回写，避免旧文本覆盖新采集值。
    private var thresholdCommitSuppressedUntil = Date.distantPast
    /// 滑块拖动中的实时数值与限速写入状态。
    private var isBrightnessSliderTracking = false
    private var isTemperatureSliderTracking = false
    private var lastSliderWriteAt = Date.distantPast
    private var pendingBrightnessValue: Int?
    private var pendingTemperatureValue: Int?

    /// 用户正在拖滑块时，策略引擎不覆写亮度色温。
    var isUserAdjustingLamp: Bool { isBrightnessSliderTracking || isTemperatureSliderTracking }

    private var isBuiltinManuallyDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: "builtinManuallyDisabled") }
        set { UserDefaults.standard.set(newValue, forKey: "builtinManuallyDisabled") }
    }

    init(isAsleep: Bool, lamp: LampController) {
        self.lamp = lamp
        self.isAsleep = isAsleep
        isBrightnessFollowEnabled = UserDefaults.standard.bool(forKey: "brightnessFollowEnabled")
        isDisplayBrightnessLockEnabled = UserDefaults.standard.bool(forKey: "displayBrightnessLockEnabled")
        isPowerSyncEnabled = UserDefaults.standard.object(forKey: "powerSyncEnabled") as? Bool ?? true
        isTimeTemperatureEnabled = UserDefaults.standard.bool(forKey: "timeTemperatureEnabled")
        isReadingModeEnabled = UserDefaults.standard.bool(forKey: "readingModeEnabled")
        isComboPolicyEnabled = UserDefaults.standard.bool(forKey: "comboPolicyEnabled")
        ambientCloseThreshold = UserDefaults.standard.object(forKey: "ambientCloseThreshold") as? Int
        ambientOpenThreshold = UserDefaults.standard.object(forKey: "ambientOpenThreshold") as? Int
        ambientThresholdSource = UserDefaults.standard.string(forKey: "ambientThresholdSource")
        areAmbientRulesEnabled = UserDefaults.standard.object(forKey: "ambientRulesEnabled") as? Bool
            ?? (ambientCloseThreshold != nil || ambientOpenThreshold != nil)
        // 组合模式下旧环境光规则由策略引擎接管，避免两套逻辑同时写电源。
        if isComboPolicyEnabled, areAmbientRulesEnabled {
            areAmbientRulesEnabled = false
            UserDefaults.standard.set(false, forKey: "ambientRulesEnabled")
        }
        UserDefaults.standard.removeObject(forKey: "ambientLinkEnabled")
        if ambientThresholdSource != "studioDisplayALS-v1" {
            ambientCloseThreshold = nil
            ambientOpenThreshold = nil
            areAmbientRulesEnabled = false
        }
        presenceWasEnabledBeforeAmbientLock = UserDefaults.standard.bool(forKey: "ambientSuspendedPresenceWasEnabled")
        autoLightWasEnabledBeforeAmbientLock = UserDefaults.standard.bool(forKey: "ambientSuspendedAutoLightWasEnabled")
        isAmbientPresenceLockActive = presenceWasEnabledBeforeAmbientLock || autoLightWasEnabledBeforeAmbientLock
        presenceWasEnabledBeforeScreenSleep = UserDefaults.standard.bool(forKey: "screenSleepSuspendedPresenceWasEnabled")
        isScreenSleepPresenceLockActive = presenceWasEnabledBeforeScreenSleep
        isDisplayAutoPresetEnabled = UserDefaults.standard.bool(forKey: "displayAutoPresetEnabled")
        presenceDelaySeconds = UserDefaults.standard.object(forKey: "presenceDelaySeconds") as? Int ?? 180
        if !presenceDelayOptions.contains(presenceDelaySeconds) {
            presenceDelaySeconds = 180
        }
        presenceSensitivity = UserDefaults.standard.object(forKey: "presenceSensitivity") as? Int ?? 2
        presenceSensitivity = max(0, min(2, presenceSensitivity))
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        migrateDisplayPresetIfNeeded()
        configurePanel()
        installGlassPanel()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(displaySessionBecameUnsafe(_:)),
                                           name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(displaySessionBecameUnsafe(_:)),
                                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(displaySessionBecameActive),
                                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(displaySessionBecameActive),
                                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        scheduleDisplaySessionActivation()
        update(isAsleep: isAsleep, healthy: true)
    }

    func update(isAsleep: Bool, healthy: Bool) {
        self.isAsleep = isAsleep
        isHealthy = healthy
        handleKeepAwakeLidDisplayState()
        if lamp.isAutoLightEnabled == true, isBrightnessFollowEnabled {
            isBrightnessFollowEnabled = false
            brightnessFollowSwitch.state = .off
            UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
            log("检测到灯具自动感光已开启，已自动关闭 Studio Display 亮度跟随")
        }
        updateIcon(healthy: healthy)
        let displayState = isAsleep ? "Studio Display 已熄屏" : "Studio Display 已唤醒"
        let brightnessStatus = isBrightnessFollowEnabled ? "亮度跟随已开启" : "亮度跟随已关闭"
        let powerStatus = isPowerSyncEnabled ? "熄屏同步已开启" : "熄屏同步已关闭"
        let status = isStudioDisplayAvailable ? (healthy ? "同步正常" : "同步异常") : "待机"
        _ = (displayState, brightnessStatus, powerStatus)
        if !isStudioDisplayAvailable {
            item.button?.toolTip = "待机 · 未连接 Studio Display"
        } else {
            let brightnessText = healthy ? lamp.currentBrightness.map { "\($0)%" } ?? "--%" : "--%"
            let temperatureText = healthy ? lamp.currentTemperature.map { "\($0)K" } ?? "----K" : "----K"
            item.button?.toolTip = "\(brightnessText) · \(temperatureText)"
        }
        item.button?.setAccessibilityLabel("iScreenBar \(status)")
        if displayController.isStudioCovered,
           (displayController.studioTarget() == nil || isConsoleSessionLocked()) {
            _ = displayController.setStudioEnabled(true)
        }
        if popover.isShown { refreshControls() }
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if isStudioDisplayAvailable { lamp.requestStatus() }
            refreshControls()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// 仅当 Apple 厂商 + Studio Display 型号均匹配时启用全部功能，否则保持常驻待机。
    func setStudioDisplayAvailable(_ available: Bool) {
        guard isStudioDisplayAvailable != available else { return }
        isStudioDisplayAvailable = available
        updateIcon(healthy: isHealthy)
        if popover.isShown { refreshControls() }
        log(available ? "已识别 Studio Display，功能启用" : "未检测到 Studio Display，功能进入待机")
    }

    @objc private func powerChanged() {
        let requested = powerSwitch.state == .on
        markManualOverride(seconds: 1800)
        if !lamp.setPower(on: requested) { powerSwitch.state = requested ? .off : .on }
        updateIcon(healthy: isHealthy && lamp.isConnected)
        lamp.requestStatus()
    }

    @objc private func captureBrightThreshold() {
        // 先结束正在进行的输入，再采集：保证采集值最终生效，不被旧文本回写。
        endThresholdEditingForCapture()
        guard let value = currentDisplayAmbientProxy else {
            captureBrightButton.state = .off
            ambientStatusLabel.stringValue = "暂时无法读取 Studio Display 光线传感器"
            NSSound.beep()
            return
        }
        applyAmbientThreshold(value, isClose: true)
        flashCaptureSuccess(button: captureBrightButton, valueLabel: brightThresholdField)
        log("已采集环境关灯点：\(currentAmbientSourceName) 响应分数 \(value)")
    }

    /// 手动填写或采集后统一写入标定值，保证持久化键与数据源一致。
    private func applyAmbientThreshold(_ value: Int, isClose: Bool) {
        if isClose {
            ambientCloseThreshold = value
            UserDefaults.standard.set(value, forKey: "ambientCloseThreshold")
        } else {
            ambientOpenThreshold = value
            UserDefaults.standard.set(value, forKey: "ambientOpenThreshold")
        }
        ambientThresholdSource = "studioDisplayALS-v1"
        UserDefaults.standard.set("studioDisplayALS-v1", forKey: "ambientThresholdSource")
        updateAmbientStatusLabel()
    }

    /// 采集按钮与输入框共存：点采集时先取消编辑，并在短时间内忽略结束编辑的回写。
    private func endThresholdEditingForCapture() {
        thresholdCommitSuppressedUntil = Date().addingTimeInterval(0.5)
        if brightThresholdField.currentEditor() != nil || darkThresholdField.currentEditor() != nil {
            brightThresholdField.window?.makeFirstResponder(nil)
        }
    }

    @objc private func ambientThresholdFieldEdited(_ sender: NSTextField) {
        commitAmbientThreshold(from: sender)
    }

    private func commitAmbientThreshold(from field: NSTextField) {
        guard Date() >= thresholdCommitSuppressedUntil else {
            // 刚刚点过采集按钮：丢弃过期的编辑内容，避免覆盖采集结果。
            syncThresholdFields(force: true)
            return
        }
        let isClose = field === brightThresholdField
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Int(text), value >= 0, value <= 60000 else {
            NSSound.beep()
            syncThresholdFields(force: true)
            if !text.isEmpty { ambientStatusLabel.stringValue = "标定值需为 0–60000 的整数" }
            return
        }
        let unchanged = isClose ? ambientCloseThreshold == value : ambientOpenThreshold == value
        applyAmbientThreshold(value, isClose: isClose)
        if !unchanged {
            log("已手动设置环境\(isClose ? "关灯点" : "开灯点")：\(value)")
        }
        flashCaptureSuccess(button: isClose ? captureBrightButton : captureDarkButton, valueLabel: field)
    }

    @objc private func captureDarkThreshold() {
        endThresholdEditingForCapture()
        guard let value = currentDisplayAmbientProxy else {
            captureDarkButton.state = .off
            ambientStatusLabel.stringValue = "暂时无法读取 Studio Display 光线传感器"
            NSSound.beep()
            return
        }
        applyAmbientThreshold(value, isClose: false)
        flashCaptureSuccess(button: captureDarkButton, valueLabel: darkThresholdField)
        log("已采集环境开灯点：\(currentAmbientSourceName) 响应分数 \(value)")
    }

    private func flashCaptureSuccess(button: FeatureButton, valueLabel: NSTextField) {
        button.state = .on
        valueLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak button, weak valueLabel] in
            button?.state = .off
            valueLabel?.textColor = .secondaryLabelColor
        }
    }

    @objc private func ambientEnableChanged() {
        areAmbientRulesEnabled = ambientEnableSwitch.state == .on
        UserDefaults.standard.set(areAmbientRulesEnabled, forKey: "ambientRulesEnabled")
        updateAmbientStatusLabel()
        log(areAmbientRulesEnabled ? "已启用保存的环境光规则" : "已停用环境光规则，保留标定数值")
    }

    func updateDisplayAmbientProxy(_ value: Int?, sourceName: String) {
        currentDisplayAmbientProxy = value
        currentAmbientSourceName = sourceName
        if popover.isShown { updateAmbientStatusLabel() }
    }

    @discardableResult
    func suspendPresenceForAmbientLock() -> Bool {
        if isAmbientPresenceLockActive {
            maintainPresenceSuspendedForAmbientLock()
            return true
        }
        isAmbientPresenceLockActive = true
        presenceWasEnabledBeforeAmbientLock = presenceWasEnabledBeforeAmbientLock || lamp.isPresenceDetectionEnabled == true
        autoLightWasEnabledBeforeAmbientLock = autoLightWasEnabledBeforeAmbientLock || lamp.isAutoLightEnabled == true
        if autoLightWasEnabledBeforeAmbientLock {
            guard lamp.setAutoLight(enabled: false) else {
                isAmbientPresenceLockActive = false
                autoLightWasEnabledBeforeAmbientLock = false
                return false
            }
            UserDefaults.standard.set(true, forKey: "ambientSuspendedAutoLightWasEnabled")
            log("环境关灯锁定已临时暂停自动感光")
        }
        if presenceWasEnabledBeforeAmbientLock {
            guard lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                            sensitivity: presenceSensitivity) else {
                if autoLightWasEnabledBeforeAmbientLock {
                    _ = lamp.setAutoLight(enabled: true)
                    UserDefaults.standard.removeObject(forKey: "ambientSuspendedAutoLightWasEnabled")
                }
                isAmbientPresenceLockActive = false
                presenceWasEnabledBeforeAmbientLock = false
                autoLightWasEnabledBeforeAmbientLock = false
                return false
            }
            UserDefaults.standard.set(true, forKey: "ambientSuspendedPresenceWasEnabled")
            log("环境关灯锁定已临时暂停入座检测")
        }
        refreshControls()
        return true
    }

    func maintainPresenceSuspendedForAmbientLock() {
        guard isAmbientPresenceLockActive else { return }
        // 灯体关闭时，固件不会应用“写入手动亮度”这个退出自动感光动作。
        // 旧版留下的关灯锁定只记住恢复意图；若灯体自行亮起，再立即暂停。
        if lamp.isPowerOn == true, lamp.isAutoLightEnabled == true {
            autoLightWasEnabledBeforeAmbientLock = true
            if lamp.setAutoLight(enabled: false) {
                UserDefaults.standard.set(true, forKey: "ambientSuspendedAutoLightWasEnabled")
                log("检测到环境锁定期间自动感光仍开启，已临时暂停")
            }
        }
        if lamp.isPresenceDetectionEnabled == true {
            presenceWasEnabledBeforeAmbientLock = true
            if lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                         sensitivity: presenceSensitivity) {
                UserDefaults.standard.set(true, forKey: "ambientSuspendedPresenceWasEnabled")
                log("检测到环境锁定期间入座检测仍开启，已临时暂停")
            }
        }
    }

    func restorePresenceAfterAmbientLock() {
        guard isAmbientPresenceLockActive || presenceWasEnabledBeforeAmbientLock || autoLightWasEnabledBeforeAmbientLock else { return }
        let shouldRestorePresence = presenceWasEnabledBeforeAmbientLock
        let shouldRestoreAutoLight = autoLightWasEnabledBeforeAmbientLock
        isAmbientPresenceLockActive = false
        presenceWasEnabledBeforeAmbientLock = false
        autoLightWasEnabledBeforeAmbientLock = false
        UserDefaults.standard.removeObject(forKey: "ambientSuspendedPresenceWasEnabled")
        UserDefaults.standard.removeObject(forKey: "ambientSuspendedAutoLightWasEnabled")
        if shouldRestorePresence, isScreenSleepPresenceLockActive {
            presenceWasEnabledBeforeScreenSleep = true
            UserDefaults.standard.set(true, forKey: "screenSleepSuspendedPresenceWasEnabled")
        } else if shouldRestorePresence {
            if lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds,
                                         sensitivity: presenceSensitivity) {
                log("环境关灯锁定已解除，已恢复入座检测")
            } else {
                log("环境关灯锁定已解除，但入座检测恢复失败")
            }
        }
        if shouldRestoreAutoLight {
            if lamp.setAutoLight(enabled: true) {
                log("环境关灯锁定已解除，已恢复自动感光")
            } else {
                log("环境关灯锁定已解除，但自动感光恢复失败")
            }
        }
        refreshControls()
    }

    func suspendPresenceForScreenSleep() {
        if isScreenSleepPresenceLockActive {
            if lamp.isPresenceDetectionEnabled == true {
                presenceWasEnabledBeforeScreenSleep = true
                if lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                             sensitivity: presenceSensitivity) {
                    UserDefaults.standard.set(true, forKey: "screenSleepSuspendedPresenceWasEnabled")
                    log("检测到熄屏期间入座检测仍开启，已重新暂停")
                }
            }
            return
        }
        // 环境关灯锁定已经暂停时，由环境锁负责恢复，避免唤醒时抢先开启。
        guard !isAmbientPresenceLockActive else { return }
        isScreenSleepPresenceLockActive = true
        presenceWasEnabledBeforeScreenSleep = lamp.isPresenceDetectionEnabled == true
        guard presenceWasEnabledBeforeScreenSleep else { return }
        if lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                     sensitivity: presenceSensitivity) {
            UserDefaults.standard.set(true, forKey: "screenSleepSuspendedPresenceWasEnabled")
            log("熄屏同步已临时暂停入座检测")
        } else {
            isScreenSleepPresenceLockActive = false
            presenceWasEnabledBeforeScreenSleep = false
            log("熄屏时暂停入座检测失败")
        }
        refreshControls()
    }

    func restorePresenceAfterScreenWake() {
        guard isScreenSleepPresenceLockActive || presenceWasEnabledBeforeScreenSleep else { return }
        let shouldRestore = presenceWasEnabledBeforeScreenSleep
        isScreenSleepPresenceLockActive = false
        presenceWasEnabledBeforeScreenSleep = false
        UserDefaults.standard.removeObject(forKey: "screenSleepSuspendedPresenceWasEnabled")
        if shouldRestore, isAmbientPresenceLockActive {
            presenceWasEnabledBeforeAmbientLock = true
            UserDefaults.standard.set(true, forKey: "ambientSuspendedPresenceWasEnabled")
        }
        if shouldRestore, !isAmbientPresenceLockActive {
            if lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds,
                                         sensitivity: presenceSensitivity) {
                log("屏幕已唤醒，已恢复入座检测")
            } else {
                log("屏幕已唤醒，但入座检测恢复失败")
            }
        }
        refreshControls()
    }

    var hasPendingAmbientPresenceRestore: Bool {
        return presenceWasEnabledBeforeAmbientLock || autoLightWasEnabledBeforeAmbientLock
    }

    private func updateAmbientStatusLabel() {
        syncThresholdFields()
        captureBrightButton.state = .off
        captureDarkButton.state = .off
        let targetState: NSControl.StateValue = areAmbientRulesEnabled ? .on : .off
        if ambientEnableSwitch.state != targetState {
            log("环境光规则开关状态同步：\(ambientEnableSwitch.state == .on ? "开" : "关") → \(targetState == .on ? "开" : "关")")
        }
        ambientEnableSwitch.state = targetState
        ambientEnableSwitch.isEnabled = isStudioDisplayAvailable && !isComboPolicyEnabled && currentDisplayAmbientProxy != nil &&
            (ambientCloseThreshold != nil || ambientOpenThreshold != nil)
        let currentText = currentDisplayAmbientProxy.map { "当前环境 \($0)" } ?? "当前环境 --"
        if isComboPolicyEnabled {
            let close = ambientCloseThreshold.map(String.init) ?? "--"
            let open = ambientOpenThreshold.map(String.init) ?? "--"
            ambientStatusLabel.stringValue = "\(currentText) lux（环境估算，已扣除灯光） ·  ≤\(open) 补光 / ≥\(close) 关灯  ·  健康目标 300–500 lux"
        } else if let close = ambientCloseThreshold, let open = ambientOpenThreshold, open >= close {
            ambientStatusLabel.stringValue = "\(currentText)  ·  阈值重叠，可能反复开关"
        } else if !areAmbientRulesEnabled, ambientCloseThreshold != nil || ambientOpenThreshold != nil {
            ambientStatusLabel.stringValue = "\(currentText)  ·  已保存，未启用"
        } else {
            ambientStatusLabel.stringValue = currentText
        }
    }

    var isAmbientLinkEnabled: Bool {
        return areAmbientRulesEnabled && (ambientCloseThreshold != nil || ambientOpenThreshold != nil)
    }

    @objc private func brightnessChanged() {
        let value = Int(brightnessSlider.doubleValue.rounded())
        brightnessValueLabel.stringValue = "\(value)%"
        guard isBrightnessSliderTracking else {
            _ = lamp.setBrightness(value)
            markManualOverride()
            lamp.requestStatus()
            return
        }
        // 拖动中：标签随时刷新，灯体写入限速 80ms，避免刷 HID 报文。
        let now = Date()
        if now.timeIntervalSince(lastSliderWriteAt) >= 0.08 {
            lastSliderWriteAt = now
            _ = lamp.setBrightness(value)
            pendingBrightnessValue = nil
        } else {
            pendingBrightnessValue = value
        }
    }

    @objc private func temperatureChanged() {
        let value = Int((temperatureSlider.doubleValue / 100).rounded()) * 100
        temperatureSlider.doubleValue = Double(value)
        temperatureValueLabel.stringValue = "\(value)K"
        guard isTemperatureSliderTracking else {
            _ = lamp.setTemperature(value)
            markManualOverride()
            lamp.requestStatus()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastSliderWriteAt) >= 0.08 {
            lastSliderWriteAt = now
            _ = lamp.setTemperature(value)
            pendingTemperatureValue = nil
        } else {
            pendingTemperatureValue = value
        }
    }

    /// 松手后补写最后一个值，并同步回读。
    private func flushSliderInteraction() {
        if let pending = pendingBrightnessValue {
            _ = lamp.setBrightness(pending)
            pendingBrightnessValue = nil
        }
        if let pending = pendingTemperatureValue {
            _ = lamp.setTemperature(pending)
            pendingTemperatureValue = nil
        }
        markManualOverride()
        lamp.requestStatus()
    }

    @objc private func timeTemperatureChanged() {
        isTimeTemperatureEnabled = timeTemperatureSwitch.state == .on
        UserDefaults.standard.set(isTimeTemperatureEnabled, forKey: "timeTemperatureEnabled")
        lastScheduledTemperature = nil
        lastScheduledTemperatureChangeAt = .distantPast
        refreshControls()
        if isTimeTemperatureEnabled {
            applyScheduledTemperatureIfNeeded(isAsleep: isAsleep, force: true)
            log("已开启色温随时间")
        } else {
            log("已关闭色温随时间，保持当前色温")
        }
    }

    func applyScheduledTemperatureIfNeeded(isAsleep: Bool, force: Bool = false) {
        guard isTimeTemperatureEnabled,
              !isAsleep,
              lamp.isConnected,
              lamp.isPowerOn == true else { return }
        let target = scheduledTemperature(at: Date())
        guard force || target != lastScheduledTemperature || lamp.currentTemperature != target else { return }
        guard force || Date().timeIntervalSince(lastScheduledTemperatureChangeAt) >= 60 else { return }
        if lamp.setTemperature(target) {
            lastScheduledTemperature = target
            lastScheduledTemperatureChangeAt = Date()
            log("色温随时间已调整为 \(target)K")
        }
    }

    private func scheduledTemperature(at date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let value: Double
        switch minute {
        case 0..<(6 * 60):
            value = 3000
        case (6 * 60)..<(10 * 60):
            value = interpolate(minute: minute, from: 6 * 60, to: 10 * 60, start: 3000, end: 5500)
        case (10 * 60)..<(16 * 60):
            value = 5500
        case (16 * 60)..<(21 * 60):
            value = interpolate(minute: minute, from: 16 * 60, to: 21 * 60, start: 5500, end: 3500)
        default:
            value = interpolate(minute: minute, from: 21 * 60, to: 24 * 60, start: 3500, end: 3000)
        }
        return max(2700, min(6500, Int((value / 50).rounded()) * 50))
    }

    private func interpolate(minute: Int, from: Int, to: Int, start: Double, end: Double) -> Double {
        let progress = Double(minute - from) / Double(to - from)
        return start + (end - start) * max(0, min(1, progress))
    }

    @objc private func autoLightChanged() {
        let requested = autoLightSwitch.state == .on
        if !lamp.setAutoLight(enabled: requested) {
            autoLightSwitch.state = requested ? .off : .on
            return
        }
        autoLightChangePendingUntil = Date().addingTimeInterval(1)
        pendingAutoLightState = requested
        if requested, isBrightnessFollowEnabled {
            isBrightnessFollowEnabled = false
            brightnessFollowSwitch.state = .off
            UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
            update(isAsleep: isAsleep, healthy: isHealthy)
            log("已关闭 Studio Display 亮度跟随，改用灯具自动感光")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.lamp.requestStatus()
        }
    }

    @objc private func presenceChanged() {
        let requested = presenceSwitch.state == .on
        if !lamp.setPresenceDetection(enabled: requested, delaySeconds: presenceDelaySeconds, sensitivity: presenceSensitivity) {
            presenceSwitch.state = requested ? .off : .on
        }
        lamp.requestStatus()
    }

    @objc private func presenceDelayChanged() {
        let seconds = selectedPresenceDelaySeconds()
        presenceDelaySeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "presenceDelaySeconds")
        log("入座检测时间设置为 \(seconds) 秒")
        if lamp.isPresenceDetectionEnabled == true {
            let requested = presenceSwitch.state == .on
            if !lamp.setPresenceDetection(enabled: requested, delaySeconds: seconds, sensitivity: presenceSensitivity) {
                log("入座检测时间未成功下发到灯具，已保持本地设置")
            }
            lamp.requestStatus()
        }
    }

    @objc private func presenceSensitivityChanged() {
        presenceSensitivity = presenceSensitivityPopup.selectedItem?.tag ?? 2
        UserDefaults.standard.set(presenceSensitivity, forKey: "presenceSensitivity")
        log("离席侦测灵敏度设置为 \(presenceSensitivityPopup.titleOfSelectedItem ?? "高")")
        if lamp.isPresenceDetectionEnabled == true {
            if !lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds, sensitivity: presenceSensitivity) {
                log("离席侦测灵敏度未成功下发到灯具，已保持本地设置")
            }
            lamp.requestStatus()
        }
    }

    @objc private func videoModeChanged() {
        let requested = videoModeSwitch.state == .on
        if !lamp.setVideoMode(enabled: requested) {
            videoModeSwitch.state = requested ? .off : .on
        }
        lamp.requestStatus()
    }

    @objc private func readingModeChanged() {
        markManualOverride()
        if readingModeSwitch.state == .on {
            enterReadingMode()
        } else {
            leaveReadingMode()
        }
    }

    private func enterReadingMode() {
        guard lamp.isConnected else {
            readingModeSwitch.state = .off
            NSSound.beep()
            log("阅读模式未应用：iScreenBar 未连接")
            return
        }
        // 环境光规则会持续把灯压回关闭状态，与固定组合互斥，进入前先停用并解除关灯锁定。
        if isAmbientLinkEnabled {
            areAmbientRulesEnabled = false
            UserDefaults.standard.set(false, forKey: "ambientRulesEnabled")
            if ambientTurnedLampOff {
                setAmbientLampLock(false)
                _ = lamp.setPower(on: true)
            }
            restorePresenceAfterAmbientLock()
            updateAmbientStatusLabel()
            log("阅读模式已停用环境光规则并解除关灯锁定")
        }
        if !isReadingModeEnabled,
           let brightness = lamp.currentBrightness,
           let temperature = lamp.currentTemperature {
            let snapshot = SavedMode(name: "阅读模式前", brightness: brightness, temperature: temperature,
                                     videoMode: lamp.isVideoModeEnabled == true)
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: "readingModeRestore")
            }
            // 自动感光开启时回读的手动亮度不可用作恢复值，退出时改回自动感光。
            UserDefaults.standard.set(lamp.isAutoLightEnabled == true, forKey: "readingModeRestoreAutoLight")
        }
        // 亮度跟随与色温随时间会持续覆写固定组合，进入前先关掉，并记住原开关以便退出时回滚。
        UserDefaults.standard.set(isBrightnessFollowEnabled, forKey: "readingModeRestoreBrightnessFollow")
        UserDefaults.standard.set(isTimeTemperatureEnabled, forKey: "readingModeRestoreTimeTemperature")
        if isBrightnessFollowEnabled {
            isBrightnessFollowEnabled = false
            brightnessFollowSwitch.state = .off
            UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
            log("阅读模式已关闭 Studio Display 亮度跟随")
        }
        if isTimeTemperatureEnabled {
            isTimeTemperatureEnabled = false
            timeTemperatureSwitch.state = .off
            lastScheduledTemperature = nil
            lastScheduledTemperatureChangeAt = .distantPast
            UserDefaults.standard.set(false, forKey: "timeTemperatureEnabled")
            log("阅读模式已关闭色温随时间")
        }
        guard lamp.setPower(on: true),
              lamp.setBrightness(readingModeBrightness),
              lamp.setTemperature(readingModeTemperature) else {
            readingModeSwitch.state = .off
            NSSound.beep()
            log("阅读模式应用失败：USB HID 指令未成功")
            return
        }
        _ = lamp.setVideoMode(enabled: false)
        isReadingModeEnabled = true
        UserDefaults.standard.set(true, forKey: "readingModeEnabled")
        log("已开启阅读模式：亮度 \(readingModeBrightness)%、色温 \(readingModeTemperature)K、视频模式关闭")
        refreshControls()
        lamp.requestStatus()
    }

    private func leaveReadingMode() {
        isReadingModeEnabled = false
        UserDefaults.standard.set(false, forKey: "readingModeEnabled")
        guard let data = UserDefaults.standard.data(forKey: "readingModeRestore"),
              let snapshot = try? JSONDecoder().decode(SavedMode.self, from: data) else {
            log("已退出阅读模式，未找到可恢复的灯态")
            refreshControls()
            return
        }
        _ = lamp.setTemperature(snapshot.temperature)
        _ = lamp.setVideoMode(enabled: snapshot.videoMode)
        if UserDefaults.standard.bool(forKey: "readingModeRestoreAutoLight"), lamp.setAutoLight(enabled: true) {
            log("已退出阅读模式，恢复自动感光与色温 \(snapshot.temperature)K")
        } else if snapshot.brightness >= 5 {
            _ = lamp.setBrightness(snapshot.brightness)
            log("已退出阅读模式，恢复亮度 \(snapshot.brightness)%、色温 \(snapshot.temperature)K")
        } else {
            // 自动感光开启时回读的手动亮度是固件残留值（通常为 1%），不能当恢复值用。
            log("已退出阅读模式，快照亮度 \(snapshot.brightness)% 无效（自动感光残留），保留当前亮度")
        }
        if UserDefaults.standard.bool(forKey: "readingModeRestoreTimeTemperature"), !isTimeTemperatureEnabled {
            isTimeTemperatureEnabled = true
            UserDefaults.standard.set(true, forKey: "timeTemperatureEnabled")
            timeTemperatureSwitch.state = .on
            log("已退出阅读模式，恢复色温随时间")
        }
        if UserDefaults.standard.bool(forKey: "readingModeRestoreBrightnessFollow"), !isBrightnessFollowEnabled {
            isBrightnessFollowEnabled = true
            UserDefaults.standard.set(true, forKey: "brightnessFollowEnabled")
            brightnessFollowSwitch.state = .on
            log("已退出阅读模式，恢复亮度跟随")
        }
        refreshControls()
        lamp.requestStatus()
    }

    @objc private func comboPolicyChanged() {
        let requested = comboPolicySwitch.state == .on
        isComboPolicyEnabled = requested
        UserDefaults.standard.set(requested, forKey: "comboPolicyEnabled")
        if requested {
            // 旧环境光规则的开关灯职责由引擎接管，避免两套逻辑同时写电源；标定值继续作为亮度映射区间。
            if areAmbientRulesEnabled {
                areAmbientRulesEnabled = false
                UserDefaults.standard.set(false, forKey: "ambientRulesEnabled")
            }
            if ambientTurnedLampOff {
                setAmbientLampLock(false)
                restorePresenceAfterAmbientLock()
            }
            updateAmbientStatusLabel()
            // 策略引擎需要独占亮度与色温：关掉固件自动感光、亮度跟随与色温随时间。
            if lamp.isAutoLightEnabled == true { _ = lamp.setAutoLight(enabled: false) }
            autoLightSwitch.state = .off
            if isBrightnessFollowEnabled {
                isBrightnessFollowEnabled = false
                brightnessFollowSwitch.state = .off
                UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
            }
            if isTimeTemperatureEnabled {
                isTimeTemperatureEnabled = false
                timeTemperatureSwitch.state = .off
                UserDefaults.standard.set(false, forKey: "timeTemperatureEnabled")
            }
            // 开启组合后只需短暂让位（避免与刚写入的固件状态抢写），不需要像手动调灯那样停 15 分钟。
            comboManualOverrideUntil = Date().addingTimeInterval(3)
            log("已开启智能组合策略：入座与 Mac 活动决定开关，环境光决定亮度，时段为主决定色温")
        } else {
            // 引擎因环境过亮关灯时会暂停固件入座检测与自动感光，关闭组合时必须释放，否则会一直卡在暂停。
            if ambientTurnedLampOff {
                setAmbientLampLock(false)
                restorePresenceAfterAmbientLock()
            }
            updateAmbientStatusLabel()
            log("已关闭智能组合策略，恢复各功能独立工作")
        }
        refreshControls()
        lamp.requestStatus()
    }

    @objc private func quitApplication() {
        pendingDisplayPolicyWorkItem?.cancel()
        pendingBuiltinWakeWorkItems.forEach { $0.cancel() }
        pendingBuiltinWakeWorkItems.removeAll()
        _ = displayController.setStudioEnabled(true)
        _ = keepAwakeController.setActive(false)
        log("用户从面板退出应用，版本 \(appVersionText())")
        NSApp.terminate(nil)
    }

    /// 灵敏度枚举对应的中文，便于读日志时不再误以为 2 是“两档”之类的含义。
    private func presenceSensitivityLabel(_ value: Int) -> String {
        switch value {
        case 0: return "低(0)"
        case 1: return "中(1)"
        default: return "高(2)"
        }
    }

    /// 启动后把面板里的离席时间/灵敏度同步给灯体，避免两边参数不一致导致“以为改了但没生效”。
    func syncPresenceSettingsIfNeeded() {
        guard !didSyncPresenceSettings, let presenceEnabled = lamp.isPresenceDetectionEnabled else { return }
        didSyncPresenceSettings = true
        guard presenceEnabled else { return }
        if lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds, sensitivity: presenceSensitivity) {
            log("已同步入座检测参数到灯体：离席 \(presenceDelaySeconds) 秒、灵敏度 \(presenceSensitivityLabel(presenceSensitivity))")
        }
    }

    /// 组合模式用：根据当前是否“需要灯体自己点灯”来启用/停用入座检测，
    /// 避免固件的自动开灯与“环境充足关灯”互相拆台。
    @discardableResult
    func updateFirmwarePresence(requested: Bool) -> Bool {
        guard didSyncPresenceSettings, lamp.isConnected else { return false }
        guard lamp.isPresenceDetectionEnabled != requested else { return false }
        let success = setFirmwarePresenceEnabled(requested)
        if success {
            isPresenceSuspendedByPolicy = !requested
            log(requested
                ? "已启用灯体入座检测（需要它感知入座/自动点灯）"
                : "已停用灯体入座检测（环境充足，改用键鼠活动判定）")
        }
        return success
    }

    /// 组合模式用：临时启用/停用灯体入座检测（无人时避免固件误触发点灯）。
    @discardableResult
    func setFirmwarePresenceEnabled(_ enabled: Bool) -> Bool {
        let success = lamp.setPresenceDetection(enabled: enabled,
                                               delaySeconds: presenceDelaySeconds,
                                               sensitivity: presenceSensitivity)
        if success { refreshControls() }
        return success
    }

    /// 策略引擎使用的时段色温基线（与「色温随时间」同一曲线）。
    func baselineTemperature(at date: Date) -> Int {
        return scheduledTemperature(at: date)
    }

    func setComboStatus(_ text: String) {
        guard comboStatusLabel.stringValue != text else { return }
        comboStatusLabel.stringValue = text
    }

    func markManualOverride(seconds: TimeInterval = 900) {
        comboManualOverrideUntil = Date().addingTimeInterval(seconds)
    }

    @objc private func presetChanged(_ sender: NSMenuItem) {
        markManualOverride()
        let index = sender.tag
        let preset: (brightness: Int, temperature: Int, video: Bool)
        if (index == 0 || index >= 3),
           let data = UserDefaults.standard.data(forKey: "savedCustomMode"),
           let saved = try? JSONDecoder().decode(SavedMode.self, from: data) {
            preset = (saved.brightness, saved.temperature, saved.videoMode)
        } else {
            switch index {
            case 1: preset = (30, 4000, false)
            case 2: preset = (20, 3000, false)
            default: preset = (47, 5500, false)
            }
        }
        isBrightnessFollowEnabled = false
        brightnessFollowSwitch.state = .off
        UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
        _ = lamp.setPower(on: true)
        _ = lamp.setBrightness(preset.brightness)
        _ = lamp.setTemperature(preset.temperature)
        _ = lamp.setVideoMode(enabled: preset.video)
        refreshControls()
        modeButton.title = sender.title
        log("已应用模式预设：\(sender.title)")
        lamp.requestStatus()
    }

    @objc private func showModeMenu() {
        let menu = NSMenu()
        for (index, title) in modeNames().enumerated() {
            let item = NSMenuItem(title: title, action: #selector(presetChanged(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            if title == modeButton.title { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let center = NSMenuItem(title: "模式中心设置…", action: #selector(showModeCenter), keyEquivalent: "")
        center.target = self
        menu.addItem(center)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modeButton.bounds.height + 4), in: modeButton)
    }

    private func modeNames() -> [String] {
        var names = ["我的最爱", "夜间工作", "睡前放松"]
        if let data = UserDefaults.standard.data(forKey: "savedCustomMode"),
           let mode = try? JSONDecoder().decode(SavedMode.self, from: data),
           !names.contains(mode.name) {
            names.append(mode.name)
        }
        return names
    }

    @objc private func showModeCenter() {
        if let window = modeCenterWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 270),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "模式中心"
        let title = NSTextField(labelWithString: "模式中心")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "快速切换预设灯光场景")
        subtitle.font = UIStyle.bodyFont
        subtitle.textColor = .secondaryLabelColor
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 1
        rows.wantsLayer = true
        rows.layer?.cornerRadius = 10
        rows.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        for (index, name) in modeNames().enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(modeCenterPresetChanged(_:)))
            button.tag = index
            button.isBordered = false
            button.setAccessibilityTitle(name)
            button.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: name)
            label.font = UIStyle.bodyFont
            label.translatesAutoresizingMaskIntoConstraints = false
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            chevron.translatesAutoresizingMaskIntoConstraints = false
            let row = NSView()
            row.addSubview(button)
            row.addSubview(label)
            row.addSubview(chevron)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 44),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 10),
                chevron.heightAnchor.constraint(equalToConstant: 14)
            ])
            rows.addArrangedSubview(row)
        }
        let add = NSButton(title: "新增场景模式", target: self, action: #selector(saveCurrentMode))
        add.bezelStyle = .rounded
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        let bind = NSButton(title: "绑定应用", target: self, action: #selector(bindCurrentModeToApp))
        bind.bezelStyle = .rounded
        bind.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        bind.imagePosition = .imageLeading
        let leadingSpace = NSView()
        let trailingSpace = NSView()
        leadingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [leadingSpace, add, bind, trailingSpace])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.distribution = .fill
        actions.widthAnchor.constraint(equalToConstant: 512).isActive = true
        leadingSpace.widthAnchor.constraint(equalTo: trailingSpace.widthAnchor).isActive = true
        let stack = NSStackView(views: [title, subtitle, rows, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            rows.widthAnchor.constraint(equalToConstant: 512)
        ])
        window.contentView = content
        window.isReleasedWhenClosed = false
        if let screen = item.button?.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        } else {
            window.center()
        }
        modeCenterWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func modeCenterPresetChanged(_ sender: NSButton) {
        let item = NSMenuItem(title: modeNames()[sender.tag], action: nil, keyEquivalent: "")
        item.tag = sender.tag
        presetChanged(item)
    }

    @objc private func saveCurrentMode() {
        guard let brightness = lamp.currentBrightness,
              let temperature = lamp.currentTemperature else {
            log("尚未获取灯具状态，无法保存模式")
            return
        }
        let alert = NSAlert()
        alert.messageText = "保存新模式"
        alert.informativeText = "记录当前亮度、色温和视频模式。"
        let field = NSTextField(string: "我的模式")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let mode = SavedMode(name: field.stringValue.isEmpty ? "我的模式" : field.stringValue,
                             brightness: brightness,
                             temperature: temperature,
                             videoMode: lamp.isVideoModeEnabled == true)
        if let data = try? JSONEncoder().encode(mode) {
            UserDefaults.standard.set(data, forKey: "savedCustomMode")
            modeButton.title = mode.name
            log("已保存模式：\(mode.name)")
            modeCenterWindow?.close()
            modeCenterWindow = nil
        }
    }

    @objc private func bindCurrentModeToApp() {
        guard let brightness = lamp.currentBrightness,
              let temperature = lamp.currentTemperature else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要绑定的应用"
        panel.prompt = "绑定"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let mode = SavedMode(name: url.deletingPathExtension().lastPathComponent,
                             brightness: brightness,
                             temperature: temperature,
                             videoMode: lamp.isVideoModeEnabled == true)
        var mappings = loadAppModes()
        mappings[bundleID] = mode
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: "appModes")
            bindAppButton.title = "已绑定 \(mode.name)"
            log("已绑定应用模式：\(mode.name)")
        }
    }

    func applyModeForFrontmostAppIfNeeded() {
        // 未连接 Studio Display 时处于待机，不做任何灯体写入。
        guard isStudioDisplayAvailable, lamp.isConnected else { return }
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundleID != lastFrontmostBundleID else { return }
        lastFrontmostBundleID = bundleID
        guard let mode = loadAppModes()[bundleID] else { return }
        // 组合模式下应用绑定属于用户显式动作，写入后给引擎一个保护期。
        if isComboPolicyEnabled { markManualOverride() }
        _ = lamp.setPower(on: true)
        _ = lamp.setBrightness(mode.brightness)
        _ = lamp.setTemperature(mode.temperature)
        _ = lamp.setVideoMode(enabled: mode.videoMode)
        log("已应用应用模式：\(mode.name)")
    }

    private func loadAppModes() -> [String: SavedMode] {
        guard let data = UserDefaults.standard.data(forKey: "appModes") else { return [:] }
        return (try? JSONDecoder().decode([String: SavedMode].self, from: data)) ?? [:]
    }

    @objc private func brightnessFollowChanged() {
        let requested = brightnessFollowSwitch.state == .on
        if requested, lamp.isAutoLightEnabled == true {
            guard lamp.setAutoLight(enabled: false) else {
                brightnessFollowSwitch.state = .off
                log("关闭自动感光失败，未开启 Studio Display 亮度跟随")
                return
            }
            autoLightSwitch.state = .off
            autoLightChangePendingUntil = Date().addingTimeInterval(1)
            pendingAutoLightState = false
            lamp.requestStatus()
            log("已关闭自动感光，改用 Studio Display 亮度跟随")
        }
        isBrightnessFollowEnabled = requested
        UserDefaults.standard.set(isBrightnessFollowEnabled, forKey: "brightnessFollowEnabled")
        update(isAsleep: isAsleep, healthy: isHealthy)
        log(isBrightnessFollowEnabled ? "已开启 Studio Display 亮度跟随" : "已关闭 Studio Display 亮度跟随")
    }

    @objc private func displayBrightnessLockChanged() {
        isDisplayBrightnessLockEnabled = displayBrightnessLockSwitch.state == .on
        UserDefaults.standard.set(isDisplayBrightnessLockEnabled, forKey: "displayBrightnessLockEnabled")
        log(isDisplayBrightnessLockEnabled
            ? "已开启 MacBook 与 Studio Display 双屏亮度锁定"
            : "已关闭 MacBook 与 Studio Display 双屏亮度锁定")
        refreshControls()
    }

    @objc private func powerSyncChanged() {
        isPowerSyncEnabled = powerSyncSwitch.state == .on
        UserDefaults.standard.set(isPowerSyncEnabled, forKey: "powerSyncEnabled")
        update(isAsleep: isAsleep, healthy: isHealthy)
        log(isPowerSyncEnabled ? "已开启熄屏电源同步" : "已关闭熄屏电源同步")
    }

    @objc private func keepAwakeChanged() {
        let requested = keepAwakeSwitch.state == .on
        guard keepAwakeController.setActive(requested) else {
            keepAwakeSwitch.state = .off
            let alert = NSAlert()
            alert.messageText = "无法开启防止休眠"
            alert.informativeText = "macOS 未能启动 caffeinate，请稍后重试。"
            alert.runModal()
            return
        }
        keepAwakeSwitch.state = keepAwakeController.isActive ? .on : .off
        handleKeepAwakeLidDisplayState()
        log(keepAwakeController.isActive ? "已开启防止空闲休眠" : "已恢复系统默认休眠")
    }

    private func handleKeepAwakeLidDisplayState() {
        guard displayController.lidClosed() else {
            didRequestDisplaySleepForCurrentLidClosure = false
            return
        }
        guard keepAwakeController.isActive,
              displayController.externalDisplays().isEmpty,
              !didRequestDisplaySleepForCurrentLidClosure else { return }

        // disablesleep 会让合盖后改用 displaysleep 计时；无外屏时主动请求立即熄屏。
        didRequestDisplaySleepForCurrentLidClosure = true
        let success = requestSystemDisplaySleep()
        log(success
            ? "防休眠状态下检测到合盖，已请求关闭内屏"
            : "防休眠状态下合盖熄屏请求失败")
    }

    private func migrateDisplayPresetIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: "rotationPreset") == nil else { return }
        if let old = UserDefaults(suiteName: "local.qiu.builtin-display-rotation"),
           old.bool(forKey: "DisplayPresetSaved") {
            let preset = DisplayPreset(name: "我的旋转预设",
                                       builtinEnabled: old.bool(forKey: "DisplayPresetBuiltinEnabled"),
                                       rotation: old.integer(forKey: "DisplayPresetRotation"),
                                       builtinPrimary: old.bool(forKey: "DisplayPresetBuiltinPrimary"))
            saveRotationPreset(preset)
            return
        }
        saveRotationPreset(DisplayPreset(name: "竖屏双屏", builtinEnabled: true, rotation: 90, builtinPrimary: false))
    }

    private func saveRotationPreset(_ preset: DisplayPreset) {
        if let data = try? JSONEncoder().encode(preset) {
            UserDefaults.standard.set(data, forKey: "rotationPreset")
            rotationModeButton.title = preset.name
        }
    }

    private func loadRotationPreset() -> DisplayPreset {
        if let data = UserDefaults.standard.data(forKey: "rotationPreset"),
           let preset = try? JSONDecoder().decode(DisplayPreset.self, from: data) { return preset }
        return DisplayPreset(name: "竖屏双屏", builtinEnabled: true, rotation: 90, builtinPrimary: false)
    }

    private func saveDisplayBaselineIfNeeded() {
        guard UserDefaults.standard.data(forKey: "displayAutoBaseline") == nil,
              let baseline = displayController.currentPreset(name: "自动启用前") else { return }
        if let data = try? JSONEncoder().encode(baseline) {
            UserDefaults.standard.set(data, forKey: "displayAutoBaseline")
        }
    }

    private func restoreDisplayBaseline(clear: Bool) {
        guard let data = UserDefaults.standard.data(forKey: "displayAutoBaseline"),
              let baseline = try? JSONDecoder().decode(DisplayPreset.self, from: data) else {
            _ = displayController.enableBuiltin(); return
        }
        _ = displayController.apply(baseline)
        if clear { UserDefaults.standard.removeObject(forKey: "displayAutoBaseline") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshControls() }
    }

    @objc private func displayPowerChanged() {
        guard isDisplaySessionSafe, !isConsoleSessionLocked() else {
            refreshControls()
            return
        }
        let requested = displayPowerSwitch.state == .on
        let success = requested ? displayController.enableBuiltin() : displayController.disableBuiltin()
        if success {
            isBuiltinManuallyDisabled = !requested
        } else {
            displayPowerSwitch.state = requested ? .off : .on
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshControls() }
    }

    @objc private func studioPowerChanged() {
        guard isDisplaySessionSafe, !isConsoleSessionLocked() else { refreshControls(); return }
        let enabled = studioPowerSwitch.state == .on
        guard displayController.setStudioEnabled(enabled) else {
            refreshControls()
            let alert = NSAlert()
            alert.messageText = "无法切换 Studio Display"
            alert.informativeText = "未找到可用的 Studio Display。"
            alert.runModal()
            return
        }
        if !enabled { popover.performClose(nil) }
        refreshControls()
    }

    @objc private func displaySessionBecameUnsafe(_ notification: Notification) {
        _ = displayController.setStudioEnabled(true)
        isDisplaySessionSafe = false
        pendingDisplayPolicyWorkItem?.cancel()
        pendingDisplayPolicyWorkItem = nil
        log("锁屏或显示器休眠，已暂停内屏配置写入")
        if notification.name == NSWorkspace.sessionDidResignActiveNotification {
            // Chrome/Web 视频可能持有 NoDisplaySleepAssertion，使锁屏后显示器仍亮数分钟。
            // 只在确认会话已锁定时请求系统立即熄屏，不影响解锁后的显示配置。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard isConsoleSessionLocked() else { return }
                // 刚发生过入座唤醒时不要立刻又熄屏，否则会形成循环。
                guard Date().timeIntervalSince(lastPresenceWakeAt) > 120,
                      Date().timeIntervalSince(lastForcedDisplaySleepAt) > 300 else { return }
                lastForcedDisplaySleepAt = Date()
                log(requestSystemDisplaySleep()
                    ? "检测到 Mac 已锁定，已请求系统立即熄屏"
                    : "检测到 Mac 已锁定，但系统熄屏请求失败")
            }
        }
    }

    @objc private func displaySessionBecameActive() {
        scheduleDisplaySessionActivation()
    }

    private func scheduleDisplaySessionActivation() {
        isDisplaySessionSafe = false
        pendingDisplayPolicyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isDisplaySessionSafe = true
            let pendingState = self.pendingDisplayConnectionState
            self.pendingDisplayConnectionState = nil
            if let pendingState {
                self.scheduleDisplayPolicy(forExternalConnection: pendingState)
            }
            self.refreshControls()
            log("显示会话已稳定，恢复内屏手动控制")
        }
        pendingDisplayPolicyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func scheduleDisplayPolicy(forExternalConnection connected: Bool) {
        pendingDisplayPolicyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let externalStillConnected = studioDisplayID() != nil
            guard externalStillConnected == connected else { return }
            if !connected {
                // 外屏断开后内屏是唯一的退路：即使显示会话正在切换或锁定，
                // 也先恢复内屏在线，避免“不安全”保护把断开事件直接丢掉。
                self.isBuiltinManuallyDisabled = false
                let enabled = self.displayController.enableBuiltin()
                if enabled {
                    self.requestBuiltinWakeAfterExternalDisconnect()
                    if self.isDisplaySessionSafe, !isConsoleSessionLocked() {
                        _ = self.displayController.restoreBuiltinDefault()
                    }
                } else {
                    self.pendingDisplayConnectionState = false
                    self.scheduleDisplaySessionActivation()
                    log("外接显示器已断开，内屏恢复未生效，已安排重试")
                }
                self.refreshControls()
                return
            }
            guard self.isDisplaySessionSafe, !isConsoleSessionLocked() else {
                self.pendingDisplayConnectionState = true
                return
            }
            if connected {
                if self.isDisplayAutoPresetEnabled {
                    self.saveDisplayBaselineIfNeeded()
                    _ = self.displayController.apply(self.automaticRotationPreset())
                    log("连接 Studio Display：自动预设已开启，应用保存角度")
                } else {
                    if !self.isBuiltinManuallyDisabled {
                        _ = self.displayController.enableBuiltin()
                    }
                    self.resetBuiltinRotationWhenPresetDisabled()
                }
            }
            self.refreshControls()
        }
        pendingDisplayPolicyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func requestBuiltinWakeAfterExternalDisconnect() {
        pendingBuiltinWakeWorkItems.forEach { $0.cancel() }
        pendingBuiltinWakeWorkItems.removeAll()

        let delays: [TimeInterval] = [0, 1.5, 4, 8, 15]
        for (index, delay) in delays.enumerated() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, studioDisplayID() == nil else { return }
                self.isBuiltinManuallyDisabled = false
                let enabled = self.displayController.enableBuiltin(force: true)
                let lidOpen = !self.displayController.lidClosed()
                let wakeRequested = lidOpen && requestSystemDisplayWake()
                if self.displayController.builtinIsAwake() {
                    log("外接显示器已断开，系统回报内屏 online/active/awake，实际画面仍需确认")
                    self.pendingBuiltinWakeWorkItems.forEach { $0.cancel() }
                    self.pendingBuiltinWakeWorkItems.removeAll()
                } else if index == delays.count - 1 {
                    log("外接显示器已断开，内屏恢复未确认：在线=\(enabled)，盒盖=\(!lidOpen)，已请求唤醒=\(wakeRequested)")
                }
                self.refreshControls()
            }
            pendingBuiltinWakeWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func automaticRotationPreset() -> DisplayPreset {
        var preset = loadRotationPreset()
        preset.builtinEnabled = !isBuiltinManuallyDisabled
        return preset
    }

    @objc private func displayRotationChanged() {
        guard isDisplaySessionSafe, !isConsoleSessionLocked() else { return }
        guard let builtin = displayController.builtinDisplay(), CGDisplayIsOnline(builtin) != 0 else { return }
        let current = Int(CGDisplayRotation(builtin).rounded())
        let next = current == 0 ? 90 : (current == 90 ? 270 : 0)
        popover.performClose(nil)
        guard displayController.rotateBuiltin(to: next) else {
            log("内屏旋转失败，未进入确认流程")
            return
        }

        let alert = NSAlert()
        alert.messageText = "保留内屏旋转？"
        alert.informativeText = "5 秒内未确认，将恢复到 \(current)°。"
        alert.addButton(withTitle: "保留旋转")
        alert.addButton(withTitle: "恢复原状")
        // 不让连续按回车意外确认旋转；Esc 始终回退。
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var expired = false
        let countdown = Timer(timeInterval: 0.1, repeats: true) { _ in
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                expired = true
                NSApplication.shared.abortModal()
            } else {
                alert.informativeText = "\(Int(ceil(remaining))) 秒内未确认，将恢复到 \(current)°。"
            }
        }
        // runModal 使用独立运行循环模式，普通 scheduledTimer 在此期间不会触发。
        RunLoop.main.add(countdown, forMode: .modalPanel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        countdown.invalidate()
        alert.window.orderOut(nil)
        let confirmed = response == .alertFirstButtonReturn && !expired &&
            ProcessInfo.processInfo.systemUptime < deadline
        if !confirmed {
            let restored = displayController.rotateBuiltin(to: current)
            log(restored ? "未确认内屏旋转，已请求恢复到 \(current)°" : "内屏旋转回退失败")
        } else {
            log("已确认内屏旋转为 \(next)°")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshControls() }
    }

    @objc private func displayAutoPresetChanged() {
        guard isDisplaySessionSafe, !isConsoleSessionLocked() else {
            refreshControls()
            return
        }
        isDisplayAutoPresetEnabled = displayAutoPresetSwitch.state == .on
        UserDefaults.standard.set(isDisplayAutoPresetEnabled, forKey: "displayAutoPresetEnabled")
        if isDisplayAutoPresetEnabled {
            saveDisplayBaselineIfNeeded()
            if !displayController.externalDisplays().isEmpty { _ = displayController.apply(automaticRotationPreset()) }
            log("旋转自动预设已开启")
        } else {
            // 关闭预设明确回到横屏，旧基线可能已经是 270°，不能再应用。
            UserDefaults.standard.removeObject(forKey: "displayAutoBaseline")
            resetBuiltinRotationWhenPresetDisabled()
            log("旋转自动预设已关闭，后续连接保持 0°")
        }
        refreshControls()
    }

    private func resetBuiltinRotationWhenPresetDisabled() {
        guard !isDisplayAutoPresetEnabled,
              let builtin = displayController.builtinDisplay(),
              CGDisplayIsOnline(builtin) != 0 else { return }
        if Int(CGDisplayRotation(builtin).rounded()) != 0 {
            let requested = displayController.rotateBuiltin(to: 0)
            log("自动预设关闭，恢复内屏横屏请求：\(requested)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isDisplayAutoPresetEnabled,
                  let id = self.displayController.builtinDisplay() else { return }
            log("自动预设关闭，内屏角度回读：\(Int(CGDisplayRotation(id).rounded()))°")
            self.refreshControls()
        }
    }

    @objc private func showRotationModeMenu() {
        let menu = NSMenu()
        let preset = loadRotationPreset()
        let apply = NSMenuItem(title: "应用“\(preset.name)”", action: #selector(applyRotationPreset), keyEquivalent: "")
        apply.target = self; menu.addItem(apply)
        let save = NSMenuItem(title: "保存当前为旋转预设…", action: #selector(saveCurrentRotationPreset), keyEquivalent: "")
        save.target = self; menu.addItem(save)
        menu.addItem(.separator())
        let automatic = NSMenuItem(title: "连接 Studio Display 时自动启用", action: #selector(toggleRotationPresetAutomation), keyEquivalent: "")
        automatic.target = self; automatic.state = isDisplayAutoPresetEnabled ? .on : .off
        menu.addItem(automatic)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: rotationModeButton.bounds.height + 4), in: rotationModeButton)
    }

    @objc private func applyRotationPreset() {
        guard isDisplaySessionSafe, !isConsoleSessionLocked() else { return }
        if !displayController.apply(loadRotationPreset()) { log("应用旋转预设失败") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshControls() }
    }

    @objc private func saveCurrentRotationPreset() {
        guard let current = displayController.currentPreset(name: "我的旋转预设") else { return }
        let alert = NSAlert()
        alert.messageText = "保存旋转预设"
        alert.informativeText = "记录内屏开关、旋转角度和主屏角色。"
        let field = NSTextField(string: loadRotationPreset().name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var preset = current
        preset.name = field.stringValue.isEmpty ? "我的旋转预设" : field.stringValue
        saveRotationPreset(preset)
        log("已保存旋转预设：\(preset.name)")
    }

    @objc private func toggleRotationPresetAutomation() {
        displayAutoPresetSwitch.state = isDisplayAutoPresetEnabled ? .off : .on
        displayAutoPresetChanged()
    }

    func handleStudioDisplayConnection(connected: Bool) {
        pendingDisplayConnectionState = connected
        if connected {
            pendingBuiltinWakeWorkItems.forEach { $0.cancel() }
            pendingBuiltinWakeWorkItems.removeAll()
        }
        if !connected {
            // 不等待 5 秒的会话稳定期；先尝试打开内屏，后续再恢复旋转和主屏。
            isBuiltinManuallyDisabled = false
            requestBuiltinWakeAfterExternalDisconnect()
            log("检测到外屏断开，已安排强制启用内屏和独立重试")
        }
        guard isDisplaySessionSafe else { return }
        pendingDisplayConnectionState = nil
        scheduleDisplayPolicy(forExternalConnection: connected)
    }

    @objc private func applicationWillTerminate() {
        pendingDisplayPolicyWorkItem?.cancel()
        _ = displayController.setStudioEnabled(true)
        _ = keepAwakeController.setActive(false)
    }

    private func configurePanel() {
        powerSwitch.target = self
        powerSwitch.action = #selector(powerChanged)
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.isContinuous = true
        brightnessSlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isBrightnessSliderTracking = tracking
            if !tracking { self.flushSliderInteraction() }
        }
        temperatureSlider.target = self
        temperatureSlider.action = #selector(temperatureChanged)
        temperatureSlider.isContinuous = true
        temperatureSlider.onTrackingChanged = { [weak self] tracking in
            guard let self else { return }
            self.isTemperatureSliderTracking = tracking
            if !tracking { self.flushSliderInteraction() }
        }
        temperatureSlider.numberOfTickMarks = 5
        temperatureSlider.tickMarkPosition = .below
        timeTemperatureSwitch.target = self
        timeTemperatureSwitch.action = #selector(timeTemperatureChanged)
        timeTemperatureSwitch.toolTip = "根据当前时间自动调整色温"
        autoLightSwitch.target = self
        autoLightSwitch.action = #selector(autoLightChanged)
        autoLightSwitch.toolTip = "使用官方 HID 切换指令开启或关闭自动感光"
        presenceSwitch.target = self
        presenceSwitch.action = #selector(presenceChanged)
        for seconds in presenceDelayOptions {
            let title = "\(seconds / 60) 分钟"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = seconds
            presenceDelayPopup.menu?.addItem(item)
        }
        presenceDelayPopup.target = self
        presenceDelayPopup.action = #selector(presenceDelayChanged)
        selectPresenceDelay(presenceDelaySeconds)
        for (title, value) in [("低", 0), ("中", 1), ("高", 2)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = value
            presenceSensitivityPopup.menu?.addItem(item)
        }
        presenceSensitivityPopup.selectItem(withTag: presenceSensitivity)
        presenceSensitivityPopup.target = self
        presenceSensitivityPopup.action = #selector(presenceSensitivityChanged)
        videoModeSwitch.target = self
        videoModeSwitch.action = #selector(videoModeChanged)
        readingModeSwitch.target = self
        readingModeSwitch.action = #selector(readingModeChanged)
        readingModeSwitch.toolTip = "一键应用护眼组合：亮度 70%、色温 4200K、关闭视频模式；关闭时恢复进入前的灯态"
        comboPolicySwitch.target = self
        comboPolicySwitch.action = #selector(comboPolicyChanged)
        comboPolicySwitch.toolTip = "组合策略：入座/离座与 Mac 活动决定开关，环境光决定亮度，时段为主决定色温；开启后自动关闭自动感光、亮度跟随与色温随时间"
        comboStatusLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        comboStatusLabel.textColor = .secondaryLabelColor
        comboStatusLabel.isHidden = !isComboPolicyEnabled
        comboStatusLabel.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        modeButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        modeButton.imagePosition = .imageTrailing
        modeButton.alignment = .left
        modeButton.bezelStyle = .rounded
        modeButton.controlSize = .large
        modeButton.font = UIStyle.bodyFont
        modeButton.target = self
        modeButton.action = #selector(showModeMenu)
        bindAppButton.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        bindAppButton.imagePosition = .imageLeading
        bindAppButton.bezelStyle = .roundRect
        bindAppButton.controlSize = .small
        bindAppButton.target = self
        bindAppButton.action = #selector(bindCurrentModeToApp)
        brightnessFollowSwitch.target = self
        brightnessFollowSwitch.action = #selector(brightnessFollowChanged)
        displayBrightnessLockSwitch.target = self
        displayBrightnessLockSwitch.action = #selector(displayBrightnessLockChanged)
        displayBrightnessLockSwitch.toolTip = "锁定 MacBook 内屏与 Studio Display 当前亮度差，调节任意一块时双向跟随"
        powerSyncSwitch.target = self
        powerSyncSwitch.action = #selector(powerSyncChanged)
        keepAwakeSwitch.target = self
        keepAwakeSwitch.action = #selector(keepAwakeChanged)
        keepAwakeSwitch.toolTip = "在电池、接通电源或合盖时阻止休眠；首次开启需要管理员授权"
        captureBrightButton.target = self
        captureBrightButton.action = #selector(captureBrightThreshold)
        captureBrightButton.setButtonType(.momentaryPushIn)
        captureBrightButton.toolTip = "点击后将当前环境值保存为明亮关灯点"
        captureDarkButton.target = self
        captureDarkButton.action = #selector(captureDarkThreshold)
        captureDarkButton.setButtonType(.momentaryPushIn)
        captureDarkButton.toolTip = "点击后将当前环境值保存为昏暗开灯点"
        ambientEnableSwitch.target = self
        ambientEnableSwitch.action = #selector(ambientEnableChanged)
        for field in [brightThresholdField, darkThresholdField] {
            field.delegate = self
        }
        ambientStatusLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        ambientStatusLabel.textColor = .secondaryLabelColor
        displayPowerSwitch.target = self
        displayPowerSwitch.action = #selector(displayPowerChanged)
        studioPowerSwitch.target = self
        studioPowerSwitch.action = #selector(studioPowerChanged)
        studioPowerSwitch.toolTip = "纯黑遮罩，不断开显示器、不改变窗口布局；双击黑屏或再次点击按钮恢复"
        displayRotateButton.setButtonType(.momentaryPushIn)
        displayRotateButton.target = self
        displayRotateButton.action = #selector(displayRotationChanged)
        displayAutoPresetSwitch.target = self
        displayAutoPresetSwitch.action = #selector(displayAutoPresetChanged)
        rotationModeButton.title = loadRotationPreset().name
        rotationModeButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        rotationModeButton.imagePosition = .imageTrailing
        rotationModeButton.alignment = .left
        rotationModeButton.bezelStyle = .rounded
        rotationModeButton.controlSize = .large
        rotationModeButton.font = UIStyle.bodyFont
        rotationModeButton.target = self
        rotationModeButton.action = #selector(showRotationModeMenu)

        [brightnessSlider, temperatureSlider].forEach { $0.controlSize = .small }
        [presenceDelayPopup, presenceSensitivityPopup].forEach { $0.controlSize = .small }
        brightnessValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        brightnessValueLabel.textColor = .secondaryLabelColor
        temperatureValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        temperatureValueLabel.textColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "iScreen Menu")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Screen and Light Controller")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        let brightnessRow = sliderRow(symbol: "sun.max", title: "亮度", slider: brightnessSlider, valueLabel: brightnessValueLabel)
        let temperatureRow = sliderRow(symbol: "thermometer.medium", title: "色温", slider: temperatureSlider, valueLabel: temperatureValueLabel)
        let delayField = optionField(symbol: "clock", title: "离席时间", control: presenceDelayPopup)
        let sensitivityField = optionField(symbol: "gauge", title: "侦测灵敏度", control: presenceSensitivityPopup)
        let presenceOptions = NSStackView(views: [delayField, sensitivityField])
        presenceOptions.orientation = .horizontal
        presenceOptions.alignment = .top
        presenceOptions.spacing = 12
        delayField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        sensitivityField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let featureTitle = sectionLabel("快捷控制")
        let featureGrid = NSGridView(views: [
            [powerSwitch, autoLightSwitch, presenceSwitch],
            [videoModeSwitch, brightnessFollowSwitch, powerSyncSwitch],
            [timeTemperatureSwitch, displayBrightnessLockSwitch, keepAwakeSwitch],
            [readingModeSwitch, comboPolicySwitch, NSView()]
        ])
        featureGrid.rowSpacing = 6
        featureGrid.columnSpacing = 6
        featureGrid.xPlacement = .fill
        for button in [powerSwitch, autoLightSwitch, presenceSwitch, videoModeSwitch, brightnessFollowSwitch, powerSyncSwitch, timeTemperatureSwitch, displayBrightnessLockSwitch, keepAwakeSwitch, readingModeSwitch, comboPolicySwitch] {
            button.widthAnchor.constraint(equalToConstant: 100).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        let featureContainer = NSStackView(views: [featureTitle, featureGrid])
        featureContainer.orientation = .vertical
        featureContainer.alignment = .leading
        featureContainer.spacing = UIStyle.sectionSpacing

        let adjustmentTitle = sectionLabel("灯光调节")
        let adjustmentContainer = NSStackView(views: [adjustmentTitle, brightnessRow, temperatureRow])
        adjustmentContainer.orientation = .vertical
        adjustmentContainer.alignment = .leading
        adjustmentContainer.spacing = 8

        let presetTitle = sectionLabel("灯光预设")
        modeButton.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        modeButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let rotationPresetTitle = sectionLabel("旋转预设")
        rotationModeButton.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        rotationModeButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let presetContainer = NSStackView(views: [presetTitle, modeButton, rotationPresetTitle, rotationModeButton])
        presetContainer.orientation = .vertical
        presetContainer.alignment = .leading
        presetContainer.spacing = UIStyle.sectionSpacing

        let presenceTitle = sectionLabel("入座检测设置")
        let presenceContainer = NSStackView(views: [presenceTitle, presenceOptions])
        presenceContainer.orientation = .vertical
        presenceContainer.alignment = .leading
        presenceContainer.spacing = UIStyle.sectionSpacing

        let ambientTitle = sectionLabel("环境光标定")
        let ambientEnableLabel = NSTextField(labelWithString: "启用")
        ambientEnableLabel.font = UIStyle.bodyFont
        ambientEnableLabel.textColor = .secondaryLabelColor
        let ambientHeader = NSStackView(views: [ambientTitle, flexibleSpace(), ambientEnableLabel, ambientEnableSwitch])
        ambientHeader.orientation = .horizontal
        ambientHeader.alignment = .centerY
        ambientHeader.spacing = 6
        ambientHeader.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        for button in [captureBrightButton, captureDarkButton] {
            button.widthAnchor.constraint(equalToConstant: 92).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        for label in [brightThresholdField, darkThresholdField] {
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        let brightCapture = NSStackView(views: [captureBrightButton, brightThresholdField])
        brightCapture.orientation = .horizontal
        brightCapture.alignment = .centerY
        brightCapture.spacing = 4
        let darkCapture = NSStackView(views: [captureDarkButton, darkThresholdField])
        darkCapture.orientation = .horizontal
        darkCapture.alignment = .centerY
        darkCapture.spacing = 4
        let ambientActions = NSStackView(views: [brightCapture, darkCapture])
        ambientActions.orientation = .horizontal
        ambientActions.alignment = .centerY
        ambientActions.spacing = 12
        ambientActions.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        ambientStatusLabel.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        let ambientContainer = NSStackView(views: [ambientHeader, ambientActions, ambientStatusLabel])
        ambientContainer.orientation = .vertical
        ambientContainer.alignment = .leading
        ambientContainer.spacing = 6

        let displayGrid = NSGridView(views: [[displayPowerSwitch, displayRotateButton], [studioPowerSwitch, NSView()]])
        displayGrid.rowSpacing = 6
        displayGrid.columnSpacing = 6
        displayGrid.xPlacement = .fill
        for button in [displayPowerSwitch, studioPowerSwitch, displayRotateButton] {
            button.widthAnchor.constraint(equalToConstant: 153).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        let displayTitle = sectionLabel("显示屏与旋转")
        let displayContainer = NSStackView(views: [displayTitle, displayGrid])
        displayContainer.orientation = .vertical
        displayContainer.alignment = .leading
        displayContainer.spacing = UIStyle.sectionSpacing

        let autoPresetLabel = NSTextField(labelWithString: "启用预设")
        autoPresetLabel.font = UIStyle.bodyFont
        autoPresetLabel.textColor = .secondaryLabelColor
        let rotationPresetHeader = NSStackView(views: [rotationPresetTitle, flexibleSpace(), autoPresetLabel, displayAutoPresetSwitch])
        rotationPresetHeader.orientation = .horizontal
        rotationPresetHeader.alignment = .centerY
        rotationPresetHeader.spacing = 6
        rotationPresetHeader.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        presetContainer.setViews([presetTitle, modeButton, rotationPresetHeader, rotationModeButton], in: .top)

        standbyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        standbyLabel.textColor = .secondaryLabelColor
        standbyLabel.isHidden = isStudioDisplayAvailable
        standbyLabel.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        versionLabel.stringValue = appVersionText()
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        let quitButton = NSButton(title: "退出应用", target: self, action: #selector(quitApplication))
        quitButton.bezelStyle = .inline
        quitButton.controlSize = .small
        quitButton.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitButton.imagePosition = .imageLeading
        quitButton.font = UIStyle.controlFont
        quitButton.toolTip = "退出 iScreen Menu；下次登录或重新运行 install.sh 才会启动"
        let footer = NSStackView(views: [versionLabel, flexibleSpace(), quitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true

        let stack = NSStackView(views: [header, standbyLabel, separator(), featureContainer, comboStatusLabel, separator(), adjustmentContainer,
                                       separator(), ambientContainer, separator(), presenceContainer, separator(), displayContainer,
                                       separator(), presetContainer, separator(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: UIStyle.outerInset, bottom: 14, right: UIStyle.outerInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [brightnessRow, temperatureRow, presenceOptions] {
            view.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        }

        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: UIStyle.panelWidth, height: 710))
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor)
        ])
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: UIStyle.panelWidth, height: 710)
        popover.behavior = .transient
    }

    private func sliderRow(symbol: String, title: String, slider: NSSlider, valueLabel: NSTextField) -> NSStackView {
        let label = rowLabel(title)
        label.widthAnchor.constraint(equalToConstant: 32).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 184).isActive = true
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [symbolView(symbol), label, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func optionField(symbol: String, title: String, control: NSView) -> NSStackView {
        let heading = NSStackView(views: [symbolView(symbol), rowLabel(title)])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        let field = NSStackView(views: [heading, control])
        field.orientation = .vertical
        field.alignment = .leading
        field.spacing = 5
        control.widthAnchor.constraint(equalToConstant: 150).isActive = true
        return field
    }

    private func optionsRow(symbol: String, title: String, controls: [NSView]) -> NSStackView {
        let row = NSStackView(views: [symbolView(symbol), rowLabel(title), flexibleSpace()] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func symbolView(_ name: String) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = .init(pointSize: UIStyle.iconSize, weight: .regular)
        view.widthAnchor.constraint(equalToConstant: 18).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }

    private func rowLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = UIStyle.bodyFont
        return label
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = UIStyle.captionFont
        label.textColor = .secondaryLabelColor
        return label
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func separator() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        return divider
    }

    private func refreshControls() {
        // 未连接 Studio Display 时整个面板进入待机：仅保留防休眠可用。
        let standby = !isStudioDisplayAvailable
        standbyLabel.isHidden = !standby
        let displayControlsAllowed = isStudioDisplayAvailable && isDisplaySessionSafe && !isConsoleSessionLocked()
        let studioID = displayController.studioTarget()
        studioPowerSwitch.state = studioID != nil && !displayController.isStudioCovered ? .on : .off
        studioPowerSwitch.isEnabled = displayControlsAllowed && studioID != nil
        powerSwitch.state = lamp.isPowerOn == true ? .on : .off
        let autoLightChangePending = autoLightChangePendingUntil.map { Date() < $0 } ?? false
        if isAmbientPresenceLockActive {
            autoLightSwitch.title = autoLightWasEnabledBeforeAmbientLock ? "感光暂停" : "自动感光"
            autoLightSwitch.state = autoLightWasEnabledBeforeAmbientLock ? .on : .off
            autoLightSwitch.toolTip = autoLightWasEnabledBeforeAmbientLock
                ? "原设置已开启；环境关灯锁定期间临时暂停，解除后自动恢复"
                : "环境关灯锁定期间不可开启自动感光"
        } else if autoLightChangePending, let pendingAutoLightState {
            autoLightSwitch.title = "自动感光"
            autoLightSwitch.state = pendingAutoLightState ? .on : .off
            autoLightSwitch.toolTip = pendingAutoLightState ? "正在开启自动感光" : "正在关闭自动感光"
        } else if lamp.isAutoLightEnabled == true {
            autoLightSwitch.title = "自动感光"
            autoLightChangePendingUntil = nil
            pendingAutoLightState = nil
            autoLightSwitch.state = .on
            autoLightSwitch.toolTip = "关闭自动感光"
        } else {
            autoLightSwitch.title = "自动感光"
            autoLightChangePendingUntil = nil
            pendingAutoLightState = nil
            autoLightSwitch.state = .off
            autoLightSwitch.toolTip = "开启自动感光"
        }
        if isAmbientPresenceLockActive || isScreenSleepPresenceLockActive {
            let wasEnabled = presenceWasEnabledBeforeAmbientLock || presenceWasEnabledBeforeScreenSleep
            presenceSwitch.title = wasEnabled ? "入座暂停" : "入座检测"
            presenceSwitch.state = wasEnabled ? .on : .off
            presenceSwitch.toolTip = wasEnabled
                ? "原设置已开启；关灯锁定期间临时暂停，解除后自动恢复"
                : "关灯锁定期间不可开启入座检测"
        } else {
            if isPresenceSuspendedByPolicy, lamp.isPresenceDetectionEnabled != true {
                presenceSwitch.title = "入座检测·暂停"
                presenceSwitch.state = .off
                presenceSwitch.toolTip = "环境光已充足，策略临时停用灯体入座检测避免自动点灯；屏幕休眠时会自动恢复"
            } else {
                presenceSwitch.title = "入座检测"
                presenceSwitch.state = lamp.isPresenceDetectionEnabled == true ? .on : .off
                presenceSwitch.toolTip = "开启或关闭灯体入座检测"
            }
        }
        videoModeSwitch.state = lamp.isVideoModeEnabled == true ? .on : .off
        brightnessFollowSwitch.state = isBrightnessFollowEnabled ? .on : .off
        brightnessFollowSwitch.isEnabled = !standby && lamp.isConnected && !isComboPolicyEnabled
        displayBrightnessLockSwitch.state = isDisplayBrightnessLockEnabled ? .on : .off
        displayBrightnessLockSwitch.isEnabled = displayControlsAllowed && studioDisplayID() != nil && activeBuiltinDisplayID() != nil
        powerSyncSwitch.state = isPowerSyncEnabled ? .on : .off
        keepAwakeSwitch.state = keepAwakeController.isActive ? .on : .off
        timeTemperatureSwitch.state = isTimeTemperatureEnabled ? .on : .off
        readingModeSwitch.state = isReadingModeEnabled ? .on : .off
        comboPolicySwitch.state = isComboPolicyEnabled ? .on : .off
        comboStatusLabel.isHidden = !isComboPolicyEnabled
        updateAmbientStatusLabel()
        if let builtin = displayController.builtinDisplay() {
            let online = CGDisplayIsOnline(builtin) != 0
            displayPowerSwitch.state = online ? .on : .off
            displayPowerSwitch.isEnabled = displayControlsAllowed && displayController.isAvailable
            displayRotateButton.isEnabled = displayControlsAllowed && online && displayController.isAvailable
            rotationModeButton.isEnabled = displayControlsAllowed && online && displayController.isAvailable
            displayRotateButton.title = online ? "旋转 \(Int(CGDisplayRotation(builtin).rounded()))°" : "旋转 —"
        } else {
            displayPowerSwitch.state = .off
            displayPowerSwitch.isEnabled = false
            displayRotateButton.isEnabled = false
            rotationModeButton.isEnabled = false
            displayRotateButton.title = "旋转 —"
        }
        displayAutoPresetSwitch.state = isDisplayAutoPresetEnabled ? .on : .off
        displayAutoPresetSwitch.isEnabled = displayControlsAllowed && displayController.isAvailable && displayController.builtinDisplay() != nil
        rotationModeButton.title = loadRotationPreset().name
        selectPresenceDelay(presenceDelaySeconds)
        presenceSensitivityPopup.selectItem(withTag: presenceSensitivity)
        if let brightness = lamp.currentBrightness, !isBrightnessSliderTracking {
            brightnessSlider.doubleValue = Double(brightness)
            brightnessValueLabel.stringValue = "\(brightness)%"
        }
        if let temperature = lamp.currentTemperature, !isTemperatureSliderTracking {
            temperatureSlider.doubleValue = Double(temperature)
            temperatureValueLabel.stringValue = "\(temperature)K"
        }
        let enabled = !standby && lamp.isConnected
        modeButton.isEnabled = enabled
        bindAppButton.isEnabled = enabled
        brightThresholdField.isEnabled = !standby
        darkThresholdField.isEnabled = !standby
        powerSwitch.isEnabled = enabled
        autoLightSwitch.isEnabled = enabled && !isAmbientPresenceLockActive && !isComboPolicyEnabled
        brightnessSlider.isEnabled = enabled
        temperatureSlider.isEnabled = enabled && !isTimeTemperatureEnabled
        timeTemperatureSwitch.isEnabled = enabled && !isComboPolicyEnabled
        presenceSwitch.isEnabled = enabled && !isAmbientPresenceLockActive && !isScreenSleepPresenceLockActive
        videoModeSwitch.isEnabled = enabled
        readingModeSwitch.isEnabled = enabled
        comboPolicySwitch.isEnabled = enabled
        powerSyncSwitch.isEnabled = enabled
        captureBrightButton.isEnabled = !standby && currentDisplayAmbientProxy != nil
        captureDarkButton.isEnabled = !standby && currentDisplayAmbientProxy != nil
        presenceDelayPopup.isEnabled = enabled
        presenceSensitivityPopup.isEnabled = enabled
        publishPanelSnapshot()
    }

    // MARK: - SwiftUI 面板桥接

    /// 用 SwiftUI + Liquid Glass 面板替换 AppKit 布局，原有控件对象保留作为状态载体。
    private func installGlassPanel() {
        panelModel.actions = PanelActions(
            setPower: { [weak self] on in
                guard let self else { return }
                self.powerSwitch.state = on ? .on : .off
                self.powerChanged()
            },
            setBrightness: { [weak self] value in
                guard let self else { return }
                self.brightnessSlider.doubleValue = value.rounded()
                self.brightnessValueLabel.stringValue = "\(Int(value.rounded()))%"
                self.brightnessChanged()
            },
            brightnessEditing: { [weak self] editing in
                guard let self else { return }
                self.isBrightnessSliderTracking = editing
                if !editing { self.flushSliderInteraction() }
            },
            setTemperature: { [weak self] value in
                guard let self else { return }
                self.temperatureSlider.doubleValue = value
                self.temperatureChanged()
            },
            temperatureEditing: { [weak self] editing in
                guard let self else { return }
                self.isTemperatureSliderTracking = editing
                if !editing { self.flushSliderInteraction() }
            },
            setAutoLight: { [weak self] on in
                guard let self else { return }
                self.autoLightSwitch.state = on ? .on : .off
                self.autoLightChanged()
            },
            setPresence: { [weak self] on in
                guard let self else { return }
                self.presenceSwitch.state = on ? .on : .off
                self.presenceChanged()
            },
            setPresenceDelay: { [weak self] seconds in
                guard let self else { return }
                self.selectPresenceDelay(seconds)
                self.presenceDelayChanged()
            },
            setPresenceSensitivity: { [weak self] value in
                guard let self else { return }
                self.presenceSensitivityPopup.selectItem(withTag: value)
                self.presenceSensitivityChanged()
            },
            setVideoMode: { [weak self] on in
                guard let self else { return }
                self.videoModeSwitch.state = on ? .on : .off
                self.videoModeChanged()
            },
            setBrightnessFollow: { [weak self] on in
                guard let self else { return }
                self.brightnessFollowSwitch.state = on ? .on : .off
                self.brightnessFollowChanged()
            },
            setPowerSync: { [weak self] on in
                guard let self else { return }
                self.powerSyncSwitch.state = on ? .on : .off
                self.powerSyncChanged()
            },
            setTimeTemperature: { [weak self] on in
                guard let self else { return }
                self.timeTemperatureSwitch.state = on ? .on : .off
                self.timeTemperatureChanged()
            },
            setDisplayLock: { [weak self] on in
                guard let self else { return }
                self.displayBrightnessLockSwitch.state = on ? .on : .off
                self.displayBrightnessLockChanged()
            },
            setKeepAwake: { [weak self] on in
                guard let self else { return }
                self.keepAwakeSwitch.state = on ? .on : .off
                self.keepAwakeChanged()
            },
            setReadingMode: { [weak self] on in
                guard let self else { return }
                self.readingModeSwitch.state = on ? .on : .off
                self.readingModeChanged()
            },
            setCombo: { [weak self] on in
                guard let self else { return }
                self.comboPolicySwitch.state = on ? .on : .off
                self.comboPolicyChanged()
            },
            captureClose: { [weak self] in self?.captureBrightThreshold() },
            captureOpen: { [weak self] in self?.captureDarkThreshold() },
            commitClose: { [weak self] text in self?.commitAmbientText(text, isClose: true) },
            commitOpen: { [weak self] text in self?.commitAmbientText(text, isClose: false) },
            setAmbientRules: { [weak self] on in
                guard let self else { return }
                self.ambientEnableSwitch.state = on ? .on : .off
                self.ambientEnableChanged()
            },
            setBuiltin: { [weak self] on in
                guard let self else { return }
                self.displayPowerSwitch.state = on ? .on : .off
                self.displayPowerChanged()
            },
            rotateBuiltin: { [weak self] in self?.displayRotationChanged() },
            setStudio: { [weak self] on in
                guard let self else { return }
                self.studioPowerSwitch.state = on ? .on : .off
                self.studioPowerChanged()
            },
            setDisplayAutoPreset: { [weak self] on in
                guard let self else { return }
                self.displayAutoPresetSwitch.state = on ? .on : .off
                self.displayAutoPresetChanged()
            },
            applyMode: { [weak self] index in
                guard let self else { return }
                let item = NSMenuItem(title: self.modeNames()[index], action: nil, keyEquivalent: "")
                item.tag = index
                self.presetChanged(item)
            },
            showModeCenter: { [weak self] in self?.showModeCenter() },
            bindCurrentApp: { [weak self] in self?.bindCurrentModeToApp() },
            applyRotationPreset: { [weak self] in self?.applyRotationPreset() },
            saveRotationPreset: { [weak self] in self?.saveCurrentRotationPreset() },
            toggleRotationAutomation: { [weak self] in self?.toggleRotationPresetAutomation() },
            quit: { [weak self] in self?.quitApplication() }
        )
        let host = NSHostingController(rootView: GlassPanelView(model: panelModel))
        host.view.frame = NSRect(x: 0, y: 0, width: 372, height: 720)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        glassHostController = host
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 372, height: 720)
    }

    /// 把 AppKit 控件上的当前状态镜像给 SwiftUI 面板。
    private func publishPanelSnapshot() {
        var snapshot = PanelSnapshot()
        snapshot.standbyNote = isStudioDisplayAvailable ? nil : "未检测到 Studio Display，功能待机"
        snapshot.lampConnected = lamp.isConnected
        snapshot.powerOn = powerSwitch.state == .on
        snapshot.brightness = Double(lamp.currentBrightness ?? Int(brightnessSlider.doubleValue))
        snapshot.brightnessText = brightnessValueLabel.stringValue
        snapshot.temperature = Double(lamp.currentTemperature ?? Int(temperatureSlider.doubleValue))
        snapshot.temperatureText = temperatureValueLabel.stringValue
        snapshot.autoLightOn = autoLightSwitch.state == .on
        snapshot.autoLightTitle = autoLightSwitch.title
        snapshot.autoLightEnabled = autoLightSwitch.isEnabled
        snapshot.presenceOn = presenceSwitch.state == .on
        snapshot.presenceTitle = presenceSwitch.title
        snapshot.presenceEnabled = presenceSwitch.isEnabled
        snapshot.videoOn = videoModeSwitch.state == .on
        snapshot.brightnessFollowOn = brightnessFollowSwitch.state == .on
        snapshot.brightnessFollowEnabled = brightnessFollowSwitch.isEnabled
        snapshot.powerSyncOn = powerSyncSwitch.state == .on
        snapshot.timeTemperatureOn = timeTemperatureSwitch.state == .on
        snapshot.timeTemperatureEnabled = timeTemperatureSwitch.isEnabled
        snapshot.displayLockOn = displayBrightnessLockSwitch.state == .on
        snapshot.displayLockEnabled = displayBrightnessLockSwitch.isEnabled
        snapshot.keepAwakeOn = keepAwakeSwitch.state == .on
        snapshot.readingModeOn = readingModeSwitch.state == .on
        snapshot.comboOn = comboPolicySwitch.state == .on
        snapshot.comboStatus = comboStatusLabel.stringValue
        snapshot.presenceDelay = presenceDelaySeconds
        snapshot.presenceDelayOptions = presenceDelayOptions.map { seconds in
            PresenceDelayOption(id: seconds, label: "\(seconds / 60) 分钟")
        }
        snapshot.presenceSensitivity = presenceSensitivity
        snapshot.ambientCloseText = brightThresholdField.stringValue
        snapshot.ambientOpenText = darkThresholdField.stringValue
        snapshot.ambientStatus = ambientStatusLabel.stringValue
        snapshot.ambientRulesOn = ambientEnableSwitch.state == .on
        snapshot.ambientRulesEnabled = ambientEnableSwitch.isEnabled
        snapshot.ambientFieldsEnabled = brightThresholdField.isEnabled
        snapshot.captureEnabled = captureBrightButton.isEnabled
        snapshot.builtinOn = displayPowerSwitch.state == .on
        snapshot.builtinEnabled = displayPowerSwitch.isEnabled
        snapshot.rotateTitle = displayRotateButton.title
        snapshot.rotateEnabled = displayRotateButton.isEnabled
        snapshot.studioOn = studioPowerSwitch.state == .on
        snapshot.studioEnabled = studioPowerSwitch.isEnabled
        snapshot.displayAutoPresetOn = displayAutoPresetSwitch.state == .on
        snapshot.displayAutoPresetEnabled = displayAutoPresetSwitch.isEnabled
        snapshot.modeTitle = modeButton.title
        snapshot.modeItems = modeNames()
        snapshot.rotationTitle = rotationModeButton.title
        snapshot.bindTitle = bindAppButton.title
        snapshot.version = appVersionText()
        if panelModel.snapshot != snapshot {
            panelModel.snapshot = snapshot
        }
    }

    /// SwiftUI 输入框提交：校验后写入标定值。
    private func commitAmbientText(_ text: String, isClose: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value >= 0, value <= 60000 else {
            NSSound.beep()
            ambientStatusLabel.stringValue = "标定值需为 0–60000 的整数"
            publishPanelSnapshot()
            return
        }
        applyAmbientThreshold(value, isClose: isClose)
        log("已手动设置环境\(isClose ? "关灯点" : "开灯点")：\(value)")
        publishPanelSnapshot()
    }

    private func syncThresholdFields(force: Bool = false) {
        if force || brightThresholdField.currentEditor() == nil {
            brightThresholdField.stringValue = ambientCloseThreshold.map(String.init) ?? "--"
        }
        if force || darkThresholdField.currentEditor() == nil {
            darkThresholdField.stringValue = ambientOpenThreshold.map(String.init) ?? "--"
        }
    }

    private static func thresholdField() -> NSTextField {
        let field = NSTextField(string: "--")
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        field.alignment = .right
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.toolTip = "可直接输入数值，回车或失焦即保存；也可用左侧按钮采集当前环境值"
        return field
    }

    private func updateIcon(healthy: Bool) {
        let iconColor: NSColor
        if !isStudioDisplayAvailable {
            // 待机：未连接 Studio Display 不算异常，用灰色区分。
            iconColor = .systemGray
        } else if !healthy {
            iconColor = .systemRed
        } else if lamp.isPowerOn == true {
            iconColor = .systemYellow
        } else {
            iconColor = .systemGray
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [iconColor])
        let symbol = NSImage(systemSymbolName: "sun.min.fill", accessibilityDescription: "iScreenBar 状态")?
            .withSymbolConfiguration(configuration)
        symbol?.isTemplate = false
        item.button?.attributedTitle = NSAttributedString(string: "")
        item.button?.image = symbol
    }

    private func selectPresenceDelay(_ seconds: Int) {
        if let item = presenceDelayPopup.menu?.item(withTag: seconds) {
            presenceDelayPopup.select(item)
            return
        }
        if let fallback = presenceDelayPopup.itemArray.first(where: { $0.tag == 180 }) {
            presenceDelayPopup.select(fallback)
        }
    }

    private func selectedPresenceDelaySeconds() -> Int {
        return presenceDelayPopup.selectedItem?.tag ?? presenceDelaySeconds
    }

}

extension StatusIndicator: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commitAmbientThreshold(from: field)
    }
}

private final class LampController {
    private var manager: IOHIDManager
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private(set) var currentBrightness: Int?
    private(set) var currentTemperature: Int?
    private(set) var isPowerOn: Bool?
    private(set) var isAutoLightEnabled: Bool?
    private(set) var isPresenceDetectionEnabled: Bool?
    private(set) var isVideoModeEnabled: Bool?
    private(set) var statusRevision = 0
    private var lastTemperatureValues: (Int, Int)?
    private var lastStatusHex: String?

    var isConnected: Bool { device != nil }

    init() {
        manager = Self.makeManager()
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("无法打开 iScreenBar USB HID 设备")
            return
        }
        guard attachFirstDevice() else {
            log("未检测到 iScreenBar USB HID 设备，等待重新连接")
            return
        }
        _ = requestStatus()
    }

    deinit {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deallocate()
    }

    func setPower(on: Bool) -> Bool {
        if sendPowerReport(on: on) {
            isPowerOn = on
            lastLampPowerCommandAt = Date()
            log("灯已\(on ? "开启" : "关闭")")
            return true
        }

        log("USB HID 连接已失效，正在重新连接")
        guard reconnect(), sendPowerReport(on: on) else {
            log("USB HID 重连后指令仍失败")
            return false
        }

        isPowerOn = on
        lastLampPowerCommandAt = Date()
        log("重连成功，灯已\(on ? "开启" : "关闭")")
        return true
    }

    func setBrightness(_ brightness: Int) -> Bool {
        let value = UInt8(clamping: max(1, min(100, brightness)))
        guard sendCommand(0x04, payload: [value, value]) else { return false }
        currentBrightness = Int(value)
        log("灯亮度已调整为 \(brightness)%")
        return true
    }

    func setTemperature(_ temperature: Int) -> Bool {
        let value = max(2700, min(6500, temperature))
        let high = UInt8((value >> 8) & 0xFF)
        let low = UInt8(value & 0xFF)
        // iScreenBar 有主灯和背灯两组独立色温；两组都必须写入完整的 16 位 Kelvin 值。
        guard sendCommand(0x03, payload: [high, low, high, low]) else { return false }
        currentTemperature = value
        log("灯色温已调整为 \(value)K（主灯与背灯同步）")
        return true
    }

    func setAutoLight(enabled: Bool) -> Bool {
        if isAutoLightEnabled == enabled {
            return true
        }
        if enabled {
            // 官方 App 用 01 F0 01 04 F5 进入自动感光。
            guard sendCommand(0x01, payload: []) else { return false }
        } else {
            // 灯具固件不会用同一指令退出自动感光；官方控制逻辑通过写入手动亮度退出。
            guard let brightness = currentBrightness else {
                log("尚未获取当前亮度，无法关闭自动感光")
                return false
            }
            guard setBrightness(brightness) else { return false }
        }
        isAutoLightEnabled = enabled
        log(enabled ? "已开启自动感光" : "已关闭自动感光")
        return true
    }

    func setPresenceDetection(enabled: Bool, delaySeconds: Int, sensitivity: Int) -> Bool {
        let basePayload = [UInt8(enabled ? 1 : 0)]
        let delayMinutes = UInt8(clamping: delaySeconds / 60)
        let sensitivityValue = UInt8(clamping: max(0, min(2, sensitivity)))
        if !sendCommand(0x06, payload: basePayload + [delayMinutes, sensitivityValue]) {
            if !sendCommand(0x06, payload: basePayload) {
                return false
            }
            log("入座检测时间参数发送失败，已回退为仅开关命令")
        }
        isPresenceDetectionEnabled = enabled
        presenceDetectionDelaySeconds = delaySeconds
        log(enabled ? "已开启入座检测" : "已关闭入座检测")
        return true
    }

    private(set) var presenceDetectionDelaySeconds: Int?

    func setVideoMode(enabled: Bool) -> Bool {
        guard sendCommand(0x09, payload: [enabled ? 1 : 0]) else { return false }
        isVideoModeEnabled = enabled
        log(enabled ? "已开启视频模式" : "已关闭视频模式")
        return true
    }

    @discardableResult
    func requestStatus() -> Bool {
        var report = [UInt8](repeating: 0, count: 33)
        report[0] = 0x01
        report[1] = 0xF0
        report[2] = 0x20
        report[3] = 0x04
        report[4] = 0x14
        return send(report)
    }

    func checkConnection() -> Bool {
        if requestStatus() { return true }
        guard reconnect(), requestStatus() else { return false }
        log("USB HID 已重新连接")
        return true
    }

    private func sendPowerReport(on: Bool) -> Bool {
        var report = [UInt8](repeating: 0, count: 33)
        report[0] = 0x01
        report[1] = 0xF0
        report[2] = 0x07
        report[3] = 0x05
        report[4] = on ? 0xFD : 0xFC
        report[5] = on ? 0x01 : 0x00
        return send(report)
    }

    private func sendCommand(_ command: UInt8, payload: [UInt8]) -> Bool {
        var report = [UInt8](repeating: 0, count: 33)
        report[0] = 0x01
        report[1] = 0xF0
        report[2] = command
        report[3] = UInt8(payload.count + 4)
        report[4] = UInt8(truncatingIfNeeded: Int(report[1]) + Int(command) + Int(report[3]) + payload.reduce(0) { $0 + Int($1) })
        for (index, value) in payload.enumerated() {
            report[5 + index] = value
        }
        return send(report)
    }

    private func send(_ report: [UInt8]) -> Bool {
        guard let device else { return false }
        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1,
                                 bytes.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
        if result != kIOReturnSuccess {
            log(String(format: "USB HID 指令失败：0x%08X", result))
        }
        return result == kIOReturnSuccess
    }

    private func configureInputCallback(for device: IOHIDDevice) {
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, 64,
            { context, _, _, _, _, report, reportLength in
                guard let context, reportLength >= 5 else { return }
                let controller = Unmanaged<LampController>.fromOpaque(context).takeUnretainedValue()
                if report[0] == 0x02, report[1] == 0xE1, report[2] == 0x20,
                   report[3] == 0x0D, reportLength >= 15 {
                    let statusHex = (0..<reportLength).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
                    if controller.lastStatusHex != statusHex {
                        controller.lastStatusHex = statusHex
                        log("状态原始报文：\(statusHex)")
                    }
                    controller.isPowerOn = (report[6] & 0x01) != 0
                    controller.isAutoLightEnabled = (report[6] & 0x04) != 0
                    controller.isPresenceDetectionEnabled = (report[6] & 0x20) != 0
                    controller.isVideoModeEnabled = (report[6] & 0x80) != 0
                    let mainTemperature = (Int(report[8]) << 8) | Int(report[9])
                    let backTemperature = (Int(report[11]) << 8) | Int(report[12])
                    if controller.lastTemperatureValues?.0 != mainTemperature ||
                        controller.lastTemperatureValues?.1 != backTemperature {
                        controller.lastTemperatureValues = (mainTemperature, backTemperature)
                        log("色温回读：主灯=\(mainTemperature)K，背灯=\(backTemperature)K")
                    }
                    controller.currentTemperature = mainTemperature
                    controller.currentBrightness = Int(report[10])
                    controller.statusRevision += 1
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func reconnect() -> Bool {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        device = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = Self.makeManager()
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        return attachFirstDevice()
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: benqVendorID,
            kIOHIDProductIDKey as String: iScreenBarProductID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        return manager
    }

    private func attachFirstDevice() -> Bool {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = devices.first else { return false }
        device = first
        configureInputCallback(for: first)
        return true
    }
}

private final class DisplayBrightnessReader {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let getter: GetBrightness?
    private let setter: SetBrightness?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getter = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getter = nil
        }
        if let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setter = unsafeBitCast(symbol, to: SetBrightness.self)
        } else {
            setter = nil
        }
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func percent(for displayID: CGDirectDisplayID) -> Int? {
        guard let getter else { return nil }
        var value: Float = 0
        guard getter(displayID, &value) == 0 else { return nil }
        return Int((max(0, min(1, value)) * 100).rounded())
    }

    func setPercent(_ percent: Int, for displayID: CGDirectDisplayID) -> Bool {
        guard let setter else { return false }
        let value = Float(max(0, min(100, percent))) / 100
        return setter(displayID, value) == 0
    }
}

private final class StudioDisplayAmbientSensor {
    private var manager: IOHIDManager
    private var device: IOHIDDevice?
    private var illuminanceElement: IOHIDElement?
    private var lastReconnectAttempt = Date.distantPast

    init() {
        manager = Self.makeManager()
        guard openManager() else {
            log("无法打开 Studio Display 环境光传感器")
            return
        }
        _ = attachSensor()
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func rawIlluminance() -> Int? {
        if device == nil || illuminanceElement == nil,
           !attachSensor(),
           !reconnectIfNeeded() {
            return nil
        }
        if let value = readCurrentValue() { return value }

        // Studio Display 在锁屏、睡眠或显示器重新排列后会重建 HID 服务。
        // 旧 IOHIDDevice 对象仍可能存在，但 GetValue 会持续失败，必须重建 manager。
        device = nil
        illuminanceElement = nil
        guard reconnectIfNeeded() else { return nil }
        return readCurrentValue()
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x1118,
            kIOHIDPrimaryUsagePageKey as String: 0x20,
            kIOHIDPrimaryUsageKey as String: 0x41
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        return manager
    }

    private func openManager() -> Bool {
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    private func readCurrentValue() -> Int? {
        guard let device, let illuminanceElement else { return nil }
        var rawValue: Unmanaged<IOHIDValue> = .fromOpaque(UnsafeRawPointer(bitPattern: 1)!)
        guard IOHIDDeviceGetValue(device, illuminanceElement, &rawValue) == kIOReturnSuccess else {
            return nil
        }
        let raw = IOHIDValueGetIntegerValue(rawValue.takeUnretainedValue())
        // Studio Display 以约千分之一照度单位回传；转换为易读的相对环境分数。
        return max(0, raw / 1_000)
    }

    private func reconnectIfNeeded() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastReconnectAttempt) >= 2 else { return false }
        lastReconnectAttempt = now
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = Self.makeManager()
        guard openManager(), attachSensor() else { return false }
        log("Studio Display 环境光传感器已重新连接")
        return true
    }

    private func attachSensor() -> Bool {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else { return false }
        let elements = (IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        guard let element = elements.first(where: {
            IOHIDElementGetUsagePage($0) == 0x20 && IOHIDElementGetUsage($0) == 0x04D1
        }) else { return false }
        self.device = device
        illuminanceElement = element
        return true
    }
}

private func studioDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).first {
        CGDisplayIsBuiltin($0) == 0 &&
            CGDisplayIsOnline($0) != 0 &&
            CGDisplayVendorNumber($0) == appleDisplayVendorID &&
            CGDisplayModelNumber($0) == studioDisplayProductID
    }
}

private func activeBuiltinDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).first {
        CGDisplayIsBuiltin($0) != 0 && CGDisplayIsOnline($0) != 0 && CGDisplayIsActive($0) != 0
    }
}

private func isConsoleSessionLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

var displayID = studioDisplayID()
/// App 自身最后一次下发电源指令的时间：3 秒内的电源变化都算自身写入的回显，
/// 不判为固件“自行点亮/熄灭”（否则熄屏同步关灯会被误判成离座、补开又被误判成入座）。
var lastLampPowerCommandAt = Date.distantPast
private let lamp = LampController()
private let displayBrightnessReader = DisplayBrightnessReader()
private let studioAmbientSensor = StudioDisplayAmbientSensor()

if let displayID {
    log("开始监听 Studio Display ID=\(displayID)，分辨率=\(CGDisplayPixelsWide(displayID))x\(CGDisplayPixelsHigh(displayID))")
} else {
    log("未找到外接显示器，程序保持运行并等待 Studio Display 连接")
}
var wasAsleep = displayID.map { CGDisplayIsAsleep($0) != 0 } ?? false
var wasConsoleSessionLocked = isConsoleSessionLocked()
var helperTurnedLampOff = false
/// 入座唤醒显示器的限速时间戳，避免固件反复点亮时不断发唤醒。
var lastPresenceWakeAt = Date.distantPast
/// 入座唤醒后一直无人碰键鼠的连续次数；满 2 次判为固件误检。
var presenceWakeNoResponse = 0
/// 入座唤醒的冷却截止时间：误检暂停期内不再自动点亮显示器。
var presenceWakePausedUntil = Date.distantPast
/// 上一次观察到的灯体电源状态，用于识别“固件自行点亮”这种入座事件。
var lastKnownLampPower: Bool?
/// 最近一次“固件报告有人入座”的时间，短时间内视为有人在座。
var lastPresenceEventAt = Date.distantPast
/// 灯体自行熄灭（离座）的时间：短时间内 App 不再自动补开，避免“刚关又开”。
var lastFirmwareOffAt = Date.distantPast
/// 入座检测启停去抖：期望状态、变更时间与上次下发时间。
var lastPresenceDesire: Bool?
var presenceDesireSince = Date()
var lastPresenceToggleAt = Date.distantPast
/// 上次强制系统熄屏的时间，用于限速，避免与人座唤醒形成循环。
var lastForcedDisplaySleepAt = Date.distantPast
var ambientTurnedLampOff = UserDefaults.standard.bool(forKey: "ambientLampLockActive")
var ambientCloseCandidateSince: Date?
var ambientOpenCandidateSince: Date?
var ambientProxySamples: [(Date, Int)] = []
var ambientProxySourceName: String?
var lastLoggedAmbientProxy: Int?

private func setAmbientLampLock(_ active: Bool) {
    ambientTurnedLampOff = active
    if active {
        UserDefaults.standard.set(true, forKey: "ambientLampLockActive")
    } else {
        UserDefaults.standard.removeObject(forKey: "ambientLampLockActive")
    }
}
private let statusIndicator = StatusIndicator(isAsleep: wasAsleep, lamp: lamp)
log("启动：\(Bundle.main.bundleURL.path)，\(appVersionText())")
log("策略状态：智能组合=\(statusIndicator.isComboPolicyEnabled ? "开" : "关")，环境规则=\(statusIndicator.isAmbientLinkEnabled ? "开" : "关")，标定=关灯\(statusIndicator.ambientCloseThreshold.map(String.init) ?? "无")/开灯\(statusIndicator.ambientOpenThreshold.map(String.init) ?? "无")")
statusIndicator.handleStudioDisplayConnection(connected: displayID != nil)
if !wasAsleep {
    statusIndicator.restorePresenceAfterScreenWake()
}
var wasBrightnessFollowEnabled = statusIndicator.isBrightnessFollowEnabled
var wasDisplayBrightnessLockEnabled = statusIndicator.isDisplayBrightnessLockEnabled
var wasPowerSyncEnabled = statusIndicator.isPowerSyncEnabled
var wasAmbientLinkEnabled = statusIndicator.isAmbientLinkEnabled
var wasAmbientCloseThreshold = statusIndicator.ambientCloseThreshold
var brightnessOffset: Int?
var anchorStatusRevision: Int?
var lastDisplayBrightness: Int?
var displayBrightnessOffset: Int?
var lastBuiltinDisplayBrightness: Int?
var lastStudioDisplayBrightnessForLock: Int?
var displayBrightnessWriteSuppressedUntil = Date.distantPast
var lastStatusRequest = Date.distantPast
var wasLampConnected = lamp.isConnected
if !wasAmbientLinkEnabled, ambientTurnedLampOff || statusIndicator.hasPendingAmbientPresenceRestore {
    if ambientTurnedLampOff, !wasAsleep { _ = lamp.setPower(on: true) }
    setAmbientLampLock(false)
    statusIndicator.restorePresenceAfterAmbientLock()
    log("已清理上次环境规则遗留的关灯与入座暂停状态")
}
if wasBrightnessFollowEnabled {
    anchorStatusRevision = lamp.statusRevision
    lamp.requestStatus()
    log("Studio Display 亮度跟随已开启，正在锁定当前亮度差")
}

private struct ComboPolicyState {
    var lastBrightness: Int?
    var lastTemperature: Int?
    var lastBrightnessWriteAt = Date.distantPast
    var lastTemperatureWriteAt = Date.distantPast
    var lastEnginePowerOffAt = Date.distantPast
    var lastPowerWriteAt = Date.distantPast
    var didWarnThresholdOverlap = false
    /// 平滑后的目标亮度，避免环境光跳变时亮度阶梯突变造成“闪烁”。
    var smoothedBrightness: Double?
    var ambientBrightSince: Date?
    var ambientDarkSince: Date?
}

private var comboPolicyState = ComboPolicyState()

/// Mac 侧空闲秒数（任意键鼠与触控板事件）。
private func systemIdleSeconds() -> TimeInterval {
    guard let anyEvent = CGEventType(rawValue: UInt32.max) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
}

private func comboSetting(_ key: String, _ fallback: Int) -> Int {
    return UserDefaults.standard.object(forKey: key) as? Int ?? fallback
}

/// 组合策略：入座/离座决定开关，环境光映射亮度，时段为主 + 环境微调决定色温。
/// 只在「智能组合」开启时接管；熄屏同步与待机仍在其之前生效。
private func runComboPolicy(isAsleep: Bool, displayAmbientProxy: Int?) {
    guard statusIndicator.isComboPolicyEnabled else { return }
    guard displayID != nil, !isAsleep else {
        statusIndicator.setComboStatus("组合策略 · 显示器未就绪")
        return
    }
    if Date() < statusIndicator.comboManualOverrideUntil {
        statusIndicator.setComboStatus("组合策略 · 手动设置保护中，暂不覆写")
        return
    }
    if statusIndicator.isReadingModeEnabled {
        statusIndicator.setComboStatus("组合策略 · 阅读模式优先，暂停自动调整")
        return
    }
    if statusIndicator.isUserAdjustingLamp {
        statusIndicator.setComboStatus("组合策略 · 正在手动调节，暂停自动调整")
        return
    }

    let openThreshold = statusIndicator.ambientOpenThreshold
    let closeThresholdValue = statusIndicator.ambientCloseThreshold
    let ambient = displayAmbientProxy
    let rawIdle = systemIdleSeconds()
    // 系统在部分上下文会返回 NaN/负值；无效值按“刚有活动”处理，避免整条策略静默失效。
    let idle = rawIdle.isFinite && rawIdle >= 0 ? rawIdle : 0
    // 离座判定阈值：固件实测约 3 分钟才关灯，所以默认用 App 侧 90 秒兼底。
    let idleLimit = TimeInterval(comboSetting("comboIdleSeconds", 600))
    let macActive = idle < idleLimit
    let now = Date()
    // 等待首次状态回读，避免启动瞬间因电源状态未知而多写一次。
    guard lamp.isPowerOn != nil else {
        statusIndicator.setComboStatus("组合策略 · 等待灯体状态")
        return
    }
    // 任何方向的电源写入都留 45 秒冷却，避免门限重叠或状态竞态时反复开关。
    let powerWriteAllowed = now.timeIntervalSince(comboPolicyState.lastPowerWriteAt) >= 45
    // 环境光阈值直接复用面板里的两个标定值（单位≈lux）。
    // 灯体自动感光会持续覆写亮度，与策略引擎冲突，发现即关闭。
    if lamp.isAutoLightEnabled == true {
        _ = lamp.setAutoLight(enabled: false)
        log("组合策略：已关闭灯体自动感光，改由策略按环境光映射亮度")
    }

    // === 优先级：入座 → 屏幕 → 环境光 ===
    // 1) 入座最高优先级：在场以 Mac 键鼠活动为准（空闲超阈值即判离座）。
    //    固件“有人入座”事件只给 120 秒到达宽限，不用作长期在场证据，
    //    否则固件离座关灯后 App 会在 30 分钟内反复把灯又打开。
    let present = macActive
    let arrivalGrace = now.timeIntervalSince(lastPresenceEventAt) < 120
    if !present {
        if powerWriteAllowed, !arrivalGrace, lamp.isPowerOn == true,
           now.timeIntervalSince(comboPolicyState.lastEnginePowerOffAt) > 30 {
            if lamp.setPower(on: false) {
                comboPolicyState.lastEnginePowerOffAt = now
                comboPolicyState.lastPowerWriteAt = now
                log("组合策略：无人（Mac 空闲 \(Int(idle / 60)) 分钟），已关闭 iScreenBar")
            }
        }
        statusIndicator.setComboStatus("组合策略 · 无人（Mac 空闲 \(Int(idle / 60)) 分钟）")
        return
    }

    // 2) 屏幕未唤醒：不点灯（引擎已在 isAsleep 时提前返回）。
    let ambientOnThreshold = openThreshold ?? 400
    let ambientOffThreshold = closeThresholdValue ?? 450

    // 灯亮时读数包含灯自身贡献（实测 65% 时约 +670 lux ≈ 10 lux/%），
    // 扣掉后才能得到“真实环境光”，否则灯一亮就会被判为环境充足而关灯（来回振荡）。
    let lampLuxPerPercent = Double(comboSetting("lampLuxPerPercent", 1))
    let lampContribution = lamp.isPowerOn == true
        ? lampLuxPerPercent * Double(lamp.currentBrightness ?? 0)
        : 0
    let ambientOnly: Int? = ambient.map { max(0, Int((Double($0) - lampContribution).rounded())) }

    // 3) 有人在座（入座检测常开，已检测到入座 event）+ 环境充足 → 关灯
    if let ambientOnly, Double(ambientOnly) >= Double(ambientOffThreshold),
       lamp.isPowerOn == true, powerWriteAllowed,
       now.timeIntervalSince(lastPresenceEventAt) < 3600 {
        if comboPolicyState.ambientBrightSince == nil { comboPolicyState.ambientBrightSince = now }
        if let since = comboPolicyState.ambientBrightSince, now.timeIntervalSince(since) >= 30 {
            if lamp.setPower(on: false) {
                comboPolicyState.lastEnginePowerOffAt = now
                comboPolicyState.lastPowerWriteAt = now
                log("组合策略：环境 \(ambientOnly) lux ≥ 充足阈值 \(ambientOffThreshold)，持续 30 秒，已关闭 iScreenBar")
            }
            statusIndicator.setComboStatus("组合策略 · 环境充足，已关灯")
            return
        }
    } else {
        comboPolicyState.ambientBrightSince = nil
    }

    // 4) 有人 + 环境不足 → 点灯（持续 10 秒确认）
    //    刚被固件判定离座而关灯时，5 分钟内不补开（除非用户正在活跃输入），否则会变成“关→开”反复。
    let reopenAllowed = idle < 60 || now.timeIntervalSince(lastFirmwareOffAt) > 300
    if lamp.isPowerOn != true {
        if let ambient, Double(ambient) <= Double(ambientOnThreshold), reopenAllowed {
            if comboPolicyState.ambientDarkSince == nil { comboPolicyState.ambientDarkSince = now }
            if let since = comboPolicyState.ambientDarkSince, now.timeIntervalSince(since) >= 10,
               powerWriteAllowed, lamp.setPower(on: true) {
                comboPolicyState.lastPowerWriteAt = now
                comboPolicyState.lastEnginePowerOffAt = .distantPast
                log("组合策略：环境 \(ambient) lux ≤ 不足阈值 \(ambientOnThreshold)，已开启 iScreenBar")
            }
        } else {
            comboPolicyState.ambientDarkSince = nil
        }
        statusIndicator.setComboStatus("组合策略 · 在座，等待环境光判定")
        return
    }

    // 3) 亮度：环境越暗灯越亮，在 [下限, 上限] 之间线性映射，再做平滑限速。
    //    使用扣除灯贡献后的环境值，避免“灯变亮 → 读数变高 → 又调低”的反馈振荡。
    guard lamp.isPowerOn == true, let ambientOnly else {
        statusIndicator.setComboStatus(ambientOnly == nil ? "组合策略 · 等待环境光数据" : "组合策略 · 在座，等待开灯条件")
        return
    }
    let brightnessCeiling = min(100, max(1, comboSetting("comboBrightnessMax", 75)))
    let brightnessFloor = min(brightnessCeiling, max(1, comboSetting("comboBrightnessMin", 40)))
    let mapDark = Double(comboSetting("comboMapDark", 150))
    let mapBright = max(mapDark + 1, Double(comboSetting("comboMapBright", 450)))
    let ratio = min(1, max(0, (Double(ambientOnly) - mapDark) / (mapBright - mapDark)))
    let mapped = Double(brightnessCeiling) - Double(brightnessCeiling - brightnessFloor) * ratio

    // 首次从灯体当前亮度起步，让接管过程是渐变而不是一下子跳过去。
    let previous = comboPolicyState.smoothedBrightness
        ?? Double(lamp.currentBrightness ?? Int(mapped.rounded()))
    // 单次最多变化 10%，再乘 0.5 系数，避免环境光跳变时亮度阶跃。
    let slewed = previous + max(-10, min(10, (mapped - previous) * 0.5))
    comboPolicyState.smoothedBrightness = slewed
    let appliedBrightness = max(1, min(100, Int(slewed.rounded())))
    let currentBrightness = lamp.currentBrightness ?? appliedBrightness
    if abs(appliedBrightness - currentBrightness) >= 3,
       now.timeIntervalSince(comboPolicyState.lastBrightnessWriteAt) >= 4,
       lamp.setBrightness(appliedBrightness) {
        comboPolicyState.lastBrightness = appliedBrightness
        comboPolicyState.lastBrightnessWriteAt = now
        log("组合策略：环境（扣除灯贡献）\(ambientOnly) lux → 目标 \(Int(mapped.rounded()))%，平滑后亮度 \(appliedBrightness)%")
    }

    // 4) 色温：时段基线 ± 环境微调（暗更暖、亮更冷），单次最多 250K。
    let baseline = statusIndicator.baselineTemperature(at: now)
    let tweak = Int((Double(comboSetting("comboTemperatureTweakK", 400)) * (ratio * 2 - 1)).rounded())
    let mappedTemperature = max(2700, min(6500, baseline + tweak))
    let currentTemperature = lamp.currentTemperature ?? mappedTemperature
    let temperatureStep = max(-250, min(250, mappedTemperature - currentTemperature))
    let appliedTemperature = max(2700, min(6500, currentTemperature + temperatureStep))
    if abs(appliedTemperature - currentTemperature) >= 100,
       now.timeIntervalSince(comboPolicyState.lastTemperatureWriteAt) >= 30,
       lamp.setTemperature(appliedTemperature) {
        comboPolicyState.lastTemperature = appliedTemperature
        comboPolicyState.lastTemperatureWriteAt = now
        log("组合策略：时段基线 \(baseline)K 微调 \(tweak > 0 ? "+" : "")\(tweak)K → 色温 \(appliedTemperature)K")
    }

    let occupancyText = "在座·键鼠活动"
    statusIndicator.setComboStatus("组合策略 · \(occupancyText) · 亮度 \(appliedBrightness)% · 色温 \(appliedTemperature)K")
}

private func pollDisplayAndLamp() {
    statusIndicator.applyModeForFrontmostAppIfNeeded()
    let consoleSessionLocked = isConsoleSessionLocked()
    if consoleSessionLocked != wasConsoleSessionLocked {
        if consoleSessionLocked {
            // 只在“没有刚发生过入座唤醒”且距上次强制熄屏超过 5 分钟时才执行，
            // 否则会与入座唤醒形成 熄屏→唤醒→熄屏 的循环。
            if Date().timeIntervalSince(lastPresenceWakeAt) > 120,
               Date().timeIntervalSince(lastForcedDisplaySleepAt) > 300 {
                lastForcedDisplaySleepAt = Date()
                log(requestSystemDisplaySleep()
                    ? "轮询检测到 Mac 已锁定，已请求系统立即熄屏"
                    : "轮询检测到 Mac 已锁定，但系统熄屏请求失败")
            } else {
                log("检测到 Mac 已锁定（刚唤醒过，跳过强制熄屏）")
            }
        } else {
            log("检测到 Mac 已解锁")
        }
        wasConsoleSessionLocked = consoleSessionLocked
    }
    let detectedDisplayID = studioDisplayID()
    if detectedDisplayID != displayID {
        displayID = detectedDisplayID
        brightnessOffset = nil
        lastDisplayBrightness = nil
        lastBuiltinDisplayBrightness = nil
        lastStudioDisplayBrightnessForLock = nil
        anchorStatusRevision = nil
        if let displayID {
            wasAsleep = CGDisplayIsAsleep(displayID) != 0
            log("检测到 Studio Display 已连接：ID=\(displayID)，分辨率=\(CGDisplayPixelsWide(displayID))x\(CGDisplayPixelsHigh(displayID))")
            // 待机期间因未连接而关闭的灯，重新连接后恢复（屏幕已熄时交给熄屏同步处理）。
            if helperTurnedLampOff, !wasAsleep, statusIndicator.isPowerSyncEnabled, lamp.setPower(on: true) {
                helperTurnedLampOff = false
                log("Studio Display 已重新连接，已恢复 iScreenBar 电源")
            }
            if !wasAsleep { statusIndicator.restorePresenceAfterScreenWake() }
        } else {
            wasAsleep = false
            log("Studio Display 已断开，程序继续驻留等待重连")
        }
        statusIndicator.handleStudioDisplayConnection(connected: displayID != nil)
    }
    statusIndicator.setStudioDisplayAvailable(displayID != nil)
    statusIndicator.syncPresenceSettingsIfNeeded()
    let isAsleep = displayID.map { CGDisplayIsAsleep($0) != 0 } ?? false
    let brightnessFollowEnabled = statusIndicator.isBrightnessFollowEnabled
    let displayBrightnessLockEnabled = statusIndicator.isDisplayBrightnessLockEnabled
    let powerSyncEnabled = statusIndicator.isPowerSyncEnabled
    // 熄屏时是否保留入座检测、允许“入座→唤醒屏幕”（默认开启：有人入座通常就是要用显示器）。
    let presenceWakesDisplay = comboSetting("presenceWakesDisplay", 1) == 1
    let ambientLinkEnabled = statusIndicator.isAmbientLinkEnabled
    let comboEnabled = statusIndicator.isComboPolicyEnabled
    let ambientCloseThreshold = statusIndicator.ambientCloseThreshold
    let rawAmbientSource = (value: studioAmbientSensor.rawIlluminance(), name: "Studio Display 光线传感器")
    if ambientProxySourceName != rawAmbientSource.name {
        ambientProxySamples.removeAll()
        ambientProxySourceName = rawAmbientSource.name
        lastLoggedAmbientProxy = nil
        log("环境响应数据源切换为 \(rawAmbientSource.name)")
    }
    let sampleTime = Date()
    if let value = rawAmbientSource.value {
        ambientProxySamples.append((sampleTime, value))
    }
    let sampleCutoff = sampleTime.addingTimeInterval(-10)
    ambientProxySamples.removeAll { $0.0 < sampleCutoff }
    let sortedAmbientValues = ambientProxySamples.map { $0.1 }.sorted()
    // 传感器位于屏幕正面，读数低于桌面水平照度；按实测比例（542/317≈1.71）折算为桌面估算照度。
    let ambientScale = Double(comboSetting("ambientScalePercent", 208)) / 100.0
    let displayAmbientProxy = sortedAmbientValues.isEmpty
        ? nil
        : Int((Double(sortedAmbientValues[sortedAmbientValues.count / 2]) * ambientScale).rounded())
    if let displayAmbientProxy, lastLoggedAmbientProxy != displayAmbientProxy {
        log("环境响应分数：\(displayAmbientProxy)（\(rawAmbientSource.name)，10 秒中位数）")
        lastLoggedAmbientProxy = displayAmbientProxy
    }
    statusIndicator.updateDisplayAmbientProxy(displayAmbientProxy, sourceName: rawAmbientSource.name)

    // 待机（未连接 Studio Display）等同于熄屏：显示器拔线或断电时也要关闭 iScreenBar，
    // 否则灯会一直亮着；重新连接时在连接事件里恢复。
    if powerSyncEnabled, displayID == nil {
        statusIndicator.suspendPresenceForScreenSleep()
        if lamp.isPowerOn == true, lamp.setPower(on: false) {
            helperTurnedLampOff = true
            log("未连接 Studio Display，熄屏同步已关闭 iScreenBar")
        }
    }

    // 固件自行点亮/熄灭：前者=检测到入座，后者=判定离座（此时 App 不应“补开”）。
    // lastLampPowerCommandAt 在 setPower 里统一打标，覆盖熄屏同步、组合策略等全部写入路径。
    if let power = lamp.isPowerOn {
        let externalChange = Date().timeIntervalSince(lastLampPowerCommandAt) > 3
        if lastKnownLampPower == false, power == true, externalChange {
            lastPresenceEventAt = Date()
            log("灯体自行点亮：视为检测到入座")
        } else if lastKnownLampPower == true, power == false, externalChange {
            lastFirmwareOffAt = Date()
            log("灯体自行熄灭：判定为离座（App 在 5 分钟内不会自动补开）")
        }
        lastKnownLampPower = power
    }

    // 动态管理灯体入座检测：只在“需要它自动点灯”时开启，避免与环境充足关灯互相拉扯。
    // 入座检测：改为固件常开（优先级最高）。是否有人、何时离座全部交给灯体毫米波传感器，
    // 不再用 Mac 键鼠空闲判离座（看视频不动键鼠会被误判为离座）。
    if Date().timeIntervalSince(lastPresenceToggleAt) >= 30 {
        if statusIndicator.updateFirmwarePresence(requested: true) {
            lastPresenceToggleAt = Date()
        }
    }

    // 熄屏同步是最高优先级：屏幕熄灭期间，环境光、入座检测或灯体自身逻辑
    // 都不得重新点亮灯。持续检测可覆盖灯体在熄屏后中途自行亮起的情况。
    if powerSyncEnabled, isAsleep {
        if presenceWakesDisplay, lamp.isPresenceDetectionEnabled == true {
            // 保留入座检测：固件因“有人坐下”把灯点亮时，视为人回来了，直接唤醒屏幕并保留灯光。
            // 但要求 Mac 近期有操作，否则整夜无人时也会被固件误检点亮并唤醒屏幕。
            if lamp.isPowerOn == true {
                let rawIdle = systemIdleSeconds()
                // 系统偶发返回 NaN/负值，按“刚有活动”处理，与组合策略口径一致。
                let macIdle = rawIdle.isFinite && rawIdle >= 0 ? rawIdle : 0
                // 真实键鼠活动立即清掉误检冷却：有人正在用电脑。
                if macIdle < 5 {
                    presenceWakeNoResponse = 0
                    presenceWakePausedUntil = .distantPast
                }
                if macIdle >= 7200 {
                    if lamp.setPower(on: false) {
                        helperTurnedLampOff = true
                        log("忽略入座信号：Mac 已空闲 \(Int(macIdle / 60)) 分钟，判为固件误检，已关灯")
                    }
                } else if Date().timeIntervalSince(lastPresenceWakeAt) > 30,
                          Date() >= presenceWakePausedUntil {
                    // 只在“最近 2 小时内用过电脑”且不在误检冷却期时接受入座唤醒，
                    // 避免整夜无人时被固件误检叫醒屏幕、或误检期间反复亮屏。
                    lastPresenceWakeAt = Date()
                    helperTurnedLampOff = false
                    let woke = requestSystemDisplayWake()
                    log(woke ? "检测到入座：灯体已点亮，已唤醒显示器" : "检测到入座：但唤醒显示器请求失败")
                }
            }
        } else {
            statusIndicator.suspendPresenceForScreenSleep()
            if lamp.isPowerOn == true {
                let turnedOff = lamp.setPower(on: false)
                helperTurnedLampOff = helperTurnedLampOff || turnedOff
                if turnedOff {
                    log("熄屏同步优先级已压制灯体自动重新点亮")
                }
                statusIndicator.update(isAsleep: true, healthy: turnedOff)
            }
        }
    }

    if wasAmbientCloseThreshold != nil, ambientCloseThreshold == nil, ambientTurnedLampOff {
        if !isAsleep { _ = lamp.setPower(on: true) }
        setAmbientLampLock(false)
        statusIndicator.restorePresenceAfterAmbientLock()
        ambientCloseCandidateSince = nil
        log("明亮关灯规则已关闭，已解除关灯锁定并恢复入座检测")
    }
    wasAmbientCloseThreshold = ambientCloseThreshold

    if ambientLinkEnabled != wasAmbientLinkEnabled {
        ambientCloseCandidateSince = nil
        ambientOpenCandidateSince = nil
        if !ambientLinkEnabled, ambientTurnedLampOff {
            if !isAsleep { _ = lamp.setPower(on: true) }
            setAmbientLampLock(false)
            statusIndicator.restorePresenceAfterAmbientLock()
            log("环境联动已关闭，已释放环境关灯状态")
        }
        wasAmbientLinkEnabled = ambientLinkEnabled
    }

    if ambientLinkEnabled, !comboEnabled, !isAsleep, let displayAmbientProxy {
        if ambientTurnedLampOff {
            statusIndicator.maintainPresenceSuspendedForAmbientLock()
            ambientCloseCandidateSince = nil
            let reachedOpenPoint = statusIndicator.ambientOpenThreshold.map { displayAmbientProxy <= $0 } ?? false
            // 保留用户标定的“昏暗开灯”快速触发；普通变暗则用窄回差和延时恢复。
            // 计时开始后允许短暂波动，只有重新明显高于关灯点才取消，
            // 避免 Studio Display 传感器瞬时跳值让开灯计时永远归零。
            let gradualMargin = statusIndicator.ambientCloseThreshold.map {
                max(8, min(20, Int((Double($0) * 0.04).rounded())))
            }
            let gradualOpenPoint = statusIndicator.ambientCloseThreshold.flatMap { close in
                gradualMargin.map { close - $0 }
            }
            let gradualCancelPoint = statusIndicator.ambientCloseThreshold.flatMap { close in
                gradualMargin.map { close + $0 }
            }
            let reachedGradualOpenPoint = gradualOpenPoint.map { displayAmbientProxy <= $0 } ?? false
            let mayContinueGradualOpening = ambientOpenCandidateSince != nil &&
                (gradualCancelPoint.map { displayAmbientProxy < $0 } ?? false)
            let shouldBeginOpening = reachedOpenPoint || reachedGradualOpenPoint || mayContinueGradualOpening
            if reachedOpenPoint {
                if ambientOpenCandidateSince == nil { ambientOpenCandidateSince = Date() }
                if let since = ambientOpenCandidateSince, Date().timeIntervalSince(since) >= 30 {
                    if lamp.setPower(on: true) {
                        setAmbientLampLock(false)
                        ambientOpenCandidateSince = nil
                        statusIndicator.restorePresenceAfterAmbientLock()
                        log("环境已低于独立开灯点，已释放环境关灯锁定")
                    }
                } else if lamp.isPowerOn == true {
                    _ = lamp.setPower(on: false)
                }
            } else if shouldBeginOpening {
                if ambientOpenCandidateSince == nil {
                    ambientOpenCandidateSince = Date()
                    if let gradualOpenPoint {
                        log("环境已持续低于平衡回开点 \(gradualOpenPoint)，开始延时确认")
                    }
                }
                if let since = ambientOpenCandidateSince,
                   Date().timeIntervalSince(since) >= 45,
                   statusIndicator.ambientCloseThreshold.map({ displayAmbientProxy < $0 }) == true {
                    if lamp.setPower(on: true) {
                        setAmbientLampLock(false)
                        ambientOpenCandidateSince = nil
                        statusIndicator.restorePresenceAfterAmbientLock()
                        log("环境持续变暗，已平衡恢复 iScreenBar")
                    }
                } else if lamp.isPowerOn == true {
                    _ = lamp.setPower(on: false)
                }
            } else {
                ambientOpenCandidateSince = nil
                if lamp.isPowerOn == true, lamp.setPower(on: false) {
                    log("环境关灯优先级已压制灯体自动重新点亮")
                }
            }
        } else if lamp.isPowerOn == true {
            ambientOpenCandidateSince = nil
            if let closeThreshold = statusIndicator.ambientCloseThreshold,
               displayAmbientProxy >= closeThreshold {
                if ambientCloseCandidateSince == nil { ambientCloseCandidateSince = Date() }
                if let since = ambientCloseCandidateSince, Date().timeIntervalSince(since) >= 30 {
                    if statusIndicator.suspendPresenceForAmbientLock(), lamp.setPower(on: false) {
                        setAmbientLampLock(true)
                        ambientCloseCandidateSince = nil
                        log("环境已高于独立关灯点，已关闭 iScreenBar")
                    } else {
                        statusIndicator.restorePresenceAfterAmbientLock()
                    }
                }
            } else {
                ambientCloseCandidateSince = nil
            }
        } else {
            ambientCloseCandidateSince = nil
            if let closeThreshold = statusIndicator.ambientCloseThreshold,
               displayAmbientProxy >= closeThreshold {
                setAmbientLampLock(true)
                ambientOpenCandidateSince = nil
                _ = statusIndicator.suspendPresenceForAmbientLock()
                log("检测到灯已关闭且环境仍高于关灯点，已恢复关灯锁定")
            } else if let openThreshold = statusIndicator.ambientOpenThreshold,
               displayAmbientProxy <= openThreshold {
                if ambientOpenCandidateSince == nil { ambientOpenCandidateSince = Date() }
                if let since = ambientOpenCandidateSince, Date().timeIntervalSince(since) >= 30 {
                    if lamp.setPower(on: true) {
                        setAmbientLampLock(false)
                        ambientOpenCandidateSince = nil
                        log("环境已低于独立开灯点，已开启 iScreenBar")
                    }
                }
            } else {
                ambientOpenCandidateSince = nil
            }
        }
    } else {
        ambientCloseCandidateSince = nil
        ambientOpenCandidateSince = nil
    }

    if powerSyncEnabled != wasPowerSyncEnabled {
        if powerSyncEnabled, isAsleep {
            statusIndicator.suspendPresenceForScreenSleep()
            helperTurnedLampOff = lamp.setPower(on: false)
        } else if !powerSyncEnabled {
            if helperTurnedLampOff { _ = lamp.setPower(on: true) }
            helperTurnedLampOff = false
            statusIndicator.restorePresenceAfterScreenWake()
        }
        wasPowerSyncEnabled = powerSyncEnabled
        statusIndicator.update(isAsleep: isAsleep, healthy: true)
    }

    if brightnessFollowEnabled != wasBrightnessFollowEnabled {
        brightnessOffset = nil
        lastDisplayBrightness = nil
        if brightnessFollowEnabled {
            anchorStatusRevision = lamp.statusRevision
            lamp.requestStatus()
        } else {
            anchorStatusRevision = nil
        }
        wasBrightnessFollowEnabled = brightnessFollowEnabled
        statusIndicator.update(isAsleep: isAsleep, healthy: true)
    }

    if displayBrightnessLockEnabled != wasDisplayBrightnessLockEnabled {
        displayBrightnessOffset = nil
        lastBuiltinDisplayBrightness = nil
        lastStudioDisplayBrightnessForLock = nil
        displayBrightnessWriteSuppressedUntil = Date.distantPast
        wasDisplayBrightnessLockEnabled = displayBrightnessLockEnabled
    }

    if isAsleep != wasAsleep {
        if isAsleep {
            log("检测到 Studio Display 熄屏")
            // 评估上一次入座唤醒是否得到键鼠响应：最后一次键鼠时间不晚于唤醒发起时间，
            // 说明亮屏期间没人碰过电脑（典型固件误检）；连续 2 次即暂停入座唤醒 15 分钟。
            let rawIdleNow = systemIdleSeconds()
            if rawIdleNow.isFinite, rawIdleNow >= 0,
               Date().addingTimeInterval(-rawIdleNow) <= lastPresenceWakeAt {
                presenceWakeNoResponse += 1
                if presenceWakeNoResponse >= 2 {
                    presenceWakeNoResponse = 0
                    presenceWakePausedUntil = Date().addingTimeInterval(900)
                    log("入座唤醒连续 2 次无人响应，15 分钟内暂停入座唤醒")
                }
            } else {
                presenceWakeNoResponse = 0
            }
            if powerSyncEnabled {
                if presenceWakesDisplay, lamp.isPresenceDetectionEnabled == true {
                    log("熄屏同步：保留入座检测，以便入座时唤醒显示器")
                    helperTurnedLampOff = lamp.setPower(on: false)
                    statusIndicator.update(isAsleep: true, healthy: helperTurnedLampOff)
                } else {
                    statusIndicator.suspendPresenceForScreenSleep()
                    helperTurnedLampOff = lamp.setPower(on: false)
                    statusIndicator.update(isAsleep: true, healthy: helperTurnedLampOff)
                }
            } else {
                statusIndicator.update(isAsleep: true, healthy: true)
            }
        } else {
            log("检测到 Studio Display 唤醒")
            if helperTurnedLampOff, !ambientTurnedLampOff {
                let restored = lamp.setPower(on: true)
                statusIndicator.update(isAsleep: false, healthy: restored)
                helperTurnedLampOff = false
            } else {
                helperTurnedLampOff = false
                statusIndicator.update(isAsleep: false, healthy: true)
            }
            statusIndicator.restorePresenceAfterScreenWake()
        }
        wasAsleep = isAsleep
    }

    // 待机（未连接 Studio Display）时不写灯体设置。
    if !comboEnabled, displayID != nil {
        statusIndicator.applyScheduledTemperatureIfNeeded(isAsleep: isAsleep, force: false)
    }

    // 组合策略在熄屏/唤醒切换处理完之后接管，避免与熄屏同步抢写。
    runComboPolicy(isAsleep: isAsleep, displayAmbientProxy: displayAmbientProxy)

    if displayBrightnessLockEnabled,
       !isAsleep,
       !isConsoleSessionLocked(),
       let studioID = displayID,
       let builtinID = activeBuiltinDisplayID(),
       let studioBrightness = displayBrightnessReader.percent(for: studioID),
       let builtinBrightness = displayBrightnessReader.percent(for: builtinID) {
        if displayBrightnessOffset == nil || lastBuiltinDisplayBrightness == nil || lastStudioDisplayBrightnessForLock == nil {
            let isNewLock = displayBrightnessOffset == nil
            if isNewLock {
                displayBrightnessOffset = builtinBrightness - studioBrightness
            }
            lastBuiltinDisplayBrightness = builtinBrightness
            lastStudioDisplayBrightnessForLock = studioBrightness
            if isNewLock {
                log("已锁定双屏亮度差：MacBook \(builtinBrightness)% / Studio Display \(studioBrightness)%")
            }
        } else if Date() >= displayBrightnessWriteSuppressedUntil,
                  let offset = displayBrightnessOffset,
                  let previousBuiltin = lastBuiltinDisplayBrightness,
                  let previousStudio = lastStudioDisplayBrightnessForLock {
            let builtinDelta = builtinBrightness - previousBuiltin
            let studioDelta = studioBrightness - previousStudio
            if builtinDelta != 0 || studioDelta != 0 {
                if abs(builtinDelta) > abs(studioDelta) {
                    let targetStudio = max(0, min(100, builtinBrightness - offset))
                    if targetStudio == studioBrightness || displayBrightnessReader.setPercent(targetStudio, for: studioID) {
                        lastBuiltinDisplayBrightness = builtinBrightness
                        lastStudioDisplayBrightnessForLock = targetStudio
                        displayBrightnessWriteSuppressedUntil = Date().addingTimeInterval(0.6)
                    }
                } else {
                    let targetBuiltin = max(0, min(100, studioBrightness + offset))
                    if targetBuiltin == builtinBrightness || displayBrightnessReader.setPercent(targetBuiltin, for: builtinID) {
                        lastBuiltinDisplayBrightness = targetBuiltin
                        lastStudioDisplayBrightnessForLock = studioBrightness
                        displayBrightnessWriteSuppressedUntil = Date().addingTimeInterval(0.6)
                    }
                }
            }
        }
    } else {
        lastBuiltinDisplayBrightness = nil
        lastStudioDisplayBrightnessForLock = nil
    }

    if brightnessFollowEnabled, !comboEnabled, !isAsleep, let displayID,
       let displayBrightness = displayBrightnessReader.percent(for: displayID) {
        if let anchorRevision = anchorStatusRevision,
           lamp.statusRevision > anchorRevision,
           let lampBrightness = lamp.currentBrightness {
            if lamp.isAutoLightEnabled == true {
                log("检测到灯具自动感光仍在运行；亮度跟随将在关闭自动感光后生效")
                brightnessOffset = nil
                lastDisplayBrightness = displayBrightness
            } else {
                brightnessOffset = lampBrightness - displayBrightness
                lastDisplayBrightness = displayBrightness
                log("已锁定亮度差：iScreenBar \(lampBrightness)% / Studio Display \(displayBrightness)%")
            }
            anchorStatusRevision = nil
        } else if let brightnessOffset, displayBrightness != lastDisplayBrightness {
            let target = max(1, min(100, displayBrightness + brightnessOffset))
            if lamp.setBrightness(target) {
                lastDisplayBrightness = displayBrightness
            }
        }
    }

    if Date().timeIntervalSince(lastStatusRequest) >= 2 {
        let connected = lamp.checkConnection()
        if connected != wasLampConnected {
            if connected {
                log("检测到 iScreenBar 已恢复连接，正在恢复同步状态")
                if powerSyncEnabled {
                    if isAsleep {
                        helperTurnedLampOff = lamp.setPower(on: false)
                    } else if !ambientTurnedLampOff {
                        _ = lamp.setPower(on: true)
                    }
                }
                if brightnessFollowEnabled {
                    brightnessOffset = nil
                    lastDisplayBrightness = nil
                    anchorStatusRevision = lamp.statusRevision
                    lamp.requestStatus()
                }
            } else {
                log("检测到 iScreenBar 已断开")
                brightnessOffset = nil
                anchorStatusRevision = nil
            }
            wasLampConnected = connected
        }
        statusIndicator.update(isAsleep: isAsleep, healthy: connected && displayID != nil)
        lastStatusRequest = Date()
    }
}

let pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
    pollDisplayAndLamp()
}
pollingTimer.tolerance = 0.05
pollDisplayAndLamp()
NSApplication.shared.run()
