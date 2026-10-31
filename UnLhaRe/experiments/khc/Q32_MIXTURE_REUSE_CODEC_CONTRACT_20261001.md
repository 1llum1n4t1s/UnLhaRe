# 混合再利用のcodec検証条件

最終-model-layout数値証拠のsource/raw/pins独立確認後に、同じ凍結CTSを通常cfgでcodecへ組み込む。中間numeric proofはsource変更前の履歴であり採用証拠にしない。

## 失敗条件

- audit専用cfgを通常codecへ付ける、helper又はmodel仕様/wire/SAIS/Bayes表を変更する。
- weight snapshotの配列copy/分岐の追加で遅くなる可能性を無視する。
- 元71checks/130CLI、拒否理由/既存出力保持/CRC後公開/決定性/状態分離/readlocksが欠落。
- 旧splitの7small+fixed全frame byte一致/相互復号を省く。
- 数値greenだけでcodecの配置や速度を証明したとする。

親が新causal-bayes-q32-mixture-reuseのcodec.rs/build.ps1/verify.ps1だけを所有し、既存数値担当の凍結3sourceを編集しない。codecは旧split codecと全byte同一のlocal CTS参照を維持する。build/verifyは旧split入口をcloneし旧pinsをすべて保持、新CTS/数値CLI/数値verify/最終numeric proof・契約、旧split build/full/candidate/fixed frameを追加pin/readlockする。数値proofの全identities/input/oracle/rawも検証中固定する。

numeric proofはbuild/khc-q32-mixture-reuse-numeric-20261001-model-layout/report.json SHA BFF074A286B71CA770059B4CD87B1037A982EC7B28A1BD48378F5E9914E45C72、CTS BBD229E9B8E787618472E66421EF5E38E0BCBBB63B761575032892C3EDBE98E2、99checks/103CLI/65536helper/11267Model/7class17levels/Prediction544B・Node16B。codecはaudit cfgなし、Rust1.98.1/edition2024/panicabort/opt3・opt2、新root build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/。

旧71checksをすべて包含し旧split7small＋fixedの全byte一致/双方向復号8checks/24CLIを追加する。期待79checks/154CLIを実数で確認。全frame483469B SHA7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95Cと固定size483599以下、元strict574.5624msは維持。beforeafter pins/ownedtmp0、Parser/newRustskip_children fmt、別担当のraw/source監査後に性能比較へ進む。

速度は旧split対照・nativeを同sessionで測り、quiet15/preflight5/全child前後/warm1+9/circular/nativeopts/全CLI時間・表構築込みを維持する。中間版helper時間、過去のfailed split性能session、静的乗算削減数を採用値に転用しない。製品/API/x86/単体テスト/Git/stage/commit/push/version/CPU設定/共有cache/外部書込みなし。4native/holdout/総合性/製品採用はこのWindows x64検証だけでは完了しない。
