// steavie-gen-mac-touchscreen-driver — application entry point
// Copyright (C) 2026 Stefan Kriesel
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See LICENSE for details.
//
// No storyboard, no window: LSUIElement in Info.plist keeps the app to a menu
// bar icon only (no Dock icon, no entry in the app switcher).

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
