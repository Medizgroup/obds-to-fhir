# obds-to-fhir Betrieb — DIZ Gießen


## 1. Was macht das Tool bei uns

`obds-to-fhir` wandelt oBDS-XML-Exporte (aus GTDS, über Mirth Connect) in FHIR-Bundles
(MII Modul Onkologie) um. Wir nutzen den **`process-from-directory`-Modus**: einmaliger
Batch-Lauf, der alle XML-Dateien aus einem Ordner liest und FHIR-JSON-Bundles in einen
Output-Ordner schreibt. Kein Dauerbetrieb, kein ONKOSTAR, kein Kafka Connect nötig.

Die FHIR-Bundles selbst werden **nicht** von diesem Tool an einen FHIR-Server geschickt —
das übernehmen wir separat über Mirth Connect.

## 2. Unsere beiden relevanten Branches

- **`beta`** — unser Fork-Branch mit der DIZ-Gießen-spezifischen Konfiguration
  (`deploy/compose.process-from-directory.yaml`: unsere FHIR-Namespaces, Patient-Lookup-
  Strategie, Host-Pfade). Dieses Dokument lebt hier.
- **`fail-catch-branch`** — ein generischer Code-Feature-Branch (basiert direkt auf
  `master`, ohne DIZ-spezifische Config), der das "eine kaputte Meldung killt den ganzen
  Lauf"-Problem behebt (siehe Abschnitt 7). Bewusst getrennt gehalten, damit er sich bei
  Bedarf auch als PR ans Original-Repo (`bzkf/obds-to-fhir`) vorschlagen ließe, ohne unsere
  eigenen Secrets/Pfade mitzuschleppen.

Für den echten Betrieb müssen beide zusammengeführt werden (`beta` + `fail-catch-branch`
mergen), siehe Abschnitt 7.

## 3. Unser Setup

| Was | Wert |
|---|---|
| Deploy-Verzeichnis | `deploy/` in diesem Repo |
| Input-Ordner (Host) | `/mnt/mirth/channelFiles/onko/input` |
| Output-Ordner (Host) | `/mnt/mirth/channelFiles/onko/output` |
| Failed/Quarantäne-Ordner (Host) | `/mnt/mirth/channelFiles/onko/failed` |
| Compose-Dateien | `compose.yaml` (Basis) + `compose.process-from-directory.yaml` (unsere DIZ-Config) + `compose.offline.yaml` (Air-Gap-Override) |
| Betrieb | **Routine-Netz** (eingeschränkter Internetzugang, siehe Abschnitt 5) |
| Patient-Referenz-Strategie | `FHIR_SERVER_LOOKUP` gegen `http://ugisrdiztest.ugi.rka.local/fhir` (Testserver) |

## 4. Einmalige Einrichtung auf einer neuen VM

1. Repo auf die VM bringen. Git-Zugriff (HTTPS, GitHub) funktioniert inzwischen auch im
   Routine-Netz — **aber**: das betrifft nur den Quellcode/die Compose-Dateien. Das fertige
   Docker-Image lässt sich damit *nicht* automatisch mitziehen, siehe Abschnitt 5.
2. Docker ohne `sudo` nutzbar machen:
   ```sh
   sudo usermod -aG docker $USER
   ```
   Danach aus-/einloggen. Test: `docker ps` sollte ohne `sudo` funktionieren.
3. Ordner anlegen:
   ```sh
   mkdir -p /mnt/mirth/channelFiles/onko/{input,output,failed}
   ```

## 5. Images ins Air-Gap-Netz bringen (bei jeder neuen Image-Version nötig)

Das Routine-Netz hat (Stand Oktober 2026) direkten `git`/GitHub-Zugriff, aber **keinen**
Zugriff auf Docker Hub/GHCR/Maven Central — und das Image selbst lässt sich dort auch nicht
bauen: Das `Dockerfile` zieht beim Bauen mehrere Base-Images aus unterschiedlichen Registries
(`docker.io/library/gradle`, `docker.io/library/debian`, `gcr.io/distroless/...`) und lädt
während `gradle build` sämtliche Java-Abhängigkeiten aus Maven Central/dem Gradle Plugin
Portal nach — das ist eine ganz andere, viel umfangreichere Firewall-Freigabe als nur
`git pull` von GitHub. **Bauen muss also weiterhin auf einem Rechner mit vollem
Internetzugang passieren**, nicht auf der Routine-VM.

Großer Dateidownload läuft außerdem über einen **McAfee Web Gateway**-Virenscan-Proxy, der
bei "Ziel speichern unter" (Rechtsklick) nur eine Zwischenseite (paar KB HTML) statt der
echten Datei liefert — **immer mit einfachem Linksklick** herunterladen und den Scan-
Fortschritt im Browser abwarten lassen (Fenster offen lassen, nicht "Speichern unter"
benutzen).

Schritt für Schritt:

```sh
# 1. Auf einem Rechner MIT Internetzugang, nachdem das Image gebaut/gepullt wurde:
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
6. `deploy/compose.offline.yaml` auf die neue Version anpassen (siehe Abschnitt 6).

Kafka-Image (`docker.io/apache/kafka`) muss **nicht** bei jedem obds-to-fhir-Update neu
transportiert werden — das ist nur ein Wegwerf-Hilfscontainer für den einmaligen Lauf, die
genaue Version ist irrelevant. Das bereits geladene Kafka-Image einfach weiter per
`compose.offline.yaml` pinnen.

## 6. `compose.offline.yaml`

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

## 7. Problem: Eine kaputte Meldung killt den ganzen Lauf

**Upstream (bzkf) ist das beabsichtigtes Verhalten:** Die Maintainer wollen lieber früh
abbrechen und einzelne Meldungen reparieren bzw. das Mapping toleranter machen, statt
Nachrichten unbemerkt zu verwerfen (Risiko: unvollständige/inkonsistente Patientendaten in
einem Krebsregister). Ein generelles "Fehler ignorieren"-Flag wollten sie upstream nicht
per Default anbieten — waren aber explizit offen dafür, dass *wir* uns ein solches,
standardmäßig deaktiviertes Flag selbst bauen.

### Unsere Lösung: `fail-catch-branch`

Statt eines externen Wrapper-Skripts (frühere Idee, verworfen) haben wir das direkt im
Tool nachgerüstet. Neue, standardmäßig deaktivierte Config:

```yaml
obds:
  process-from-directory:
    on-error:
      skip-invalid-messages: false   # bei uns: true
      failed-directory: "/opt/obds-to-fhir/failed"
```

Env-Var-Form (für die Compose-Datei):
```
OBDS_PROCESS_FROM_DIRECTORY_ON_ERROR_SKIP_INVALID_MESSAGES=true
OBDS_PROCESS_FROM_DIRECTORY_ON_ERROR_FAILED_DIRECTORY=/opt/obds-to-fhir/failed
```

Technisch: In `ProcessFromDirectory.java` wird die komplette Pro-Datei-Verarbeitung
(Deserialisieren + Mapping + Bundle-Schreiben) in einem try/catch gekapselt. Schlägt sie
fehl, wird — nur wenn `skip-invalid-messages: true` — die Datei geloggt und in
`failed-directory` verschoben, statt den ganzen Lauf abzubrechen. Da eine Datei immer
**alle** Meldungen **eines* Patienten enthält, ist das Skip-Verhalten atomar pro Datei:
entweder wurden alle Bundles für diesen Patienten geschrieben, oder keines — nie ein
inkonsistenter Zwischenzustand. Das war der zentrale Einwand der Maintainer, und er greift
hier nicht.

**Wichtig — `failed-directory` ist ein Review-Postfach, kein Papierkorb:** Den Ordner
(`/mnt/mirth/channelFiles/onko/failed`) regelmäßig durchsehen. Für jede neue Fehlerart:
1. Betroffenes Feld in der oBDS-XSD nachschlagen (Abschnitt 9) — Pflicht oder optional?
   Gibt's einen "keine Angabe"-Code, der stattdessen hätte genutzt werden sollen?
2. Je nach Befund: an GTDS-Team melden (Datenqualität an der Quelle) **und/oder** als Issue
   bei `bzkf/obds-to-fhir` einreichen (Mapping sollte toleranter sein).
3. Erst wenn die Ursache geklärt ist, die Datei ggf. korrigiert erneut einspeisen.

### `beta` und `fail-catch-branch` zusammenführen

```sh
git checkout beta
git merge fail-catch-branch
# compose.process-from-directory.yaml hat sich in beiden Branches geändert -
# Merge-Konflikt manuell auflösen: unsere DIZ-Werte behalten, die neuen
# OBDS_PROCESS_FROM_DIRECTORY_ON_ERROR_*-Zeilen aus fail-catch-branch übernehmen.
```
Danach neu bauen (auf einem Rechner mit Internet, siehe Abschnitt 5) und das neue Image
wie gewohnt auf die VM bringen.

## 8. Tool manuell ausführen

```sh
cd deploy
sudo USER_ID="$(id -u)" GROUP_ID="$(id -g)" docker compose \
  -f compose.yaml \
  -f compose.process-from-directory.yaml \
  -f compose.offline.yaml \
  run --rm obds-to-fhir
```

`USER_ID`/`GROUP_ID` sorgen dafür, dass die erzeugten Output-Dateien dem eigenen User gehören
statt dem Container-internen `65532`. Danach liegen die FHIR-Bundles in
`/mnt/mirth/channelFiles/onko/output` als `*.fhir.json`.

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
   XSD-Fundstelle schicken.

## 10. Bisherige Bugfixes & Meldungen (Historie)

- **[#717](https://github.com/bzkf/obds-to-fhir/issues/717) / [#718](https://github.com/bzkf/obds-to-fhir/pull/718)**
  (gefixt in v3.4.1): `FHIR_SERVER_LOOKUP` + `create-patient-resources.enabled=true` crashte
  mit `The reference 'null' should point to a Patient resource`. Von uns gemeldet, von einem
  Copilot Coding Agent innerhalb von ~10 Minuten gefixt und released.
- **Fehlendes/leeres `Intention`-Feld**: tritt sowohl bei `SYST` (`SystemischeTherapieProcedureMapper.java`)
  als auch bei `ST`/Strahlentherapie (`StrahlentherapieMapper.java`) auf — beide rufen
  `MiiCsOnkoIntention.fromValueOrThrow(...)` ohne Null-Check auf. Beide Schema-Definitionen
  kennen einen Code `X` = "Keine Angabe" für genau diesen Fall — GTDS nutzt ihn nicht.
  Eine grobe Suche (`grep -rn fromValueOrThrow mappings/src/main/java`) zeigt ca. 35 ähnliche
  Aufrufstellen in 15 Mapper-Klassen — dasselbe Bug-Muster kann an weiteren Stellen auftauchen.
- **Allgemeines "ein Lauf bricht komplett ab"-Verhalten**: als Issue eingereicht, von den
  Maintainern bewusst nicht als Upstream-Default abgelehnt (siehe Abschnitt 7) — Lösung ist
  unser eigenes `on-error.skip-invalid-messages`-Flag auf `fail-catch-branch`.

## 11. Cheat-Sheet

```sh
# Manueller Lauf:
cd deploy && sudo USER_ID="$(id -u)" GROUP_ID="$(id -g)" docker compose \
  -f compose.yaml -f compose.process-from-directory.yaml -f compose.offline.yaml \
  run --rm obds-to-fhir

# Was ist aktuell geladen:
docker images

# Failed/Quarantäne-Ordner durchsehen:
ls -la /mnt/mirth/channelFiles/onko/failed/
```
