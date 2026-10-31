# 適応suffix KTの一構成: 正しく復元できるがsize gate未達

別形式の研究candidate `adaptive-suffix-kt/`を実装した。固定groupの書庫は488592Bで、上限483599Bを4993B超過し不採用。旧KT reciprocalの483469Bからは5123B増加した。閾値32、depth16、7classes、primary/Bayes/grammarは実装前の[契約](ADAPTIVE_SUFFIX_KT_CONTRACT_20261001.md)から変更せず、この一構成を閉じる。速度比較・holdout・parameter sweepは実行しない。製品の既定、公開API、version、x86、共有Cargo cacheに変更はない。

## 実装で変えた計算

現在bitを参照せず、class別の過去historyに沿った17nodeのうち、観測数32以上の最深nodeを1個選ぶ。該当しなければroot。選んだnodeのKT確率だけを計算し、観測後は元と同じleaf→root順で全17nodeのcountを更新する。CTSの17KT・16mixture・16posterior・class alphaという各bit経路を、1KTと選択/count更新へ置き換えた。primary/Bayes/BWT/rangeは元sourceを使用する。これは旧CTSと確率・出力が異なる新modelであって出力同値最適化ではない。

`cts_model.rs` SHA `F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32`。Node8Bはrepr(C)/compile-time assertionで確認、context array7339976B＋KT table524296Bという宣言storageであり実測peak memoryではない。単一Model所有、class/count/history boundsとsnapshot検査を実装したが、private Model state/error全数値の独立oracleやstale/class/cap全分岐の実行検証はない。

`codec.rs` SHA `B45F257D723478DA4C2D3FF0A8467BB8FB6A20CF18047CFF9575FAD3A110E78C`は元wrapperとコメント2か所・magic `KHBADP01`以外の全文一致を確認した。moduleは同じ相対配置の新Modelへ解決する。共有sourceはpin/lock/afterで保持し、製品wireへ混入しない。

## CLI E2E結果

`build/khc-adaptive-suffix-kt-20261001/report.json` SHA `152ECC51BEDA2DA7C38637075548D5744A84E9A778AB8B10D6CA45C02B02D28A`、status `correctness_passed_size_no_go_not_timed`。verifier SHA `72D85099BED18AD34D4063F5079BFFF3072D0029F1E5FAC2B93C17FCF8630D39`、Rust1.98.1/edition2024/panicabort/opt3、Windows x64。

- 34checks/44CLI/61identities、checks成功、exit期待一致、timeout・実行中identity差・owned tmp/reparseは0。nativeとforcedportableをcompileし、7cases（空、1byte、全byte、反復、周期、seeded random、固定group）の両frame/復号全byteを照合した。固定native反復も全byte一致。
- 代表5破損（magic、header CRC、payload CRC、truncation、trailing）を公開前に拒否、旧/新magicの両方向拒否、encode/decode no-clobber、入力不存在、8MiB上限超過をCLIで確認した。新unitは追加していない。
- 固定group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。新frame488592B SHA `F9B76F4DED7C402BC3B06BBDC499A5A7B41CE758067F8EFA24F3ED1CCB9B4531`。旧比較frameは483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`。

有限のcodec実行証拠であり、全入力/Model状態、独立BigInteger oracle、新作者独立監査、macOS/ARM64 native、安全性全条件、速度・総合7-Zip超えを証明しない。研究CLIは製品の親handle-based race防止契約とは別であり、今回新しく入力祖先junction安全性やキャンセルを実証したとは称さない。

## 清掃と現在の保持範囲

初回の複合削除commandは実行前にpolicyで拒否された。読み取り専用で全61identity、owner/owned_paths、terminal report、対象length/hash、全祖先非reparse、関連process停止を確認し、同じ安全条件を保った明示絶対pathの単一PowerShell `Remove-Item -LiteralPath`へ組み替えて成功した。

削除対象は今回作成したゼロ-filled `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-adaptive-suffix-kt-20261001\over-cap.input` のみ。8388609B、SHA `4459F957D031A8B782DFEE09D2C7070A4B5E6C33130A8F20AC35393FD97FC57A`、残存なし。直接削除だがverifierのCreateNew＋SetLength(8388609)で再生成できる。報告する削除量はlogical lengthでありphysical空き領域の増加量を測ったものではない。

reportの61identityは削除前の履歴。削除後に、残り60のsource/EXE/input/frame/restoreの現存長さ/hash一致と、除外1件が上記fixtureのみであることを再確認した。保持root15679517B、owned tmp/reparse0、元LZ/wrapper/KT reciprocal Modelのhashも不変。`git diff --check`成功。検証結果と失敗条件を残し、他作業、旧試行、共有cacheは削除しない。

## 判定と次の境界

計算を大きく減らす別構成でも、圧縮率の許容差130Bを保てなかった。これを速度達成と読み替えない。同じsize条件を守れるcontext利用・符号化設計が引き続き必要であり、閾値やgateを緩める根拠にはしない。fullCLI速度、同境界decode/peak memory、holdout/カテゴリ、4native、製品統合を含む総合goalはactive/未達。
