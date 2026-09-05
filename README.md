# gen-mac-touchscreen-driver

A driver for **USB touchscreens on macOS**, as a small menu bar app.

macOS ships no class driver that turns an external USB HID touchscreen
(HID usage page `0x0D` "Digitizer", usage `0x04` "Touch Screen") into
pointer and click events — unlike Windows, which has had its
"HID-compliant touch screen" driver since Windows 7/8. Such a panel happily
shows a picture on a Mac but does not react to touch at all.

This project reads the raw HID reports directly and synthesizes real macOS
events from them: pointer, click, drag, double click, right click, scrolling
and (approximated) zooming.

## Requirements

- macOS 13 or newer (developed and tested on macOS 26)
- A USB touchscreen that reports itself as a HID touch screen
- Xcode or the Command Line Tools, if you want to build it yourself

## Supported devices

The driver matches **any** USB device that identifies as a HID touch screen
(usage page `0x0D`, usage `0x04`) — not one particular model. Finger slots
are read from the HID report descriptor at runtime instead of being assumed,
and virtually all of these panels speak the standard "Windows Precision
Touch" report layout.

Graphics tablets live on the same usage page but report usage `0x02` (pen),
so they are not picked up. If several touch devices match, the driver binds
to the first one and ignores the rest.

**Developed and verified with:** a 7" IPS HDMI touchscreen kit of the
lcdwiki/LCD-show family (sold for the Raspberry Pi, but works on any
HDMI + USB host). Its controller, as reported by `dump-elements.swift`:

- Vendor `wch.cn`, USB ID `0x1a86:0xe2e3`, product name `USB2IIC_CTP_CONTROL`
- Multitouch in the standard "Windows Precision Touch" layout: 10 finger
  slots in the report, `Contact Count Maximum = 5`

Whether other panels work cleanly is **untested** for lack of hardware — but
nothing in the design is tailored to this model. `dump-elements.swift` prints
what a given device actually reports, which is the place to start if
something misbehaves.

## Installation

1. Build the app and the installer package:

   ```bash
   cd app
   ./build-app.sh
   ./build-pkg.sh
   ```

   See [Building](#building) for the code signing prerequisite — it matters
   more than it looks.

2. Install `app/build/Touchscreen-Treiber-<version>.pkg` via
   **right click → Open**. The package is unsigned, so a double click would
   be blocked by Gatekeeper.

3. On first launch macOS asks for two permissions
   (System Settings → Privacy & Security):

   - **Input Monitoring** — to read the raw HID reports
   - **Accessibility** — to post mouse and keyboard events

   Without Accessibility the driver still runs and still reads touches, but
   macOS discards every event it posts **silently**. The menu bar icon turns
   red in that case and the menu offers a shortcut to the right settings
   pane.

4. Enable **"Start at login"** in the menu if you want it to come back
   automatically after a reboot.

## Gestures

| Gesture | Result |
| --- | --- |
| One finger tap | Click |
| One finger drag | Drag |
| Double / triple tap | Double / triple click |
| Two finger tap | Right click |
| Two fingers dragged | Scroll |
| Two fingers pinched | Zoom (approximated, see below) |
| Three or more fingers | Ignored |

A few details that are less obvious than they look:

- **Double click needs `mouseEventClickState`.** Two separate clicks in quick
  succession are *not* recognized as a double click by macOS; the click count
  has to be set on the event itself. Without it you cannot open anything in
  Finder by double tapping. The window is the system double click interval
  (`NSEvent.doubleClickInterval`) plus a generous 25 px position tolerance,
  because a finger never hits the exact same spot twice.
- **Right click fires only once all fingers are up**, otherwise it would
  trigger halfway through lifting the second finger.
- **Scrolling accumulates fractions** instead of rounding them away, so slow
  drags do not lose motion.
- **A two finger gesture is classified once** — as either scroll or zoom —
  and keeps that classification until you let go. Deciding per frame makes a
  gesture flip back and forth, so a pinch would drag the page around while
  zooming.
- **Zoom is an approximation** via Cmd+Plus / Cmd+Minus, not a real system
  pinch. Real pinch gestures would require Apple's private, undocumented
  multitouch gesture API, which is deliberately avoided here: it can break
  with any macOS update, injecting into the HID event stream usually needs
  entitlements Apple only grants to its own binaries, and malformed events
  reach the window server rather than just this process. The consequence is
  that zoom only works in apps that support the Cmd+± shortcut themselves
  (Safari, Preview, Photos — **not** Finder, which has no such shortcut for
  icon size).

## Settings

Driver and interface run in the **same process**, so there is no config file
and nothing to reload: the menu writes to `UserDefaults` and the gesture
engine reads from it on every event. Changes take effect immediately.

The interface follows the system language (English and German are
included). The menu offers:

- **Status** — whether the driver runs and which device is connected
- **Target display** — automatic, or a specific display
- **Scrolling** — natural or classic, horizontal axis invertible
- **Sliders** for zoom sensitivity and click delay
- **Start at login** (`SMAppService`), verbose logging, reset settings,
  restart driver

### Target display

Touch coordinates are normalized (0…1) and mapped onto one display, so the
driver has to know which one. Selection order:

1. A display pinned in the menu. It is stored as its EDID identity
   (`vendor:model:serial`), which survives replugging, reboots and
   rearranging — unlike a display index, which shifts.
2. Automatic: the display that is *not* the main one. This is a fallback
   only, and it **aims at the wrong screen as soon as the touchscreen itself
   becomes the main display** — a failure mode that presents as "touch
   stopped working".

Geometry is re-resolved on every display change via
`CGDisplayRegisterReconfigurationCallback`, so the mapping does not go stale
after the first rearrangement. If the chosen display is absent, the driver
waits for it instead of quitting — the panel may simply not be plugged in
yet at login.

**Physical size is not usable for identification:** the reference panel
reports `469x259mm` (~21") over EDID although it is a 7" display. Cheap HDMI
panels routinely report generic nonsense there.

## Building

```bash
cd app
./build-app.sh    # builds and signs Touchscreen-Treiber.app
./build-pkg.sh    # wraps it into Touchscreen-Treiber-<version>.pkg
```

`build-app.sh` signs with a code signing identity from your keychain,
defaulting to the author's. Override it:

```bash
SIGN_IDENTITY="Your Identity" ./build-app.sh
```

### Why signing with your own certificate matters

macOS binds TCC permissions (Accessibility, Input Monitoring) to the
binary's *designated requirement*. With an **ad-hoc** signature
(`codesign -s -`) that requirement is the file hash:

```
designated => cdhash H"7ff6caf7f974d17196eb09e3fc46bad45a82313e"
```

So **every rebuild invalidates both permissions** — you have to delete the
entries in System Settings and grant them again, on every single code
change. With your own (self-signed) certificate the requirement is bound to
identifier plus certificate instead:

```
designated => identifier "de.aronax.touchscreen-driver" and
              certificate leaf = H"…"
```

Both stay stable across rebuilds, so the permissions survive. Verified by
rebuilding with a demonstrably different CDHash and confirming the grant
still held.

**Creating the certificate** (once — reliable only through the GUI; going
via `openssl` + `security import` fails, the certificate arrives but the
private key does not, so no usable identity is formed):

1. Keychain Access → menu **Keychain Access → Certificate Assistant →
   "Create a Certificate…"**
2. Name of your choice, identity type **Self Signed Root**, certificate type
   **Code Signing**, tick **"Let me override defaults"**
3. Validity e.g. 3650 days, serial number 1, key usage "Signature", extended
   key usage "Code Signing", keychain **login**

The certificate stays `CSSMERR_TP_NOT_TRUSTED` — macOS does not
automatically trust self-signed roots — and therefore does **not** show up
under `security find-identity -v -p codesigning`, though it does without
`-v`. `codesign` works with it regardless; nothing needs to be marked as
trusted.

### Packaging

The `.pkg` is **unsigned**. A Gatekeeper-accepted package would need a
"Developer ID Installer" certificate from Apple; a self-signed code signing
certificate is not enough. Install via right click → Open.

The `postinstall` script removes the old command line version (LaunchAgent)
and terminates a running instance of the app before starting the new one —
otherwise an update would leave two drivers running and every click would
land twice.

## Files

- `app/Sources/TouchEngine.swift` — the gesture engine (reads HID, posts
  events). The substance of the project.
- `app/Sources/AppDelegate.swift` — menu bar interface
- `app/Sources/Settings.swift` — settings in `UserDefaults`
- `app/Info.plist`, `app/build-app.sh`, `app/build-pkg.sh`,
  `app/pkg-scripts/postinstall` — bundle, build, packaging
- `dump-elements.swift` — diagnostic tool, lists all HID elements of the
  connected device (report IDs, cookies, usage pages, value ranges)
- `main.swift`, `de.aronax.touchscreen-driver.plist` — **obsolete**: the
  earlier command line version and its LaunchAgent, kept for reference. It
  is not maintained; everything above describes the app.
- `NOTES.de.md` — development log in German: how this came about, which
  decisions were made and which dead ends were hit

## Architecture

`TouchEngine.swift` uses `IOHIDManager` to match touch screen devices by
usage page and to receive raw `IOHIDValue` updates. The callbacks
(`hidInputCallback`, `hidDeviceMatchedCallback`, …) are **top level
functions without closure capture**, because `IOHIDValueCallback` is a C
function pointer; they reach global `var`s (`slots`, `mode`,
`cookieToSlotField`, …) instead. That is also why everything is built with
`-swift-version 5`: Swift 6 would treat those global accesses from a C
callback as a concurrency violation.

Per finger slot (up to 10, discovered from the HID report descriptor on
connect) X, Y and tip switch are tracked. A state machine decides, based on
the number of active fingers, whether a click, a scroll or a zoom goes out:

- `idle` — nothing active
- `single` — one finger: pointer, click, drag
- `twoFinger` — a gesture is running (classified once, see above)
- `suppressed` — fingers are still down, but no new gesture is started until
  *all* of them are lifted. Without this state, lifting one finger at the end
  of a two finger gesture triggers a phantom click, because the machine sees
  "one finger active" while `idle`.

The click of a single finger touch is **held back for 35 ms**: if a second
finger arrives within that window it was a gesture all along and no click is
emitted at all (two fingers never land at exactly the same moment). If the
finger lifts first — a quick tap — the click is emitted immediately, so there
is no perceptible latency.

On device removal (`IOHIDManagerRegisterDeviceRemovalCallback`) everything is
reset and a pending `leftMouseDown` is closed with a `leftMouseUp` —
otherwise the left mouse button would stay logically held down system-wide
if you unplug the cable mid-touch.

### Two device-level pitfalls worth knowing

**Keyboard layout for Cmd+±.** macOS resolves menu shortcuts through
`charactersIgnoringModifiers`, which is derived from the **physical key code
plus the current keyboard layout** — not from a character injected with
`keyboardSetUnicodeString()` (that only affects text input). A hardcoded US
key code for "+"/"-" hits the wrong key on, say, a German layout and the
zoom shortcut never fires. The driver therefore looks up the key that
produces "+" and "-" in the *current* layout at runtime, via `UCKeyTranslate`
and `TISCopyCurrentKeyboardLayoutInputSource`.

**Report order on touch down.** The reference controller sends X/Y
coordinates **before** the tip switch down report of the same touch.
Resetting "have X / have Y" flags on touch down — the obvious way to avoid
stale coordinates — therefore discards the fresh coordinates that just
arrived, before the activation check sees them, and touch never triggers at
all. The code keeps the flags sticky instead, which works with either order.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
