// Gesten-Engine: liest die rohen USB-HID-Digitizer-Reports des Touchscreens
// (Vendor wch.cn, USB2IIC_CTP_CONTROL, 0x1a86:0xe2e3) und erzeugt daraus
// echte macOS-Events.
//
// Hintergrund: macOS hat keinen eingebauten Klassentreiber, der externe
// USB-HID-Touchscreens (UsagePage 0x0D "Digitizer", Usage 0x04 "Touch Screen")
// als Zeiger/Klick interpretiert - anders als Windows.
//
//   1 Finger        = Zeiger, Klick, Ziehen, Doppel-/Dreifachtipp
//   2 Finger kurz   = Rechtsklick
//   2 Finger ziehen = eine Geste, die zu Beginn EINMAL als Scroll ODER Zoom
//                     festgelegt und bis zum Loslassen beibehalten wird
//   3+ Finger       = ignoriert (unterdrückt, bis alle Finger weg sind)
//
// Die Callbacks von IOHIDManager und CoreGraphics sind C-Funktionszeiger und
// können nichts einfangen. Deshalb sind Zustand und Callbacks hier bewusst
// auf Dateiebene global und nicht in einer Klasse gekapselt - und deshalb
// wird mit -swift-version 5 gebaut (Swift 6 würde die globalen Zugriffe aus
// den C-Callbacks als Concurrency-Verstoß werten).

import Cocoa
import IOKit
import IOKit.hid
import ApplicationServices
import Carbon.HIToolbox

let targetVendorID = 0x1a86   // wch.cn
let targetProductID = 0xe2e3  // USB2IIC_CTP_CONTROL

func vlog(_ message: @autoclosure () -> String) {
    if Settings.verboseLogging { NSLog("%@", message()) }
}

// MARK: - Displays

/// Stabile Kennung eines physischen Displays aus dessen EDID. Anders als die
/// CGDirectDisplayID und anders als der Index in der Display-Liste bleibt sie
/// über Umstecken, Neustarts und Änderungen der Anordnung gleich.
struct DisplayKey: Equatable, CustomStringConvertible {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var description: String { "\(vendor):\(model):\(serial)" }

    init(_ id: CGDirectDisplayID) {
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
    }

    init?(parsing text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let v = UInt32(parts[0]), let m = UInt32(parts[1]), let s = UInt32(parts[2]) else { return nil }
        vendor = v; model = m; serial = s
    }
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let key: DisplayKey

    var isMain: Bool { id == CGMainDisplayID() }
    var label: String {
        "\(Int(bounds.width))×\(Int(bounds.height))" + (isMain ? " (Hauptbildschirm)" : "")
    }
}

func activeDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0), key: DisplayKey($0)) }
}

/// Auswahl in dieser Reihenfolge: feste EDID-Kennung aus den Einstellungen,
/// sonst automatisch das Display, das nicht der Hauptbildschirm ist. Die
/// Automatik ist nur eine Notlösung - sie zielt daneben, sobald der
/// Touchscreen selbst zum Hauptbildschirm gemacht wird.
func pickTargetDisplay(_ displays: [DisplayInfo]) -> DisplayInfo? {
    let setting = Settings.targetDisplay
    if setting != "auto", let key = DisplayKey(parsing: setting) {
        return displays.first { $0.key == key }
    }
    if displays.count == 2 {
        return displays[0].isMain ? displays[1] : displays[0]
    }
    return displays.count == 1 ? displays[0] : nil
}

var targetBounds = CGRect.zero
var haveTarget = false
var targetDescription = "—"

func resolveTargetDisplay() {
    guard let target = pickTargetDisplay(activeDisplays()) else {
        if !haveTarget { targetDescription = "nicht gefunden" }
        return
    }
    targetBounds = target.bounds
    haveTarget = true
    targetDescription = target.label
    vlog("Ziel-Display: \(target.label) \(target.key)")
    TouchEngine.notifyStatusChanged()
}

// MARK: - Zustand

struct TouchSlot {
    var down = false
    var x: Double = 0   // normalisiert 0..1
    var y: Double = 0
    var haveX = false
    var haveY = false
}

enum SlotField { case tip, x, y }

enum GestureMode {
    case idle          // nichts aktiv
    case single        // genau ein Finger, Zeiger/Klick
    case twoFinger     // Geste läuft
    case suppressed    // Finger noch drauf, aber keine neue Geste beginnen,
                       // bis wirklich alle Finger weg sind
}

enum TwoFingerKind { case undecided, scroll, zoom }

var slots: [TouchSlot] = []
var slotXRange: [(min: CFIndex, max: CFIndex)] = []
var slotYRange: [(min: CFIndex, max: CFIndex)] = []
var cookieToSlotField: [IOHIDElementCookie: (slot: Int, field: SlotField)] = [:]

var mode: GestureMode = .idle

// Ein-Finger-Zustand
var singleSlot: Int? = nil
var singleDownPosted = false
var singleDownPoint = CGPoint.zero
var lastSinglePoint = CGPoint.zero
var pendingDownWork: DispatchWorkItem? = nil

// Klickfolge (einfach/doppelt/dreifach)
var lastClickTime: TimeInterval = 0
var lastClickPoint = CGPoint.zero
var currentClickState: Int64 = 1

// Zwei-Finger-Zustand
var pairSlots: [Int] = []
var twoKind: TwoFingerKind = .undecided
var gestureStartAvg = CGPoint.zero
var gestureStartSpread: Double = 0
var prevAvg = CGPoint.zero
var lastZoomSpread: Double = 0
var scrollRemainderX: Double = 0
var scrollRemainderY: Double = 0
var twoFingerStart: TimeInterval = 0
/// Gesetzt, wenn eine Zwei-Finger-Berührung endete, ohne je zu einer Scroll-
/// oder Zoom-Geste zu werden - also ein Zwei-Finger-Tipp war. Der Rechtsklick
/// wird erst ausgelöst, wenn wirklich alle Finger weg sind (sonst käme er
/// mitten im Abheben des zweiten Fingers).
var pendingRightClick: CGPoint? = nil

let eventSource = CGEventSource(stateID: .hidSystemState)

func mappedPoint(slot idx: Int) -> CGPoint {
    // Defensiv: nach einer Neuverbindung kann sich die Slot-Liste ändern,
    // während noch ein alter Index herumliegt.
    guard slots.indices.contains(idx) else { return lastSinglePoint }
    let s = slots[idx]
    return CGPoint(
        x: targetBounds.origin.x + CGFloat(s.x) * targetBounds.width,
        y: targetBounds.origin.y + CGFloat(s.y) * targetBounds.height
    )
}

// MARK: - Event-Ausgabe

/// `clickState` ist die laufende Nummer innerhalb einer Klickfolge (1 =
/// einfach, 2 = doppelt, 3 = dreifach). Ohne dieses Feld erkennt macOS zwei
/// schnell aufeinanderfolgende Klicks NICHT als Doppelklick - man könnte
/// dann z.B. im Finder nichts per Doppeltipp öffnen.
func postMouse(_ type: CGEventType, at point: CGPoint,
               button: CGMouseButton = .left, clickState: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    event.post(tap: .cghidEventTap)
}

func postRightClick(at point: CGPoint) {
    postMouse(.rightMouseDown, at: point, button: .right)
    postMouse(.rightMouseUp, at: point, button: .right)
    vlog("RECHTSKLICK \(point)")
}

/// Scrollt pixelgenau. Die Nachkommastellen werden aufgesammelt statt
/// weggerundet, sonst geht bei langsamem Ziehen laufend Bewegung verloren.
func postScroll(dx: Double, dy: Double) {
    // Standard ist macOS-Verhalten: der Inhalt folgt dem Finger. Y wächst in
    // Quartz-Koordinaten nach unten, die Scrollrad-Achsen von CGEvent zeigen
    // jeweils entgegengesetzt dazu.
    let dirY: Double = Settings.invertScrollY ? -1 : 1
    let dirX: Double = Settings.invertScrollX ? 1 : -1

    scrollRemainderX += dirX * dx
    scrollRemainderY += dirY * dy
    let ix = Int32(scrollRemainderX.rounded(.towardZero))
    let iy = Int32(scrollRemainderY.rounded(.towardZero))
    guard ix != 0 || iy != 0 else { return }
    scrollRemainderX -= Double(ix)
    scrollRemainderY -= Double(iy)

    guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                              wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
    event.post(tap: .cghidEventTap)
    vlog("SCROLL x=\(ix) y=\(iy)")
}

// Echtes Pinch-to-Zoom braucht private Multitouch-APIs (bewusst nicht
// genutzt). Näherung: Cmd+Plus / Cmd+Minus, das viele Apps (Safari,
// Vorschau, Fotos, Browser) als Zoom-Shortcut unterstützen - Finder z.B.
// nicht, der hat dafür keinen Shortcut.
//
// Wichtig: Menü-Shortcuts (NSMenuItem keyEquivalent-Matching) werden von
// AppKit über "charactersIgnoringModifiers" aufgelöst, das aus dem
// PHYSISCHEN Tastencode + aktuellem Tastaturlayout berechnet wird - NICHT
// über ein per keyboardSetUnicodeString() gesetztes Zeichen (das wirkt nur
// für echte Text-Eingabe, nicht für Shortcut-Matching). Deshalb muss hier
// wirklich der Tastencode ermittelt werden, der im AKTUELLEN Layout "+"
// bzw. "-" erzeugt, statt einen festen (US-)Code zu raten.
func keyCodeForCharacter(_ target: Character) -> (keyCode: CGKeyCode, needsShift: Bool)? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
    guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let layoutData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data

    return layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (CGKeyCode, Bool)? in
        guard let layoutPtr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }

        for keyCode in 0..<128 {
            for shift in [false, true] {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let modifiers: UInt32 = shift ? UInt32(shiftKey) >> 8 : 0
                let status = UCKeyTranslate(
                    layoutPtr, UInt16(keyCode), UInt16(kUCKeyActionDown), modifiers,
                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &length, &chars
                )
                if status == noErr, length > 0,
                   let ch = String(utf16CodeUnits: chars, count: length).first, ch == target {
                    return (CGKeyCode(keyCode), shift)
                }
            }
        }
        return nil
    }
}

/// Einmal ermittelt und gemerkt - das Durchprobieren aller Tastencodes lohnt
/// sich nicht pro Zoom-Schritt. Bei Layout-Wechsel im laufenden Betrieb
/// müsste die App neu gestartet werden.
let zoomInKey = keyCodeForCharacter("+")
let zoomOutKey = keyCodeForCharacter("-")

func postZoomKey(zoomIn: Bool) {
    guard let (keyCode, needsShift) = zoomIn ? zoomInKey : zoomOutKey else { return }
    guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else { return }
    var flags: CGEventFlags = .maskCommand
    if needsShift { flags.insert(.maskShift) }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    vlog(zoomIn ? "ZOOM-IN" : "ZOOM-OUT")
}

// MARK: - Ein-Finger-Logik

func cancelPendingDown() {
    pendingDownWork?.cancel()
    pendingDownWork = nil
}

/// Setzt den zurückgehaltenen Mausklick ab (per Timer oder vorgezogen, wenn
/// der Finger vorher wieder hochgeht).
func commitSingleDown() {
    guard mode == .single, !singleDownPosted else { return }
    cancelPendingDown()
    singleDownPosted = true

    // Gehört dieser Tipp noch zur vorherigen Klickfolge (Doppel-/Dreifach-
    // tipp)? Maßstab ist das System-Doppelklick-Intervall plus eine
    // großzügige Ortstoleranz.
    let now = ProcessInfo.processInfo.systemUptime
    let distance = hypot(singleDownPoint.x - lastClickPoint.x, singleDownPoint.y - lastClickPoint.y)
    if now - lastClickTime <= NSEvent.doubleClickInterval && Double(distance) <= Settings.doubleClickSlop {
        currentClickState = min(currentClickState + 1, 3)
    } else {
        currentClickState = 1
    }
    lastClickTime = now
    lastClickPoint = singleDownPoint

    postMouse(.leftMouseDown, at: singleDownPoint, clickState: currentClickState)
    vlog("DOWN \(singleDownPoint) clickState=\(currentClickState)")
    // Falls sich der Finger während der Verzögerung schon bewegt hat,
    // die Bewegung nachziehen.
    if lastSinglePoint != singleDownPoint {
        postMouse(.leftMouseDragged, at: lastSinglePoint, clickState: currentClickState)
    }
}

func beginSingle(slot idx: Int) {
    mode = .single
    singleSlot = idx
    singleDownPosted = false
    singleDownPoint = mappedPoint(slot: idx)
    lastSinglePoint = singleDownPoint

    let work = DispatchWorkItem { commitSingleDown() }
    pendingDownWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Settings.singleTouchDelay, execute: work)
}

/// Beendet eine Ein-Finger-Berührung. `click: false` verwirft einen noch
/// nicht abgesetzten Klick komplett (z.B. weil daraus eine Zwei-Finger-Geste
/// wurde oder das Gerät abgezogen wurde).
func endSingle(click: Bool) {
    guard mode == .single else {
        cancelPendingDown()
        return
    }
    if !singleDownPosted {
        if click { commitSingleDown() } else { cancelPendingDown() }
    }
    if singleDownPosted {
        postMouse(.leftMouseUp, at: lastSinglePoint, clickState: currentClickState)
        vlog("UP \(lastSinglePoint)")
    }
    cancelPendingDown()
    singleDownPosted = false
    singleSlot = nil
}

// MARK: - Zwei-Finger-Logik

func beginTwoFinger(active: [Int], avg: CGPoint, spread: Double) {
    mode = .twoFinger
    pairSlots = active
    twoKind = .undecided
    gestureStartAvg = avg
    gestureStartSpread = spread
    prevAvg = avg
    lastZoomSpread = spread
    scrollRemainderX = 0
    scrollRemainderY = 0
    twoFingerStart = ProcessInfo.processInfo.systemUptime
    pendingRightClick = nil
}

/// Beim Verlassen einer Zwei-Finger-Berührung prüfen, ob es ein kurzer Tipp
/// war (nie zu Scroll/Zoom geworden) - dann ist ein Rechtsklick fällig.
func noteTwoFingerEnd() {
    guard mode == .twoFinger, twoKind == .undecided else { return }
    if ProcessInfo.processInfo.systemUptime - twoFingerStart <= Settings.twoFingerTapMaxDuration {
        pendingRightClick = prevAvg
    }
}

func updateZoom(spread: Double) {
    let step = max(Settings.zoomStepPixels, 5)
    let delta = spread - lastZoomSpread
    guard abs(delta) >= step else { return }
    let steps = min(Int(abs(delta) / step), 3)   // Ausreißer deckeln
    guard steps > 0 else { return }
    let zoomIn = delta > 0
    for _ in 0..<steps { postZoomKey(zoomIn: zoomIn) }
    lastZoomSpread += (zoomIn ? 1 : -1) * Double(steps) * step
}

func resetGesture() {
    pairSlots = []
    twoKind = .undecided
    scrollRemainderX = 0
    scrollRemainderY = 0
}

// MARK: - Zustandsautomat

func activeValidSlots() -> [Int] {
    slots.indices.filter { slots[$0].down && slots[$0].haveX && slots[$0].haveY }
}

func processGestureState() {
    // Ohne bekanntes Ziel-Display wären alle Koordinaten sinnlos.
    guard haveTarget else { return }
    let active = activeValidSlots()

    switch active.count {
    case 0:
        noteTwoFingerEnd()
        endSingle(click: true)
        mode = .idle
        resetGesture()
        if let p = pendingRightClick {
            pendingRightClick = nil
            postRightClick(at: p)
        }

    case 1:
        let idx = active[0]
        switch mode {
        case .idle:
            beginSingle(slot: idx)
        case .single:
            if singleSlot == idx {
                lastSinglePoint = mappedPoint(slot: idx)
                if singleDownPosted {
                    postMouse(.leftMouseDragged, at: lastSinglePoint, clickState: currentClickState)
                }
            } else {
                // Anderer Finger als der, der die Geste begonnen hat.
                endSingle(click: true)
                mode = .suppressed
            }
        case .twoFinger:
            // Ein Finger einer Geste wurde gehoben: NICHT als neuen Klick
            // werten, sondern warten bis wirklich alle Finger weg sind.
            noteTwoFingerEnd()
            mode = .suppressed
            resetGesture()
        case .suppressed:
            break
        }

    case 2:
        let p0 = mappedPoint(slot: active[0])
        let p1 = mappedPoint(slot: active[1])
        let avg = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let spread = Double(hypot(p0.x - p1.x, p0.y - p1.y))

        switch mode {
        case .suppressed:
            break

        case .idle:
            beginTwoFinger(active: active, avg: avg, spread: spread)

        case .single:
            // Zweiter Finger kam dazu: der zurückgehaltene Klick wird
            // verworfen, es war von Anfang an eine Geste.
            endSingle(click: false)
            beginTwoFinger(active: active, avg: avg, spread: spread)

        case .twoFinger:
            if active != pairSlots {
                // Anderes Fingerpaar (z.B. dritter Finger kam/ging):
                // Basislinie neu setzen, sonst gibt es einen Sprung.
                pairSlots = active
                gestureStartAvg = avg
                gestureStartSpread = spread
                prevAvg = avg
                lastZoomSpread = spread
                break
            }

            let dx = Double(avg.x - prevAvg.x)
            let dy = Double(avg.y - prevAvg.y)
            prevAvg = avg

            switch twoKind {
            case .undecided:
                // Art der Geste EINMAL festlegen und bis zum Loslassen
                // beibehalten - sonst wechselt eine Geste ständig zwischen
                // Scrollen und Zoomen hin und her.
                let moved = Double(hypot(avg.x - gestureStartAvg.x, avg.y - gestureStartAvg.y))
                let spreadChange = abs(spread - gestureStartSpread)
                if spreadChange > Settings.gestureDecideSpread && spreadChange > moved {
                    twoKind = .zoom
                    lastZoomSpread = gestureStartSpread
                    vlog("GESTE: Zoom")
                    updateZoom(spread: spread)
                } else if moved > Settings.gestureDecideMove {
                    twoKind = .scroll
                    vlog("GESTE: Scroll")
                    postScroll(dx: dx, dy: dy)
                }
            case .scroll:
                postScroll(dx: dx, dy: dy)
            case .zoom:
                updateZoom(spread: spread)
            }
        }

    default:
        // 3+ Finger werden nicht unterstützt: laufende Geste sauber beenden
        // und bis zum vollständigen Loslassen nichts mehr auslösen. Ein
        // dritter Finger macht aus einem Zwei-Finger-Tipp auch keinen
        // Rechtsklick mehr.
        endSingle(click: false)
        pendingRightClick = nil
        mode = .suppressed
        resetGesture()
    }
}

// MARK: - HID-Callbacks

func hidInputCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                      sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let cookie = IOHIDElementGetCookie(element)
    guard let mapping = cookieToSlotField[cookie] else { return }
    guard slots.indices.contains(mapping.slot) else { return }
    let raw = IOHIDValueGetIntegerValue(value)

    switch mapping.field {
    case .tip:
        // Achtung: dieser Controller schickt X/Y VOR dem Tip-Down-Report im
        // selben Tastendruck - haveX/haveY hier NICHT zurücksetzen, sonst
        // werden die gerade erst eingetroffenen frischen Koordinaten wieder
        // verworfen, bevor die Aktivierungsprüfung sie sieht.
        slots[mapping.slot].down = raw != 0
    case .x:
        let range = slotXRange[mapping.slot]
        if range.max > range.min {
            slots[mapping.slot].x = Double(raw - range.min) / Double(range.max - range.min)
        }
        slots[mapping.slot].haveX = true
    case .y:
        let range = slotYRange[mapping.slot]
        if range.max > range.min {
            slots[mapping.slot].y = Double(raw - range.min) / Double(range.max - range.min)
        }
        slots[mapping.slot].haveY = true
    }

    processGestureState()
}

/// Bricht alles Laufende sauber ab - wichtig, damit nach einem Abziehen des
/// Kabels mitten in einer Berührung nicht die linke Maustaste systemweit
/// "gedrückt" hängen bleibt.
func resetEverything() {
    endSingle(click: false)
    cancelPendingDown()
    mode = .idle
    singleSlot = nil
    singleDownPosted = false
    pendingRightClick = nil
    resetGesture()
    for i in slots.indices { slots[i] = TouchSlot() }
}

func hidDeviceMatchedCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                              sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
        return
    }

    resetEverything()
    slots = []
    slotXRange = []
    slotYRange = []
    cookieToSlotField = [:]

    var currentSlot = -1
    for element in elements {
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let cookie = IOHIDElementGetCookie(element)

        switch (page, usage) {
        case (0x0D, 0x42): // Digitizer / Tip Switch -> neuer Finger-Slot
            slots.append(TouchSlot())
            slotXRange.append((0, 0))
            slotYRange.append((0, 0))
            currentSlot = slots.count - 1
            cookieToSlotField[cookie] = (currentSlot, .tip)

        case (0x01, 0x30) where currentSlot >= 0: // Generic Desktop / X
            slotXRange[currentSlot] = (IOHIDElementGetLogicalMin(element), IOHIDElementGetLogicalMax(element))
            cookieToSlotField[cookie] = (currentSlot, .x)

        case (0x01, 0x31) where currentSlot >= 0: // Generic Desktop / Y
            slotYRange[currentSlot] = (IOHIDElementGetLogicalMin(element), IOHIDElementGetLogicalMax(element))
            cookieToSlotField[cookie] = (currentSlot, .y)

        default:
            break
        }
    }

    TouchEngine.panelConnected = true
    vlog("Touch-Panel verbunden (\(slots.count) Finger-Slots)")
    TouchEngine.notifyStatusChanged()
}

func hidDeviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                              sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    resetEverything()
    TouchEngine.panelConnected = false
    vlog("Touch-Panel getrennt")
    TouchEngine.notifyStatusChanged()
}

func displayReconfigCallback(display: CGDirectDisplayID,
                             flags: CGDisplayChangeSummaryFlags,
                             userInfo: UnsafeMutableRawPointer?) {
    // Nur nach Abschluss der Umkonfiguration reagieren.
    if flags.contains(.beginConfigurationFlag) { return }
    resolveTargetDisplay()
}

// MARK: - Steuerung

enum TouchEngine {
    static var manager: IOHIDManager? = nil
    static var panelConnected = false
    static var onStatusChange: (() -> Void)? = nil

    static var isRunning: Bool { manager != nil }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var targetDisplayLabel: String { targetDescription }

    static func notifyStatusChanged() {
        DispatchQueue.main.async { onStatusChange?() }
    }

    static func start() {
        guard manager == nil else { return }

        resolveTargetDisplay()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: targetVendorID,
            kIOHIDProductIDKey as String: targetProductID
        ]
        IOHIDManagerSetDeviceMatching(m, matchDict as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, hidInputCallback, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(m, hidDeviceMatchedCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, hidDeviceRemovedCallback, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            NSLog("HID-Manager konnte nicht geöffnet werden - fehlt die Freigabe für Eingabeüberwachung?")
            notifyStatusChanged()
            return
        }
        manager = m
        notifyStatusChanged()
    }

    static func stop() {
        guard let m = manager else { return }
        resetEverything()
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, nil)
        manager = nil
        panelConnected = false
        notifyStatusChanged()
    }

    static func restart() {
        stop()
        start()
    }
}
