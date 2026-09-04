import Foundation

/// Locates the static web client. Installed builds carry it in
/// `Contents/Resources/Web`; `swift run` falls back to the source tree.
enum WebAssets {
    static let files: [String: String] = [
        "/": "index.html",
        "/index.html": "index.html",
        "/app.js": "app.js",
        "/pair-parse.js": "pair-parse.js",
        "/jsqr.js": "jsqr.js",
        "/app.css": "app.css",
        "/manifest.webmanifest": "manifest.webmanifest",
        "/icon.svg": "icon.svg",
    ]

    static func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    static var directory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        // Development fallback: Sources/PlanMeter/Remote/WebAssets.swift → Sources/PlanMeter/Web
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("index.html").path) { return source }
        return nil
    }

    static func load(path: String) -> (data: Data, contentType: String)? {
        guard let name = files[path], let dir = directory else { return nil }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return (data, contentType(for: name))
    }

    /// Headers for every static response. The page is a single origin with no
    /// third-party anything, so the policy can be tight.
    static let securityHeaders: [String: String] = [
        // blob: images are the photo-decoding fallback for the in-page QR scanner.
        "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
        "X-Frame-Options": "DENY",
        "Permissions-Policy": "camera=(self), microphone=(), geolocation=()",
        "Cross-Origin-Opener-Policy": "same-origin",
    ]
}
