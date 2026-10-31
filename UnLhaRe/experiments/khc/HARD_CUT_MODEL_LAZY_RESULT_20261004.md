# Model3 lazy-error：通常候補結果

## 結果

親の単回runnerは diagnostic-passed。compile1/native2、各exit0/stderr0。実行前のnormalized全文差分はModel3/codecpath1/scopepath1、adapter/probeはexact bytes一致。元ファイルを変更せず別private候補で確認した。

| 指標 | 今回 |
| --- | ---: |
| 内部圧縮単回診断 | 2114.141 ms |
| 内部展開単回診断 | 1998.692 ms |
| frame / header / payload | 478856 / 285 / 478571 B |
| 固定実peak WS / private | 54808576 / 51507200 B |
| selfcheck実peak WS / private | 15450112 / 12689408 B |
| 生成物2件合計 | 524686 B |
| 終了時空き | 58804961280 B |

前通常単回2327.9594/2201.5761msとの比較は参考に留め、因果的速度改善率・正式CLI速度・物理allocation数を主張しない。ソース上の成功時String評価を避ける変更であり、正常計算と拒否文字列は維持する。

固定plain全2811006Bを直接一致、同型Proof14全Eq、encode/decode全stats/前通常全statsとDebug一致。finite正常14/全byte roundtrip14/再圧縮frame14、破損34の厳密reason、短header4は旧E2E全JSONと一致。固定旧新全frame直接比較は今回なし、固定再encode0。前段別計測付き全frame証拠とは区別する。

## 再現・証拠

- runner SHA `6CA0D2032387391EA18E28A5B9DC12554CE97CD91AB4F119A8680BB1834E545F`
- `build/khc-hard-cut-model-lazy-20261004/report.json` 114574B、SHA `62B93E3FF942CEB13ECD6572DAD6CDBBE4DD45F88B72512E9348BBA4812BBEF3`
- EXE410112B、SHA `93A68018BC95F2731F3B42BAB8E943F299FE091616D6E0CF6D10001E7EF20D51`
- `hard-cut-model-lazy/verify-readonly.ps1` SHA `D5517175557E919A1324D91D27C9F9BF96B0D37577660536720BD0FD1B5F5D7F`

親readonly再照合exit0、149 before/after/live組（source18+identity131）、17edges/source108822B、raw2・E2E全文・stats/Proof・RAM算術・両実peak・2出力形状確認。追加compile/native0。rustc1.98.1、Windows x64、opt3/thinLTO/codegen1/unwind/overflowyes、wire_auditのみ。旧source/report/EXE/PLAN識別値はreportで固定。

worker-high要求/役割実効 gpt-6.1-sol/high、所有6filesはREADYで全停止・親へ返却。親がrunner実行とreadonly保存を担当した。製品dirty変更を保持、stage/commit/push/version/API/x86/外部/削除0。単体小出力、Cargo target追加・生frame/plain/inputコピー0、予算8MiB/空き5GiBの事前事後確認。

## 残る仕事

総合ゲート（size483599、fullCLI encode574.5624/decode47.3884ms、静穏warm1+9、holdout、完成書庫/API、4native）は未達/未検証。今回は正当性・容量条件のみ成功、製品採用や7-Zip超えではない。GOAL active。

次は現hardcutのCTS/pool/残り三bucket診断を優先する。旧CTS stage比率やfreshの旧opt2結果を現在の内訳として使わない。調査詳細はHARD_CUT_NEXT_HOTPATH_NOTES_20261004.md。計測版と通常版の速度を区別する。
