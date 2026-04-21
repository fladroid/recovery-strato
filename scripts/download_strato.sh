#!/bin/bash
# =============================================================================
# download_strato.sh
# Skida backup sa GDrive na lokalni disk i spaja part- fajlove
# Autor: Flavio & Claude | Projekt Katalog
# Verzija: 1.0 | 2026-04-13
#
# Upotreba: bash /root/recovery/scripts/download_strato.sh [YYYY-MM-DD]
# Bez datuma — skida najnoviji backup
# =============================================================================

set -euo pipefail

GDRIVE_REMOTE="gdrive"
GDRIVE_BASE="backup_balsam"
RCLONE="/usr/bin/rclone"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RESTORE_DIR="/root/recovery/restore"
LOG_FILE="/root/recovery/logs/download_$(date +%Y-%m-%d_%H-%M).log"

mkdir -p "$RESTORE_DIR" "/root/recovery/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Odredi datum backupa
if [ -n "${1:-}" ]; then
    BACKUP_DATE="$1"
else
    # Najnoviji folder na GDriveu
    BACKUP_DATE=$("${RCLONE}" --config "${RCLONE_CONFIG}" lsd "${GDRIVE_REMOTE}:${GDRIVE_BASE}/" 2>/dev/null | \
        awk '{print $NF}' | sort | tail -1)
    if [ -z "$BACKUP_DATE" ]; then
        log "GREŠKA: Nije pronađen nijedan backup na GDriveu."
        exit 1
    fi
fi

GDRIVE_SRC="${GDRIVE_REMOTE}:${GDRIVE_BASE}/${BACKUP_DATE}"
DEST="${RESTORE_DIR}/${BACKUP_DATE}"

log "========================================================"
log "--- DOWNLOAD START: $BACKUP_DATE ---"
log "Izvor:      ${GDRIVE_SRC}"
log "Destinacija: ${DEST}"
log "========================================================"

# Provjeri da folder postoji na GDriveu
FILE_COUNT=$("${RCLONE}" --config "${RCLONE_CONFIG}" ls "${GDRIVE_SRC}/" 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
    log "GREŠKA: Backup ${BACKUP_DATE} nije pronađen na GDriveu ili je prazan."
    exit 1
fi
log "Pronađeno fajlova na GDriveu: ${FILE_COUNT}"

mkdir -p "${DEST}"

# Download
log "Skidanje s GDrivea..."
"${RCLONE}" --config "${RCLONE_CONFIG}" copy "${GDRIVE_SRC}/" "${DEST}/" \
    --transfers 1 --checkers 2 2>&1
log "Download završen."

# Spajanje part- fajlova
log "Spajam part- fajlove..."
for prefix in home opt; do
    if ls "${DEST}/${prefix}.tar.gz.part-"* 2>/dev/null | grep -q .; then
        log "Spajam ${prefix}.tar.gz ..."
        cat "${DEST}/${prefix}.tar.gz.part-"* > "${DEST}/${prefix}.tar.gz"
        rm -f "${DEST}/${prefix}.tar.gz.part-"*
        log "${prefix}.tar.gz: $(du -sh ${DEST}/${prefix}.tar.gz | cut -f1)"
    fi
done

log "========================================================"
log "Sadržaj restore direktorija:"
ls -lh "${DEST}/"
log "========================================================"
log "--- DOWNLOAD ZAVRŠEN ---"
log "Sljedeći korak: bash /root/recovery/scripts/recover_strato.sh ${BACKUP_DATE}"
log "========================================================"

exit 0
