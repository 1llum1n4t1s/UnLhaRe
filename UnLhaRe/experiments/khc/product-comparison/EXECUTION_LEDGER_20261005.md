# 製品ブロック比較の実行台帳

2026-10-05 Windows x64、Rust 1.98.1。外部公開・依存追加・バージョン変更なし。

## ビルド

共有 `build/cargo` を使い、次を実行。終了コード0、Release helper 263,680 bytes。

```powershell
$env:RUSTC='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
& 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/cargo.exe' build --locked --offline --release --target x86_64-pc-windows-msvc --example khc_block_io
```

helper SHA256: `DAB84057869264AAD41E1AE8BD4CB01B97EB604BDBBBCB636706F6AEEAC971C3`。
source helper SHA256: `A145F372F71E659C93BAEAFBCDBC08D2F6518D41CAEC6606195B111AA0B67D81`。
本番実行前の read-only preflight は38pins、native0/write0、前後同一。これはコンパイル証明そのものではない。

## initial: 比較基盤の故障

`build/khc-product-comparison-20261005/report.json` 12,336 bytes、SHA256
`D073B3CF4FC6C45ED4DC22A1F8D9C83881E8BA42F14A5FB84F579E82610E532E`。
native1、sample0、pipeline結果なし、全pins不変。
`status` プロパティ取得時に失敗した。性能結果として扱わず、元reportを保存する。

repair1は stdin非同期書込みの GetResult 戻り値を `$null` へ明示的に捨て、PowerShellの関数出力へ混入させない。
障害時のstack位置も保存する。codec・入力・比較設定・メモリ/時間/容量条件を変更しない。
元reportを上書きせず、別の固定suffix `-repair1` を使う。修正成功は実行結果まで未確認。

## repair1: command入口の故障

戻り値の修正後はchildの終了コード7を正しく保存した。
`build/khc-product-comparison-20261005-repair1/report.json` 12,672 bytes、SHA256
`E00C8BCF6B67989497BDD0B9225E8C8317E0E487DACE73BC012364C8097B1C2A`。
native1/sample0、`Cannot find archive name`。xz codec未対応を証明する結果ではなく、
stdout/stdin専用commandでarchive名解析を無効化していなかった。
repair2はLZMA2 encode/decode双方に `-an` のみ追加する。
辞書、レベル、スレッド、時間・RAM・入力・判定条件は不変。元2reportを保存。
Igor Pavlovによる説明：<https://sourceforge.net/p/sevenzip/discussion/45797/thread/5883b447a7/>。

## repair2: 正常往復・校正

status completed、650 rows（585測定+65暖機）、native1303、failure0、全pins同一。
report70,543B、SHA256 `CC6D7BFEFEFA10A628CBF131A45E3CA478C2D6AC7A79D3E4E6960A2EA707BD3A`。
実行357.31835秒。frame/rawのdisk保存0。
親の別helper compile（8.64秒）がこの試走中に重なったため、速度優位の根拠には採用しない。
これは入口・全byte往復・資源guardの校正記録として保持し、都合よく失敗履歴を除去しない。

追加したcurrent helperは `KHC0LAB Standard` を既存sourceのまま直接encode/decodeする。
Release2,870,272B、SHA256 `FC892BDF003FBA5440B9BCDFB3245F650AA69DCB87ED4745DDD1AFCE7F9361E5`。
build exit0、sourceは `examples/khc_current_io.rs`、buildコマンドは上記のexample名だけ差し替え。
dictionary1MiB/Range/max_output1MiB/memory64MiBとし、製品LHA公開APIの実測とは呼ばない。

次のfinal1は全helper build終了後、他のcompile/native診断を同時実行しない単独測定とする。
旧KHC Standardを同roundへ加え、圧縮後総frame・速度・process最大メモリをpaired比較する。
採用条件・入力・warmup1+測定9・quiet/上限を維持し、旧reportを上書きしない。

repair2のread-only verifierは初回、JSONの自動DateTime変換による末尾0の書式差と、
小数wait_msへ整数条件を誤適用したためinvalidを返した。
DateKind Stringでmtimeの元精度を保持し、wait_msの有限値・範囲検査（indices/件数は整数）へ修正。
親の実report再実行は errors0/complete true、native0/write0、65warm/585measuredを確認した。
この成功は修正後verifyのみであり、校正時間を最終性能へ昇格しない。
final1は1回の同round比較にcurrentを加える（780rows/1563native予定）。
runnerのbyte照合は長さ＋全byteの単射Base64文字列の厳密比較へ置換し、hash一致だけには依存しない。
比較処理はchild stopwatchの外側で、元の復元一致条件と計時scopeは維持する。

## final1: 最終採用測定

377.123599秒、completed、780往復（78暖機/702測定）、native1563、54pins同一、failure0。
report84,136B、SHA256 `18D68DFDB5C8DFBE3798412CDF61DFC7FFE49AC885BE9D46202958681A24C176`。
親のread-only verifyはerrors0/complete true。結果はRESULT_20261005.mdへ要約した。
型検査・追加回帰はこのnative測定の前後に行い、final1へcompileを重ねていない。
共通disk-budgetは最終実行中0B/8MiB、事後84,136B/8MiB、free5GiB維持を確認した。
native起動前のfree/path/source/pinチェックはrunner内のpreflight/本実行で確認している。
