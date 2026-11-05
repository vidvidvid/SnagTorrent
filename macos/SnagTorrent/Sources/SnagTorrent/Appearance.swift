import AppKit
import Foundation

/// User-selected appearance; "system" follows macOS, the others force light or dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        (AppAppearance(rawValue: raw) ?? .system).apply()
    }
}
