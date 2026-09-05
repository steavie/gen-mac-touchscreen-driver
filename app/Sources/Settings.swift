// steavie-gen-mac-touchscreen-driver — settings, persisted in UserDefaults
// Copyright (C) 2026 Stefan Kriesel
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See LICENSE for details.
//
// Driver and interface live in the same process, so there is no config file
// and nothing to reload: the menu writes here, and the gesture engine reads
// from here on every event.

import Foundation

enum SettingsKey {
    static let targetDisplay = "targetDisplay"        // "auto" or "vendor:model:serial"
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

    /// Either "auto" or an EDID identity "vendor:model:serial".
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

    /// Distance change per zoom step, in pixels. Smaller means more sensitive.
    static var zoomStepPixels: Double {
        get { d.double(forKey: SettingsKey.zoomStepPixels) }
        set { d.set(newValue, forKey: SettingsKey.zoomStepPixels) }
    }

    /// How long a touch is held back before it becomes a click, in seconds.
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

    /// Back to factory defaults.
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
