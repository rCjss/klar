# Changelog

Alle nennenswerten Änderungen an Klar. Format angelehnt an [Keep a Changelog](https://keepachangelog.com/de/).

## 0.2.0 – 2026-10-17

### Neu
- **Cocaine**: Mac und Bildschirm wach halten – 15 Minuten bis 8 Stunden oder unbegrenzt, per Menüleiste,
  Fenster oder Hotkey (⌥⇧⌘W). Während Meeting-Transkriptionen und Bildschirmaufnahmen automatisch aktiv.
- **Deckel-Modus**: zugeklappt weiterlaufen ohne externen Bildschirm (Systemeinstellung, fragt nach Admin-Passwort;
  wird beim Beenden der Sitzung, nach Ablauf der Zeit und beim Beenden der App zurückgesetzt).
- **Zusammenfassung über Claude Code**: Meeting-Zusammenfassungen laufen über die installierte Claude-Code-Kommandozeile
  und damit über ein Claude-Abo, ohne API-Schlüssel. Auswahl in den Einstellungen: Automatisch, Claude Code,
  Claude-API, Apple Intelligence.
- **GIF-Reiter** im Zwischenablage-Panel mit Giphy-Suche (eigener API-Schlüssel), animierte Vorschauen,
  Einfügen als Datei.
- **Stecknadel** in jeder Panel-Zeile zum Anpinnen; Klick auf einen Eintrag fügt ihn ein und rückt ihn nach oben.
- Autorenzeile in der Seitenleiste; Versionsnummer kommt aus der Info.plist.

### Sicherheit
- Hardened Runtime mit Entitlements – keine Code-Injektion in eine App, die Bedienungshilfen, Mikrofon und
  Bildschirmaufnahme besitzt.
- Skript-Steuerung per DistributedNotification nur noch im Debug-Build.
- Datendateien mit Rechten 0600 in Ordnern mit 0700.
- Kopien aus Passwortmanagern und der Schlüsselbundverwaltung werden nie aufgezeichnet.
- Abschnitt „Sicherheit und Datenabflüsse“ im README.

### Geändert
- Signatur mit lokalem Zertifikat „Klar Dev“ (`sign-setup.sh`), damit Systemfreigaben Neubauten überleben.
- Berechtigungsanzeige in den Einstellungen aktualisiert sich von selbst.
- Standard-Textbaustein „Signatur“ nutzt den Namen des angemeldeten Benutzers.
- `build.sh --dist` erzeugt ein ad hoc signiertes Release-Archiv.

## 0.1.0 – 2026-10-15

Erste öffentliche Version: Zwischenablage-Verlauf mit Suche und Pins, Diktat mit Sprachbefehlen und
Push-to-Talk, Meeting-Transkription (Systemton und Mikrofon getrennt) mit Zusammenfassung,
Bildschirmaufnahme mit Systemton.
