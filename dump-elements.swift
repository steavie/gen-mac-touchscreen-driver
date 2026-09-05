// Einmaliges Diagnose-Tool: listet alle HID-Elemente des Touch-Controllers auf,
// um zu prüfen ob Multitouch (Contact Identifier / Contact Count / mehrere
// Finger-Collections) überhaupt gemeldet wird.

import Foundation
import IOKit
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matchDict: [String: Any] = [
    kIOHIDVendorIDKey as String: 0x1a86,
    kIOHIDProductIDKey as String: 0xe2e3
]
IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = deviceSet.first else {
    print("Kein passendes Gerät gefunden (angeschlossen?).")
    exit(1)
}

guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
    print("Keine Elemente lesbar.")
    exit(1)
}

print("Anzahl Elemente: \(elements.count)")
for e in elements {
    let page = IOHIDElementGetUsagePage(e)
    let usage = IOHIDElementGetUsage(e)
    let min = IOHIDElementGetLogicalMin(e)
    let max = IOHIDElementGetLogicalMax(e)
    let reportID = IOHIDElementGetReportID(e)
    let cookie = IOHIDElementGetCookie(e)
    print(String(format: "reportID=%2d cookie=%3d usagePage=0x%02x usage=0x%02x range=[%ld..%ld]", reportID, cookie, page, usage, min, max))
}
