# lookup-float 新モデル自身の段階計測

## 目的と先行失敗条件

7-Zip総合超えの継続作業。凍結済みlookup-float-ctsの圧縮478750Bと完全復元を維持して、残る処理時間を帰属させる。以前のinteger CTSの割合を流用しない。この診断だけで改善採用・7-Zip勝利を宣言しない。

コード前に扱う失敗は、計時追加による数値演算順の変化、frame/Proof14/statsの変化、encode/decodeサンプル母数の不一致、親子計時の二重加算、ゼロ件層の欠落、入力や凍結sourceの書換え、出力容量超過、child無制限実行、PowerShell自動変数/aliasとの衝突。正常系の全frameと全plainの直接比較、Proof14とstatsの一致、件数とsample規則の照合で拒否する。少量入力・空入力でも同じ入口を通す。測定誤差と計器の擾乱は残るため正式性能値へ外挿しない。

## 所有権とスコープ

新規 `lookup-float-profile/` のみ実装担当一名が編集する。凍結済み `lookup-float-cts/` とそのreport/EXE/planは読み取り専用。製品・公開API・別版・Git操作・外部書込み・削除は対象外。編集はapply_patch。新Cargo target、PDB、frame/plain/input disk copy、raw traceを作らない。

## 計測契約

- component×prefixごとの1-based ordinalで、ordinal % 256 == 128を決定的に採取する。全件母数とsample件数をencode/decode両方で記録し、ゼロ件の層も明示する。
- 同じsampleのpredict親とCTS/pool子、observe親とpool/CTS子、coder区間を測る。親はinclusive、残余は親からその内側の子だけを引く。無計測区間をCTSへ誤帰属させない。
- 数値の順序・閾値・演算・snapshot・拒否順・auditを変えない。profile clock/counterだけの差を可視化する。モデル初期化とwhole encode/decodeも別記する。
- 同一process内でreferenceのframeをRAMに保持してinstrumented encodeと全byte比較し、両decoderの全plainを直接比較する。全Proof14・stats（entropy bits含む）も比較する。固定inputは既存all.groupを使い、複製しない。
- reference自身の数字との同等性確認を行い、profile比率を速度改善率へ換算しない。今回の基礎確認は新診断のreference同値経路で、製品全buildを再実行しない。

## 資源上限

実験生成物8MiB、EXE1MiB、report256KiB、source閉包300KiB、stdout64KiB、stderr16KiB。rustc compile60秒、native child120秒。disk-budget事前・事後、最終report保存後にも確認する。失敗の証拠は保持し、同条件の有利な再試行やparameter sweepをしない。

## opop観点台帳

Performance: 新モデルのstage attributionを親が採否判断。Hardening/Tester: instrumentation非干渉とbounded standalone E2E。Startup: constructorを独立計測。Modernizer: dependency/runtime変更なしで非該当。Normalizer: 新公開方式を導入せず非該当。Cleaner: 凍結証拠を削除せず非該当。Async: 同期private codecで非該当。Intel: 外部現在仕様に依存しないローカル計測で非該当。

## 次の判断

支配段が得られたら、その段を構造的に減らす候補をfailure-firstで検証する。snapshot再検証の削減やtransaction融合はまだ採用しない。固定サイズゲート・元の総合目標は維持する。
