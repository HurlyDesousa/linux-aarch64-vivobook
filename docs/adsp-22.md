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
3. Blob mismatch ESP `/firmware` vs `/lib/firmware`. **Still open on
   the laptop** (no EBS log). Must hash-check; do not assume.
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

## Next on-device experiments (Omarchy / Toby)

Blocked on **firmware/UEFI**, not another 7.2 PAS sequence patch.
Capture these on the laptop. Do not commit blobs.

### 1. Get a real qebspil EBS log (ConOut, not USB)

`Print()` in `stephan-gh/qebspil` (`Hello World!`, `Found remoteproc`,
`Starting remoteproc`, `Failed to init firmware … (wrong firmware?)`,
`Failed to authenticate and start firmware`) goes to the UEFI console.
A USB stick with only `qebspilaa64.efi` + `startup.nsh` is **not** a
log. Photograph the panel around ExitBootServices, or use a serial
console if one exists.

Must answer:

- Did it print `qebspil: Found remoteproc: qcom,x1e80100-adsp-pas`?
  If not: the bootloader did not install `EfiDtbTableGuid` (qebspil
  README: systemd-boot / GRUB / dtbloader / UKI-with-DTB). Limine
  must install the Linux DTB as that UEFI config table or qebspil
  never starts ADSP.
- Did it print `qebspil: Starting remoteproc: qcom,x1e80100-adsp-pas`?
- `Failed to init firmware for … DTB` vs `…` (main, empty suffix)?
- `Failed to authenticate and start firmware` for DTB and/or main?
- Did it stop lite before AUTH_RESET?

### 2. Rebuild qebspil with ALWAYS_START

```
make CROSS_COMPILE=aarch64-linux-gnu- QEBSPIL_ALWAYS_START=1
```

Vivobook `&remoteproc_adsp` has **no** `qcom,broken-reset`. Stock
qebspil skips ADSP. Copy new `out/qebspilaa64.efi` next to the ESP
firmware. Do not add `qcom,broken-reset` to the board DTS as a
workaround unless that is a deliberate Linux-side policy change.

### 3. ESP vs `/lib/firmware` identity (do not commit hashes in a blob)

qebspil reads from the **same volume as `qebspilaa64.efi`**:

```
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn
```

Linux reads `/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/`.
If ESP is missing `qcadsp8380.mbn` or it is a different file, qebspil
INITs DTB then fails main INIT and **leaves 0x24 up** — the
REUSE_PARTIAL signature.

On the laptop (example; do not paste firmware into git):

```
# ESP mount may be /boot or /efi — use the volume that holds qebspilaa64.efi
sha256sum \
  /lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf \
  /lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn \
  /boot/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf \
  /boot/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn
ls -l /sys/class/remoteproc/remoteproc0/device  # confirm firmware-name
```

Both names must exist on the qebspil volume and match Linux (or be a
known QTI-CASS substitute). `qcadsp8380.mbn` size on the reuse boot
was **21879224** from Linux `request_firmware`.

### 4. After EBS shows AUTH_RESET of 0x1

1. Confirm on the **next** Linux boot **without** extra flags that
   `PAS shutdown main (id=0x1): 0` (was up). If it is still -22,
   UEFI did not leave main running; do not enable attach-main.
2. Then A/B:

   ```
   qcom_q6v5_pas.attach_running_main=1
   ```

3. **Do not** set `reuse_authenticated_dtb=1` on that boot (destroys
   0x1). **Do not** set `attach_lite_on_dtb_fail=0`.
4. Expect `attaching to UEFI/qebspil main ADSP` and **no**
   `PAS shutdown main`. Then `aplay -l`. If still empty, that is a
   later audio/GLINK problem, not another PAS_INIT of the OEM MBN.

### 5. What not to do

- Daily boot stays **no flags** (attach-to-lite, charging).
- Do **not** use `attach_running_main=1` while 0x1 shutdown is -22.
- Do **not** add Vivobook sound-card / WSA DTS as the next PAS -22
  step. `CONFIG_RESET_GPIO=y` is already on.
- Do **not** treat attach-to-lite or REUSE_PARTIAL as a TZ signature
  fix.
- A full remoteproc-core `RPROC_DETACHED` / Gerhold
  `wip/x1e80100-6.16-el2` backport is the upstream-shaped late-attach;
  pkgrel 11 is the 7.2-sized landing pad for the same moment (main
  already running). Not needed until EBS AUTH of 0x1 exists.
