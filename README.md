# linux-aarch64-vivobook

Custom [Arch Linux ARM](https://github.com/archlinuxarm/PKGBUILDs/tree/master/core/linux-aarch64)
`linux-aarch64` for an ASUS Vivobook S 15 **S5507QA** (Snapdragon X Elite
X1E-78-100, DTB `x1e80100-asus-vivobook-s15`) already running Omarchy ARM.

This is **not** the omarchy-iso fork. Native-build on the laptop (X Elite).
Dual-boots with stock `linux-aarch64`: this package does not Provide `linux`
and does not Conflict the stock kernel.

## Camera — Phase B (pkgrel 7)

### Phase B live results (7.2.0-6, pkg 7.2.2-6)

Running `7.2.2-6-aarch64-vivobook` on S5507QA gave these results:

| Device | Status | Notes |
|--------|--------|-------|
| `acb7000.isp` (CAMSS) | **BOUND** | video0–15, v4l-subdev0–27, /dev/media0; TPG warn only |
| `ac15000.cci` (CCI0) | **FAIL -110** | deferred probe timeout; no i2c adapter |
| `ac16000.cci` (CCI1) | **FAIL -110** | deferred probe timeout; no i2c adapter |
| `cam_cc_cci_0_clk` | exists @ 19.2MHz, enable=0 | **deviceless** — never claimed |
| TITAN_TOP GDSC | off | consumers: only `acb7000.isp`; CCI not listed |

### Root cause: GDSC not powered at hardware-init time

On x1e80100, `CAM_CC_TITAN_TOP_GDSC` is controlled **exclusively** through
the genpd power-domain layer.  Unlike older Qualcomm SoCs (sdm845, sm8450)
where enabling a clock gate also raises the upstream GDSC, x1e80100 CAMCC
keeps GDSC control separate.

The v7.2 `i2c-qcom-cci` driver probe calls `cci_enable_clocks()` (opens
the clock gates) and then immediately writes `CCI_RESET_CMD` to the CCI
hardware and waits 100 ms for a `RST_DONE_ACK` IRQ.  With TITAN_TOP GDSC
still off, the hardware is powered down and never responds → timeout →
`-ETIMEDOUT` (-110).  The device goes through deferred-probe retries and
eventually the deferred-probe watchdog fires, producing the observed
`-110 deferred probe timeout`.

**The DTS (clocks / clock-names / power-domains) is correct** and matches
the upstream Linaro v4 patch series for x1e80100 CCI verbatim.  No DTS
change is required for the root cause.

### Fix: `0004-i2c-qcom-cci-power-on-gdsc-before-hw-init.patch`

Restructures `cci_probe()` to set up `pm_runtime` **before** the first
hardware register access:

1. `pm_runtime_set_suspended()` + `pm_runtime_enable()` — arms the
   pm_runtime engine (which knows about `power-domains` in DTS).
2. `pm_runtime_resume_and_get()` — genpd raises `CAM_CC_TITAN_TOP_GDSC`
   through the camcc power-domain provider, then calls
   `cci_resume_runtime()` → `cci_enable_clocks()` + `cci_init()`.
3. `cci_reset()` + `cci_init()` run with GDSC **on** — hardware responds,
   `RST_DONE_ACK` fires, probe continues.
4. `pm_runtime_mark_last_busy()` + `pm_runtime_put_autosuspend()` — allows
   the device to auto-suspend after probe (GDSC off when idle).
5. `cci_xfer()` already calls `pm_runtime_get_sync()` for every transfer,
   so runtime-resume (GDSC on + clocks on + cci_init) happens correctly.

### Post-boot verification after pkgrel 7

```bash
# After rebuild+install+reboot into 7.2.2-7-aarch64-vivobook:
dmesg | grep -E 'cci|camcc'          # expect no -110; CCI bound
ls /sys/class/i2c-adapter/           # new i2c-N entries for CCI0 (2) and CCI1 (2)
cat /sys/kernel/debug/clk/cam_cc_cci_0_clk/enable   # expect 0 when idle
# Optional (confirms TITAN_TOP comes up with CCI):
i2cdetect -y <N>                     # 0x36 deferred to Phase C
```

---

## Camera — Phase A (pkgrel 6)

**7.2.2-6 (pkgrel 6)** fixes a DTC FATAL introduced by pkgrel 5: the
`&camss` board overlay in `x1-asus-vivobook-s15.dtsi` contained an empty
`ports {};` child node listed after property assignments, violating the
DTC rule that properties must precede subnodes.  The empty `ports {}` was
removed; the overlay now contains only the three property assignments
(`vdd-csiphy-0p8-supply`, `vdd-csiphy-1p2-supply`, `status = "okay"`).
No functional change — `camss` in `hamoa.dtsi` already has no child nodes
at Phase A; adding an empty overlay `ports {}` served no purpose and
broke the build.

**7.2.2-5 (pkgrel 5)** enables the camera infrastructure on
x1e80100/Vivobook S15 so CCI I2C adapters can probe after boot.
No sensor node is wired yet; that is Phase C after CCI is confirmed.

### What was enabled

| Component | Location | Notes |
|-----------|----------|-------|
| CAMCC clock controller | `hamoa.dtsi` | `@0xade0000`; needed by CCI+CAMSS for clocks/power |
| CCI0 I2C adapter | `hamoa.dtsi` | `@0xac15000` IRQ 460; gpio101-104 |
| CCI1 I2C adapter | `hamoa.dtsi` | `@0xac16000` IRQ 271; gpio105-106 + gpio235-236 (aon_cci) |
| CAMSS ISP | `hamoa.dtsi` | `@0xacb7000`; v7.2 embedded-CSIPHY legacy binding |
| CCI pinctrl | `hamoa.dtsi` / tlmm | gpio101-106 `cci_i2c`, gpio235-236 `aon_cci` |
| Board enable | `x1-asus-vivobook-s15.dtsi` | `&camss`, `&cci0`, `&cci1` status=okay |
| `CONFIG_VIDEO_OV02C10=m` | `config.vivobook` | Module compiled, NOT bound (no DTS sensor node yet) |

### What is left as TODO / Phase C

- **Sensor node**: OV02C10 @ CCI1 i2c1 0x36 is a **HUNCH** — must be
  confirmed by `i2cdetect` once CCI adapters appear.
- **CSIPHY supply regulators**: `vdd-csiphy-0p8-supply` / `1p2-supply`
  in the board DTS use `vreg_l1d_0p8` / `vreg_l3e_1p2` as guesses (no
  pm8010 camera PMIC visible in Vivobook DTS).  Verify against BSP
  schematic before wiring a sensor.
- **PHY API**: upstream v13 CSIPHY series (Bryan O'Donoghue / Linaro,
  still under review 2026-07) will replace embedded CSIPHY with
  separate `csiphy@` nodes; update in a follow-up once merged.
- **ACPI HID**: OVTI02C1 vs OVTI08X40 still unconfirmed from Vivobook
  DSDT; not blocking this PR.

### Post-boot checks

```
# After building and installing 7.2.2-6-aarch64-vivobook:
ls /sys/class/i2c-adapter/          # new i2c-N entries for CCI0 and CCI1
dmesg | grep -E 'cci|camss|csiphy|qcom-camss'
# Phase B: once CCI adapters are confirmed:
i2cdetect -y <N>                    # look for 0x36 on the CCI1 i2c1 bus
ls /dev/video*                      # will be empty until Phase C sensor bind
```

See `0003-x1e80100-vivobook-camera-phase-a.patch` for the full DTS.

---

## Config diff vs the live 7.2.0-2 kernel

| Symbol | Live 7.2.0-2 | This fragment |
|--------|----------------|---------------|
| `CONFIG_RESET_GPIO` | unset | **y** (WSA amp reset / unmute after ADSP) |
| `CONFIG_POWER_RESET_GPIO` | y | unchanged |
| `CONFIG_VIDEO_QCOM_IRIS` | unset | **m** (needs `qcvss8380.mbn`; decode still needs the module) |
| `CONFIG_VIDEO_OV02C10` | unset | **m** (Phase A: module compiled, not bound — no sensor DTS yet) |
| `CONFIG_QCOM_Q6V5_PAS` | m | unchanged |
| `CONFIG_SND_SOC_SC8280XP` | m | unchanged |

See `config.vivobook`. The PKGBUILD starts from ALARM's full `config` and
merges this fragment.

## ADSP -22

Not a DTS carveout mismatch. The ELF and the 7.2 DTS already agree:

- `adsp_dtbs.elf` PT_LOAD paddr `0x8b800000` filesz `0x10e4c` (CFGL + 8 DTBs:
  hamoa/purwa default, charger, audio, sensor)
- `remoteproc_adsp` memory-region is `adspslpi@87e00000` + `q6-adsp-dtb@8b800000`
- `qcadsp8380.mbn` paddr starts at `0x87e00000` (adspslpi)
- CDSP ELF `0x8d900000` matches `q6-cdsp-dtb` and **runs**
- PAS ids already `pas=1`, `dtb=0x24`, `lite=0x1f`, `lite_dtb=0x29`

The -22 is `qcom_scm_pas_init_image(0x24)` (TZ metadata). Lite ADSP is
already up from UEFI.

**7.2.2-2 (pkgrel 2)** moved DTB PAS_INIT into `qcom_pas_start()` after
power, shut down leftover PAS 0x24 / PAS 1 **and lite**, PAGE-aligned
metadata DMA, and logged every shutdown errno. Result on S5507QA: lite
shutdown returned 0, PAS 0x24 still -22. TZ will not accept this
OEM-signed DTB from NS. Battery EAGAIN, no soundcards. CDSP/GPU/SSH fine.

**7.2.2-3 (pkgrel 3)** keeps that sequence except it does **not** kill
lite until DTB PAS_INIT succeeds. If TZ still rejects 0x24 and the rproc
has `lite_pas_id`, `start()` attaches to UEFI lite ADSP (return 0 so
remoteproc goes RUNNING, GLINK/battmgr can attach) instead of failing.
This is **attach-to-lite fallback, not a TZ signature fix**. Full audio
ADSP still needs a TZ-accepted DTB (QTI-CASS or qebspil), not another
DTS change. `aplay -l` will stay empty on lite. Optional cmdline
`qcom_q6v5_pas.attach_lite_on_dtb_fail=0` restores kill-lite-then-init.

**7.2.2-4 (pkgrel 4)** keeps attach-to-lite unchanged. 7.2.2-3 on S5507QA
got lite ADSP + battmgr (Charging, energy_now/energy_full ~12%) but
`capacity` / `charge_now` were ENODATA — lite does not send SOC.
`0002-qcom-battmgr-capacity-from-energy.patch` exports CAPACITY on
x1e80100 and, when firmware SOC is missing, returns
`energy_now/energy_full` percent. Firmware SOC is still preferred when
full ADSP later provides it. Do not expect `aplay -l` to grow a card.

**7.2.2-9 post-qebspil VERIFY** (same `0001` attach-to-lite): `PAS
shutdown dtb (id=0x24): 0` (was -22), main 0x1 still -22, TZ still
rejects NS `adsp_dtbs.elf`, attach-to-lite 0x1f, `aplay -l` empty.
qebspil left DTB PAS state; `start()` tore it down then failed NS
PAS_INIT. Not a DTS fix.

**7.2.2-10 (pkgrel 10)** adds
`0005-x1e-adsp-reuse-authenticated-dtb.patch`: opt-in
`qcom_q6v5_pas.reuse_authenticated_dtb=1` skips 0x24 teardown + NS DTB
PAS_INIT and tries main `qcadsp8380.mbn` against the UEFI DTB. Default
**off** (keep attach-to-lite / charging). ADSP-only (`lite_pas_id`);
CDSP unchanged. If main PAS_INIT fails, attach-to-lite. If it succeeds,
lite is stopped before main AUTH_RESET (charging may drop if AUTH_RESET
then fails). Still not a TZ signature fix.

**7.2.2-10 REUSE_PARTIAL VERIFY** (Omarchy, live): reuse line hit;
`PAS shutdown main (id=0x1): -22`; `error -22 initializing
.../qcadsp8380.mbn`; attach-to-lite; `aplay -l` empty. CDSP main 0x12
came up. No qebspil EBS AUTH log on USB (ConOut only). Linux NS cannot
`PAS_INIT` the OEM main MBN. Not a limine/pkg miss; not a sound DTS
fix. Next is UEFI/qebspil AUTH_RESET of **main PAS 0x1**, then Linux
attach.

**7.2.2-11 (pkgrel 11)** adds
`0006-x1e-adsp-attach-running-main.patch`: opt-in
`qcom_q6v5_pas.attach_running_main=1` skips teardown + NS PAS_INIT of
DTB **and** main and attaches to a UEFI-started PAS 0x1. Default
**off**. **Do not enable** while 0x1 shutdown is still -22 (not lite;
charging/GLINK may break). After EBS shows AUTH of 0x1, use this flag
**alone** — do not also set `reuse_authenticated_dtb=1` (that path
still `PAS_SHUTDOWN`s main). CDSP unchanged.

**7.2.2-11 ConOut VERIFY** (pkgrel 11 held): EFI `load qebspilaa64.efi`
printed `Hello World!` + `Found QCOM SCM protocol version 0x50002` +
`Image loaded … Success`. **No** `Found remoteproc` / Starting / AUTH
for 0x24 or 0x1. Post-boot systab has ACPI/SMBIOS only — **no `DTB=`**.
`dmesg` efi lists SMBIOS/TPM/ACPI/MEMATTR/ESRT/RNG/INITRD/MEMRESERVE
— **no DTB**. `/sys/firmware/fdt` exists via UKI; that is not the EFI
DTB config table. `limine.conf` is `protocol` `efi` + the same UKI
(cmdline A/B only); no `dtb_path` / `efi_dtb` / `global_dtb`. Firmware
hashes MATCH.

**Root cause:** qebspil (`efi_dtb_changed` /
`LibGetSystemConfigurationTable`) enumerates remoteprocs only when
`EfiDtbTableGuid` is installed. **Limine never publishes that GUID**
(UKI `efi` protocol feeds the kernel, not other EFI drivers).
**Fix:** load TravMurav [dtbloader](https://github.com/TravMurav/dtbloader)
first (`InstallConfigurationTable`), then
`qebspilaa64.efi` built with `QEBSPIL_ALWAYS_START=1` (Vivobook DT has
no `qcom,broken-reset`), then Limine. Do not fork Limine here. Do not
enable `attach_running_main` until 0x1 AUTHs. Do not treat another
NS `PAS_INIT` tweak as a table fix.

**7.2.2-11 dtbloader VERIFY** (pkgrel 11 held): after dtbloader →
ALWAYS_START qebspil → Limine, ConOut **`Found remoteproc` OK**
(adsp+cdsp). That is enumerate+prepare only — **not AUTH**. Late-EBS
ConOut **not captured** (load-time Found only). Omarchy reuse=1
dmesg: `reusing UEFI/qebspil DTB PAS (id=0x24); skip teardown + NS
… adsp_dtbs.elf PAS_INIT`; `PAS shutdown main (id=0x1): -22`;
error initializing `qcadsp8380.mbn`; attach-to-lite. **No**
`PAS shutdown dtb (id=0x24): 0` on this boot — reuse skipped
teardown. CDSP: dtb `0x25` -22; main `0x12` 0. Dummy / no cards.
`systab` still no `DTB=` (post-EBS; secondary). Insyde + qebspil
`event.c` TPL poke is suspect if there is no `Starting`. Firmware
must sit on the same FAT as `qebspilaa64.efi` under
`/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/`. **HOLD**
`attach_running_main`. Next: one Limine→UKI ConOut photo (or one
no-reuse boot to read `PAS shutdown dtb 0x24` vs main 0x1).

See [docs/adsp-22.md](docs/adsp-22.md) and the operator recipe
[docs/qebspil-dtbloader.md](docs/qebspil-dtbloader.md)
(`startup.nsh`: `load dtbloader.efi` then `load qebspilaa64.efi`).
Patches live at repo root as
`0001-x1e-adsp-dtb-init-after-power.patch`,
`0002-qcom-battmgr-capacity-from-energy.patch`,
`0005-x1e-adsp-reuse-authenticated-dtb.patch`, and
`0006-x1e-adsp-attach-running-main.patch` (makepkg `source=()`
basenames; copies under `patches/` are optional).

After reboot into `7.2.2-11-aarch64-vivobook`:

```
dmesg | grep -E 'PAS shutdown|initializing firmware|attaching to|reusing UEFI|attach_running_main'
cat /sys/class/remoteproc/remoteproc0/state
cat /sys/class/power_supply/qcom-battmgr-bat/capacity
aplay -l
```

Daily boot: no extra flags (attach-to-lite). dtbloader then
ALWAYS_START qebspil is already staged (`Found remoteproc` OK).
Next is a Limine→UKI ConOut photo of `Starting` / INIT / AUTH —
not `attach_running_main`. After EBS AUTH of 0x1 only: Limine
cmdline `qcom_q6v5_pas.attach_running_main=1`.

## Build and install (on the Vivobook)

```bash
sudo pacman -S --needed base-devel xmlto docbook-xsl kmod inetutils bc git dtc python pahole
git clone https://github.com/HurlyDesousa/linux-aarch64-vivobook.git
cd linux-aarch64-vivobook
makepkg -s
sudo pacman -U linux-aarch64-vivobook-*.pkg.tar.* linux-aarch64-vivobook-headers-*.pkg.tar.*
sudo limine-update
sudo reboot
```

Does **not** replace stock `linux-aarch64`. The Omarchy hook should build
`/boot/EFI/Linux/omarchy_linux-aarch64-vivobook.efi` because the package
ships `/usr/lib/modules/<kver>/{pkgbase,vmlinuz}` with `pkgbase=linux-aarch64-vivobook`.
Keep the old kernel as the Limine fallback.

Kernel tarball is large. Build on the laptop, not a GitHub runner.

## Firmware

Do not commit Qualcomm/ASUS `.mbn` / `.elf` / BSP exe. Fetch from the official
S5507QA BSP; see the [omarchy-iso fork docs](https://github.com/HurlyDesousa/omarchy-iso/blob/asus-vivobook-s15/docs/asus-vivobook-s15.md).
