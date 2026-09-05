// gen-mac-touchscreen-driver — menu bar interface
// Copyright (C) 2026 Stefan Kriesel
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See LICENSE for details.
//
// The driver runs in the same process (see TouchEngine), so changes here take
// effect immediately, without a restart and without a config file.

import Cocoa
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        // Without this the status lines would be greyed out because they have
        // no action; we control their appearance ourselves instead.
        menu.autoenablesItems = false
        statusItem.menu = menu

        TouchEngine.onStatusChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }

        TouchEngine.start()
        updateStatusItemAppearance()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TouchEngine.stop()
    }

    /// If a permission is missing or the driver is not running, a struck
    /// through icon is shown — otherwise there is no outward sign that the
    /// driver runs but has all its events silently discarded.
    ///
    /// Important: not every SF Symbol exists on every macOS version
    /// (`hand.tap.slash` does not, here). A symbol that is not found yields an
    /// empty image — and thus an invisible menu bar item. Hence the text
    /// fallback.
    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        // TSD_FORCE_WARN=1 forces the warning appearance, so this otherwise
        // rare state can actually be tested.
        let forceWarn = ProcessInfo.processInfo.environment["TSD_FORCE_WARN"] != nil
        let healthy = TouchEngine.isRunning && TouchEngine.accessibilityTrusted && !forceWarn
        let candidates = healthy ? ["hand.tap", "hand.point.up.left", "cursorarrow.click"]
                                 : ["cursorarrow.slash", "hand.tap"]

        let image = candidates.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Touchscreen-Treiber") }
            .first

        if let image {
            if healthy {
                // Normal case: template image, adapts to light/dark.
                image.isTemplate = true
                button.image = image
            } else {
                // Error case: deliberately red rather than a template — a
                // monochrome struck-through symbol is easy to miss among the
                // other menu bar icons.
                let tinted = image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? image
                tinted.isTemplate = false
                button.image = tinted
            }
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: healthy ? "TS" : "TS !",
                attributes: [.foregroundColor: healthy ? NSColor.labelColor : NSColor.systemRed])
        }
        button.toolTip = healthy
            ? "Touchscreen-Treiber läuft"
            : (TouchEngine.isRunning ? "Bedienungshilfen-Freigabe fehlt" : "Treiber gestoppt")
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        updateStatusItemAppearance()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // --- status ---
        menu.addItem(statusLine(
            ok: TouchEngine.isRunning,
            text: TouchEngine.isRunning ? "Treiber läuft" : "Treiber gestoppt"))
        menu.addItem(statusLine(
            ok: TouchEngine.panelConnected,
            text: TouchEngine.panelConnected
                ? "Verbunden: \(TouchEngine.deviceName)"
                : "Kein Touch-Gerät gefunden"))

        if !TouchEngine.accessibilityTrusted {
            let warn = NSMenuItem(title: "Bedienungshilfen freigeben …",
                                  action: #selector(requestAccessibility), keyEquivalent: "")
            warn.target = self
            warn.attributedTitle = NSAttributedString(
                string: "⚠︎  Bedienungshilfen freigeben …",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.menuFont(ofSize: 0)])
            warn.toolTip = "Ohne diese Freigabe verwirft macOS alle vom Treiber gesendeten Ereignisse."
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        // --- target display ---
        let displayItem = NSMenuItem(title: "Display: \(TouchEngine.targetDisplayLabel)", action: nil, keyEquivalent: "")
        displayItem.submenu = buildDisplayMenu()
        menu.addItem(displayItem)

        // --- scroll direction ---
        let scrollItem = NSMenuItem(
            title: "Scrollen: " + (Settings.invertScrollY ? "klassisch" : "natürlich"),
            action: nil, keyEquivalent: "")
        scrollItem.submenu = buildScrollMenu()
        menu.addItem(scrollItem)

        menu.addItem(.separator())

        // --- sliders ---
        // Zoom: the stored value is the distance change required per zoom
        // step, so SMALLER means more sensitive. The slider is therefore
        // presented inverted.
        menu.addItem(sliderItem(
            title: "Zoom-Empfindlichkeit",
            min: 15, max: 80, value: Settings.zoomStepPixels, inverted: true,
            format: { String(format: "%.0f px/Schritt", $0) },
            action: #selector(zoomSliderChanged(_:))))

        menu.addItem(sliderItem(
            title: "Klick-Verzögerung",
            min: 0, max: 0.12, value: Settings.singleTouchDelay, inverted: false,
            format: { String(format: "%.0f ms", $0 * 1000) },
            action: #selector(delaySliderChanged(_:))))

        menu.addItem(.separator())

        // --- misc ---
        let loginItem = NSMenuItem(title: "Bei Anmeldung starten",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let logItem = NSMenuItem(title: "Ausführliches Protokoll",
                                 action: #selector(toggleVerbose), keyEquivalent: "")
        logItem.target = self
        logItem.state = Settings.verboseLogging ? .on : .off
        logItem.toolTip = "Schreibt jedes Ereignis ins Systemprotokoll (Konsole.app)."
        menu.addItem(logItem)

        let resetItem = NSMenuItem(title: "Einstellungen zurücksetzen",
                                   action: #selector(resetSettings), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "Treiber neu starten", action: #selector(restartEngine), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let quit = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Status line with a coloured dot: green when running, red when not.
    /// The line is not clickable but still rendered normally rather than
    /// greyed out — that is what `menu.autoenablesItems = false` is for.
    private func statusLine(ok: Bool, text: String) -> NSMenuItem {
        let attributed = NSMutableAttributedString(
            string: "●  ",
            attributes: [.foregroundColor: ok ? NSColor.systemGreen : NSColor.systemRed,
                         .font: NSFont.menuFont(ofSize: 0)])
        attributed.append(NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.labelColor,
                         .font: NSFont.menuFont(ofSize: 0)]))

        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = attributed
        item.isEnabled = true   // nur Darstellung; ohne Aktion passiert beim Klick nichts
        return item
    }

    private func buildDisplayMenu() -> NSMenu {
        let sub = NSMenu()
        let setting = Settings.targetDisplay

        let auto = NSMenuItem(title: "Automatisch (nicht der Hauptbildschirm)",
                              action: #selector(selectAutoDisplay), keyEquivalent: "")
        auto.target = self
        auto.state = (setting == "auto") ? .on : .off
        auto.toolTip = "Notlösung - zielt daneben, sobald der Touchscreen selbst Hauptbildschirm ist."
        sub.addItem(auto)
        sub.addItem(.separator())

        for display in activeDisplays() {
            let item = NSMenuItem(title: display.label, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.key.description
            item.state = (setting == display.key.description) ? .on : .off
            item.toolTip = "EDID-Kennung \(display.key) - bleibt über Umstecken und Umsortieren gleich."
            sub.addItem(item)
        }
        return sub
    }

    private func buildScrollMenu() -> NSMenu {
        let sub = NSMenu()

        let natural = NSMenuItem(title: "Natürlich (Inhalt folgt dem Finger)",
                                 action: #selector(setNaturalScrolling), keyEquivalent: "")
        natural.target = self
        natural.state = Settings.invertScrollY ? .off : .on
        sub.addItem(natural)

        let classic = NSMenuItem(title: "Klassisch (wie Windows)",
                                 action: #selector(setClassicScrolling), keyEquivalent: "")
        classic.target = self
        classic.state = Settings.invertScrollY ? .on : .off
        sub.addItem(classic)

        sub.addItem(.separator())

        let flipX = NSMenuItem(title: "Horizontal umkehren",
                               action: #selector(toggleInvertX), keyEquivalent: "")
        flipX.target = self
        flipX.state = Settings.invertScrollX ? .on : .off
        sub.addItem(flipX)

        return sub
    }

    /// A slider inside the menu. `inverted` mirrors the scale so that
    /// "further right" always means "more sensitive", even where the stored
    /// value works the other way round.
    private func sliderItem(title: String, min: Double, max: Double, value: Double,
                            inverted: Bool, format: @escaping (Double) -> String,
                            action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 48))

        let label = NSTextField(labelWithString: "\(title): \(format(value))")
        label.frame = NSRect(x: 14, y: 26, width: 232, height: 16)
        label.font = .menuFont(ofSize: 12)
        view.addSubview(label)

        let slider = NSSlider(frame: NSRect(x: 12, y: 4, width: 236, height: 20))
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = inverted ? (min + max - value) : value
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.tag = inverted ? 1 : 0
        view.addSubview(slider)

        // keep the label in sync while dragging
        sliderLabels[ObjectIdentifier(slider)] = (label, title, format)

        item.view = view
        return item
    }

    private var sliderLabels: [ObjectIdentifier: (NSTextField, String, (Double) -> String)] = [:]

    private func liveUpdate(_ slider: NSSlider, storedValue: Double) {
        if let (label, title, format) = sliderLabels[ObjectIdentifier(slider)] {
            label.stringValue = "\(title): \(format(storedValue))"
        }
    }

    /// Translate the slider position into the value to store (mirrored if needed).
    private func storedValue(from slider: NSSlider) -> Double {
        slider.tag == 1 ? (slider.minValue + slider.maxValue - slider.doubleValue) : slider.doubleValue
    }

    // MARK: - Actions

    @objc private func zoomSliderChanged(_ sender: NSSlider) {
        let value = storedValue(from: sender)
        Settings.zoomStepPixels = value
        liveUpdate(sender, storedValue: value)
    }

    @objc private func delaySliderChanged(_ sender: NSSlider) {
        let value = storedValue(from: sender)
        Settings.singleTouchDelay = value
        liveUpdate(sender, storedValue: value)
    }

    @objc private func selectAutoDisplay() {
        Settings.targetDisplay = "auto"
        resolveTargetDisplay()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        Settings.targetDisplay = key
        resolveTargetDisplay()
    }

    @objc private func setNaturalScrolling() { Settings.invertScrollY = false }
    @objc private func setClassicScrolling() { Settings.invertScrollY = true }
    @objc private func toggleInvertX() { Settings.invertScrollX.toggle() }
    @objc private func toggleVerbose() { Settings.verboseLogging.toggle() }

    @objc private func resetSettings() {
        Settings.resetAll()
        Settings.registerDefaults()
        resolveTargetDisplay()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Could not change the login item: %@", error.localizedDescription)
        }
    }

    @objc private func requestAccessibility() {
        // Triggers the system dialog if the permission was never granted or
        // has been removed again.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restartEngine() {
        TouchEngine.restart()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
