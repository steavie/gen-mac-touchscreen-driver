# touchscreen-driver

> **Ab Version 2.0 ist das eine Menüleisten-App** (`app/`), die den Treiber
> enthält. Die frühere reine Kommandozeilen-Version (`main.swift` im
> Wurzelverzeichnis, als LaunchAgent betrieben) bleibt als Referenz liegen,
> wird aber nicht mehr gepflegt. Aufbau und Hintergründe unten gelten für
> beide - die App-spezifischen Teile stehen im Abschnitt
> [Menüleisten-App](#menüleisten-app-ab-20).

macOS hat keinen eingebauten Treiber, der externe USB-HID-Touchscreens
(HID UsagePage `0x0D` "Digitizer", Usage `0x04` "Touch Screen") als
Zeiger/Klick interpretiert - anders als Windows. Dieses Tool liest die
rohen HID-Reports eines per HDMI+USB angeschlossenen 7"-Touchscreens direkt
aus und übersetzt sie in echte macOS-Events (Mausklick, Scroll, Zoom).

Eingerichtet am 04.09.2026 für ein Display, das über HDMI (Bild) und USB
(Touch) an einem Mac hängt und dessen Touch-Funktion macOS von sich aus
nicht erkannt hat.

## Hardware

7"-IPS-Touchscreen-Kit (baugleich mit den lcdwiki.com/LCD-show-Kits,
eigentlich für Raspberry Pi gedacht, funktioniert aber generisch an jedem
HDMI+USB-Host). Anleitung dazu liegt in Paperless unter dem Titel
"7 Inch Screen Case Assembly Instruction".

Touch-Controller laut `dump-elements.swift`:

- Vendor: `wch.cn`, USB-ID `0x1a86:0xe2e3`, Produktname `USB2IIC_CTP_CONTROL`
- Meldet Multitouch nach Standard-"Windows Precision Touch"-Layout:
  10 Finger-Slots im Report, `Contact Count Maximum = 5`

## Funktionsweise

- **1 Finger**: Zeiger bewegen + Klick + Ziehen (Mouse Down/Dragged/Up)
- **1 Finger, doppelt/dreifach getippt**: Doppel-/Dreifachklick. Dafür muss
  im CGEvent das Feld `mouseEventClickState` gesetzt werden - zwei einzelne
  Klicks hintereinander erkennt macOS **nicht** als Doppelklick, im Finder
  ließe sich sonst nichts per Doppeltipp öffnen. Maßstab ist das
  System-Doppelklick-Intervall (`NSEvent.doubleClickInterval`) plus eine
  großzügige Ortstoleranz (25px), weil ein Finger nie zweimal exakt
  dieselbe Stelle trifft.
- **2 Finger kurz aufgetippt** (ohne Scroll-/Zoom-Bewegung): **Rechtsklick**,
  wie das Zwei-Finger-Tippen auf dem Trackpad. Wird erst ausgelöst, wenn
  wirklich alle Finger weg sind - sonst käme er mitten im Abheben.
- **2 Finger, parallel bewegt**: Scrollen (`CGEventCreateScrollWheelEvent`,
  pixelgenau, mit Aufsammeln der Nachkommastellen, damit langsames Ziehen
  keine Bewegung verliert)
- **2 Finger, auseinander-/zusammenziehen (Pinch)**: Zoom-**Näherung** über
  Cmd+Plus / Cmd+Minus, nicht echtes System-Pinch. Echtes Pinch bräuchte
  Apples private/undokumentierte Multitouch-Gesten-API - bewusst nicht
  genutzt (Risiko: bricht jederzeit mit macOS-Updates). Cmd+±-Zoom
  funktioniert deshalb nur in Apps, die diesen Shortcut selbst unterstützen
  (Safari, Vorschau, Fotos - **nicht** Finder, der hat keinen Cmd+±-Shortcut
  für die Symbolgröße).
- 3+ Finger: werden ignoriert.

Die Art der Zwei-Finger-Geste (Scroll **oder** Zoom) wird zu Beginn einmal
festgelegt und bis zum Loslassen beibehalten - sonst wechselt eine Geste
laufend zwischen beidem hin und her und ein Pinch verschiebt nebenbei die
Seite.

### Ziel-Display

`--list` zeigt alle Displays samt fertiger Kennung zum Kopieren:

```
Gefundene Displays:
  [0] id=3 1920x1080 bei (0,0)  --display 4837:8448:20000080  (Hauptbildschirm)
  [1] id=1 3840x1620 bei (1920,0)  --display 4268:17167:842018892
```

Ausgewählt wird in dieser Reihenfolge:

1. **`--display <vendor:model:serial>`** - empfohlen. Die Kennung stammt aus
   der EDID des Displays und bleibt über Umstecken, Neustarts und Änderungen
   der Anordnung gleich. Genau so ist es in der LaunchAgent-Plist hinterlegt.
2. `--screen <index>` - der Index in obiger Liste. Achtung: **verschiebt
   sich**, sobald sich die Anordnung ändert.
3. Automatik: das Display, das nicht der Hauptbildschirm ist. Nur eine
   Notlösung - **sie greift daneben, sobald der Touchscreen selbst zum
   Hauptbildschirm gemacht wird** (dann zielt der Treiber auf den anderen
   Monitor und "der Touch geht nicht mehr").

Die Geometrie wird per `CGDisplayRegisterReconfigurationCallback` bei jeder
Änderung neu ermittelt, damit das Koordinaten-Mapping nicht nach dem ersten
Umstöpseln falsch bleibt. Ist das gewählte Display (noch) nicht da, wartet
der Treiber darauf, statt sich zu beenden - das Panel kann beim Login ja
schlicht noch nicht angesteckt sein.

**Nicht** brauchbar zur Erkennung ist die physische Größe: dieses Panel
meldet per EDID `469x259mm` (~21"), obwohl es ein 7"-Display ist. Billige
HDMI-Panels geben da oft generische Werte an.

Laufende Event-Ausgabe nur mit `--verbose`. Standardmäßig loggt der Treiber
nur Start und An-/Abstecken - er läuft dauerhaft, und eine Zeile pro
Scroll-Event würde das Log unbegrenzt wachsen lassen (launchd rotiert nicht).

### Scrollrichtung

Standard ist macOS-Verhalten ("natürliches Scrollen", der Inhalt folgt dem
Finger). Jede Achse lässt sich einzeln umdrehen:

- `--invert-y` - vertikal umdrehen (klassisches Windows-Verhalten)
- `--invert-x` - horizontal umdrehen

Bewusst als **Laufzeit-Flag** statt als Konstante im Code: ein Rebuild macht
die TCC-Freigaben ungültig (siehe unten), ein zusätzliches Argument in der
LaunchAgent-Plist nicht. Zum Ändern also das Flag in
`~/Library/LaunchAgents/de.aronax.touchscreen-driver.plist` unter
`ProgramArguments` ergänzen und den Dienst neu laden - ohne neu zu bauen.

### Wichtiger Stolperstein: Tastaturlayout bei Cmd+±

Menü-Shortcuts wie Cmd+Plus matcht macOS über den **physischen Tastencode +
aktuelles Tastaturlayout**, nicht über ein per `keyboardSetUnicodeString()`
gesetztes Zeichen (das wirkt nur für echte Text-Eingabe). Ein fest codierter
US-Tastencode für "+"/"-" trifft auf einem deutschen Layout die falsche
Taste und der Zoom-Shortcut feuert nie. Der Treiber ermittelt die richtige
Taste deshalb zur Laufzeit über die Carbon-Layout-API (`UCKeyTranslate` +
`TISCopyCurrentKeyboardLayoutInputSource`), sodass das layoutunabhängig
funktioniert.

### Zweiter Stolperstein: Report-Reihenfolge beim Touch-Down

Dieser Controller schickt X/Y-Koordinaten **vor** dem Tip-Switch-Down-Report
im selben Tastendruck. Ein "haveX/haveY beim Touch-Down zurücksetzen, um
alte Koordinaten zu vermeiden" (naheliegend, aber falsch für dieses Gerät)
verwirft dadurch die gerade erst eingetroffenen frischen Koordinaten wieder,
bevor die Aktivierungsprüfung sie sieht - Touch hätte dadurch nie ausgelöst.

## Menüleisten-App (ab 2.0)

Treiber und Oberfläche laufen im **selben Prozess**. Dadurch braucht es
keine Konfigurationsdatei und kein Nachladen: die Menü-Einträge schreiben in
`UserDefaults`, die Gesten-Engine liest bei jedem Ereignis direkt daraus -
Änderungen wirken sofort.

Im Menü:

- **Status**: ob der Treiber läuft und ob das Panel verbunden ist (grüner
  bzw. roter Punkt)
- **Warnung**, falls die Bedienungshilfen-Freigabe fehlt - in Rot, samt
  Verknüpfung in die Systemeinstellungen
- **Display**: Automatik oder festes Display (Liste aller angeschlossenen)
- **Scrollen**: natürlich / klassisch, horizontal umkehrbar
- **Regler** für Zoom-Empfindlichkeit und Klick-Verzögerung
- **Bei Anmeldung starten** (`SMAppService`), ausführliches Protokoll,
  Einstellungen zurücksetzen, Treiber neu starten

Das Menüleisten-Symbol ist im Normalfall ein Schablonenbild (passt sich
hell/dunkel an), im Fehlerfall bewusst **rot** - ein monochromes
durchgestrichenes Symbol übersieht man in der Menüleiste sonst leicht.

**Stolperstein:** Nicht jedes SF-Symbol existiert auf jeder macOS-Version.
`hand.tap.slash` gibt es hier z.B. nicht, `NSImage(systemSymbolName:)`
liefert dann `nil` - und ein Menüleisten-Symbol ohne Bild hat keine Breite
und ist damit **unsichtbar**. Deshalb probiert die App mehrere Symbolnamen
durch und fällt notfalls auf einen Text zurück.

Zum Prüfen der selten sichtbaren Warndarstellung gibt es einen versteckten
Schalter:

```bash
TSD_FORCE_WARN=1 /Applications/Touchscreen-Treiber.app/Contents/MacOS/TouchscreenDriver
```

### Bauen und paketieren

```bash
cd app
./build-app.sh    # baut und signiert Touchscreen-Treiber.app
./build-pkg.sh    # schnürt daraus Touchscreen-Treiber-<version>.pkg
```

Das Paket ist **unsigniert** - für ein von Gatekeeper akzeptiertes Paket
bräuchte es ein "Developer ID Installer"-Zertifikat von Apple, das
selbstsignierte Codesignatur-Zertifikat reicht dafür nicht. Zum Installieren
deshalb **Rechtsklick auf das Paket → Öffnen**, ein Doppelklick würde
blockiert.

Das `postinstall`-Skript räumt dabei die alte Kommandozeilen-Version ab
(LaunchAgent) und beendet eine eventuell laufende Instanz der App, bevor es
die neue startet - sonst liefen nach einem Update zwei Treiber gleichzeitig
und jeder Klick käme doppelt.

## Dateien

- `app/Sources/TouchEngine.swift` - die Gesten-Engine (HID lesen, Events
  erzeugen). Der inhaltliche Kern.
- `app/Sources/AppDelegate.swift` - Menüleisten-Oberfläche
- `app/Sources/Settings.swift` - Einstellungen in UserDefaults
- `app/Info.plist`, `app/build-app.sh`, `app/build-pkg.sh`,
  `app/pkg-scripts/postinstall` - Bundle, Bauen, Paketieren
- `main.swift` - **veraltet**: die frühere reine Kommandozeilen-Version,
  bleibt als Referenz liegen
- `dump-elements.swift` - Diagnose-Tool, listet alle HID-Elemente des
  Controllers auf (Report-IDs, Cookies, Usage Pages, Value-Ranges). Nützlich
  falls sich am Gerät oder der Zuordnung mal wieder was klären lässt.
- `de.aronax.touchscreen-driver.plist` - LaunchAgent-Config als Referenz
  (die tatsächlich aktive Version liegt unter
  `~/Library/LaunchAgents/de.aronax.touchscreen-driver.plist`)

## Build & Deploy (auf dem Mac mit dem Touchscreen)

```bash
swiftc -swift-version 5 -O main.swift -o touchscreen-driver \
  -framework Cocoa -framework IOKit
codesign -s "Aronax Local Codesign" --force \
  -i de.aronax.touchscreen-driver touchscreen-driver
```

`-swift-version 5` vermeidet Swift-6-Strict-Concurrency-Fehler bei den
globalen Variablen, die der C-Callback von IOHIDManager referenziert (siehe
unten, "Architektur").

Live läuft es unter `/Users/familie/touchscreen-driver/` als LaunchAgent
`de.aronax.touchscreen-driver` (RunAtLoad, KeepAlive, Logs unter
`~/Library/Logs/touchscreen-driver/`).

```bash
launchctl bootout gui/$(id -u)/de.aronax.touchscreen-driver
# neu bauen (s.o.), dann:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/de.aronax.touchscreen-driver.plist
```

### Freigaben (Systemeinstellungen -> Datenschutz & Sicherheit)

Nötig, jeweils für `touchscreen-driver`:

- **Eingabeüberwachung** - zum Lesen der rohen HID-Reports
- **Bedienungshilfen** - zum Senden von Maus-/Tastatur-Events

Beim allerersten Start (bzw. wenn die Einträge gelöscht wurden) fragt macOS
danach - `AXIsProcessTrustedWithOptions(prompt: true)` löst den Dialog beim
Programmstart aus. Bleibt die Bedienungshilfen-Freigabe aus, läuft der
Treiber trotzdem und liest auch Touch-Events, aber macOS verwirft alle
gesendeten Maus-/Tastatur-Events **stillschweigend** - er weist beim Start
im Log darauf hin.

### Warum die Signatur mit eigenem Zertifikat wichtig ist

macOS bindet TCC-Freigaben an das "Designated Requirement" der Binary. Bei
**ad-hoc**-Signatur (`codesign -s -`) ist das der Datei-Hash:

```
designated => cdhash H"7ff6caf7f974d17196eb09e3fc46bad45a82313e"
```

Damit macht **jeder Rebuild beide Freigaben ungültig** - man muss die
Einträge in den Systemeinstellungen löschen und neu bestätigen, bei jeder
Code-Änderung. Mit einem eigenen (selbstsignierten) Zertifikat hängt es
stattdessen an Identifier + Zertifikat:

```
designated => identifier "de.aronax.touchscreen-driver" and
              certificate leaf = H"fe19213beeec4cd918d13aa3bc9bccf82d9e00f7"
```

Beides bleibt über Rebuilds hinweg gleich, die Freigaben überleben also.
Verifiziert am 05.09.2026: Rebuild mit nachweislich geändertem CDHash
(`c3a46b…` → `094e1a9b…`), Freigabe blieb gültig.

**Zertifikat anlegen** (einmalig, nur über die GUI zuverlässig - der Weg
über `openssl` + `security import` scheitert daran, dass der private
Schlüssel nicht als Identität ankommt):

1. Schlüsselbundverwaltung → Menü **Schlüsselbundverwaltung →
   Zertifikatsassistent → "Zertifikat erstellen…"**
2. Name `Aronax Local Codesign`, Identitätstyp **Selbstsigniertes
   Root-Zertifikat**, Zertifikatstyp **Codesignatur**, Haken bei
   **"Standardwerte überschreiben"**
3. Gültigkeit z.B. 3650 Tage, Seriennummer 1, Schlüsselverwendung
   "Signatur", erweiterte Schlüsselverwendung "Codesignatur",
   Schlüsselbund **Anmeldung**

Das Zertifikat bleibt dabei `CSSMERR_TP_NOT_TRUSTED` (selbstsignierte Roots
vertraut macOS nicht automatisch) und taucht deshalb bei
`security find-identity -v -p codesigning` **nicht** auf - ohne `-v` schon.
Für `codesign` reicht das trotzdem, es muss nichts als vertrauenswürdig
markiert werden.

## Architektur (kurz)

`main.swift` nutzt `IOHIDManager`, um sich auf Vendor/Product-ID des
Controllers zu matchen und rohe `IOHIDValue`-Updates zu bekommen. Die
Callback-Funktionen (`hidInputCallback`, `hidDeviceMatchedCallback`) sind
**top-level Funktionen ohne Closure-Capture**, weil `IOHIDValueCallback` ein
C-Funktionszeiger ist - sie referenzieren stattdessen globale `var`s
(`slots`, `mode`, `cookieToSlotField`, ...). Deshalb auch `-swift-version 5`
beim Bauen: Swift 6 würde die globalen `var`-Zugriffe aus dem C-Callback
sonst als Concurrency-Verstoß werten.

Pro Finger-Slot (max. 10, dynamisch aus dem HID-Report-Descriptor beim
Verbinden ermittelt, siehe `hidDeviceMatchedCallback`) wird X/Y/Tip-Switch
getrackt. Ein Zustandsautomat (`GestureMode`) entscheidet je nach Anzahl
aktiver Finger, ob ein Klick, ein Scroll oder eine Zoom-Geste rausgeht:

- `idle` - nichts aktiv
- `single` - ein Finger, Zeiger/Klick/Ziehen
- `twoFinger` - Geste läuft (Art einmalig festgelegt, siehe oben)
- `suppressed` - Finger liegen noch auf, aber es wird keine neue Geste mehr
  begonnen, bis wirklich alle Finger weg sind. Ohne diesen Zustand löst
  jedes Heben eines einzelnen Fingers am Ende einer Zwei-Finger-Geste einen
  Phantom-Klick aus (der Automat sieht "1 Finger aktiv" bei `idle`).

Der Mausklick bei Ein-Finger-Berührung wird um 35ms zurückgehalten: kommt in
dieser Zeit ein zweiter Finger dazu, war es von Anfang an eine Geste und es
wird gar nicht geklickt (zwei Finger setzen nie exakt gleichzeitig auf).
Geht der Finger vorher wieder hoch (schneller Tap), wird der Klick sofort
nachgeholt - kostet also keine spürbare Latenz.

Beim Abziehen des Geräts (`IOHIDManagerRegisterDeviceRemovalCallback`) wird
alles zurückgesetzt und ein eventuell offener `leftMouseDown` mit einem
`leftMouseUp` geschlossen - sonst bliebe die linke Maustaste systemweit
"gedrückt" hängen, wenn man das Kabel mitten in einer Berührung zieht.
