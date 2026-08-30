# linux-aarch64-vivobook

Custom [Arch Linux ARM](https://github.com/archlinuxarm/PKGBUILDs/tree/master/core/linux-aarch64)
`linux-aarch64` for an ASUS Vivobook S 15 **S5507QA** (Snapdragon X Elite
X1E-78-100, DTB `x1e80100-asus-vivobook-s15`) already running Omarchy ARM.

This is **not** the omarchy-iso fork. Native-build on the laptop (X Elite).

## Config diff vs the live 7.2.0-2 kernel

Live measurements:

| Symbol | Live 7.2.0-2 | This fragment |
|--------|----------------|---------------|
| `CONFIG_RESET_GPIO` | unset | **y** (WSA amp reset / unmute after ADSP) |
| `CONFIG_POWER_RESET_GPIO` | y | unchanged |
| `CONFIG_VIDEO_QCOM_IRIS` | unset | **m** (needs `qcvss8380.mbn`; decode still needs the module) |
| `CONFIG_QCOM_Q6V5_PAS` | m | unchanged |
| `CONFIG_SND_SOC_SC8280XP` | m | unchanged |

ALARM's current `core/linux-aarch64` config already has `CONFIG_RESET_GPIO=m`.
The live box is `7.2.0-2-aarch64-ARCH` with it **unset**. We force `=y` so the
reset controller is there before the codec probes.

See `config.vivobook`. The PKGBUILD starts from ALARM's full `config` and
merges this fragment.

## ADSP -22 (honest call)

**RESET_GPIO-only.** No kernel patch in this tree claims to fix ADSP.

On the running 7.2-2 module:

- Firmware from official ASUS S5507QA Qualcomm BSP V1.318.7800.0 is already
  installed under `/usr/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/`.
  Blobs are **not** in this repo.
- CDSP remoteproc runs. ADSP fails every boot:
  `qcom_q6v5_pas error -22 initializing firmware .../adsp_dtbs.elf` then
  `Failed to load program segments: -22`.
- `lite_pas_id=0x1f` and `lite_dtb_pas_id=0x29` are **already** in the 7.2-2
  module. Re-adding the 2025 "Shutdown lite ADSP DTB on X1E" patch is a no-op.
- Lenovo 21N1 `adsp_dtbs.elf` also returned -22. Reverted.

Remaining -22 is likely TZ still holding the lite DTB region, metadata/ELF
auth, or a later mainline carveout/auth-reset path that is not in 7.2-2. That
is unverified. RESET_GPIO does not fix ADSP bring-up; it is for speaker unmute
*after* ADSP is up.

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

`Provides: linux=7.2` so Omarchy Limine / mkinitcpio still resolve. Conflicts
with stock `linux-aarch64`. UKI path:
`/boot/EFI/Linux/omarchy_linux-aarch64.efi`.

Kernel tarball is large. Build on the laptop, not a GitHub runner.

## Firmware

Do not commit Qualcomm/ASUS `.mbn` / `.elf` / BSP exe. Fetch from the official
S5507QA BSP; see the [omarchy-iso fork docs](https://github.com/HurlyDesousa/omarchy-iso/blob/asus-vivobook-s15/docs/asus-vivobook-s15.md).
