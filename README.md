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

The -22 is `qcom_scm_pas_init_image(0x24)` (TZ metadata), raised from
`qcom_pas_load()` **before** LCX/LMX and XO are enabled. Lite ADSP is already
up from UEFI. pkgrel 2 moves that init into `qcom_pas_start()` after power,
shuts down leftover PAS 0x24 / PAS 1 as well as lite, PAGE-aligns the
metadata DMA buffer, and logs every shutdown errno.

See [docs/adsp-22.md](docs/adsp-22.md) and
`patches/0001-x1e-adsp-dtb-init-after-power.patch`.

If ADSP still fails after reboot, grab the new `PAS shutdown` dmesg lines.
`0` on lite/dtb then still `-22` on init means TZ policy (not this sequence).
A non-zero lite shutdown means TZ will not release UEFI lite ADSP.

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
