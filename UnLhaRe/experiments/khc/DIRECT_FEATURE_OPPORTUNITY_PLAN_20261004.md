# directモデル損失の帰属と欠落featureの限定診断

## 次に変える判断

static-direct-mdlは予算642170Bで不採用。metadata/reserveを無料にしても626045B。headerやcoderだけを変更する大型実装を避け、rank/length別の損失と、現lookup-floatモデルのglobal/symbol/recent/jointに相当する情報の欠落を定量化する。一候補の再試行やparameter sweepではなく、次のモデル設計を選ぶための同一入力の診断。GOALと固定size/速度/資源/holdout/製品/4native条件は維持する。

## コードより先の失敗条件

static frozen report/header/source pins差、input/BWT/run/grammar/countsずれ、run更新前のhistoryを更新後と取り違える、sentinel/初期/terminal/escapeでfeature誤り、rank0のsaturating exponent誤り、length escapeからactual長さを復元できないのに推測する、branch node付きhash keyと新direct非hash featureを同一視する、sparse count/row sum/quantization/bit費用のoverflow、prefix/zero freq/finite loss違反、component合算不一致、training-only推定をholdout/実サイズ/速度/最適下界と呼ぶ、naive header費用を実serialized費用と呼ぶ、memory見積り/timeout/出力予算超過、trace/frame/plain/input copy、失敗や旧証拠上書き、有利な再試行。

## 固定診断

1. 凍結static model-headerをparseし、凍結Front同一runsのscoreをrank/length別Kahan合算する。合計を保存5000107.114226128bitに絶対差1e-6bit以内で照合、runs889227/token1778454/escape742/primary1762795/grammarを照合する。新frameは生成しない。
2. 四つのfeature familyを一つずつ集計して、各々一つのsparse `(key, token)` histogramだけを保持する。family数/式は事前固定：global=(component<<4)|context、symbol=(global<<9)|symbol、recent=(global<<16)|recent16、joint=(global<<18)|(symbol<<9)|(previous_rank_exponent<<5)|previous_length_exponent。key最大bit幅は5/14/21/23。rank context0、length context=exponent(rank+1)。previous exponentは旧run_doneのexponent(rank.saturating_sub(1))/exponent(actual length-1)、recent16は旧run_doneのlast4 nibbles(rank.min3 | actual length class<<2)。初期すべて0。現在token前の値を使い、length処理後だけ更新。actual lengthは保持runsの当該runから取得する。旧branch nodeとhash衝突はこの新direct featureでは省かれており、既存expertの再現ではない。
3. histogramはchecked u32 counts、sorted集約rowへ変換し、元mapを破棄してからscore。元のcountsと量子化CDF prefixを使うempirical/truncated lossとQ32768 Hamilton lossをrank/length別に記録する。全counts/rows/cells/tokens/escape合計を照合。これは同じtraining入力の楽観的機会診断で、汎化・実codec・entropy最適下界の証明ではない。
4. 保存費用は仮の完全sparse model（row count32bit、各rowに固定key幅+used count9bit+sorted IDs9bit×used+明示freq15bit×(used-1)）の式を集計し、ceil後framing285/model-bitlength4/escape742/reserve2048を別欄で加える。モデルを実serializeしていないため『naive modeled metadata』として扱い、予算内でも成功候補としない。多数のsingleton contextがtraining lossだけを減らす過学習を、cells/rows/metadata費用と一緒に示す。

## E2Eと資源

新 `direct-feature-opportunity/` だけを編集。失敗一覧を先に保存し、historyの初期/前後更新/length bucket・terminal、keys最大/境界、counts/rows/sort、quantization prefixについて小さなhand-sequenceのE2E入口を作る（新unit testsなし）。固定inputは一度だけRAM read/BWT、runsを再利用。新feature historyを凍結scannerのprevious rank/length bucket/contextと逐次照合する。旧全frame/plain比較は前screenの実行済み証拠であり今回再実行したとは呼ばない。

単一familyのtoken events上限1778454、集約cells<=token events。HashMap/集約vectorは同時保持の必要性を見積もり、familyごとに破棄、容量/cell/row/working RAM見積りを報告する。生token sequence/rawtraceのRAM Vecやdisk保存は作らない（histogramは集約count）。peak RAMは実測しない限り推定として区別。実装前に最悪見積りが160MiBを超える場合はsourceでbounded方式を見直す。別大corpus/新Cargo targetなし。

新build/khc-direct-feature-opportunity-20261004未使用必須、8MiB全出力、EXE1MiB/report256KiB/source閉包300KiB/stdout64KiB/stderr16KiB、compile60s/native120s、rustc単体opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE。source/tool/input/static report/header/plan前後pin、最終report後disk guardとowned process0。設定/depth/sweepなし、既存target/PDB/copy/削除/Git/外部書込み/製品変更なし。

## 担当と観点

編集停止確認済みfloat_stage_profile_implを同じ性能研究の診断担当として再利用し、新rootと新buildだけ所有させる。parentはplan/既存decisionと採否を所有。Performance/Hardening/Testerは損失帰属・範囲・全件比較、Normalizerはkeyと保存費用式の一貫性、Modernizer/Cleanerは依存/製品整理なしで非該当、Async/Startup/Intelは並行/製品起動/外部coder未実装で非該当。新context独立監査は未実施であり再利用担当の自己確認で代替したとは言わない。
