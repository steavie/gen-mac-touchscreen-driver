# Entwicklungsnotizen (deutsch)

> Development log, kept in German. The project documentation is in
> English — see [README.md](README.md). This file records how the
> project came about, which decisions were made and which dead ends
> were hit; it is a diary, not a specification.


Entstehungsgeschichte, Entscheidungen und offene Punkte zu diesem Projekt -
für den technischen Aufbau siehe `README.md`.

## Ausgangslage

04.09.2026: An einem Mac hängt ein 7"-Display per HDMI (Bild) + USB
(Touch). Bild funktionierte sofort, Touch wurde von macOS nicht erkannt.
Anleitung des Displays lag in Paperless ("7 Inch Screen Case Assembly
Instruction", Dokument-ID 159) - eigentlich für Raspberry Pi gedacht, ohne
jeden Hinweis auf macOS.

## Diagnose

Per `ioreg`/`hidutil` geprüft, ob das Gerät auf USB-/HID-Ebene überhaupt
sauber ankommt:

- USB-Verbindung und Treiberkette bis `IOHIDEventServiceUserClient` waren
  einwandfrei - kein Kabel-/Erkennungsproblem
- `hidutil list` zeigte: `UsagePage 13 (Digitizer), Usage 4 (Touch Screen)`
  - also ein korrekt gemeldetes Touch-Digitizer-Gerät

**Kernbefund:** macOS hat schlicht keinen eingebauten Klassentreiber, der
externe USB-HID-Touchscreens automatisch in Zeiger-/Klick-Events übersetzt
- anders als Windows (dort gibt es seit Win7/8 den "HID-compliant touch
screen"-Klassentreiber). Deshalb bewusste Entscheidung: eigenen kleinen
Treiber (Userspace-Daemon) schreiben, der genau das übernimmt.

## Grundsatzentscheidungen

- **Sprache/Technik:** Swift-Daemon mit `IOHIDManager` (roher HID-Zugriff)
  + `CGEventPost` (synthetische Maus-/Tastatur-Events), statt Python o.ä. -
  nativ, keine externen Abhängigkeiten.
- **Kein echtes System-Pinch:** Bewusst keine privaten/undokumentierten
  Multitouch-Gesten-APIs (Apples `MultitouchSupport.framework`) genutzt,
  obwohl damit "echtes" Pinch/Rotate möglich wäre. Begründung: nicht
  dokumentiert, kann mit jedem macOS-Update brechen, hoher Aufwand für
  unsicheren Nutzen. Stattdessen bewusste Näherungen mit stabilen,
  öffentlichen APIs (Scroll-Events, Tastatur-Shortcuts).
- **Autostart:** LaunchAgent statt manuellem Start - läuft dauerhaft im
  Hintergrund bei jedem Login.
- **Ad-hoc-Signatur statt echtem Zertifikat:** Kein Apple-Entwicklerkonto
  vorhanden. Versuch, ein lokales selbst-signiertes Code-Signing-Zertifikat
  einzurichten (damit TCC-Freigaben Rebuilds überleben), ist an einem
  PKCS#12-Kompatibilitätsproblem zwischen OpenSSL 3.x und macOS Keychain
  gescheitert (Zertifikat kam an, privater Schlüssel nicht - auch mit
  `-legacy`-Exportflag nicht zuverlässig lösbar über die reine CLI). Für
  jetzt akzeptiert: ad-hoc-Signatur, mit der Konsequenz, dass nach jedem
  Rebuild beide TCC-Freigaben (Bedienungshilfen, Eingabeüberwachung) manuell
  neu erteilt werden müssen (siehe README, Abschnitt "Freigaben").

## Namensgebung

Erste Version hieß `touch-bridge` - auf Wunsch umbenannt zu
`touchscreen-driver`, weil "bridge" in der Bedienungshilfen-Freigabeliste
für Laien nichts über die Funktion aussagt. Reverse-DNS-Schema
`de.aronax.*` beibehalten (passt zum Rest des Homelabs, siehe zentrales
`homelab`-Repo).

## Multitouch-Fähigkeit der Hardware

Per `dump-elements.swift` (eigens für diese Diagnose geschrieben) ermittelt:

- Controller `USB2IIC_CTP_CONTROL` (Vendor `wch.cn`, USB-ID `1a86:e2e3`)
- Meldet HID-Reports im Standard-"Windows Precision Touch"-Layout: 10
  Finger-Slots im Report (je Tip-Switch/Contact-ID/X/Y/Width),
  `Contact Count Maximum = 5`
- Damit war klar: echtes Multitouch ist auslesbar, nur die Interpretation
  auf macOS-Seite fehlt (siehe oben, Grundsatzentscheidung gegen private
  APIs für die Geste selbst).

## Funktionsumfang (finale Entscheidung des Nutzers)

Zur Wahl standen: (a) nur Ein-Finger-Zeiger/Klick, (b) zusätzlich
Zwei-Finger-Scroll, (c) zusätzlich eine Pinch-Zoom-Näherung über öffentliche
APIs, (d) echte Trackpad-Gesten über private APIs. Gewählt: **(c)** - Scroll
+ Zoom-Näherung, echte private Gesten-APIs bewusst ausgeschlossen.

## Bugs während der Entwicklung (chronologisch, mit Ursache)

1. **Kein einziger Klick kam an, trotz korrekt gelesener Rohdaten.**
   Ursache: `haveX`/`haveY`-Flags wurden beim Tip-Switch-Down absichtlich
   zurückgesetzt, um veraltete Koordinaten von einer vorherigen Berührung
   auszuschließen - nachvollziehbare Annahme, aber falsch für dieses Gerät:
   Es schickt X/Y **vor** dem Tip-Switch-Down-Report im selben Tastendruck.
   Der Reset hat dadurch die gerade erst eingetroffenen, echten Koordinaten
   sofort wieder verworfen. Fix: Reset entfernt.
2. **Bedienungshilfen-Freigabe wirkungslos nach jedem Rebuild.** Ursache:
   ad-hoc-Signatur bindet TCC an den Datei-Hash (siehe oben, Abschnitt
   "Ad-hoc-Signatur"). Workaround etabliert: Eintrag in den
   Datenschutzeinstellungen komplett entfernen (nicht nur Haken raus), dann
   Dienst neu starten - `AXIsProcessTrustedWithOptions(prompt: true)` beim
   Programmstart löst dann zuverlässig einen frischen Dialog aus.
3. **Pinch-Zoom-Näherung über "Option+Scroll" wirkungslos.** Ursache: das
   war schlicht eine falsche Annahme - Option+Scroll ist keine allgemeine
   App-Zoom-Konvention, sondern (nur wenn in den Bedienungshilfen aktiviert)
   der macOS-**System**-Bildschirm-Zoom, standardmäßig sogar an Control statt
   Option gebunden. Verworfen zugunsten von Cmd+Plus/Minus (Näherung 2).
4. **Cmd+Plus/Minus-Näherung wirkungslos trotz Cmd+Plus manuell an der
   echten Tastatur nachweislich funktionierend.** Ursache: erst mit
   festem US-Tastencode (`0x18`/`0x1B`) versucht - falsch auf dem deutschen
   Layout des Nutzers. Danach mit `keyboardSetUnicodeString()` versucht,
   das gewünschte Zeichen direkt zu injizieren - ebenfalls wirkungslos, weil
   AppKit Menü-Shortcuts (`NSMenuItem`-`keyEquivalent`-Matching) über
   `charactersIgnoringModifiers` auflöst, was aus dem **physischen
   Tastencode + aktuellem Layout** berechnet wird, nicht aus einem
   nachträglich gesetzten Zeichen. Endgültiger Fix: zur Laufzeit per Carbon
   (`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`) den
   tatsächlich richtigen Tastencode für "+"/"-" im aktuell aktiven Layout
   ermitteln - funktioniert dadurch unabhängig vom Tastaturlayout.

## Review-Runde (04.09.2026, nach der ersten funktionierenden Version)

Code nochmal kritisch durchgesehen, dabei fünf echte Bugs und vier
Qualitätsprobleme gefunden und in **einem** Rebuild behoben (jeder Rebuild
kostet eine neue TCC-Freigabe, siehe unten - deshalb gebündelt):

Bugs:

1. **Hängende Maustaste beim Abziehen des Kabels.** Es gab keinen
   Device-Removal-Callback. Wurde das USB-Kabel gezogen, während ein Finger
   auflag, blieb der `leftMouseDown` ohne passendes `leftMouseUp` stehen -
   die linke Maustaste galt danach systemweit als gedrückt. Fix:
   `IOHIDManagerRegisterDeviceRemovalCallback` + sauberes Zurücksetzen.
2. **Phantom-Klick nach jeder Zwei-Finger-Geste.** Wird ein Finger minimal
   früher gehoben als der andere, sah der Automat "1 Finger aktiv" bei
   `mode == .idle` und löste einen echten Klick aus. Fix: neuer Zustand
   `suppressed` - nach einer Geste wird erst wieder etwas ausgelöst, wenn
   wirklich alle Finger weg sind.
3. **Phantom-Klick vor jeder Zwei-Finger-Geste** (war als offener Punkt
   notiert). Fix: der Mausklick wird bei Ein-Finger-Berührung 35ms
   zurückgehalten; kommt in der Zeit ein zweiter Finger, wird gar nicht
   geklickt. Schneller Tap holt den Klick sofort nach, kostet also keine
   spürbare Latenz.
4. **Absturzrisiko bei Neuverbindung.** `endSingleIfNeeded()` griff über
   einen gespeicherten Slot-Index auf `slots[...]` zu; wird das Gerät neu
   erkannt (Slot-Liste wird neu aufgebaut), war der Index ungültig →
   Index-out-of-range. Fix: letzter Punkt wird gemerkt statt neu berechnet,
   plus Bounds-Checks.
5. **Sprung bei wechselndem Fingerpaar.** Wechselt das aktive Paar (z.B.
   {0,1} → {0,2}, wenn ein dritter Finger dazukommt/geht), blieb die alte
   Basislinie stehen → ein einzelner riesiger Scroll-/Zoom-Sprung. Fix:
   Basislinie wird bei Paarwechsel neu gesetzt.

Qualität:

6. **Log wuchs unbegrenzt** - eine Zeile pro Scroll-Event bei einem
   dauerhaft laufenden LaunchAgent, ohne Rotation durch launchd. Fix:
   laufende Ausgabe nur noch mit `--verbose`, im Normalbetrieb werden nur
   Start und An-/Abstecken geloggt. Die Debug-Reste (`raw#…`-Zähler,
   30 Zeilen Cookie-Mapping bei jedem Verbinden) sind mit hinter das Flag
   gewandert.
7. **Scroll und Zoom flippten innerhalb einer Geste hin und her** (im Log
   gut sichtbar: `ZOOM-IN, SCROLL, ZOOM-IN, SCROLL…`), weil pro Tick neu
   entschieden wurde - ein Pinch verschob dadurch nebenbei die Seite. Fix:
   Gestenart wird zu Beginn einmal festgelegt (Schwellen: 12px
   Abstandsänderung für Zoom, 8px Bewegung für Scroll) und bis zum
   Loslassen beibehalten.
8. **Zoom feuerte stoßweise.** Statt pro Tick bei überschrittener Schwelle
   wird die Abstandsänderung jetzt aufsummiert und pro 35px genau ein
   Zoom-Schritt gesendet (max. 3 pro Tick, um Ausreißer zu deckeln).
9. **Langsames Scrollen verlor Bewegung**, weil `Int32(dx.rounded())` alles
   unter 0,5px pro Tick verwarf. Fix: Nachkommastellen werden aufgesammelt.
10. **Display-Geometrie wurde nur beim Start gelesen** - nach Änderung von
    Anordnung/Auflösung oder Umstecken stimmte das Koordinaten-Mapping bis
    zum Neustart nicht mehr. Fix:
    `CGDisplayRegisterReconfigurationCallback`, Ziel-Display wird bei jeder
    Änderung neu aufgelöst.

## Zertifikat gelöst + Funktionslücken geschlossen (05.09.2026)

**Signatur-Problem gelöst.** Das lokale Code-Signing-Zertifikat wurde über
Schlüsselbundverwaltung → Zertifikatsassistent angelegt (`Aronax Local
Codesign`) - der CLI-Weg über `openssl` + `security import` war ja
gescheitert, weil dabei nur das Zertifikat, nicht aber der private Schlüssel
als Identität ankam. Über die GUI klappt es auf Anhieb.

Kurios, aber unkritisch: Das Zertifikat bleibt `CSSMERR_TP_NOT_TRUSTED`
(selbstsignierte Roots vertraut macOS nicht automatisch) und taucht deshalb
bei `security find-identity -v -p codesigning` nicht auf - ohne `-v` schon.
`codesign` signiert damit trotzdem problemlos, es musste nichts als
vertrauenswürdig markiert werden.

Wirkung nachgemessen statt geglaubt: Rebuild mit nachweislich geändertem
CDHash (`c3a46b…` → `094e1a9b…`), Designated Requirement unverändert, und
die Bedienungshilfen-Freigabe blieb gültig. Damit kosten Code-Änderungen ab
jetzt keine Freigabe-Prozedur mehr - das war vorher die eigentliche Bremse
beim Weiterentwickeln.

**Zwei Funktionslücken geschlossen (v1.2):**

- **Doppeltipp funktionierte nicht.** Zwei einzelne Klicks hintereinander
  erkennt macOS nicht als Doppelklick - dafür muss im CGEvent das Feld
  `mouseEventClickState` auf 2 (bzw. 3) gesetzt werden. Ohne das ließ sich
  im Finder nichts per Doppeltipp öffnen. Ortstoleranz bewusst großzügig
  (25px), weil ein Finger nie zweimal exakt dieselbe Stelle trifft.
- **Kein Rechtsklick möglich.** Jetzt per **Zwei-Finger-Tipp** (kurz
  auftippen, ohne dass daraus eine Scroll-/Zoom-Geste wird), analog zum
  Trackpad. Wird bewusst erst ausgelöst, wenn alle Finger weg sind, sonst
  käme er mitten im Abheben des zweiten Fingers.

## Ziel-Display-Erkennung repariert (05.09.2026, v1.3)

Direkt nach v1.2 gemeldet: "der Touch geht nicht mehr". Naheliegender
Verdacht war die Freigabe (die vorher ja ständig kaputtging) - war es aber
nicht: Prozess lief, keine Warnung im Log, `AXIsProcessTrusted` war true.

Tatsächliche Ursache: **die Display-Anordnung hatte sich geändert und der
Touchscreen war zum Hauptbildschirm geworden.** Die Automatik "nimm das
Display, das nicht der Hauptbildschirm ist" zielte damit auf den großen
Monitor - die Berührungen bewegten den Zeiger also auf dem falschen
Bildschirm.

Lehre daraus: sowohl die Automatik als auch `--screen <index>` sind fragil,
weil sich beides mit der Anordnung ändert (die Indizes hatten in dem Moment
tatsächlich getauscht: id=1 war vorher [0], danach [1]).

Zwischenschritt, der sich nicht bewährt hat: das Panel über seine
**physische Größe** zu erkennen (ein 7"-Display sollte ja unverwechselbar
klein sein). Messung mit `CGDisplayScreenSize` widerlegte das sofort - das
Panel meldet `469x259mm` (~21"), also generische Fantasiewerte, wie bei
billigen HDMI-Panels üblich. Gut, dass gemessen und nicht darauf gebaut
wurde.

Lösung: Auswahl über die **EDID-Kennung** `vendor:model:serial`
(`CGDisplayVendorNumber` / `-ModelNumber` / `-SerialNumber`), die über
Umstecken und Umsortieren stabil bleibt. Beide Displays haben hier
eindeutige Werte:

- Touchscreen: `4837:8448:20000080`
- großer Monitor: `4268:17167:842018892`

Der Touchscreen ist jetzt per `--display 4837:8448:20000080` fest in der
LaunchAgent-Plist verdrahtet. `--list` gibt die Kennungen fertig zum
Kopieren aus. Zusätzlich beendet sich der Treiber nicht mehr, wenn das
Ziel-Display fehlt, sondern wartet darauf (das Panel kann beim Login noch
nicht angesteckt sein).

## Umbau zur Menüleisten-App + Installer (05.09.2026, v2.0)

Auf Wunsch: Installer und eine kleine App zum Einstellen. Zwei
Entscheidungen vorab getroffen (Auswahl durch den Nutzer):

- **Menüleisten-App mit integriertem Treiber** statt getrenntem Daemon plus
  Einstellungsfenster. Nebeneffekt, der die Sache deutlich vereinfacht: da
  Treiber und Oberfläche im selben Prozess laufen, braucht es keine
  Konfigurationsdatei, kein Dateiwächter, kein Nachladen - die Engine liest
  einfach bei jedem Ereignis aus `UserDefaults`.
- **.pkg-Installationspaket** statt Shell-Skript.

Der LaunchAgent entfällt; Autostart läuft jetzt über `SMAppService`
("Bei Anmeldung starten" im Menü).

**Bundle-Identifier bewusst gleich gelassen** (`de.aronax.touchscreen-driver`
wie der Signatur-Identifier der CLI-Version), damit das Designated
Requirement identisch bleibt und erteilte Freigaben möglichst weitergelten.
Hat in der Praxis nur teilweise geklappt - der Nutzer musste zwei Freigaben
neu erteilen.

**Zwei Fehler dabei, beide derselben Sorte** (etwas schlägt still fehl):

1. **Menüleisten-Symbol war unsichtbar.** Für den Zustand "Freigabe fehlt"
   hatte ich `hand.tap.slash` verwendet - das SF-Symbol gibt es auf diesem
   macOS gar nicht. `NSImage(systemSymbolName:)` liefert dann `nil`, und ein
   Menüleisten-Symbol ohne Bild hat keine Breite, ist also unsichtbar. Fix:
   mehrere Symbolnamen durchprobieren, notfalls Textfallback - ein
   Statussymbol darf nie verschwinden können.
2. **Statuszeilen waren grau.** Sie hatten keine Aktion und wurden deshalb
   von der automatischen Menü-Aktivierung ausgegraut. Fix:
   `menu.autoenablesItems = false` und farbige Punkte (grün/rot) über
   `attributedTitle`.

Auf Wunsch wurde die Warndarstellung zusätzlich **rot** eingefärbt (vorher
nur ein monochromes durchgestrichenes Symbol, das man leicht übersieht).
Weil dieser Zustand im Normalbetrieb selten auftritt, gibt es dafür einen
versteckten Testschalter `TSD_FORCE_WARN=1`; beide Zustände wurden per
Bildschirmfoto der Menüleiste tatsächlich geprüft statt nur angenommen.

Das `postinstall`-Skript des Pakets räumt die alte CLI-Version ab und
beendet eine laufende Instanz der App, bevor es die neue startet - sonst
liefen nach einem Update zwei Treiber gleichzeitig und jeder Klick käme
doppelt.

## Installer startete die App nicht (05.09.2026, v2.3)

Nach der Installation von v2.2 lief gar nichts mehr: Paket sauber
installiert, richtige Version in `/Programme`, aber **kein Prozess**. Manuell
gestartet lief die App tadellos.

Ursache im Installationsprotokoll gefunden:

```
19:30:09  Executing script "postinstall"        <- Startversuch
19:30:14  Registered bundle ... for uid 501     <- erst jetzt kennt
                                                   LaunchServices die App
```

Das `postinstall`-Skript läuft, **bevor** der Installer das Bundle fertig
registriert hat - `open -a` griff also ins Leere. Verschärft dadurch, dass
der Aufruf als `... 2>/dev/null || true` geschrieben war: Der Fehlschlag war
vollständig unsichtbar, das Paket meldete Erfolg, der Treiber war weg.

Zwei Lehren, beide von der Sorte, die in diesem Projekt immer wieder
auftaucht:

1. Fehler nicht wegwerfen. `2>/dev/null || true` an einer Stelle, die etwas
   Wichtiges tut, ist eine Falle - PackageKit hätte die Ausgabe brav ins
   Installationsprotokoll geschrieben.
2. Nicht annehmen, dass unmittelbar nach dem Kopieren alles bereit ist. Der
   Start wird jetzt bis zu zehnmal über rund 20 Sekunden versucht, im
   Hintergrund, damit der Installer nicht wartet. Die App erscheint dadurch
   ein paar Sekunden nach der Installation - das ist beabsichtigt.

## Status (Stand 05.09.2026, v1.3)

Alles vom Nutzer bestätigt:

- Ein-Finger: Zeiger, Klick, Ziehen
- Doppel-/Dreifachtipp
- Zwei-Finger-Tipp = Rechtsklick
- Zwei-Finger-Scroll (Richtung macOS-konform, Inhalt folgt dem Finger)
- Zwei-Finger-Pinch-Zoom-Näherung (Cmd+±) - wirkt nur in Apps, die diesen
  Shortcut unterstützen, siehe README
- Ziel-Display fest per EDID-Kennung, unabhängig von Anordnung und
  Hauptbildschirm
- Läuft als LaunchAgent, startet automatisch bei Login
- Signiert mit lokalem Zertifikat: Rebuilds kosten keine neue Freigabe mehr

## Offene Punkte / mögliche nächste Schritte

- 3+ Finger werden aktuell komplett ignoriert (keine Anforderung dafür
  geäußert).
- **Feintuning der Gesten-Schwellen** (`singleTouchDelay`,
  `gestureDecideMove`, `gestureDecideSpread`, `zoomStepPixels`, ganz oben in
  `main.swift`) beruht auf plausiblen Startwerten, nicht auf systematischem
  Ausprobieren. Falls sich Scrollen/Zoomen zu träge oder zu hektisch
  anfühlt, sind das die Stellschrauben.
- **Zoom-Richtung bei "natural scrolling"**: Die Scroll-Vorzeichen wurden
  einmal festgelegt und für gut befunden, aber nicht gegen die
  Systemeinstellung "Scrollrichtung: natürlich" gegengeprüft. Wird die
  umgestellt, dreht sich die Scrollrichtung vermutlich mit.
