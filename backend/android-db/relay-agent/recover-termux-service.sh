#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"
SVDIR="$PREFIX/var/service"
LOGDIR="$PREFIX/var/log"
export SVDIR LOGDIR
NAME="ani-games-relay-agent"
SERVICE="$SVDIR/$NAME"
REPORT="$HOME/storage/downloads/ANI-Relay-Agent-Recovery-Report.txt"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
fail() { say "STATUS: GAGAL"; say "PENYEBAB: $*"; say "Laporan: $REPORT"; exit 1; }

[ -d "$HOME/storage/downloads" ] && [ -w "$HOME/storage/downloads" ] || { printf 'Internal Storage/Download tidak tersedia. Jalankan termux-setup-storage.\n'; exit 1; }
: > "$REPORT"
say "ANI GAMES READY - RELAY AGENT RECOVERY"
[ -d "$SERVICE" ] || fail "Folder service Agent tidak ditemukan. Installer sebelumnya belum selesai."
[ -x "$SERVICE/run" ] || fail "File run Agent tidak ada atau tidak executable."
[ -x "$PREFIX/bin/service-daemon" ] || fail "termux-services/service-daemon tidak tersedia."
[ -x "$PREFIX/bin/sv" ] || fail "Perintah sv tidak tersedia."

# Reuse a running service-daemon. If its PID file is stale, remove only that
# exact PID file; never stop or restart any existing service.
PIDFILE="$PREFIX/var/run/service-daemon.pid"
DAEMON_RUNNING=0
if [ -s "$PIDFILE" ]; then
  PID="$(tr -cd '0-9' < "$PIDFILE")"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    CMD="$(tr '\000' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
    case "$CMD" in
      *"$PREFIX/bin/runsvdir $SVDIR"*) DAEMON_RUNNING=1 ;;
      *) fail "PID service-daemon terpakai proses lain; tidak disentuh." ;;
    esac
  else
    rm -f "$PIDFILE"
  fi
fi

if [ "$DAEMON_RUNNING" -eq 0 ]; then
  # service-daemon supervises every enabled service in SVDIR. To protect
  # existing services, refuse to bootstrap if any other service is enabled.
  for entry in "$SVDIR"/*; do
    [ -d "$entry" ] || continue
    [ "${entry##*/}" = "$NAME" ] && continue
    [ -e "$entry/down" ] || fail "Service lain (${entry##*/}) tidak memiliki marker down. Demi keamanan, daemon tidak dijalankan agar service lama tidak ikut start."
  done
  say "Service daemon belum aktif. Semua service lain terdeteksi disabled; menyalakan supervisor Termux."
  SVDIR="$SVDIR" LOGDIR="$LOGDIR" "$PREFIX/bin/service-daemon" start >> "$REPORT" 2>&1 || fail "service-daemon gagal dijalankan."
else
  say "Supervisor Termux sudah aktif."
fi

sleep 3
sv status "$NAME" 2>&1 | tee -a "$REPORT" || true
sleep 3
say "Pemeriksaan akhir service:"
if sv status "$NAME" 2>&1 | tee -a "$REPORT" | grep -q '^run:'; then
  say "STATUS SERVICE: RUNNING"
else
  say "STATUS SERVICE: BELUM RUNNING"
  LOGFILE="$LOGDIR/sv/$NAME/current"
  [ ! -f "$LOGFILE" ] || { say "Log Agent:"; tail -n 30 "$LOGFILE" | tee -a "$REPORT"; }
  say "Laporan: $REPORT"
  exit 1
fi

BASE="https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
for path in "/_ani_gateway/health" "/health"; do
  code="$(curl -sS --connect-timeout 10 --max-time 20 -o "$PREFIX/tmp/ani-relay-health.tmp" -w '%{http_code}' "$BASE$path" 2>>"$REPORT" || true)"
  say "Gateway $path HTTP: ${code:-000}"
  if [ -s "$PREFIX/tmp/ani-relay-health.tmp" ] && command -v python >/dev/null 2>&1; then
    python -c 'import json,sys; d=json.load(open(sys.argv[1])); keys=("gateway","relay","agent_connected","api","database","upstream_active","error"); print(" ".join(f"{k}={d[k]}" for k in keys if k in d))' "$PREFIX/tmp/ani-relay-health.tmp" 2>/dev/null | tee -a "$REPORT" || true
  fi
done
rm -f "$PREFIX/tmp/ani-relay-health.tmp"
say "Laporan: Internal Storage/Download/ANI-Relay-Agent-Recovery-Report.txt"
