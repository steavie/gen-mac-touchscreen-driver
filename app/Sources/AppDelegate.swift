// Menüleisten-Oberfläche. Der Treiber läuft im selben Prozess (siehe
// TouchEngine), deshalb wirken Änderungen hier sofort, ohne Neustart und
// ohne Konfigurationsdatei.

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
        // Ohne das grauen die Statuszeilen aus, weil sie keine Aktion haben -
        // wir steuern die Darstellung stattdessen selbst.
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

    /// Fehlt eine Freigabe oder läuft der Treiber nicht, wird ein
    /// durchgestrichenes Symbol gezeigt - sonst sieht man von außen nicht,
    /// dass der Treiber zwar läuft, seine Events aber stillschweigend
    /// verworfen werden.
    ///
    /// Wichtig: Nicht jedes SF-Symbol existiert auf jeder macOS-Version
    /// (`hand.tap.slash` z.B. nicht). Ein nicht gefundenes Symbol ergibt ein
    /// leeres Bild - und damit ein unsichtbares Menüleisten-Symbol. Deshalb
    /// hier immer ein Textfallback.
    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        // TSD_FORCE_WARN=1 erzwingt die Warndarstellung, damit sich dieser
        // sonst selten auftretende Zustand testen lässt.
        let forceWarn = ProcessInfo.processInfo.environment["TSD_FORCE_WARN"] != nil
        let healthy = TouchEngine.isRunning && TouchEngine.accessibilityTrusted && !forceWarn
        let candidates = healthy ? ["hand.tap", "hand.point.up.left", "cursorarrow.click"]
                                 : ["cursorarrow.slash", "hand.tap"]

        let image = candidates.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Touchscreen-Treiber") }
            .first

        if let image {
            if healthy {
                // Im Normalfall Schablonenbild: passt sich hell/dunkel an.
                image.isTemplate = true
                button.image = image
            } else {
                // Im Fehlerfall bewusst rot statt Schablone - ein
                // monochromes durchgestrichenes Symbol übersieht man in der
                // Menüleiste sonst leicht.
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

    // MARK: - Menü

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
        updateStatusItemAppearance()
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // --- Status ---
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

        // --- Ziel-Display ---
        let displayItem = NSMenuItem(title: "Display: \(TouchEngine.targetDisplayLabel)", action: nil, keyEquivalent: "")
        displayItem.submenu = buildDisplayMenu()
        menu.addItem(displayItem)

        // --- Scrollrichtung ---
        let scrollItem = NSMenuItem(
            title: "Scrollen: " + (Settings.invertScrollY ? "klassisch" : "natürlich"),
            action: nil, keyEquivalent: "")
        scrollItem.submenu = buildScrollMenu()
        menu.addItem(scrollItem)

        menu.addItem(.separator())

        // --- Regler ---
        // Zoom: der gespeicherte Wert ist die nötige Abstandsänderung pro
        // Zoom-Schritt, also je KLEINER desto empfindlicher. Der Regler wird
        // deshalb umgedreht dargestellt.
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

        // --- Sonstiges ---
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

    /// Statuszeile mit farbigem Punkt: grün wenn alles läuft, rot wenn nicht.
    /// Die Zeile ist nicht anklickbar, wird aber trotzdem normal (nicht grau)
    /// dargestellt - dafür sorgt `menu.autoenablesItems = false`.
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

    /// Regler direkt im Menü. `inverted` dreht die Skala um, damit "weiter
    /// rechts" immer "empfindlicher" bedeutet, auch wenn der gespeicherte
    /// Wert genau andersherum wirkt.
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

        // Label beim Ziehen mitführen
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

    /// Wert vom Regler in den zu speichernden Wert übersetzen (ggf. gespiegelt).
    private func storedValue(from slider: NSSlider) -> Double {
        slider.tag == 1 ? (slider.minValue + slider.maxValue - slider.doubleValue) : slider.doubleValue
    }

    // MARK: - Aktionen

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
            NSLog("Anmeldeobjekt konnte nicht geändert werden: %@", error.localizedDescription)
        }
    }

    @objc private func requestAccessibility() {
        // Löst den Systemdialog aus, falls die Freigabe noch nie erteilt oder
        // wieder entfernt wurde.
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
