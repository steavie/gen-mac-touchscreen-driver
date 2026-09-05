// Einstiegspunkt der Menüleisten-App.
//
// Kein Storyboard, kein Fenster: LSUIElement in der Info.plist sorgt dafür,
// dass die App nur als Symbol in der Menüleiste erscheint (kein Dock-Symbol,
// kein Programmwechsler-Eintrag).

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
