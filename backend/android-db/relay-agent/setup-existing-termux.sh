#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PREFIX="$(printenv PREFIX || printf '/data/data/com.termux/files/usr')"
HOME="$(printenv HOME || printf '/data/data/com.termux/files/home')"
REF="$(printenv ANI_RELAY_REF || true)"
DOWNLOADS="$HOME/storage/downloads"
REPORT="$DOWNLOADS/ANI-Relay-Agent-Setup-Report.txt"
SECRET_FILE="$HOME/ani-games-db-android-stage/relay-worker-shared-secret.txt"
API_URL="http://127.0.0.1:8788"
BASE_URL="https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
BASE_RAW="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
fail() { say "STATUS: GAGAL"; say "PENYEBAB: $*"; say "Laporan: $REPORT"; exit 1; }

[ "$PREFIX" = "/data/data/com.termux/files/usr" ] || { printf 'Jalankan dari Termux Android.\n'; exit 1; }
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || { printf 'ANI_RELAY_REF SHA tidak valid.\n'; exit 1; }
[ -d "$DOWNLOADS" ] && [ -w "$DOWNLOADS" ] || { printf 'Akses Download belum aktif. Jalankan termux-setup-storage lalu ulangi.\n'; exit 1; }

: > "$REPORT"
say "ANI GAMES READY - RELAY AGENT SETUP"
say "Commit Agent: $REF"
say "Semua laporan disimpan di Internal Storage/Download."
say "Nilai secret tidak ditampilkan atau ditulis ke laporan."

[ -s "$SECRET_FILE" ] || fail "File secret Relay lokal tidak ditemukan: $SECRET_FILE"
SECRET_VALUE="$(tr -d '\r\n' < "$SECRET_FILE")"
[[ "$SECRET_VALUE" =~ ^[A-Za-z0-9._~+/=-]{32,512}$ ]] || fail "Format file secret Relay lokal tidak valid."
say "Sumber secret Relay lokal: ADA (isi dirahasiakan)"
say "Panjang secret: ${#SECRET_VALUE} karakter"
CONFIG_DIR="$HOME/.config/ani-games-relay-agent"
ENV_FILE="$CONFIG_DIR/agent.env"
if [ -f "$ENV_FILE" ]; then
  COUNT="$(grep -c '^RELAY_SHARED_SECRET=' "$ENV_FILE" || true)"
  EXISTING="$(sed -n 's/^RELAY_SHARED_SECRET=//p' "$ENV_FILE" | head -n 1)"
  [ "$COUNT" = "1" ] && [ "$EXISTING" = "$SECRET_VALUE" ] || fail "agent.env sudah ada tetapi berbeda; file lama dipertahankan dan tidak ditimpa."
  say "Konfigurasi Agent lama: cocok; dipertahankan."
else
  say "Konfigurasi Agent: installer akan membuatnya dari file lokal."
fi
unset SECRET_VALUE EXISTING

command -v node >/dev/null 2>&1 || fail "Node.js belum terpasang."
command -v npm >/dev/null 2>&1 || fail "npm belum tersedia."
command -v curl >/dev/null 2>&1 || fail "curl belum tersedia."
command -v sv >/dev/null 2>&1 || fail "termux-services/runit belum tersedia."
[ -x "$PREFIX/share/termux-services/svlogger" ] || fail "svlogger tidak ditemukan; Agent tidak dipasang."
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 20 ] || fail "Node.js 20+ diperlukan. Versi sekarang: $(node --version)."
say "Runtime Node.js: $(node --version)"

curl --fail --silent --show-error --connect-timeout 3 --max-time 8 "$API_URL/health" >/dev/null \
  || fail "API lokal 127.0.0.1:8788 belum merespons. API lama dan PostgreSQL tidak disentuh."
say "API lokal: merespons."

SERVICE_DIR="$PREFIX/var/service/ani-games-relay-agent"
AGENT_DIR="$HOME/ani-games-ready-relay-agent-$REF"
[ ! -e "$SERVICE_DIR" ] || fail "Service Agent sudah ada; tidak ditimpa."
[ ! -e "$AGENT_DIR" ] || fail "Folder Agent versi ini sudah ada; tidak ditimpa."

say "Mengunduh dan memasang Agent dari commit yang sudah diuji..."
if ! curl -fsSL "$BASE_RAW/$REF/backend/android-db/relay-agent/install.sh" | \
  ANI_RELAY_REF="$REF" ANI_RELAY_SECRET_FILE="$SECRET_FILE" bash 2>&1 | tee -a "$REPORT"; then
  fail "Installer Agent gagal. Lihat log di laporan Download."
fi

[ -x "$SERVICE_DIR/run" ] || fail "File service Agent tidak terbentuk."
say "Instalasi: berhasil. Service dibuat dalam kondisi STOPPED."

say "Menjalankan service Relay Agent..."
rm -f "$SERVICE_DIR/down"
sv up ani-games-relay-agent 2>&1 | tee -a "$REPORT"
sleep 5
sv status ani-games-relay-agent 2>&1 | tee -a "$REPORT"

LOGFILE="$PREFIX/var/log/sv/ani-games-relay-agent/current"
if [ -f "$LOGFILE" ]; then
  say "Log Agent terbaru:"
  tail -n 25 "$LOGFILE" | tee -a "$REPORT"
fi

check_url() {
  local label="$1" url="$2" result code body
  result="$(curl -sS --connect-timeout 10 --max-time 20 -w $'\n__HTTP__%{http_code}' "$url" 2>&1 || true)"
  code="${result##*$'\n__HTTP__'}"
  body="${result%$'\n__HTTP__'*}"
  [ "$code" != "$result" ] || code="000"
  say "$label HTTP: $code"
  if command -v python >/dev/null 2>&1; then
    printf '%s' "$body" | python -c 'import json,sys; d=json.load(sys.stdin); keys=("gateway","relay","agent_connected","api","database","upstream_active","reason","app","apiVersion","remote_access_enabled"); print(" ".join(f"{k}={d[k]}" for k in keys if k in d))' 2>/dev/null | tee -a "$REPORT" || say "Body bukan JSON yang dikenali."
  fi
}

say "Tes Gateway Relay health..."
check_url "Gateway Relay health" "$BASE_URL/_ani_gateway/health"
say "Tes API Gateway health..."
check_url "API Gateway health" "$BASE_URL/health"

say "STATUS: PEMERIKSAAN SELESAI"
say "Laporan tersimpan: Internal Storage/Download/ANI-Relay-Agent-Setup-Report.txt"
say "PostgreSQL, API lama, DB, dan Worker secrets tidak diubah."
