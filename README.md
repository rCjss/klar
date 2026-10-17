# Klar

**Flow state for you and your Mac.**

Minimalistische Menüleisten-App für macOS: Zwischenablage-Verlauf, Diktat mit Sprachbefehlen,
Meeting-Transkription mit Zusammenfassung, GIF-Suche, Bildschirmaufnahme mit Systemton und
„Cocaine“ zum Wachhalten. Schwarz-Weiß, viel Weißraum, keine Deko.

Aktuelle Version: 0.2.0 – siehe [CHANGELOG](CHANGELOG.md).

Klar ist ein privates Projekt und wird hier öffentlich und kostenlos bereitgestellt. Wenn dir die App gefällt, freue ich mich über einen ⭐ Stern für dieses Repository
oder ein Follow – das ist die Währung auf GitHub und hilft anderen, Klar zu finden.

## Haftungsausschluss

Klar wird „wie besehen“ („as is“) ohne jede Gewährleistung bereitgestellt (siehe [LICENSE](LICENSE), MIT).
Ich übernehme keine Haftung für Schäden, Datenverluste, Sicherheitslücken oder sonstige Folgen, die aus der
Nutzung, dem Bauen oder dem Verändern dieser Software entstehen. Die App greift auf Zwischenablage, Mikrofon,
Bildschirm und Tastatureingaben zu – prüfe den Quellcode selbst, bevor du ihr diese Freigaben erteilst.
Die Nutzung erfolgt auf eigenes Risiko. Sicherheitsrelevante Hinweise siehe unten unter
„Sicherheit und Datenabflüsse“; Meldungen zu Lücken sind als Issue willkommen.

## Funktionen

- **Zwischenablage-Verlauf** – Text, Bilder und Dateien, durchsuchbar, anpinnbar, per Tastatur einfügbar
- **Diktat** – Hotkey drücken, sprechen, Text landet in der aktiven App; lokal über Apple Speech
- **Sprachbefehle** – „Signatur“ sagen und ein Textbaustein wird eingefügt
- **Meetings** – Systemton („Andere“) und Mikrofon („Ich“) parallel transkribieren, danach Zusammenfassung
  über Apple Intelligence, Claude Code (Abo) oder die Claude-API
- **GIFs** – Giphy-Suche direkt im Panel, Einfügen als Datei
- **Bildschirmaufnahme** – mit Systemton, optional Mikrofon, als .mov in `~/Movies/Klar`
- **Cocaine** – hält Mac und Bildschirm wach wie Amphetamine: 15 Minuten bis 8 Stunden oder unbegrenzt, per Hotkey,
  Menü oder Fenster; während Meetings und Aufnahmen automatisch; Deckel-Modus für zugeklapptes Weiterlaufen

## Voraussetzungen

- macOS 14 oder neuer; Apple Intelligence, GIF-Vorschauen und die beste Spracherkennung brauchen macOS 26
- Apple-Silicon-Mac empfohlen

## Installation

### Variante A: Fertiges Archiv

1. Unter [Releases](../../releases) die neueste `Klar-x.y.z.zip` laden und entpacken.
2. `Klar.app` nach `/Programme` ziehen.
3. Die App ist nicht mit einem Apple-Entwicklerzertifikat signiert. macOS blockiert den ersten Start deshalb.
   Entweder Rechtsklick auf `Klar.app` → „Öffnen“ → „Öffnen“ bestätigen, oder im Terminal:

   ```
   xattr -d com.apple.quarantine /Applications/Klar.app
   ```

4. Klar erscheint als Kreis in der Menüleiste. Über das Menü „Einstellungen“ die Freigaben erteilen.

### Variante B: Selbst bauen (empfohlen)

Voraussetzung sind die Command Line Tools für Xcode 26 (Swift 6.3), kein Xcode nötig:

```
xcode-select --install
git clone https://github.com/rCjss/klar.git
cd klar
./sign-setup.sh      # einmalig: lokales Zertifikat, damit Freigaben Neubauten überleben
./build.sh --open    # bauen, nach /Applications installieren, starten
```

`sign-setup.sh` legt ein selbstsigniertes Zertifikat „Klar Dev“ im Anmelde-Schlüsselbund an; macOS fragt
dabei einmal nach dem Passwort. Ohne diesen Schritt wird ad hoc signiert, und macOS verlangt die Freigaben
nach jedem Neubau erneut.

## Berechtigungen

| Freigabe | Wofür |
|---|---|
| Bedienungshilfen | Einfügen per ⌘V in die aktive App, Einzeltasten-Hotkeys (z. B. rechte ⌘) |
| Mikrofon | Diktat, Meetings, optional Bildschirmaufnahme |
| Spracherkennung | Umwandlung in Text, läuft lokal auf dem Gerät |
| Bildschirmaufnahme | Systemton für Meetings, Videoaufnahmen |

Alle vier werden in Klar unter „Einstellungen → Berechtigungen“ angefragt. Ohne Bedienungshilfen landet
diktierter oder gewählter Text nur in der Zwischenablage.

## Tastenkürzel (Standard, änderbar)

| Funktion | Kürzel |
|---|---|
| Zwischenablage-Panel | ⇧⌘V |
| Diktat (tippen = Start/Stopp, halten = Push-to-Talk) | ⌥Space |
| Meeting transkribieren | ⌥⇧⌘M |
| Bildschirm aufnehmen | ⌥⇧⌘R |
| Cocaine an/aus | ⌥⇧⌘W |

Im Panel: ↑↓ wählen, ↩ einfügen, ⌘↩ nur kopieren, ⌘P oder Stecknadel anpinnen, ⌘⌫ löschen, ⌘1–9 Schnellwahl,
tippen = suchen. Klick auf einen Eintrag fügt ihn ein und rückt ihn nach oben. Angepinnte Einträge bleiben
über Neustarts erhalten. ↹ wechselt zum Reiter „GIFs“.

Als Diktat-Hotkey lässt sich auch eine einzelne Modifier-Taste festlegen, etwa die rechte ⌘-Taste.

## Sprachbefehle

In den Einstellungen Bausteine anlegen (z. B. „Signatur“). Dann entweder nur den Namen diktieren oder mitten
im Satz „einfügen Signatur“ sagen. „Neue Zeile“ und „neuer Absatz“ sind eingebaut.

## Zusammenfassungen

Nach einem Meeting entsteht automatisch eine Zusammenfassung (Kurzfassung, Themen, Entscheidungen, Aufgaben,
offene Fragen). Drei Wege, in den Einstellungen wählbar:

- **Claude Code** – nutzt die installierte Claude-Code-Kommandozeile und damit ein Claude-Abo, kein Schlüssel nötig
- **Claude-API** – eigener API-Schlüssel, wird im Schlüsselbund abgelegt
- **Apple Intelligence** – lokal, ohne Netz (macOS 26, Apple Intelligence aktiviert)

## Cocaine (wach halten)

Über das Menüleisten-Symbol → „Cocaine“ eine Dauer wählen, oder im Fenster unter „Cocaine“. Der Hotkey schaltet
unbegrenztes Wachhalten an und aus. Solange aktiv, zeigt die Menüleiste eine Sonne. Klar setzt dafür dieselben
Power-Assertions wie `caffeinate`, sichtbar mit `pmset -g assertions`.

**Deckel-Modus:** Ein zugeklapptes MacBook schläft normalerweise, außer es hängt an Netzteil und externem Bildschirm.
Der Schalter „Zugeklappt weiterlaufen“ hebt das auf (`pmset disablesleep 1`, wie Amphetamines Closed-Display Mode).
Das ist eine Systemeinstellung, deshalb fragt macOS beim Ein- und Ausschalten nach dem Administrator-Passwort.
Klar schaltet den Modus beim Beenden der Sitzung, nach Ablauf der Zeit und beim Beenden der App wieder ab.
Vorsicht: Ein zugeklappter, laufender Mac in der Tasche wird heiß.

## GIFs

Der Reiter „GIFs“ im Panel durchsucht Giphy. Dafür in den Einstellungen einen kostenlosen Schlüssel hinterlegen:
developers.giphy.com → „Create an App“ → API → Key kopieren.

## Daten

- Verlauf, Diktate, Transkripte, GIFs: `~/Library/Application Support/Klar/` (nur für den eigenen Benutzer lesbar)
- Aufnahmen: `~/Movies/Klar/`
- API-Schlüssel (Claude, Giphy): macOS-Schlüsselbund (Eintrag „Klar“ mit der Bundle-ID der App)

## Sicherheit und Datenabflüsse

Was das Gerät verlässt – und nur dann, wenn du die Funktion nutzt:

| Funktion | Empfänger | Inhalt |
|---|---|---|
| GIF-Suche | api.giphy.com | Suchbegriff, Giphy-Schlüssel |
| Zusammenfassung über Claude Code | Anthropic (über dein Abo) | Meeting-Transkript |
| Zusammenfassung über Claude-API | api.anthropic.com | Meeting-Transkript, API-Schlüssel |
| Zusammenfassung über Apple Intelligence | niemand (lokal) | – |
| Diktat, Transkription | niemand (lokal, Apple Speech) | – |

Alle Verbindungen laufen über HTTPS (App Transport Security ohne Ausnahmen). Klar hat kein URL-Schema,
keinen Update-Mechanismus, keine Telemetrie und keine offenen Ports.

Schutzmaßnahmen:

- Hardened Runtime: keine Code-Injektion per `DYLD_*`, keine fremden Bibliotheken. Wichtig, weil die App
  Bedienungshilfen, Mikrofon und Bildschirmaufnahme besitzt und sonst als Türöffner für andere Prozesse dienen könnte.
- Skript-Steuerung per DistributedNotification (Diktat/Panel auslösen) gibt es nur im Debug-Build.
- Kopien aus Passwortmanagern und der Schlüsselbundverwaltung werden nie aufgezeichnet; ebenso Inhalte mit
  den Markern `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`.
- Claude Code wird ohne Werkzeuge (`--tools ""`) und ohne Sitzungsspeicherung aufgerufen; ein Transkript kann
  dadurch keine Aktionen auslösen.
- Datendateien werden mit Rechten 0600 in Ordnern mit 0700 angelegt.
- Der Verlauf lässt sich jederzeit leeren („Verlauf leeren“), einzelne Einträge per ⌘⌫ löschen.

Bewusste Restrisiken:

- Verlauf, Diktate und Transkripte liegen unverschlüsselt im Benutzerordner. Jede App, die als dein Benutzer
  läuft, kann sie lesen (macOS-Apps ohne Sandbox können das generell). FileVault schützt sie im ausgeschalteten Zustand.
- Das Zertifikat „Klar Dev“ liegt im Anmelde-Schlüsselbund; `codesign` darf es ohne Rückfrage nutzen. Ein Programm,
  das bereits als dein Benutzer läuft, könnte sich damit als „Klar“ signieren und dessen Freigaben erben. Wer das
  ausschließen will, entfernt in `sign-setup.sh` das `-T /usr/bin/codesign` – dann fragt macOS bei jedem Build nach.
- Für Einzeltasten-Hotkeys beobachtet Klar global Tastendrücke, um ein Halten zu erkennen. Es speichert oder
  sendet dabei nichts; der Monitor existiert nur, wenn ein solcher Hotkey eingestellt ist.
- Das Release-Archiv ist ad hoc signiert, nicht notarisiert. Wer dem nicht trauen möchte, baut selbst (Variante B).

## Mitmachen

Issues und Pull Requests sind willkommen. Bitte beim Stil bleiben: Schwarz, Weiß, Weißraum, keine Deko.

## Lizenz

MIT – siehe [LICENSE](LICENSE).
