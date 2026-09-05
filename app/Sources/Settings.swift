// Einstellungen der App, gesichert in UserDefaults.
//
// Da Treiber und Oberfläche seit der App-Version im selben Prozess laufen,
// braucht es keine Konfigurationsdatei und kein Nachladen: die Menü-Einträge
// schreiben hier hinein, die Gesten-Engine liest bei jedem Event direkt
// wieder heraus.

import Foundation

enum SettingsKey {
    static let targetDisplay = "targetDisplay"        // "auto" oder "vendor:model:serial"
    static let invertScrollX = "invertScrollX"
    static let invertScrollY = "invertScrollY"
    static let zoomStepPixels = "zoomStepPixels"
    static let singleTouchDelay = "singleTouchDelay"
    static let gestureDecideMove = "gestureDecideMove"
    static let gestureDecideSpread = "gestureDecideSpread"
    static let doubleClickSlop = "doubleClickSlop"
    static let twoFingerTapMaxDuration = "twoFingerTapMaxDuration"
    static let verboseLogging = "verboseLogging"
}

enum Settings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.targetDisplay: "auto",
            SettingsKey.invertScrollX: false,
            SettingsKey.invertScrollY: false,
            SettingsKey.zoomStepPixels: 35.0,
            SettingsKey.singleTouchDelay: 0.035,
            SettingsKey.gestureDecideMove: 8.0,
            SettingsKey.gestureDecideSpread: 12.0,
            SettingsKey.doubleClickSlop: 25.0,
            SettingsKey.twoFingerTapMaxDuration: 0.4,
            SettingsKey.verboseLogging: false
        ])
    }

    private static let d = UserDefaults.standard

    /// "auto" oder eine EDID-Kennung "vendor:model:serial".
    static var targetDisplay: String {
        get { d.string(forKey: SettingsKey.targetDisplay) ?? "auto" }
        set { d.set(newValue, forKey: SettingsKey.targetDisplay) }
    }

    static var invertScrollX: Bool {
        get { d.bool(forKey: SettingsKey.invertScrollX) }
        set { d.set(newValue, forKey: SettingsKey.invertScrollX) }
    }

    static var invertScrollY: Bool {
        get { d.bool(forKey: SettingsKey.invertScrollY) }
        set { d.set(newValue, forKey: SettingsKey.invertScrollY) }
    }

    /// Abstandsänderung pro Zoom-Schritt in Pixeln. Kleiner = empfindlicher.
    static var zoomStepPixels: Double {
        get { d.double(forKey: SettingsKey.zoomStepPixels) }
        set { d.set(newValue, forKey: SettingsKey.zoomStepPixels) }
    }

    /// Wartezeit, bevor aus einer Berührung ein Klick wird (Sekunden).
    static var singleTouchDelay: Double {
        get { d.double(forKey: SettingsKey.singleTouchDelay) }
        set { d.set(newValue, forKey: SettingsKey.singleTouchDelay) }
    }

    static var gestureDecideMove: Double {
        get { d.double(forKey: SettingsKey.gestureDecideMove) }
        set { d.set(newValue, forKey: SettingsKey.gestureDecideMove) }
    }

    static var gestureDecideSpread: Double {
        get { d.double(forKey: SettingsKey.gestureDecideSpread) }
        set { d.set(newValue, forKey: SettingsKey.gestureDecideSpread) }
    }

    static var doubleClickSlop: Double {
        get { d.double(forKey: SettingsKey.doubleClickSlop) }
        set { d.set(newValue, forKey: SettingsKey.doubleClickSlop) }
    }

    static var twoFingerTapMaxDuration: Double {
        get { d.double(forKey: SettingsKey.twoFingerTapMaxDuration) }
        set { d.set(newValue, forKey: SettingsKey.twoFingerTapMaxDuration) }
    }

    static var verboseLogging: Bool {
        get { d.bool(forKey: SettingsKey.verboseLogging) }
        set { d.set(newValue, forKey: SettingsKey.verboseLogging) }
    }

    /// Alles auf Werkseinstellung zurück.
    static func resetAll() {
        for key in [SettingsKey.targetDisplay, SettingsKey.invertScrollX, SettingsKey.invertScrollY,
                    SettingsKey.zoomStepPixels, SettingsKey.singleTouchDelay,
                    SettingsKey.gestureDecideMove, SettingsKey.gestureDecideSpread,
                    SettingsKey.doubleClickSlop, SettingsKey.twoFingerTapMaxDuration,
                    SettingsKey.verboseLogging] {
            d.removeObject(forKey: key)
        }
    }
}
