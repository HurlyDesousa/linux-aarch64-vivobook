# Camera Phase C — OV02C10 raw preview (pkgrel 15)

Probe success (`ov02c10 8-0036`, chip-id `0x5602`) is **not** frame capture.
Naive `v4l2-ctl --stream-mmap` on `/dev/video0` still returns **0 bytes**
until `media-ctl` fixes formats and enables the CSIPHY → CSID → RDI links.

This recipe is **userspace only** — no DTS / pkgrel bump unless a DT bug is
proven.

Prerequisites: `7.2.2-15-aarch64-vivobook`, `v4l-utils` (`media-ctl`,
`v4l2-ctl`).

Parent doc: [camera-phase-c.md](camera-phase-c.md) (probe / rails / install).

---

## Live Omarchy topology (pkgrel 15, verified)

Save your own dump for diffing:

```bash
media-ctl -d /dev/media0 -p | tee /tmp/cam15-media-topology.txt
```

| Item | Live value |
|------|------------|
| Media device | **`/dev/media0` only** (no other `/dev/media*`) |
| Video nodes | **`/dev/video0`–`video15`** |
| Capture node | **`/dev/video0`** (`msm_vfe0_rdi0` → `msm_vfe0_video0`) |

**Sensor → CSIPHY (already wired in DT — do not `-l` this):**

| Entity | # | subdev | Pad | Link / format |
|--------|---|--------|-----|----------------|
| `ov02c10 8-0036` | 423 | `/dev/v4l-subdev28` | 0 SOURCE | `SGRBG10_1X10/1928x1092` → `msm_csiphy4`:0 **`[ENABLED,IMMUTABLE]`** |
| `msm_csiphy4` | 10 | `/dev/v4l-subdev3` | 0 SINK | sensor link above |

**Gap before capture works:**

| Entity | Pad | State | Problem |
|--------|-----|-------|---------|
| `msm_csiphy4` | 1 SOURCE | → `msm_csid0`…`msm_csid4` pads all **`[]` (disabled)** | Must `-l` one CSID |
| `msm_csiphy4` | 0, 1 | fmt **`UYVY8_1X16/1920x1080`** | Mismatch vs sensor — override to **`SGRBG10_1X10/1928x1092`** |
| chosen `msm_csidN` | 0, 1 | default formats wrong / links off | Set SGRBG10 + enable → `msm_vfe0_rdi0` |
| `msm_vfe0_rdi0` | 0 SINK | → **`/dev/video0`** **`[ENABLED,IMMUTABLE]`** | Stream here after upstream links |

Entity **numbers** (423, 10, …) vary by boot — always use **quoted entity
names** in `media-ctl -V` / `-l`, not numeric IDs. Pad indices below match
live pkgrel 15; re-read `-p` if `-l` returns `-EINVAL`.

---

## 1) Confirm probe (skip if already green)

```bash
uname -r
# expect 7.2.0-15-aarch64-vivobook

dmesg | rg 'ov02c10|chip id|vreg_l7b|vreg_l3m|csiphy4'
# success: chip id 0x5602

i2cdetect -y 8
# UU @ 0x36
```

---

## 2) Inspect topology

```bash
MEDIA=/dev/media0
media-ctl -d "$MEDIA" -p | rg 'ov02c10|csiphy4|csid|vfe0_rdi0|video0|ENABLED|IMMUTABLE'
```

Expect sensor→`msm_csiphy4`:0 enabled; `msm_csiphy4`:1→CSID links empty;
`msm_vfe0_rdi0` tied to `/dev/video0`.

---

## 3) OV02C10 format (single mode)

| Width | Height | Media bus (`media-ctl`) | Sensor pad |
|-------|--------|-------------------------|------------|
| 1928 | 1092 | **`SGRBG10_1X10/1928x1092`** | already set on pad 0 |

Apply this on **every** CSIPHY / CSID / RDI pad in the chain. Do not leave
the CSIPHY default `UYVY8_1X16/1920x1080`.

---

## 4) Configure pipeline (manual)

Use entity **names** only. Do **not** `-l` sensor→CSIPHY (immutable DT link).
Do **not** `--reset` unless you know you need it — it clears software links
but leaves immutable sensor→CSIPHY enabled.

```bash
MEDIA=/dev/media0
SENSOR='ov02c10 8-0036'
CSIPHY='msm_csiphy4'
CSID='msm_csid0'          # try csid1..csid4 if capture stays 0 B
VFE='msm_vfe0_rdi0'
VIDEO=/dev/video0
FMT='SGRBG10_1X10/1928x1092'

# Pads (pkgrel 15 live — tweak from -p if -l fails):
#   csiphy4:0 SINK (sensor)  csiphy4:1 SOURCE
#   csidN:0 SINK             csidN:1 SOURCE
#   vfe0_rdi0:0 SINK

media-ctl -d "$MEDIA" -V "\"$SENSOR\":0[fmt:$FMT field:none]"
media-ctl -d "$MEDIA" -V "\"$CSIPHY\":0[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSIPHY\":1[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSID\":0[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSID\":1[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$VFE\":0[fmt:$FMT]"

media-ctl -d "$MEDIA" -l "\"$CSIPHY\":1->\"$CSID\":0[1]"
media-ctl -d "$MEDIA" -l "\"$CSID\":1->\"$VFE\":0[1]"

media-ctl -d "$MEDIA" -p | rg 'csiphy4|csid0|vfe0_rdi0|\[ENABLED\]'
```

If `msm_csid0` fails, repeat the last two `-l` lines with `msm_csid1` …
`msm_csid4` (keep the same pad indices unless `-p` shows otherwise).

---

## 5) Stream `/dev/video0`

```bash
v4l2-ctl -d "$VIDEO" --list-formats-ext
v4l2-ctl -d "$VIDEO" --set-fmt-video=width=1928,height=1092,pixelformat=pgAA
# live video0: pgAA (10-bit GRBG packed), pRAA, BG10, GRBG, BA81, …

OUT=/tmp/ov02c10.raw
rm -f "$OUT"
v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count=10 --stream-to="$OUT"

ls -l "$OUT"
wc -c "$OUT"
test -s "$OUT" && echo OK || echo FAIL
```

Success: **size > 0** (~2.5 MiB × frame count for 10-bit 1928×1092).

---

## 6) Automated helper

```bash
./scripts/camera-ov02c10-raw.sh
# tries msm_csid0 .. msm_csid4; streams /dev/video0 by default
echo $?
```

`--dry-run` prints `media-ctl` / `v4l2-ctl` without capturing.

Environment overrides: `MEDIA`, `VIDEO`, `CSID`, `FRAMES`, `OUT`, `PIXFMT`,
`*_PAD` — see script header.

---

## 7) Failure triage (still 0 bytes)

```bash
{
  echo "=== uname ==="; uname -a
  echo "=== dmesg ==="; dmesg | rg 'ov02c10|camss|csiphy|csid|vfe|dma'
  echo "=== media-ctl -p ==="; media-ctl -d /dev/media0 -p
  echo "=== v4l2-ctl video0 ==="; v4l2-ctl -d /dev/video0 --all
  echo "=== capture ==="; ls -l /tmp/ov02c10.raw 2>/dev/null || true
} | tee /tmp/cam-capture-fail.txt
```

| Symptom | Likely cause |
|---------|----------------|
| `csiphy4`:1→CSID still `[]` | `-l` pad mismatch or wrong CSID — try `csid1`…`csid4` |
| Links OK, CSIPHY still `UYVY8/1920x1080` | Formats not applied — re-run all `-V` lines |
| Formats OK, 0 B stream | Wrong CSID or pixelformat — check `--list-formats-ext` |
| `-32` pipeline error | Bayer code mismatch — use `SGRBG10_1X10` on **all** pads |

---

## Omarchy VERIFY block (copy/paste)

After pkgrel **15** probe is green:

```bash
# probe
uname -r
dmesg | rg 'ov02c10|chip id 0x5602|vreg_l7b|vreg_l3m'
i2cdetect -y 8

# topology snapshot
media-ctl -d /dev/media0 -p | tee /tmp/cam15-media-topology.txt
media-ctl -d /dev/media0 -p | rg 'ov02c10|csiphy4|csid|vfe0_rdi0|video0'

# pipeline (entity names; csid0 first)
MEDIA=/dev/media0 VIDEO=/dev/video0
SENSOR='ov02c10 8-0036' CSIPHY='msm_csiphy4' CSID='msm_csid0' VFE='msm_vfe0_rdi0'
FMT='SGRBG10_1X10/1928x1092'
media-ctl -d "$MEDIA" -V "\"$SENSOR\":0[fmt:$FMT field:none]"
media-ctl -d "$MEDIA" -V "\"$CSIPHY\":0[fmt:$FMT]" -V "\"$CSIPHY\":1[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$CSID\":0[fmt:$FMT]" -V "\"$CSID\":1[fmt:$FMT]"
media-ctl -d "$MEDIA" -V "\"$VFE\":0[fmt:$FMT]"
media-ctl -d "$MEDIA" -l "\"$CSIPHY\":1->\"$CSID\":0[1]"
media-ctl -d "$MEDIA" -l "\"$CSID\":1->\"$VFE\":0[1]"
v4l2-ctl -d "$VIDEO" --set-fmt-video=width=1928,height=1092,pixelformat=pgAA
v4l2-ctl -d "$VIDEO" --stream-mmap --stream-count=10 --stream-to=/tmp/ov02c10.raw
ls -l /tmp/ov02c10.raw; wc -c /tmp/ov02c10.raw

# scripted (auto-tries csid0..4)
git clone -b cursor/vivobook-camera-phase-c-977f \
  https://github.com/HurlyDesousa/linux-aarch64-vivobook.git /tmp/vivobook-cam
/tmp/vivobook-cam/scripts/camera-ov02c10-raw.sh
```

Success: `/tmp/ov02c10.raw` **non-zero** bytes.
