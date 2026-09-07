# Vivobook `/sound` graph (pkgrel 12)

Omarchy live DT (`/sys/firmware/devicetree/base`) confirmed SoundWire
+ WSA/TX/RX macros + remoteproc under `soc`, and **no top-level
`/sound`**. That matches stock 7.2 `x1-asus-vivobook-s15.dtsi`.
`0007-x1e80100-vivobook-sound-dts.patch` ports Elliot Huang’s tested
board graph (LKML Jun 2025, “arm64: dts: qcom: support sound on Asus
Vivobook S15”) so ALSA can eventually bind. Yoga Slim 7x DTS is
**reference only** (4× WSA, no WCD).

Live `soundwire@6ab0000` is `label = "WSA2"`, `status = "disabled"`.
In 7.2 `hamoa.dtsi` that node is **`swr3`** (WSA2 / Yoga’s second
bank), not `swr0`. `0007` enables **`&swr0`** (`soundwire@6b10000`,
`label = "WSA"`) plus WSA8845 children, matching Elliot / T14s
(2 speakers). Do not turn on WSA2 unless a later dump shows four
amps.

`CONFIG_RESET_GPIO=y` is already in `config.vivobook` (Yoga lesson:
WSA amp reset/unmute is a GPIO reset, not `POWER_RESET_GPIO`).

## Still required after this DTS (not in this repo)

- **AudioReach topology** matching `model = "X1E80100-ASUS-Vivobook-S15"`:
  [linux-msm/audioreach-topology#22](https://github.com/linux-msm/audioreach-topology/pull/22)
  aliases the T14s graph —
  `X1E80100-LENOVO-Thinkpad-T14s` → `X1E80100-ASUS-Vivobook-S15` →
  install dir `qcom/x1e80100/ASUSTeK/vivobook-s15`. Userspace still
  has to ship that `.bin`.
- **UCM**: alsa-ucm-conf maps `ASUSTeK COMPUTER.*ASUS Vivobook S 15`
  onto the T14s Qualcomm x1e80100 profile
  ([alsa-ucm-conf#570](https://github.com/alsa-project/alsa-ucm-conf/pull/570)
  / commit `e055d16`). PipeWire `auto_null` is expected until the card
  + topology + UCM exist.

## Parallel: PAS -22 / full ADSP

TZ-accepted ADSP DTB and full PAS AUTH `0x24` → `0x1` are **parallel**,
not a blocker for adding the `/sound` graph. Today PAS `0x24` and `0x1`
still return `-22`; attach-to-lite; `aplay -l` empty. Do **not** treat
this patch as a qebspil / `reuse_authenticated_dtb` / `attach_running_main`
change. See [adsp-22.md](adsp-22.md).

**HOLD install. Do not ask Omarchy to reboot for this PR.**

## What Omarchy should still capture from live DT

After a later install (not this PR), dump and keep:

```bash
# Graph present in the running DTB?
ls /proc/device-tree/sound
cat /proc/device-tree/sound/compatible
cat /proc/device-tree/sound/model
# Confirm 7.2 symbols (do not trust address→swr0 guesses)
xxd -p /proc/device-tree/__symbols__/swr0   # expect …/soundwire@6b10000
xxd -p /proc/device-tree/__symbols__/swr1   # 6ad0000 WCD RX
xxd -p /proc/device-tree/__symbols__/swr2   # 6d30000 WCD TX
xxd -p /proc/device-tree/__symbols__/swr3   # 6ab0000 WSA2, stay disabled
for a in 6b10000 6ad0000 6d30000 6ab0000; do
  echo "== $a =="; cat /proc/device-tree/soc/soundwire@$a/label /proc/device-tree/soc/soundwire@$a/status
  ls /proc/device-tree/soc/soundwire@$a
done
ls /proc/device-tree/audio-codec             # wcd938x
find /proc/device-tree -name 'sound*' -o -name '*wsa*' -o -name '*wcd*' | sort
dmesg | grep -E 'snd|soundwire|wsa|wcd|q6apm|remoteproc|PAS'
aplay -l
# Topology / UCM (userspace, not this kernel)
ls /usr/lib/firmware/qcom/x1e80100/ASUSTeK/vivobook-s15/*tplg* 2>/dev/null
ls /usr/share/alsa/ucm2/Qualcomm/x1e80100/
```

Compare live node names, `qcom,port-mapping`, reset GPIOs (TLMM 191,
LPASS 12), and supplies (`vreg_l15b_1p8`, `vreg_l12b_1p2`,
`vreg_l1b_1p8`, `vreg_bob1`) against this patch. ASUS fw paths stay
`qcom/x1e80100/ASUSTeK/vivobook-s15/`.
