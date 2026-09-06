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

## 7.2.2-9 result (post-qebspil VERIFY)

Same attach-to-lite kernel (`0001`, pkgrel 9) after UEFI **qebspil**
(Qualcomm Exit Boot Services Peripheral Image Loader) on S5507QA:

```
aplay -l          # no soundcards
PipeWire          # Dummy / auto_null
PAS shutdown dtb (id=0x24): 0     # was -22 pre-qebspil
PAS shutdown main (id=0x1): -22
# TZ still rejects NS adsp_dtbs.elf → attach-to-lite PAS 0x1f
remoteproc0 adsp running
remoteproc1 cdsp running
# zero ALSA cards
```

This is still **attach-to-lite, not a TZ signature fix**. Lite has no
audio. Do **not** try another board DTS / RESET_GPIO tweak. Do **not**
treat attach-to-lite as a TZ fix.

What changed vs pre-qebspil: **PAS 0x24 is now shutdown-able**. That is
the only new kernel-visible fact.

## What PAS shutdown 0 vs -22 means (7.2 `qcom_scm`)

`qcom_scm_pas_shutdown(pas_id)` is `QCOM_SCM_SVC_PIL` /
`QCOM_SCM_PIL_PAS_SHUTDOWN`. The SCM wrapper returns `ret ?: res.result[0]`:

| return | meaning |
|--------|---------|
| **0** | TZ accepted shutdown. The PAS id was in a shutdown-able state (initialized and/or AUTH_RESET / running). After this call, that state is **gone**. |
| **-22** (`-EINVAL`) | TZ rejected shutdown. Typical for "this PAS id was never brought up". |

There is **no** documented non-destructive "is this PAS running?" call.
`qcom_scm_pas_supported()` only asks whether the id exists. Stephan
Gerhold noted the same on the late-attach series: a PAS status query
would be ideal and is not available.

So post-qebspil `PAS shutdown dtb (id=0x24): 0` means TZ **had** DTB PAS
state for 0x24, and `start()` **destroyed it** before retrying NS
`adsp_dtbs.elf`. `main (id=0x1): -22` means full ADSP was **not**
running. Lite 0x1f was still up (attach-to-lite still works).

## Hypothesis (checked in qebspil + 7.2 PAS/SCM; not yet proven on device)

qebspil (`stephan-gh/qebspil`) for `qcom,x1e80100-adsp-pas` uses the same
PAS ids as 7.2 (`full` DTB 36 / 0x24, lite DTB 41 / 0x29, full main 1,
lite main 31 / 0x1f). At late ExitBootServices it:

1. `TZ_PIL_INIT` + `TZ_PIL_MEM` for DTB then main (UEFI QCOM SCM protocol,
   not Linux NS `PAS_INIT_IMAGE`)
2. Copies ELF segments into the DT carveouts
3. Stops lite (ignore errors)
4. `TZ_PIL_AUTH_RESET` DTB (0x24) then main (0x1)
5. On main AUTH_RESET failure, rolls back by **stopping** the DTB

Firmware paths come from the board `firmware-name` and are read from the
ESP as `/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/{qcadsp8380.mbn,adsp_dtbs.elf}`.

Default qebspil only starts remoteprocs with `qcom,broken-reset`. The
7.2 Vivobook overlay (`&remoteproc_adsp` in
`x1e80100-asus-vivobook-s15.dts`) has **no** `qcom,broken-reset`. So a
stock qebspil binary will skip ADSP unless it was built with
`QEBSPIL_ALWAYS_START=1` (or the DT was patched). The 0x24:0 result
means whatever qebspil build/flags were used **did** touch PAS 0x24.

UEFI SCM `TZ_PIL_INIT` of the same OEM `adsp_dtbs.elf` can succeed when
Linux NS `qcom_scm_pas_init_image(0x24)` returns `-EINVAL`. That matches
the VERIFY: 0x24 was up, then Linux tore it down and NS PAS_INIT failed
again.

Current `0001` `start()` always:

1. `PAS_SHUTDOWN` 0x24 (now 0 — **throws away the UEFI-authenticated DTB**)
2. `PAS_SHUTDOWN` 0x1 (still -22)
3. `request_firmware` + `qcom_mdt_pas_load` of NS `adsp_dtbs.elf`
   (`PAS_INIT_IMAGE` 0x24) → TZ `-EINVAL`
4. attach-to-lite 0x1f

So the next kernel experiment is: **do not tear down 0x24, do not
PAS_INIT the NS ELF, try main `qcadsp8380.mbn` against the
already-authenticated DTB**. That is not a TZ fix and not a DTS tweak.

This does **not** need a remoteproc-core `RPROC_DETACHED` / `early_boot`
backport. Full qebspil takeover (attach to an already-running **main**
ADSP) would, and is the wrong experiment here: main 0x1 is not running.

## Kernel change (pkgrel 10)

New patch `0005-x1e-adsp-reuse-authenticated-dtb.patch` on top of
unchanged `0001` attach-to-lite:

1. Module param `qcom_q6v5_pas.reuse_authenticated_dtb` (bool, **default
   N**). Safest default: keep today's attach-to-lite path unless Omarchy
   opts in. CDSP has no `lite_pas_id`, so the path never runs on CDSP.
2. When the param is set **and** this rproc has `lite_pas_id` (X1E ADSP):
   - do **not** `PAS_SHUTDOWN` 0x24
   - do **not** `request_firmware` / `qcom_mdt_pas_load` / DTB
     `AUTH_RESET` of NS `adsp_dtbs.elf` (no Linux PAS ctx; DTB XPU may
     be locked)
   - still `PAS_SHUTDOWN` main 0x1 leftovers (expected -22)
   - `qcom_mdt_pas_load` main `qcadsp8380.mbn` (`PAS_INIT` 0x1)
   - if that fails: attach-to-lite (lite was never killed) and return 0
   - if it succeeds: then `PAS_SHUTDOWN` lite 0x1f / lite-dtb 0x29
     (qebspil AUTH_RESETs full ADSP only after stopping lite), then main
     `AUTH_RESET` + wait-for-start
   - if main `AUTH_RESET` or wait-for-start fails **after** lite was
     stopped: log `reuse DTB path: lite already stopped; not attaching
     to lite` (charging may drop). Do not pretend lite is still there.
3. Default / param unset: identical to pkgrel 3–9 attach-to-lite,
   including `PAS shutdown dtb (id=0x24): 0` after qebspil.

`0001` / battmgr / CCI / camera patches are unchanged.

## How to tell if pkgrel 10 reuse worked

After `pacman -U` + `limine-update`, A/B via Limine cmdline.

**A — current path (default, no new flag):**

```
dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to|reusing UEFI'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/capacity
aplay -l
```

Expected after qebspil (same as 7.2.2-9 VERIFY):

- `PAS shutdown dtb (id=0x24): 0`
- `PAS shutdown main (id=0x1): -22`
- `error -22 initializing firmware .../adsp_dtbs.elf`
- `attaching to UEFI lite ADSP`
- **no** `reusing UEFI/qebspil DTB`
- `remoteproc0` running, capacity readable, `aplay -l` empty

**B — experimental reuse (add to kernel cmdline):**

```
qcom_q6v5_pas.reuse_authenticated_dtb=1
```

```
dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to|reusing UEFI|reuse DTB|authenticate image'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/{capacity,status}
aplay -l
```

Expected logs (one of these):

| outcome | dmesg | audio / batt |
|---------|-------|----------------|
| reuse + main PAS_INIT fails | `reusing UEFI/qebspil DTB PAS (id=0x24); skip teardown + NS ... PAS_INIT`; **no** `PAS shutdown dtb (id=0x24)`; `error N initializing firmware .../qcadsp8380.mbn`; `attaching to UEFI lite ADSP` | no card; charging should still work |
| reuse + main AUTH_RESET / start fails | reuse line; then `PAS shutdown lite (id=0x1f): 0` (or not); `failed to authenticate image` or `start timed out`; `reuse DTB path: lite already stopped` | no card; **charging may drop** |
| reuse + full ADSP | reuse line; lite shutdown **after** main PAS_INIT; no attach-to-lite; no `-22 initializing .../adsp_dtbs.elf` | `aplay -l` may grow a card; RESET_GPIO unmute can matter **only then** |

A/B back to attach-to-lite: drop the cmdline flag (default N).

Do **not** combine with `attach_lite_on_dtb_fail=0` for the first reuse
boot (that kills lite before DTB/main work).

## Next on-device experiments (if reuse does not get a card)

These are for the laptop, not another kernel DTS patch:

1. **qebspil console at late EBS.** Did it print `Starting remoteproc:
   qcom,x1e80100-adsp-pas`? Did `TZ_PIL_INIT` / `AUTH_RESET` succeed for
   DTB 0x24 and/or main 0x1? Did it stop lite? If ADSP was skipped,
   rebuild qebspil with `QEBSPIL_ALWAYS_START=1` (Vivobook DT has no
   `qcom,broken-reset`).
2. **ESP vs Linux firmware paths.** qebspil reads
   `/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/` on the ESP. Linux
   reads `/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/`. Confirm
   they are the same `adsp_dtbs.elf` / `qcadsp8380.mbn` (do not commit
   blobs). A QTI-CASS / different-signed DTB on the ESP is the real TZ
   path if one exists.
3. **qebspil timing.** Late EBS stall is 500 ms in qebspil (`FIXME:
   wait for SMP2P`). If INIT 0x24 happened but AUTH_RESET 0x24 did not
   finish before Linux `start()`, reuse still has an initialized DTB
   but not a started one; main AUTH_RESET may then be the clearer
   failure.
4. **Keep default attach-to-lite** as the daily boot. Only use
   `reuse_authenticated_dtb=1` for A/B. If charging dies on the
   AUTH_RESET-after-lite-stop path, that is a recorded failure, not a
   reason to add sound-card DTS.
5. Do **not** add Vivobook sound-card / WSA DTS as the next step. Full
   ADSP first. `CONFIG_RESET_GPIO=y` is already on.

qebspil README also says Linux needs extra patches to **take over** a
firmware qebspil already started (Gerhold `wip/x1e80100-6.16-el2` /
`wip/qcom-laptops-6.17-el2`, plus upstream late-attach
`RPROC_DETACHED`). That is for a running **main** PAS 0x1. Post-qebspil
VERIFY shows 0x1 was not running, so that backport is not the next
step.
