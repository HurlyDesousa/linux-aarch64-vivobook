# Camera Phase C — sensor bind + media pipeline (pkgrel 15)

Phase A/B already bring up CAMCC, CCI, and CAMSS. Phase C does **not**
create `/dev/video*` — those nodes already exist.

Out of scope: keyboard/touchpad; `omarchy-hw-laptop` ACPI lid;
speakers/PAS/qebspil/ADSP; Lenovo/Yoga sensor-node copies.

**HOLD install** until greenlight. Do not `pacman -U` 7.2.2-15 yet.

## Live 7.2.2-14 FAIL

OF bind works. Chip-id does not. Rails that matter were never in the
consumer list.

```
ov02c10 8-0036: Error reading reg 0x300a: -110
ov02c10 8-0036: failed to find sensor: -110
```

`i2cdetect -y 8` empty (CCI master 1 queue 0 timeout). CAMSS
video0–15 still up. DT path `cci@ac16000/i2c-bus@1/camera@36` binds.

After fail: `vreg_l2m_1p2` / `vreg_l4m_1p8` / `vreg_l7m_2p8` are
`state=disabled`, `num_users=0`. That sysfs snapshot **cannot** prove
the driver skipped `regulator_bulk_enable` — 7.2 `ov02c10_probe()`
calls `ov02c10_power_on()` (MCLK + `bulk_enable(dovdd,avdd,dvdd)` +
reset) **before** the 0x300a read, then `ov02c10_power_off()` +
`devm` unwind on identify fail. Supply names already match DT.

What it **does** prove: those three LDOs are not the CAMF pins.
S5507QA AeoB never votes them for the front RGB module.

## AeoB evidence (this is the 0010 change)

[`CAMF_RES_QRD.json`](https://github.com/alexVinarskis/qcom-aeob-dumps/blob/master/asus-vivobook-s15-s5507/CAMF_RES_QRD.json)
(identical to Zenbook A14 CAMF):

| Resource | Value | DT |
|----------|-------|----|
| `PPP_RESOURCE_ID_LDO7_B` | `0x2AB980` = 2.801 V | `vreg_l7b_2p8` (pm8550-b ldo7) |
| `PPP_RESOURCE_ID_LDO3_M` | `0x1B7740` = 1.800 V | `vreg_l3m_1p8` (pm8010-m ldo3) |
| `cam_cc_mclk4_clk` | 19.2 MHz | `CAM_CC_MCLK4_CLK` / gpio100 `cam_aon` |
| TLMMGPIO `0xED` | reset assert → rails → MCLK → deassert | `tlmm 237` ACTIVE_LOW |
| [`SCFG_FRONT_QRD`](https://github.com/alexVinarskis/qcom-aeob-dumps/blob/master/asus-vivobook-s15-s5507/SCFG_FRONT_QRD.json) | `ov02c10.bin`, id `0x5602300A` | `ovti,ov02c10`, chip-id `0x5602` |

[`CAMI_RES_QRD.json`](https://github.com/alexVinarskis/qcom-aeob-dumps/blob/master/asus-vivobook-s15-s5507/CAMI_RES_QRD.json)
(IR) votes `LDO4_M` + `LDO7_M`. The T14s RGB map `l7m`/`l2m`/`l4m`
copied the **IR** PMIC, not CAMF. Yoga Slim 7x had the same `-110`
on that T14s copy and moved RGB off those rails.

`ov02c10_power_on()` order (do **not** rewrite the driver):

1. `clk_prepare_enable` (MCLK)
2. `regulator_bulk_enable` (dovdd, avdd, dvdd) — both avdd and dvdd
   now point at `l7b` (same as Zenbook A14)
3. reset already asserted (`GPIOD_OUT_HIGH` + ACTIVE_LOW); 2 ms;
   deassert; wait 5 ms (AeoB CAMF delay is 5 ms)
4. CCI read `0x300a`

`regulator-always-on` / `regulator-boot-on` would only hide this
sequence. Not used.

## What 0008 + 0009 + 0010 add

`0008` — sensor OF node, pm8010-m rails, reset/MCLK, CAMSS `port@3`.

`0009` (pkgrel 14) — 10 ms settle on the **wrong** T14s LDOs; unused
`l1m`/`l3m`. Did not fix chip-id.

`0010` (pkgrel 15) — AeoB CAMF wiring:

- Add `vreg_l7b_2p8` on existing `regulators-0` (pm8550-b; parent
  `vdd-l6-l7-supply` is already `bob2`)
- `avdd-supply` + `dvdd-supply` = `<&vreg_l7b_2p8>`
- `dovdd-supply` = `<&vreg_l3m_1p8>` (was declared unused)
- Leave `l2m`/`l4m`/`l7m` declared but **unwired** (CAMI leftovers)
- Still **no** OV08X40 node (same 0x36). SCFG says ov02c10.

| Item | Value | Evidence |
|------|--------|----------|
| Bus / addr | `&cci1_i2c1` `camera@36` → **i2c-8** | live OF bind `8-0036` |
| Compat | `ovti,ov02c10` | SCFG_FRONT_QRD `ov02c10.bin` / `0x5602` |
| Reset | `tlmm 237` ACTIVE_LOW | AeoB GPIO `0xED` |
| MCLK | `CAM_CC_MCLK4` @ 19.2 MHz, `gpio100` `cam_aon` | AeoB `cam_cc_mclk4_clk` |
| AVDD / DVDD | `l7b` 2.8 V (shared) | AeoB `LDO7_B` |
| DOVDD | `l3m` 1.8 V | AeoB `LDO3_M` |
| Not CAMF | `l2m` / `l4m` / `l7m` | AeoB CAMI; live 13/14 `-110` |
| Windows ACPI | `QCOM0C06` Spectra front sensor | not `OVTI02C1` |

## Omarchy install (HOLD)

Do **not** install until greenlight. When unblocked:

```bash
sudo pacman -S --needed base-devel xmlto docbook-xsl kmod inetutils bc git dtc python pahole \
    i2c-tools v4l-utils ffmpeg
git clone -b cursor/vivobook-camera-phase-c-977f \
    https://github.com/HurlyDesousa/linux-aarch64-vivobook.git
cd linux-aarch64-vivobook
makepkg -s
sudo pacman -U linux-aarch64-vivobook-7.2.2-15-*.pkg.tar.* \
              linux-aarch64-vivobook-headers-7.2.2-15-*.pkg.tar.*
sudo limine-update
sudo reboot
```

Select `7.2.2-15-aarch64-vivobook` (uname `7.2.0-15-…-ARCH`).
Does not replace stock `linux-aarch64`.

## VERIFY (order matters)

`ls /dev/video*` is **not** success. After 0010 the **first** question
is: does chip-id become `0x5602` now that CAMF rails are `l7b`+`l3m`?

### 1) dmesg — sensor probe

```bash
uname -r
# expect 7.2.0-15-aarch64-vivobook

dmesg | rg 'ov02c10|ov08x40|cci|camss|pm8010|rpmh|vreg_l7b|vreg_l3m|vreg_l2m|vreg_l4m|vreg_l7m|MCLK|gpio237|ldom'
# or: dmesg | grep -E 'ov02c10|ov08x40|cci|camss|pm8010|rpmh|vreg_l7b|vreg_l3m|vreg_l2m|vreg_l4m|vreg_l7m|MCLK|gpio237|ldom'

# success: chip id 0x5602, no "failed to find sensor"
# still-fail: "Error reading reg 0x300a: -110"
```

During probe, expect rpmh **SET** on `vreg_l7b_2p8` and `vreg_l3m_1p8`.
`l2m`/`l4m`/`l7m` staying unused is now **correct** (not CAMF).

Capture next if still `-110`:

```bash
# CAMF rails after probe (success: enabled + users>=1 while bound;
# fail: disabled users=0 is power_off, look at dmesg SET instead)
for r in /sys/class/regulator/regulator.*/name; do
  n=$(cat "$r")
  case $n in vreg_l7b*|vreg_l3m*|vreg_l2m*|vreg_l4m*|vreg_l7m*|vreg_l1m*)
    d=$(dirname "$r")
    echo "$n $(cat $d/microvolts 2>/dev/null) $(cat $d/state 2>/dev/null) users=$(cat $d/num_users 2>/dev/null)"
  esac
done

# MCLK (0 after fail is expected — power_off unprepares it)
cat /sys/kernel/debug/clk/cam_cc_mclk4_clk/clk_enable_count 2>/dev/null
cat /sys/kernel/debug/clk/cam_cc_mclk4_clk/clk_rate 2>/dev/null

# reset pin owner
grep -n 237 /sys/kernel/debug/gpio 2>/dev/null

# rpmh / cmd-db
dmesg | rg 'ldom|rpmh-regulator|could not find RPMh|ldo7'
```

### 2) i2cdetect — only after a successful chip-id

```bash
i2cdetect -y 8          # UU or 36 once the driver stays bound
i2cdetect -y 5; i2cdetect -y 6; i2cdetect -y 7
```

### 3) media pipeline + raw capture — only after the entity exists

Naive `v4l2-ctl` on `/dev/video0` returns **0 bytes** until `media-ctl` sets
**`SGRBG10_1X10/1928x1092`** on CSIPHY/CSID/RDI (CSIPHY defaults to wrong
`UYVY8/1920x1080`) and enables **`msm_csiphy4`:1 → `msm_csidN` →
`msm_vfe0_rdi0`**. Sensor→CSIPHY is already **`[ENABLED,IMMUTABLE]`** on
pkgrel 15 live (`/dev/media0` only).

Full recipe: **[camera-phase-c-preview.md](camera-phase-c-preview.md)**.

Quick check:

```bash
media-ctl -d /dev/media0 -p | rg 'ov02c10|csiphy4|csid|vfe0_rdi0|video0'
./scripts/camera-ov02c10-raw.sh
ls -l /tmp/ov02c10.raw
```

## If 15 still `-110`

Driver already enables `avdd`/`dvdd`/`dovdd` before CCI. Next is not
another T14s LDO guess.

| Next | How |
|------|-----|
| Confirm l7b/l3m SET in dmesg | If no SET on those two, rpmh rejected ldo7-b or l3m |
| Reset still wrong | AeoB is gpio237; try `GPIO_ACTIVE_HIGH` only if SET happened |
| MCLK pin | AeoB votes `cam_cc_mclk4_clk`; SoC pad is gpio100 `cam_aon` |
| OV08X40 | Only if a future chip-id ACK returns not `0x5602`. SCFG says no |
| `regulator-always-on` | Last resort only, to see whether rails dropping mid-CCI is real |

Paste the `dmesg \| rg` + `l7b`/`l3m` regulator + `cam_cc_mclk4_clk` +
`gpio 237` captures before the next DTS guess.
