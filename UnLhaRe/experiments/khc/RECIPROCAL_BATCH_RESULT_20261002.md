# 逆数補正posteriorの数値・full codec結果

compact posteriorのAVX2商推定を、4double除算から4float逆数初期値・元double分母によるNewton補正2回・numerator乗算へ置換した。integer certificateと上下補正、失敗時の既存厳密fallbackを維持し、legacy divide/scalar/KT/BWT/学習・書庫形式は変更していない。これは速度改善を狙う実装候補であり、正式速度や採用の証明ではない。

## 実行した確認

| 経路 | 実行結果 | 証拠 |
| --- | --- | --- |
| 独立u128商と逐次照合 | 32確認/87CLI/28識別レコード。opt2/3×scalar/AVX2の4条件で各9293629 record、2323408 batch。tail1/2/3、混在lane拒否、独立BigInteger14条件も成功 | build/khc-reciprocal-batch-20261002/report.json |
| 完全codec | 51確認/86CLI/466 unique identities。既存841レコードと数値28レコードを前後照合。7入力×4条件で圧縮frame・第1 stdout全行・復元が既存結果と一致 | build/khc-reciprocal-codec-20261002/report.json |
| 相互運用・異常系 | 各入力の旧integer decoderとの双方向復元、不正fixture5種類、encode/decode no-clobber、欠落入力の拒否に成功 | 同full reportのchecks/invocations/compared_output_records |
| 実kernelの経路 | counted encode/decodeの全stdoutが既存結果と一致。compact groups12892624、fallback groups0、Node12B、light prediction24B、scheduler prediction608B | 同full reportのcounted invocations |

数値summaryは旧proofと全フィールド一致。compact適用8398832、certificate fallback0、fingerprint `f02dbdcb00adbe1d`。戻る商はchecked整数余り条件で確認するため近似値そのものを正解としない。有限suiteの適用件数/一致を全入力の速度や四native実証へ拡張しない。

固定corpus2811006Bとframe483496Bの実byte一致を確認し、サイズ上限483599Bを満たす。frame SHA256は不変の `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`。計測時計を使わない検証なので、kernelや全CLIが速くなったとはまだ判断しない。

## 識別値と再現

- 数値契約 SHA256: `F5470A66960B07EA6C4C79938218438DBFBF4B5B536110BB082C14563BAF84EB`
- kernel source `reciprocal-batch/exact_div.rs`: `E9A073E15A62D6ACFD4740E847ECB34A4A93F7FCE53AD6EE7F1E4972089FB45D`
- 数値verifier: `1775800BA20D8F11285DB5DFCCE6028B6DB16DBA216DFB938DB7D6A9640D286D`
- 数値report: `A58898BA7716CE836B921FA04E3152718BB5D96B53FA279EC5EB27FAD69D3DD4`
- full契約: `3018755158AD075547CFB8C1753E76A678714C83CE4646500F2C387876B80306`
- full verifier `reciprocal-codec/verify.ps1`: `B97B7DBCA1D6BE7B0A80826BD4593CB0BED3934C30A6EADBA9F00F0C46AA7420`
- full report: `22C7D3364743D2FD962A330BCA5EC9BBE2DF4EC6E1603F8BB4ED655FE0D645BE`
- native codec241152B: `7DCB3AC8CD16139D48483FEE8FB2078902EAB7DF3AE0912F33A843F40714944B`
- full実行UTC: 2026-10-01T21:25:41.6766529Z ～ 21:26:28.7898949Z。runtime/compiler/CWD/CPU/source対応と全argvはreport内。

保存EXE・shared inputs・golden frames・reportを保持した。検証器はfresh root限定で既存rootを上書き・自動再試行しない。再現する場合はreportのargvと保存EXEを使用し、出力名だけ別の明示したfresh出力先へ変更する。scratch出力の復元・圧縮結果は、各CLI終了後に64KiB逐次比較とhash/bytes/比較相手を72件の台帳に残した。うち固定native frame以外の71出力はexact owned scratch pathを確認してRemove-Item -LiteralPathで削除した。旧証拠や共有cacheは削除していない。

## 容量と次の工程

数値出力368059B、full出力2008051B、合計2376110B（約2.266MiB）。fullの検査済みピーク4986830B（約4.756MiB）で8MiB予算内。5つのcodec EXE、固定native frame、2つの小no-clobber sentinelとreportを保持。復元複製・Cargo/cache・PDB・raw traceは残さなかった。既存fullでは全条件の復元を常時保持していたが、今回は検証時に逐次比較し、再現可能なEXE/入力/frame/台帳だけ残した。

次は本候補を正式比較へ接続する。CPU15%・全CLI encode median574.5624ms未満・warmup1+測定9・single-thread・サイズの固定ゲートを維持する。計測器初期化の分離についての確認待ちは実行せず、旧候補terminalを再試行しない。正式性能とholdout/カテゴリ、同境界decode、四native、製品/APIの組込み・安全性は未達。7-Zipの総合超えは未達でgoalはactive。

命令仕様の確認には[Rust公式の逆数intrinsic](https://doc.rust-lang.org/core/arch/x86_64/fn._mm_rcp_ps.html)と[Intel命令仕様](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2b-manual.pdf)を使用した。近似値しか得られないことを前提に、浮動精度の想定からinteger certificateを省略する設計にはしなかった。
