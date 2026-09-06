# qebspil late-EBS efivar log (Omarchy binary)

pkgrel **11** held. **HOLD** `attach_running_main`. No kernel install.
No ConOut photo. No dedicated reboot ask.

Pinned upstream: [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
`8e4d9e676a3b3afe136cda9b953a2139ff1a32d0` +
`0001-main-fail-file-and-efivar-log.patch`.
Built with `QEBSPIL_ALWAYS_START=1`.

## Why 72634c6 (and #14 volatile) missed stages

Omarchy collect: efivar `QebspilAdsp` **==** USB `\qebspil-adsp.log`
(**931 B**). Banner `main-fail-log build (file+efivar)`. Only load-time
`Firmware` path lines for ADSP/CDSP DTB+MAIN, **repeated once**
(`efi_dtb_changed` twice). Paths/carveouts sane. No `stage=INIT|AUTH`.
PAS still `0x24: 0` / `0x1: -22` — late EBS **did** AUTH DTB;
`pil_finish` ran.

72634c6 persist **grew** the NV var (931 B → stages). That realloc
needs SPI/FTW, already down at EBS, then FAT + Print. #14 deleted NV
and recreated a **volatile loglen-sized** var — after EBS volatile is
read-only / may vanish, and a growing write still needs a new slot.

## What this binary does

- Banner: `qebspil: ebs-efivar-fixed build` (not `main-fail-log`, not
  `ebs-efivar-ram`)
- `[MAIN]` / `[DTB]` + `pas=0x1` / `0x24` + `stage=INIT|AUTH|fw_check|…`
  + `status=0x…` from `pil_finish`
- **Keep `QebspilAdsp` NV|BS|RT** (same var Linux already showed)
- At load, create a **fixed 4 KiB** slot. Every persist — including
  late EBS — is an **in-place same-size** `SetVariable`. No FTW
  realloc, no FAT, no ConOut at EBS
- `QebspilEbs` is a fixed 256 B last-line slot (same idea)

## EFI variables (GUID `6b7c0a11-24e1-4a01-9e80-11ad50010024`)

| name | size | contents |
|------|------|----------|
| `QebspilAdsp` | 4096 B NV | full log, NUL-padded (EBS **primary**) |
| `QebspilEbs` | 256 B NV | last stage line, NUL-padded |

```
# skip 4-byte EFI attribute prefix; expect ebs-efivar-fixed + stage=
dd if=/sys/firmware/efi/efivars/QebspilAdsp-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo
```

LIVE no-reuse (`0x24: 0`, `0x1: -22`) prefers **MAIN INIT** fail:

```
qebspil: qcom,x1e80100-adsp-pas [MAIN] pas=0x1 stage=INIT status=0x…
```

vs `stage=AUTH`. AUTH-fail of MAIN would have dropped DTB.

## Next Omarchy step (the binary)

Replace USB `qebspilaa64.efi` only (same stick as dtbloader + MATCH
firmware). Do not rebuild the kernel. Do not enable
`attach_running_main`. After next boot: **efivar only** (the `dd`
above). No ConOut, no photo, no USB log.

```
cp qebspil/qebspilaa64.efi /path/to/that/volume/qebspilaa64.efi
```

Rebuild (optional): `./qebspil/build-main-fail-log.sh`
