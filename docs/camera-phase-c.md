# Camera Phase C — sensor bind + media pipeline (pkgrel 13)

Phase A/B already bring up CAMCC, CCI, and CAMSS. Live Omarchy on the
installed Vivobook (current kernel with CAMSS) confirmed:

| Piece | Live status |
|-------|-------------|
| `/dev/video0`–`video15` + `/dev/media0` | **EXIST** — CAMSS already up |
| `v4l-subdev0`–`27` under `acb7000.isp` | present |
| `ac15000.cci` (CCI0) | **BOUND** — `i2c-5` (bus@0), `i2c-6` (bus@1) |
| `ac16000.cci` (CCI1) | **BOUND** — `i2c-7` (bus@0), `i2c-8` (bus@1) |
| CCI clients on i2c-5..8 | **NONE** |
| `ov02c10.ko` | on disk, **not loaded** (no OF match) |
| `i2cdetect -y 5..8` | **ALL EMPTY** (`--`) + `i2c-qcom-cci … queue N timeout` |

Phase C does **not** create `/dev/video*` from scratch. Those nodes are
CAMSS capture/RDI devices and are already there. The missing piece is
**sensor bind** (power + CCI client + chip-id) so a media-controller
pipeline can run: sensor → csiphy4 → csid → vfe rdi → existing video node.

Empty CCI ACKs do **not** disprove `OV02C10 @ 0x36`. USB 1.2/1.8 V rails
(`vreg_l3e_1p2` / `vreg_l3d_1p8`) are already on for eUSB and the sensor
still does not ACK, so those are the **wrong** supplies. The sensor is
unpowered until DTS enables dedicated rails + MCLK + XSHUTDOWN.

`0008-x1e80100-vivobook-camera-phase-c.patch` adds only the sensor OF
node, pm8010 RGB rails, reset/MCLK pinctrl, and the v7.2 CAMSS `port@3`
(csiphy4) link. It does **not** change 0003/0004, speakers, or PAS.

Out of scope: keyboard/touchpad (unrelated, leave as-is);
`omarchy-hw-laptop` ACPI lid fail; speakers/PAS/qebspil/ADSP;
Lenovo/Yoga sensor-node copies.

## What the DTS adds (HUNCH labelled)

No new i2c ACK exists yet, so the node stays the Phase A/B hunch.

| Item | Value | Evidence |
|------|--------|----------|
| Bus | `&cci1_i2c1` → live **i2c-8** | CCI1 bus@1 on 7.2.2-12 |
| Addr / compat | `camera@36` / `ovti,ov02c10` | empty scan does not refute |
| Reset | `tlmm 237` ACTIVE_LOW (XSHUTDOWN) | SoC reference-design pin; unused on this board |
| MCLK | `CAM_CC_MCLK4` @ 19.2 MHz, `gpio100` `cam_aon` | same; x1e80100 pinctrl groups gpio100 as `cam_aon` |
| AVDD | `vreg_l7m_2p8` (pm8010 LDO7) | dedicated camera PMIC; 7.2 has `qcom,pm8010-rpmh-regulators` |
| DVDD | `vreg_l2m_1p2` (pm8010 LDO2) | RGB mapping used on T14s/Romulus |
| DOVDD | `vreg_l4m_1p8` (pm8010 LDO4) | same |
| Parents | `vreg_s5j_1p2`, `vreg_s4c_1p8`, `vreg_bob1` | **this board's** rails, not Yoga phandles |
| CSI | `&camss port@3` (csiphy4), 2-lane, 400 MHz | v7.2 embedded-CSIPHY binding |

Driver facts once probe succeeds: chip-id `0x5602`, pad format
`SGRBG10` / 1928×1092, link-freq 400 MHz.

If `rpmh-regulator` rejects pmic-id `m`, pm8010 is not on this SPMI
bus — capture that dmesg before rewriting rails.

If chip-id is not `0x5602` or ACPI HID is `OVTI08X40`, change
`compatible` to `ovti,ov08x40` and `data-lanes` to `<1 2 3 4>` (same
0x36 — do not enable both). `CONFIG_VIDEO_OV08X40=m` is built.

## Omarchy install

Native-build on the laptop. Dual-boot: this package does not replace
stock `linux-aarch64`.

```bash
sudo pacman -S --needed base-devel xmlto docbook-xsl kmod inetutils bc git dtc python pahole \
    i2c-tools v4l-utils ffmpeg
# optional GUI preview (RAW10 often will not open in these):
# sudo pacman -S --needed cheese guvcview

git clone -b cursor/vivobook-camera-phase-c-977f \
    https://github.com/HurlyDesousa/linux-aarch64-vivobook.git
cd linux-aarch64-vivobook
makepkg -s
sudo pacman -U linux-aarch64-vivobook-7.2.2-13-*.pkg.tar.* \
              linux-aarch64-vivobook-headers-7.2.2-13-*.pkg.tar.*
sudo limine-update
sudo reboot
```

Select `7.2.2-13-aarch64-vivobook` (or `7.2.0-13-…-ARCH` localversion).

## VERIFY (order matters)

Pre-Phase-C `i2cdetect` on i2c-5..8 is expected empty. After this DTB,
the **driver** enables pm8010 + MCLK + deasserts reset at probe. That is
the power-on path. Check probe **first**; only then can i2cdetect ACK;
only then can the media pipeline stream.

`/dev/video0`–`15` existing before this reboot is **not** success.

### 1) dmesg — sensor probe (required)

```bash
uname -r
# expect 7.2.2-13 / 7.2.0-13-aarch64-vivobook

dmesg | grep -E 'ov02c10|ov08x40|cci|camss|pm8010|rpmh-regulator|csiphy'
lsmod | grep -E 'ov02c10|ov08x40|qcom_camss|i2c_qcom_cci'

# success: ov02c10 bound, chip id 0x5602, no "failed to find sensor"
# fail signatures:
#   rpmh / pm8010 / "failed to enable regulators"  -> rails / pmic-id m
#   "failed to get imaging clock" / clk 19.2 MHz   -> MCLK4
#   "failed to get reset gpio"                     -> gpio237
#   chip id mismatch / -ENXIO                      -> try OV08X40 or other bus
#   "waiting for fwnode graph endpoint"            -> CAMSS port@3 link
```

### 2) i2cdetect — CCI ACK (only after probe)

```bash
ls /sys/class/i2c-adapter/
# i2c-5/6 = CCI0, i2c-7/8 = CCI1; sensor hunch is i2c-8
i2cdetect -y 8          # expect UU (driver bound) or 36
i2cdetect -y 5; i2cdetect -y 6; i2cdetect -y 7   # if 8 still empty
```

CCI queue timeouts with every `--` still mean unpowered / wrong bus,
not "0x36 is wrong" by itself.

### 3) media pipeline — bind the existing video node

Dump the graph. Sensor entity must appear; `video0`–`15` were already
there.

```bash
v4l2-ctl --list-devices
media-ctl -p -d /dev/media0
media-ctl -p -d /dev/media0 | grep -E 'ov02c10|ov08x40|csiphy|csid|vfe|entity'
```

Expect an `ov02c10 8-0036` (or `ov08x40 …`) entity linked toward
`msm_csiphy4`. Entity names come from that dump — substitute if they
differ. Then set RAW10 1928×1092 and enable csiphy → csid → vfe rdi:

```bash
MEDIA=/dev/media0
# names are from media-ctl -p; typical x1e80100 CAMSS:
#   "ov02c10 8-0036"  "msm_csiphy4"  "msm_csid0"  "msm_vfe0_rdi0"
media-ctl -d $MEDIA --reset
media-ctl -d $MEDIA -V '"ov02c10 8-0036":0[fmt:SGRBG10_1X10/1928x1092 field:none]'
media-ctl -d $MEDIA -V '"msm_csiphy4":0[fmt:SGRBG10_1X10/1928x1092]'
media-ctl -d $MEDIA -V '"msm_csid0":0[fmt:SGRBG10_1X10/1928x1092]'
media-ctl -d $MEDIA -V '"msm_vfe0_rdi0":0[fmt:SGRBG10_1X10/1928x1092]'
media-ctl -d $MEDIA -l '"msm_csiphy4":1 -> "msm_csid0":0[1]'
media-ctl -d $MEDIA -l '"msm_csid0":1 -> "msm_vfe0_rdi0":0[1]'
```

Find the **capture** node attached to that VFE RDI (do not assume
`/dev/video0`):

```bash
media-ctl -p -d $MEDIA | grep -A2 'vfe0_rdi0\|vfe_lite'
# then, using the videoN listed for that entity:
v4l2-ctl -d /dev/videoN --list-formats-ext
v4l2-ctl -d /dev/videoN --set-fmt-video=width=1928,height=1092,pixelformat=GRBG \
         --stream-mmap --stream-count=2 --stream-to=/tmp/cam-test.raw
# pixelformat: try GRBG / GB10 / RG10 as listed by --list-formats-ext
```

Cheese/guvcview usually want YUYV. First success is a non-zero
`cam-test.raw` (or ffmpeg on that same `videoN`). GUI preview is a
follow-up after RAW capture works.

`camera@8e100000` reserved-memory and `camera0/1-thermal` already appear
on the live DT (SoC / later hamoa). Phase C does not add them.

`camcc … sync_state pending` for CCI/ISP can still appear at boot;
it is not the Phase C pass/fail.

## If probe or pipeline fails

| Symptom | Next |
|---------|------|
| no ov02c10 lines | DTB not this package; check `/proc/device-tree` for `cci@ac16000/.../camera@36` |
| rpmh / regulators fail | pm8010 id `m` wrong or missing; dump `dmesg \| grep rpmh` |
| chip-id mismatch | try OV08X40 compatible + 4-lane; or move node to i2c-5/6/7 |
| still no ACK after successful chip-id | unexpected; capture `i2cdetect` + `media-ctl -p` |
| sensor bound, no csiphy link | CAMSS `port@3` / remote-endpoint; paste `media-ctl -p` |
| links set, zero-length capture | format/lane mismatch or still-wrong CSIPHY rails; paste v4l2-ctl + dmesg |
