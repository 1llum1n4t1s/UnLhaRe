# inverse BWT packed23：等価内部layoutの限定診断

## 根拠と採否条件

BWT_INVERSE_GATE_QUESTION_20261004.mdの問いを一候補で反証する。旧単発inverse123.3028msは正式値でも新opt3下界でもない。参照と候補を同一opt3 EXEで全内容比較し、配列縮小と処理時間を実測する。製品・wire・metadata・frameサイズ・モデル・encodeを変更しない。限定inverseが47.3884msを下回っても全decode/7-Zip総合達成ではない。前causal診断は凍結し再試行しない。

## コードより先の失敗条件

参照bodyの無許可変更、frozen codec/BWT/tool/input/source/plan pin差、packed bit重複、index23bit境界、primary/sentinel/0byte/255byte/空plainの混同、prefix/alphabet欠落、LF短cycleを見逃す、n訪問のunique証明不成立、direct result index誤り、n>2^23で対応長を切り捨てる、referenceとplain/拒否差、出力/timeout/RAM上限超過、timingに比較処理を混ぜる、有利な順序/設定/反復選別、単発旧time/限定比較を正式全CLI・decode gate達成と呼ぶ。

## 固定実装

参照は凍結lookup-float-profile/codec.rsのfilledとinverse_bwt関数をそのまま新reference.rsへ抽出。公開visibilityを付ける以外の全body bytes同値をallowlistで証明（元sourceのdiskコピーは不要、抽出本体だけは比較用source）。旧codec/rootは編集禁止。reference bodyの全配列/全guardを保持する。

候補はn<=2^23で一行u32：bits0..22=LF next、bits23..30=元byte(s-1)、bit31=visited。sentinelは検査済みprimary rowだけなのでそのbyteはdummy0。次index<nとnext mask、byte0/255、visit flagをchecked検査する。counts/sentinel count1/alphabet presence等の前提を維持してpackedを構築する。walkerはn回、row範囲/訪問済み拒否、mark後LFへ、step>0のみresult[n-1-step]へbyteを直接書く。最初にsentinelを訪れ最後primaryへ戻ることを確認する。n個の異なるrowがすべて[0,n)なら全row訪問が含意されるので別visited全scan/text配列を不要にする。結果の意味を切り替えない。

n>2^23では参照usize実装へfallbackする。現private codec上限8MiB plain+sentinel（n<=8388609）を維持する。大入力でpackedへ強制castしない。private診断のraw alphabetが256を超える場合は両入口の共通wrapperで先に拒否し、参照本体を変えず、既存の検査済みheaderと同等の呼出前提へ限定する。このwrapperの拒否を旧inverse内部の動的成功とは呼ばない。

## 実装前E2E一覧

- empty/plain1、0/255混在、全256byte列、反復/交互/決定的非反復列（数KiBまで）は凍結BWTで生成しreference/packedの全plainを元inputへ直接比較。plain/result/inputをdiskへ書かない。case/length/seed固定、範囲をfailure planへ先に保存。
- empty last、primary>=n、primary非sentinel、sentinel0/複数、symbol257、alphabet不足/余分、短LF cycleのhand不正last（例[0,1,1,1] primary0、[1,0,1,1] primary1）を両入口で拒否比較。alphabet out-of-rangeは共通wrapper拒否と分離する。
- n=2^23-1/2^23/2^23+1はRAMだけでsynthetic valid BWT `last[0..n-1]=1,last[n-1]=0,primary=n-1,alphabet=[0,1]` を生成し、全resultが0、全reference/候補result一致、packed/fallback routeを照合。巨大BWT forwardを作らない。期待byteのために別巨大plain Vecを作らない。mask/index/byte255/visit bit最大は小さなhand packingも比較。新unit testsなし、bounded入口のE2Eだけ。

## 固定入力と限定計時

固定all.group2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一度read/BWT（小hand forwardとは別件数）、last/primary/alphabetをRAM再利用。inverse出力を全byte比較し、上書き/既存frame生成をしない。

同EXE reference/packed各warmup1、9pair計18計時call、pair順は偶数reference→packed、奇数packed→referenceに事前固定。比較/集計/JSONは計時外。各callはallocate/init/guard/walk/freeを含むfunction全体。全raw18samplesを小JSON配列に保存しmedian/両順別値を報告するが、CPU quietを確認しない場合は正式比較に使わない。candidate timerは実配列構築/破棄を省略しない。第一sampleの低速だけで改善率を誇張せず全値を残す。elapsedはinverseだけ、BWT/entropy/header/API/fullCLIを含まない。

ここでfreeはfunction内のscratch LF/visited/textまたはpacked arrayの破棄を指す。戻りVecの構築までが計時内、その全plain比較と呼出元でのdropは両方式とも計時外。測定のために結果を比較前に破棄したり、片側だけ出力破棄を含めたりしない。

fixed timingsを先に、巨大boundary E2Eは後に実行し、巨大fixtureのallocator/cold影響を意図的に固定比較へ混ぜない。原則一compile/native（失敗保持、追加実行は親判断）、単一setting/sweep0。

## 資源と所有権

新packed-inverse/と未使用build/khc-packed-inverse-20261004/だけを再利用担当が所有。親はplan/decision所有、旧全evidence/rootはread-only。コード前FAILURE_PLAN、reference抽出ledger、環境/source/tool/input/plan前後pinsを保存。capacityが取れた配列値とlogical推定/実測peakを区別する。fixed reference作業約12n、packed約5n。boundaryでlast2n+保持reference result(n-1)+新reference作業12n+4MiB余裕で約130MiB以下、BWTは別phase141598926B推定。実装前の同時live最悪を再計算して160MiB以内。大caseは一つずつ破棄、last/出力/期待plainの余計なcopyなし。

可能ならnative終端にWindows GetProcessMemoryInfoで当該nativeのpeak working setを読取り記録（計時外、一回、任意外部依存/常駐processなし）。API追加はsource/ABI/structsizeを自己検査し、取得不能は未測定として明記。peakが160MiBを超えた場合は資源未達と報告し、見積りを実測保証へ読み替えない。資源条件や閾値を緩めない。

rustc1.98.1単体opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、source閉包300KiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、全出力8MiB、compile60s/native120s、report保存後readonly verifier/guard/owned process0。Cargo target/PDB/raw trace/frame/plain/input diskcopy/Git/依存/版/公開/削除なし。source停止・ownership返却後にparent採否。別新context独立監査はこの段階では未実施。

Performance/Hardening/Tester/Normalizerは依存参照とbit layout/拒否・全件比較/資源・計時境界を担当と親で確認。Modernizer/Cleaner/Intel/Async/Startupは製品/依存/外部仕様/並行/起動を変更しないため非該当。全CLI/CPU15%/holdout/categories/完成書庫/API/4nativeは未達のまま保持する。
