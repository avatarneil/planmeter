import AppKit
import SwiftUI
import PlanMeterDesktopShared

/// `PlanMeter --snapshot /path/out.png [--size WxH]` renders the main window
/// after the first scan and exits. Used for visual checks without needing
/// Screen Recording permission for a terminal.
enum SnapshotMode {
    static var path: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--snapshot-menu /path/out.png` renders the menu bar popover content
    /// off-screen with `ImageRenderer` (it is pure SwiftUI, so this works).
    static var menuPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-menu"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func captureMenu(to path: String, model: AppModel) async {
        try? await Task.sleep(for: .seconds(1))
        let view = MenuBarView().environment(model).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-menu: render failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot-menu: wrote \(path)")
        NSApp.terminate(nil)
    }

    /// `--snapshot-remote /path/out.png` renders the Remote sheet off-screen.
    static var remotePath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-remote"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func captureRemote(to path: String, model: AppModel) async {
        try? await Task.sleep(for: .seconds(2))
        model.remote.newInvite()
        try? await Task.sleep(for: .milliseconds(300))
        let view = RemoteSettingsView().environment(model).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-remote: render failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot-remote: wrote \(path)")
        NSApp.terminate(nil)
    }

    /// `--snapshot-desktop /tmp/widget` writes small, medium, and empty widget previews.
    static var desktopPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-desktop"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func captureDesktop(to prefix: String, model: AppModel) async {
        let payload = CommandLine.arguments.contains("--widget-preview") ? DesktopSnapshot.preview : model.desktopSnapshot()
        let variants: [(String, Double, Double, DesktopSpendView.Size, DesktopSnapshot?)] = [
            ("small", 170, 170, .small, payload), ("medium", 360, 170, .medium, payload),
            ("large", 360, 360, .large, payload), ("extra-large", 720, 360, .extraLarge, payload),
            ("empty", 170, 170, .small, nil),
        ]
        for (name, width, height, size, snapshot) in variants {
            let view = DesktopSpendView(snapshot: snapshot, date: Date(), size: size)
                .padding(16).frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            do { try png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png")) }
            catch { print("snapshot-desktop: \(error)"); exit(1) }
        }
        print("snapshot-desktop: wrote \(prefix)-{small,medium,large,extra-large,empty}.png")
        NSApp.terminate(nil)
    }

    static var size: NSSize {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--size"), i + 1 < args.count else { return NSSize(width: 1280, height: 1000) }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return NSSize(width: 1280, height: 1000) }
        return NSSize(width: parts[0], height: parts[1])
    }

    @MainActor
    static func capture(to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            FileHandle.standardError.write(Data("snapshot: no visible window\n".utf8))
            exit(1)
        }
        window.setContentSize(size)
        window.center()
        // Let SwiftUI lay out the resized content and Charts finish animating.
        try? await Task.sleep(for: .seconds(2))
        // SwiftUI content is layer-backed, so `cacheDisplay` renders blank;
        // capture the composited window instead. An app may capture its own
        // windows without Screen Recording permission.
        let windowId = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowId, [.boundsIgnoreFraming, .bestResolution]) else {
            FileHandle.standardError.write(Data("snapshot: window capture failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("snapshot: wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(1)
        }
        NSApp.terminate(nil)
    }
}
