import Foundation
import PlanMeterHost

/// Locates the static web client. Installed builds carry it in
/// `Contents/Resources/Web`; `swift run` falls back to the source tree. The
/// file list, content types, and headers live in `WebAssetCatalog`.
enum WebAssets {
    static var files: [String: String] { WebAssetCatalog.files }

    static func contentType(for name: String) -> String {
        WebAssetCatalog.contentType(for: name)
    }

    static var directory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true),
           WebAssetCatalog.isWebDirectory(bundled) {
            return bundled
        }
        // Development fallback: Sources/PlanMeter/Remote/WebAssets.swift → Sources/PlanMeter/Web
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Web", isDirectory: true)
        if WebAssetCatalog.isWebDirectory(source) { return source }
        return nil
    }

    static func load(path: String) -> (data: Data, contentType: String)? {
        WebAssetCatalog.load(path: path, from: directory)
    }

    static var securityHeaders: [String: String] { WebAssetCatalog.securityHeaders }
}
