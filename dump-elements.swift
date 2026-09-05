// gen-mac-touchscreen-driver — HID diagnostic tool
// Copyright (C) 2026 Stefan Kriesel
// Licensed under the GNU General Public License v3.0, see LICENSE.
//
// Lists every HID element of the touch controller, to see what a device
// actually reports: report IDs, cookies, usage pages and value ranges — and
// whether multitouch (contact identifier / contact count / several finger
// collections) is reported at all.

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
