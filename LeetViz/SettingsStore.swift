import AppKit
import Foundation

enum VisualizerStyle: String, CaseIterable {
    case bars = "Spectrum bars"
    case waveform = "Waveform"
    case blocks = "Pulsing blocks"
}

enum AccentColor: String, CaseIterable {
    case cyan
    case magenta
    case green
    case orange
    case white

    var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var nsColor: NSColor {
        switch self {
        case .cyan:    return NSColor(calibratedRed: 0.35, green: 0.85, blue: 1.00, alpha: 1)
        case .magenta: return NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.75, alpha: 1)
        case .green:   return NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.55, alpha: 1)
        case .orange:  return NSColor(calibratedRed: 1.00, green: 0.65, blue: 0.20, alpha: 1)
        case .white:   return NSColor.white
        }
    }
}

final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let style = "leetviz.style"
        static let accent = "leetviz.accent"
    }

    var style: VisualizerStyle {
        get { VisualizerStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .bars }
        set { defaults.set(newValue.rawValue, forKey: Key.style) }
    }

    var accent: AccentColor {
        get { AccentColor(rawValue: defaults.string(forKey: Key.accent) ?? "") ?? .cyan }
        set { defaults.set(newValue.rawValue, forKey: Key.accent) }
    }
}
