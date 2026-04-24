#!/bin/bash
# =============================================================================
# recover_strato.sh
# Restore svega sa lokalnih tar arhiva na pravo mjesto
# Autor: Flavio & Claude | Projekt Katalog
# Verzija: 1.1 | 2026-04-24 (paths: /root -> /home/balsam)
#
# Upotreba: bash /home/balsam/recovery/scripts/recover_strato.sh [YYYY-MM-DD]
# Bez datuma — koristi najnoviji u /home/balsam/recovery/restore/
#
# ⚠️  UPOZORENJE: Ova skripta je destruktivna — prepisuje postojeće fajlove!
#     Pokreći samo na svježoj instalaciji ili kad si siguran šta radiš.
# =============================================================================

set -euo pipefail

RESTORE_DIR="/home/balsam/recovery/restore"
LOG_FILE="/home/balsam/recovery/logs/recover_$(date +%Y-%m-%d_%H-%M).log"

mkdir -p "/home/balsam/recovery/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Odredi datum
if [ -n "${1:-}" ]; then
    BACKUP_DATE="$1"
else
    BACKUP_DATE=$(ls -1 "${RESTORE_DIR}/" 2>/dev/null | sort | tail -1)
    if [ -z "$BACKUP_DATE" ]; then
        log "GREŠKA: Nije pronađen nijedan backup u ${RESTORE_DIR}/"
        exit 1
    fi
fi

SRC="${RESTORE_DIR}/${BACKUP_DATE}"

log "========================================================"
log "--- RECOVER START: $BACKUP_DATE ---"
log "Izvor: ${SRC}"
log "⚠️  Ovo prepisuje postojeće fajlove na sistemu!"
log "========================================================"

# Provjeri da direktorij postoji
if [ ! -d "${SRC}" ]; then
    log "GREŠKA: ${SRC} ne postoji. Pokreni prvo download_strato.sh."
    exit 1
fi

# Provjeri da su part- fajlovi spojeni
if ls "${SRC}/"*.part-* 2>/dev/null | grep -q .; then
    log "GREŠKA: Pronađeni nespojeni part- fajlovi. Pokreni prvo download_strato.sh."
    exit 1
fi

# 1. /home/
if [ -f "${SRC}/home.tar.gz" ]; then
    log "Restore /home/ ..."
    tar -xzf "${SRC}/home.tar.gz" -C / 2>/dev/null || log "UPOZORENJE: tar /home/ završio s greškama — nastavljam"
    log "Restore /home/ završen."
else
    log "UPOZORENJE: home.tar.gz nije pronađen — preskačem"
fi

# 2. /opt/
if [ -f "${SRC}/opt.tar.gz" ]; then
    log "Restore /opt/ ..."
    tar -xzf "${SRC}/opt.tar.gz" -C / 2>/dev/null || log "UPOZORENJE: tar /opt/ završio s greškama — nastavljam"
    log "Restore /opt/ završen."
else
    log "UPOZORENJE: opt.tar.gz nije pronađen — preskačem"
fi

# 3. /var/www/ + apache2
if [ -f "${SRC}/www.tar.gz" ]; then
    log "Restore /var/www/ i apache2/sites-available/ ..."
    tar -xzf "${SRC}/www.tar.gz" -C / 2>/dev/null || log "UPOZORENJE: tar www/apache2 završio s greškama — nastavljam"
    log "Restore www/apache2 završen."
else
    log "UPOZORENJE: www.tar.gz nije pronađen — preskačem"
fi

# 4. PostgreSQL restore
if [ -f "${SRC}/db.tar.gz" ]; then
    log "Restore PostgreSQL baze..."
    # Raspakuj SQL dump
    tar -xzf "${SRC}/db.tar.gz" -C /tmp/
    SQL_FILE=$(ls /tmp/full_db_*.sql 2>/dev/null | head -1)
    if [ -z "$SQL_FILE" ]; then
        log "GREŠKA: SQL dump fajl nije pronađen nakon raspakivanja."
        exit 1
    fi
    log "SQL dump: $SQL_FILE ($(du -sh $SQL_FILE | cut -f1))"
    log "Importujem u PostgreSQL (korisnik: pgu)..."
    docker exec -i pgdb psql -U pgu -f - < "$SQL_FILE" 2>&1 || \
        log "UPOZORENJE: psql završio s greškama — baza može biti djelimično restore-ovana"
    rm -f "$SQL_FILE"
    log "Restore baze završen."
else
    log "UPOZORENJE: db.tar.gz nije pronađen — preskačem"
fi

# 5. Sysinfo — samo informativno, ne restore-uje automatski
if [ -f "${SRC}/sysinfo.tar.gz" ]; then
    log "Sysinfo arhiva pronađena — raspakujem u /tmp/sysinfo_restore/ za ručnu provjeru"
    mkdir -p /tmp/sysinfo_restore
    tar -xzf "${SRC}/sysinfo.tar.gz" -C /tmp/sysinfo_restore/ 2>/dev/null || true
    # Stare arhive (<v2.3) imaju strukturu root/recovery/configs/; novije home/balsam/recovery/configs/
    SYSINFO_FILES=$(ls /tmp/sysinfo_restore/home/balsam/recovery/configs/ 2>/dev/null \
                 || ls /tmp/sysinfo_restore/root/recovery/configs/ 2>/dev/null \
                 || find /tmp/sysinfo_restore -type f 2>/dev/null)
    log "Sysinfo fajlovi: ${SYSINFO_FILES}"
    log "Korisnici/grupe se NE restore-uju automatski — provjeri ručno u /tmp/sysinfo_restore/"
fi

log "========================================================"
log "--- RECOVER ZAVRŠEN: $(date) ---"
log ""
log "Sljedeći koraci (ručno):"
log "  1. Provjeri korisnike: cat /tmp/sysinfo_restore/.../users_*.txt"
log "  2. Restart Docker kontejnera: docker restart pgdb pgad ntfy ollama"
log "  3. Provjeri Apache: apache2ctl configtest && systemctl restart apache2"
log "  4. Provjeri bazu: docker exec pgdb psql -U pgu -d balsam -c '\l'"
log "========================================================"

exit 0
