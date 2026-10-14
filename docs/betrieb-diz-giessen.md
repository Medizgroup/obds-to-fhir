# obds-to-fhir Betrieb — DIZ Gießen

Dieses Dokument ist für "mich in 3 Wochen, der sich an nichts mehr erinnert". Es beschreibt
unseren konkreten Betrieb von [obds-to-fhir](https://github.com/bzkf/obds-to-fhir) bei UKGM
Gießen — nicht die allgemeine Projekt-Doku (die steht im Haupt-[README.md](../README.md) und
in [docs/config.md](config.md)).

## 1. Was macht das Tool bei uns

`obds-to-fhir` wandelt oBDS-XML-Exporte (aus GTDS, über Mirth Connect) in FHIR-Bundles
(MII Modul Onkologie) um. Wir nutzen den **`process-from-directory`-Modus**: einmaliger
Batch-Lauf, der alle XML-Dateien aus einem Ordner liest und FHIR-JSON-Bundles in einen
Output-Ordner schreibt. Kein Dauerbetrieb, kein ONKOSTAR, kein Kafka Connect nötig.

Die FHIR-Bundles selbst werden **nicht** von diesem Tool an einen FHIR-Server geschickt —
das übernehmen wir separat über Mirth Connect.

## 2. Unser Setup

| Was | Wert |
|---|---|
| Deploy-Verzeichnis | `deploy/` in diesem Repo |
| Input-Ordner (Host) | `/mnt/mirth/channelFiles/onko/input` |
| Output-Ordner (Host) | `/mnt/mirth/channelFiles/onko/output` |
| Quarantäne-Ordner (Host) | `/mnt/mirth/channelFiles/onko/quarantaene` |
| Compose-Dateien | `compose.yaml` (Basis) + `compose.process-from-directory.yaml` (unsere DIZ-Config) + `compose.offline.yaml` (Air-Gap-Override) |
| Betrieb | **Routine-Netz** (kein direkter Internetzugang, siehe Abschnitt 4) |
| Patient-Referenz-Strategie | `FHIR_SERVER_LOOKUP` gegen `http://ugisrdiztest.ugi.rka.local/fhir` (Testserver) |

## 3. Einmalige Einrichtung auf einer neuen VM

1. Repo auf die VM bringen (Git-Zugriff im Routine-Netz ist i.d.R. auch gesperrt — einfach die
   paar benötigten Dateien aus `deploy/` manuell per WinSCP/Copy-Paste rüberziehen, siehe
   Abschnitt 4. Man braucht **kein** vollständiges `git clone` auf der VM, da nur das fertige
   Docker-Image + die Compose-YAMLs gebraucht werden, kein Java/Gradle-Build).
2. Docker ohne `sudo` nutzbar machen:
   ```sh
   sudo usermod -aG docker $USER
   ```
   Danach aus-/einloggen. Test: `docker ps` sollte ohne `sudo` funktionieren.
3. Ordner anlegen:
   ```sh
   mkdir -p /mnt/mirth/channelFiles/onko/{input,output,quarantaene}
   ```

## 4. Images ins Air-Gap-Netz bringen (bei jeder neuen Image-Version nötig)

Das Routine-Netz hat **keinen** Zugriff auf Docker Hub/GHCR (DNS-Auflösung schlägt fehl).
Großer Dateidownload läuft außerdem über einen **McAfee Web Gateway**-Virenscan-Proxy, der
bei "Ziel speichern unter" (Rechtsklick) nur eine Zwischenseite (paar KB HTML) statt der
echten Datei liefert — **immer mit einfachem Linksklick** herunterladen und den Scan-
Fortschritt im Browser abwarten lassen (Fenster offen lassen, nicht "Speichern unter"
benutzen).

Schritt für Schritt:

```sh
# 1. Auf einem Rechner MIT Internetzugang:
docker pull ghcr.io/bzkf/obds-to-fhir:<NEUE_VERSION>
docker save --output obds-to-fhir_<NEUE_VERSION>.tar ghcr.io/bzkf/obds-to-fhir:<NEUE_VERSION>
```

2. Datei nach Nextcloud hochladen.
3. Auf dem Routine-Rechner: Link mit **Linksklick** öffnen (nicht Rechtsklick/"Speichern
   unter"), McAfee-Scan im Browserfenster abwarten, bis der echte Download startet.
4. Mit WinSCP vom Routine-Rechner auf die Ziel-VM kopieren (z.B. nach `~/obds-images/`).
5. Auf der VM:
   ```sh
   cd ~/obds-images
   docker load --input obds-to-fhir_<NEUE_VERSION>.tar
   docker images   # prüfen, ob es einen Namen bekommen hat
   ```
   Falls nur `Loaded image ID: sha256:...` ohne Namen kommt:
   ```sh
   docker tag <IMAGE_ID> ghcr.io/bzkf/obds-to-fhir:<NEUE_VERSION>
   ```
6. `deploy/compose.offline.yaml` auf die neue Version anpassen (siehe Abschnitt 5).

Kafka-Image (`docker.io/apache/kafka`) muss **nicht** bei jedem obds-to-fhir-Update neu
transportiert werden — das ist nur ein Wegwerf-Hilfscontainer für den einmaligen Lauf, die
genaue Version ist irrelevant. Das bereits geladene Kafka-Image einfach weiter per
`compose.offline.yaml` pinnen.

## 5. `compose.offline.yaml`

Diese Datei existiert **nur bei uns** (nicht im Original-Repo) und sorgt dafür, dass Docker
Compose ausschließlich lokal geladene Images nutzt, statt zu versuchen aus dem Internet zu
pullen:

```yaml
services:
  obds-to-fhir:
    image: ghcr.io/bzkf/obds-to-fhir:<AKTUELLE_VERSION>
    pull_policy: never
  kafka:
    image: docker.io/apache/kafka:4.1.1
    pull_policy: never
```

Bei einem Image-Update: nur den Tag in der `obds-to-fhir`-Zeile anpassen.

## 6. Tool manuell ausführen

```sh
cd deploy
sudo USER_ID="$(id -u)" GROUP_ID="$(id -g)" docker compose \
  -f compose.yaml \
  -f compose.process-from-directory.yaml \
  -f compose.offline.yaml \
  run --rm obds-to-fhir
```

`USER_ID`/`GROUP_ID` sorgen dafür, dass die erzeugten Output-Dateien dem eigenen User gehören
statt dem Container-internen `65532`. (Falls Docker-Gruppe wie in Abschnitt 3 eingerichtet
ist, kann das `sudo` am Anfang auch entfallen.)

Danach liegen die FHIR-Bundles in `/mnt/mirth/channelFiles/onko/output` als `*.fhir.json`.

## 7. Problem: Eine kaputte Meldung killt den ganzen Lauf

**Das ist beabsichtigtes Verhalten** der Maintainer (Stand: ihre Antwort auf unsere Issue,
Oktober 2026): Sie wollen lieber früh abbrechen und einzelne Meldungen reparieren bzw. das
Mapping toleranter machen, statt Nachrichten unbemerkt zu verwerfen (Risiko: unvollständige/
inkonsistente Patientendaten in einem Krebsregister). Es wird **kein** generelles
"Fehler ignorieren"-Flag für den `process-from-directory`-Modus geben. Die Dead-Letter-Queue
(`docs/config.md#dead-letter-queue`) existiert nur im Kafka-Streaming-Modus und ist selbst
dort nur als Diagnose-Hilfsmittel gedacht, nicht zum dauerhaften Verwerfen.

### Unsere Lösung: `deploy/run-obds-to-fhir.sh`

Ein Wrapper-Skript, das bei einem Absturz automatisch **nur die eine** verursachende Datei
(ermittelt aus dem Log, `fileName=...`) in den Quarantäne-Ordner verschiebt und den Lauf neu
startet — so lange, bis entweder alles durch ist oder eine Sicherheitsgrenze (50 Versuche)
erreicht ist.

```sh
cd deploy
./run-obds-to-fhir.sh
```

Logs landen unter `~/obds-to-fhir-logs/run-<timestamp>-attempt<n>.log`.

**Wichtig — das ist ein Review-Postfach, kein Papierkorb:** Den Quarantäne-Ordner
(`/mnt/mirth/channelFiles/onko/quarantaene`) regelmäßig durchsehen. Für jede neue
Fehlerart:
1. Betroffenes Feld in der oBDS-XSD nachschlagen (Abschnitt 9) — Pflicht oder optional?
   Gibt's einen "keine Angabe"-Code, der stattdessen hätte genutzt werden sollen?
2. Je nach Befund: an GTDS-Team melden (Datenqualität an der Quelle) **und/oder** als Issue
   bei `bzkf/obds-to-fhir` einreichen (Mapping sollte toleranter sein).
3. Erst wenn die Ursache geklärt ist, die Datei ggf. korrigiert erneut einspeisen.

### Geplant, noch nicht umgesetzt: Cron-Automatisierung

Erst einrichten, wenn sich die Fehlerrate im Quarantäne-Ordner über ein paar manuelle Läufe
beruhigt hat (sonst sammelt sich nachts unbemerkt Material an). Ablauf, wenn es soweit ist:

1. Docker-Gruppe wie in Abschnitt 3 einrichten (kein `sudo`-Passwort-Prompt im Cronjob).
2. Skript manuell einmal testen.
3. `crontab -e`, Zeile ergänzen:
   ```
   0 4 * * * /home/<user>/dev/obds-to-fhir/deploy/run-obds-to-fhir.sh >> /home/<user>/obds-to-fhir-logs/cron.log 2>&1
   ```
4. Am nächsten Tag prüfen: `grep CRON /var/log/syslog`, `cat ~/obds-to-fhir-logs/cron.log`.
5. **Absolute Pfade** im Skript verwenden — Cron kennt kein `PATH` aus der `.bashrc`.

## 8. Bisherige Bugfixes (Historie, damit man nicht nochmal danach sucht)

- **[#717](https://github.com/bzkf/obds-to-fhir/issues/717) / [#718](https://github.com/bzkf/obds-to-fhir/pull/718)**
  (gefixt in v3.4.1): `FHIR_SERVER_LOOKUP` + `create-patient-resources.enabled=true` crashte
  mit `The reference 'null' should point to a Patient resource`, wenn ein Patient auf dem
  Ziel-FHIR-Server noch nicht existierte. Von uns gemeldet, von einem Copilot Coding Agent
  innerhalb von ~10 Minuten gefixt und released.
- **Fehlendes/leeres `Intention`-Feld**: tritt sowohl bei `SYST` (`SystemischeTherapieProcedureMapper.java`)
  als auch bei `ST`/Strahlentherapie (`StrahlentherapieMapper.java:161`) auf — beide rufen
  `MiiCsOnkoIntention.fromValueOrThrow(...)` ohne Null-Check auf, anders als z.B. `Therapieart`
  im selben File, das einen sauberen `DataAbsentReason`-Fallback hat. Beide Schema-Definitionen
  (SYST wie ST) kennen einen Code `X` = "Keine Angabe" für genau diesen Fall — GTDS nutzt ihn
  aber nicht (lässt das Feld stattdessen leer/weg). **Hinweis:** eine grobe Suche
  (`grep -rn fromValueOrThrow mappings/src/main/java`) zeigt ca. 35 ähnliche Aufrufstellen in
  15 Mapper-Klassen — dasselbe Bug-Muster kann an weiteren Stellen auftauchen, sobald GTDS dort
  ebenfalls kein `X`/"keine Angabe" einträgt.
- **Allgemeines "ein Lauf bricht komplett ab"-Verhalten**: von uns als Issue eingereicht,
  von den Maintainern bewusst abgelehnt (siehe Abschnitt 7) — Lösung ist unser eigenes
  Quarantäne-Skript, kein Upstream-Flag.

## 9. Datenqualität: Wie man Pflicht/optional selbst nachschlägt

Technische Quelle der Wahrheit: die oBDS-v3-XSD, die auch `obds-to-fhir` nutzt:
[`oBDS_v3.0.4.xsd`](https://github.com/bzkf/obds2-to-obds3/blob/master/lib/src/main/resources/schema/oBDS_v3.0.4.xsd)
(Teil von [bzkf/obds2-to-obds3](https://github.com/bzkf/obds2-to-obds3)). Fachliche Referenz:
[Kerndatensatz Onkologie, basisdatensatz.de](https://www.basisdatensatz.de/basisdatensatz).

Vorgehen bei einem neuen Fehler:
1. Feldname in der XSD suchen (z.B. `LDH`, `Intention`).
2. `minOccurs="0"` vorhanden? → Feld ist **optional**, sollte bei Unbekannt einfach weggelassen
   werden (nicht mit Platzhaltern wie `"NaN"` befüllt werden).
3. Kein `minOccurs` → Feld ist **Pflicht** (XSD-Default `1`). Prüfen, ob die Enum einen
   "keine Angabe"/"unbekannt"-Code hat (häufig `X` oder `U`) — den sollte GTDS dann nutzen,
   statt das Feld leer zu lassen.
4. Gefundene Abweichung in einer Mail ans GTDS-Team mit konkretem Dateibeispiel und
   XSD-Fundstelle schicken (siehe Mail-Vorlage, die wir für den LDH-Fall genutzt haben —
   Struktur: Kontext, konkretes Beispiel, Schema-Zitat, Bitte um Prüfung, unsere
   Interims-Lösung).

## 10. Cheat-Sheet

```sh
# Manueller Lauf (bricht beim ersten Fehler ab):
cd deploy && sudo USER_ID="$(id -u)" GROUP_ID="$(id -g)" docker compose \
  -f compose.yaml -f compose.process-from-directory.yaml -f compose.offline.yaml \
  run --rm obds-to-fhir

# Robuster Lauf mit automatischer Quarantäne:
cd deploy && ./run-obds-to-fhir.sh

# Was ist aktuell geladen:
docker images

# Logs der letzten Läufe:
ls -la ~/obds-to-fhir-logs/

# Quarantäne-Ordner durchsehen:
ls -la /mnt/mirth/channelFiles/onko/quarantaene/
```
