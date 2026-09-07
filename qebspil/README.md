# qebspil late-EBS efivar log (Omarchy binary)

pkgrel **11** held. **HOLD** `attach_running_main`. No kernel install.
No ConOut photo. No dedicated reboot ask.

Pinned upstream: [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
`8e4d9e676a3b3afe136cda9b953a2139ff1a32d0` +
`0001-main-fail-file-and-efivar-log.patch`.
Built with `QEBSPIL_ALWAYS_START=1`.

**Parked — stage only when Chief unparks.** Do not swap USB tonight.

## acca195 LIVE (verbatim)

```
qebspil: ebs-efivar-fixed build
qebspil: Firmware 1 [DTB] …/adsp_dtbs.elf
qebspil: Firmware 0 [MAIN] …/qcadsp8380.mbn
qebspil: Firmware 1 [DTB] …/cdsp_dtbs.elf
qebspil: Firmware 0 [MAIN] …/qccdsp8380.mbn
(+ same 4 lines once more)
```

No `late-EBS enter`. No `stage=INIT|AUTH`. Linux this boot:
`0x24: -22` and `0x1: -22`.

**Contradiction:** Firmware/prepare lines mean remotes **were**
found and prepared this load. That is **not** a zero-remote path
and is **not** explained by “skipped dtbloader → no remotes”.
`efi_dtb_changed` ran twice (same as 72634c6). Load-time 4 KiB NV
write worked.

`0x24: -22` means DTB was **not** left AUTH’d. Prepare ≠ AUTH.

Prefer: late-EBS callback **never registered**, **never fired**,
or **SetVariable at EBS failed** despite the fixed 4 KiB slot.

## What this binary does

- Banner: `qebspil: ebs-register-status build`
- Same GUID, same **fixed 4 KiB NV** `QebspilAdsp`. Never FAT /
  Print at EBS
- **Always** registers `efi_late_ebs` at load
- Load-time: banner, `persist SetVariable status=`, `late-EBS
  registered status=`, `EfiDtbTableGuid found|missing`,
  `remotecount=N`, then `late-EBS armed remotecount=N
  registered=0x…` **after** prepare
- Late-EBS: `late-EBS enter remotecount=N` even if N=0, then
  `late-EBS persist SetVariable status=0x…`, then INIT/AUTH when
  N>0

## EFI variables (GUID `6b7c0a11-24e1-4a01-9e80-11ad50010024`)

| name | size | contents |
|------|------|----------|
| `QebspilAdsp` | 4096 B NV | full log, NUL-padded (EBS **primary**) |
| `QebspilEbs` | 256 B NV | last stage line, NUL-padded |

```
dd if=/sys/firmware/efi/efivars/QebspilAdsp-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo
```

| line | meaning |
|------|---------|
| `ebs-register-status build` | this binary |
| `late-EBS registered status=0x0` | `CreateEvent(EBS)` succeeded |
| `late-EBS armed remotecount=2 registered=0x0` | remotes + callback coexist at load (acca195-shaped) |
| `late-EBS enter remotecount=N` | callback **ran** |
| `late-EBS persist SetVariable status=0x0` | EBS in-place NV write worked |
| armed + registered 0x0, **no** enter | never fired, **or** EBS SetVariable failed |
| `[MAIN] pas=0x1 stage=INIT\|AUTH` | AUTH path (N>0 only) |

Rebuild (optional): `./qebspil/build-main-fail-log.sh`
