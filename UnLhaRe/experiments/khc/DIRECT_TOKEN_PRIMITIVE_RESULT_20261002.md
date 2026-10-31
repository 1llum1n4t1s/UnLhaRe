# direct token primitive: 数値・状態CLIの結果

PROGRESS。rank/lengthをbinary event列ではなくmulti-symbol intervalへまとめる新研究形式の下回りを実装し、独立oracleとの照合に成功した。既存の製品API、level0/4/5/6/7、旧研究format、過去の測定済み候補・契約・証拠は変更していない。7-Zip総合超えは未達。

## 観測した結果

| primitive | 各コンパイル条件の照合 | 結果 |
| --- | --- | --- |
| multi_range | u128 wire/slot算術750000区間、明示カウントされた拒否415、512 symbolsの別プロセスencode→decode | 4条件一致、fingerprint `4864b9047b217366` |
| CDF model | naive配列/逐次和/linear searchと393216更新、424319 prefix照合、1118306 count照合、918拒否 | 4条件一致、fingerprint `78eada9fb3f1fcc5` |

rangeはcarry14238回、最大保留3 byte、1MiB初期reserveを超えた1122173 byteのgrowthを確認した。normalize81852回は最初の200000区間のみの集計。CDFはalphabet16/256/257、13 keys、variable truncationを通し、root rescale45回/local rescale21回を独立oracleと照合した。拒否後の継続と全counts不変も確認した。heap allocation失敗の実注入は未実施。

compilerはRust1.98.1 Windows x64、SHA256 `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`。opt2/3 × overflow checks有無の4条件。これは4 nativeの確認ではない。CDFのsource/contract/guard/verifierを読み取り共有でロックし、実行前後の同一性を確認した。range側は実行時source識別と最終再照合であり、実行中ロックによる保証ではない。

## 証拠・容量

- `build/khc-direct-token-range-20261002/report.json`: SHA256 `3C15411EEA53B6F9E401BC4A0C692629F9B53140E56963F362FE3DC0851B95AE`。
- `build/khc-direct-token-model-20261002/report.json`: SHA256 `A3670F506550B6DA89878B840E7DCB63C770A5FD2F2BAFF3EC1CE19517FB3632`。
- 各生成先は4小EXE+1小JSONのみ。range695735 byte、model644239 byte、合計1339974 byte（約1.278MiB）。8MiBずつの事前・事後予算チェック成功。PDB/Cargo cache/raw trace/入力複製/復元ファイルを保存しないため、用途終了した一時ファイルの削除対象はない。
- `DIRECT_TOKEN_CONTRACT_20261002.md` の「2個EXE」は4条件4EXE保持の事前指示と不一致。immutable契約は変更せず、実数と差異を各reportへ記載した。rangeのfailure planだけ検証後に表記を統一したため、reportは実行時SHA `4D7FA1BEBE4BB0898BB6C237836DA50BBBB44F8AF96F205F766CD512E311F689` と最終SHA `D31950F685A3B3815F77C53260ED484F848988AC0F0FB1AC7F6D434750FE16F6` を区別する。実行source2件とverifier、8EXEは最終同一性を確認した。
- `git diff --check` 成功。無関係なDESIGN.mdのLF/CRLF警告は変更しない。既存入力・共有cache・過去proof・x86版を削除していない。

## 再現入口と未完了

指定bundled pwshで `direct-token/verify-range.ps1` または `direct-token/verify-model.ps1`。両入口はfresh固定root限定で、現在の生成先へ上書き・自動再試行しない。再現する場合は別の新契約・生成先が必要。child120秒、各stdout/stderr65536文字以下。

次は成功した両primitiveを別magic `KHNTOK01` のfull BWT/next-use rank/length grammarへ接続し、7入力のfull-byte復元、決定性、異常・no-clobber、完全frameサイズを検証する。full生成予算は先に見積もる。primitive成功だけで圧縮率・速度の向上を主張しない。固定483599B/574.5624ms未満/CPU15%/warmup1+9測定を維持し、過去terminal候補や確認待ちobserver変更を再実行しない。holdout/カテゴリ、同境界decode、4 native、製品/API安全性・統合は未達のまま。目標はactiveを維持する。
