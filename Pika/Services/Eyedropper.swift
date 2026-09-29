import Defaults
import SwiftUI
import ScreenCaptureKit

class Eyedropper: ObservableObject {
    enum Types: String, CustomStringConvertible {
        case foreground
        case background

        var description: String {
            switch self {
            case .foreground: return PikaText.textColorForeground
            case .background: return PikaText.textColorBackground
            }
        }

        var copySelector: Selector {
            switch self {
            case .foreground: return #selector(AppDelegate.triggerCopyForeground)
            case .background: return #selector(AppDelegate.triggerCopyBackground)
            }
        }

        var pickSelector: Selector {
            switch self {
            case .foreground: return #selector(AppDelegate.triggerPickForeground)
            case .background: return #selector(AppDelegate.triggerPickBackground)
            }
        }

        var systemPickerSelector: Selector {
            switch self {
            case .foreground: return #selector(AppDelegate.triggerSystemPickerForeground)
            case .background: return #selector(AppDelegate.triggerSystemPickerBackground)
            }
        }

        var pickNotification: Notification.Name {
            switch self {
            case .foreground: return .triggerPickForeground
            case .background: return .triggerPickBackground
            }
        }

        var copyNotification: Notification.Name {
            switch self {
            case .foreground: return .triggerCopyForeground
            case .background: return .triggerCopyBackground
            }
        }

        var systemPickerNotification: Notification.Name {
            switch self {
            case .foreground: return .triggerSystemPickerForeground
            case .background: return .triggerSystemPickerBackground
            }
        }
    }

    let type: Types
    var forceShow = false
    var pendingChainCommit = false

    let colorNames: [ColorName] = loadColors()!
    var closestVector: ClosestVector!

    @objc @Published public var color: NSColor

    private static var isSampling = false
    private var overlayWindow = ColorPickOverlayWindow()

    init(type: Types, color: NSColor) {
        self.type = type
        self.color = color.usingColorSpace(.sRGB) ?? color

        // Load colors
        closestVector = ClosestVector(colorNames.map { $0.color.toRGB8BitArray() })
    }

    func getClosestColor() -> String {
        colorNames[closestVector.compare(color)].name
    }

    func set(_ selectedColor: NSColor) {
        color = selectedColor.usingColorSpace(.sRGB) ?? selectedColor
    }

    @objc func colorDidChange(sender: AnyObject) {
        if let picker = sender as? NSColorPanel {
            guard let srgbColor = picker.color.usingColorSpace(.sRGB) else { return }
            color = srgbColor
            NotificationCenter.default.post(name: .systemColorChanged, object: nil)
        }
    }

    func picker() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.title = "\(type.rawValue.capitalized)"
        panel.titleVisibility = .visible
        panel.setTarget(self)
        panel.color = color
        panel.mode = .RGB
        panel.colorSpace = Defaults[.colorSpace]
        panel.orderFrontRegardless()
        panel.setAction(#selector(colorDidChange))
        panel.isContinuous = true
    }
}

// MARK: - Screen sampling

extension Eyedropper {
    func start(chainContrasting: Bool = false) {
        guard !Self.isSampling else { return }
        Self.isSampling = true
        if Defaults[.hidePikaWhilePicking] {
            if NSApp.mainWindow?.isVisible == true {
                forceShow = true
            }
            NSApp.sendAction(#selector(AppDelegate.hidePika), to: nil, from: nil)
        }

        // Drop the window's shadow while the sampler is up so it can't tint pixels
        // picked near the window edge. Restored on every terminal pick path below;
        // a chained background pick simply re-suppresses when it starts. The call is
        // a no-op unless the shadow preference is `.hiddenWhilePicking`.
        AppDelegate.shared?.windowCoordinator.setPickingShadowSuppressed(true)

        DispatchQueue.main.asyncAfter(deadline: .now()) {
            if Defaults[.appMode].usesPopover {
                NSApp.activate(ignoringOtherApps: true)
            }
            let completion: (NSColor?) -> Void = { selectedColor in
                Self.isSampling = false
                if let selectedColor = selectedColor {
                    self.commitPick(selectedColor, chainContrasting: chainContrasting)
                } else if self.pendingChainCommit {
                    self.commitCancelledChain()
                } else {
                    // Fresh pick cancelled: restore the shadow the sampler suppressed.
                    AppDelegate.shared?.windowCoordinator.setPickingShadowSuppressed(false)
                }

                if self.forceShow {
                    self.forceShow = false
                    if !Defaults[.appMode].usesPopover {
                        NSApp.sendAction(#selector(AppDelegate.showPika), to: nil, from: nil)
                    }
                }

                let panel = NSColorPanel.shared
                if panel.isVisible {
                    self.picker()
                }
            }
            if Defaults[.useZoomedCursor] {
                NSColorSampler().show(selectionHandler: completion)
            } else {
                UnzoomedColorSampler.show(completion)
            }
        }
    }

    private func commitPick(_ selectedColor: NSColor, chainContrasting: Bool) {
        let normalizedColor = selectedColor.usingColorSpace(.sRGB) ?? selectedColor

        if Defaults[.showColorOverlay] {
            let colorText = normalizedColor.toFormat(
                format: Defaults[.colorFormat], style: Defaults[.copyFormat]
            )
            let cursorPosition = NSEvent.mouseLocation
            overlayWindow.show(
                colorText: colorText,
                pickedColor: normalizedColor,
                nearCursor: cursorPosition,
                duration: Defaults[.colorOverlayDuration]
            )
        }

        set(normalizedColor)

        if chainContrasting,
           type == .foreground,
           let appDelegate = AppDelegate.shared
        {
            startChainedBackgroundPick(using: appDelegate)
        } else {
            pendingChainCommit = false
            NotificationCenter.default.post(name: .colorPicked, object: nil)
            finishPick(copySelector: type.copySelector)
        }
    }

    private func startChainedBackgroundPick(using appDelegate: AppDelegate) {
        // Defer committing the foreground pick — we'll record once the
        // background is also picked (or the chained pick is cancelled).
        let background = appDelegate.eyedroppers.background
        background.pendingChainCommit = true
        // Don't bounce Pika back into view between picks: forward the
        // forceShow intent to the background pick instead.
        if forceShow {
            forceShow = false
            background.forceShow = true
        }
        let delay: Double = Defaults[.showColorOverlay] ? 0.4 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            background.start()
        }
    }

    private func commitCancelledChain() {
        // Chained background pick was cancelled; commit the foreground change
        // that was deferred so it isn't lost. self.type is .background here, so
        // route copy-on-pick to the foreground selector explicitly.
        pendingChainCommit = false
        NotificationCenter.default.post(name: .colorPicked, object: nil)
        finishPick(copySelector: Eyedropper.Types.foreground.copySelector)
    }

    private func finishPick(copySelector: Selector) {
        if Defaults[.copyColorOnPick] {
            NSApp.sendAction(copySelector, to: nil, from: nil)
        } else if Defaults[.appMode].usesPopover {
            NSApp.sendAction(#selector(AppDelegate.showPopover), to: nil, from: nil)
        } else {
            NSApp.sendAction(#selector(AppDelegate.showPika), to: nil, from: nil)
        }

        // Terminal path for a committed pick (or a cancelled chain): bring the
        // window's shadow back. No-op unless the shadow preference suppressed it.
        AppDelegate.shared?.windowCoordinator.setPickingShadowSuppressed(false)
    }
}

// The system sampler always magnifies. Present native-resolution snapshots instead
// so the crosshair selects exactly the pixel shown, even if the source animates.
@MainActor
final class UnzoomedColorSampler {
    private static var active: UnzoomedColorSampler?
    private var windows: [NSWindow] = []
    private var cursorPushed = false
    private let completion: (NSColor?) -> Void

    private init(completion: @escaping (NSColor?) -> Void) {
        self.completion = completion
    }

    static func show(_ completion: @escaping (NSColor?) -> Void) {
        guard active == nil else { return }
        let sampler = UnzoomedColorSampler(completion: completion)
        active = sampler
        Task { await sampler.present() }
    }

    private func present() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // Capture every screen before showing any picker window.
            var snapshots: [(NSScreen, CGImage)] = []
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                else { continue }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
                configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
                configuration.showsCursor = false
                configuration.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                snapshots.append((screen, image))
            }
            guard !snapshots.isEmpty else {
                throw NSError(domain: "Pika.ScreenSampler", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No screen is available for color sampling.",
                ])
            }
            NSApp.activate(ignoringOtherApps: true)
            for (screen, image) in snapshots {
                let window = SamplingWindow(contentRect: screen.frame, styleMask: .borderless,
                                            backing: .buffered, defer: false)
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.hasShadow = false
                window.acceptsMouseMovedEvents = true
                window.isReleasedWhenClosed = false
                let view = SamplingView(image: image, size: screen.frame.size) { [weak self] color in
                    self?.finish(color)
                }
                window.contentView = view
                windows.append(window)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                window.invalidateCursorRects(for: view)
            }
            NSCursor.crosshair.push()
            cursorPushed = true
        } catch {
            finish(nil)
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("picker.capture.error.title", comment: "Screen capture failed")
            alert.informativeText = NSLocalizedString("picker.capture.error.help", comment: "Screen capture permission help")
                + "\n\n" + error.localizedDescription
            alert.runModal()
        }
    }

    private func finish(_ color: NSColor?) {
        guard Self.active === self else { return }
        for window in windows { window.close() }
        windows.removeAll()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        Self.active = nil
        completion(color)
    }

    // NSView coordinates start at bottom left; bitmap rows start at top left.
    nonisolated static func color(at point: NSPoint, size: NSSize, bitmap: NSBitmapImageRep) -> NSColor? {
        guard size.width > 0, size.height > 0,
              point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else { return nil }
        let x = min(bitmap.pixelsWide - 1, Int(point.x / size.width * CGFloat(bitmap.pixelsWide)))
        let y = min(bitmap.pixelsHigh - 1, Int((size.height - point.y) / size.height * CGFloat(bitmap.pixelsHigh)))
        return bitmap.colorAt(x: x, y: y)
    }
}

private final class SamplingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SamplingView: NSView {
    private var cursorTrackingArea: NSTrackingArea?
    private let snapshot: NSImage
    private let bitmap: NSBitmapImageRep
    private let completion: (NSColor?) -> Void

    init(image: CGImage, size: NSSize, completion: @escaping (NSColor?) -> Void) {
        snapshot = NSImage(cgImage: image, size: size)
        bitmap = NSBitmapImageRep(cgImage: image)
        self.completion = completion
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        snapshot.draw(in: bounds)
    }

    override func updateTrackingAreas() {
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        completion(UnzoomedColorSampler.color(at: point, size: bounds.size, bitmap: bitmap))
    }

    override func rightMouseDown(with event: NSEvent) { completion(nil) }
    override func cancelOperation(_ sender: Any?) { completion(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) }
    }
}
