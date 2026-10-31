# exp scale 通常 wire 旧新比較

2026-10-04、Windows x64。計器・独自allocatorなし。compile 1/native 3、全child exit0、診断成功。製品への採用はしない。

- 旧新の全frame 478856 bytesを直接比較して一致。双方の復元plain 2811006 bytesを入力全体と比較して一致。
- 各型内Proof14 Eq、型間全14field Debug、4方向の全statsと凍結通常版が一致。header/payload/input CRCを検査。
- 各selfcheckは正常14、破損34、短header4。凍結E2E JSON全体と一致。
- OS実測peak：pair working set 55472128/private commit 52015104 bytes、両selfも160MiB内。
- 新出力EXE 505344/report 142237、合計647581 bytes（8MiB上限）。大きな入力/frame/plainコピーは保存しない。終了時空き53802622976 bytes。

| 単回内部時間 | control ms | candidate ms |
| --- | ---: | ---: |
| 圧縮 | 2468.7824 | 2858.0979 |
| 展開 | 2667.8035 | 2604.6716 |

control先行・warmup0・各1回。圧縮側は遅く、安定した速度改善の根拠なし。命令削減だけでは性能改善と判定できない。正式fullCLI、quiet条件、warm1+9、holdout、4 nativeの目標は未達。

親readonly verifierはexit0、174 before/after/live組、raw native3件、全E2E/stats/Proof/実memory/RAM式/出力形状を再照合。追加compile/native0。

- report SHA256: `2834F9D475C4E07D64DB8DD5D9FAFC0247737DD8CB7EFF76101FAE3C830457FA`
- EXE SHA256: `15C52B978B8E4A8E5A764C6A6DDF4E84DE11E30620038C8B35F6675F558DDA30`
- 再照合: `pwsh -NoProfile -File UnLhaRe/experiments/khc/hard-cut-exp-scale-wire/verify-readonly.ps1`

次候補は元の通常Model上のbranch entropy log2 lookup。exp-scale候補とは重ねない。失敗契約と数値同値を先行確認し、計測が成立するまで採用しない。7-Zip超えGOALはactive、停止指示なし。
