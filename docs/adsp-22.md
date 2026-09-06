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

## 7.2.2-10 REUSE_PARTIAL VERIFY (Omarchy, live)

Booted `linux-aarch64-vivobook-adsp-reuse` · uname `7.2.0-10` · pkgs
**7.2.2-10** · cmdline `qcom_q6v5_pas.reuse_authenticated_dtb=1`.

Authoritative dmesg (~00:02 CEST):

```
remoteproc0: Booting fw image .../qcadsp8380.mbn, size 21879224
6800000.remoteproc: reusing UEFI/qebspil DTB PAS (id=0x24); skip teardown + NS .../adsp_dtbs.elf PAS_INIT
6800000.remoteproc: PAS shutdown main (id=0x1): -22
6800000.remoteproc: error -22 initializing firmware .../qcadsp8380.mbn
6800000.remoteproc: full ADSP start failed (err=-22); attaching to UEFI lite ADSP (PAS 0x1f) ...
attach-to-lite fallback, not a TZ signature fix; full audio ADSP still needs a TZ-accepted DTB
remoteproc0: remote processor adsp is now up
```

CDSP on the same boot: dtb `0x25` shutdown **-22**; main `0x12` shutdown
**0** then came up (fastrpc/IPCRTR **-12**). CDSP NS PAS of the QTI-CASS
main MBN works. ADSP does not. remoteproc adsp+cdsp running (lite);
`aplay -l` empty; PipeWire Dummy Output.

qebspil EBS AUTH log: **none on USB** (stick had EFI binaries +
`startup.nsh` only). `Print()` goes to UEFI ConOut (screen / serial),
not a file next to `qebspilaa64.efi`.

### What this proves

| claim | result |
|-------|--------|
| pkgrel 10 reuse path ran | **yes** — skip 0x24 teardown + skip NS `adsp_dtbs.elf` PAS_INIT |
| main 0x1 was already AUTH/INIT in UEFI | **no** — `PAS shutdown main (id=0x1): -22` then and now |
| Linux NS `PAS_INIT` of OEM `qcadsp8380.mbn` | **-22** — same class as NS `adsp_dtbs.elf` |
| attach-to-lite still saved charging | **yes** — lite never killed |
| ALSA card on lite | **no** — lite has no audio |
| limine / pkg miss | **no** — reuse line + 7.2.2-10 uname |
| another board DTS / sound-card carveout | **not the fix** for PAS -22 |

Inference (matches qebspil `pil_finish()`): post-qebspil `0x24`
shutdown=0 means TZ had DTB PAS state (INIT and/or AUTH). Main `0x1`
stayed -22 — **no evidence AUTH (or even INIT) of 0x1**. Kernel reuse
only reuses DTB 0x24.

qebspil (`stephan-gh/qebspil` `src/pil.c`) for
`qcom,x1e80100-adsp-pas` does **DTB then main**: `scm_pil_init` +
`scm_pil_mem_setup` for 0x24, then the same for 0x1. If main INIT fails
(`Failed to init firmware for … (wrong firmware?)`) it **returns
without rolling back DTB**. Rollback `scm_pil_stop` of already-started
full ids happens only on later `scm_pil_start` (AUTH_RESET) failure.
That is exactly "0x24 shutdown-able, 0x1 never up".

Default qebspil also **skips** Vivobook ADSP unless built with
`QEBSPIL_ALWAYS_START=1` (board DT has no `qcom,broken-reset`).
qebspil only enumerates after the bootloader installs `EfiDtbTableGuid`.

### Hypotheses (pkgrel 10) — keep / discard

1. **Main PAS 0x1 also needs UEFI/qebspil AUTH** (same class as DTB).
   Linux NS cannot `PAS_INIT` OEM-signed `qcadsp8380.mbn`. **Kept.**
   Next: get UEFI to AUTH_RESET 0x1, then Linux attach/reuse for main.
2. Wrong Linux auth_reset vs init_image order / metadata / carveout
   after reused DTB. **Discarded as primary.** We never reached main
   AUTH_RESET; NS `PAS_INIT` 0x1 failed first. Do not ship another
   0005 sequence tweak hoping NS accepts the MBN.
3. Blob mismatch ESP `/firmware` vs `/lib/firmware`. **Closed for
   this USB staging** (Omarchy): same volume as `qebspilaa64.efi` +
   dtbloader has `/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/
   {adsp_dtbs.elf,qcadsp8380.mbn}`; hashes **MATCH** the prior
   MATCH vs `/lib/firmware`. Missing/wrong-path firmware is ruled
   out. Recheck only if the stick is recopied.
4. Something else unique in 7.2 `qcom_q6v5_pas` / SCM. **Not primary.**
   CDSP main 0x12 NS path works on the same kernel.

Do **not** invent sound-card / WSA DTS as the PAS -22 fix.
`CONFIG_RESET_GPIO=y` already. Do **not** try another NS `PAS_INIT` of
the OEM MBN.

## Kernel change (pkgrel 11)

New patch `0006-x1e-adsp-attach-running-main.patch` on top of unchanged
`0001` + `0005`:

1. Module param `qcom_q6v5_pas.attach_running_main` (bool, **default
   N**). Daily boot stays attach-to-lite / charging. CDSP unchanged
   (`lite_pas_id` required).
2. When set on ADSP: after proxy PDs/XO/regulators, **before** any
   `PAS_SHUTDOWN`:
   - do **not** tear down 0x24 or 0x1
   - do **not** NS `PAS_INIT` DTB or main
   - do **not** `AUTH_RESET` (UEFI already did that if 0x1 is up)
   - log `attaching to UEFI/qebspil main ADSP (PAS 0x1); skip teardown
     + NS PAS_INIT + AUTH_RESET`
   - `main_attached` + `handover_issued`; `start()` returns 0
3. `stop()` leaves UEFI main running (same idea as lite attach).
4. **Unsafe if 0x1 is not running.** That claims full ADSP while only
   lite is up; GLINK/battmgr may break. Do **not** enable until the
   qebspil EBS log shows AUTH_RESET of main 0x1 succeeded.

`reuse_authenticated_dtb=1` is now a **known dead end for audio**:
it still `PAS_SHUTDOWN` main, then NS `PAS_INIT`s the OEM MBN (-22),
then attach-to-lite. After UEFI has 0x1, **do not** use that flag —
it will destroy the running main. Use `attach_running_main=1` only.

## How to tell if pkgrel 11 attach-main worked

Build `7.2.2-11-aarch64-vivobook`. Daily boot: **no new flags**.

**C — attach-main (only after EBS AUTH of 0x1):**

```
qcom_q6v5_pas.attach_running_main=1
```

Do **not** also set `reuse_authenticated_dtb=1` on that boot.

```
dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to|reusing UEFI|attach_running_main'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/{capacity,status}
aplay -l
```

| outcome | dmesg | audio / batt |
|---------|-------|----------------|
| used too early (0x1 still -22) | `attaching to UEFI/qebspil main ADSP`; **no** `PAS shutdown main`; **no** attach-to-lite | no card; **charging/GLINK may break** — drop the flag |
| UEFI AUTH 0x1 + attach | attach-main line; no `-22 initializing .../qcadsp8380.mbn`; no lite fallback | `aplay -l` *may* grow a card; RESET_GPIO unmute only then |
| default / no flag | same as 7.2.2-3..10 attach-to-lite | no card; charging stays |

## 7.2.2-11 ConOut VERIFY (pkgrel 11 held)

EFI Shell `load qebspilaa64.efi` on the ESP, then Limine UKI (Chief +
Omarchy). ConOut:

```
Hello World!
Found QCOM SCM protocol version 0x50002
Image loaded … Success
```

**No** `Found remoteproc` / `Starting` / AUTH for PAS 0x24 or 0x1.

Post-boot (~00:16 Berlin, post-reuse; SSH later down):

- `/sys/firmware/efi/systab` — only `ACPI20` / `SMBIOS3` / `SMBIOS`.
  **No `DTB=` line.** `EfiDtbTableGuid` was never in the config table.
- `dmesg` efi: `EFI v2.9 by INSYDE Corp.` lists
  SMBIOS / TPM / ACPI / MEMATTR / ESRT / RNG / INITRD / MEMRESERVE —
  **no DTB**.
- `/sys/firmware/fdt` exists (212468 B) via UKI / other. That is
  **not** the EFI DTB config table.
- `limine.conf`: `protocol` `efi`, same UKI
  `omarchy_linux-aarch64-vivobook.efi` for default + `adsp-reuse`
  (cmdline-only A/B). **No** `dtb_path` / `efi_dtb` / `global_dtb`.
- Firmware hashes **MATCH**. PR #7 / pkgrel 11 held.

This is the silent no-rproc path: qebspil printed Hello World + SCM
and then `efi_dtb_changed()` saw `LibGetSystemConfigurationTable`
`EFI_NOT_FOUND` and returned success without enumerating.

### Root cause (checked in qebspil + dtbloader + Limine docs)

`stephan-gh/qebspil` `efi_main()` registers a group callback on
`EfiDtbTableGuid` and immediately calls `efi_dtb_changed()`. That
function only calls `dtb_enumerate_rprocs()` when
`LibGetSystemConfigurationTable(&EfiDtbTableGuid, &dtb)` succeeds.
`Found remoteproc` lives in `src/dtb.c`; `Starting remoteproc` /
INIT / AUTH live in `src/pil.c` and run at late ExitBootServices.
README: qebspil is active when a bootloader installs a device tree
(systemd-boot / GRUB / dtbloader).

**Limine does not `InstallConfigurationTable(EfiDtbTableGuid)`.**
It may consume a DTB via `dtb_path` / `global_dtb` / firmware table
for the *kernel* on `linux` / `limine` protocols. Omarchy uses
`protocol: efi` (UKI chainload). That never publishes the GUID for
other EFI drivers. Loading qebspil from EFI Shell before Limine, or
with Limine alone, is exactly Hello World + SCM and silent no-rproc.

A kernel NS `PAS_INIT` tweak does **not** create that table. Do
**not** fork Limine in this repo; a future **upstream** Limine
`InstallConfigurationTable` is optional, not the path here.

### Fix path: dtbloader, then qebspil, then Limine

TravMurav [dtbloader](https://github.com/TravMurav/dtbloader) is an
EFI driver that `InstallConfigurationTable`s DeviceTree
(`EfiDtbTableGuid`). ASUS Vivobook S 15 is on its supported list
(`src/devices/asus_vivobook_s15.c` →
`qcom\x1e80100-asus-vivobook-s15.dtb` for S5507QA X Elite).

Order:

1. `load dtbloader.efi` (or `bcfg driver`)
2. `load qebspilaa64.efi` built with `QEBSPIL_ALWAYS_START=1`
   (Vivobook DT has no `qcom,broken-reset`)
3. Boot Limine as today

See [qebspil-dtbloader.md](qebspil-dtbloader.md) for the operator
recipe (build, ESP/USB layout, `startup.nsh`, expected ConOut).

**Do not** enable `attach_running_main` while 0x1 still never AUTH'd.
Keep using `adsp-reuse` (`reuse_authenticated_dtb=1`) only as the
known REUSE_PARTIAL A/B; that path still cannot NS `PAS_INIT` the
OEM main MBN.

## 7.2.2-11 dtbloader → ALWAYS_START VERIFY (Found-remoteproc only)

After dtbloader → `QEBSPIL_ALWAYS_START=1` qebspil → Limine, on the
`adsp-reuse` entry (`reuse_authenticated_dtb=1`). pkgrel **11** held.
No install ask. `attach_running_main` still **off**.

ConOut at `load` (dtbloader path **works**):

```
qebspil: Found remoteproc: qcom,x1e80100-adsp-pas
qebspil: Found remoteproc: qcom,x1e80100-cdsp-pas
```

Linux after that same boot (Omarchy confirmed, reuse=1). Late-EBS
ConOut was **not** captured — only the load-time Found remoteproc
lines above.

```
reusing UEFI/qebspil DTB PAS (id=0x24); skip teardown + NS … adsp_dtbs.elf PAS_INIT
PAS shutdown main (id=0x1): -22
error initializing firmware …/qcadsp8380.mbn
attaching to UEFI lite ADSP
```

This boot did **not** print `PAS shutdown dtb (id=0x24): 0` because
reuse **skipped** that teardown. Do not read a missing 0x24 shutdown
line as “DTB was AUTH’d.”

CDSP on the same boot: dtb `0x25` shutdown **-22**; main `0x12`
shutdown **0** (NS CDSP still comes up). Dummy / no cards.

`/sys/firmware/efi/systab` still **no `DTB=`** (post-EBS; secondary).

**`Found remoteproc` is not AUTH.** In `stephan-gh/qebspil` that
`Print` lives in `src/dtb.c` `dtb_enumerate_rprocs()`: find the
node, `fw_prepare` the ELF from the same FAT as `qebspilaa64.efi`,
`pil_prepare` (proxy vote). It does **not** call `TZ_PIL_INIT` or
`TZ_PIL_AUTH_RESET`.

Actual start is `pil_finish()` on **late ExitBootServices**:
`efi_late_ebs` → `pil_finish_all` → `Starting remoteproc`. For each
component (DTB suffix ` DTB`, then main with an empty suffix):

1. `fw_check` / `fw_load_metadata`
2. `scm_pil_init` — on fail: `Failed to init firmware for … (wrong
   firmware?)` and **return with no rollback of prior inits**
3. `scm_pil_mem_setup`, `fw_load`
4. stop lite (ignore errors)
5. `scm_pil_start` (`AUTH_RESET`) — on fail: `Failed to authenticate
   and start firmware for …` and rollback prior **full** components

### Why this reuse=1 boot does **not** prove DTB AUTH

`reuse_authenticated_dtb=1` **skips** `PAS_SHUTDOWN` of 0x24. So
that boot’s dmesg cannot tell INIT/AUTH of 0x24 from "never
touched". The `PAS shutdown main (id=0x1): -22` line only says
main was never shutdown-able.

The **default** (no-reuse) dump **landed** (next section):
`0x24: 0`, `0x1: -22`. That is the proof late EBS INITed/AUTH’d
DTB on this staging. Older 7.2.2-9 `0x24: 0` was a different
boot (no dtbloader / no Found-remoteproc). Exact main fail line
(INIT vs AUTH) still needs the Limine→UKI ConOut photo.

`efi_late_ebs` (`src/main.c`): on SUCCESS returns immediately.
`BS->Stall(500ms)` is only on the error path (inverted vs the
"wait for handover" comment). Upstream quirk — do **not** patch
qebspil in this repo unless asked.

Linux `systab` missing `DTB=` after EBS is **secondary**. Limine
`protocol: efi` / UKI may drop `EfiDtbTableGuid` once boot services
end. The no-reuse `0x24: 0` line is what says late EBS ran.

### Insyde + qebspil TPL hack (retired as primary)

`event_register_late_ebs_callback` (`src/event.c`) creates an
`EXIT_BOOT_SERVICES` event at `EFI_TPL_CALLBACK`, then **pokes**
the EDK2 `IEVENT.NotifyTpl` to `CALLBACK-1` so it runs last. The
comment says this may not work on other EFI implementations. This
board is **`EFI v2.9 by INSYDE Corp.`**, not EDK2.

A **totally dead** TPL poke is **retired**: no-reuse `PAS shutdown
dtb (id=0x24): 0` means `efi_late_ebs` → `pil_finish` ran. TPL can
still be flaky; it is not the explanation for “0x24 up, 0x1 never”.

### Firmware path CLOSED (this USB staging)

Omarchy confirmed the **same USB volume** holds:

```
/qebspilaa64.efi
/dtbloader.efi          # or dtbloaderaa64.efi
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn
```

Hashes **MATCH** the prior MATCH vs `/lib/firmware/...`. Missing or
wrong-path firmware is **ruled out** for this stick. `fw_prepare`
prefixes `firmware\` onto the DT `firmware-name`. Found-remoteproc
without `Failed to enumerate` / `Failed to prepare` already meant
those files opened at `load` time. A later ConOut `wrong firmware?`
is TZ/INIT, not a missing path. Do not re-hash unless the stick is
recopied. Do not paste hashes or blobs into git.

**Firmware-path / ALWAYS_START / carveouts (checked, not the gate):**

- Vivobook `&remoteproc_adsp` `firmware-name` is **main then DTB**:
  `qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn` then
  `…/adsp_dtbs.elf`. qebspil `dtb.c` maps DTB component to the
  **last** string and main to the **first**. USB `/firmware/...`
  MATCH already closed both files.
- `QEBSPIL_ALWAYS_START` / `qcom,broken-reset` skip the **whole**
  rproc at enumerate. They do **not** start DTB and skip main.
  `Found remoteproc` adsp already means both components were
  `fw_prepare`d.
- DTB/main carveouts still match the ELFs (see table at top). No
  known x1e80100 quirk where ALWAYS_START leaves main unprepared.

## 7.2.2-11 no-reuse VERIFY (late EBS ran; main never up)

After dtbloader → ALWAYS_START qebspil → Limine **default**
(no `reuse_authenticated_dtb`, no `attach_running_main`). pkgrel
**11** held. Audio still Dummy. USB firmware MATCH already CLOSED.

```
PAS shutdown dtb (id=0x24): 0
PAS shutdown main (id=0x1): -22
error -22 initializing …/adsp_dtbs.elf
→ attach-to-lite
```

| line | meaning |
|------|---------|
| `0x24: 0` | late EBS **did** run. TZ had DTB PAS state (INIT and/or AUTH). Insyde TPL is **not** totally dead. |
| `0x1: -22` | main **never** left up by UEFI (never INIT/AUTH, or was rolled back). |
| NS `-22` on `adsp_dtbs.elf` | **expected** on this path: default `start()` tears down UEFI 0x24 then Linux NS `PAS_INIT`s the OEM DTB. Same class as pre-qebspil. Not a new TZ bug. |

This is the A/B that reuse=1 could not give (reuse skips 0x24
teardown). Older 7.2.2-9 `0x24: 0` was a different staging; **this**
dump is the dtbloader + ALWAYS_START default boot.

### Why “late EBS never fired” is retired as primary

A totally-dead Insyde TPL poke would leave **both** 0x24 and 0x1
at shutdown **-22**. `0x24: 0` after this staging means
`efi_late_ebs` → `pil_finish` **ran** and at least INITed DTB.
`Unexpected IEvent` / missing `Starting` is no longer the lead.
TPL can still be flaky; it is not the explanation for “0x24 up,
0x1 never”.

### Preferred hypothesis (qebspil `pil_finish`, matches LIVE)

`stephan-gh/qebspil` `src/pil.c` — DTB (` DTB` suffix) then main
(empty suffix):

1. `fw_check` / `fw_load_metadata` (all components)
2. `scm_pil_init` + `mem_setup` — on INIT fail: `Failed to init
   firmware for … (wrong firmware?)` and **return with no rollback
   of prior inits** → DTB stays up
3. `fw_load`, stop lite (ignore errors)
4. `scm_pil_start` (`AUTH_RESET`) — on AUTH fail: `Failed to
   authenticate and start firmware for …` and **rollback prior
   full components** → would **drop** DTB (`scm_pil_stop` 0x24)

LIVE `0x24: 0` + `0x1: -22` matches **main failed at INIT** (or
never reached AUTH). An AUTH fail of main would roll back DTB and
Linux would then see `0x24: -22`. So lock the next gate as **main
INIT vs AUTH**, with INIT-fail preferred.

Do **not** ship a kernel that keeps UEFI 0x24 and NS-`AUTH_RESET`s
main only. REUSE_PARTIAL already kept 0x24 and NS `PAS_INIT` of
`qcadsp8380.mbn` was **-22**; 0x1 was never up, so
`attach_running_main` stays **HOLD**. pkgrel stays 11.

## Next on-device experiment (Omarchy / Toby) — one primary

dtbloader + ALWAYS_START + Found-remoteproc + **no-reuse PAS dump**
are **done**. USB `/firmware` MATCH is **closed**. pkgrel 11 held.
No rebuild ask. **HOLD** `attach_running_main`. Operator recipe:
[qebspil-dtbloader.md](qebspil-dtbloader.md).

### Primary: one ConOut photo of the **main** Failed line

`Print()` is ConOut only. Same dtbloader → ALWAYS_START → Limine
**default** (no reuse). Photograph Limine pick → UKI until the
qebspil Failed line for **ADSP main** (empty suffix, no ` DTB`).
`Starting remoteproc` is now **expected** (0x24:0). The ask is
which Failed line, not whether late EBS ran.

| ConOut (after `Starting remoteproc: qcom,x1e80100-adsp-pas`) | meaning | vs LIVE |
|--------|---------|---------|
| `Failed to init firmware for qcom,x1e80100-adsp-pas:` (empty suffix) `(wrong firmware?)` | main `scm_pil_init` failed; DTB **not** rolled back | **preferred** — matches `0x24: 0` + `0x1: -22` |
| `Failed to authenticate and start firmware for qcom,x1e80100-adsp-pas:` (no ` DTB`) | main AUTH failed; qebspil **stops DTB** | would predict `0x24: -22`; **not** the lead vs this dump |
| `Failed to init firmware for … DTB` / `Failed to authenticate … DTB` | DTB never left up | contradicts `0x24: 0` |
| `Starting` and **no** Failed-* for ADSP | claims AUTH of DTB **and** main | then confirm next default boot `PAS shutdown main (id=0x1): 0` — still no attach-main on that first boot |
| `Firmware check failed` / `Failed to load firmware metadata` / `Failed to setup memory area` / `Failed to load firmware` + empty suffix | never reached INIT/AUTH of main | say which line |

Do **not** re-hash the stick. Do **not** rebuild qebspil for louder
logs unless this photo is unreadable. Do **not** enable
`attach_running_main`. Do **not** bump pkgrel.

### After EBS shows AUTH_RESET of 0x1

Still **HOLD** `attach_running_main`. First confirm the next
**default** (no extra flags) boot shows `PAS shutdown main (id=0x1): 0`.
If it is still -22, UEFI did not leave main running.

Only then A/B:

```
qcom_q6v5_pas.attach_running_main=1
```

**Do not** set `reuse_authenticated_dtb=1` on that boot (destroys
0x1). **Do not** set `attach_lite_on_dtb_fail=0`.
Expect `attaching to UEFI/qebspil main ADSP` and **no**
`PAS shutdown main`. Then `aplay -l`. If still empty, that is a
later audio/GLINK problem, not another PAS_INIT of the OEM MBN.

### What not to do

- Daily boot stays **no flags** (attach-to-lite, charging) unless
  you are on the known `adsp-reuse` A/B. That A/B still cannot
  NS `PAS_INIT` the OEM main MBN.
- Do **not** enable `attach_running_main=1` yet (0x1 shutdown is
  still -22; 0x1 has never AUTH'd on this board).
- Do **not** treat “late EBS never fired / Insyde TPL dead” as
  primary. `0x24: 0` on the no-reuse dump retired that.
- Do **not** treat Found-remoteproc, attach-to-lite, or
  REUSE_PARTIAL as a TZ signature fix or as AUTH of 0x1.
- Do **not** add Vivobook sound-card / WSA DTS as the next PAS -22
  step. `CONFIG_RESET_GPIO=y` is already on.
- Do **not** claim another NS `PAS_INIT` kernel tweak publishes
  `EfiDtbTableGuid` or AUTHs 0x1. Do **not** bump pkgrel.
- Do **not** fork Limine or patch qebspil (TPL / Stall) in this
  repo unless asked.
- A full remoteproc-core `RPROC_DETACHED` / Gerhold
  `wip/x1e80100-6.16-el2` backport is the upstream-shaped late-attach;
  pkgrel 11 is the 7.2-sized landing pad for the same moment (main
  already running). Not needed until EBS AUTH of 0x1 exists.
