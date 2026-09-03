# linux-aarch64-vivobook

Custom [Arch Linux ARM](https://github.com/archlinuxarm/PKGBUILDs/tree/master/core/linux-aarch64)
`linux-aarch64` for an ASUS Vivobook S 15 **S5507QA** (Snapdragon X Elite
X1E-78-100, DTB `x1e80100-asus-vivobook-s15`) already running Omarchy ARM.

This is **not** the omarchy-iso fork. Native-build on the laptop (X Elite).
Dual-boots with stock `linux-aarch64`: this package does not Provide `linux`
and does not Conflict the stock kernel.

## Camera — Phase A (pkgrel 5)

**7.2.2-5 (pkgrel 5)** enables the camera infrastructure on
x1e80100/Vivobook S15 so CCI I2C adapters can probe after boot.
No sensor node is wired yet; that is Phase C after CCI is confirmed.

### What was enabled

| Component | Location | Notes |
|-----------|----------|-------|
| CAMCC clock controller | `hamoa.dtsi` | `@0xade0000`; needed by CCI+CAMSS for clocks/power |
| CCI0 I2C adapter | `hamoa.dtsi` | `@0xac15000` IRQ 460; gpio101-104 |
| CCI1 I2C adapter | `hamoa.dtsi` | `@0xac16000` IRQ 271; gpio105-106 + gpio235-236 (aon_cci) |
| CAMSS ISP | `hamoa.dtsi` | `@0xacb7000`; v7.2 embedded-CSIPHY legacy binding |
| CCI pinctrl | `hamoa.dtsi` / tlmm | gpio101-106 `cci_i2c`, gpio235-236 `aon_cci` |
| Board enable | `x1-asus-vivobook-s15.dtsi` | `&camss`, `&cci0`, `&cci1` status=okay |
| `CONFIG_VIDEO_OV02C10=m` | `config.vivobook` | Module compiled, NOT bound (no DTS sensor node yet) |

### What is left as TODO / Phase C

- **Sensor node**: OV02C10 @ CCI1 i2c1 0x36 is a **HUNCH** — must be
  confirmed by `i2cdetect` once CCI adapters appear.
- **CSIPHY supply regulators**: `vdd-csiphy-0p8-supply` / `1p2-supply`
  in the board DTS use `vreg_l1d_0p8` / `vreg_l3e_1p2` as guesses (no
  pm8010 camera PMIC visible in Vivobook DTS).  Verify against BSP
  schematic before wiring a sensor.
- **PHY API**: upstream v13 CSIPHY series (Bryan O'Donoghue / Linaro,
  still under review 2026-07) will replace embedded CSIPHY with
  separate `csiphy@` nodes; update in a follow-up once merged.
- **ACPI HID**: OVTI02C1 vs OVTI08X40 still unconfirmed from Vivobook
  DSDT; not blocking this PR.

### Post-boot checks

```
# After building and installing 7.2.2-5-aarch64-vivobook:
ls /sys/class/i2c-adapter/          # new i2c-N entries for CCI0 and CCI1
dmesg | grep -E 'cci|camss|csiphy|qcom-camss'
# Phase B: once CCI adapters are confirmed:
i2cdetect -y <N>                    # look for 0x36 on the CCI1 i2c1 bus
ls /dev/video*                      # will be empty until Phase C sensor bind
```

See `0003-x1e80100-vivobook-camera-phase-a.patch` for the full DTS.

---

## Config diff vs the live 7.2.0-2 kernel

| Symbol | Live 7.2.0-2 | This fragment |
|--------|----------------|---------------|
| `CONFIG_RESET_GPIO` | unset | **y** (WSA amp reset / unmute after ADSP) |
| `CONFIG_POWER_RESET_GPIO` | y | unchanged |
| `CONFIG_VIDEO_QCOM_IRIS` | unset | **m** (needs `qcvss8380.mbn`; decode still needs the module) |
| `CONFIG_VIDEO_OV02C10` | unset | **m** (Phase A: module compiled, not bound — no sensor DTS yet) |
| `CONFIG_QCOM_Q6V5_PAS` | m | unchanged |
| `CONFIG_SND_SOC_SC8280XP` | m | unchanged |

See `config.vivobook`. The PKGBUILD starts from ALARM's full `config` and
merges this fragment.

## ADSP -22

Not a DTS carveout mismatch. The ELF and the 7.2 DTS already agree:

- `adsp_dtbs.elf` PT_LOAD paddr `0x8b800000` filesz `0x10e4c` (CFGL + 8 DTBs:
  hamoa/purwa default, charger, audio, sensor)
- `remoteproc_adsp` memory-region is `adspslpi@87e00000` + `q6-adsp-dtb@8b800000`
- `qcadsp8380.mbn` paddr starts at `0x87e00000` (adspslpi)
- CDSP ELF `0x8d900000` matches `q6-cdsp-dtb` and **runs**
- PAS ids already `pas=1`, `dtb=0x24`, `lite=0x1f`, `lite_dtb=0x29`

The -22 is `qcom_scm_pas_init_image(0x24)` (TZ metadata). Lite ADSP is
already up from UEFI.

**7.2.2-2 (pkgrel 2)** moved DTB PAS_INIT into `qcom_pas_start()` after
power, shut down leftover PAS 0x24 / PAS 1 **and lite**, PAGE-aligned
metadata DMA, and logged every shutdown errno. Result on S5507QA: lite
shutdown returned 0, PAS 0x24 still -22. TZ will not accept this
OEM-signed DTB from NS. Battery EAGAIN, no soundcards. CDSP/GPU/SSH fine.

**7.2.2-3 (pkgrel 3)** keeps that sequence except it does **not** kill
lite until DTB PAS_INIT succeeds. If TZ still rejects 0x24 and the rproc
has `lite_pas_id`, `start()` attaches to UEFI lite ADSP (return 0 so
remoteproc goes RUNNING, GLINK/battmgr can attach) instead of failing.
This is **attach-to-lite fallback, not a TZ signature fix**. Full audio
ADSP still needs a TZ-accepted DTB (QTI-CASS or qebspil), not another
DTS change. `aplay -l` will stay empty on lite. Optional cmdline
`qcom_q6v5_pas.attach_lite_on_dtb_fail=0` restores kill-lite-then-init.

**7.2.2-4 (pkgrel 4)** keeps attach-to-lite unchanged. 7.2.2-3 on S5507QA
got lite ADSP + battmgr (Charging, energy_now/energy_full ~12%) but
`capacity` / `charge_now` were ENODATA — lite does not send SOC.
`0002-qcom-battmgr-capacity-from-energy.patch` exports CAPACITY on
x1e80100 and, when firmware SOC is missing, returns
`energy_now/energy_full` percent. Firmware SOC is still preferred when
full ADSP later provides it. Do not expect `aplay -l` to grow a card.

See [docs/adsp-22.md](docs/adsp-22.md). Patches live at repo root as
`0001-x1e-adsp-dtb-init-after-power.patch` and
`0002-qcom-battmgr-capacity-from-energy.patch` (makepkg `source=()`
basenames; copies under `patches/` are optional).

After reboot into `7.2.2-4-aarch64-vivobook`:

```
dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/capacity
aplay -l
```

## Build and install (on the Vivobook)

```bash
sudo pacman -S --needed base-devel xmlto docbook-xsl kmod inetutils bc git dtc python pahole
git clone https://github.com/HurlyDesousa/linux-aarch64-vivobook.git
cd linux-aarch64-vivobook
makepkg -s
sudo pacman -U linux-aarch64-vivobook-*.pkg.tar.* linux-aarch64-vivobook-headers-*.pkg.tar.*
sudo limine-update
sudo reboot
```

Does **not** replace stock `linux-aarch64`. The Omarchy hook should build
`/boot/EFI/Linux/omarchy_linux-aarch64-vivobook.efi` because the package
ships `/usr/lib/modules/<kver>/{pkgbase,vmlinuz}` with `pkgbase=linux-aarch64-vivobook`.
Keep the old kernel as the Limine fallback.

Kernel tarball is large. Build on the laptop, not a GitHub runner.

## Firmware

Do not commit Qualcomm/ASUS `.mbn` / `.elf` / BSP exe. Fetch from the official
S5507QA BSP; see the [omarchy-iso fork docs](https://github.com/HurlyDesousa/omarchy-iso/blob/asus-vivobook-s15/docs/asus-vivobook-s15.md).
