# split商推定のcodec統合条件

split-estimate-quotientの数値E2E、独立監査、実生成コード診断が成立した後に限り実装する。通常small枝でsigned変換だけ、wide枝は別関数呼出という狙いが成立しなければcodecへ入れない。

## 失敗条件

- module参照違い、guess分離以外の数値/model/wire変更。
- opt2/3/反復/旧候補frameが不一致、相互復号できない。
- 既存63checks、異常系CRC/cap/no-clobber/保持/状態分離やreadlocksが欠落。
- 数値CLIとcodecで生成コードが違うのに省略成立と断定。
- CPU guard不成立や部分samplesを速度採用に使う。

担当一人が新 `causal-bayes-q32-split-lut/{codec.rs,cts_model.rs,build.ps1,verify.ps1}` を所有。旧inline LUT候補codec/CTS/build/verifyを再利用し、codec CTSをlocal、CTS商moduleを凍結split helperへ向けるだけ。ratio wrapperのinline(always)を維持し、Bayes表/SAIS/grammar/model/cap/errors/wireは不変。新numeric proofとsource、旧inline build/full proof/source/EXEを固定readlock。

新root `build/khc-bwt-causal-bayes-q32-split-lut-20261001/`、Rust1.98.1/edition2024/panicabort opt3/opt2。旧63checksを保ち、旧inline EXE SHA `02C7D3D132DFD664CEA7BE643CDB0A5200583D5583AE101C715CC59FEF703083` との7small＋fixedframeの全byte一致と双方向decodeを追加。生成fixture/既存output/全source/EXE/proof beforeafter locksを維持、非zero/timeout/ownedtmp0を確認、新Rustのみskip_children fmt/Parser。数値CLIのflags変更をcodec出力変更に混同しない。

親は契約/新compare/codec生成診断/記録を所有。数値・実装担当と別の文脈でsource差分/旧check包含/全raw/全pins/計測7helpersの独立確認を行う。製品/API/単体テスト/x86/CPU設定/共有cache/既存source/Git/version/外部書込は不変。4native/holdout/OOM/IOfault/総合性能をWindowsx64 E2Eで証明したとしない。

固定group2811006B/SHA18B8...、全frame483469B/SHA7584...、archive<=483599B/strict fullCLI encode<574.5624ms、quiet15%/warm1+9/circular/nativeoptsを維持する。inline枝の局所14.13%削減は証拠だが研究全体SAIS基準への昇格や総合7-Zip超過ではない。
