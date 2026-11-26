#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077
# Inspect both databases; lifecycle controls are StarDesk-only.
readonly PG_PORT="5432" OLD_DB="ani_games_ready_stage" STAR_DB="stardesk_custom_v0"
readonly OLD_API_PORT="8788" STAR_API_PORT="8789"
readonly OLD_API_SERVICE="ani-games-ready-api" OLD_RELAY_SERVICE="ani-games-relay-agent"
readonly STAR_API_SERVICE="stardesk-custom-v0-api"
readonly STAR_RELAY_SERVICE="ani-games-stardesk-relay-agent"
readonly GATEWAY_HEALTH="https://ani-games-db-android-stage-gateway.anigamesready.workers.dev/stardesk/_ani_gateway/health"
PG_ADMIN_USER=""
say(){ printf '[STAR-DESK DB CONTROL] %s\n' "$*"; }
pause(){ printf '\nTekan Enter untuk kembali ke menu…'; read -r _ || true; }
need_termux(){ [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || { say "Menu ini hanya untuk Termux Android."; return 1; }; }
find_pg_admin(){
  [ -n "$PG_ADMIN_USER" ] && return 0
  local candidate
  for candidate in "$(id -un)" postgres; do
    if psql -X -h "$PREFIX/tmp" -p "$PG_PORT" -U "$candidate" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then PG_ADMIN_USER="$candidate"; return 0; fi
  done
  return 1
}
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$PG_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }
db_exists(){ local db="$1"; psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null | grep -qx '1'; }
service_status(){
  local name="$1"
  case "$name" in "$OLD_API_SERVICE"|"$OLD_RELAY_SERVICE"|"$STAR_API_SERVICE"|"$STAR_RELAY_SERVICE"|postgres) ;; *) say "Nama service tidak diizinkan."; return 1 ;; esac
  if command -v sv >/dev/null 2>&1; then sv status "$name" 2>&1 || true; else say "Perintah sv tidak ditemukan."; fi
}
api_status(){
  local name="$1" port="$2"
  say "$name — http://127.0.0.1:$port/health"
  if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/health"; then printf '\n'; else say "API tidak merespons pada port $port."; fi
}
show_status(){
  say "STATUS DUA SISTEM — tidak ada data atau konfigurasi yang diubah."
  if command -v pg_isready >/dev/null 2>&1 && pg_isready -h "$PREFIX/tmp" -p "$PG_PORT" >/dev/null 2>&1; then say "PostgreSQL: SIAP pada socket Termux / port $PG_PORT."; else say "PostgreSQL: TIDAK SIAP. Menu tidak akan menyalakan atau me-restart PostgreSQL."; fi
  service_status postgres
  if find_pg_admin; then
    say "Database terpisah:"
    psql_admin -d postgres -P pager=off -c "SELECT d.datname AS database, pg_get_userbyid(d.datdba) AS owner, CASE WHEN d.datallowconn THEN 'CONNECTABLE' ELSE 'DISABLED' END AS status FROM pg_database d WHERE d.datname IN ('$OLD_DB','$STAR_DB') ORDER BY d.datname;"
  else say "Tidak dapat membaca katalog PostgreSQL lokal dengan akun Termux yang tersedia."; fi
  printf '\n'; say "Ani Games Ready lama (status saja):"
  service_status "$OLD_API_SERVICE"; service_status "$OLD_RELAY_SERVICE"; api_status "Ani Games Ready API lama" "$OLD_API_PORT"
  printf '\n'; say "StarDesk Custom terpisah:"
  service_status "$STAR_API_SERVICE"; service_status "$STAR_RELAY_SERVICE"; api_status "StarDesk API" "$STAR_API_PORT"
}
check_gateway(){
  say "Probe read-only Gateway → Relay → Agent → API → DB StarDesk:"
  curl -sS --connect-timeout 5 --max-time 18 "$GATEWAY_HEALTH" || { say "Probe Gateway gagal/timeout. Periksa status Agent dan log melalui menu."; return 1; }
  printf '\n'
}
open_database_readonly(){
  local db="$1"
  if ! find_pg_admin; then say "Akun PostgreSQL lokal tidak tersedia."; return 1; fi
  if ! db_exists "$db"; then say "Database $db belum ditemukan."; return 1; fi
  say "Membuka $db dengan default_transaction_read_only=on. Jangan ubah mode read-only atau jalankan perintah tulis."
  PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c default_transaction_read_only=on" psql -X -h "$PREFIX/tmp" -p "$PG_PORT" -U "$PG_ADMIN_USER" -d "$db"
}
restart_stardesk_service(){
  local service="$1" service_dir="$PREFIX/var/service/$1"
  case "$service" in "$STAR_API_SERVICE"|"$STAR_RELAY_SERVICE") ;; *) say "DITOLAK: hanya service StarDesk yang boleh dikelola."; return 1 ;; esac
  [ -x "$service_dir/run" ] || { say "Service StarDesk belum terpasang: $service"; return 1; }
  if sv status "$service" 2>&1 | grep -q '^run:'; then say "Restart hanya $service…"; sv restart "$service"; else say "Menyalakan hanya $service…"; sv up "$service"; fi
  sleep 2; sv status "$service" || true
}
tail_stardesk_log(){
  local service="$1" log="$PREFIX/var/log/sv/$1/current"
  case "$service" in "$STAR_API_SERVICE"|"$STAR_RELAY_SERVICE") ;; *) say "DITOLAK: log hanya untuk service StarDesk."; return 1 ;; esac
  [ -f "$log" ] || { say "Log belum tersedia: $log"; return 1; }
  say "Log $service. Keluar dari tail dengan Ctrl+C."; tail -n 40 -f "$log"
}
main(){
  need_termux || exit 1
  for bin in psql curl; do command -v "$bin" >/dev/null 2>&1 || { say "$bin belum tersedia."; exit 1; }; done
  while true; do
    printf '\n=========================================\n       STAR DESK • QUICK DB CONTROL\n=========================================\n'
    printf 'Ani Games lama : %s  | API : %s\nStarDesk baru : %s | API : %s\n' "$OLD_DB" "$OLD_API_PORT" "$STAR_DB" "$STAR_API_PORT"
    printf '%s\n' '-----------------------------------------' '1. Cek status kedua DB, API, dan service' '2. Tes Gateway / Relay StarDesk' '3. Buka database StarDesk (read-only default)' '4. Buka database Ani Games lama (read-only default)' '5. Restart / start API StarDesk saja' '6. Restart / start Relay Agent StarDesk saja' '7. Lihat log API StarDesk' '8. Lihat log Relay StarDesk' '0. Keluar' '-----------------------------------------'
    printf 'Pilih menu: '; local choice; read -r choice || exit 0
    case "$choice" in
      1) show_status; pause ;;
      2) check_gateway || true; pause ;;
      3) open_database_readonly "$STAR_DB" || true; pause ;;
      4) open_database_readonly "$OLD_DB" || true; pause ;;
      5) restart_stardesk_service "$STAR_API_SERVICE" || true; pause ;;
      6) restart_stardesk_service "$STAR_RELAY_SERVICE" || true; pause ;;
      7) tail_stardesk_log "$STAR_API_SERVICE" || true ;;
      8) tail_stardesk_log "$STAR_RELAY_SERVICE" || true ;;
      0) say "Selesai."; break ;;
      *) say "Pilihan tidak dikenal."; pause ;;
    esac
  done
}
main "$@"
