# Operator recipe: dtbloader then qebspil (Omarchy / Limine)

pkgrel **11** held. This is **UEFI staging**, not a kernel rebuild.
Do **not** commit Qualcomm/ASUS firmware blobs.

dtbloader → ALWAYS_START is **done** (`Found remoteproc` adsp+cdsp).
That line is prepare only. USB `/firmware/...` next to qebspil
**MATCH**es `/lib/firmware` — missing/wrong-path firmware is
**closed**. No-reuse default boot **landed**: `PAS shutdown dtb
(id=0x24): 0` + `main (id=0x1): -22` + NS `-22` on `adsp_dtbs.elf`
→ attach-to-lite. Late EBS **ran**; Insyde TPL is **not** totally
dead. Main never left up. The 72634c6 file+NV logger **missed `pil_finish` stages** (931 B
efivar == USB log; path lines only, repeated once). #14 volatile
still grew the var at EBS. acca195 **ebs-efivar-fixed** 4 KiB NV
wrote the banner at load; this boot skipped dtbloader (keymap-only
Limine unlock) so `efi_late_ebs` was **never registered** (no
`EfiDtbTableGuid` / remotecount=0) and `late-EBS enter` never
appeared. `PAS shutdown dtb 0x24: -22` on that boot is **invalid
for AUTH comparison**. Next gate is **ebs-always-register**: copy
[qebspil/qebspilaa64.efi](../qebspil/qebspilaa64.efi) over the live
ALWAYS_START efi. After next **full dtbloader→qebspil** boot, paste
**efivar only** (`QebspilAdsp`, `dd … skip=4`). INIT-fail preferred
— no DTB rollback. **HOLD** `attach_running_main`. No ConOut photo.

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
`qebspilaa64.efi`. Omarchy closed this for the live USB: that
volume has `qebspilaa64.efi` + dtbloader +
`/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/{adsp_dtbs.elf,qcadsp8380.mbn}`
and hashes **MATCH** the prior MATCH vs
`/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/`. Do not paste
hashes or blobs into git. Recheck only if the stick is recopied.

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
No-reuse `0x24: 0` means that callback **ran**. The remaining
ask is the patched efi log (`[MAIN] stage=INIT` vs `AUTH`), not
whether `Starting` appeared and not a ConOut photo.

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

No-reuse dump **landed**: `PAS shutdown dtb (id=0x24): 0` and
`main (id=0x1): -22`. Late EBS ran; DTB left up; main never left
up. INIT-fail of main has **no** rollback (matches LIVE). AUTH-fail
of main **stops** DTB (would predict `0x24: -22`). Exact stage is
the patched efi log (`[MAIN] stage=INIT` vs `AUTH`), not a photo.

`efi_late_ebs` (`src/main.c`): SUCCESS returns immediately.
`BS->Stall(500ms)` is only on the error path (inverted vs the
"wait for handover" comment). Upstream quirk — do not change Stall
here. The **log** patch in [qebspil/](../qebspil/) is the
justified qebspil edit (fixed 4 KiB NV; always register late-EBS;
TPL/Stall untouched).

Upstream registers `efi_late_ebs` **only** after
`EfiDtbTableGuid` + remotecount>0. No table → callback never
exists → `pil_finish_all` never runs. The patched efi registers
that callback at load and always writes
`late-EBS enter remotecount=N`.

### Insyde + TPL hack (retired as primary)

`src/event.c` registers `EXIT_BOOT_SERVICES` at `EFI_TPL_CALLBACK`
then pokes EDK2 `IEVENT.NotifyTpl` to `CALLBACK-1`. Comment: may
not work off EDK2. Vivobook is **Insyde 2.9**. A **totally dead**
TPL poke is **retired**: no-reuse `0x24: 0` means `pil_finish`
ran. TPL can still be flaky; it is not the “0x24 up, 0x1 never”
explanation.

## Next: copy the ebs-always-register EFI (efivar only)

ConOut photo is **retired**. Prebuilt
[qebspil/qebspilaa64.efi](../qebspil/qebspilaa64.efi) (`ALWAYS_START=1`
+ ebs-always-register). Copy it over the live `qebspilaa64.efi` on the
same volume as dtbloader + MATCH firmware. After next **full
dtbloader→qebspil** boot, **efivar only** — no USB log, no photo.
Keymap-only unlock without dtbloader is **invalid** for 0x24 AUTH
and will show `EfiDtbTableGuid missing` / `remotecount=0` (still
useful: proves register + enter). Recipe:
[qebspil/README.md](../qebspil/README.md).

```
dd if=/sys/firmware/efi/efivars/QebspilAdsp-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo
```

| log (`[MAIN] pas=0x1 stage=…`) | meaning | vs no-reuse LIVE |
|--------|---------|------------------|
| `stage=INIT` fail | main INIT failed; DTB **not** rolled back | **preferred** |
| `stage=AUTH` fail | main AUTH failed; qebspil **stops DTB** | would predict `0x24: -22` |
| `[DTB]` INIT/AUTH fail | DTB never left up | contradicts `0x24: 0` |
| `AUTH ok (DTB+MAIN)` | claims AUTH of 0x24 **and** 0x1 | then default boot `PAS shutdown main (id=0x1): 0` |

USB `/firmware/...` next to `qebspilaa64.efi` is **already MATCH**.
Do not re-hash. **HOLD** `attach_running_main`. Next collect of
MAIN stages **requires** dtbloader→qebspil.

`ALWAYS_START` / missing `qcom,broken-reset` skip the **whole**
rproc at enumerate — they do **not** start DTB and skip main.
`firmware-name` is main `qcadsp8380.mbn` then DTB `adsp_dtbs.elf`
(qebspil maps DTB to the last string). Both files MATCH. Carveouts
already agree with the ELFs.

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
skipped teardown. CDSP: dtb `0x25` **-22**; main `0x12` **0**.
`systab` still missing `DTB=` after EBS is secondary.

### No-reuse default boot (LANDED — do not repeat as the ask)

Same staging, Limine **default** (no reuse):

```
PAS shutdown dtb (id=0x24): 0
PAS shutdown main (id=0x1): -22
error -22 initializing …/adsp_dtbs.elf
→ attach-to-lite
```

`0x24: 0` = late EBS ran; DTB left up (INIT and/or AUTH). Insyde
TPL is **not** totally dead. `0x1: -22` = main never left up.
NS `-22` on `adsp_dtbs.elf` is **expected** after tearing down
UEFI 0x24. Audio still Dummy. The remaining ask is **copy**
[qebspil/qebspilaa64.efi](../qebspil/qebspilaa64.efi) onto that
volume, then after next **full dtbloader→qebspil** boot read
efivar `QebspilAdsp` (`dd … skip=4`). Not the USB log (FAT is down
at EBS). Not a photo. Not another PAS dump. Not a keymap-only
unlock (that skips dtbloader; `0x24: -22` is invalid for AUTH).

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
- Not a reason to fork Limine or patch qebspil TPL / Stall. The
  ebs-always-register patch in `qebspil/` is the justified
  edit (prebuilt `qebspilaa64.efi` ready to copy).
- Not a TZ signature fix. Found-remoteproc + lite still has no
  audio until UEFI AUTH of full ADSP (main 0x1).
- Not a missing `/firmware` path on this USB (MATCH closed).
- Not “late EBS never fired / Insyde TPL dead” as primary
  (no-reuse `0x24: 0` retired that).
- Not a kernel that keeps UEFI 0x24 and NS-`AUTH_RESET`s main
  only. REUSE_PARTIAL already kept 0x24; NS `PAS_INIT` of
  `qcadsp8380.mbn` was -22. **HOLD** `attach_running_main`.
