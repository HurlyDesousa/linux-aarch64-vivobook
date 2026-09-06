# qebspil main-fail log (Omarchy binary)

pkgrel **11** held. **HOLD** `attach_running_main`. No kernel install.
No ConOut photo. No dedicated reboot ask.

Pinned upstream: [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
`8e4d9e676a3b3afe136cda9b953a2139ff1a32d0` +
`0001-main-fail-file-and-efivar-log.patch`.
Built with `QEBSPIL_ALWAYS_START=1`.

## What the binary does

Same ALWAYS_START path as the live stick. Extra:

- Explicit `[MAIN]` / `[DTB]` + `pas=0x1` / `0x24` + stage
  (`INIT` / `AUTH` / `fw_check` / …) + `status=0x…`
- Writes `\qebspil-adsp.log` on the **same volume** as the `.efi`
  (load-time lines always; late-EBS lines best-effort — FAT may
  already be down)
- EFI variable `QebspilAdsp` (GUID
  `6b7c0a11-24e1-4a01-9e80-11ad50010024`) — survives EBS

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
(no extra photo, no extra PAS dump):

```
# skip 4-byte EFI attribute prefix
dd if=/sys/firmware/efi/efivars/QebspilAdsp-6b7c0a11-24e1-4a01-9e80-11ad50010024 \
   bs=1 skip=4 status=none; echo
# and/or, on the same volume as the efi:
cat /qebspil-adsp.log
```

Rebuild from source (optional; prebuilt already in this dir):

```
./qebspil/build-main-fail-log.sh
```
