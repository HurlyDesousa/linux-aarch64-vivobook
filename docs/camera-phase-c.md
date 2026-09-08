# Camera Phase C — sensor bind + media pipeline (pkgrel 14)

Phase A/B already bring up CAMCC, CCI, and CAMSS. Phase C does **not**
create `/dev/video*` — those nodes already exist.

Out of scope: keyboard/touchpad; `omarchy-hw-laptop` ACPI lid;
speakers/PAS/qebspil/ADSP; Lenovo/Yoga sensor-node copies.

## Live 7.2.2-13 FAIL (this is the current problem)

OF bind works. Chip-id does not.

```
ov02c10 8-0036: Error reading reg 0x300a: -110
ov02c10 8-0036: failed to find sensor: -110
ov02c10 8-0036: probe with driver ov02c10 failed with error -110
```

During that probe:

```
vreg_l2m_1p2: Setting 1200000-1256000uV
vreg_l4m_1p8: Setting 1800000-1800000uV
vreg_l7m_2p8: Setting 2800000-2800000uV
```

After fail: those three regulators are **present but disabled**
(`num_users=0`). i2c client `8-0036` stays registered; OF path
`cci@ac16000/i2c-bus@1/camera@36`; `waiting_for_supplier=0`.
`i2cdetect` 5–8 still all `--`. `media-ctl` has no ov02 entity.
No gpio237 / gpio100 / MCLK / pm8010 strings in dmesg besides the
three vreg SET lines.

### What that means

| Observation | Meaning |
|-------------|---------|
| `ov02c10 8-0036` probed | **Bus/addr confirmed** — CCI1 i2c1 @ 0x36 == live i2c-8 |
| Voltage SET on l2m/l4m/l7m | **pm8010-m is in CMD-DB** (`ldom2/4/7`). Not a silent miss. |
| vregs disabled after fail | **Expected** — `ov02c10_identify_module()` fails → `ov02c10_power_off()` drops rails + MCLK + asserts reset. Not a no-op enable. |
| No gpio/MCLK dmesg | **Expected** unless get/enable fails. Clock get succeeded (else `failed to get imaging clock`). Reset is optional and silent. |
| chip-id `-110` + empty i2cdetect | CCI no-ACK. Sensor still not electrically ready **or** those LDOs are not the physical rails **or** reset/MCLK pin is wrong. Not an OV08X40 chip-id mismatch (that would be `-ENXIO` after an ACK). |

`ov02c10_power_on()` order (do **not** rewrite the driver):

1. `clk_prepare_enable` (MCLK)
2. `regulator_bulk_enable` (dovdd, avdd, dvdd)
3. reset assert 2 ms, deassert, wait 5 ms
4. CCI read `0x300a`

`regulator-always-on` / `regulator-boot-on` would only hide this
sequence. Not used.

## What 0008 + 0009 add

`0008` — sensor OF node, pm8010-m rails, reset/MCLK, CAMSS `port@3`.

`0009` (pkgrel 14) — power-on settle only:

- `startup-delay-us` / `regulator-enable-ramp-delay` = 10 ms on the
  **wired** LDOs so `bulk_enable` returns after a settle window
  (driver only waits 5 ms after reset).
- Unused `vreg_l1m_1p2` / `vreg_l3m_1p8` declared for a one-line
  supply swap if l2m/l4m are the wrong physical rails.
- Still **no** OV08X40 node (same 0x36). Swap `compatible` only.

| Item | Value | Evidence |
|------|--------|----------|
| Bus / addr | `&cci1_i2c1` `camera@36` → **i2c-8** | live OF bind `8-0036` |
| Compat | `ovti,ov02c10` | FHD+IR spec; `-110` is no-ACK |
| Reset | `tlmm 237` ACTIVE_LOW | SoC ref-design; unused on this board |
| MCLK | `CAM_CC_MCLK4` @ 19.2 MHz, `gpio100` `cam_aon` | x1e80100 pinctrl; CRD names this CAM_RESET_N / MCLK on those pins |
| AVDD / DVDD / DOVDD | `l7m` 2.8 / `l2m` 1.2 / `l4m` 1.8 | CMD-DB accepted SET on 7.2.2-13 |
| Alt (declared, unused) | `l1m` 1.2 / `l3m` 1.8 | if still `-110` after settle |
| Windows ACPI | `QCOM0C06` Spectra front sensor | not `OVTI02C1`; no public S5507QA camera DTS |

No public Vivobook camera DTS. Do not copy Lenovo sensor wiring.

## Omarchy install

```bash
sudo pacman -S --needed base-devel xmlto docbook-xsl kmod inetutils bc git dtc python pahole \
    i2c-tools v4l-utils ffmpeg
git clone -b cursor/vivobook-camera-phase-c-977f \
    https://github.com/HurlyDesousa/linux-aarch64-vivobook.git
cd linux-aarch64-vivobook
makepkg -s
sudo pacman -U linux-aarch64-vivobook-7.2.2-14-*.pkg.tar.* \
              linux-aarch64-vivobook-headers-7.2.2-14-*.pkg.tar.*
sudo limine-update
sudo reboot
```

Select `7.2.2-14-aarch64-vivobook` (uname `7.2.0-14-…-ARCH`).
Does not replace stock `linux-aarch64`.

## VERIFY (order matters)

`ls /dev/video*` is **not** success. After 0009 the **first** question
is: does chip-id still `-110` after the 10 ms rail settle?

### 1) dmesg — sensor probe

```bash
uname -r
# expect 7.2.0-14-aarch64-vivobook

dmesg | rg 'ov02c10|ov08x40|cci|camss|pm8010|rpmh|vreg_l|MCLK|gpio237|ldom'
# or: dmesg | grep -E 'ov02c10|ov08x40|cci|camss|pm8010|rpmh|vreg_l|MCLK|gpio237|ldom'

# success: chip id 0x5602, no "failed to find sensor"
# 7.2.2-13 fail (still possible): "Error reading reg 0x300a: -110"
#   then vregs disabled = power_off cleanup, not a new bug
```

Capture next if still `-110`:

```bash
# rails after failed probe (expect disabled; that is power_off)
for r in /sys/class/regulator/regulator.*/name; do
  n=$(cat "$r")
  case $n in vreg_l*m_*|vreg_l2m*|vreg_l4m*|vreg_l7m*|vreg_l1m*|vreg_l3m*)
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
dmesg | rg 'ldom|rpmh-regulator|could not find RPMh'
```

### 2) i2cdetect — only after a successful chip-id

```bash
i2cdetect -y 8          # UU or 36 once the driver stays bound
i2cdetect -y 5; i2cdetect -y 6; i2cdetect -y 7
```

### 3) media pipeline — only after the entity exists

```bash
media-ctl -p -d /dev/media0 | grep -E 'ov02c10|csiphy|csid|vfe'
# then SGRBG10 1928x1092, csiphy4 -> csid0 -> vfe0_rdi0, capture that videoN
```

## If 14 still `-110`

| Next swap | How |
|-----------|-----|
| Wrong physical LDOs | Point `dvdd-supply` at `<&vreg_l1m_1p2>` and `dovdd-supply` at `<&vreg_l3m_1p8>` (already in DTS, unused) |
| Reset polarity | Try `GPIO_ACTIVE_HIGH` on gpio237 |
| Reset pin | Need ACPI/BSP GPIO (Windows HID `QCOM0C06`); no public dump yet |
| MCLK pin | Need ACPI/BSP; SoC ref is gpio100 `cam_aon` / MCLK4 |
| OV08X40 | Only if a future chip-id ACK returns not `0x5602`. Change `compatible` + 4-lane; do not add a second `@36` |
| `regulator-always-on` | Last resort only, to see whether rails dropping mid-CCI is real |

Paste the `dmesg \| rg` + regulator + clk + gpio237 captures before the
next DTS guess.
