# BlackShelf

Hörbuch-App fürs iPhone für deinen **Audiobookshelf**-Server, mit **Blackbox Request** nur für Hörbücher.
SwiftUI, iOS 18+, Gestaltung nach den Apple Human Interface Guidelines.

## Funktionen

**Hören**
- Start: „Weiterhören“ als große Karten mit Restzeit und Play-Taste, dazu die Audiobookshelf-Regale (Neu hinzugefügt, Serie fortsetzen, Entdecken, Nochmal hören …)
- Bibliothek: Titel (Raster, sortieren und filtern nach Begonnen, Nicht begonnen, Beendet), Serien (nach Bandnummer), Autoren, Sammlungen
- Buchdetails: Cover, Sprecher, Serie, Beschreibung, Kapitelliste (Tippen startet ab dem Kapitel), als beendet markieren, Fortschritt zurücksetzen
- Player: Kapitel-Schieberegler, ±15/30 s (einstellbar), Kapitel vor/zurück, Geschwindigkeit 0,75–2×, Schlaf-Timer (Minuten oder Kapitelende, mit sanftem Ausblenden), Kapitelliste, AirPlay
- Mini-Player über der Tab-Leiste
- Hintergrundwiedergabe, Sperrbildschirm und Kontrollzentrum (zeigt das aktuelle Kapitel), Kopfhörer-Tasten, Pause beim Abziehen der Kopfhörer, Fortsetzen nach Anrufen
- Fortschritt wird alle 15 s mit Audiobookshelf synchronisiert (Wiedergabesitzungen, Hörstatistik zählt mit)
- Bücher aus mehreren Audiodateien laufen als eine durchgehende Zeitachse

**Anfragen (Blackbox Request)**
- Tab „Anfragen“: eigene Hörbuch-Anfragen mit Live-Status (Wartet, Lädt mit Prozent, Wird einsortiert, Verfügbar), Wischen zum Wiederholen oder Entfernen
- „+“ öffnet die Suche bei Blackbox Request, Detailseite mit „Hörbuch anfragen“
- In der normalen Suche erscheinen unter den eigenen Treffern auch Hörbücher, die **nicht in deiner Bibliothek** sind, und lassen sich direkt anfragen
- Verfügbare Anfragen öffnen das Buch in der Bibliothek

Genutzte Blackbox-Request-Endpunkte (dieselben wie im Amperfy-Fork):
`GET /api/books/search`, `GET /api/books/{id}`, `GET/POST /api/requests` (`kind: "audiobook"`), `POST /api/requests/{id}/retry`, `DELETE /api/requests/{id}`, `GET /api/health`, Header `X-Api-Key`.

## Bauen ohne Mac (GitHub Actions + Sideloadly)

1. Auf GitHub ein neues **öffentliches** Repository anlegen (z. B. `goofysnuts/blackshelf`). Öffentlich, damit die macOS-Builds kostenlos sind.
2. Den Inhalt dieses Ordners hochladen (inklusive `.github/workflows/build-ipa.yml`).
3. Unter **Actions → Build unsigned IPA** läuft der Build automatisch. XcodeGen erzeugt dabei aus `project.yml` das Xcode-Projekt.
4. Die fertige `BlackShelf-…-unsigned.ipa` unter **Artifacts** herunterladen und mit **Sideloadly** und deiner Apple-ID aufs iPhone installieren.

## Erste Schritte in der App

1. Audiobookshelf-Adresse eingeben (z. B. `http://NAS-IP:13378`) und mit Benutzername/Passwort oder einem **API-Schlüssel** anmelden. API-Schlüssel laufen nicht ab; du erstellst sie in Audiobookshelf ab Version 2.26 unter Einstellungen → API-Schlüssel.
2. Für Anfragen: Profil-Symbol oben rechts → **Blackbox Request** → Adresse und gegebenenfalls API-Schlüssel eintragen → „Verbindung testen“.

## Projektstruktur

```
project.yml                 XcodeGen-Projektdefinition
BlackShelf/App              App-Einstieg, Tabs
BlackShelf/Core             Audiobookshelf-API, Modelle, Blackbox-Request-Client, Keychain
BlackShelf/Player           Wiedergabe (AVPlayer, Sitzungen, Now Playing), Player-Oberfläche
BlackShelf/Views            Start, Bibliothek, Details, Suche, Anfragen, Einstellungen
```
