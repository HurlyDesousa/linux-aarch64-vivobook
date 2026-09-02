# linux-aarch64-vivobook

Custom [Arch Linux ARM](https://github.com/archlinuxarm/PKGBUILDs/tree/master/core/linux-aarch64)
`linux-aarch64` for an ASUS Vivobook S 15 **S5507QA** (Snapdragon X Elite
X1E-78-100, DTB `x1e80100-asus-vivobook-s15`) already running Omarchy ARM.

This is **not** the omarchy-iso fork. Native-build on the laptop (X Elite).
Dual-boots with stock `linux-aarch64`: this package does not Provide `linux`
and does not Conflict the stock kernel.

## Config diff vs the live 7.2.0-2 kernel

| Symbol | Live 7.2.0-2 | This fragment |
|--------|----------------|---------------|
| `CONFIG_RESET_GPIO` | unset | **y** (WSA amp reset / unmute after ADSP) |
| `CONFIG_POWER_RESET_GPIO` | y | unchanged |
| `CONFIG_VIDEO_QCOM_IRIS` | unset | **m** (needs `qcvss8380.mbn`; decode still needs the module) |
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
