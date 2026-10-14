#!/bin/bash
#
# Führt den obds-to-fhir "process-from-directory"-Lauf aus.
#
# Hintergrund: Eine einzelne nicht-konforme oBDS-Meldung im Input-Ordner lässt
# den obds-to-fhir-Container mit einem Fehler abbrechen (Absicht der Maintainer,
# siehe docs/betrieb-diz-giessen.md) - und zwar für den GESAMTEN Lauf, nicht nur
# für die eine Datei. Dieses Skript fängt genau das ab: wenn ein Lauf abbricht,
# wird aus dem Log ermittelt, welche Datei den Fehler verursacht hat, diese eine
# Datei in einen Quarantäne-Ordner verschoben, und der Lauf neu gestartet - so
# lange, bis entweder alle Dateien durch sind oder eine Sicherheitsgrenze
# erreicht ist.
#
# WICHTIG: Der Quarantäne-Ordner ist eine Review-Warteschlange, kein Papierkorb.
# Regelmäßig durchsehen und jede neue Fehlerart entweder an GTDS melden (wenn es
# an der Exportdatenqualität liegt) oder als Issue bei bzkf/obds-to-fhir
# einreichen (wenn das Mapping toleranter werden sollte). Siehe
# docs/betrieb-diz-giessen.md für den vollen Kontext und bisherige Beispiele.
#
# Aufruf: ./run-obds-to-fhir.sh
# (keine Argumente; Pfade werden unten im Skript konfiguriert)

set -uo pipefail

# --- Pro Umgebung (Dev-Rechner vs. Routine-VM) ggf. anpassen ---
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="/mnt/mirth/channelFiles/onko/input"
QUARANTINE_DIR="/mnt/mirth/channelFiles/onko/quarantaene"
LOG_DIR="$HOME/obds-to-fhir-logs"
MAX_ATTEMPTS=50
# ----------------------------------------------------------------

cd "$DEPLOY_DIR" || exit 1
mkdir -p "$QUARANTINE_DIR" "$LOG_DIR"

attempt=0
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  timestamp="$(date +%Y%m%d-%H%M%S)"
  logfile="$LOG_DIR/run-${timestamp}-attempt${attempt}.log"

  echo "=== Versuch $attempt: starte obds-to-fhir ($(date)) ===" | tee -a "$logfile"

  USER_ID="$(id -u)" GROUP_ID="$(id -g)" docker compose \
    -f compose.yaml \
    -f compose.process-from-directory.yaml \
    -f compose.offline.yaml \
    run --rm obds-to-fhir 2>&1 | tee -a "$logfile"

  exit_code=${PIPESTATUS[0]}

  if [ "$exit_code" -eq 0 ]; then
    echo "=== Lauf erfolgreich abgeschlossen (Versuch $attempt) ===" | tee -a "$logfile"
    exit 0
  fi

  bad_file=$(grep -oP 'fileName=\K[^ ,]+' "$logfile" | tail -1)

  if [ -z "$bad_file" ]; then
    echo "FEHLER: Konnte die fehlerhafte Datei nicht aus dem Log ermitteln. Breche ab, statt zu raten." >&2
    echo "Bitte Logdatei manuell prüfen: $logfile" >&2
    exit 1
  fi

  if [ ! -f "$INPUT_DIR/$bad_file" ]; then
    echo "FEHLER: Datei '$bad_file' nicht (mehr) im Input-Ordner gefunden. Breche ab, um keine Endlosschleife zu riskieren." >&2
    exit 1
  fi

  echo "Datei '$bad_file' hat einen Fehler verursacht -> verschiebe nach Quarantäne."
  mv "$INPUT_DIR/$bad_file" "$QUARANTINE_DIR/${timestamp}-$bad_file"
done

echo "FEHLER: Maximale Anzahl an Versuchen ($MAX_ATTEMPTS) erreicht. Breche ab." >&2
echo "Das deutet auf ein größeres Problem hin (z.B. kaputtes Image, falsche Config) - bitte prüfen, bevor weiter quarantänisiert wird." >&2
exit 1
