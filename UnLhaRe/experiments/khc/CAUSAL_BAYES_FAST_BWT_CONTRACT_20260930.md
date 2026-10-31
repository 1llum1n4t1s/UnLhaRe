# 同値BWTの単一改善 — 実装前failure-first契約

前段のdebug-info付き別pairは全frame483468B/SHA・復元が元候補と一致し、36checks/61CLI完了。fresh ETWは4980 target samples、欠落0、完全stack/lifetime/PE-PDB照合済み。BWT inclusive2452/4980 (49.24%)、CTS predict1250 (25.10%)、update502 (10.08%)、Bayes update190 (3.82%)。caller/calleeの比率を足さず、別debugpairを元opt3の壁時間へ読み替えない。旧minimal-PDBはsource-required解析で正しく拒否され、FunctionNameだけのnearest labelは原因証拠から除かれた。

## 一案だけを固定

byte+1/末尾unique最小sentinel、出力BWT/primary、grammar/primary/CTS/Bayes/packed metadata/range/CRCは不変。新研究directory `causal-bayes-fast-bwt/`にcodecの別copyとBWT moduleを作り、元候補のsource/modules/report/binary/traceは変更しない。既存moduleは相対path参照する。

1. 初期symbol stable countsortでSAを整列しdense rankを割り当てる。identity SAをそのままshiftしてはならない（入力0,1,0が反例）。n=1は初期classes==nで終了。
2. SAの旧順にj=(i>=step ? i-step : i+n-step)をscratchへ生成する。第2rankが整列済みになるので、rank[j]によるstable countsortを一度だけ実行する。再rankは第1rank/循環第2rankの対で行い、classes==nで終了してからstepをchecked倍増する。
3. 5本のn配列SA/rank/scratch/new-rank/countはu32、添字はusize。n<=8388609を明示しchecked conversion、filled allocation failure、sentinel先頭/primary一意を維持。追加n配列なし。理論配列本体は概ね44n→24n bytesで、OS peak/速度は実測まで未達。

一意最小sentinelにより2 suffixの大小は片方のsentinelまでに確定し、循環rotationのwrap後を読んで大小が変わることはない。完成rotation順は既存suffix順と一致する。途中rank/round数は変わってよいが最終BWT/primaryと全frameは完全一致しなければ不採用。深さ/prior/context/係数や他改善の同時変更、外部SAライブラリ/依存、SAIS導入、holdout、製品統合は行わない。

## 先に失敗条件

空入力/1byte/最初のsymbol-sort欠落/循環第2rank漏れ/stable性欠落、unique sentinel崩れ、step0/step>=n/倍増overflow、u32境界/入力上限超過、rank/count/sumの範囲、allocation失敗、primary欠落/重複、全frame/復元/反復決定性不一致、既存outputへの書込/失敗後公開を失敗とする。旧pair/report/source SHAを現在値へ上書きしない。

新unit testは追加しない。研究専用audit CLIを経由し小入力のBWT/primaryを独立suffix比較sortと照合する。empty/single0/255/0,1,0/banana/全256/反復/周期/固定seed混合/2冪周辺長を対象にする。small/固定groupは新旧の別process全frame byte一致・双方decode/再encode一致で照合する。8MiB境界は反復入力の新旧全frame比較を行い、上限+1は両CLIで拒否する。元の全36checks/61CLI破損/CRC修復攻撃/no-clobberも新directory専用harnessで再実行する。全group本文SHA・11entry名前/順序/長さ/本文を照合し、既知483468Bの全frame SHAを不変条件にする。

全E2E合格後のみfull encode/decodeの別process性能へ進む。warmup1+9測定、元opt3候補/新opt3候補/native11file7zを循環順で測定し、fullwall/CPU/OSpeak/privateを区別、前後hash/argv/exit/初回最終decodeを保存する。固定size<=483599B、strictfullencode<574.5624msは緩めない。局所改善はgoal達成ではなく、約88.36%の必要全体短縮と残るCTS等のコストを明記する。採取/buildとbenchmarkは非重複。

所有基点 `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-fast-bwt-20260930/`。新source/harnessと成果物はhash記録。生成物を記録し、用途終了後は安全確認して不要物のみ清掃、policy拒否済みの古い清掃対象には再試行しない。stage/commit/push/release/version、UnLha32Re/shared cache/registryを操作しない。独立役はsource/同値性/実際のE2E証拠を読み取り確認する。
