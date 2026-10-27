#!/usr/bin/env bash
# pearl-entrypoint: kjører en Pearl-miner som vast «default job» på én GPU.
#
# Vast starter samme bilde på hver GPU på maskinen (en enkelt-GPU-instans per kort) og setter jobben på pause når en
# kunde leier. Bildet inneholder bare dette skriptet. Mineren hentes ved oppstart fra en URL du har valgt og kjøres BARE
# hvis SHA-256 stemmer med det du har festet, så en endret fil hos leverandøren stoppes. Lommebok og pool ligger i
# argumentene (offentlig adresse, ingen nøkler).
#
#   pearl-entrypoint --miner-url URL --miner-sha256 HEX --miner-bin NAVN [--worker-prefix gpu] \
#       --miner-args <argumenter til mineren, {WORKER} byttes ut med f.eks. gpu-3fa9c1d2>
#
# --miner-args må stå sist (vast sender alt etter --args uendret). --selftest laster ned og kontrollerer, men starter ikke.
set -u

log() { printf '%s pearl: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FEIL: $1"; exit "${2:-1}"; }

MINER_URL=""; MINER_SHA256=""; MINER_BIN=""; WORKER_PREFIX="gpu"; SELFTEST=0
MINER_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --miner-url)     MINER_URL="${2:-}"; shift 2 ;;
    --miner-sha256)  MINER_SHA256="${2:-}"; shift 2 ;;
    --miner-bin)     MINER_BIN="${2:-}"; shift 2 ;;
    --worker-prefix) WORKER_PREFIX="${2:-}"; shift 2 ;;
    --selftest)      SELFTEST=1; shift ;;
    --miner-args)    shift; MINER_ARGS=("$@"); break ;;
    *) die "ukjent argument: $1" 64 ;;
  esac
done

case "$MINER_URL" in
  https://*) ;;
  file://*) [ "${PEARL_ALLOW_FILE:-0}" = 1 ] || die "file:// er bare tillatt i test" 64 ;;
  *) die "--miner-url må være https://" 64 ;;
esac
printf '%s' "$MINER_SHA256" | grep -Eq '^[0-9a-fA-F]{64}$' || die "--miner-sha256 må være 64 heksadesimale tegn" 64
printf '%s' "$MINER_BIN" | grep -Eq '^[A-Za-z0-9._-]+$' || die "--miner-bin må være et filnavn uten sti" 64
printf '%s' "$WORKER_PREFIX" | grep -Eq '^[A-Za-z0-9_-]{1,24}$' || die "--worker-prefix må være bokstaver/tall, maks 24" 64
[ "${#MINER_ARGS[@]}" -gt 0 ] || die "--miner-args mangler" 64

# Worker-navnet følger kortet, ikke maskinen eller instansen: GPU-UUID (stabil mellom pauser og unik på tvers av
# maskiner, så samme mal kan brukes på hele flåten): GPU-3fa9c1d2-... -> gpu-3fa9c1d2. PCIe-bussen logges ved siden av
# for å koble navnet til et fysisk kort (nvidia-smi -L på verten viser UUID-en).
ID=""; BUS=""
if command -v nvidia-smi >/dev/null 2>&1; then
  GPUS=()
  while IFS= read -r line; do [ -n "$line" ] && GPUS+=("$line"); done \
    < <(nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader 2>/dev/null | tr -d ' ')
  [ "${#GPUS[@]}" -eq 1 ] || log "ADVARSEL: ser ${#GPUS[@]} GPU-er, forventet 1 (enkelt-GPU-instans)"
  ID="$(printf '%s' "${GPUS[0]:-}" | awk -F, '{u=tolower($1); sub(/^gpu-/, "", u); print substr(u, 1, 8)}')"
  BUS="$(printf '%s' "${GPUS[0]:-}" | awk -F, '{print $2}')"
  printf '%s' "$ID" | grep -Eq '^[0-9a-f]{8}$' || ID=""
else
  log "ADVARSEL: nvidia-smi finnes ikke"
fi
WORKER="${WORKER_PREFIX}-${ID:-x}"
log "worker=${WORKER} (buss ${BUS:-ukjent})"

WORK="${PEARL_WORKDIR:-$HOME/pearl}"
mkdir -p "$WORK/x" || die "får ikke lage $WORK"
PKG="$WORK/miner.pkg"

fetch_and_verify() {
  rm -rf "$WORK/x" "$PKG"; mkdir -p "$WORK/x"
  log "henter mineren"
  curl -fsSL --retry 5 --retry-delay 5 --connect-timeout 20 --max-time 300 -o "$PKG" "$MINER_URL" || return 1
  if ! printf '%s  %s\n' "$MINER_SHA256" "$PKG" | sha256sum -c - >/dev/null 2>&1; then
    log "SHA-256 stemmer IKKE (fikk $(sha256sum "$PKG" | cut -d' ' -f1)) – kjører ikke filen"
    rm -f "$PKG"; return 2
  fi
  case "${MINER_URL%%\?*}" in
    *.tar.gz|*.tgz) tar -xzf "$PKG" -C "$WORK/x" ;;
    *.tar.xz)       tar -xJf "$PKG" -C "$WORK/x" ;;
    *.zip)          unzip -q "$PKG" -d "$WORK/x" ;;
    *)              cp "$PKG" "$WORK/x/$MINER_BIN" ;;
  esac || return 3
  BIN="$(find "$WORK/x" -type f -name "$MINER_BIN" | head -n 1)"
  [ -n "$BIN" ] || { log "fant ikke $MINER_BIN i pakken"; return 4; }
  chmod +x "$BIN"
}

# Feil hash er en varig feil (vi prøver ikke i en løkke mot en fil som ikke stemmer); nettfeil prøves på nytt.
BIN=""
tries=0
until fetch_and_verify; do
  rc=$?
  [ "$rc" -eq 1 ] || die "mineren avvist (kode $rc)" 65
  tries=$((tries + 1)); [ "$tries" -lt 6 ] || die "klarte ikke å hente mineren" 66
  sleep $((tries * 15))
done
log "mineren verifisert: $(basename "$BIN")"
[ "$SELFTEST" -eq 0 ] || { log "selvtest OK"; exit 0; }

ARGS=()
for a in "${MINER_ARGS[@]}"; do ARGS+=("${a//\{WORKER\}/$WORKER}"); done

child=0
stop() {
  trap - TERM INT
  if [ "$child" -gt 0 ]; then
    kill -TERM "$child" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
    kill -KILL "$child" 2>/dev/null
  fi
  log "stoppet"
  exit 0
}
trap stop TERM INT

# Ingen klokke-/effektinnstillinger her: containeren er uten rettigheter, effektgrensen (550 W) settes av verten.
backoff=10
while true; do
  started=$(date +%s)
  "$BIN" "${ARGS[@]}" &
  child=$!
  wait "$child"; rc=$?
  child=0
  ran=$(( $(date +%s) - started ))
  if [ "$ran" -ge 300 ]; then backoff=10; else backoff=$(( backoff * 2 > 300 ? 300 : backoff * 2 )); fi
  log "mineren avsluttet (kode $rc etter ${ran}s), starter om ${backoff}s"
  sleep "$backoff" &
  wait $!
done
