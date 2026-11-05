import Foundation

enum Format {
    private static func bytes(_ value: UInt64) -> String {
        let formatted = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false)
        return Int64(clamping: value).formatted(formatted)
    }

    static func size(_ value: UInt64) -> String {
        value == 0 ? "—" : bytes(value)
    }

    static func rate(_ value: UInt64) -> String {
        value == 0 ? "—" : bytes(value) + "/s"
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        if clamped >= 1 { return "100%" }
        return clamped >= 0.9995 ? "99.9%" : String(format: "%.1f%%", clamped * 100)
    }

    static func eta(_ seconds: UInt64?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
