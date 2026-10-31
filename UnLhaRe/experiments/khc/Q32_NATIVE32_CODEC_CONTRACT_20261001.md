# guarded64/32商の全codec接続と反証条件

前提: 数値helper proof `DF1FCBAA5884D8DB2B7234F5DF7A0356C1C3A5D198204929DEDB1F9C836EE656`、Model proof `89C9D6773D95A281C01437BB4653DE50B4716638A2F597AD13467B2CFA347B58`（57checks/54CLI/95current identities/11267records/4EXEs/layout一致）。速度未測定、元cloneの非標準書式は保持し新helperのみfmt検査済。

親が `causal-bayes-q32-native32/codec.rs,verify-codec.ps1` を所有する。codecを元balanced codec SHA `9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B` から全文一致でcloneする。CTSと新helperはModel検証済の凍結値を使用し、新audit cfgを通常codecへ入れない。ed2024/panicabort/opt3の通常版とforcedportable版を新root `build/khc-bwt-causal-bayes-q32-native32-20261001` へcompileする。

失敗条件を先に固定する:

- source/contract/compiler/直接親proof/使用した旧raw・入力・旧EXEの長さSHA/current hold又はafter照合が欠ける。audit cfg混入、source全文コピー差分、compile失敗、120秒子期限超過。
- empty/single/all_bytes/repeated/periodic/seeded_random及び固定2811006B groupの通常版・forcedportable版・凍結balanced EXEの書庫全byte又はCLI Statsが異なる。全復号内容が入力と異なる。固定frameが483469B SHA7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95Cと異なる。
- 新版が旧版frameを、旧版が新frameを復号できない。通常版同入力反復の全frame不一致。
- 誤magic、header CRC、payload CRC破損、末尾追加、truncationを受理又は出力公開する。既存outputがencode/decodeで置換される。所有一時物残存、current identity変更。

CLI/全frameのE2E evidenceを保存する。旧87項目の全面監査を新たにしたとは称さない。今回のE2Eは商差し替えの実経路と代表破損/公開安全性へ限定し、旧検証の削除・弱化・製品安全性保証には用いない。codecは元研究用のCreateNew公開を保持する（製品の親handle/CRC後公開の検証とは別）。失敗root保存、既存root拒否、自動retryなし。

速度採用は別のquiet/fullCLI/同session比較が通るまで禁止する。固定size<=483599B・encode<574.5624msのgate、native7za26.03設定、holdout・decode・peak memory・4環境native・製品統合・総合7-Zip超えの完了条件はそのまま。新unit/Git/公開/CPU設定/x86作業なし。
