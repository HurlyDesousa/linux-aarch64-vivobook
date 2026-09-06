# Operator recipe: dtbloader then qebspil (Omarchy / Limine)

pkgrel **11** held. This is **UEFI staging**, not a kernel rebuild.
Do **not** commit Qualcomm/ASUS firmware blobs.

dtbloader → ALWAYS_START is **done** (`Found remoteproc` adsp+cdsp).
That line is prepare only. The remaining gate is late-EBS AUTH
(`Starting remoteproc` at Limine→UKI). **HOLD** `attach_running_main`.

## Why this recipe exists

`stephan-gh/qebspil` (`src/main.c`) registers for `EfiDtbTableGuid` and
calls `efi_dtb_changed()` → `LibGetSystemConfigurationTable`. It only
enumerates remoteprocs when that EFI **configuration table** is present.
README: qebspil is active when a bootloader installs a device tree
(systemd-boot / GRUB / [dtbloader](https://github.com/TravMurav/dtbloader)).

**Limine does not `InstallConfigurationTable(EfiDtbTableGuid)`.**
Omarchy `limine.conf` uses `protocol` `efi` and chainloads the same UKI
`omarchy_linux-aarch64-vivobook.efi` for default + `adsp-reuse`
(cmdline-only A/B). There is no `dtb_path` / `efi_dtb` / `global_dtb`.
Limine `protocol: efi` is EFI chainload — those DTB keys apply to
`linux` / `limine` protocols anyway, and even then they feed the
*kernel*, not other EFI drivers.

`/sys/firmware/fdt` can still exist (UKI / other). That is **not** the
EFI DTB config table. qebspil never sees it.

TravMurav **dtbloader** is the driver that *does* install DeviceTree
into the UEFI configuration table. ASUS Vivobook S 15 is on its
supported list (`src/devices/asus_vivobook_s15.c`).

A Limine fork that publishes the GUID is a **future upstream option
only**. Do not invent one in this repo.

## Load order (required)

1. `dtbloader.efi` — `InstallConfigurationTable(EfiDtbTableGuid)`
2. `qebspilaa64.efi` — now sees the table, enumerates remoteprocs
3. Limine — boot the UKI as today (`protocol: efi`)

Also build qebspil with **`QEBSPIL_ALWAYS_START=1`**. Vivobook
`&remoteproc_adsp` has no `qcom,broken-reset`; stock qebspil skips ADSP
even after the DTB table is present.

## Build (no blobs in git)

On an aarch64 host or with a cross toolchain. Do not vendor the
binaries in this kernel repo.

**dtbloader** ([TravMurav/dtbloader](https://github.com/TravMurav/dtbloader);
needs `clang` + `lld`):

```
git clone --recursive https://github.com/TravMurav/dtbloader.git
cd dtbloader
make -j$(nproc)
# output: build-aarch64/dtbloader.efi
```

For systemd-boot driver dirs the conventional name is
`dtbloaderaa64.efi`. EFI Shell `load` accepts `dtbloader.efi`.

**qebspil** ([stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)):

```
git clone --recursive https://github.com/stephan-gh/qebspil.git
cd qebspil
make CROSS_COMPILE=aarch64-linux-gnu- QEBSPIL_ALWAYS_START=1
# native: omit CROSS_COMPILE=
# output: out/qebspilaa64.efi
```

## Stage on ESP or USB

Same volume as the EFI binaries (USB for first ConOut test, or the ESP
that Limine already uses).

```
/dtbloader.efi          # or dtbloaderaa64.efi
/qebspilaa64.efi
/startup.nsh            # optional; see below
/dtbloader/dtbs/qcom/x1e80100-asus-vivobook-s15.dtb
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn
```

dtbloader searches `\dtbloader\dtbs\`, `\dtbs\`, then `\` on **its**
volume. S5507QA X Elite entry wants
`qcom\x1e80100-asus-vivobook-s15.dtb`. Copy the board DTB from
`/boot/dtbs/...` (this package) — not a firmware blob.

qebspil reads `/firmware/...` from the **same volume** as
`qebspilaa64.efi`. Those two files must match
`/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/` (already verified
MATCH on pkgrel 11). Do not paste hashes or blobs into git.

`bcfg driver add` (dtbloader first, then qebspil) is the persistent
form. EFI Shell `load` is the ConOut test.

## `startup.nsh` sketch

```
# fsXY: = the USB/ESP volume that holds these files
fsXY:
load dtbloader.efi
load qebspilaa64.efi
# then exit the shell / pick Limine / boot the UKI
```

Order is the whole point. `load qebspilaa64.efi` **before** dtbloader
is the Hello World / SCM-only ConOut (pkgrel 11 VERIFY).

dtbloader ConOut should include `Detected device: … Vivobook S 15 …`.
If it prints `Failed to detect this device!` or `Cant open the file`,
the DTB path/name on that volume is wrong.

## Expected ConOut after both loads

**Broken (qebspil only — older pkgrel 11 VERIFY):**

```
Hello World!
Found QCOM SCM protocol version 0x50002
Image loaded … Success
```

No `Found remoteproc` / `Starting` / AUTH for PAS 0x24 or 0x1.

**Load-time OK (dtbloader then ALWAYS_START — live):**

```
Detected device: ASUSTeK COMPUTER INC. ASUS Vivobook S 15 …
Hello World!
Found QCOM SCM protocol version 0x50002
qebspil: Found remoteproc: qcom,x1e80100-adsp-pas
qebspil: Found remoteproc: qcom,x1e80100-cdsp-pas
```

**`Found remoteproc` ≠ AUTH.** That `Print` is `dtb_enumerate_rprocs`
(`src/dtb.c`): match `qcom,x1e80100-*-pas`, `fw_prepare` the ELF,
`pil_prepare`. It does **not** INIT or AUTH. You can see Found
adsp+cdsp and still land on lite / Dummy Output.

`Starting remoteproc` and INIT / AUTH print only at **late
ExitBootServices** (`efi_late_ebs` → `pil_finish_all` →
`pil_finish`). That is the Limine → UKI handoff, not `load` time.
That screen is the current gap.

## Late EBS is the AUTH gate (`pil_finish`)

`stephan-gh/qebspil` `src/pil.c`. For each prepared rproc, DTB
first (ConOut suffix ` DTB`) then main (empty suffix):

1. `fw_check` / `fw_load_metadata`
2. `scm_pil_init` — on fail: `Failed to init firmware for … (wrong
   firmware?)` and **return with no rollback of prior inits**
3. `mem_setup`, `fw_load`
4. stop lite (ignore errors)
5. `scm_pil_start` (`AUTH_RESET`) — on fail:
   `Failed to authenticate and start firmware for …` and rollback
   prior full components

Hypothesis that matches a later no-reuse `PAS shutdown dtb 0x24 = 0`
plus live `main 0x1 = -22`: late EBS at least INITed DTB 0x24; main
INIT or AUTH failed (or never reached); DTB left up. The reuse=1
boot does **not** prove that (it never shuts 0x24 down). Exact fail
line = Toby ConOut photo.

`efi_late_ebs` (`src/main.c`): SUCCESS returns immediately.
`BS->Stall(500ms)` is only on the error path (inverted vs the
"wait for handover" comment). Documented upstream quirk — do not
patch qebspil here unless asked.

### Insyde + TPL hack

`src/event.c` registers `EXIT_BOOT_SERVICES` at `EFI_TPL_CALLBACK`
then pokes EDK2 `IEVENT.NotifyTpl` to `CALLBACK-1`. Comment: may
not work off EDK2. Vivobook is **Insyde 2.9**. Mismatch prints
`Unexpected IEvent structure (not edk2)?` and late EBS may never
run. **No `Starting` after Found adsp+cdsp** → treat this as
suspect before blaming firmware or Linux.

## Photograph this (Toby / Omarchy — preferred)

One photo (or burst) through Limine pick → UKI. Read these lines:

| ConOut | meaning |
|--------|---------|
| no `Starting remoteproc` after Found adsp+cdsp | late EBS never ran (TPL/Insyde) or the handoff scrolled off |
| `Unexpected IEvent structure (not edk2)?` | TPL poke unsafe on Insyde |
| `Starting remoteproc: qcom,x1e80100-adsp-pas` | late EBS **did** enter `pil_finish` for ADSP |
| `Failed to init firmware for … DTB` `(wrong firmware?)` | DTB INIT failed |
| `Failed to init firmware for qcom,x1e80100-adsp-pas:` (no ` DTB`) | main INIT failed; DTB INIT already done; DTB left up |
| `Failed to authenticate and start firmware for …` | `AUTH_RESET` failed (DTB vs main by suffix) |
| `Starting` and no Failed-* for ADSP | claims AUTH of 0x24 **and** 0x1 |

Also confirm the **same volume** as `qebspilaa64.efi` has:

```
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/adsp_dtbs.elf
/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/qcadsp8380.mbn
```

## After Linux is up (no install ask)

```
# GUID present? Linux prints DTB= when EfiDtbTableGuid was in systab
cat /sys/firmware/efi/systab
dmesg | grep -i efi
# /sys/firmware/fdt alone is not enough (UKI can populate it)

dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to|reusing UEFI|attach_running_main'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/{capacity,status}
aplay -l
```

Daily Limine entry: **no extra flags** (attach-to-lite / charging).

**reuse=1 does not prove DTB AUTH.** That path skips `PAS_SHUTDOWN`
of 0x24. Omarchy this-boot dmesg (late-EBS ConOut **not** captured):

```
reusing UEFI/qebspil DTB PAS (id=0x24); skip teardown + NS … adsp_dtbs.elf PAS_INIT
PAS shutdown main (id=0x1): -22
error initializing firmware …/qcadsp8380.mbn
attaching to UEFI lite ADSP
```

This boot did **not** print `PAS shutdown dtb (id=0x24): 0` — reuse
skipped teardown. CDSP: dtb `0x25` **-22**; main `0x12` **0**. Use
ConOut (§ above) to know if late EBS ran. `systab` still missing
`DTB=` after EBS is secondary (UKI / post-EBS), not the AUTH gate.

### Omarchy A/B if the photo is impossible

Same dtbloader → ALWAYS_START qebspil → Limine, **one** boot
**without** `reuse_authenticated_dtb=1`:

| dmesg | meaning |
|-------|---------|
| `PAS shutdown dtb (id=0x24): 0` | TZ had DTB state (INIT and/or AUTH) |
| `PAS shutdown dtb (id=0x24): -22` | 0x24 never up — late EBS did not INIT DTB |
| `PAS shutdown main (id=0x1): 0` | main was up |
| `PAS shutdown main (id=0x1): -22` | main never up |

If EBS AUTH of **main PAS 0x1** succeeded, first confirm the next
**default** boot shows `PAS shutdown main (id=0x1): 0`. Only then A/B
the existing `adsp-reuse` (or a new) entry with:

```
qcom_q6v5_pas.attach_running_main=1
```

**HOLD `attach_running_main` until that 0x1 shutdown is 0.**
**Do not** set `reuse_authenticated_dtb=1` on an attach-main boot
(pkgrel 10 REUSE_PARTIAL still `PAS_SHUTDOWN`s main, then NS
`PAS_INIT` of OEM `qcadsp8380.mbn` is -22).

## What this is not

- Not another NS `PAS_INIT` kernel tweak. That does not publish the
  DTB table and does not AUTH 0x1. pkgrel stays 11.
- Not a reason to fork Limine or patch qebspil (TPL / Stall) here.
- Not a TZ signature fix. Found-remoteproc + lite still has no
  audio until UEFI AUTH of full ADSP (main 0x1).
