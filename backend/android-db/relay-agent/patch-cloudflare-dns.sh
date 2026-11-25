#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"
REF="${ANI_RELAY_REF:-}"
NAME="ani-games-relay-agent"
SERVICE="$PREFIX/var/service/$NAME"
REPORT="$HOME/storage/downloads/ANI-Relay-Agent-DNS-Patch-Report.txt"
BASE="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom"
fail() { printf 'GAGAL: %s\n' "$*" | tee -a "$REPORT"; exit 1; }
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }

[ -d "$HOME/storage/downloads" ] && [ -w "$HOME/storage/downloads" ] || fail "Folder Download belum tersedia."
: > "$REPORT"
say "ANI GAMES READY - RELAY AGENT DNS PATCH"
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || fail "Commit SHA tidak valid."
[ -x "$PREFIX/bin/sv" ] || fail "Termux runit/sv tidak tersedia."
[ -x "$SERVICE/run" ] || fail "Service Relay Agent belum terpasang."

AGENT_DIR="$(sed -n 's/^cd "\(.*\)"$/\1/p' "$SERVICE/run" | head -n 1)"
[ -n "$AGENT_DIR" ] && [ -d "$AGENT_DIR" ] || fail "Folder Agent aktif tidak dapat diidentifikasi dari service run."
[ -f "$AGENT_DIR/agent.mjs" ] && [ -f "$AGENT_DIR/protocol.mjs" ] || fail "File Agent aktif tidak lengkap."

TMP="$(mktemp -d "$HOME/.ani-relay-dns-patch.XXXXXX")"
cleanup() { [ ! -d "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

for file in agent.mjs protocol.mjs protocol.test.mjs; do
  curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 \
    "$BASE/$REF/backend/android-db/relay-agent/$file" -o "$TMP/$file" || fail "Download $file gagal."
  [ -s "$TMP/$file" ] || fail "File $file kosong."
done

cd "$TMP"
node --check agent.mjs
node --check protocol.mjs
node --test protocol.test.mjs
say "Syntax dan tes protokol/DNS: LULUS."

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$AGENT_DIR/backup-$STAMP"
cp -p "$AGENT_DIR/agent.mjs" "$AGENT_DIR/protocol.mjs" "$AGENT_DIR/backup-$STAMP/"
say "Backup file lama: $AGENT_DIR/backup-$STAMP"

sv down "$NAME" >/dev/null 2>&1 || fail "Tidak dapat menghentikan Agent untuk patch."
for file in agent.mjs protocol.mjs protocol.test.mjs; do
  install -m 600 "$TMP/$file" "$AGENT_DIR/.$file.new"
  mv -f "$AGENT_DIR/.$file.new" "$AGENT_DIR/$file"
done
sv up "$NAME" >/dev/null 2>&1 || fail "File baru terpasang tetapi Agent belum dapat di-start."
sleep 5

say "Status Agent:"
sv status "$NAME" 2>&1 | tee -a "$REPORT" || true
LOG="$PREFIX/var/log/sv/$NAME/current"
if [ -f "$LOG" ]; then
  say "Log Agent:"
  tail -n 20 "$LOG" | tee -a "$REPORT"
fi

GATEWAY="ani-games-db-android-stage-gateway.anigamesready.workers.dev"
RELAY="ani-games-db-android-stage-ws-relay.anigamesready.workers.dev"
for item in "$GATEWAY|/_ani_gateway/health" "$RELAY|/_relay/health"; do
  host="${item%%|*}"
  path="${item#*|}"
  say "Health test: $host$path"
  curl --resolve "$host:443:104.18.13.15" -sS --connect-timeout 8 --max-time 15 \
    -o "$TMP/health.json" -w 'HTTP=%{http_code} TLS=%{ssl_verify_result} IP=%{remote_ip}\n' \
    "https://$host$path" 2>&1 | tee -a "$REPORT" || true
  if command -v python >/dev/null 2>&1 && [ -s "$TMP/health.json" ]; then
    python -c 'import json,sys; d=json.load(open(sys.argv[1])); keys=("gateway","relay","agent_connected","api","database","upstream_active","error"); print(" ".join(f"{k}={d[k]}" for k in keys if k in d))' "$TMP/health.json" 2>/dev/null | tee -a "$REPORT" || true
  fi
done

say "Patch DNS selesai. TLS certificate verification tetap aktif."
say "Laporan: Internal Storage/Download/ANI-Relay-Agent-DNS-Patch-Report.txt"
say "PostgreSQL, API lama, DB, dan Worker secrets tidak diubah."
