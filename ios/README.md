# Klar fürs iPhone

Diktieren und Meetings mitschreiben, mit Modellauswahl. Alles läuft lokal
auf dem iPhone, der Ton verlässt das Gerät nicht.

Auf dem iPhone gibt es keine systemweiten Tastenkürzel und keinen Zwischenablage-Verlauf im Hintergrund.
Die iPhone-App beschränkt sich deshalb auf Diktat und Meetings. Zwischenablage, GIFs, Bildschirmaufnahme und
„Cocaine“ gibt es nur auf Mac und Windows.

## Funktionen

- **Diktieren** – großer Knopf, Text erscheint während bzw. nach jeder Sprechpause, am Ende automatisch kopiert
- **Erkennung**: Apple, Whisper Large-v3 (1,1 GB), Whisper Large-v3 Turbo (574 MB), Parakeet TDT 0.6B v3 (671 MB)
- **Sprachen**: Deutsch, Englisch, Rumänisch, Polnisch, Türkisch (Parakeet ohne Türkisch)
- **Meetings** – iPhone auf den Tisch legen, „Meeting starten“: fortlaufendes Transkript mit Zeitmarken, läuft
  bei gesperrtem Bildschirm weiter. Danach Zusammenfassung über Apple Intelligence (iOS 26, ab iPhone 15 Pro),
  Teilen und Kopieren. Aufgenommen wird nur, was das Mikrofon hört – den Ton von Zoom, Teams oder Telefonaten
  gibt iOS nicht frei (Lautsprecher hilft). Mit Apples Erkennung kann iOS die Erkennung bei gesperrtem
  Bildschirm drosseln; für lange Meetings Whisper Turbo oder Parakeet wählen.
- **Verlauf** der letzten 200 Diktate, antippen kopiert, wischen löscht
- **Teilen** an jede App

Hinweise zu den Modellen:

- Whisper Large-v3 braucht viel Arbeitsspeicher. Empfohlen ab iPhone 15 Pro (8 GB); auf älteren Geräten kann
  iOS die App beenden. Large-v3 Turbo und Parakeet laufen auch auf Geräten mit 6 GB.
- Die Modelle werden beim ersten Gebrauch geladen (WLAN empfohlen), per Größe und SHA-256 geprüft und liegen
  danach in der App. In den Einstellungen lässt sich ein Modell wieder löschen.

## Installieren

Ein fertiges Paket liegt bei jedem Release als `Klar-<Version>-iOS-unsigned.ipa`. Es ist **nicht signiert**,
weil Apple dafür ein Entwicklerkonto verlangt. Drei Wege:

1. **Sideloadly oder AltStore mit eigener Apple-ID** (kostenlos): die `.ipa` damit aufs iPhone übertragen.
   Mit einer kostenlosen Apple-ID läuft die Signatur nach 7 Tagen ab und muss erneuert werden.
2. **Xcode auf einem Mac**: `brew install xcodegen`, dann im Repository
   ```
   ./fetch-whisper.sh --ios
   cd ios && xcodegen generate && open KlarMobile.xcodeproj
   ```
   In Xcode unter „Signing & Capabilities“ das eigene Team wählen, iPhone anschließen, ausführen.
3. **Apple-Developer-Konto** (99 €/Jahr): wie 2., dann über TestFlight verteilen.

Auf dem iPhone muss unter „Einstellungen → Datenschutz & Sicherheit“ der Entwicklermodus eingeschaltet sein
(Wege 1 und 2).

## Bauen und Prüfen

Der Workflow `.github/workflows/ios.yml` läuft auf einem Mac mit Xcode bei jedem Pull Request, der `ios/` oder
die gemeinsamen Swift-Teile berührt. Er:

1. lädt whisper.cpp und sherpa-onnx (`fetch-whisper.sh --ios`) und erzeugt das Projekt mit XcodeGen,
2. lädt Parakeet und Whisper Large-v3 Turbo und spricht Testsätze in den fünf Sprachen ein,
3. führt die Tests im iPhone-Simulator aus – darunter die echte Erkennung mit beiden Modellen,
4. baut die App für echte iPhones und legt die unsignierte `.ipa` als Artefakt ab (bei Tags auch am Release).

## Aufbau

| Pfad | Inhalt |
|---|---|
| `Klar/` | Die App: Oberfläche, Diktat (Mikrofon, Apple-Erkennung, lokale Modelle), Verlauf, Einstellungen |
| `KlarTests/` | Tests: Modellliste, Abschnitte, echte Erkennung im Simulator |
| `../Sources/KlarSpeech` | Mit dem Mac geteilt: Modelle, Sprachen, Abschnitte, Download mit Prüfsumme |
| `../Sources/KlarRecognizers` | Mit dem Mac geteilt: Whisper (whisper.cpp) und Parakeet (sherpa-onnx) |
| `project.yml` | Projektbeschreibung für XcodeGen |

Anders als auf dem Mac läuft die Erkennung hier in der App selbst. iOS-Apps sind ohnehin abgeschottet,
und ein Hilfsprozess ist auf dem iPhone nicht möglich.
