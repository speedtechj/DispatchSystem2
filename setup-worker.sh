#!/usr/bin/env bash
# Part 40 · Settings → Photo storage: a background worker with Supervisor.
# Run once on the server as root, in the wmsv2 folder:   sudo bash setup-worker.sh
# Safe to run again: it only fixes what is missing. Nothing in the app files is changed
# (only QUEUE_CONNECTION in .env when it is not "database", with a backup first).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${NAME:-wmsv2-worker}"
CONF="/etc/supervisor/conf.d/${NAME}.conf"
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run it as root: sudo bash setup-worker.sh"
[ -f "$APP_DIR/artisan" ] || fail "artisan not found in $APP_DIR (run it from the wmsv2 folder)"

# 1 · The user that owns the site (Plesk system user), never root
RUN_AS="$(stat -c '%U' "$APP_DIR")"
[ "$RUN_AS" != "root" ] || RUN_AS="$(stat -c '%U' "$APP_DIR/storage")"
ok "Site user: $RUN_AS"

# 2 · PHP: PHP=/path/to/php to choose; else the newest Plesk PHP; else php
PHP_BIN="${PHP:-}"
if [ -z "$PHP_BIN" ] && [ -d /opt/plesk/php ]; then
  for v in $(ls -1 /opt/plesk/php | sort -rV); do
    if [ -x "/opt/plesk/php/$v/bin/php" ]; then PHP_BIN="/opt/plesk/php/$v/bin/php"; break; fi
  done
fi
PHP_BIN="${PHP_BIN:-$(command -v php || true)}"
[ -n "$PHP_BIN" ] && [ -x "$PHP_BIN" ] || fail "PHP not found. Run: PHP=/opt/plesk/php/8.3/bin/php bash setup-worker.sh"
"$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.2", "<") ? 1 : 0);' || fail "$PHP_BIN is older than 8.2. Run: PHP=/opt/plesk/php/8.3/bin/php bash setup-worker.sh"
ok "PHP: $PHP_BIN ($("$PHP_BIN" -r 'echo PHP_VERSION;'))"

# 3 · The queue uses the database
ENV_FILE="$APP_DIR/.env"
if grep -qE '^QUEUE_CONNECTION=database\s*$' "$ENV_FILE"; then
  ok "QUEUE_CONNECTION=database"
else
  cp "$ENV_FILE" "$ENV_FILE.before-worker-$(date +%Y%m%d%H%M%S)"
  if grep -qE '^QUEUE_CONNECTION=' "$ENV_FILE"; then
    sed -i 's/^QUEUE_CONNECTION=.*/QUEUE_CONNECTION=database/' "$ENV_FILE"
  else
    printf '\nQUEUE_CONNECTION=database\n' >> "$ENV_FILE"
  fi
  sudo -u "$RUN_AS" "$PHP_BIN" "$APP_DIR/artisan" config:cache >/dev/null 2>&1 || true
  ok "QUEUE_CONNECTION set to database (old .env kept as a backup)"
fi

# 4 · Supervisor
if ! command -v supervisorctl >/dev/null 2>&1; then
  info "Installing Supervisor…"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq supervisor
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q supervisor
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q supervisor
  else
    fail "Could not install Supervisor (no apt-get, dnf or yum). Install it, then run this again."
  fi
fi
for svc in supervisor supervisord; do
  systemctl enable --now "$svc" >/dev/null 2>&1 && break || true
done
ok "Supervisor installed and on"

# RHEL keeps the programs in /etc/supervisord.d
if [ ! -d /etc/supervisor/conf.d ] && [ -d /etc/supervisord.d ]; then CONF="/etc/supervisord.d/${NAME}.ini"; fi
mkdir -p "$(dirname "$CONF")"

# 5 · The worker
NEW_CONF="[program:${NAME}]
command=${PHP_BIN} ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --timeout=600 --max-time=3600
directory=${APP_DIR}
user=${RUN_AS}
numprocs=2
process_name=%(program_name)s_%(process_num)02d
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
stopwaitsecs=620
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/worker.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=2
"
if [ -f "$CONF" ] && [ "$(cat "$CONF")" = "$(printf '%s' "$NEW_CONF")" ]; then
  ok "Worker config already set ($CONF)"
else
  printf '%s' "$NEW_CONF" > "$CONF"
  ok "Worker config written ($CONF)"
fi
touch "$APP_DIR/storage/logs/worker.log" && chown "$RUN_AS" "$APP_DIR/storage/logs/worker.log" || true

supervisorctl reread >/dev/null
supervisorctl update >/dev/null
sudo -u "$RUN_AS" "$PHP_BIN" "$APP_DIR/artisan" queue:restart >/dev/null 2>&1 || true
sleep 3
supervisorctl status "${NAME}:*" || true

if supervisorctl status "${NAME}:*" 2>/dev/null | grep -q RUNNING; then
  ok "Done. The worker starts by itself after a reboot."
  info "After each Part script:  php artisan queue:restart"
  info "Log: ${APP_DIR}/storage/logs/worker.log"
else
  fail "The worker is not RUNNING. See: tail -50 ${APP_DIR}/storage/logs/worker.log"
fi
