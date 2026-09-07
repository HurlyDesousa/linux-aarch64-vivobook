# Camera Phase C — OV02C10 sensor bind (pkgrel 13)

Phase A/B already bring up CAMCC, CCI, and CAMSS. Live **7.2.2-12** on
S5507QA confirmed that stack:

| Piece | Live status |
|-------|-------------|
| `acb7000.isp` / qcom-camss | **UP** — `/dev/video0-15`, `/dev/media0`, `v4l-subdev0-27` |
| `ac15000.cci` (CCI0) | **BOUND** — `i2c-5` (bus@0), `i2c-6` (bus@1) |
| `ac16000.cci` (CCI1) | **BOUND** — `i2c-7` (bus@0), `i2c-8` (bus@1) |
| CCI clients on i2c-5..8 | **NONE** |
| `ov02c10.ko` | on disk, **not loaded** (no OF match) |
| `i2cdetect -y 5..8` | **ALL EMPTY** (`--`) + `i2c-qcom-cci … queue N timeout` |

Empty CCI ACKs do **not** disprove `OV02C10 @ 0x36`. USB 1.2/1.8 V rails
(`vreg_l3e_1p2` / `vreg_l3d_1p8`) are already on for eUSB and the sensor
still does not ACK, so those are the **wrong** supplies. The sensor is
unpowered until DTS enables dedicated rails + MCLK + XSHUTDOWN.

`0008-x1e80100-vivobook-camera-phase-c.patch` adds only the sensor OF
node, pm8010 RGB rails, reset/MCLK pinctrl, and the v7.2 CAMSS `port@3`
(csiphy4) link. It does **not** change 0003/0004, speakers, or PAS.

## What the DTS adds (HUNCH labelled)

| Item | Value | Evidence |
|------|--------|----------|
| Bus | `&cci1_i2c1` → live **i2c-8** | CCI1 bus@1 on 7.2.2-12 |
| Addr / compat | `camera@36` / `ovti,ov02c10` | Phase A/B hunch; empty scan does not refute |
| Reset | `tlmm 237` ACTIVE_LOW (XSHUTDOWN) | SoC reference-design pin; unused on this board |
| MCLK | `CAM_CC_MCLK4` @ 19.2 MHz, `gpio100` `cam_aon` | same; x1e80100 pinctrl groups gpio100 as `cam_aon` |
| AVDD | `vreg_l7m_2p8` (pm8010 LDO7) | dedicated camera PMIC; 7.2 has `qcom,pm8010-rpmh-regulators` |
| DVDD | `vreg_l2m_1p2` (pm8010 LDO2) | RGB mapping used on T14s/Romulus |
| DOVDD | `vreg_l4m_1p8` (pm8010 LDO4) | same |
| Parents | `vreg_s5j_1p2`, `vreg_s4c_1p8`, `vreg_bob1` | **this board's** rails, not Yoga phandles |
| CSI | `&camss port@3` (csiphy4), 2-lane, 400 MHz | v7.2 embedded-CSIPHY binding |

Not copied: Yoga sensor node, Yoga pm8010 GPIO map, speakers/PAS.

If `rpmh-regulator` rejects pmic-id `m`, pm8010 is not on this SPMI
bus — capture that dmesg before rewriting rails.

If chip-id is not `0x5602` or ACPI HID is `OVTI08X40`, change
`compatible` to `ovti,ov08x40` and `data-lanes` to `<1 2 3 4>` (same
0x36 — do not enable both). `CONFIG_VIDEO_OV08X40=m` is built.

## Omarchy install

```bash
sudo pacman -S --needed base-devel xmlto docbook-xsl kmod inetutils bc git dtc python pahole \
    i2c-tools v4l-utils ffmpeg
# optional preview apps:
# sudo pacman -S --needed cheese guvcview

git clone https://github.com/HurlyDesousa/linux-aarch64-vivobook.git
cd linux-aarch64-vivobook
# this PR branch, or main after merge
makepkg -s
sudo pacman -U linux-aarch64-vivobook-7.2.2-13-*.pkg.tar.* \
              linux-aarch64-vivobook-headers-7.2.2-13-*.pkg.tar.*
sudo limine-update
sudo reboot
```

Select `7.2.2-13-aarch64-vivobook` (or `7.2.0-13-…-ARCH` localversion).
Does **not** replace stock `linux-aarch64`.

## VERIFY (order matters)

Pre-Phase-C `i2cdetect` on i2c-5..8 is expected empty. After this DTB,
the **driver** enables pm8010 + MCLK + deasserts reset at probe. Check
probe **first**; only then does i2cdetect have a chance to ACK.

```bash
# 1) Sensor probe — this is the power-on path
uname -r
dmesg | grep -E 'ov02c10|ov08x40|cci|camss|pm8010|rpmh-regulator'
lsmod | grep -E 'ov02c10|ov08x40|qcom_camss|i2c_qcom_cci'
# expect: ov02c10 bound, chip id 0x5602, no "failed to find sensor"
# fail signatures:
#   rpmh / pm8010 / "failed to enable regulators"  -> rails/pmic-id m
#   "failed to get imaging clock" / clk 19.2 MHz   -> MCLK4
#   "failed to get reset gpio"                     -> gpio237
#   chip id mismatch / -ENXIO                      -> OV08X40 or wrong bus

# 2) Only after probe: CCI ACK
ls /sys/class/i2c-adapter/
# i2c-5/6 = CCI0, i2c-7/8 = CCI1; sensor hunch is i2c-8
i2cdetect -y 8          # expect UU (driver bound) or 36
i2cdetect -y 5; i2cdetect -y 6; i2cdetect -y 7   # if 8 still empty

# 3) V4L graph + preview
v4l2-ctl --list-devices
media-ctl -p | grep -E 'ov02c10|ov08x40|csiphy4|entity'
# ffmpeg (headless):
ffmpeg -f v4l2 -input_format rawvideo -video_size 1928x1092 -i /dev/video0 \
       -frames:v 2 /tmp/cam-test.jpg
# GUI: Cheese or guvcview on the qcom-camss capture node
```

`camera@8e100000` reserved-memory and `camera0/1-thermal` already appear
on the live DT (SoC / later hamoa). Phase C does not add them.

## If probe fails

| dmesg | Next |
|-------|------|
| no ov02c10 lines | DTB not this package; check `/proc/device-tree` for `cci@ac16000/.../camera@36` |
| rpmh / regulators fail | pm8010 id `m` wrong or missing; dump `dmesg \| grep rpmh` |
| chip-id mismatch | try OV08X40 compatible + 4-lane; or move node to i2c-5/6/7 |
| still no ACK after successful chip-id | unexpected; capture `i2cdetect` + `media-ctl -p` |
