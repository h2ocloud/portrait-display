import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import ScreenCaptureKit

// MARK: - Virtual Display Creation

var virtualDisplay: CGVirtualDisplay?

func createVirtualDisplay(width: UInt32, height: UInt32) -> CGVirtualDisplay? {
    let ppi: Double = 110.0
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.maxPixelsWide = width
    descriptor.maxPixelsHigh = height
    descriptor.sizeInMillimeters = CGSize(
        width: Double(width) / ppi * 25.4,
        height: Double(height) / ppi * 25.4
    )
    descriptor.name = "Portrait Virtual"
    descriptor.vendorID = 0xEEEE
    descriptor.productID = 0x0001
    descriptor.serialNum = 0x0001
    descriptor.queue = DispatchQueue.main

    guard let display = CGVirtualDisplay(descriptor: descriptor) else {
        print("ERROR: Failed to create virtual display")
        return nil
    }

    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = false
    settings.modes = [
        CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60.0)!,
        CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 50.0)!,
    ]

    guard display.apply(settings) else {
        print("ERROR: Failed to apply settings")
        return nil
    }
    return display
}

// MARK: - Display Enumeration

struct DisplayInfo {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
    let rotation: Double
    let isMain: Bool
    let origin: CGPoint
}

func getDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { id in
        let bounds = CGDisplayBounds(id)
        return DisplayInfo(
            id: id,
            width: CGDisplayPixelsWide(id),
            height: CGDisplayPixelsHigh(id),
            rotation: CGDisplayRotation(id),
            isMain: CGDisplayIsMain(id) != 0,
            origin: bounds.origin
        )
    }
}

func printDisplays(_ displays: [DisplayInfo]) {
    print("\n=== Active Displays ===")
    for d in displays {
        let mainStr = d.isMain ? " [MAIN]" : ""
        print("  ID:\(d.id)  \(d.width)x\(d.height)  rot:\(Int(d.rotation))°  origin:(\(Int(d.origin.x)),\(Int(d.origin.y)))\(mainStr)")
    }
    print()
}

// MARK: - ScreenCaptureKit Stream Output

class StreamOutput: NSObject, SCStreamOutput {
    weak var imageLayer: CALayer?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Get IOSurface directly — zero-copy GPU path, no CPU image conversion
        let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()

        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.imageLayer else { return }
            // Disable implicit animations to eliminate ghosting
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = ioSurface
            CATransaction.commit()
        }
    }
}

// MARK: - Stream Controller

class StreamController: NSObject {
    let sourceDisplayID: CGDirectDisplayID
    let targetScreen: NSScreen
    let targetWidth: Int
    let targetHeight: Int
    var window: NSWindow?
    var imageLayer: CALayer?
    var scStream: SCStream?
    var streamOutput: StreamOutput?
    private var isRestarting = false

    init(sourceDisplayID: CGDirectDisplayID, targetScreen: NSScreen) {
        self.sourceDisplayID = sourceDisplayID
        self.targetScreen = targetScreen
        self.targetWidth = Int(targetScreen.frame.width)
        self.targetHeight = Int(targetScreen.frame.height)
        super.init()
    }

    func start() {
        // Create borderless fullscreen window on target screen
        let frame = targetScreen.frame
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .statusBar
        win.isOpaque = true
        win.backgroundColor = .black
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.ignoresMouseEvents = true

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = CALayer()
        win.contentView = view

        let layer = CALayer()
        // Layer is portrait-sized (1080x1920) but rotated 90° CW to fill landscape screen
        // Center the layer in the view, then rotate
        let screenW = frame.size.width
        let screenH = frame.size.height
        layer.bounds = CGRect(x: 0, y: 0, width: screenH, height: screenW)
        layer.position = CGPoint(x: screenW / 2, y: screenH / 2)
        layer.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
        layer.contentsGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
        // Disable all implicit animations to prevent ghosting
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(layer)
        self.imageLayer = layer

        win.setFrame(frame, display: true)
        win.orderFrontRegardless()
        self.window = win

        // Start ScreenCaptureKit capture
        startSCKCapture()

        // Listen for screen wake/unlock to restart stream
        registerWakeObservers()

        // Monitor for display disconnect — if USB adapter is unplugged,
        // close the fullscreen window immediately to avoid covering the MacBook screen
        registerDisplayChangeCallback()
    }

    func registerDisplayChangeCallback() {
        CGDisplayRegisterReconfigurationCallback({ displayID, flags, userInfo in
            // Only react when reconfiguration is complete
            guard flags.contains(.beginConfigurationFlag) == false else { return }
            let controller = Unmanaged<StreamController>.fromOpaque(userInfo!).takeUnretainedValue()
            controller.checkTargetDisplayAlive()
        }, Unmanaged.passUnretained(self).toOpaque())
        print("✓ Registered display disconnect watchdog")
    }

    func checkTargetDisplayAlive() {
        // Check if any screen still matches our target dimensions
        let targetAlive = NSScreen.screens.contains(where: { screen in
            Int(screen.frame.width) == targetWidth && Int(screen.frame.height) == targetHeight
        })

        if !targetAlive {
            print("⚠ Target display (\(targetWidth)x\(targetHeight)) disconnected — shutting down to avoid covering MacBook screen")
            DispatchQueue.main.async {
                self.stop()
                NSApp.terminate(nil)
            }
        }
    }

    func registerWakeObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let nc = DistributedNotificationCenter.default()

        // Screen wake from sleep
        ws.addObserver(self, selector: #selector(handleWake(_:)),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Session becomes active (unlock / screensaver dismiss)
        ws.addObserver(self, selector: #selector(handleWake(_:)),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        // Screen unlock (covers screensaver + lock screen)
        nc.addObserver(self, selector: #selector(handleWake(_:)),
                       name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        print("✓ Registered wake/unlock observers for stream recovery")
    }

    @objc func handleWake(_ notification: Notification) {
        guard !isRestarting else { return }
        isRestarting = true
        let reason = notification.name.rawValue.components(separatedBy: ".").last ?? "unknown"
        print("⟳ Wake/unlock detected (\(reason)), restarting stream in 2s...")

        // Delay to let displays stabilize after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.restartStream()
        }
    }


    func restartStream() {
        // Stop existing stream
        if let stream = scStream {
            stream.stopCapture { [weak self] _ in
                DispatchQueue.main.async {
                    self?.scStream = nil
                    self?.streamOutput = nil
                    self?.startSCKCapture()
                    self?.isRestarting = false
                }
            }
        } else {
            startSCKCapture()
            isRestarting = false
        }
    }

    func startSCKCapture() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self, let content = content else {
                print("ERROR: SCShareableContent failed: \(error?.localizedDescription ?? "unknown")")
                return
            }

            // Find the SCDisplay matching our virtual display
            guard let scDisplay = content.displays.first(where: { $0.displayID == self.sourceDisplayID }) else {
                print("ERROR: Virtual display \(self.sourceDisplayID) not found in ScreenCaptureKit")
                print("Available displays:")
                for d in content.displays {
                    print("  ID:\(d.displayID) \(d.width)x\(d.height)")
                }
                return
            }

            // Exclude our own streaming window from capture to avoid recursion
            let excludedWindows = content.windows.filter { w in
                w.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }

            let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = 1080
            config.height = 1920
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60fps
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 3  // minimize latency

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let output = StreamOutput()
            output.imageLayer = self.imageLayer
            self.streamOutput = output

            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "stream-capture", qos: .userInteractive))
                stream.startCapture { error in
                    if let error = error {
                        print("ERROR: Stream start failed: \(error.localizedDescription)")
                        print("→ Grant Screen Recording permission in System Settings → Privacy & Security")
                    } else {
                        print("✓ Streaming at 60fps (zero-copy IOSurface)")
                    }
                }
                self.scStream = stream
            } catch {
                print("ERROR: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        CGDisplayRemoveReconfigurationCallback({ displayID, flags, userInfo in
            let controller = Unmanaged<StreamController>.fromOpaque(userInfo!).takeUnretainedValue()
            controller.checkTargetDisplayAlive()
        }, Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        scStream?.stopCapture { _ in }
        scStream = nil
        window?.close()
        window = nil
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var streamController: StreamController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let command = args.count > 1 ? args[1] : "help"

        switch command {
        case "list":
            printDisplays(getDisplays())
            NSApp.terminate(nil)
        case "start":
            startPortraitStreaming(args: args)
        default:
            printUsage()
            NSApp.terminate(nil)
        }
    }

    func startPortraitStreaming(args: [String]) {
        let targetDisplayID: CGDirectDisplayID? = args.count > 2 ? UInt32(args[2]) : nil

        // IMPORTANT: Capture the target NSScreen BEFORE creating the virtual display,
        // because MCT USB displays may disappear from the active display list
        // when a CGVirtualDisplay is created.
        let displays = getDisplays()
        printDisplays(displays)

        let target: DisplayInfo
        if let tid = targetDisplayID {
            guard let found = displays.first(where: { $0.id == tid }) else {
                print("ERROR: Display \(tid) not found")
                NSApp.terminate(nil)
                return
            }
            target = found
        } else {
            let candidates = displays.filter { d in
                !d.isMain && d.rotation == 0
            }
            if let preferred = candidates.first(where: { $0.width == 1920 && $0.height == 1080 }) {
                target = preferred
            } else if candidates.count == 1 {
                target = candidates[0]
            } else {
                print("Multiple candidates. Specify target display ID:")
                for d in candidates {
                    print("  portrait-display start \(d.id)    # \(d.width)x\(d.height)")
                }
                NSApp.terminate(nil)
                return
            }
        }

        // Lock the target NSScreen by frame position before virtual display creation
        guard let targetScreen = NSScreen.screens.first(where: { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return num == target.id
        }) else {
            print("ERROR: NSScreen not found for \(target.id)")
            NSApp.terminate(nil)
            return
        }
        let targetFrame = targetScreen.frame
        print("Step 1: Locked target → ID:\(target.id) \(target.width)x\(target.height) frame:\(targetFrame)")

        print("Step 2: Creating virtual portrait display (1080x1920)...")
        guard let vd = createVirtualDisplay(width: 1080, height: 1920) else {
            NSApp.terminate(nil)
            return
        }
        virtualDisplay = vd
        print("✓ Virtual display ID: \(vd.displayID)")

        // Wait for virtual display to register, then find target screen by saved frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            self.setupStreaming(virtualDisplayID: vd.displayID, savedTargetFrame: targetFrame, targetWidth: target.width, targetHeight: target.height)
        }
    }

    func setupStreaming(virtualDisplayID: CGDirectDisplayID, savedTargetFrame: CGRect, targetWidth: Int, targetHeight: Int) {
        let logFile = "/tmp/portrait-display-debug.log"
        var debugLines = [String]()
        debugLines.append("[\(Date())] setupStreaming: saved frame:\(savedTargetFrame)")

        // Re-scan NSScreens and match by frame origin (most stable identifier)
        for screen in NSScreen.screens {
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            debugLines.append("  NSScreen ID:\(num) frame:\(screen.frame)")
        }

        // Try matching by frame origin (position persists even if ID changes)
        var targetScreen = NSScreen.screens.first(where: { screen in
            screen.frame.origin == savedTargetFrame.origin &&
            Int(screen.frame.width) == Int(savedTargetFrame.width) &&
            Int(screen.frame.height) == Int(savedTargetFrame.height)
        })

        // Fallback: match by frame size only, excluding main and virtual
        if targetScreen == nil {
            debugLines.append("  Frame origin match failed, falling back to size match")
            targetScreen = NSScreen.screens.first(where: { screen in
                let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return num != 1 && num != virtualDisplayID &&
                    Int(screen.frame.width) == targetWidth && Int(screen.frame.height) == targetHeight
            })
        }

        guard let targetScreen = targetScreen else {
            debugLines.append("  ERROR: No NSScreen matched — target may have disconnected")
            try? debugLines.joined(separator: "\n").appending("\n").write(toFile: logFile, atomically: true, encoding: .utf8)
            print("ERROR: Target screen disappeared after virtual display creation")
            print("  This is a known MCT driver issue. Try the hardware fallback approach.")
            NSApp.terminate(nil)
            return
        }

        let matchedID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        debugLines.append("  ✓ Matched NSScreen ID:\(matchedID) frame:\(targetScreen.frame)")
        try? debugLines.joined(separator: "\n").appending("\n").write(toFile: logFile, atomically: true, encoding: .utf8)
        print("Step 3: Target screen matched → ID:\(matchedID) frame:\(targetScreen.frame)")

        print("Step 3: Starting stream...")
        let ctrl = StreamController(sourceDisplayID: virtualDisplayID, targetScreen: targetScreen)
        ctrl.start()
        self.streamController = ctrl
        printBanner(targetID: matchedID, targetWidth: targetWidth, targetHeight: targetHeight)
    }

    func applicationWillTerminate(_ notification: Notification) {
        streamController?.stop()
        virtualDisplay = nil
    }
}

func printBanner(targetID: CGDirectDisplayID, targetWidth: Int, targetHeight: Int) {
    print("""

    ╔══════════════════════════════════════════════════╗
    ║  Portrait Virtual Display — ACTIVE               ║
    ╠══════════════════════════════════════════════════╣
    ║  Virtual workspace: 1080x1920 (portrait)         ║
    ║  Streaming to:      ID:\(targetID) (\(targetWidth)x\(targetHeight))      ║
    ║                                                  ║
    ║  → System Settings → Displays → Arrange          ║
    ║  → Position "Portrait Virtual" where you want    ║
    ║  → Drag windows to the virtual display           ║
    ║  → Physically rotate your monitor 90°            ║
    ║                                                  ║
    ║  Ctrl+C to stop                                  ║
    ╚══════════════════════════════════════════════════╝
    """)
}

func printUsage() {
    print("""
    portrait-display — Virtual portrait display streamed to USB Display

    Usage:
      portrait-display start [targetID]   Create portrait display & stream to USB display
      portrait-display list                List all active displays
      portrait-display help                Show this help

    How it works:
      1. Creates a virtual 1080x1920 portrait display
      2. Captures it with ScreenCaptureKit at 30fps
      3. Renders on a fullscreen window on the target USB display
      4. Physically rotate the monitor for portrait viewing

    The virtual display is your workspace. The USB display is the renderer.
    """)
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate

signal(SIGINT) { _ in
    DispatchQueue.main.async { NSApp.terminate(nil) }
}
signal(SIGTERM) { _ in
    DispatchQueue.main.async { NSApp.terminate(nil) }
}

app.run()
