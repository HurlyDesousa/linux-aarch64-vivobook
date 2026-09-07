# qebspil late-EBS efivar log (Omarchy binary)

pkgrel **11** held. **HOLD** `attach_running_main`. No kernel install.
No ConOut photo. No dedicated reboot ask.

Pinned upstream: [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
`8e4d9e676a3b3afe136cda9b953a2139ff1a32d0` +
`0001-main-fail-file-and-efivar-log.patch`.
Built with `QEBSPIL_ALWAYS_START=1`.

## Why acca195 missed `late-EBS enter`

LIVE USB swap of the ebs-efivar-fixed binary: `QebspilAdsp` banner
`ebs-efivar-fixed build` **OK** (load-time fixed 4 KiB NV write
works). Rest **NUL-padded**. No `late-EBS enter`. No `[MAIN] stage=`.

That boot: Toby Limine **keymap-only unlock — skipped dtbloader**.
Linux `PAS shutdown dtb 0x24: -22`. That is **invalid for AUTH
comparison**. Prior good boots needed dtbloader→qebspil for `0x24: 0`.

Upstream `efi_dtb_changed()`:

1. `LibGetSystemConfigurationTable(EfiDtbTableGuid)` — no GUID →
   return SUCCESS
2. `dtb_enumerate_rprocs` — `EFI_NOT_FOUND` → return SUCCESS
3. **Only then** `event_register_late_ebs_callback(efi_late_ebs)`

No GUID / remotecount=0 → **callback never registered** →
`pil_finish_all` **never runs** → SetVariable at EBS is **never
attempted**. Fixed-size NV cannot persist a line that is never
written. qebspil still loaded (banner proves it).

## What this binary does

- Banner: `qebspil: ebs-always-register build` (not
  `ebs-efivar-fixed`)
- Same GUID, same **fixed 4 KiB NV** `QebspilAdsp` in-place
  `SetVariable`. Never FAT / Print at EBS
- Load-time always persists: banner, `persist SetVariable status=`,
  `late-EBS registered status=`, `EfiDtbTableGuid missing|found`,
  `remotecount=N`
- **Always** registers `efi_late_ebs` at load (not gated on the
  DTB table or remotes)
- Late-EBS always writes `late-EBS enter remotecount=N` even if
  N=0; then per-component INIT/AUTH when N>0

## EFI variables (GUID `6b7c0a11-24e1-4a01-9e80-11ad50010024`)

| name | size | contents |
|------|------|----------|
| `QebspilAdsp` | 4096 B NV | full log, NUL-padded (EBS **primary**) |
| `QebspilEbs` | 256 B NV | last stage line, NUL-padded |

```
# skip 4-byte EFI attribute prefix
dd if=/sys/firmware/efi/efivars/QebspilAdsp-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo
```

| load-time line | meaning |
|----------------|---------|
| `ebs-always-register build` | new binary is on the stick |
| `persist SetVariable status=0x0` | 4 KiB NV write still works |
| `late-EBS registered status=0x0` | callback **exists** |
| `EfiDtbTableGuid missing` | keymap-only / no dtbloader |
| `remotecount=0` | no prepared rprocs; no MAIN stages this boot |
| `remotecount=2` + `EfiDtbTableGuid found` | dtbloader path; expect INIT/AUTH at EBS |

| late-EBS line | meaning |
|---------------|---------|
| `late-EBS enter remotecount=N` | callback **ran** (even if N=0) |
| `[MAIN] pas=0x1 stage=INIT\|AUTH` | only when N>0 (needs dtbloader) |
| no enter, but registered 0x0 | EBS persist failed or callback never fired |

Keymap-only unlock **without dtbloader** is invalid for 0x24 AUTH.
Next collect of MAIN stages needs a **full dtbloader→qebspil** boot.

LIVE no-reuse (`0x24: 0`, `0x1: -22`) still prefers **MAIN INIT** fail
on that proper path:

```
qebspil: qcom,x1e80100-adsp-pas [MAIN] pas=0x1 stage=INIT status=0x…
```

vs `stage=AUTH`. AUTH-fail of MAIN would have dropped DTB.

## Next Omarchy step (the binary)

Replace USB `qebspilaa64.efi` only (same stick as dtbloader + MATCH
firmware). Do not rebuild the kernel. Do not enable
`attach_running_main`. After next **full dtbloader→qebspil** boot:
**efivar only** (the `dd` above). No ConOut, no photo, no USB log.

```
cp qebspil/qebspilaa64.efi /path/to/that/volume/qebspilaa64.efi
```

Rebuild (optional): `./qebspil/build-main-fail-log.sh`
