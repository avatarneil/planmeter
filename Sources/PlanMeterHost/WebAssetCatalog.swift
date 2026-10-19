import Foundation

/// The static web client's files, content types, and response headers. Each
/// host decides where the directory lives (the Mac app bundle, an install
/// prefix, or the source tree during development).
public enum WebAssetCatalog {
    public static let files: [String: String] = [
        "/": "index.html",
        "/index.html": "index.html",
        "/app.js": "app.js",
        "/pair-parse.js": "pair-parse.js",
        "/jsqr.js": "jsqr.js",
        "/app.css": "app.css",
        "/manifest.webmanifest": "manifest.webmanifest",
        "/icon.svg": "icon.svg",
    ]

    public static func contentType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    public static func load(path: String, from directory: URL?) -> (data: Data, contentType: String)? {
        guard let name = files[path], let directory else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return (data, contentType(for: name))
    }

    /// True when `directory` holds the web client.
    public static func isWebDirectory(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path)
    }

    /// The source tree's copy, for development runs:
    /// Sources/PlanMeterHost/WebAssetCatalog.swift → Sources/PlanMeter/Web.
    public static var sourceTreeDirectory: URL? {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlanMeter", isDirectory: true).appendingPathComponent("Web", isDirectory: true)
        return isWebDirectory(source) ? source : nil
    }

    /// Headers for every static response. The page is a single origin with no
    /// third-party anything, so the policy can be tight.
    public static let securityHeaders: [String: String] = [
        // blob: images are the photo-decoding fallback for the in-page QR scanner.
        "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
        "X-Frame-Options": "DENY",
        "Permissions-Policy": "camera=(self), microphone=(), geolocation=()",
        "Cross-Origin-Opener-Policy": "same-origin",
    ]
}
