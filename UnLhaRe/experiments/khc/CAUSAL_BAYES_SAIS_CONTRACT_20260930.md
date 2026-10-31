# 同値SA-IS BWT — 実装前failure-first契約

研究基準は凍結exact-div。signed mixture/log2表/float CTSは静穏性能比較待ちで、組み合わせない。exact-div由来の区間診断はBWT elapsed share中央値29.68%、payload70.15%だった。BWTだけで固定全時間を達成するとは考えないが、約1111msのBWT区間自体が574.5624msを超えるため、全配列を繰り返すprefix-doublingを減らす独立案は必要。これは既知のSA-IS原理を使った独立実装であり、新発明や7-Zip超過の証明ではない。前のMTF/Fenwickはモデルのsize no-goで撤去済み、本件はsize通過済みBayesモデルを一切変えずBWTだけの同値置換。

## 所有と変更範囲

新 `causal-bayes-sais/{codec.rs,bwt.rs,audit_cli.rs,verify.ps1,verify-bwt.ps1,compare.ps1,cleanup-*.ps1}` と専用 `build/khc-bwt-causal-bayes-sais-20260930/`、本契約と開発文書だけを所有する。codecは凍結exact-div copyからBWTをlocal参照、CTS/exact_divを凍結相対参照するだけ。BWT入力上限8MiB、byte+1/末尾unique最小sentinel0、戻り値Vec<u16>/primaryは元と同じ。grammar/全モデル/depth/prior/context/更新順/packed/range/wire/CRC/decoderは不変。第三者source/constants/libraryのコピーや依存追加はしない。Rust1.98.1/edition2024/opt3/panicabort/debuginfo未指定、auditはopt2も作る。新unit/製品/API/version/Git stage/commit/push/公開なし。

## 実装前に列挙する失敗

- 上限判定前の巨大割当て、長さ/u32/桶数overflow、不正sentinel/alphabet、non-fallible巨大reserve、空入力n=1/単byteの境界誤り、再帰が縮まらない/深さ無制限、配列外添字、panicを拒否する。再帰LMS数はn/2以下、縮約列末尾は唯一0、深さは上限で制限する。全scratchは呼出所有Vec、共有global cache/unsafe/pointerなし。
- S/L等値伝播、LMSのSかつ直前L分類、桶先頭/末尾、最初のLMS順/逆順挿入、L前向き/S後向き誘導順、EMPTYをsuffix0と取り違える、同じ桶再初期化漏れを失敗とする。
- LMS substring比較で終端LMSを含めない、型差/長さ差を見落とす、sentinelの次を読む、縮約名をsorted順ではなく元位置順へ戻し忘れる、同一名の再帰を省略する、unique-name逆置換が不正、最終LMS再配置/再誘導でsentinel先頭/全suffix順を崩す場合は不採用。
- 新BWT/primaryが独立直接suffix sortと異なる、全frameが凍結exact-divと異なる、反復/opt2が異なる、復元metadata/本文/CRC/EOFが異なる、旧破損拒否/上限/no-clobberを弱める場合は候補無効。正当なallocation failureはResultで返す。OOM/I/O故障注入・他OS未実施を成功と称さない。
- auditは入力regular/容量/argc検査後、実BWT関数を呼び、u32LE primary/count＋u16LE symbolsをcreate_new/write/syncする。I/O失敗時はpathを削除しない（外部置換ファイル誤削除回避、partial own output残存の限界を記録）。syntax/計算失敗は作成前、既存出力no-clobberを維持する。

## 実CLI E2Eと独立照合

別構造のC#直接非循環suffix比較oracleを小入力へ使用し、元prefix-doublingは巨大入力用の相互照合にだけ使う。空/0/255/banana/全byte/同値/周期/seeded random/2冪周辺、LMS substring長さ・等値名・再帰を誘発する小alphabet列を含める。audit opt3/opt2の別process同値、8MiBの反復と交互周期を監査CLIで旧BWTと全bytes比較、上限+1/argc/不存在/ディレクトリ/no-clobber拒否を確認する。最大反復の新旧全frame/decodeも確認。旧全codec36 checks/61 CLIを継承、fixed483468 bytes/SHA B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A、group11件全metadata/本文/EOFを維持する。別担当がS/L分類・誘導・縮約・終端数学とsource許可差分、実exit/provenance/raw/CRCを独立読み取り照合する。

証拠完了後だけ性能へ進む。凍結exact-div/native26.03とwarmup1+9/circular/39 CLI、fullwall/CPU/peak memoryを記録し、静穏observerを読込前lock、preflight5/子前後<=15%と固定total archive<=483599B/strict fullencode<574.5624msを維持する。他process停止・priority/affinity/power操作・設定/閾値の緩和なし。入力group2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、native11件/options/単一threadは不変。速度未測定の乗算削減・線形構築・理論scratchを実速度/OS peakや総合勝利へ読み替えない。holdout/複数カテゴリ/製品統合は別工程。

所有成果物を記録し、独立照合後に用途終了した反復のみ絶対LiteralPath/非reparse/終了process/hash保持を確認して清掃する。初回/最終/再現入力/proof/source/binaryは保持、旧policy拒否対象/shared cache/UnLha32Re/registryは操作しない。
