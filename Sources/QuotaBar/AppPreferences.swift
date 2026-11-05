import AppKit
import SwiftUI
import QuotaCore

enum AppAppearanceController {
    @MainActor
    static func apply(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    @MainActor
    static func label(language: AppLanguage) -> String {
        L10n.format(.versionFormat, marketing, build, language: language)
    }
}
