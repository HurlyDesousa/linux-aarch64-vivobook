# qebspil late-EBS efivar log (Omarchy binary)

pkgrel **11** held. **HOLD** `attach_running_main`. No kernel install.
No ConOut photo. No dedicated reboot ask.

Pinned upstream: [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
`8e4d9e676a3b3afe136cda9b953a2139ff1a32d0` +
`0001-main-fail-file-and-efivar-log.patch`.
Built with `QEBSPIL_ALWAYS_START=1`.

## Why the 72634c6 logger missed stages

LIVE collect: efivar `QebspilAdsp` and USB `\qebspil-adsp.log` were
**identical** — only load-time `Firmware … path=` lines for ADSP/CDSP
DTB+MAIN. No `[MAIN] pas=0x1 stage=INIT|AUTH`. PAS still `0x24: 0` /
`0x1: -22`, so late EBS **did** AUTH DTB; `pil_finish` ran.

The old persist used `NON_VOLATILE` `SetVariable` (SPI / FTW) then FAT
`LibOpenRoot` + `Print`. Load-time writes succeeded. At late
ExitBootServices, FAT is already down and Insyde refuses NV var writes.
Stage lines stayed in RAM and died with EBS.

## What this binary does

- Same ALWAYS_START path. Banner line: `qebspil: ebs-efivar-ram build`
- `[MAIN]` / `[DTB]` + `pas=0x1` / `0x24` + `stage=INIT|AUTH|fw_check|…`
  + `status=0x…` from `pil_finish`
- **Primary persist is efivar**, including at late EBS: RAM-backed
  (volatile, no `NON_VOLATILE`) `SetVariable` of `QebspilAdsp`. No FAT
  and no ConOut once `efi_late_ebs` starts
- USB `\qebspil-adsp.log` is load-time only (best-effort). Do not rely
  on it for INIT vs AUTH

## EFI variables (GUID `6b7c0a11-24e1-4a01-9e80-11ad50010024`)

| name | when | contents |
|------|------|----------|
| `QebspilAdsp` | every persist; **EBS primary** | full log (volatile RAM) |
| `QebspilEbs` | every persist | last line only (compact fallback) |
| `QebspilPtr` | load-time NV | `rt=0x… cap=4096 used=…` (runtime buffer phys) |

Readback after Linux is up (4-byte EFI attribute prefix):

```
# primary — expect ebs-efivar-ram + late-EBS enter + [MAIN] stage=
dd if=/sys/firmware/efi/efivars/QebspilAdsp-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo

# last stage only, if the full var is truncated
dd if=/sys/firmware/efi/efivars/QebspilEbs-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo
```

LIVE no-reuse (`0x24: 0`, `0x1: -22`) prefers **MAIN INIT** fail.
Look for:

```
qebspil: qcom,x1e80100-adsp-pas [MAIN] pas=0x1 stage=INIT status=0x…
```

vs `stage=AUTH`. AUTH-fail of MAIN would have dropped DTB.

## Next Omarchy step (the binary)

Copy this file over the live ALWAYS_START `qebspilaa64.efi` on the
**same USB/ESP** that already has dtbloader + MATCH firmware.
Do not rebuild the kernel. Do not enable `attach_running_main`.

```
# USB/ESP that already holds dtbloader + qebspil + /firmware/...
cp qebspil/qebspilaa64.efi /path/to/that/volume/qebspilaa64.efi
```

After that file is on the stick, the next time the machine is up
(no ConOut, no photo): paste **efivar only** (`QebspilAdsp` `dd`
above). Skip `cat /qebspil-adsp.log`.

Rebuild from source (optional; prebuilt already in this dir):

```
./qebspil/build-main-fail-log.sh
```
