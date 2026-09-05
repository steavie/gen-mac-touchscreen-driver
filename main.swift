// touchscreen-driver: übersetzt rohe USB-HID-Digitizer-Reports des 7"-Touchscreens
// (Vendor wch.cn, USB2IIC_CTP_CONTROL, 0x1a86:0xe2e3) in echte macOS-Events.
//
// Hintergrund: macOS hat keinen eingebauten Klassentreiber, der externe
// USB-HID-Touchscreens (UsagePage 0x0D "Digitizer", Usage 0x04 "Touch Screen")
// automatisch als Zeiger/Klick interpretiert - anders als Windows. Dieses
// Tool liest die Digitizer-Elemente direkt per IOHIDManager und postet
// passende CGEvents.
//
// Multitouch: der Controller meldet bis zu 5 gleichzeitige Kontakte in 10
// Finger-Slots (Standard "Windows Precision Touch"-Layout, per
// dump-elements.swift ermittelt).
//   1 Finger  = Zeiger + Klick + Ziehen
//   2 Finger  = eine Geste, die zu Beginn EINMAL als Scroll ODER Zoom
//               festgelegt und bis zum Loslassen beibehalten wird
//   3+ Finger = ignoriert (unterdrückt, bis alle Finger weg sind)
//
// Braucht beim ersten Start zwei Freigaben in Systemeinstellungen ->
// Datenschutz & Sicherheit: "Eingabeüberwachung" (zum Lesen der HID-Reports)
// und "Bedienungshilfen" (zum Senden von Events).
//
// Aufruf:
//   ./touchscreen-driver --list              zeigt verfügbare Displays
//   ./touchscreen-driver --display <v:m:s>   Ziel-Display fest über EDID-Kennung (empfohlen)
//   ./touchscreen-driver --screen <index>    Ziel-Display über Index (verschiebt sich)
//   ./touchscreen-driver --verbose           laufende Event-Ausgabe (sonst still)
//   ./touchscreen-driver                     bei 1-2 Displays automatisch das externe

import Cocoa
import IOKit
import IOKit.hid
import ApplicationServices
import Carbon.HIToolbox

setvbuf(stdout, nil, _IONBF, 0)

let driverVersion = "1.3"

let targetVendorID = 0x1a86   // wch.cn
let targetProductID = 0xe2e3  // USB2IIC_CTP_CONTROL

// MARK: - Feintuning

/// Wartezeit, bevor aus einer Ein-Finger-Berührung wirklich ein Mausklick
/// wird. Kommt in dieser Zeit ein zweiter Finger dazu, war es eine Geste und
/// es wird gar nicht erst geklickt (verhindert Phantom-Klicks, da zwei Finger
/// nie exakt gleichzeitig aufsetzen). Wird der Finger vorher wieder gehoben
/// (schneller Tap), holen wir den Klick sofort nach - kostet also keine
/// spürbare Latenz.
let singleTouchDelay: TimeInterval = 0.035

/// Wie weit sich zwei Finger bewegen bzw. ihr Abstand ändern muss, bevor die
/// Geste als Scroll oder Zoom festgelegt wird (Pixel).
let gestureDecideMove: Double = 8.0
let gestureDecideSpread: Double = 12.0

/// Abstandsänderung pro Zoom-Schritt (Pixel).
let zoomStepPixels: Double = 35.0

/// Wie weit zwei aufeinanderfolgende Tipps auseinanderliegen dürfen, um noch
/// als Doppel-/Dreifachklick zu zählen (Pixel). Großzügiger als bei einer
/// Maus, weil ein Finger nie zweimal exakt dieselbe Stelle trifft.
let doubleClickSlop: Double = 25.0

/// Ein Zwei-Finger-Tipp (kurz auftippen, ohne zu scrollen oder zu zoomen)
/// löst einen Rechtsklick aus - wie das Zwei-Finger-Tippen auf dem Trackpad.
/// Länger als das gilt es nicht mehr als Tipp.
let twoFingerTapMaxDuration: TimeInterval = 0.4

// MARK: - CLI-Argumente

let args = CommandLine.arguments
let verbose = args.contains("--verbose") || args.contains("-v")
let listOnly = args.contains("--list")

/// Standard ist macOS-Verhalten ("natürliches Scrollen"): der Inhalt folgt
/// dem Finger. Mit --invert-y bzw. --invert-x lässt sich jede Achse einzeln
/// umdrehen (z.B. auf klassisches Windows-Verhalten). Bewusst als
/// Laufzeit-Flag statt als Konstante im Code: ein Rebuild würde die
/// TCC-Freigaben ungültig machen (siehe README), ein Flag in der
/// LaunchAgent-Plist nicht.
let invertScrollY = args.contains("--invert-y")
let invertScrollX = args.contains("--invert-x")
var explicitDisplayIndex: Int? = nil
if let idx = args.firstIndex(of: "--screen"), idx + 1 < args.count {
    explicitDisplayIndex = Int(args[idx + 1])
}

/// Ziel-Display fest über seine EDID-Kennung (vendor:model:serial) wählen.
/// Robuster als --screen: der Index verschiebt sich, sobald sich die
/// Anordnung ändert, und die Automatik "nicht der Hauptbildschirm" greift
/// daneben, sobald der Touchscreen selbst zum Hauptbildschirm wird.
/// Die passenden Werte listet --list auf.
var pinnedDisplayKey: DisplayKey? = nil
if let idx = args.firstIndex(of: "--display"), idx + 1 < args.count {
    pinnedDisplayKey = DisplayKey(parsing: args[idx + 1])
    if pinnedDisplayKey == nil {
        print("Ungültiges --display Format '\(args[idx + 1])', erwartet vendor:model:serial.")
        exit(1)
    }
}

/// Laufende Event-Ausgabe nur mit --verbose: der Treiber läuft dauerhaft als
/// LaunchAgent, eine Zeile pro Scroll-Event würde das Log sonst unbegrenzt
/// wachsen lassen (launchd rotiert nicht).
func vlog(_ message: @autoclosure () -> String) {
    if verbose { print(message()) }
}

// MARK: - Ziel-Display (Quartz-Koordinaten, direkt kompatibel mit CGEvent)

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
}

func activeDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0), key: DisplayKey($0)) }
}

func printDisplays(_ displays: [DisplayInfo]) {
    print("Gefundene Displays:")
    for (i, d) in displays.enumerated() {
        let mark = d.id == CGMainDisplayID() ? "  (Hauptbildschirm)" : ""
        print("  [\(i)] id=\(d.id) \(Int(d.bounds.width))x\(Int(d.bounds.height)) bei (\(Int(d.bounds.origin.x)),\(Int(d.bounds.origin.y)))  --display \(d.key)\(mark)")
    }
}

func pickTargetIndex(_ displays: [DisplayInfo]) -> Int? {
    // 1. Fest verdrahtete EDID-Kennung - die zuverlässigste Variante.
    if let pinnedDisplayKey {
        return displays.firstIndex { $0.key == pinnedDisplayKey }
    }
    // 2. Fester Index. Achtung: Indizes verschieben sich, wenn sich die
    //    Anordnung ändert - deshalb ist --display vorzuziehen.
    if let explicitDisplayIndex {
        return displays.indices.contains(explicitDisplayIndex) ? explicitDisplayIndex : nil
    }
    // 3. Automatik: das Display, das nicht der Hauptbildschirm ist. Nur eine
    //    Notlösung - wird der Touchscreen selbst zum Hauptbildschirm gemacht,
    //    zielt sie auf das falsche Display (deshalb --display nutzen).
    if displays.count == 2 {
        return displays[0].id == CGMainDisplayID() ? 1 : 0
    }
    if displays.count == 1 {
        return 0
    }
    return nil
}

var targetBounds = CGRect.zero
var haveTarget = false

/// Wird beim Start und bei jeder Display-Änderung (Anordnung, Auflösung,
/// An-/Abstecken) aufgerufen - sonst würde das Koordinaten-Mapping nach dem
/// ersten Umstöpseln bis zum Neustart falsch bleiben.
func resolveTargetDisplay(quiet: Bool = false) {
    let displays = activeDisplays()
    guard let index = pickTargetIndex(displays) else {
        if haveTarget {
            print("Ziel-Display nicht mehr eindeutig bestimmbar, behalte \(targetBounds).")
        }
        return
    }
    targetBounds = displays[index].bounds
    haveTarget = true
    if !quiet {
        print("Ziel-Display: [\(index)] \(targetBounds)")
    }
}

// MARK: - Zustand

struct TouchSlot {
    var down = false
    var x: Double = 0   // normalisiert 0..1
    var y: Double = 0
    var haveX = false
    var haveY = false
}

enum SlotField {
    case tip, x, y
}

enum GestureMode {
    case idle          // nichts aktiv
    case single        // genau ein Finger, Zeiger/Klick
    case twoFinger     // Geste läuft
    case suppressed    // Finger noch drauf, aber keine neue Geste beginnen,
                       // bis wirklich alle Finger weg sind
}

enum TwoFingerKind {
    case undecided, scroll, zoom
}

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
let doubleClickInterval = NSEvent.doubleClickInterval
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
    // Vorzeichen für "Inhalt folgt dem Finger" (macOS-Standard). Y in
    // Quartz-Koordinaten wächst nach unten, die Scrollrad-Achsen von CGEvent
    // zeigen jeweils entgegengesetzt dazu.
    let dirY: Double = invertScrollY ? -1 : 1
    let dirX: Double = invertScrollX ? 1 : -1

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

let zoomInKey = keyCodeForCharacter("+")
let zoomOutKey = keyCodeForCharacter("-")

func postZoomKey(zoomIn: Bool) {
    guard let (keyCode, needsShift) = zoomIn ? zoomInKey : zoomOutKey else {
        print("Konnte Taste für '\(zoomIn ? "+" : "-")' im aktuellen Tastaturlayout nicht ermitteln.")
        return
    }
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
    if now - lastClickTime <= doubleClickInterval && Double(distance) <= doubleClickSlop {
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
    DispatchQueue.main.asyncAfter(deadline: .now() + singleTouchDelay, execute: work)
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
        if click {
            commitSingleDown()
        } else {
            cancelPendingDown()
        }
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
    if ProcessInfo.processInfo.systemUptime - twoFingerStart <= twoFingerTapMaxDuration {
        pendingRightClick = prevAvg
    }
}

func updateZoom(spread: Double) {
    let delta = spread - lastZoomSpread
    guard abs(delta) >= zoomStepPixels else { return }
    let steps = min(Int(abs(delta) / zoomStepPixels), 3)   // Ausreißer deckeln
    guard steps > 0 else { return }
    let zoomIn = delta > 0
    for _ in 0..<steps {
        postZoomKey(zoomIn: zoomIn)
    }
    lastZoomSpread += (zoomIn ? 1 : -1) * Double(steps) * zoomStepPixels
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
                if spreadChange > gestureDecideSpread && spreadChange > moved {
                    twoKind = .zoom
                    lastZoomSpread = gestureStartSpread
                    vlog("GESTE: Zoom")
                    updateZoom(spread: spread)
                } else if moved > gestureDecideMove {
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
// Top-level Funktionen ohne Closure-Capture, damit sie als C-Funktionszeiger
// nutzbar sind - sie greifen deshalb auf die globalen vars oben zu (und
// deshalb wird mit -swift-version 5 gebaut, siehe README).

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
    for i in slots.indices {
        slots[i] = TouchSlot()
    }
}

func hidDeviceMatchedCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                              sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"

    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
        print("Touch-Panel verbunden: \(product), aber Elemente nicht lesbar.")
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

    print("Touch-Panel verbunden: \(product) (\(slots.count) Finger-Slots, \(cookieToSlotField.count) Mappings)")
    if verbose {
        for (cookie, m) in cookieToSlotField.sorted(by: { $0.key < $1.key }) {
            print("  Mapping cookie=\(cookie) -> slot=\(m.slot) field=\(m.field)")
        }
    }
}

func hidDeviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                              sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    resetEverything()
    print("Touch-Panel getrennt.")
}

func displayReconfigCallback(display: CGDirectDisplayID,
                             flags: CGDisplayChangeSummaryFlags,
                             userInfo: UnsafeMutableRawPointer?) {
    // Nur nach Abschluss der Umkonfiguration reagieren.
    if flags.contains(.beginConfigurationFlag) { return }
    resolveTargetDisplay()
}

// MARK: - Start

let axOptions: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
if !AXIsProcessTrustedWithOptions(axOptions as CFDictionary) {
    print("Hinweis: Bedienungshilfen-Freigabe fehlt noch - ohne sie werden gesendete")
    print("Maus-/Tastatur-Events von macOS stillschweigend verworfen.")
}

let displaysAtStart = activeDisplays()
printDisplays(displaysAtStart)

if listOnly {
    exit(0)
}

if pickTargetIndex(displaysAtStart) == nil {
    // Kein harter Abbruch: das Panel kann beim Login schlicht noch nicht
    // angesteckt sein. Sobald es auftaucht, greift der
    // Reconfiguration-Callback. Bis dahin werden Berührungen ignoriert.
    print("Ziel-Display noch nicht gefunden - warte darauf. Zum Festlegen:")
    print("  --display <vendor:model:serial>  (empfohlen, siehe Liste oben)")
    print("  --screen <index>                 (verschiebt sich bei Änderung der Anordnung)")
}
resolveTargetDisplay()
CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)

if zoomInKey == nil || zoomOutKey == nil {
    print("Warnung: Zoom-Tasten im aktuellen Tastaturlayout nicht gefunden, Zoom wird nicht funktionieren.")
} else {
    vlog("Zoom-Tasten: + -> \(zoomInKey!), - -> \(zoomOutKey!)")
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matchDict: [String: Any] = [
    kIOHIDVendorIDKey as String: targetVendorID,
    kIOHIDProductIDKey as String: targetProductID
]
IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
IOHIDManagerRegisterInputValueCallback(manager, hidInputCallback, nil)
IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatchedCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemovedCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    print("Fehler beim Öffnen des HID-Managers (Code \(openResult)).")
    print("Vermutlich fehlt die Freigabe unter Systemeinstellungen -> Datenschutz & Sicherheit -> Eingabeüberwachung.")
    exit(1)
}

print("Touchscreen-Treiber \(driverVersion) läuft (1 Finger = Zeiger/Klick, 2 Finger = Scroll oder Zoom).")
CFRunLoopRun()
