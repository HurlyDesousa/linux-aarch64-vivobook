# Camera Phase C — OV02C10 raw preview (pkgrel 15)

Probe success (`ov02c10 8-0036`, chip-id `0x5602`, entity on `msm_csiphy4`) is
**not** frame capture. A bare `v4l2-ctl --stream-mmap` on an arbitrary
`/dev/videoN` returns **0 bytes** until the media controller pipeline is
linked and formatted end-to-end.

This recipe is **userspace only** — no DTS / pkgrel bump unless a DT bug is
proven. Speakers stay parked.

Prerequisites: `7.2.2-15-aarch64-vivobook` (or newer on the same branch),
`v4l-utils` (`media-ctl`, `v4l2-ctl`), optional `yavta` from
[`v4l-utils`](https://git.linuxtv.org/v4l-utils.git) examples.

Parent doc: [camera-phase-c.md](camera-phase-c.md) (probe / rails / install).

---

## 1) Confirm probe (skip if already green)

```bash
uname -r
# expect 7.2.0-15-aarch64-vivobook

dmesg | rg 'ov02c10|chip id|vreg_l7b|vreg_l3m|csiphy4'
# success: "chip id 0x5602", no "failed to find sensor"

i2cdetect -y 8
# expect UU @ 0x36
```

---

## 2) Find the media device that owns OV02C10

On S5507QA with embedded CAMSS there is usually one graph (`/dev/media0`), but
always discover — do not hard-code:

```bash
for m in /dev/media*; do
  echo "=== $m ==="
  media-ctl -d "$m" -p 2>/dev/null | rg 'ov02c10|csiphy|csid|vfe|video' && echo "^^ use this device"
done
```

Pick the `/dev/mediaN` whose topology lists `ov02c10 8-0036` (CCI1 / i2c-8).

Shortcut (same scan):

```bash
MEDIA=$(for m in /dev/media*; do
  media-ctl -d "$m" -p 2>/dev/null | rg -q 'ov02c10' && echo "$m" && break
done)
echo "MEDIA=$MEDIA"
```

Or run the repo helper:

```bash
./scripts/camera-ov02c10-raw.sh --dry-run
```

---

## 3) Read `media-ctl -p` (x1e80100 / embedded CSIPHY)

Save the full topology before changing anything:

```bash
media-ctl -d "$MEDIA" -p | tee /tmp/camss-topology.txt
```

Typical entity names on **qcom,x1e80100-camss** (legacy embedded CSIPHY, v7.2):

| Role | Entity name (usual) | Notes |
|------|---------------------|-------|
| Sensor | `ov02c10 8-0036` | I2C addr 0x36 on adapter 8 |
| CSIPHY | `msm_csiphy4` | DT `&camss` `port@3` → csiphy4 |
| CSID | `msm_csid0` | First full CSID block |
| VFE RDI | `msm_vfe0_rdi0` | Raw dump port for VC0 |
| Capture node | `/dev/video*` | `media-ctl -e "msm_vfe0_rdi0"` |

Expected **DT-fixed** link (may show `[ENABLED]` before `--reset`):

```
"ov02c10 8-0036":0 -> "msm_csiphy4":0
```

Links you must **enable in software** after `--reset`:

```
"msm_csiphy4":1 -> "msm_csid0":0
"msm_csid0":1 -> "msm_vfe0_rdi0":0
```

**Pad indices are not guaranteed.** If `media-ctl -l` fails with `-EINVAL` /
`-EBUSY`, re-read `-p` and adjust pad numbers on the failing entity only.
Upstream Yoga / Romulus bring-up uses the pads above for CSIPHY4 → CSID0 →
VFE0 RDI0 on VC0.

Other entities (`msm_csitpg*`, `msm_vfe0_pix`, lite CSIDs) are unrelated to
this sensor path — ignore them unless you deliberately route TPG.

---

## 4) OV02C10 mode and bus format

The upstream `ov02c10` driver exposes **one** mode:

| Width | Height | Media bus code | MIPI |
|-------|--------|----------------|------|
| 1928 | 1092 | `SGRBG10_1X10` (`SGRBG10` in media-ctl shorthand) | 2 lanes @ 400 MHz link freq (DT) |

Use **1928×1092** on every pad in the chain. Do not ask for 1920×1080 on the
sensor subdev — the driver snaps to 1928×1092.

---

## 5) Configure pipeline (manual)

Set shell vars from §2–§3:

```bash
MEDIA=/dev/media0          # from discovery
SENSOR='ov02c10 8-0036'
CSIPHY='msm_csiphy4'
CSID='msm_csid0'
VFE='msm_vfe0_rdi0'
FMT='SGRBG10/1928x1092'
# Pad numbers — override if live -p differs:
SENSOR_PAD=0
CSIPHY_SINK_PAD=0
CSIPHY_SRC_PAD=1
CSID_SINK_PAD=0
CSID_SRC_PAD=1
VFE_SINK_PAD=0
```

Reset inactive links, set formats, enable the chain:

```bash
media-ctl -d "$MEDIA" --reset

media-ctl -d "$MEDIA" -V "\"$SENSOR\":$SENSOR_PAD[fmt:$FMT field:none]"
media-ctl -d "$MEDIA" -V "\"$CSIPHY\":$CSIPHY_SINK_PAD[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSIPHY\":$CSIPHY_SRC_PAD[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSID\":$CSID_SINK_PAD[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSID\":$CSID_SRC_PAD[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$VFE\":$VFE_SINK_PAD[fmt:$FMT]"

media-ctl -d "$MEDIA" -l "\"$SENSOR\":$SENSOR_PAD->\"$CSIPHY\":$CSIPHY_SINK_PAD[1]"
media-ctl -d "$MEDIA" -l "\"$CSIPHY\":$CSIPHY_SRC_PAD->\"$CSID\":$CSID_SINK_PAD[1]"
media-ctl -d "$MEDIA" -l "\"$CSID\":$CSID_SRC_PAD->\"$VFE\":$VFE_SINK_PAD[1]"

media-ctl -d "$MEDIA" -p | rg 'ov02c10|csiphy4|csid0|vfe0_rdi0|\[ENABLED\]'
```

Resolve the capture device:

```bash
VIDEO=$(media-ctl -d "$MEDIA" -e "$VFE")
echo "VIDEO=$VIDEO"
v4l2-ctl -d "$VIDEO" --all
v4l2-ctl -d "$VIDEO" --list-formats-ext
```

Pick a **10-bit Bayer** pixel format the node advertises (often `RG10` or
`SGRBG10` / `SGRBG10P`). Match width/height to the pipeline:

```bash
v4l2-ctl -d "$VIDEO" --set-fmt-video=width=1928,height=1092,pixelformat=RG10
# if RG10 missing, retry pixelformat from --list-formats-ext
```

---

## 6) Stream raw frames

```bash
OUT=/tmp/ov02c10.raw
rm -f "$OUT"

v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count=10 --stream-to="$OUT"

ls -l "$OUT"
# success: size > 0 (roughly 2.5 MiB × frame count for 10-bit 1928×1092)
wc -c "$OUT"
```

One-liner success check:

```bash
test -s "$OUT" && echo "OK: $(wc -c < "$OUT") bytes" || echo "FAIL: 0 bytes"
```

Optional **`yavta`** (same topology as upstream CAMSS RDI examples):

```bash
yavta -B capture-mplane -c -I -n 10 -f SGRBG10P -s 1928x1092 -F "$VIDEO" -o /tmp/yavta-%03d.raw
```

Quick sanity on Bayer data (non-zero entropy):

```bash
hexdump -C "$OUT" | head
# not all 0x00 / 0xff
```

---

## 7) Automated helper

From a clone of this repo (or after copying the script):

```bash
./scripts/camera-ov02c10-raw.sh
# env overrides: MEDIA=, FRAMES=, OUT=, PIXFMT=RG10
echo $?   # 0 = non-zero capture file
```

`--dry-run` prints discovered entities and the `media-ctl` / `v4l2-ctl`
commands without executing capture.

---

## 8) Failure triage (still 0 bytes)

Collect **before** opening a DTS / pkgrel ticket:

```bash
{
  echo "=== uname ==="; uname -a
  echo "=== dmesg ov02c10 ==="; dmesg | rg 'ov02c10|camss|csiphy|csid|vfe'
  echo "=== media-ctl -p ==="; media-ctl -d "$MEDIA" -p
  echo "=== v4l2-ctl --all ($VIDEO) ==="; v4l2-ctl -d "$VIDEO" --all
  echo "=== capture file ==="; ls -l "$OUT" 2>/dev/null || true
} | tee /tmp/cam-capture-fail.txt
```

| Symptom | Likely cause | Next step |
|---------|--------------|-----------|
| No `ov02c10` in `-p` | Probe failed / wrong kernel | Back to [camera-phase-c.md §1](camera-phase-c.md#1-dmesg--sensor-probe) |
| Sensor present, all links `[DISABLED]` after setup | Pad index mismatch or `--reset` without re-link | Fix pads from `-p`; ensure 3 links `[ENABLED]` |
| Links enabled, `--list-formats-ext` empty | Wrong `/dev/videoN` | Re-run `media-ctl -e "msm_vfe0_rdi0"` |
| Formats OK, stream 0 B, dmesg DMA / CSID errors | CSIPHY rail / clock / lane mismatch | Paste triage bundle; **do not** guess new LDOs |
| `Failed to start media pipeline: -32` | Bus code mismatch (e.g. SRGGB vs SGRBG) | Use `SGRBG10` on **all** pads |

---

## Omarchy VERIFY block (copy/paste)

Run on hardware after pkgrel **15** is installed and probe is green:

```bash
# --- probe ---
uname -r
dmesg | rg 'ov02c10|chip id 0x5602|vreg_l7b|vreg_l3m'
i2cdetect -y 8

# --- discover + topology ---
MEDIA=$(for m in /dev/media*; do media-ctl -d "$m" -p 2>/dev/null | rg -q ov02c10 && echo "$m" && break; done)
media-ctl -d "$MEDIA" -p | rg 'ov02c10|csiphy4|csid0|vfe0_rdi0'

# --- pipeline + capture (manual) ---
SENSOR='ov02c10 8-0036'; CSIPHY='msm_csiphy4'; CSID='msm_csid0'; VFE='msm_vfe0_rdi0'
FMT='SGRBG10/1928x1092'
media-ctl -d "$MEDIA" --reset
media-ctl -d "$MEDIA" -V "\"$SENSOR\":0[fmt:$FMT field:none]"
media-ctl -d "$MEDIA" -V "\"$CSIPHY\":0[fmt:$FMT]" -V "\"$CSIPHY\":1[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSID\":0[fmt:$FMT]" -V "\"$CSID\":1[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$VFE\":0[fmt:$FMT]"
media-ctl -d "$MEDIA" -l "\"$SENSOR\":0->\"$CSIPHY\":0[1]"
media-ctl -d "$MEDIA" -l "\"$CSIPHY\":1->\"$CSID\":0[1]"
media-ctl -d "$MEDIA" -l "\"$CSID\":1->\"$VFE\":0[1]"
VIDEO=$(media-ctl -d "$MEDIA" -e "$VFE")
v4l2-ctl -d "$VIDEO" --list-formats-ext
v4l2-ctl -d "$VIDEO" --set-fmt-video=width=1928,height=1092,pixelformat=RG10
v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count=10 --stream-to=/tmp/ov02c10.raw
ls -l /tmp/ov02c10.raw; wc -c /tmp/ov02c10.raw

# --- or scripted ---
git clone -b cursor/vivobook-camera-phase-c-977f \
  https://github.com/HurlyDesousa/linux-aarch64-vivobook.git /tmp/vivobook-cam
/tmp/vivobook-cam/scripts/camera-ov02c10-raw.sh
```

Success criterion: `/tmp/ov02c10.raw` (or script `$OUT`) **non-zero** size,
typically ≥ ~2.5 MiB for a single 10-bit frame × frame count.
