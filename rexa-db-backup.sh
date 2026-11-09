#!/usr/bin/env bash
# ==============================================================================
# Rexa-DB-Backup — CLI Auto Backup MySQL/MariaDB + PostgreSQL
# Mode: docker (via podman/docker exec ke container) / host (TCP langsung ke server DB)
# OS: Alpine Linux (apk) / Ubuntu (apt) — TUI teks + cron otomatis
# Copyright Risky Setiawan
# ==============================================================================
set -u

APP_NAME="Rexa-DB-Backup"
APP_VERSION="0.1.10"
APP_FOOTER="Copyright Risky Setiawan"
REPO="sinnersman/rexa-db-backup"

CONFIG_FILE="/etc/db-autobackup/config.json"
LOG_FILE="/var/log/db-autobackup.log"
CRON_TAG="# DB-AUTOBACKUP-CRON"
TIMEOUT_S=3   # timeout koneksi biar cepet

if [ "$(id -u)" -ne 0 ]; then
  echo "[-] Wajib root!" >&2
  exit 1
fi
mkdir -p /etc/db-autobackup "$(dirname "$LOG_FILE")"

# Runtime container: podman preferred (server sudah on), fallback docker
detect_rt() {
  if command -v podman >/dev/null 2>&1; then echo podman;
  elif command -v docker >/dev/null 2>&1; then echo docker;
  else echo podman; fi
}
RT=$(detect_rt)
[ -n "${CONTAINER_RT:-}" ] && RT="$CONTAINER_RT"

# Info OS untuk TUI (Alpine / Ubuntu / lain + kernel)
os_info() {
  local name="Unknown OS" ver="" ker=""
  if [ -f /etc/os-release ]; then
    name=$(grep '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
    ver=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
  fi
  ker=$(uname -r 2>/dev/null || echo "?")
  [ -n "$ver" ] && echo "$name $ver (kernel $ker)" || echo "$name (kernel $ker)"
}

# Cek TCP cepat via python3 socket (tanpa client DB) — return 0 bila open
tcp_check() {
  python3 -c "import socket,sys; s=socket.create_connection(('$1',$2),timeout=3); s.close()" 2>/dev/null
}

# ---------------------------------------------------------------- 1. Config
init_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
{
  "mode": "docker",
  "db_target": "both",
  "db_type": "mysql",
  "socket_path": "/opt/lampp/var/mysql/mysql.sock",
  "pg_container": "datasetsync-db",
  "pg_user": "datasetsync",
  "pg_password": "CHANGE_ME",
  "pg_db": "datasetsync",
  "pg_host": "127.0.0.1",
  "pg_port": 5432,
  "mysql_container": "mysql",
  "mysql_user": "root",
  "mysql_password": "",
  "mysql_db": "small_db_test",
  "mysql_host": "127.0.0.1",
  "mysql_port": 3306,
  "backup_dir": "/var/backups/db-backup",
  "backup_hour": "02",
  "backup_minute": "00",
  "retain_days": 7
}
EOF
    chmod 600 "$CONFIG_FILE"
    echo "[+] Config awal dibuat: $CONFIG_FILE — EDIT dulu pg_password/mysql_* sebelum run."
  fi
}

read_config() {
  init_config
  # python3 preferred, fallback: busybox sh parse sederhana
  if command -v python3 >/dev/null 2>&1; then
    MODE=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mode','docker'))")
    DB_TARGET=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('db_target','both'))")
    DB_TYPE=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('db_type','mysql'))")
    SOCKET_PATH=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('socket_path','/opt/lampp/var/mysql/mysql.sock'))")
    PG_CT=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('pg_container','datasetsync-db'))")
    PG_USER=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('pg_user','datasetsync'))")
    PG_PASS=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('pg_password',''))")
    PG_DB=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('pg_db','datasetsync'))")
    MY_CT=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mysql_container','mysql'))")
    MY_USER=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mysql_user','root'))")
    MY_PASS=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mysql_password',''))")
    MY_DB=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mysql_db','small_db_test'))")
    PG_HOST=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('pg_host','127.0.0.1'))")
    PG_PORT=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('pg_port',5432))")
    MY_HOST=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mysql_host','127.0.0.1'))")
    MY_PORT=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('mysql_port',3306))")
    BACKUP_DIR=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('backup_dir','/var/backups/db-backup'))")
    BACKUP_HOUR=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('backup_hour','02'))")
    BACKUP_MINUTE=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('backup_minute','00'))")
    RETAIN_DAYS=$(python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('retain_days',7))")
  else
    echo "[-] python3 belum ada, jalankan menu 1 dulu." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- 2. Deps (Alpine apk / Ubuntu apt)
check_dependencies() {
  read_config
  local os="unknown"
  command -v apk >/dev/null 2>&1 && os="alpine"
  command -v apt-get >/dev/null 2>&1 && os="ubuntu"
  echo "[*] Cek dependensi (OS: $os, mode: ${MODE:-docker})..."
  need=""
  # runtime container cuma wajib di mode docker
  if [ "${MODE:-docker}" != "host" ]; then
    if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then need="$need podman"; fi
  fi
  command -v python3 >/dev/null 2>&1 || need="$need python3"
  command -v gzip >/dev/null 2>&1 || need="$need gzip"
  command -v crontab >/dev/null 2>&1 || need="$need cron"
  command -v whiptail >/dev/null 2>&1 || need="$need gui-whiptail"
  # client DB wajib di mode host/socket (langsung tanpa container)
  if [ "${MODE:-docker}" != "docker" ]; then
    (command -v pg_isready >/dev/null 2>&1 || command -v psql >/dev/null 2>&1) || need="$need pg-client"
    (command -v mysql >/dev/null 2>&1 || command -v mariadb >/dev/null 2>&1) || need="$need mysql-client"
  fi
  if [ -z "$need" ]; then tui_msg "Dependensi" "Semua dependensi utama terpenuhi."; return 0; fi
  tui_yesno "Dependensi" "Paket kurang:$need — install sekarang?" || return 0
  if [ "$os" = "alpine" ]; then
    apk update && apk add --no-cache python3 gzip bash busybox-suid \
      $([ "${MODE:-docker}" = "docker" ] && echo "podman") \
      $([ "${MODE:-docker}" != "docker" ] && echo "postgresql16-client mariadb-client") \
      $(echo "$need" | grep -q "gui-whiptail" && echo "newt")
    rc-update add cgroups boot 2>/dev/null || true
    rc-update add crond boot 2>/dev/null || true
    rc-service crond start 2>/dev/null || crond 2>/dev/null || true
  elif [ "$os" = "ubuntu" ]; then
    sudo apt-get update && sudo apt-get install -y python3 gzip bash cron \
      $([ "${MODE:-docker}" = "docker" ] && echo "podman") \
      $([ "${MODE:-docker}" != "docker" ] && echo "postgresql-client mariadb-client") \
      $(echo "$need" | grep -q "gui-whiptail" && echo "whiptail")
    sudo systemctl enable --now cron 2>/dev/null || sudo service cron start 2>/dev/null || true
  else
    echo "[-] OS tidak dikenal (bukan apk/apt). Install manual:$need" >&2
  fi
  # pastikan cron jalan
  if command -v crond >/dev/null 2>&1; then
    if ! pgrep -x crond >/dev/null 2>&1; then (crond 2>/dev/null || true); fi
  fi
}

have_container() { $RT ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# Helper: binary MySQL/MariaDB (image mariadb:11 cuma punya mariadb-*)
# $1=container (kosong = host), lalu sisa args diteruskan
ct_mysql_exec() {
  local ct="$1"; shift
  if [ -n "$ct" ]; then
    if $RT exec "$ct" sh -c 'command -v mysql' >/dev/null 2>&1; then $RT exec "$ct" mysql "$@";
    else $RT exec "$ct" mariadb "$@"; fi
  else
    if command -v mysql >/dev/null 2>&1; then mysql "$@";
    elif command -v mariadb >/dev/null 2>&1; then mariadb "$@";
    else echo "[-] mysql/mariadb client tidak ada di host (apk add mariadb-client)" >&2; return 127; fi
  fi
}
ct_mysqldump() {
  local ct="$1"; shift
  if [ -n "$ct" ]; then
    if $RT exec "$ct" sh -c 'command -v mysqldump' >/dev/null 2>&1; then $RT exec "$ct" mysqldump "$@";
    else $RT exec "$ct" mariadb-dump "$@"; fi
  else
    if command -v mysqldump >/dev/null 2>&1; then mysqldump "$@";
    elif command -v mariadb-dump >/dev/null 2>&1; then mariadb-dump "$@";
    else echo "[-] mysqldump/mariadb-dump tidak ada di host (apk add mariadb-client)" >&2; return 127; fi
  fi
}
ct_mysqladmin_ping() {
  local ct="$1"; shift
  if [ -n "$ct" ]; then
    if $RT exec "$ct" sh -c 'command -v mysqladmin' >/dev/null 2>&1; then $RT exec "$ct" mysqladmin "$@" ping 2>&1;
    else $RT exec "$ct" mariadb-admin "$@" ping 2>&1; fi
  else
    if command -v mysqladmin >/dev/null 2>&1; then mysqladmin "$@" ping 2>&1;
    elif command -v mariadb-admin >/dev/null 2>&1; then mariadb-admin "$@" ping 2>&1;
    else echo "[-] mysqladmin tidak ada (apk add mariadb-client)" >&2; return 127; fi
  fi
}

# ---------------------------------------------------------------- Socket mode
# DB lokal via unix socket (XAMPP / mysql standar), tanpa container & tanpa TCP.
# db_type: mysql|mariadb -> sisi MySQL | pgsql -> sisi PG.
sock_dump_bin() {
  if [ -f "/opt/lampp/bin/mysqldump" ]; then echo /opt/lampp/bin/mysqldump;
  elif command -v mysqldump >/dev/null 2>&1; then echo mysqldump;
  else echo mariadb-dump; fi
}
test_socket() {
  if [ "${DB_TYPE:-mysql}" = "pgsql" ]; then
    echo "=== PGSQL socket: $(dirname "$SOCKET_PATH") db=$PG_DB user=$PG_USER ==="
    export PGPASSWORD="$PG_PASS"
    if timeout "$TIMEOUT_S" pg_isready -h "$(dirname "$SOCKET_PATH")" -U "$PG_USER" -d "$PG_DB" -t "$TIMEOUT_S"; then
      echo "[+] pg_isready OK"
    else echo "[-] pg_isready GAGAL"; unset PGPASSWORD; return 1; fi
    timeout 10 psql -h "$(dirname "$SOCKET_PATH")" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1 AS ok;" \
      -c "SELECT datname AS db, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate=false ORDER BY pg_database_size(datname);" \
      || echo "[-] query gagal (kemungkinan password salah)"
    unset PGPASSWORD
  else
    echo "=== MySQL socket: $SOCKET_PATH db=$MY_DB user=$MY_USER ==="
    [ -S "$SOCKET_PATH" ] || { echo "[-] socket tidak ada: $SOCKET_PATH (pastikan mysql jalan & path benar)"; return 1; }
    PASSARG=""; [ -n "$MY_PASS" ] && PASSARG="-p$MY_PASS"
    if mysqladmin --socket="$SOCKET_PATH" -u"$MY_USER" ${PASSARG:+"$PASSARG"} ping 2>&1 | grep -qi alive \
      || mariadb-admin --socket="$SOCKET_PATH" -u"$MY_USER" ${PASSARG:+"$PASSARG"} ping 2>&1 | grep -qi alive; then
      echo "[+] mysql ping OK (alive)"
    else echo "[-] mysql ping GAGAL (cek user/password)"; return 1; fi
    { mysql --socket="$SOCKET_PATH" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -e \
      "SELECT table_schema AS db, ROUND(SUM(data_length+index_length)/1024/1024,2) AS MB FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length+index_length);" 2>/dev/null \
    || mariadb --socket="$SOCKET_PATH" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -e \
      "SELECT table_schema AS db, ROUND(SUM(data_length+index_length)/1024/1024,2) AS MB FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length+index_length);" 2>&1; } | head -n 30
  fi
}
do_backup_socket_pg() {
  mkdir -p "$BACKUP_DIR"
  ts=$(date +"%Y%m%d_%H%M%S")
  export PGPASSWORD="$PG_PASS"
  if [ "$PG_DB" = "all" ]; then
    out="$BACKUP_DIR/pg_all_$ts.sql.gz"
    echo "[$(date '+%F %T')] PG[socket] backup --all-databases -> $out" | tee -a "$LOG_FILE"
    if timeout 600 pg_dumpall -h "$(dirname "$SOCKET_PATH")" -U "$PG_USER" 2>>"$LOG_FILE" | gzip -1 > "$out" \
      && verify_out "$out"; then
      echo "[+] PG OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else echo "[-] PG GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; unset PGPASSWORD; return 1; fi
  else
    out="$BACKUP_DIR/pg_${PG_DB}_$ts.sql.gz"
    echo "[$(date '+%F %T')] PG[socket] backup $PG_DB -> $out" | tee -a "$LOG_FILE"
    if timeout 600 pg_dump -h "$(dirname "$SOCKET_PATH")" -U "$PG_USER" -d "$PG_DB" --no-owner --no-acl 2>>"$LOG_FILE" | gzip -1 > "$out" \
      && verify_out "$out"; then
      echo "[+] PG OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else echo "[-] PG GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; unset PGPASSWORD; return 1; fi
  fi
  unset PGPASSWORD
}
do_backup_socket_mysql() {
  mkdir -p "$BACKUP_DIR"
  ts=$(date +"%Y%m%d_%H%M%S")
  [ -S "$SOCKET_PATH" ] || { echo "[-] socket tidak ada: $SOCKET_PATH (pastikan mysql jalan & path benar)" | tee -a "$LOG_FILE"; return 1; }
  PASSARG=""; [ -n "$MY_PASS" ] && PASSARG="-p$MY_PASS"
  DUMP=$(sock_dump_bin)
  if [ "$MY_DB" = "all" ]; then
    out="$BACKUP_DIR/mysql_all_$ts.sql.gz"
    echo "[$(date '+%F %T')] MySQL[socket] backup --all-databases -> $out (via $DUMP)" | tee -a "$LOG_FILE"
    if timeout 600 "$DUMP" --socket="$SOCKET_PATH" -u"$MY_USER" ${PASSARG:+"$PASSARG"} \
        --all-databases --single-transaction --quick --skip-lock-tables 2>>"$LOG_FILE" | gzip -1 > "$out" \
        && verify_out "$out"; then
      echo "[+] MySQL OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else echo "[-] MySQL GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; return 1; fi
  else
    out="$BACKUP_DIR/mysql_${MY_DB}_$ts.sql.gz"
    echo "[$(date '+%F %T')] MySQL[socket] backup $MY_DB -> $out (via $DUMP)" | tee -a "$LOG_FILE"
    if timeout 600 "$DUMP" --socket="$SOCKET_PATH" -u"$MY_USER" ${PASSARG:+"$PASSARG"} \
        "$MY_DB" --single-transaction --quick --skip-lock-tables 2>>"$LOG_FILE" | gzip -1 > "$out" \
        && verify_out "$out"; then
      echo "[+] MySQL OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else echo "[-] MySQL GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; return 1; fi
  fi
}

# ------------------------------------------------- 3. Tes koneksi CEPAT (<=3 dtk)
test_pg() {
  read_config
  if [ "${MODE:-docker}" = "host" ]; then
    echo "=== PGSQL host langsung: $PG_HOST:$PG_PORT db=$PG_DB user=$PG_USER ==="
    export PGPASSWORD="$PG_PASS"
    echo "[*] pg_isready (timeout $TIMEOUT_S dtk)..."
    if timeout "$TIMEOUT_S" pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t "$TIMEOUT_S"; then
      echo "[+] pg_isready OK"
    else echo "[-] pg_isready GAGAL"; unset PGPASSWORD; return 1; fi
    timeout 10 psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1 AS ok;" \
      -c "SELECT datname AS db, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate=false ORDER BY pg_database_size(datname);" \
      || echo "[-] query gagal"
    unset PGPASSWORD
    return 0
  fi
  echo "=== PGSQL: container=$PG_CT db=$PG_DB user=$PG_USER === [rt=$RT]"
  if ! have_container "$PG_CT"; then
    echo "[-] container '$PG_CT' TIDAK jalan. Daftar:"; $RT ps --format '{{.Names}} ({{.Image}})' 2>/dev/null || echo "($RT ps gagal)"
    return 1
  fi
  echo "[*] pg_isready (timeout $TIMEOUT_S dtk)..."
  if timeout "$TIMEOUT_S" $RT exec -e PGPASSWORD="$PG_PASS" "$PG_CT" pg_isready -U "$PG_USER" -d "$PG_DB" -t "$TIMEOUT_S"; then
    echo "[+] pg_isready OK"
  else
    echo "[-] pg_isready GAGAL (cek user/pass/nama db)"; return 1
  fi
  echo "[*] SELECT 1 + ukuran DB (biar tau mana yg kecil)..."
  timeout 10 $RT exec -e PGPASSWORD="$PG_PASS" "$PG_CT" \
    psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1 AS ok;" \
    -c "SELECT datname AS db, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datistemplate=false ORDER BY pg_database_size(datname);" \
    || echo "[-] query gagal (kemungkinan password salah)"
}

test_mysql() {
  read_config
  PASSARG=""; [ -n "$MY_PASS" ] && PASSARG="-p$MY_PASS"
  if [ "${MODE:-docker}" = "host" ]; then
    echo "=== MySQL host langsung: $MY_HOST:$MY_PORT db=$MY_DB user=$MY_USER ==="
    echo "[*] ping (timeout $TIMEOUT_S dtk)..."
    if ct_mysqladmin_ping "" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -h"$MY_HOST" -P"$MY_PORT" --connect-timeout=3 2>&1 | grep -qi alive; then
      echo "[+] mysql ping OK (alive)"
    else echo "[-] mysql ping GAGAL:"; ct_mysqladmin_ping "" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -h"$MY_HOST" -P"$MY_PORT" --connect-timeout=3 2>&1 | head -n 5; return 1; fi
    echo "[*] Ukuran tiap DB (paling kecil = paling cepet)..."
    ct_mysql_exec "" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -h"$MY_HOST" -P"$MY_PORT" --connect-timeout=3 -e \
      "SELECT table_schema AS db, ROUND(SUM(data_length+index_length)/1024/1024,2) AS MB FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length+index_length);" \
      2>&1 | head -n 30
    return 0
  fi
  echo "=== MySQL: container=$MY_CT db=$MY_DB user=$MY_USER === [rt=$RT]"
  if ! have_container "$MY_CT"; then
    echo "[-] container '$MY_CT' TIDAK jalan. Daftar:"; $RT ps --format '{{.Names}} ({{.Image}})' 2>/dev/null || echo "($RT ps gagal)"
    echo "[i] Kalau nama beda, edit config: mysql_container (menu 2). Auto-deteksi kandidat:"
    $RT ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i -E 'mysql|maria|db' || echo "(tidak ada kandidat mysql)"
    return 1
  fi
  echo "[*] mysqladmin ping (timeout $TIMEOUT_S dtk)..."
  if ct_mysqladmin_ping "$MY_CT" -u"$MY_USER" ${PASSARG:+"$PASSARG"} 2>&1 | grep -qi alive; then
    echo "[+] mysql ping OK (alive)"
  else
    echo "[-] mysql ping GAGAL:"; ct_mysqladmin_ping "$MY_CT" -u"$MY_USER" ${PASSARG:+"$PASSARG"} 2>&1 | head -n 5; return 1
  fi
  echo "[*] SELECT 1 + ukuran tiap DB (paling kecil = paling cepet di-backup)..."
  ct_mysql_exec "$MY_CT" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -e \
    "SELECT 1 AS ok; SELECT table_schema AS db, ROUND(SUM(data_length+index_length)/1024/1024,2) AS MB FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length+index_length);" \
    2>&1 | head -n 30
}

test_all() {
  read_config
  # Mode socket (XAMPP/lokal): satu jalur sesuai db_type
  if [ "${MODE:-docker}" = "socket" ]; then test_socket; return $?; fi
  # Mode host/TCP: pastikan port DB bisa ditembak dulu sebelum auth
  if [ "${MODE:-docker}" = "host" ]; then
    echo "--- Pra-cek TCP (tanpa auth, timeout 3 dtk) ---"
    if [ "${DB_TARGET:-both}" != "mysql" ]; then
      if tcp_check "$PG_HOST" "$PG_PORT"; then echo "[+] TCP PG $PG_HOST:$PG_PORT OPEN";
      else echo "[-] TCP PG $PG_HOST:$PG_PORT CLOSED/filtered — cek IP/port/firewall dulu!"; fi
    fi
    if [ "${DB_TARGET:-both}" != "pg" ]; then
      if tcp_check "$MY_HOST" "$MY_PORT"; then echo "[+] TCP MySQL $MY_HOST:$MY_PORT OPEN";
      else echo "[-] TCP MySQL $MY_HOST:$MY_PORT CLOSED/filtered — cek IP/port/firewall dulu!"; fi
    fi
    echo ""
  fi
  case "${DB_TARGET:-both}" in
    pg) test_pg ;;
    mysql) test_mysql ;;
    *) test_pg; echo; test_mysql ;;
  esac
}

# Validasi hasil backup: file harus ada & >100 byte (cegah sukses palsu / dump kosong)
verify_out() {
  local f="$1"
  local sz
  sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
  if [ ! -s "$f" ] || [ "$sz" -le 100 ]; then
    echo "[-] hasil backup kosong/invalid ($f, ${sz}B)" | tee -a "$LOG_FILE"
    rm -f "$f"; return 1
  fi
  return 0
}

# ------------------------------------------------- 4. Backup inti ($RT exec / host langsung)
do_backup_pg() {
  read_config
  mkdir -p "$BACKUP_DIR"
  ts=$(date +"%Y%m%d_%H%M%S")
  # Mode socket: pgsql hanya bila db_type=pgsql, selain itu skip (di-handle sisi MySQL)
  if [ "${MODE:-docker}" = "socket" ]; then
    if [ "${DB_TYPE:-mysql}" = "pgsql" ]; then do_backup_socket_pg; return $?; fi
    echo "[i] skip PG (mode socket, db_type=${DB_TYPE:-mysql})" | tee -a "$LOG_FILE"; return 0
  fi
  # Target mysql saja: skip sisi PG
  if [ "${DB_TARGET:-both}" = "mysql" ]; then
    echo "[i] skip PG (db_target=mysql)" | tee -a "$LOG_FILE"; return 0
  fi
  out="$BACKUP_DIR/pg_${PG_DB}_$ts.sql.gz"
  echo "[$(date '+%F %T')] PG backup $PG_DB -> $out [mode=${MODE:-docker}]" | tee -a "$LOG_FILE"
  if [ "${MODE:-docker}" = "host" ]; then
    export PGPASSWORD="$PG_PASS"
    if timeout 300 pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" --no-owner --no-acl 2>>"$LOG_FILE" | gzip -1 > "$out" \
       && verify_out "$out"; then
      echo "[+] PG OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else echo "[-] PG GAGAL, lihat $LOG_FILE" | tee -a "$LOG_FILE"; rm -f "$out"; unset PGPASSWORD; return 1; fi
    unset PGPASSWORD
    return 0
  fi
  if ! have_container "$PG_CT"; then echo "[-] skip pg: container stop" | tee -a "$LOG_FILE"; return 1; fi
  # pg_dump cepat: --no-owner --no-acl, gzip -1 (fast, bukan max)
  if timeout 300 $RT exec -e PGPASSWORD="$PG_PASS" "$PG_CT" \
      pg_dump -U "$PG_USER" -d "$PG_DB" --no-owner --no-acl 2>>"$LOG_FILE" | gzip -1 > "$out" \
      && verify_out "$out"; then
    echo "[+] PG OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
  else
    echo "[-] PG GAGAL, lihat $LOG_FILE" | tee -a "$LOG_FILE"; rm -f "$out"; return 1
  fi
}

do_backup_mysql() {
  read_config
  mkdir -p "$BACKUP_DIR"
  ts=$(date +"%Y%m%d_%H%M%S")
  PASSARG=""; [ -n "$MY_PASS" ] && PASSARG="-p$MY_PASS"
  # Mode socket: mysql/mariadb bila db_type bukan pgsql, selain itu skip
  if [ "${MODE:-docker}" = "socket" ]; then
    if [ "${DB_TYPE:-mysql}" != "pgsql" ]; then do_backup_socket_mysql; return $?; fi
    echo "[i] skip MySQL (mode socket, db_type=pgsql)" | tee -a "$LOG_FILE"; return 0
  fi
  # Target pg saja: skip sisi MySQL
  if [ "${DB_TARGET:-both}" = "pg" ]; then
    echo "[i] skip MySQL (db_target=pg)" | tee -a "$LOG_FILE"; return 0
  fi
  # Mode host langsung (bukan container): mysqldump/mariadb-dump ke host:port
  if [ "${MODE:-docker}" = "host" ]; then
    if [ "$MY_DB" = "all" ]; then out="$BACKUP_DIR/mysql_all_$ts.sql.gz";
      echo "[$(date '+%F %T')] MySQL[host] backup --all-databases -> $out" | tee -a "$LOG_FILE"
      if ct_mysqldump "" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -h"$MY_HOST" -P"$MY_PORT" \
          --all-databases --single-transaction --quick --skip-lock-tables 2>>"$LOG_FILE" | gzip -1 > "$out" \
          && verify_out "$out"; then
        echo "[+] MySQL OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
      else echo "[-] MySQL GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; return 1; fi
    else out="$BACKUP_DIR/mysql_${MY_DB}_$ts.sql.gz";
      echo "[$(date '+%F %T')] MySQL[host] backup $MY_DB -> $out" | tee -a "$LOG_FILE"
      if ct_mysqldump "" -u"$MY_USER" ${PASSARG:+"$PASSARG"} -h"$MY_HOST" -P"$MY_PORT" \
          "$MY_DB" --single-transaction --quick --skip-lock-tables 2>>"$LOG_FILE" | gzip -1 > "$out" \
          && verify_out "$out"; then
        echo "[+] MySQL OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
      else echo "[-] MySQL GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; return 1; fi
    fi
    return 0
  fi
  if [ "$MY_DB" = "all" ]; then
    out="$BACKUP_DIR/mysql_all_$ts.sql.gz"
    echo "[$(date '+%F %T')] MySQL backup --all-databases -> $out" | tee -a "$LOG_FILE"
    if ! have_container "$MY_CT"; then echo "[-] skip mysql: container stop" | tee -a "$LOG_FILE"; return 1; fi
    # --single-transaction --quick = cepat & non-blocking InnoDB; skip-lock biar ga lock
    if ct_mysqldump "$MY_CT" -u"$MY_USER" ${PASSARG:+"$PASSARG"} \
        --all-databases --single-transaction --quick --skip-lock-tables 2>>"$LOG_FILE" | gzip -1 > "$out" \
        && verify_out "$out"; then
      echo "[+] MySQL OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else
      echo "[-] MySQL GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; return 1
    fi
  else
    out="$BACKUP_DIR/mysql_${MY_DB}_$ts.sql.gz"
    echo "[$(date '+%F %T')] MySQL backup $MY_DB -> $out" | tee -a "$LOG_FILE"
    if ! have_container "$MY_CT"; then echo "[-] skip mysql: container stop" | tee -a "$LOG_FILE"; return 1; fi
    if ct_mysqldump "$MY_CT" -u"$MY_USER" ${PASSARG:+"$PASSARG"} \
        "$MY_DB" --single-transaction --quick --skip-lock-tables 2>>"$LOG_FILE" | gzip -1 > "$out" \
        && verify_out "$out"; then
      echo "[+] MySQL OK: $(du -h "$out" | cut -f1) $out" | tee -a "$LOG_FILE"
    else
      echo "[-] MySQL GAGAL" | tee -a "$LOG_FILE"; rm -f "$out"; return 1
    fi
  fi
}

cleanup_old() {
  read_config
  find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +"$RETAIN_DAYS" -exec rm -f {} \;
  echo "[$(date '+%F %T')] Cleanup >$RETAIN_DAYS hari OK" >> "$LOG_FILE"
}

run_backup() {
  echo "=== Backup: PG dulu (kecil/cepat), lalu MySQL ==="
  do_backup_pg
  do_backup_mysql
  cleanup_old
  echo "[+] Selesai. Isi $BACKUP_DIR:"; ls -lh "$BACKUP_DIR" | tail -n 10
}

# ---------------------------------------------------------------- 5. Cron (Alpine busybox)
cron_on() {
  read_config
  sp="$(realpath "$0")"
  crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
  (crontab -l 2>/dev/null; echo "$BACKUP_MINUTE $BACKUP_HOUR * * * /bin/bash $sp run-backup $CRON_TAG") | crontab -
  (crond 2>/dev/null || true)
  echo "[+] Cron ON: tiap hari $BACKUP_HOUR:$BACKUP_MINUTE"
  crontab -l 2>/dev/null | grep "$CRON_TAG"
}
cron_off() {
  crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
  echo "[+] Cron OFF"
}

edit_config_simple() {
  read_config
  if tui_on; then
    whiptail --backtitle "$(tui_back)" --title "Config sekarang" --msgbox "$(cat "$CONFIG_FILE")" 20 72
  else
    echo "--- Config sekarang ($CONFIG_FILE) ---"
    cat "$CONFIG_FILE"
    echo "--- Edit cepat (Enter = keep) ---"
  fi
  MODE=$(tui_pick "Mode koneksi" "Pilih cara backup:" "$MODE" docker host socket)
  case "$MODE" in docker|host|socket) ;; *) echo "[i] mode tidak dikenal, tetap: ${MODE:-docker}"; read_config; esac
  case "$MODE" in
    socket)
      DB_TYPE=$(tui_pick "Tipe database" "DB lokal via socket:" "$DB_TYPE" mysql mariadb pgsql)
      SOCKET_PATH=$(tui_ask "Socket path" "Path unix socket:" "$SOCKET_PATH")
      if [ "$DB_TYPE" = "pgsql" ]; then
        PG_USER=$(tui_ask "PostgreSQL (socket)" "User:" "$PG_USER")
        v=$(tui_pass "PostgreSQL (socket)" "Password (batal = keep):"); [ -n "$v" ] && PG_PASS=$v
        PG_DB=$(tui_ask "PostgreSQL (socket)" "Database (kecil / 'all'):" "$PG_DB")
      else
        MY_USER=$(tui_ask "MySQL/MariaDB (socket)" "User:" "$MY_USER")
        v=$(tui_pass "MySQL/MariaDB (socket)" "Password (kosong = tanpa pw, batal = keep):"); [ -n "$v" ] && MY_PASS=$v
        MY_DB=$(tui_ask "MySQL/MariaDB (socket)" "Database (kecil / 'all'):" "$MY_DB")
      fi
      ;;
    host)
      DB_TARGET=$(tui_pick "Target backup" "Backup DB apa?" "$DB_TARGET" pg mysql both)
      if [ "$DB_TARGET" != "mysql" ]; then
        PG_HOST=$(tui_ask "PostgreSQL (TCP)" "Host:" "$PG_HOST")
        PG_PORT=$(tui_ask "PostgreSQL (TCP)" "Port:" "$PG_PORT")
        PG_USER=$(tui_ask "PostgreSQL (TCP)" "User:" "$PG_USER")
        v=$(tui_pass "PostgreSQL (TCP)" "Password (batal = keep):"); [ -n "$v" ] && PG_PASS=$v
        PG_DB=$(tui_ask "PostgreSQL (TCP)" "Database (kecil):" "$PG_DB")
      fi
      if [ "$DB_TARGET" != "pg" ]; then
        MY_HOST=$(tui_ask "MySQL/MariaDB (TCP)" "Host:" "$MY_HOST")
        MY_PORT=$(tui_ask "MySQL/MariaDB (TCP)" "Port:" "$MY_PORT")
        MY_USER=$(tui_ask "MySQL/MariaDB (TCP)" "User:" "$MY_USER")
        v=$(tui_pass "MySQL/MariaDB (TCP)" "Password (kosong = tanpa pw, batal = keep):"); [ -n "$v" ] && MY_PASS=$v
        MY_DB=$(tui_ask "MySQL/MariaDB (TCP)" "Database (kecil / 'all'):" "$MY_DB")
      fi
      ;;
    *)
      MODE="docker"
      DB_TARGET=$(tui_pick "Target backup" "Backup DB apa?" "$DB_TARGET" pg mysql both)
      if [ "$DB_TARGET" != "mysql" ]; then
        PG_CT=$(tui_ask "PostgreSQL (container)" "Nama container:" "$PG_CT")
        PG_USER=$(tui_ask "PostgreSQL (container)" "User:" "$PG_USER")
        v=$(tui_pass "PostgreSQL (container)" "Password (batal = keep):"); [ -n "$v" ] && PG_PASS=$v
        PG_DB=$(tui_ask "PostgreSQL (container)" "Database (kecil):" "$PG_DB")
      fi
      if [ "$DB_TARGET" != "pg" ]; then
        MY_CT=$(tui_ask "MySQL/MariaDB (container)" "Nama container:" "$MY_CT")
        MY_USER=$(tui_ask "MySQL/MariaDB (container)" "User:" "$MY_USER")
        v=$(tui_pass "MySQL/MariaDB (container)" "Password (kosong = tanpa pw, batal = keep):"); [ -n "$v" ] && MY_PASS=$v
        MY_DB=$(tui_ask "MySQL/MariaDB (container)" "Database (kecil / 'all'):" "$MY_DB")
      fi
      ;;
  esac
  BACKUP_DIR=$(tui_ask "Penyimpanan" "Direktori backup:" "$BACKUP_DIR")
  BACKUP_HOUR=$(tui_ask "Jadwal" "Jam backup (00-23):" "$BACKUP_HOUR")
  BACKUP_MINUTE=$(tui_ask "Jadwal" "Menit backup:" "$BACKUP_MINUTE")
  RETAIN_DAYS=$(tui_ask "Retensi" "Hapus file > N hari:" "$RETAIN_DAYS")
  python3 - "$CONFIG_FILE" "$MODE" "$DB_TARGET" "$DB_TYPE" "$SOCKET_PATH" "$PG_CT" "$PG_USER" "$PG_PASS" "$PG_DB" "$PG_HOST" "$PG_PORT" "$MY_CT" "$MY_USER" "$MY_PASS" "$MY_DB" "$MY_HOST" "$MY_PORT" "$BACKUP_DIR" "$BACKUP_HOUR" "$BACKUP_MINUTE" "$RETAIN_DAYS" << 'PYEOF'
import json,sys
f,mode,dbtgt,dbt,sp,pgct,pgu,pgp,pgdb,pgh,pgp2,myct,myu,myp,mydb,myh,myp2,bdir,bh,bm,ret = sys.argv[1:]
d = json.load(open(f))
d.update({"mode":mode or "docker","db_target":dbtgt or "both","db_type":dbt or "mysql","socket_path":sp,
 "pg_container":pgct,"pg_user":pgu,"pg_password":pgp,"pg_db":pgdb,
 "pg_host":pgh,"pg_port":int(pgp2) if str(pgp2).isdigit() else 5432,
 "mysql_container":myct,"mysql_user":myu,"mysql_password":myp,"mysql_db":mydb,
 "mysql_host":myh,"mysql_port":int(myp2) if str(myp2).isdigit() else 3306,
 "backup_dir":bdir,"backup_hour":bh,"backup_minute":bm,
 "retain_days":int(ret) if str(ret).isdigit() else 7})
json.dump(d, open(f,'w'), indent=2)
PYEOF
  chmod 600 "$CONFIG_FILE"
  tui_msg "Config" "Konfigurasi berhasil disimpan!"
}

# ------------------------------------------------- Update dari repo GitHub
remote_ver() {
  # API GitHub selalu fresh (raw.githubusercontent di-cache CDN ~5 mnt).
  # API primer -> raw fallback (buat server yg blokir api.github.com / kena rate-limit).
  local v=""
  v=$(remote_ver_api)
  if [ -z "$v" ]; then
    local url="https://raw.githubusercontent.com/$REPO/main/VERSION"
    if command -v curl >/dev/null 2>&1; then v=$(curl -fsSL --max-time 10 "$url" 2>/dev/null);
    elif command -v wget >/dev/null 2>&1; then v=$(wget -qO- --timeout=10 "$url" 2>/dev/null); fi
  fi
  v=$(echo "$v" | tr -d '[:space:]')
  echo "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo "$v" || echo ""
}
remote_ver_api() {
  local j=""
  if command -v curl >/dev/null 2>&1; then j=$(curl -fsSL --max-time 10 "https://api.github.com/repos/$REPO/contents/VERSION" 2>/dev/null);
  elif command -v wget >/dev/null 2>&1; then j=$(wget -qO- --timeout=10 "https://api.github.com/repos/$REPO/contents/VERSION" 2>/dev/null); fi
  [ -z "$j" ] && return 1
  echo "$j" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode().strip())" 2>/dev/null
}
check_update() {
  echo "--- Cek update $APP_NAME ---"
  echo "[*] Versi lokal : $APP_VERSION"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "[-] butuh curl/wget dulu (apk add curl / apt install curl)"; return 1
  fi
  RV=$(remote_ver)
  [ -z "$RV" ] && { echo "[-] gagal hubungi repo, cek koneksi internet."; return 1; }
  echo "[*] Versi repo  : $RV"
  if [ "$RV" = "$APP_VERSION" ]; then echo "[+] Sudah versi terbaru.";
  else echo "[!] Update tersedia: $APP_VERSION -> $RV (pilih menu Update)"; fi
}
do_update() {
  echo "--- Update $APP_NAME ---"
  RV=$(remote_ver)
  [ -z "$RV" ] && { echo "[-] gagal hubungi repo."; return 1; }
  if [ "$RV" = "$APP_VERSION" ]; then tui_msg "Update $APP_NAME" "Sudah versi terbaru ($APP_VERSION)."; return 0; fi
  tui_yesno "Update $APP_NAME" "Update $APP_VERSION -> $RV sekarang?" || return 0
  SELF="$(realpath "$0")"
  TMP="$(mktemp /tmp/rexa-update.XXXXXX)"
  URL="https://github.com/$REPO/releases/latest/download/rexa-db-backup.sh"
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 60 "$URL" -o "$TMP";
  else wget -q --timeout=60 -O "$TMP" "$URL"; fi
  [ -s "$TMP" ] || { tui_msg "Update $APP_NAME" "Download gagal, periksa koneksi."; rm -f "$TMP"; return 1; }
  bash -n "$TMP" || { tui_msg "Update $APP_NAME" "File update rusak (sintaks), dibatalkan."; rm -f "$TMP"; return 1; }
  NV=$(grep '^APP_VERSION=' "$TMP" | cut -d'"' -f2)
  cp "$SELF" "$SELF.bak_$(date +%Y%m%d_%H%M%S)"
  cat "$TMP" > "$SELF" && chmod +x "$SELF" && rm -f "$TMP"
  echo "[+] Update OK → $NV (backup lama: $SELF.bak_*). Restart ke versi baru..."
  exec "$SELF" || { echo "[-] restart otomatis gagal, jalankan ulang manual: $SELF"; exit 1; }
}

# ------------------------------------------------- Lapisan TUI (whiptail) + fallback teks
# GUI dipakai bila whiptail ada + stdin terminal + tidak dipaksa teks (REXA_TEXT=1).
# Cek stdin (bukan stdout) karena form dipanggil dalam $(...) yg stdout-nya pipe.
tui_on() { command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ -z "${REXA_TEXT:-}" ]; }
tui_back() { echo "$APP_NAME $APP_VERSION | $(os_info) | mode: ${MODE:-docker}"; }
# Buang sisa ketikan (mis. Enter dobel) biar dialog baru tidak ke-dismiss instan.
tui_drain() { local _d; while read -t 0.2 -rs -n 1 _d; do :; done; }
tui_ask() { # $1=judul $2=prompt $3=default -> stdout nilai (batal=keep default)
  if tui_on; then tui_drain; whiptail --backtitle "$(tui_back)" --title "$1" --inputbox "$2" 10 65 "$3" 3>&1 1>&2 2>&3 || echo "$3";
  else printf "%s [%s]: " "$2" "$3" >&2; read -r v || v=""; echo "${v:-$3}"; fi
}
tui_pass() { # $1=judul $2=prompt -> stdout password (batal="")
  if tui_on; then tui_drain; whiptail --backtitle "$(tui_back)" --title "$1" --passwordbox "$2" 10 65 3>&1 1>&2 2>&3 || echo "";
  else printf "%s: " "$2" >&2; read -rs v || v=""; echo >&2; echo "$v"; fi
}
tui_pick() { # $1=judul $2=prompt $3=default $4..=opsi -> stdout pilihan
  local t="$1" p="$2" d="$3"; shift 3
  if tui_on; then
    tui_drain
    local args=()
    for o in "$@"; do if [ "$o" = "$d" ]; then args+=("$o" "" ON); else args+=("$o" "" OFF); fi; done
    whiptail --backtitle "$(tui_back)" --title "$t" --radiolist "$p" 16 65 "$#" "${args[@]}" 3>&1 1>&2 2>&3 || echo "$d"
  else
    printf "%s (opsi: %s) [%s]: " "$p" "$*" "$d" >&2; read -r v || v=""; echo "${v:-$d}"
  fi
}
tui_box() { # $1=judul ; stdin -> textbox GUI (scroll) / cat teks
  if tui_on; then
    local f
    f=$(mktemp /tmp/rexa-box.XXXXXX)
    cat > "$f"
    if [ -s "$f" ]; then
      tui_drain
      whiptail --backtitle "$(tui_back)" --title "$1" --scrolltext --textbox "$f" 22 78
    fi
    rm -f "$f"
  else cat; fi
}
tui_msg() { # $1=judul $2=teks -> msgbox GUI / echo
  if tui_on; then tui_drain; whiptail --backtitle "$(tui_back)" --title "$1" --msgbox "$2" 14 65;
  else echo "$2"; fi
}
tui_yesno() { # $1=judul $2=teks -> return 0 bila Ya
  if tui_on; then tui_drain; whiptail --backtitle "$(tui_back)" --title "$1" --yesno "$2" 10 60 3>&1 1>&2 2>&3;
  else printf "%s (y/n): " "$2" >&2; read -r c || return 1; [ "$c" = "y" ]; fi
}

# ------------------------------------------------- Pilih tampilan saat dibuka
pick_ui() {
  [ -n "${REXA_UI:-}" ] && return 0
  # Non-interaktif (cron/pipe) atau tanpa whiptail: langsung CLI teks.
  if ! command -v whiptail >/dev/null 2>&1 || ! [ -t 0 ]; then REXA_UI=cli; return 0; fi
  local c
  c=$(whiptail --backtitle "$APP_NAME $APP_VERSION" --title "Pilih tampilan" \
    --radiolist "Jalankan $APP_NAME via:" 14 60 3 \
    "GUI" "Grafis di terminal (panah + Enter)" ON \
    "CLI" "Teks biasa" OFF \
    "WEB" "Browser (segera hadir)" OFF 3>&1 1>&2 2>&3) || { REXA_UI=gui; return 0; }
  case "$c" in
    WEB) whiptail --backtitle "$APP_NAME $APP_VERSION" --title "WEB" \
           --msgbox "Versi WEB segera hadir.\nUntuk sekarang pakai GUI atau CLI dulu." 10 55
         pick_ui ;;
    CLI) REXA_UI=cli ;;
    *)   REXA_UI=gui ;;
  esac
}

menu() {
  pick_ui
  [ "${REXA_UI:-gui}" = "cli" ] && export REXA_TEXT=1
  while true; do
    read_config
    if tui_on; then
      c=$(whiptail --backtitle "$(tui_back)" --title "Menu utama" --cancel-button "Keluar" \
        --menu "Pilih aksi (panah + Enter, Tab = pindah tombol):" 22 72 11 \
        "1" "Cek & install deps (apk/apt)" \
        "2" "Edit config (mode + koneksi + db)" \
        "3" "Tes koneksi CEPAT (wajib sebelum backup)" \
        "4" "Backup sekarang" \
        "5" "Backup PG saja" \
        "6" "Backup MySQL saja" \
        "7" "Cron ON (backup otomatis harian)" \
        "8" "Cron OFF + lihat log" \
        "9" "Cek update dari repo (lokal $APP_VERSION)" \
        "10" "Update script ke versi terbaru" \
        "11" "Keluar" 3>&1 1>&2 2>&3) || exit 0
    else
    echo ""
    echo "================================================================"
    echo "  $APP_NAME"
    echo "  OS: $(os_info) | runtime: $RT | mode: ${MODE:-docker}"
    echo "================================================================"
    echo "1) Cek & install deps (apk/apt)"
    echo "2) Edit config (mode docker/host/socket, koneksi & db)"
    echo "3) Tes koneksi CEPAT pg + mysql (TCP + auth, wajib sebelum backup)"
    echo "4) Backup sekarang (pg kecil dulu, lalu mysql)"
    echo "5) Backup PG saja"
    echo "6) Backup MySQL saja"
    echo "7) Cron ON"
    echo "8) Cron OFF + lihat log"
    echo "9) Cek update dari repo (lokal $APP_VERSION)"
    echo "10) Update script ke versi terbaru"
    echo "11) Keluar"
    echo "----------------------------------------------------------------"
    echo "  $APP_FOOTER"
    echo "================================================================"
    printf "Pilih [1-11]: "; read -r c || exit 0
    fi
    case "$c" in
      1) check_dependencies 2>&1 | tui_box "Cek dependensi" ;;
      2) edit_config_simple ;;
      3) test_all 2>&1 | tui_box "Tes koneksi" ;;
      4) run_backup 2>&1 | tui_box "Backup sekarang" ;;
      5) { do_backup_pg; cleanup_old; } 2>&1 | tui_box "Backup PG" ;;
      6) { do_backup_mysql; cleanup_old; } 2>&1 | tui_box "Backup MySQL" ;;
      7) cron_on 2>&1 | tui_box "Cron ON" ;;
      8) { cron_off; echo "--- cron:"; crontab -l 2>/dev/null | grep "$CRON_TAG" || echo "(off)"; echo "--- log tail:"; tail -n 20 "$LOG_FILE" 2>/dev/null || echo "(belum ada log)"; } 2>&1 | tui_box "Cron + Log" ;;
      9) check_update 2>&1 | tui_box "Cek update" ;;
      10) do_update ;;
      11) exit 0 ;;
      *) echo "?" ;;
    esac
  done
}

case "${1:-}" in
  run-backup) run_backup ;;
  test) test_all ;;
  backup-pg) do_backup_pg; cleanup_old ;;
  backup-mysql) do_backup_mysql; cleanup_old ;;
  check-update) check_update ;;
  update) do_update ;;
  version) echo "$APP_NAME $APP_VERSION" ;;
  *) menu ;;
esac
