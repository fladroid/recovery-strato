#!/bin/bash
# =============================================================================
# backup_strato.sh
# Backup Strato servera (Balsam VPS) na Google Drive
# Autor: Flavio & Claude | Projekt Katalog
# Verzija: 2.3 | 2026-04-24 (RECOVERY_DIR ispravljen: /root -> /home/balsam)
# Cron (root): 0 3 * * * /bin/bash /home/balsam/recovery/scripts/backup_strato.sh
# =============================================================================

set -euo pipefail

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
RECOVERY_DIR="/home/balsam/recovery"
LOG_FILE="$RECOVERY_DIR/logs/backup_$TIMESTAMP.log"
CONFIGS_DIR="$RECOVERY_DIR/configs"
TMP_DIR="/tmp/backup_strato_${DATE}"
GDRIVE_REMOTE="gdrive"
GDRIVE_BASE="backup_balsam"
GDRIVE_DEST="${GDRIVE_REMOTE}:${GDRIVE_BASE}/${DATE}"
SPLIT_SIZE="2G"
RETENTION_DAYS=3
RCLONE="/usr/bin/rclone"
RCLONE_CONFIG="/home/balsam/recovery/rclone.conf"
NTFY_URL="https://ntfy-balsam.dynu.net/balsam-flavio-minitor"
NTFY_TOKEN="tk_hegwsgk6f03v1cgaauzc4z76xuicw"

mkdir -p "$RECOVERY_DIR/logs" "$CONFIGS_DIR" "$TMP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ntfy_send() {
    curl -s -o /dev/null \
        -H "Authorization: Bearer ${NTFY_TOKEN}" \
        -H "Title: $1" \
        -H "Priority: ${3:-default}" \
        -H "Tags: ${4:-white_check_mark}" \
        -d "$2" "${NTFY_URL}" || true
}

check_file() {
    if [ ! -s "$1" ]; then
        log "GREŠKA: Fajl je prazan ili ne postoji: $1"
        return 1
    fi
}

do_split() {
    local archive="$1"
    local size_bytes
    size_bytes=$(stat -c%s "$archive")
    if [ "$size_bytes" -gt 1073741824 ]; then
        log "Split $(basename $archive) na ${SPLIT_SIZE} komade..."
        split -b "${SPLIT_SIZE}" -d --suffix-length=3 "${archive}" "${archive}.part-"
        local parts
        parts=$(ls "${archive}.part-"* | wc -l)
        rm -f "${archive}"
        log "Split završen: ${parts} komada"
    else
        log "Veličina ispod ${SPLIT_SIZE} — split nije potreban"
    fi
}

# Cleanup se poziva SAMO pri uspjehu — ne briše /tmp ako je došlo do greške
cleanup_on_success() {
    log "Cleanup: brišem ${TMP_DIR}"
    rm -rf "${TMP_DIR}"
}

trap 'EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    log "BACKUP NEUSPJEŠAN — exit code: $EXIT_CODE"
    log "TMP_DIR ${TMP_DIR} je sačuvan za dijagnostiku."
    ntfy_send "❌ Backup NEUSPJEŠAN" "Strato backup ${DATE} pao s greškom (exit: $EXIT_CODE). TMP sačuvan: ${TMP_DIR}" "urgent" "x,rotating_light"
fi' EXIT

log "========================================================"
log "--- START: $TIMESTAMP ---"
log "Destinacija: ${GDRIVE_DEST}"
log "========================================================"

# Provjeri postoji li već TMP_DIR s prethodnog neuspjelog runa
if [ "$(ls -A $TMP_DIR 2>/dev/null)" ]; then
    log "Pronađen postojeći TMP_DIR s prethodnog runa — koristim postojeće arhive gdje je moguće"
fi

# 1. Sistemske informacije
if [ ! -f "${TMP_DIR}/sysinfo.tar.gz" ]; then
    log "Spremam listu korisnika i grupa..."
    getent passwd | awk -F: '$3 >= 1000 && $3 < 60000' > "$CONFIGS_DIR/users_$TIMESTAMP.txt"
    getent group  | awk -F: '$3 >= 1000 && $3 < 60000' > "$CONFIGS_DIR/groups_$TIMESTAMP.txt"
    cp /etc/hosts "$CONFIGS_DIR/hosts_$TIMESTAMP.txt"
    SYSINFO_ARCHIVE="${TMP_DIR}/sysinfo.tar.gz"
    tar -czf "${SYSINFO_ARCHIVE}" \
        "$CONFIGS_DIR/users_$TIMESTAMP.txt" \
        "$CONFIGS_DIR/groups_$TIMESTAMP.txt" \
        "$CONFIGS_DIR/hosts_$TIMESTAMP.txt"
    check_file "${SYSINFO_ARCHIVE}"
    log "sysinfo.tar.gz: $(du -sh ${SYSINFO_ARCHIVE} | cut -f1)"
else
    log "sysinfo.tar.gz već postoji — preskačem"
fi

# 2. PostgreSQL dump
if [ ! -f "${TMP_DIR}/db.tar.gz" ]; then
    log "Izvozim bazu podataka (korisnik: pgu)..."
    DB_DUMP="$CONFIGS_DIR/full_db_$TIMESTAMP.sql"
    docker exec pgdb pg_dumpall -U pgu > "$DB_DUMP"
    if ! check_file "${DB_DUMP}"; then
        log "GREŠKA: pg_dumpall producirao prazan fajl — abort!"
        exit 1
    fi
    log "pg_dumpall OK — veličina: $(du -sh ${DB_DUMP} | cut -f1)"
    DB_ARCHIVE="${TMP_DIR}/db.tar.gz"
    tar -czf "${DB_ARCHIVE}" -C "$(dirname $DB_DUMP)" "$(basename $DB_DUMP)"
    check_file "${DB_ARCHIVE}"
    log "db.tar.gz: $(du -sh ${DB_ARCHIVE} | cut -f1)"
else
    log "db.tar.gz već postoji — preskačem"
fi

# 3. /home/
if ! ls "${TMP_DIR}/home.tar.gz"* 2>/dev/null | grep -q .; then
    log "Arhiviram /home/ ..."
    HOME_ARCHIVE="${TMP_DIR}/home.tar.gz"
    tar -czf "${HOME_ARCHIVE}" \
        --exclude="$RECOVERY_DIR/logs/backup_*.log" \
        /home/ 2>/dev/null || log "UPOZORENJE: tar /home/ završio s greškama — nastavljam"
    check_file "${HOME_ARCHIVE}"
    log "home.tar.gz: $(du -sh ${HOME_ARCHIVE} | cut -f1)"
    do_split "${HOME_ARCHIVE}"
else
    log "home arhiva već postoji — preskačem"
fi

# 4. /opt/
if ! ls "${TMP_DIR}/opt.tar.gz"* 2>/dev/null | grep -q .; then
    log "Arhiviram /opt/ ..."
    OPT_ARCHIVE="${TMP_DIR}/opt.tar.gz"
    tar -czf "${OPT_ARCHIVE}" /opt/ 2>/dev/null || log "UPOZORENJE: tar /opt/ završio s greškama — nastavljam"
    check_file "${OPT_ARCHIVE}"
    log "opt.tar.gz: $(du -sh ${OPT_ARCHIVE} | cut -f1)"
    do_split "${OPT_ARCHIVE}"
else
    log "opt arhiva već postoji — preskačem"
fi

# 5. /var/www/ + apache2
if [ ! -f "${TMP_DIR}/www.tar.gz" ]; then
    log "Arhiviram /var/www/ i apache2/sites-available/ ..."
    WWW_ARCHIVE="${TMP_DIR}/www.tar.gz"
    tar -czf "${WWW_ARCHIVE}" \
        /var/www/ \
        /etc/apache2/sites-available/ 2>/dev/null || log "UPOZORENJE: tar www/apache2 završio s greškama — nastavljam"
    check_file "${WWW_ARCHIVE}"
    log "www.tar.gz: $(du -sh ${WWW_ARCHIVE} | cut -f1)"
else
    log "www.tar.gz već postoji — preskačem"
fi

# Upload
log "========================================================"
log "Upload na GDrive: ${GDRIVE_DEST}"
TOTAL_LOCAL=$(du -sh "${TMP_DIR}" | cut -f1)
FILE_COUNT=$(ls "${TMP_DIR}/" | wc -l)
log "Ukupno: ${TOTAL_LOCAL} | Fajlova: ${FILE_COUNT}"
log "========================================================"

"${RCLONE}" --config "${RCLONE_CONFIG}" copy "${TMP_DIR}/" "${GDRIVE_DEST}/" \
    --transfers 2 --checkers 4 --drive-chunk-size 256M 2>&1

log "Upload završen."

GDRIVE_COUNT=$("${RCLONE}" --config "${RCLONE_CONFIG}" ls "${GDRIVE_DEST}/" 2>/dev/null | wc -l)
log "Lokalno: ${FILE_COUNT} | GDrive: ${GDRIVE_COUNT}"

if [ "${GDRIVE_COUNT}" -lt "${FILE_COUNT}" ]; then
    log "GREŠKA: Manje fajlova na GDriveu (${GDRIVE_COUNT}) nego lokalno (${FILE_COUNT})"
    exit 1
fi

# Retention
log "Retention: brišem backup-e starije od ${RETENTION_DAYS} dana..."
CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" +%Y-%m-%d)
"${RCLONE}" --config "${RCLONE_CONFIG}" lsd "${GDRIVE_REMOTE}:${GDRIVE_BASE}/" 2>/dev/null | \
    awk '{print $NF}' | \
    while read -r folder; do
        if [[ "$folder" < "$CUTOFF_DATE" ]]; then
            log "Brišem stari backup: ${folder}"
            "${RCLONE}" --config "${RCLONE_CONFIG}" purge "${GDRIVE_REMOTE}:${GDRIVE_BASE}/${folder}/" 2>&1
        fi
    done

# Čišćenje lokalnih starih fajlova
log "Čišćenje lokalnih starih fajlova..."
find "$RECOVERY_DIR/logs"    -type f -mtime +7 -delete
find "$RECOVERY_DIR/configs" -type f -mtime +7 -delete

END_TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
log "========================================================"
log "--- BACKUP ZAVRŠEN: ${END_TIMESTAMP} ---"
log "GDrive: ${GDRIVE_DEST} | Fajlova: ${GDRIVE_COUNT} | Ukupno: ${TOTAL_LOCAL}"
log "========================================================"

ntfy_send "✅ Backup uspješan" "Strato backup ${DATE} završen OK. Fajlova: ${GDRIVE_COUNT} | Veličina: ${TOTAL_LOCAL}" "default" "white_check_mark,floppy_disk"

# Cleanup SAMO pri uspjehu
cleanup_on_success

exit 0
