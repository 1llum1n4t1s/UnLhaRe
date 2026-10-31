# Q32 商推定・整数補正の先行検証契約

2026-10-01。総合7-Zip超過の固定ゲートは変更しない。本工程は数値処理単体の実CLI E2Eであり、速度採用・製品変更ではない。

## 実装前の失敗条件

- 真の整数商との不一致、推定の丸めをそのまま数値モデルへ返すこと。
- 分母0、乗算overflow、無効レコード、入力長・argc・上限違反の拒否漏れ。
- 2^53/2^64近傍、Q=2^32近傍、商の境界、推定積overflowでpanicや誤補正。
- 残余の証明なしの返却、補正失敗時に近似値を返却すること。
- 同一入力のopt2/opt3、別プロセス間の不一致。
- 既存出力の上書き、失敗時の部分公開、source/input/exe/compilerの変化。

## 許可範囲と所有

`corrected-quotient/` の新しいhelper、CLI、検証harnessのみを実装担当一人が所有する。凍結Q32、製品src、既存proof、比較条件、version、Gitは変更しない。成果物rootは新しい `build/khc-corrected-quotient-20261001/` のみ。単体unit testは追加しない。

## 計算仕様

元のratio同様、分母0はerror、a*bはchecked u64積でoverflowをerror。分母Qは積>>32。その他はbinary64で積/分母の商を推定し、checked整数積を用いて高々一回ずつ下方・上方補正する。成功して返すための条件は整数で `q*d <= N` かつ `N-q*d < d` の両方を証明できること。証明できない場合は必ず元の `N/d` へfallbackする。したがって正しさはbinary64誤差境界の仮説に依存しない。速い対象範囲は1<=d<=Qと想定するが、汎用helperの域外もfallbackで正確に処理する。

診断CLIは各recordの商・補正種別・fallbackを返し、harnessは別のC# BigInteger oracleで全recordを比較する。0分子、最大u64、2^53周辺、Q周辺、d=1/Q/Q-1、q*d±1、元KT/alpha/posteriorの境界、決定的seedの有効積を含める。異常入力も実CLIで拒否を確認。正常レコードを一括事前検証し、出力はcreate-newで公開する。

## 検証・保持・後続

compilerは凍結Rust1.98.1の絶対パス/SHAを固定し、edition2024、panicabort、opt2/opt3を別EXEとして比較。所有childには120秒上限とfinally停止、input/source/compiler/exe/outputはreadlockと前後SHAを記録。実行結果・独立oracle・raw入出力・識別子をreportへ残す。必要な再現成果物は保持し、backupや反復コピーを作らない。

この工程の成功だけではCTS状態・全frame同値・4ネイティブ環境・性能は未検証。次のcodec候補は数学確認と数値E2Eの回収後に判断する。Q32元frame483469Bの同値を将来の条件とし、固定time574.5624ms未満を緩めない。通常比較のquiet-host条件を本診断へ流用して性能を主張しない。

## 公式資料と推論の境界

[Rust数値cast仕様](https://doc.rust-lang.org/reference/expressions/operator-expr.html#numeric-cast)は整数→浮動小数点のnearest/ties-even、浮動小数点→整数のtoward-zero/saturationを定義する。[f64](https://doc.rust-lang.org/std/primitive.f64.html)はbinary64。推定誤差の詳細な上限は別途独立に確認する。返却前の整数証明とfallbackはその上限によらず維持する。
