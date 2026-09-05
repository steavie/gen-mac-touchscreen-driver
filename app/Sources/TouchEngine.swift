// gen-mac-touchscreen-driver — gesture engine
// Copyright (C) 2026 Stefan Kriesel
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See LICENSE for details.
//
// Reads the raw USB HID digitizer reports of a touch screen and synthesizes
// real macOS events from them.
//
// Background: macOS ships no class driver that interprets external USB HID
// touch screens (usage page 0x0D "Digitizer", usage 0x04 "Touch Screen") as
// pointer and click — unlike Windows.
//
//   1 finger        = pointer, click, drag, double/triple tap
//   2 fingers, tap  = right click
//   2 fingers, drag = a gesture, classified ONCE as either scroll or zoom
//                     and kept that way until released
//   3+ fingers      = ignored (suppressed until all fingers are lifted)
//
// The IOHIDManager and CoreGraphics callbacks are C function pointers and
// cannot capture anything. State and callbacks are therefore deliberately
// file-scope globals rather than wrapped in a class — and that is also why
// this is built with -swift-version 5 (Swift 6 would treat those global
// accesses from a C callback as a concurrency violation).

import Cocoa
import IOKit
import IOKit.hid
import ApplicationServices
import Carbon.HIToolbox

// Matches any USB HID device that identifies as a touch screen, not one
// particular model. Finger slots are read from the HID report descriptor at
// runtime rather than assumed, and virtually all of these panels speak the
// standard "Windows Precision Touch" layout.
//
// Graphics tablets live on the same usage page but report usage 0x02 (pen)
// instead of 0x04 (touch screen), so they are not picked up here.
//
// Developed and verified with: 7" HDMI panel of the lcdwiki/LCD-show family,
// controller "USB2IIC_CTP_CONTROL" (wch.cn, 0x1a86:0xe2e3), 5 contacts.
let digitizerUsagePage = 0x0D
let touchScreenUsage = 0x04

/// Shorthand for a localized user-facing string. English text doubles as the
/// key, so en.lproj is an identity mapping and de.lproj carries the German.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func vlog(_ message: @autoclosure () -> String) {
    if Settings.verboseLogging { NSLog("%@", message()) }
}

// MARK: - Displays

/// Stable identity of a physical display, taken from its EDID. Unlike the
/// CGDirectDisplayID and unlike the index in the display list, it survives
/// replugging, reboots and rearranging.
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
        "\(Int(bounds.width))×\(Int(bounds.height))" + (isMain ? " (" + L("main display") + ")" : "")
    }
}

func activeDisplays() -> [DisplayInfo] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { DisplayInfo(id: $0, bounds: CGDisplayBounds($0), key: DisplayKey($0)) }
}

/// Selection order: the EDID identity pinned in the settings, otherwise the
/// display that is not the main one. That fallback aims at the wrong screen
/// as soon as the touch screen itself becomes the main display.
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

/// Called at startup and on every display change (arrangement, resolution,
/// plugging). Without this the coordinate mapping would stay wrong after the
/// first rearrangement until the app is restarted.
func resolveTargetDisplay() {
    guard let target = pickTargetDisplay(activeDisplays()) else {
        if !haveTarget { targetDescription = L("not found") }
        return
    }
    targetBounds = target.bounds
    haveTarget = true
    targetDescription = target.label
    vlog("Target display: \(target.label) \(target.key)")
    TouchEngine.notifyStatusChanged()
}

// MARK: - State

struct TouchSlot {
    var down = false
    var x: Double = 0   // normalized 0..1
    var y: Double = 0
    var haveX = false
    var haveY = false
}

enum SlotField { case tip, x, y }

enum GestureMode {
    case idle          // nothing active
    case single        // exactly one finger: pointer/click
    case twoFinger     // a gesture is running
    case suppressed    // fingers still down, but do not start a new
                       // gesture until all of them are lifted
}

enum TwoFingerKind { case undecided, scroll, zoom }

var slots: [TouchSlot] = []
var slotXRange: [(min: CFIndex, max: CFIndex)] = []
var slotYRange: [(min: CFIndex, max: CFIndex)] = []
var cookieToSlotField: [IOHIDElementCookie: (slot: Int, field: SlotField)] = [:]

/// Since matching happens by usage page, several devices can qualify. We bind
/// to the first and ignore the rest: the finger slots are global and a second
/// device would overwrite them — and element cookies are assigned per device,
/// so they could collide between devices.
var boundDevice: IOHIDDevice? = nil
var boundDeviceName = "—"

var mode: GestureMode = .idle

// Single finger state
var singleSlot: Int? = nil
var singleDownPosted = false
var singleDownPoint = CGPoint.zero
var lastSinglePoint = CGPoint.zero
var pendingDownWork: DispatchWorkItem? = nil

// Click sequence (single/double/triple)
var lastClickTime: TimeInterval = 0
var lastClickPoint = CGPoint.zero
var currentClickState: Int64 = 1

// Two finger state
var pairSlots: [Int] = []
var twoKind: TwoFingerKind = .undecided
var gestureStartAvg = CGPoint.zero
var gestureStartSpread: Double = 0
var prevAvg = CGPoint.zero
var lastZoomSpread: Double = 0
var scrollRemainderX: Double = 0
var scrollRemainderY: Double = 0
var twoFingerStart: TimeInterval = 0
/// Set when a two finger touch ended without ever becoming a scroll or zoom
/// gesture — i.e. it was a two finger tap. The right click is only emitted
/// once all fingers are up, otherwise it would land halfway through lifting
/// the second finger.
var pendingRightClick: CGPoint? = nil

let eventSource = CGEventSource(stateID: .hidSystemState)

func mappedPoint(slot idx: Int) -> CGPoint {
    // Defensive: after a reconnect the slot list can change while an old
    // index is still around.
    guard slots.indices.contains(idx) else { return lastSinglePoint }
    let s = slots[idx]
    return CGPoint(
        x: targetBounds.origin.x + CGFloat(s.x) * targetBounds.width,
        y: targetBounds.origin.y + CGFloat(s.y) * targetBounds.height
    )
}

// MARK: - Emitting events

/// `clickState` is the position within a click sequence (1 = single,
/// 2 = double, 3 = triple). Without this field macOS does NOT recognize two
/// quick successive clicks as a double click — you could not, for instance,
/// open anything in Finder by double tapping.
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
    vlog("RIGHT CLICK \(point)")
}

/// Scrolls by pixels. Fractions are accumulated instead of rounded away,
/// otherwise slow drags keep losing motion.
func postScroll(dx: Double, dy: Double) {
    // Default is macOS behaviour: the content follows the finger. Y grows
    // downwards in Quartz coordinates, and the CGEvent scroll wheel axes each
    // point the opposite way.
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

// Real pinch-to-zoom would need private multitouch APIs (deliberately not
// used). Approximation: Cmd+Plus / Cmd+Minus, which many apps (Safari,
// Preview, Photos, browsers) support as a zoom shortcut — Finder does not,
// it has no such shortcut.
//
// Important: AppKit resolves menu shortcuts (NSMenuItem keyEquivalent
// matching) through "charactersIgnoringModifiers", which is derived from the
// PHYSICAL key code plus the current keyboard layout — NOT from a character
// set via keyboardSetUnicodeString() (that only affects text input, not
// shortcut matching). So the key that produces "+" or "-" in the CURRENT
// layout has to be looked up, rather than guessing a fixed US key code.
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

/// Looked up once and remembered — scanning every key code is not worth
/// repeating per zoom step. Changing the layout while running requires a
/// restart of the app.
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

// MARK: - Single finger logic

func cancelPendingDown() {
    pendingDownWork?.cancel()
    pendingDownWork = nil
}

/// Emits the held-back mouse click, either from the timer or pulled forward
/// when the finger lifts before it fires.
func commitSingleDown() {
    guard mode == .single, !singleDownPosted else { return }
    cancelPendingDown()
    singleDownPosted = true

    // Does this tap still belong to the previous click sequence (double or
    // triple tap)? The yardstick is the system double click interval plus a
    // generous position tolerance.
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
    // If the finger already moved during the delay, catch that up.
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

/// Ends a single finger touch. `click: false` discards a not-yet-emitted
/// click entirely (because it turned into a two finger gesture, or the device
/// was unplugged).
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

// MARK: - Two finger logic

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

/// When leaving a two finger touch, check whether it was a short tap (never
/// became scroll or zoom) — in that case a right click is due.
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
    let steps = min(Int(abs(delta) / step), 3)   // cap outliers
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

// MARK: - State machine

func activeValidSlots() -> [Int] {
    slots.indices.filter { slots[$0].down && slots[$0].haveX && slots[$0].haveY }
}

func processGestureState() {
    // Without a known target display every coordinate would be meaningless.
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
                // A different finger than the one that started the gesture.
                endSingle(click: true)
                mode = .suppressed
            }
        case .twoFinger:
            // One finger of a gesture was lifted: do NOT treat this as a
            // new click, wait until all fingers are really gone.
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
            // A second finger joined: the held-back click is discarded, this
            // was a gesture from the start.
            endSingle(click: false)
            beginTwoFinger(active: active, avg: avg, spread: spread)

        case .twoFinger:
            if active != pairSlots {
                // Different pair of fingers (e.g. a third came or went):
                // reset the baseline, otherwise there is a jump.
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
                // Classify the gesture ONCE and keep it until released —
                // otherwise a gesture keeps flipping between scrolling and
                // zooming.
                let moved = Double(hypot(avg.x - gestureStartAvg.x, avg.y - gestureStartAvg.y))
                let spreadChange = abs(spread - gestureStartSpread)
                if spreadChange > Settings.gestureDecideSpread && spreadChange > moved {
                    twoKind = .zoom
                    lastZoomSpread = gestureStartSpread
                    vlog("GESTURE: zoom")
                    updateZoom(spread: spread)
                } else if moved > Settings.gestureDecideMove {
                    twoKind = .scroll
                    vlog("GESTURE: scroll")
                    postScroll(dx: dx, dy: dy)
                }
            case .scroll:
                postScroll(dx: dx, dy: dy)
            case .zoom:
                updateZoom(spread: spread)
            }
        }

    default:
        // 3+ fingers are unsupported: end a running gesture cleanly and emit
        // nothing until everything is released. A third finger also turns a
        // two finger tap into something that is no longer a right click.
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
    // Only evaluate events from the bound device — cookies of other devices
    // could carry the same numbers and corrupt the slots.
    guard let bound = boundDevice, IOHIDElementGetDevice(element) === bound else { return }
    let cookie = IOHIDElementGetCookie(element)
    guard let mapping = cookieToSlotField[cookie] else { return }
    guard slots.indices.contains(mapping.slot) else { return }
    let raw = IOHIDValueGetIntegerValue(value)

    switch mapping.field {
    case .tip:
        // Careful: this controller sends X/Y BEFORE the tip-down report of
        // the same touch — do NOT reset haveX/haveY here, or the fresh
        // coordinates that just arrived get discarded before the activation
        // check ever sees them.
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

/// Aborts everything cleanly — important so that unplugging the cable
/// mid-touch does not leave the left mouse button stuck "down" system-wide.
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
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? L("Touch device")

    // Bind to the first matching device, ignore the rest.
    if let bound = boundDevice, bound !== device {
        NSLog("Ignoring additional touch device: %@", product)
        return
    }

    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
        return
    }

    resetEverything()
    boundDevice = device
    boundDeviceName = product
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
    NSLog("Touch device connected: %@ (%d finger slots)", product, slots.count)
    TouchEngine.notifyStatusChanged()
}

func hidDeviceRemovedCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                              sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    // Only react when it is really our bound device that disappears.
    guard let bound = boundDevice, bound === device else { return }
    resetEverything()
    boundDevice = nil
    boundDeviceName = "—"
    TouchEngine.panelConnected = false
    vlog("Touch device disconnected")
    TouchEngine.notifyStatusChanged()
}

func displayReconfigCallback(display: CGDirectDisplayID,
                             flags: CGDisplayChangeSummaryFlags,
                             userInfo: UnsafeMutableRawPointer?) {
    // Only react once the reconfiguration has completed.
    if flags.contains(.beginConfigurationFlag) { return }
    resolveTargetDisplay()
}

// MARK: - Control

enum TouchEngine {
    static var manager: IOHIDManager? = nil
    static var panelConnected = false
    static var onStatusChange: (() -> Void)? = nil

    static var isRunning: Bool { manager != nil }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static var targetDisplayLabel: String { targetDescription }

    /// Product name of the detected touch device, shown in the menu.
    static var deviceName: String { boundDeviceName }

    static func notifyStatusChanged() {
        DispatchQueue.main.async { onStatusChange?() }
    }

    static func start() {
        guard manager == nil else { return }

        resolveTargetDisplay()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: digitizerUsagePage,
            kIOHIDDeviceUsageKey as String: touchScreenUsage
        ]
        IOHIDManagerSetDeviceMatching(m, matchDict as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, hidInputCallback, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(m, hidDeviceMatchedCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, hidDeviceRemovedCallback, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            NSLog("Could not open the HID manager — is Input Monitoring permission missing?")
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
        boundDevice = nil
        boundDeviceName = "—"
        panelConnected = false
        notifyStatusChanged()
    }

    static func restart() {
        stop()
        start()
    }
}
