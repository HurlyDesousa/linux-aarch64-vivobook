# ADSP -22 on ASUS Vivobook S15 (x1e80100)

Symptom on Omarchy ARM, `linux-aarch64-vivobook` 7.2.x:

```
qcom_q6v5_pas 6800000.remoteproc: error -22 initializing firmware
    qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
remoteproc remoteproc0: Failed to load program segments: -22
```

CDSP remoteproc on the matching ASUS firmware is fine. GPU / display / Wi-Fi
are fine. `qcom-battmgr-*` sysfs exists but every property is EAGAIN
(`service_up=false`) when lite ADSP was killed and full ADSP never started.
`aplay -l` has no card. Lite ADSP has charging/USB-C, not audio.

**This is attach-to-lite fallback, not a TZ signature fix.** Full audio ADSP
still needs a TZ-accepted DTB (QTI-CASS or qebspil), not another DTS change.

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
  lite_dtb=0x29.
- `CONFIG_RESET_GPIO`. That is for WSA unmute *after* full ADSP is up.
- Wrong OEM DTB. Lenovo `adsp_dtbs.elf` also returned -22.

`adsp_dtbs.elf` is a Qualcomm `CFGL` v2 container (8 DTBs: hamoa + purwa
default/charger/audio/sensor). CDSP uses the same CFGL format (2 DTBs) and
authenticates. TZ is not rejecting "CFGL vs FDT".

## What the -22 actually is

`qcom_mdt_read_metadata()` finds the hash PHDR (`flags & TYPE_MASK == HASH`,
offset `0x11000`, size `0xf38`) and builds ELF-header + hash. That succeeds.

`qcom_scm_pas_init_image(pas_id=0x24, metadata)` then returns `-EINVAL`.
The remoteproc core wraps that as `Failed to load program segments: -22`.

CDSP has no lite counterpart (`lite_pas_id` is 0). Same `PAS_INIT_IMAGE`
path works for CDSP (QTI-CASS signed).

## 7.2.2-2 result (pkgrel 2, commit 6bbfb584)

Native 7.2.2-2 booted on S5507QA after the PAS_INIT-after-power patch:

```
CDSP 32300000: dtb id=0x25 -22, main id=0x12 -22, then CDSP came up anyway
ADSP 6800000: lite id=0x1f 0, lite-dtb id=0x29 0, dtb id=0x24 -22, main id=0x1 -22
then error -22 initializing qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
```

Lite leftover **did** shut down (return 0). Init of PAS 0x24 is still -22.
TZ will not accept this OEM-signed ADSP DTB metadata from NS. Battery is
EAGAIN (lite was killed, full ADSP never started). No soundcards.
CDSP/GPU/SSH fine.

Do **not** try another DTS tweak. Do **not** try to make TZ accept the blob.

## Kernel change (pkgrel 2)

`0001-x1e-adsp-dtb-init-after-power.patch` (still a single file at repo root):

1. Move DTB `qcom_mdt_pas_load()` into `qcom_pas_start()` after proxy PDs,
   XO, and regulators.
2. `qcom_scm_pas_shutdown()` leftover `dtb_pas_id` (0x24) / `pas_id` (1).
3. PAGE-align the PAS metadata DMA buffer (`ALIGN(size, SZ_4K)`).

## Kernel change (pkgrel 3)

Same patch file, rewritten in place (no 0002). Keeps (1)-(3). Changes:

1. Do **not** `qcom_scm_pas_shutdown` `lite_pas_id` (0x1f) or
   `lite_dtb_pas_id` (0x29) until DTB PAS_INIT **succeeds**. Harmless
   shutdown of unused full ids (returned -22 = not running) stays.
2. If DTB firmware request or `qcom_mdt_pas_load` (PAS_INIT 0x24) fails
   **and** this rproc has `pas->lite_pas_id` nonzero: do not fail start.
   Log that TZ rejected the DTB and we are attaching to UEFI lite ADSP
   so GLINK/battmgr can work. Skip main MDT load / `pas_auth_and_reset`.
   Leave lite running. Return 0 from `start()` so remoteproc goes
   RUNNING and glink/sysmon/ssr subdevs can attach. `stop()` will not
   `pas_shutdown` lite (that killed charging on rmmod/reboot in pkgrel 2).
3. If DTB PAS_INIT succeeds: then shutdown lite+lite-dtb and continue
   the full-ADSP start (map DTB carveout, auth_reset DTB, load main MBN).
4. CDSP has no `lite_pas_id` - stays on the full-start path. Fallback
   is gated on `pas->lite_pas_id`.
5. Module param `qcom_q6v5_pas.attach_lite_on_dtb_fail` (bool, default
   true). Boot with `qcom_q6v5_pas.attach_lite_on_dtb_fail=0` to restore
   kill-lite-then-init for A/B.

Upstream linux-next has `qcom_pas_attach()` + `RPROC_DETACHED` /
`early_boot` (Nord/SOCCP, and a "firmware missing -> attach lite" path).
That does not apply cleanly to 7.2 (needs remoteproc-core DETACHED,
handover-IRQ tracking, and it attaches at probe when firmware is
**missing**, not after a present DTB fails PAS_INIT). pkgrel 3 uses
`start()` returns 0 instead of backporting that.

## How to tell if pkgrel 3 worked

After `pacman -U` + `limine-update` + reboot into
`7.2.2-3-aarch64-vivobook`:

```
dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/capacity
aplay -l
```

Expected on this board (TZ still rejects 0x24):

- `PAS shutdown dtb (id=0x24): -22` and `main (id=0x1): -22` (not running)
- **no** `PAS shutdown lite (id=0x1f): 0` before the DTB error
- `error -22 initializing firmware .../adsp_dtbs.elf`
- `attaching to UEFI lite ADSP`
- `remoteproc0` is `running`
- `capacity` reads (battmgr / GLINK against lite)
- `aplay -l` still has **no** card (lite has no audio)
- GPU/CDSP/Wi-Fi/SSH still up

If DTB PAS_INIT ever succeeds (QTI-CASS / qebspil blob): lite shutdown
lines appear **after** a successful init, then full ADSP + soundcard.

A/B back to pkgrel 2 sequence: kernel cmdline
`qcom_q6v5_pas.attach_lite_on_dtb_fail=0`.

## 7.2.2-3 result (pkgrel 3, attach-to-lite worked)

Booted on S5507QA, `7.2.0-3-aarch64-vivobook-ARCH`:

- PAS shutdown dtb `0x24` -22, main `0x1` -22, then TZ rejected
  `adsp_dtbs.elf` -22; attached to UEFI lite ADSP PAS `0x1f`
- No lite shutdown before the DTB error
- `remoteproc0` adsp running, `remoteproc1` cdsp running
- battmgr: `status=Charging` `present=1` `voltage_now=11788000`
  usb `online=1` ac `online=0`
- No sysfs `capacity` or `charge_now` (**ENODATA** — the files exist,
  reads fail). Lite ADSP does not send SOC.
- `energy_now=6600000` `energy_full=56030000` (~12%).
  `power_now=29265000`
- `aplay -l`: no soundcards (expected on lite; do not try to fix audio)

GLINK/battmgr against lite is up. Remaining battery UX hole is percent.

## Kernel change (pkgrel 4)

Second patch, `0002-qcom-battmgr-capacity-from-energy.patch` (0001
attach-to-lite is unchanged):

1. Add `POWER_SUPPLY_PROP_CAPACITY` to `x1e80100_bat_props` (7.2 listed
   it for sc8280xp but not X Elite, so sysfs `capacity` was missing or
   unreadable).
2. In `qcom_battmgr_bat_get_property`, if `status.percent` is
   `(unsigned int)-1` (the driver's "SOC not valid" sentinel from
   `qcom_battmgr_sc8280xp_callback` when `last_full_capacity == 0`)
   **and** `info.last_full_capacity > 0`: return
   `DIV_ROUND_CLOSEST_ULL(energy_now * 100, energy_full)` clamped to
   0..100. `energy_now` is `status.capacity`; `energy_full` is
   `info.last_full_capacity` (uWh when `unit == mWh`).
3. Prefer firmware SOC when `status.percent` is valid (full ADSP /
   sm8350 `BATT_CAPACITY` later). Only fall back when SOC is missing.
4. Do **not** invent `charge_now` (still ENODATA for mWh packs; that is
   correct — use `energy_now`).

After reboot into `7.2.2-4-aarch64-vivobook`:

```
cat /sys/class/power_supply/qcom-battmgr-bat/capacity
```

should print **~12** given the 7.2.2-3 energy ratio
(`6600000/56030000`).
