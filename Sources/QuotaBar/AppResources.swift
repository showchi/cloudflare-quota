import Foundation

/// Packaged apps use Contents/Resources; command-line SwiftPM builds use Bundle.module.
enum AppResources {
    static func bundle(
        main: Bundle = .main,
        developmentBundle: () -> Bundle = { .module }
    ) -> Bundle? {
        if main.bundleURL.pathExtension == "app" {
            guard let resources = main.resourceURL else { return nil }
            return Bundle(url: resources.appendingPathComponent("cloudflare-quota_QuotaBar.bundle"))
        }
        return developmentBundle()
    }
}
