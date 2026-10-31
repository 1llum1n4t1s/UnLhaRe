# KT同値mass再利用の反証結果（2026-10-04）

数値とE2E結果は一致したが、圧縮側が遅くなったため非採用。固定の両方向短縮gateを維持した。

| ABBA一周・各方式2回平均 | 旧版 | 候補 | 時間差 |
| --- | ---: | ---: | ---: |
| encode | 5811.3177 ms | 6411.40585 ms | +10.3262% |
| decode | 6768.67555 ms | 6253.06930 ms | -7.6175% |

一周・warmupなしの診断であり、展開側の差を正式改善率とは呼ばない。異なる実験の時間を混ぜない。同条件の好結果狙い再試行は行わない。

## 変更と実測

- private depth KTのchecked product後、既出同値massのHamilton補正前quotient/remainderだけコピー。全guard順、checked sum、tie-break、increment、最終vector検査は維持。
- Cts/kernel/seal/observeの他のbodyは凍結原文と一致。codecは旧Math/旧poolを維持、候補Cts aliasと拒否E2Eへ到達するcrate module visibilityのみ変更。数値allowlist/graphを親と独立analystが静的検証後に実行。worker/analystはrole既定 gpt-6.1-sol / medium、compile/CLIは親だけ。
- compile1回2341.3630ms、比較CLI1回184.9862ms、ABBA1回50718.1048ms、全exit0。compile warning stderr983B、CLI stderr0。
- KT直接比較17320件（directed936＋決定的raw4096×4）、正常17262・拒否58。全4raw CAPとprefix先行拒否、全vector要素・エラー字面・prefix3余りtieを照合。旧新model拒否helper各1回、tuple各(14,16,1)、保存state保持32assertions pass。
- ABBA old/new/new/old、encode/decode各4。全plain2811006B×4、全frame478750B×3、Proof全14field（CDF bits）・stats直接一致。483599Bサイズ上限維持、peak frames2/957500B、終了frame0。
- 206 identitiesのSHA/bytes/UTCticksをbefore/after/live照合し不一致0、source graph14。所有候補process0。timeout/pipe overflow失敗注入は未実測。

## 容量・証拠・残作業

- 新source7file計85822B。EXE409600B＋report83255B＝492855B（約481KiB）。今回3rootの生成物は6file計1393119B（約1.33MiB）、source合計257096B。大きなcorpus/frame/plain/Cargo/PDB/rawtraceを追加せず、削除なし。空き約69.50GiB。
- report: `build/khc-quaternary-cts-kt-equal-20261004/report.json` SHA256 `3DFC56A76C7186B79BFFF56DD8A4D3064510D6A8C7BED49D4ABF118884C47404`、83255B。
- EXE: 同root `kt-equal-o2.exe` SHA256 `8D636214239B3DDC3C6CD1796459324188AF49C43A993A0692B9C127397B15E2`、409600B。
- source/入口: `quaternary-cts-kt-equal/FAILURE_PLAN.md` / `verify.ps1`。既存出力を再使用する実行は拒否する。

本候補とexp-zeroは両方非採用。CTS/poolの局所内訳は改善箇所を絞る証拠だが、除算削減だけで速度改善は確定しない。次の調査はCTSの算術以外（Kernel構築、snapshot生成/認証）も含む実行量を区別し、状態保持契約を弱めず候補を選ぶ。
正式median<574.5624ms・CPU<=15%・独立holdout/categories・4native環境/製品APIと7-Zip総合超えは未達/未検証。製品・version・公開・stage/commit/pushは今回行っていない。
