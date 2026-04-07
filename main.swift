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

class StreamController {
    let sourceDisplayID: CGDirectDisplayID
    let targetScreen: NSScreen
    var window: NSWindow?
    var imageLayer: CALayer?
    var scStream: SCStream?
    var streamOutput: StreamOutput?

    init(sourceDisplayID: CGDirectDisplayID, targetScreen: NSScreen) {
        self.sourceDisplayID = sourceDisplayID
        self.targetScreen = targetScreen
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

        print("Step 1: Creating virtual portrait display (1080x1920)...")
        guard let vd = createVirtualDisplay(width: 1080, height: 1920) else {
            NSApp.terminate(nil)
            return
        }
        virtualDisplay = vd
        print("✓ Virtual display ID: \(vd.displayID)")

        // Wait for display to register
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            self.setupStreaming(virtualDisplayID: vd.displayID, targetDisplayID: targetDisplayID)
        }
    }

    func setupStreaming(virtualDisplayID: CGDirectDisplayID, targetDisplayID: CGDirectDisplayID?) {
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
                !d.isMain && d.id != virtualDisplayID && d.rotation == 0
            }
            if candidates.count == 1 {
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
        print("Step 2: Target → ID:\(target.id) \(target.width)x\(target.height)")

        guard let targetScreen = NSScreen.screens.first(where: { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return num == target.id
        }) else {
            print("ERROR: NSScreen not found for \(target.id)")
            NSApp.terminate(nil)
            return
        }

        print("Step 3: Starting stream...")
        let ctrl = StreamController(sourceDisplayID: virtualDisplayID, targetScreen: targetScreen)
        ctrl.start()
        self.streamController = ctrl

        print("""

        ╔══════════════════════════════════════════════════╗
        ║  Portrait Virtual Display — ACTIVE               ║
        ╠══════════════════════════════════════════════════╣
        ║  Virtual workspace: 1080x1920 (portrait)         ║
        ║  Streaming to:      ID:\(target.id) (\(target.width)x\(target.height))      ║
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

    func applicationWillTerminate(_ notification: Notification) {
        streamController?.stop()
        virtualDisplay = nil
    }
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
