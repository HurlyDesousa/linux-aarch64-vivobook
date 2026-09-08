#!/usr/bin/env bash
# OV02C10 raw capture on Vivobook S5507QA (x1e80100 embedded CAMSS).
# Userspace pipeline setup only — no kernel/DTS changes.
set -euo pipefail

FRAMES="${FRAMES:-10}"
OUT="${OUT:-/tmp/ov02c10.raw}"
PIXFMT="${PIXFMT:-RG10}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: camera-ov02c10-raw.sh [--dry-run]

Discover /dev/media* containing ov02c10, configure CSIPHY4→CSID0→VFE0 RDI0
for 1928x1092 SGRBG10, stream FRAMES to OUT.

Environment:
  MEDIA=     override media device (default: auto)
  FRAMES=    frame count (default: 10)
  OUT=       output file (default: /tmp/ov02c10.raw)
  PIXFMT=    v4l2 pixel format (default: RG10)
  CSIPHY= CSID= VFE=  entity names (default: msm_csiphy4, msm_csid0, msm_vfe0_rdi0)
  *_PAD=     pad indices (defaults match typical x1e80100 topology)

Exit 0 when OUT is non-empty; non-zero on discovery/setup/capture failure.
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

find_media_dev() {
  local m
  if [[ -n "${MEDIA:-}" ]]; then
    [[ -e "$MEDIA" ]] || die "MEDIA=$MEDIA does not exist"
    media-ctl -d "$MEDIA" -p 2>/dev/null | rg -q 'ov02c10' \
      || die "MEDIA=$MEDIA has no ov02c10 entity"
    echo "$MEDIA"
    return
  fi
  for m in /dev/media*; do
    [[ -e "$m" ]] || continue
    if media-ctl -d "$m" -p 2>/dev/null | rg -q 'ov02c10'; then
      echo "$m"
      return
    fi
  done
  die "no /dev/media* topology contains ov02c10 (probe bound?)"
}

find_sensor_entity() {
  local media="$1" name
  name=$(media-ctl -d "$media" -p 2>/dev/null \
    | rg -o 'entity [0-9]+: ov02c10 [^ ]+' \
    | head -1 \
    | sed 's/^entity [0-9]*: //')
  [[ -n "$name" ]] || die "could not resolve ov02c10 entity name from media-ctl -p"
  echo "$name"
}

entity_exists() {
  local media="$1" ent="$2"
  media-ctl -d "$media" -p 2>/dev/null | rg -Fq "$ent"
}

resolve_video_node() {
  local media="$1" vfe="$2" node
  node=$(media-ctl -d "$media" -e "$vfe" 2>/dev/null || true)
  [[ -n "$node" && -e "$node" ]] || die "media-ctl -e '$vfe' did not yield a video node"
  echo "$node"
}

pick_pixfmt() {
  local video="$1" want="$2" fmt
  if v4l2-ctl -d "$video" --list-formats-ext 2>/dev/null | rg -q "^\s*${want}\s"; then
    echo "$want"
    return
  fi
  for fmt in RG10 SGRBG10 SGRBG10P BA10 SGRBG8; do
    if v4l2-ctl -d "$video" --list-formats-ext 2>/dev/null | rg -q "^\s*${fmt}\s"; then
      log "PIXFMT=$want unavailable; using $fmt"
      echo "$fmt"
      return
    fi
  done
  die "no supported Bayer format on $video (--list-formats-ext empty?)"
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

MEDIA=$(find_media_dev)
SENSOR=$(find_sensor_entity "$MEDIA")
CSIPHY="${CSIPHY:-msm_csiphy4}"
CSID="${CSID:-msm_csid0}"
VFE="${VFE:-msm_vfe0_rdi0}"
FMT='SGRBG10/1928x1092'

SENSOR_PAD="${SENSOR_PAD:-0}"
CSIPHY_SINK_PAD="${CSIPHY_SINK_PAD:-0}"
CSIPHY_SRC_PAD="${CSIPHY_SRC_PAD:-1}"
CSID_SINK_PAD="${CSID_SINK_PAD:-0}"
CSID_SRC_PAD="${CSID_SRC_PAD:-1}"
VFE_SINK_PAD="${VFE_SINK_PAD:-0}"

entity_exists "$MEDIA" "$CSIPHY" || die "entity '$CSIPHY' not in $MEDIA (check CSIPHY=)"
entity_exists "$MEDIA" "$CSID" || die "entity '$CSID' not in $MEDIA (check CSID=)"
entity_exists "$MEDIA" "$VFE" || die "entity '$VFE' not in $MEDIA (check VFE=)"

log "MEDIA=$MEDIA SENSOR='$SENSOR' CSIPHY=$CSIPHY CSID=$CSID VFE=$VFE"

run media-ctl -d "$MEDIA" --reset

run media-ctl -d "$MEDIA" -V "\"$SENSOR\":$SENSOR_PAD[fmt:${FMT} field:none]"
run media-ctl -d "$MEDIA" -V "\"$CSIPHY\":$CSIPHY_SINK_PAD[fmt:${FMT}]"
run media-ctl -d "$MEDIA" -V "\"$CSIPHY\":$CSIPHY_SRC_PAD[fmt:${FMT}]"
run media-ctl -d "$MEDIA" -V "\"$CSID\":$CSID_SINK_PAD[fmt:${FMT}]"
run media-ctl -d "$MEDIA" -V "\"$CSID\":$CSID_SRC_PAD[fmt:${FMT}]"
run media-ctl -d "$MEDIA" -V "\"$VFE\":$VFE_SINK_PAD[fmt:${FMT}]"

run media-ctl -d "$MEDIA" -l "\"$SENSOR\":$SENSOR_PAD->\"$CSIPHY\":$CSIPHY_SINK_PAD[1]"
run media-ctl -d "$MEDIA" -l "\"$CSIPHY\":$CSIPHY_SRC_PAD->\"$CSID\":$CSID_SINK_PAD[1]"
run media-ctl -d "$MEDIA" -l "\"$CSID\":$CSID_SRC_PAD->\"$VFE\":$VFE_SINK_PAD[1]"

if (( DRY_RUN )); then
  run media-ctl -d "$MEDIA" -p
  log "dry-run complete (no capture)"
  exit 0
fi

VIDEO=$(resolve_video_node "$MEDIA" "$VFE")
PIXFMT=$(pick_pixfmt "$VIDEO" "$PIXFMT")
log "VIDEO=$VIDEO PIXFMT=$PIXFMT FRAMES=$FRAMES OUT=$OUT"

rm -f "$OUT"
run v4l2-ctl -d "$VIDEO" --set-fmt-video="width=1928,height=1092,pixelformat=${PIXFMT}"
run v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count="$FRAMES" --stream-to="$OUT"

if [[ ! -s "$OUT" ]]; then
  log "capture wrote 0 bytes — paste triage from docs/camera-phase-c-preview.md §8"
  media-ctl -d "$MEDIA" -p >&2 || true
  v4l2-ctl -d "$VIDEO" --all >&2 || true
  exit 1
fi

bytes=$(wc -c < "$OUT")
log "OK: ${bytes} bytes -> $OUT"
exit 0
