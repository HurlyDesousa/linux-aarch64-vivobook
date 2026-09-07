# Vivobook top-level `/sound` DTS (pkgrel 12)

7.2 / mainline `x1e80100-asus-vivobook-s15` still has SoundWire + WSA/TX/RX/VA
macros and `remoteproc_adsp` under `soc`, but the board DT has **no**
top-level `/sound`. ALSA cannot bind a card (`aplay -l` empty / PipeWire
Dummy) even if full ADSP later comes up.

`0007-x1e80100-vivobook-sound-dts.patch` ports Elliot Huang’s tested
board graph (LKML 2025-06-02, “arm64: dts: qcom: support sound on Asus
Vivobook S15”; github copy
[binarycraft007/linux-x1e80100-vivobook-s15](https://github.com/binarycraft007/linux-x1e80100-vivobook-s15/blob/main/0001-arm64-dts-qcom-support-sound-on-Asus-Vivobook-S15.patch))
onto this tree’s split `x1-asus-vivobook-s15.dtsi`.

Elliot tested: 2 speakers, 2 DMICs, headset (mic distorted / left-only
record). That is a **2-speaker** graph. Do **not** copy Yoga Slim 7x
(woofer+tweeter × 2). Yoga’s
`x1e80100-lenovo-yoga-slim7x.dts` sound section is only a valid
reference for dai-link shape. The closer peer is ThinkPad T14s.

## What the DTS adds

| Piece | Notes |
|-------|--------|
| `/sound` | `compatible = "qcom,x1e80100-sndcard"`; `model = "X1E80100-ASUS-Vivobook-S15"` |
| WSA | `swr0` + WSA8845 `@0,0` / `@0,1`; `reset-gpios = <&lpass_tlmm 12 GPIO_ACTIVE_LOW>` |
| WCD9385 | `audio-codec` + `swr1` RX `@0,4` + `swr2` TX `@0,3`; reset `tlmm` gpio191 |
| VA DMICs | `&lpass_vamacro` + `dmic01_default`; micbias `vreg_l1b_1p8` |
| Rails | pm8550 `ldo1` (`vreg_l1b_1p8`) and `ldo12` (`vreg_l12b_1p2`) — supply phandles existed, nodes did not |
| DP | DP0/DP1 playback dai-links + `sound-name-prefix` (Elliot’s github copy; LKML v1 omitted these) |

`CONFIG_RESET_GPIO=y` is already in `config.vivobook` (Yoga-style WSA
`SD_N` / gpio-reset). Live 7.2.0-2 left it unset; ALARM master is `=m`.
Built-in so the speaker reset can deassert without waiting on a module.
That unmute path only matters **after** full ADSP + a bound card.

## Still required after this DTS (userspace)

DTS is only the card graph. Playback still needs:

1. **AudioReach topology** — [linux-msm/audioreach-topology#22](https://github.com/linux-msm/audioreach-topology/pull/22)
   reuses the T14s `.m4` and emits **`X1E80100-ASUS-Vivobook-S15`** into
   `qcom/x1e80100/ASUSTeK/vivobook-s15`. Install that `tplg` (or the
   distro package that ships it). The DTS `model` string must match.
2. **UCM** — alsa-ucm-conf commit
   [e055d16](https://github.com/alsa-project/alsa-ucm-conf/commit/e055d16bdf971e26c3d92d998bccb2ca4e4f3c1a)
   (`ucm2/Qualcomm/x1e80100/`; PR
   [#570](https://github.com/alsa-project/alsa-ucm-conf/pull/570) closed
   as landed there). Speakers / DMIC / headset playback were tested;
   headset-record is incomplete upstream.

Without topology + UCM, a bound card can still be silent or unused by
PipeWire.

## Parallel track: PAS 0x24 / 0x1 (not this PR)

Today on Omarchy (Gunyah → EL1 guest) PAS **0x24** and **0x1** are still
**-22** / attach-to-lite. Lite ADSP has charging, **not** audio. A
TZ-accepted ADSP DTB and full PAS AUTH of **0x24 then 0x1** (qebspil /
QTI-CASS) remains a **parallel** track. See [adsp-22.md](adsp-22.md).

This PR does **not** change `0001` / `0005` / `0006`,
`reuse_authenticated_dtb`, `attach_running_main`, or ALWAYS_START.
**HOLD** those flags. **HOLD install / no Omarchy reboot ask.**

Missing `/sound` is a necessary ALSA bind condition; it does **not**
by itself explain Dummy-on-lite. After EBS AUTH of 0x1 + attach-main,
`aplay -l` is the check that this graph can bind.

## Omarchy capture for the next iteration

If the card probes but speakers/jack stay dead, dump live DT (do not
guess from Yoga):

```
# After a boot that has this DTB:
find /proc/device-tree/sound -maxdepth 2 -print
ls /proc/device-tree/soc/soundwire@6b10000/   # swr0 / WSA
ls /proc/device-tree/soc/soundwire@6ad0000/   # swr1 / WCD RX
ls /proc/device-tree/soc/soundwire@6d30000/   # swr2 / WCD TX
# Confirm phandles / reset GPIOs vs this patch:
#   WSA SD_N  = lpass_tlmm gpio12 ACTIVE_LOW (Elliot)
#   WCD reset = tlmm gpio191 ACTIVE_LOW (Elliot / T14s)
#   WSA rails = vreg_l15b_1p8 + vreg_l12b_1p2
```

ACPI/Windows or BSP schematic can contradict gpio12 / gpio191. Capture
those before rewriting the graph. HDMI (PS185 on USB SS2) has no extra
dai-link in Elliot’s patch; add DP2/HDMI only if live DT shows it.
