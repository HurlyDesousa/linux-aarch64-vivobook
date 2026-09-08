#!/usr/bin/env bash
# OV02C10 raw capture — Vivobook S5507QA pkgrel 15 live topology.
# /dev/media0 only; capture on /dev/video0 (msm_vfe0_rdi0).
# Sensor→msm_csiphy4:0 is DT [ENABLED,IMMUTABLE] — do not -l it.
set -euo pipefail

FRAMES="${FRAMES:-10}"
OUT="${OUT:-/tmp/ov02c10.raw}"
PIXFMT="${PIXFMT:-RG10}"
MEDIA="${MEDIA:-/dev/media0}"
VIDEO="${VIDEO:-/dev/video0}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: camera-ov02c10-raw.sh [--dry-run]

Pkgrel 15 Omarchy: /dev/media0, stream /dev/video0 after enabling
  msm_csiphy4:1 -> msm_csidN:0 -> msm_vfe0_rdi0:0
and setting SGRBG10_1X10/1928x1092 on csiphy/csid/rdi (fixes UYVY default).

Tries CSID candidates in order: msm_csid0 .. msm_csid4 (override with CSID=).

Environment:
  MEDIA=/dev/media0   VIDEO=/dev/video0
  FRAMES=10  OUT=/tmp/ov02c10.raw  PIXFMT=RG10
  CSID=        force one CSID (skip auto-try)
  CSIPHY=msm_csiphy4  VFE=msm_vfe0_rdi0
  CSIPHY_SRC_PAD=1 CSIPHY_SINK_PAD=0
  CSID_SINK_PAD=0 CSID_SRC_PAD=1 VFE_SINK_PAD=0
  RESET=1      run media-ctl --reset first (default: skip)

Uses quoted entity names in media-ctl, not entity numbers.
Exit 0 when OUT is non-empty.
EOF
}

log() { printf 'camera-ov02c10-raw: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' (install v4l-utils)"
}

run() {
  if (( DRY_RUN )); then
    printf '+ %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

entity_exists() {
  local media="$1" ent="$2"
  media-ctl -d "$media" -p 2>/dev/null | rg -Fq "$ent"
}

find_sensor_entity() {
  local media="$1" name
  name=$(media-ctl -d "$media" -p 2>/dev/null \
    | rg -o 'entity [0-9]+: ov02c10 [^ ]+' \
    | head -1 \
    | sed 's/^entity [0-9]*: //')
  [[ -n "$name" ]] || die "no ov02c10 entity on $media (probe bound?)"
  echo "$name"
}

pick_pixfmt() {
  local video="$1" want="$2" fmt
  if v4l2-ctl -d "$video" --list-formats-ext 2>/dev/null | rg -q "^\s*${want}\s"; then
    echo "$want"
    return
  fi
  for fmt in RG10 SGRBG10 SGRBG10P BA10 SGRBG8; do
    if v4l2-ctl -d "$video" --list-formats-ext 2>/dev/null | rg -q "^\s*${fmt}\s"; then
      log "PIXFMT=$want unavailable on $video; using $fmt"
      echo "$fmt"
      return
    fi
  done
  die "no Bayer pixelformat on $video"
}

setup_formats() {
  local media="$1" sensor="$2" csiphy="$3" csid="$4" vfe="$5" fmt="$6"
  run media-ctl -d "$media" -V "\"$sensor\":0[fmt:${fmt} field:none]"
  run media-ctl -d "$media" -V "\"$csiphy\":${CSIPHY_SINK_PAD}[fmt:${fmt}]"
  run media-ctl -d "$media" -V "\"$csiphy\":${CSIPHY_SRC_PAD}[fmt:${fmt}]"
  run media-ctl -d "$media" -V "\"$csid\":${CSID_SINK_PAD}[fmt:${fmt}]"
  run media-ctl -d "$media" -V "\"$csid\":${CSID_SRC_PAD}[fmt:${fmt}]"
  run media-ctl -d "$media" -V "\"$vfe\":${VFE_SINK_PAD}[fmt:${fmt}]"
}

enable_links() {
  local media="$1" csiphy="$2" csid="$3" vfe="$4"
  # Sensor→csiphy4:0 is [ENABLED,IMMUTABLE] — only enable downstream.
  run media-ctl -d "$media" -l \
    "\"$csiphy\":${CSIPHY_SRC_PAD}->\"$csid\":${CSID_SINK_PAD}[1]"
  run media-ctl -d "$media" -l \
    "\"$csid\":${CSID_SRC_PAD}->\"$vfe\":${VFE_SINK_PAD}[1]"
}

try_capture() {
  local media="$1" csid="$2" pixfmt="$3"
  local tmp="${OUT}.try.$$"
  rm -f "$tmp"
  run v4l2-ctl -d "$VIDEO" --set-fmt-video="width=1928,height=1092,pixelformat=${pixfmt}"
  run v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count="$FRAMES" --stream-to="$tmp"
  if [[ -s "$tmp" ]]; then
    mv -f "$tmp" "$OUT"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

need_cmd media-ctl
need_cmd v4l2-ctl
need_cmd rg

[[ -e "$MEDIA" ]] || die "MEDIA=$MEDIA missing"
[[ -e "$VIDEO" ]] || die "VIDEO=$VIDEO missing"

CSIPHY="${CSIPHY:-msm_csiphy4}"
VFE="${VFE:-msm_vfe0_rdi0}"
FMT='SGRBG10_1X10/1928x1092'

CSIPHY_SINK_PAD="${CSIPHY_SINK_PAD:-0}"
CSIPHY_SRC_PAD="${CSIPHY_SRC_PAD:-1}"
CSID_SINK_PAD="${CSID_SINK_PAD:-0}"
CSID_SRC_PAD="${CSID_SRC_PAD:-1}"
VFE_SINK_PAD="${VFE_SINK_PAD:-0}"

entity_exists "$MEDIA" "$CSIPHY" || die "'$CSIPHY' not in $MEDIA"
entity_exists "$MEDIA" "$VFE" || die "'$VFE' not in $MEDIA"

SENSOR=$(find_sensor_entity "$MEDIA")

if [[ -n "${CSID:-}" ]]; then
  CSID_CANDIDATES=("$CSID")
else
  CSID_CANDIDATES=(msm_csid0 msm_csid1 msm_csid2 msm_csid3 msm_csid4)
fi

log "MEDIA=$MEDIA VIDEO=$VIDEO SENSOR='$SENSOR' CSIPHY=$CSIPHY VFE=$VFE"
log "sensor→${CSIPHY}:${CSIPHY_SINK_PAD} is DT immutable; enabling ${CSIPHY}:${CSIPHY_SRC_PAD}→CSID→${VFE}"

if [[ "${RESET:-0}" == 1 ]]; then
  run media-ctl -d "$MEDIA" --reset
fi

if (( DRY_RUN )); then
  setup_formats "$MEDIA" "$SENSOR" "$CSIPHY" "${CSID_CANDIDATES[0]}" "$VFE" "$FMT"
  enable_links "$MEDIA" "$CSIPHY" "${CSID_CANDIDATES[0]}" "$VFE"
  run media-ctl -d "$MEDIA" -p
  run v4l2-ctl -d "$VIDEO" --set-fmt-video="width=1928,height=1092,pixelformat=${PIXFMT}"
  run v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT"
  log "dry-run complete (tried CSID=${CSID_CANDIDATES[0]} only)"
  exit 0
fi

PIXFMT=$(pick_pixfmt "$VIDEO" "$PIXFMT")
rm -f "$OUT"

for csid in "${CSID_CANDIDATES[@]}"; do
  entity_exists "$MEDIA" "$csid" || continue
  log "try CSID=$csid"
  setup_formats "$MEDIA" "$SENSOR" "$CSIPHY" "$csid" "$VFE" "$FMT"
  enable_links "$MEDIA" "$CSIPHY" "$csid" "$VFE"
  if try_capture "$MEDIA" "$csid" "$PIXFMT"; then
    bytes=$(wc -c < "$OUT")
    log "OK: CSID=$csid ${bytes} bytes -> $OUT"
    exit 0
  fi
  log "CSID=$csid: 0-byte capture, trying next"
done

log "all CSIDs failed — paste triage from docs/camera-phase-c-preview.md §7"
media-ctl -d "$MEDIA" -p >&2 || true
v4l2-ctl -d "$VIDEO" --all >&2 || true
exit 1
