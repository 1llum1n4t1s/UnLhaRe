# Bayes Q15尤度の同値表 — 実装前契約

## 対象と仮説

現採用研究基準はcausal-bayes-exact-div。現instrumented EXEのpayloadは経過時間share中央値70.15%だったが、log2だけの現CPU帰属は未測定。凍結bayes_model.rsは各bitで2つのcomponent Q15確率のlog2を計算する。このdiscrete domainだけをstream所有表に事前計算し、同値な参照へ置換する。速度改善は仮説であり、全CLI時間が改善しなければ採用しない。旧normal LZの確率遷移LUTとは対象と演算が異なり、旧no-goを上書きしない。

製品/既存研究source/既存proofを変更しない。新規causal-bayes-log-table/とbuild/khc-bwt-causal-bayes-log-table-20260930/だけを所有。CTS exact-div、BWT、grammar、Bayes posterior/exp2/混合順/Q15 rounding/初期prior/学習順、range、CRC、magic KHBAY001は維持する。

## 変更範囲・同値根拠

Q15 zeroは整数q=1..32767を32768で割った、f64に正確に表現可能な値。one=1-zeroも正確に(32768-q)/32768となる。32768-entry Vec<f64>をfallibleに確保し、index1..32767へ凍結式と同じ `(f64::from(q)/32768.0).log2()` の負値を格納する。index0は未使用0.0でlog2(0)を実行しない。要求追加容量262144 bytes、table生成時間もencode/decode/全CLIに含める。global/cache/OnceLock/共有状態なし、毎stream独立構築。

Predictionは更新前component Q15を保持し、混合は従来どおりf64へ変換する。bit確定後だけqまたは32768-qの表値を取り、primary次ctsの同じ順で `total -= log2value` を実行する。近似/f32/fast-math/FMA、加算の再結合、loss scale/clamp、予測器/depth/context/prior変更なし。constructorのみResult化しencode/decode両呼出元で?伝播する。q/classの既存拒否、finite/nonnegative loss検査は維持する。

この同値主張は同Windows x64/toolchain/数学関数実装での計算について。異なるOS/ISA間のlog2 bit決定性は保証しない。

## 先に列挙する失敗・E2E

- 表の0/32768誤参照、one index反転、全32767値どちらかbitで元式とf64 bits不一致。
- component Q15保存前後の違い、posterior/exp2/更新順変化、constructor片側未更新、stream state共有。
- invalid class>=7/bit>=2/q=0 or32768、奇数または6byte非整列、上限超過、argv、不正regular input、既存output上書き、失敗時公開。
- table割当失敗またはfinite違反。OOM/I/O故障注入を実施できない場合は未検証と明記する。
- frozen source/toolchain/input/proof/binaryの不一致または変化、frame/相互復号/CRC修復負例/11metadataの不一致。
- CPU totalの事前5回/各child前後>15%なら性能測定不成立。固定gateは緩めない。

数値audit CLIはrecord6bytes(class u8,bit u8,primary q u16LE,cts q u16LE)、最大65536 records(393216bytes)、empty許可。全入力を検査してから実Modelへ各recordでpredict→component log2取得→updateし、結果18bytes(primary log2 f64 bits u64LE,cts log2 bits u64LE,mixed Q15 u16LE)を保存する。candidateは実tableと実Modelを使う。referenceは凍結bayes_model.rsを直接module参照してModel predict/updateを使用し、監査用loss出力だけ元の直接式で計算する。別process/opt3/opt2の全binary列を比較する。全q×両bit65534 records、mixed/asymmetric/7classesの順序列と境界負例を含む。audit専用component取得APIはcfg限定し、製品/fullcodec hot loopへ診断を入れない。

全codecは旧36 checks/61 CLIの実E2Eを継承し、旧opt2とのcross-decode/frame、固定全483468byte/SHA B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A、no-clobber/上限/CRC修復攻撃/11entry metadataを照合する。新unit testは作成しない。数値およびfull proofの独立照合後、同一session candidate/frozen exact-div/native7zのwarmup1+9/各先頭3回、全process wall/CPU/OS peak/privateを測定する。表構築も除外しない。

固定開発group2811006 bytes/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、全archive<=483599 bytes、strict full encode<574.5624 msを維持する。局所改善採用と総合7-Zip超過は分ける。holdout/model sweep、新依存、Git stage/commit/push/releaseは行わない。成果proof/source/binaryと初回最終は保持、終了後の既知重複archiveだけ安全条件を照合して清掃する。
