# Klar für Windows

**Flow state for you and your PC.**

Die Windows-Fassung von [Klar](../README.md): Zwischenablage-Verlauf, Diktat mit Sprachbefehlen,
Meeting-Transkription mit Zusammenfassung, GIF-Suche, Bildschirmaufnahme mit Systemton und
„Cocaine“ zum Wachhalten. Gleicher Funktionsumfang und gleiches Aussehen wie auf dem Mac –
Schwarz-Weiß, viel Weißraum, keine Deko. Klar sitzt als Kreis im Infobereich der Taskleiste.

Die Mac-App ist reines Swift mit Apple-Frameworks und lässt sich nicht für Windows übersetzen.
Diese Fassung ist deshalb eine eigene Umsetzung in C# (.NET 10, WPF).

## Stand

Entwickelt und übersetzt auf einem Mac. Die gemeinsame Logik (Verlauf, Sprachbefehle, Audio-Aufbereitung,
Abschnittserkennung, Whisper-Anbindung, Zusammenfassung) ist dort mit Tests abgedeckt, inklusive eines echten
Erkennungslaufs. Oberfläche und Systemanbindung lassen sich nur unter Windows ausführen. Dafür gibt es einen
eingebauten Selbsttest, siehe unten.

Der GitHub-Workflow führt diesen Selbsttest bei jeder Änderung auf einem Windows-Rechner aus. Dort bestanden:
Start, alle Fenster, Tastenkürzel, Zwischenablage, Infobereich-Symbol, Anmeldeinformationen und die
Spracherkennung mit Whisper. Mikrofon, Systemton und Bildschirmaufnahme kann der Rechner von GitHub nicht prüfen,
weil er weder Soundkarte noch Bildschirm hat. Diese drei sind noch auf keinem echten PC erprobt.

## Voraussetzungen

- Windows 10 (ab 1903) oder Windows 11, 64 Bit
- Für Diktat, Meetings und Bildschirmaufnahme: die [Microsoft-Visual-C++-Laufzeit](https://aka.ms/vs/17/release/vc_redist.x64.exe).
  Sie ist auf den meisten PCs schon vorhanden; Pakete aus dem GitHub-Workflow bringen sie mit.
- Für die Spracherkennung einmalig 60 bis 574 MB Download (Sprachmodell, je nach gewählter Genauigkeit)

## Installation

1. `Klar-x.y.z-win-x64.zip` entpacken, zum Beispiel nach `%LocalAppData%\Programs\Klar`.
2. `Klar.exe` starten. Die App ist nicht signiert; Windows SmartScreen meldet deshalb beim ersten Start
   „Der Computer wurde durch Windows geschützt“. Über „Weitere Informationen“ → „Trotzdem ausführen“ geht es weiter.
3. Beim ersten Start öffnen sich die Einstellungen. Dort unter „Spracherkennung“ das Sprachmodell laden
   und unter „Allgemein“ bei Bedarf „Beim Anmelden starten“ einschalten.

Ein Installationsprogramm gibt es nicht. Zum Entfernen den Ordner löschen; Daten liegen unter `%AppData%\Klar`.

## Selbst bauen

Unter Windows (PowerShell), Voraussetzung ist das .NET-10-SDK (`winget install Microsoft.DotNet.SDK.10`):

```
git clone https://github.com/rCjss/klar.git
cd klar\windows
.\build.ps1 -SelfTest -Run
```

Auf dem Mac oder unter Linux entsteht dasselbe Paket per Cross-Build:

```
brew install dotnet
cd klar/windows
./build.sh
```

Beides erzeugt `dist/Klar-<Version>-win-x64.zip`. Der Workflow `.github/workflows/windows.yml` baut das Paket
zusätzlich auf einem Windows-Rechner von GitHub, legt die Visual-C++-Laufzeit bei und führt den Selbsttest aus.

## Selbsttest

```
Klar.exe --selftest bericht.txt
```

Öffnet nacheinander alle Fenster und Seiten, prüft Tastenkürzel, Zwischenablage, Anmeldeinformationen, Mikrofon,
Systemton, Spracherkennung (falls ein Modell geladen ist) und eine kurze Bildschirmaufnahme. Das Ergebnis steht
danach in der Berichtsdatei (ohne Angabe: `%TEMP%\klar-selftest.txt`). Der Test arbeitet in einem eigenen
Datenordner; Verlauf und Einstellungen bleiben unberührt, Text in der Zwischenablage wird zurückgesetzt.
Ein laufendes Klar vorher beenden – es würde die Testeinträge sonst in den echten Verlauf übernehmen.
„HINWEIS“ steht bei Schritten, die von der Hardware abhängen (kein Mikrofon, kein Bildschirm, fehlende
Visual-C++-Laufzeit); nur „FEHLER“ zählt als nicht bestanden.

## Tastenkürzel (Standard, änderbar)

| Funktion | Kürzel |
|---|---|
| Zwischenablage-Panel | Strg+Alt+V |
| Diktat (tippen = Start/Stopp, halten = Push-to-Talk) | Strg+Alt+D |
| Meeting transkribieren | Strg+Alt+Umschalt+M |
| Bildschirm aufnehmen | Strg+Alt+Umschalt+R |
| Cocaine an/aus | Strg+Alt+Umschalt+W |

Im Panel: ↑↓ wählen, ↩ einfügen, Strg+↩ nur kopieren, Strg+P oder Stecknadel anpinnen, Umschalt+Entf löschen,
Strg+1–9 Schnellwahl, tippen = suchen. Klick auf einen Eintrag fügt ihn ein und rückt ihn nach oben.
Tab wechselt zum Reiter „GIFs“.

Als Kürzel lässt sich auch eine einzelne Modifier-Taste festlegen, etwa die rechte Strg-Taste.
Strg+Alt entspricht auf deutschen Tastaturen AltGr; Buchstaben mit AltGr-Zeichen (Q, E, M) deshalb besser meiden.
AltGr selbst lässt sich nicht als Einzeltaste wählen, weil Windows sie als Strg+Alt meldet.

## Unterschiede zur Mac-Version

| Bereich | Mac | Windows |
|---|---|---|
| Spracherkennung | Apple (Text erscheint beim Sprechen) oder wahlweise Whisper | Whisper (lokal), Text erscheint nach jeder Sprechpause |
| Zusammenfassung | Claude Code, Claude-API, Apple Intelligence | Claude Code, Claude-API |
| Bildschirmaufnahme | `.mov` in Filme/Klar | `.mp4` in Videos\Klar |
| Deckel-Modus | `pmset`, fragt nach Admin-Passwort | Energieoption „Beim Zuklappen“, ohne Passwort |
| Berechtigungen | vier Systemfreigaben | keine; nur das Mikrofon lässt sich in Windows sperren |
| Symbol im Dock | optional | „Fenster in der Taskleiste anzeigen“ |
| Löschen im Panel | ⌘⌫ | Umschalt+Entf |
| API-Schlüssel | Schlüsselbund | Anmeldeinformationsverwaltung („Klar/…“) |

Einfügen per Strg+V funktioniert in allen Fenstern außer solchen, die als Administrator laufen.
Dort bleibt der Inhalt in der Zwischenablage.

## Daten

- Verlauf, Diktate, Transkripte, GIFs, Einstellungen, Protokoll: `%AppData%\Klar\`
- Sprachmodelle: `%LocalAppData%\Klar\Models\`
- Aufnahmen: `Videos\Klar\`
- API-Schlüssel (Claude, Giphy): Windows-Anmeldeinformationsverwaltung

Die Dateien für Verlauf, Diktate und Meetings haben dasselbe JSON-Format wie auf dem Mac.

## Sicherheit und Datenabflüsse

Was das Gerät verlässt – und nur dann, wenn du die Funktion nutzt:

| Funktion | Empfänger | Inhalt |
|---|---|---|
| Sprachmodell laden (einmalig) | huggingface.co | nichts außer der Anfrage selbst |
| GIF-Suche | api.giphy.com | Suchbegriff, Giphy-Schlüssel |
| Zusammenfassung über Claude Code | Anthropic (über dein Abo) | Meeting-Transkript |
| Zusammenfassung über Claude-API | api.anthropic.com | Meeting-Transkript, API-Schlüssel |
| Diktat, Transkription | niemand (lokal, Whisper) | – |

Klar hat keinen Update-Mechanismus, keine Telemetrie und keine offenen Ports.

- Kopien aus Passwortmanagern werden nie aufgezeichnet; ebenso Inhalte mit den Windows-Markern
  `ExcludeClipboardContentFromMonitorProcessing` und `CanIncludeInClipboardHistory = 0`.
- Claude Code wird ohne Werkzeuge (`--tools ""`) und ohne Sitzungsspeicherung aufgerufen.
- Verlauf, Diktate und Transkripte liegen unverschlüsselt im Benutzerprofil. Jede App, die als dein Benutzer
  läuft, kann sie lesen. BitLocker schützt sie im ausgeschalteten Zustand.
- Für Einzeltasten-Kürzel beobachtet Klar global Tastendrücke, um ein Halten zu erkennen. Es speichert oder
  sendet dabei nichts; der Hook existiert nur, wenn ein solches Kürzel eingestellt ist.
- Virenscanner stufen unsignierte Programme mit Tastatur-Hook, Zwischenablage-Zugriff und simulierten
  Tastendrücken gelegentlich als verdächtig ein. Der Quellcode liegt vollständig in diesem Ordner.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `src/Klar.Core` | Plattformneutrale Logik: Modelle, Ablage, Sprachbefehle, Audio-Aufbereitung, Whisper, Zusammenfassung, Giphy |
| `src/Klar` | Die WPF-App: Fenster, Tastenkürzel, Zwischenablage, Aufnahme, Infobereich-Symbol |
| `src/KlarRecorder` | Hilfsprogramm für die Bildschirmaufnahme (ScreenRecorderLib, .NET Framework 4.8) |
| `tests/Klar.Core.Tests` | Tests der gemeinsamen Logik, lauffähig auf Mac, Linux und Windows |

Verwendete Bibliotheken: [Whisper.net](https://github.com/sandrohanea/whisper.net) (MIT),
[NAudio](https://github.com/naudio/NAudio) (MIT), [ScreenRecorderLib](https://github.com/sskodje/ScreenRecorderLib) (MIT),
[XamlAnimatedGif](https://github.com/XamlAnimatedGif/XamlAnimatedGif) (Apache 2.0).

## Lizenz

MIT – siehe [LICENSE](../LICENSE).
