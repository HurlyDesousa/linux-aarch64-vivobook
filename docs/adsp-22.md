# ADSP -22 on ASUS Vivobook S15 (x1e80100)

Symptom on Omarchy ARM, `linux-aarch64-vivobook` 7.2.x:

```
qcom_q6v5_pas 6800000.remoteproc: error -22 initializing firmware
    qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
remoteproc remoteproc0: Failed to load program segments: -22
```

CDSP remoteproc on the matching ASUS firmware is fine. GPU / display / Wi-Fi
are fine. `qcom-battmgr-*` sysfs exists but every property is EAGAIN
(`service_up=false`). `aplay -l` has no card.

## What it is not

- Missing blobs. Firmware is from the ASUS BSP under
  `/usr/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/`.
- DTS vs ELF load address. Measured:

  | blob | PT_LOAD paddr | DTS reserved-memory | match |
  |------|---------------|---------------------|-------|
  | `adsp_dtbs.elf` | `0x8b800000` size `0x10e4c` | `q6-adsp-dtb@8b800000` 512 KiB | yes |
  | `qcadsp8380.mbn` | `0x87e00000` (relocatable) | `adspslpi@87e00000` 59392 KiB | yes |
  | `cdsp_dtbs.elf` | `0x8d900000` | `q6-cdsp-dtb@8d900000` | yes, and it runs |
  | `qccdsp8380.mbn` | `0x8b900000` | `cdsp@8b900000` | yes |

  `adsp-boot-dtb@866c0000` / `adsp-boot@86b00000` are the **lite** carveouts
  used by UEFI. `remoteproc_adsp` does not point at them.

- Missing `lite_dtb_pas_id`. 7.2 already has pas=1, dtb=0x24, lite=0x1f,
  lite_dtb=0x29 and shuts down the lite ids in `qcom_pas_load()`.
- `CONFIG_RESET_GPIO`. That is for WSA unmute *after* ADSP is up.
- Wrong OEM DTB. Lenovo `adsp_dtbs.elf` also returned -22.

`adsp_dtbs.elf` is a Qualcomm `CFGL` v2 container (8 DTBs: hamoa + purwa
default/charger/audio/sensor). CDSP uses the same CFGL format (2 DTBs) and
authenticates. TZ is not rejecting "CFGL vs FDT".

## What the -22 actually is

`qcom_mdt_read_metadata()` finds the hash PHDR (`flags & TYPE_MASK == HASH`,
offset `0x11000`, size `0xf38`) and builds ELF-header + hash. That succeeds.

`qcom_scm_pas_init_image(pas_id=0x24, metadata)` then returns `-EINVAL`.
The remoteproc core wraps that as `Failed to load program segments: -22`.

In 7.2 this SMC runs from `qcom_pas_load()`, **before** `qcom_pas_start()`
enables LCX/LMX and XO. UEFI has already started lite ADSP on those rails.

CDSP has no lite counterpart, so the same `PAS_INIT_IMAGE` in `.load()` works.

## Kernel change (pkgrel 2)

`patches/0001-x1e-adsp-dtb-init-after-power.patch`:

1. Move lite shutdown + DTB `qcom_mdt_pas_load()` into `qcom_pas_start()`
   after proxy PDs, XO, and regulators.
2. Also `qcom_scm_pas_shutdown()` on `dtb_pas_id` (0x24) and `pas_id` (1),
   in case this TZ parked lite on the full ids. Log every return code.
3. PAGE-align the PAS metadata DMA buffer (`ALIGN(size, SZ_4K)`). TZ does
   not get a size argument and protects a page.

## How to tell if it worked

After `pacman -U` + `limine-update` + reboot into
`7.2.2-2-aarch64-vivobook`:

```
dmesg | grep -E 'PAS shutdown|remoteproc|adsp_dtbs|qcom-battmgr|snd'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/capacity
aplay -l
```

Success: `remoteproc0` is `running`, capacity reads, `aplay -l` shows a card,
GPU/CDSP/Wi-Fi still up.

If it still -22, the new `PAS shutdown` dmesg lines are the next
fact. `N=0` on lite and dtb then still -22 means TZ will not accept this
metadata from NS (qebspil / attach, not another DTS tweak). Non-zero lite
shutdown means TZ will not release UEFI lite ADSP.
