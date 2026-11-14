# Quik

[中文](README.md) · [English](README.en.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md)

Ein Stockungsmonitor für macOS, der in der Menüleiste lebt. Er beantwortet zwei Fragen: stockt das System gerade, und wodurch.

Natives Swift, keine Fremdbibliotheken. Gemessene Kosten im eingeschwungenen Zustand: 0,8 % eines Kerns (0,07 % von 12 Kernen) bei etwa 25 MB residentem Speicher. Die Methode steht in `docs/metric-validation.md`. Die Oberfläche der App ist derzeit auf Chinesisch.

## Installation

Lade `Quik-<version>.dmg` von [Releases](https://github.com/lesliechowsh/quik/releases/latest) herunter, öffne das Image und ziehe Quik in den Ordner Programme. Benötigt macOS 14 oder neuer, auf Apple Silicon und Intel.

Veröffentlichte Versionen sind mit einer Developer ID signiert und von Apple notarisiert. Der erste Start zeigt daher keine Sicherheitswarnung. Ein Build aus dem Quellcode ist ad-hoc signiert; bei seinem ersten Start ist Systemeinstellungen > Datenschutz & Sicherheit > „Dennoch öffnen“ nötig.

Zum Veröffentlichen `QUIK_SIGN_IDENTITY` und `QUIK_NOTARY_PROFILE` setzen; `scripts/package.sh` signiert, notarisiert und heftet das Ticket an.

## Bauen und starten

Benötigt Xcode 26 und `xcodegen`.

```bash
brew install xcodegen
scripts/build.sh
scripts/run.sh
```

`scripts/run.sh` öffnet ein schwebendes Fenster in der oberen rechten Ecke des Bildschirms. Es zeigt den Score, den Zustand und den Hauptverdächtigen. Ein Klick öffnet das Panel, das unter dem schwebenden Fenster aufklappt und beim Moduswechsel nur nach unten wächst. Ziehen verschiebt es, die Position wird gemerkt. Das Fenster aktiviert die App nicht, stiehlt keinen Fokus und bleibt auf allen Schreibtischflächen sichtbar.

Ein Rechtsklick auf das schwebende Fenster oder die Schaltfläche „隐藏悬浮窗“ (schwebendes Fenster ausblenden) unten rechts im Panel blendet es aus. Die Wahl liegt in der Einstellung `hudVisible` und überlebt einen Neustart. Zurück kommt es über die Schaltfläche im Panel oder per Rechtsklick auf das Menüleisten-Symbol und Häkchen bei „显示悬浮窗“ (schwebendes Fenster anzeigen).

Auch das Dock-Symbol spiegelt den Zustand. Im einfachen Modus zeigt es den Zustand und den Namen des Hauptverdächtigen und wird orange oder rot, wenn das System stockt. Der erweiterte Modus setzt den Score in die obere Hälfte und die Zustandsbezeichnung direkt darunter. Die Schriftgröße folgt der Stellenzahl, 70 Punkt bei zwei Ziffern und 52 bei drei, damit „100“ vollständig bleibt und nicht zu „1…“ abgeschnitten wird. Ein Klick auf das Dock-Symbol öffnet das Panel.

Zusätzlich erscheint ein Menüleisten-Eintrag:

- `● 12` grün oder farblos, das System läuft flüssig.
- `▲ Slack Helper 44%` orange, das System ist zäh. Der folgende Text ist der Hauptverdächtige und sein Anteil an einem Kern.
- `■ Slack Helper 44%` rot, das System stockt.

Wird der Platz in der Menüleiste knapp, schiebt macOS den Eintrag unter das App-Menü. Das schwebende Fenster ist davon nicht betroffen und trägt daher das dauerhafte Signal. Ein Klick auf den Eintrag oder das schwebende Fenster öffnet das Panel. Das Panel zeigt den Stockungs-Score, seine Ursachenzuordnung (CPU, Speicher, Festplatte, Antwortlatenz, Temperatur), die fünf Hauptverdächtigen und die möglichen Aktionen je Prozess: 3 Sekunden sampeln, Aktivitätsanzeige öffnen, beenden.

Der einfache Modus ist Standard. Er beantwortet drei Dinge: stockt es, wer ist verantwortlich, soll man es beenden. Score, Ursachendetails, Verlaufsdiagramm und Sampling liegen hinter dem „erweiterten Modus“, umgeschaltet unten rechts im Panel.

Verdächtige erscheinen als App, nicht als Name der ausführbaren Datei. `Slack Helper (Renderer)` erscheint als „Slack · 页面渲染“ (Seitendarstellung), und Dock sowie schwebendes Fenster nutzen denselben Namen. Kommandozeilenprozesse ohne zugehörige App werden über ihr Arbeitsverzeichnis unterschieden, etwa „node · läuft im Ordner my-project“. Slack zu beenden beendet Slack selbst, nicht den Hilfsprozess.

Der `sample`-Bericht wird in ein temporäres Verzeichnis geschrieben und automatisch geöffnet. Er enthält 3 Sekunden Aufrufstapel und zeigt, in welcher Funktion der Prozess hängt. Dieser Eintrag erscheint nur im erweiterten Modus.

## Prüfung

```bash
# Unit-Tests: Entscheidung, Hysterese, Rangliste, Anzeigestabilität
xcodebuild -project Quik.xcodeproj -scheme Quik -configuration Debug -derivedDataPath build test

# UI-Schleife: feste Zustände einspeisen, echtes Panel aufnehmen, Text per OCR prüfen
scripts/ui-check.sh

# Messschleife: kontrollierte CPU-Überlast, prüft Sonde und Entscheidung
# Flattermessung: Zyklen von 6 s Volllast / 6 s Leerlauf, zählt Wechsel von Zustand und Rangliste (scripts/flap-check.sh)
scripts/verify-experience.sh
```

```bash
# Schleife für das schwebende Fenster: bleibt nach Neustart aus- oder eingeblendet, verschwindet und kommt im Betrieb zurück
scripts/verify-hud.sh

# Beenden-Schleife: signalisiert einen echten Prozess und prüft, dass er endet
scripts/verify-quit.sh
```

```bash
# Paket-Schleife: hängt das DMG ein, prüft Architekturen, Signatur und das Ziel und startet es einmal
scripts/verify-package.sh
```

Die Schritte zum Veröffentlichen stehen in `docs/distribution.md`.

`scripts/ui-check.sh` schreibt Screenshots und OCR-Text nach `/tmp/quik-ui`. Es prüft vier Dinge: den Panel-Text, die Fensterrechtecke von Panel und schwebendem Fenster innerhalb des Bildschirms, den Dock-Symboltext innerhalb der Kachel und die korrekte Darstellung beider Modi. Jede fehlgeschlagene Prüfung liefert einen Exit-Code ungleich null.

Die Fensterposition wird separat geprüft, weil ein Screenshot per Fenster-ID nur beweist, dass der Inhalt stimmt, nicht dass das Fenster auf dem Bildschirm liegt. Eine frühe Version setzte das Panel über den oberen Bildschirmrand; der Inhalts-Screenshot war einwandfrei und die Prüfung bestand trotzdem.

Die Icon-Prüfung liest PNGs, die die App exportiert. Sie stammen aus derselben `ImageRenderer`-Ausgabe, die das Dock zeichnet. Geprüft werden eine quadratische Kachel, Textpixel ohne Berührung des Rands und Text höher als die halbe Kachel. Der erweiterte Modus ergänzt zwei messbare Bedingungen: der vertikale Abstand zwischen Score und Bezeichnung bleibt unter 12 % der Kachelseite, und die Unterkante der Bezeichnung liegt mindestens 20 Pixel über dem Kachelrand. Ein Unit-Test rendert außerdem den Score 100 und liest ihn mit Vision, sodass ein abgeschnittener dreistelliger Score den Build scheitern lässt.

## Grenzen der Messung

Quik misst Systemkonkurrenz, nicht die UI-Frame-Zeit einer anderen App. macOS bietet keine öffentliche Schnittstelle, über die ein Prozess von außen Blockaden des Hauptthreads eines anderen Prozesses liest.

Das Panel meldet daher „wer belegt die Ressourcen“ und „kann das System interaktive Threads noch rechtzeitig einplanen“, nicht „diese App hängt“. Ist die CPU gesättigt, die Antwortlatenz aber normal, meldet Quik zäh, nicht stockend. Kritischer Speicherdruck oder kritische Temperatur sind die Ausnahme: Der Kernel friert bereits Apps ein oder senkt den Takt, dann meldet Quik direkt stockend.

Die vollständige Abbildung von Last auf Zustand und die Grundlage der Entscheidungskurve stehen in `docs/metric-validation.md`.

## Aufbau

```
Sources/Core/       Entscheidungsengine, Deltas, Erfahrungssonde, Verlauf
Sources/Probe/      mach-, sysctl-, libproc-, IOKit-Sampling und C-Brücke
Sources/UI/         Menüleiste, Panel, Aktionen, Vorschauzustände
Sources/App/        Einstiegspunkt
Tests/              Unit-Tests
scripts/            Build, UI-Prüfungen, Messexperimente
docs/               Entscheidungsprotokoll und Messvalidierung
```

## Lizenz

MIT. Siehe `LICENSE`.
