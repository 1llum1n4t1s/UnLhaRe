# depth5 CTS alpha共通係数: 単独候補の旧新ABBA契約

## 基点・所有・固定条件

前段QCANCELとMath-U64は正しさ合格だが速度採用条件不合格で未採用。従来depth5旧pool/旧Mathを基点にPERF-ALPHAだけを試す。Q-cancel、Math-U64、近似計算、depth変更、Snapshot縮小を混ぜない。fixed size<=483599B、正式single-thread codec median<574.5624ms、machine CPU<=15%、holdout/categories、4native、製品/API統合は維持し、開発Canterburyをholdoutにしない。

小さな旧library codegenではalpha divqとretained算出がloop内に残ることを確認済み。ただし既存full EXEの実命令や速度とは区別する。凍結codegen136にassembly/report/result3件を加えた139basisを参照し、旧130以下の全guardを継承する。既存source/契約/結果/EXEを改変・再実行しない。

親は本契約、レビュー、Execute、結果を所有。worker-high一人は新quaternary-cts-alpha/の8件（FAILURE_PLAN.md、probe.rs、codec.rs、optimized_codec.rs、integer_cts.rs、alpha_kernel.rs、comparison.rs、verify-alpha.ps1）だけを所有する。失敗計画をコードより先に書く。機械的テンプレートCopy-Item以外はapply_patch。製品/API/wire/version、Git、x86、shared cache、外部書込み、凍結証拠の変更は行わない。他の作業者の変更を戻さない。

workerはPS parser/Rustfmt stdout10/nonExecuteだけを行い、型/compile/候補CLI/Executeをしない。親レビュー後fresh build/khc-quaternary-cts-alpha-20261003でExecute1/compile1/compare-snapshot1/compare-alpha1/selfcheck1/selfcheck-new1/ABBA1。child120秒/stdout stderr各64KiB/rawとparsed保存後validator/kill/dispose/finally/sourceとEXE前後guardを維持し、好都合な再測定はしない。

## 許可する数値・接続差分

新alpha_kernelは旧Kernel/Result/Q/CAP/LEVELSを使用し、update_kernelとprivate helperだけを持つ。旧q32/pow2/kt64/depth sourceは変更しない。旧posterior_switch本体は旧oracleとしてそのまま残し、新depth CTSだけが新updateを呼ぶ。型を変更しない。

- update入口のinvalid prefix→invalid kernel update順、条件短絡とleaf検査をそのまま維持。next=[Q/2;LEVELS]を作り、depth0なら旧空loopと同じOk(next)で帰る。
- depth>0では入口で保証されたafter∈[1,CAP]から旧式denominator/alpha/retainedをchecked算術で一度だけ求める。1<=alpha<=Q/2、retained>=0、分母非零のためalpha関連Errは到達不能。旧Err文字列を維持し、レベル依存の拒否より新たな到達可能Errを優先させない。
- レベル昇順にprivate helperを呼び、旧posterior_switchのweight/own/rawmass/after guard、ownmass、rawmass guard、numerator/posterior、bounds、product/next算術とErr文字列/順を維持する。helperでは旧係数計算だけを引数alpha/retainedへ置き換える。u128 posterior/補間の狭幅化、guard削除、unchecked/unsafeは不可。
- 新integer_cts.rsは凍結depth source全文の機械コピーからupdate_kernel reexportだけ新helperへ向ける。predict/seal/visible-certified完全比較/派生再predict/CAP/prepare-all-before-commit/history/node/観測数は本文一致。

旧codecは前段旧codecをそのまま複製。optimized codecは同じmid numerical/timer body・同じ凍結depth/model.rsとmid/e2e.rs・親codec::Proof共有で、新CTS aliasだけを新integer_ctsへ向ける。旧Mathと旧poolを使う。14field Proof/CDF to_bits、root call単位選択、hot-loop分岐dispatchなしを維持する。

rootは旧codec、新CTS、sealed旧CTS、凍結snapshot comparison、新comparison、凍結baseline depth CTS、新alpha kernel、旧Math/pool/reference q32、BWT/packed alphabet/rangeを明示参照する。予定graph17unique sources/18edges/root13/unique destinations16。139basis+新8file+本契約1=148unique identities。body差分、validator定義/call、compiled graph、全古い照合loopを非実行で確認する。

## コード前の失敗条件とcompare-alpha

共有旧referenceを改変してold/new両方に同じ誤りを入れる問題を避け、旧update_kernelを直接oracleとして参照する。current private helperとoldの全Result配列/Err文字列を逐次直接比較する。kernel inputを巨大traceへ出さず件数/最小失敗だけ保存する。

1. 正常540件: depth0..8、prefix1..4の全child（計10child）、after{1,CAP}、weight pattern3種（非leaf0/Q/2/Q、leafはQ/2）。raw[l][j]=(l+3)*(j+5)とし、旧predict_kernelで正常Kernelを作る。9*10*2*3=540。旧実装由来のKernel生成は固定し、新predictionによる共通誤りをoracleにしない。
2. kernel入口拒否225件: depth{0,5,8}/全prefix-child/after{0,CAP+1,u32::MAX}90件、同depth/bad prefix{0,5,usize::MAX}/after{0,1,CAP+1}27件、同depth/prefix1..4/child==prefix/同after36件、bad depth{LEVELS,usize::MAX}/prefix1..4/同after24件、同正常depth/prefix1..4/leaf weight Q/2±1/after{1,CAP}48件。prefixとkernel guardの優先順を確認する。
3. switch拒否96件: depth8/prefix4/child0/after{1,CAP}、各level0..7でweight Q+1、own0、ownQ+1、rawmass0、rawmass ownmass-1、rawmass Q²+1の6種。baseは全weight Q/2。後段のみの異常でも旧順に拒否する。
4. 複合level拒否8件: after{1,CAP}で、level0 invalid＋level7 denominator、level0 denominator＋level7 invalid、level2 denominator＋level5 invalid、level2 invalid＋level5 denominatorの4種。invalidはweight Q+1、denominatorはbase ownmass-1とする。最初に失敗するlevelのErrを旧と直接比較する。

kernel比較合計869件、正常540/拒否329。after関連到達不能Errの保証と、depth0の非leaf値未検査という旧意味も維持する。

さらに凍結baseline depth CTSと新CTSのdepth0 E2Eを独立して走らせる。class0..5×prefix1..4の24組ごとに両modelを新規構築し、child0..prefixを2周、合計120成功observe。pure predictの反復、snapshot公開全field、nodes/history/observationsを逐次直接比較し、predict後とobserve後の全状態を確認する。全state cloneは小さなdepth0モデルだけで使い、ABBAのframe cloneとは区別する。

各24組で6拒否（child==prefix、snapshot prefix0、stale、kernel.kt[0][0]改変、node raw[CAP,0,0,0]かつclass obs0のnode cap、class obsCAPのclass cap）を実施し、計144拒否。Err文字列と旧新各modelの拒否前後全state一致を確認する。後段node capやforeign/rebasedは既存depth4..8比較も保持する。seedはprimitive_audit専用入口だけで行い、正常codec経路へ入れない。

compare-snapshotはfrozen mid sealed392/223/22、depth[4..8]30/1070/90/pure5/constructor2/compact60。旧新selfcheckは各plain70/canonical70/malformed165/short20/model named70/assertions80/CAP5。拒否優先順・全state不変・prepare全完了後commitを減らさない。

## 全入力ABBA・RAM・容量・採否

旧/新/新/旧のdepth5を各encode/decode2回、入力2811006Bを1read。固定frame478750/header285/payload478465、CRCplain433441561/payload3616798779/header621578488、base0caac94407124a37/CDF3820763.985142052±1e-4、共通grammar/count/classes、nodes1365/class・CTSnode196560Bを維持する。FIXED_STATSは凍結Debug空白まで一致させる。全plain4、往復全Proof/stats4、first Aとの全Proof/stats3、全frame byte3回1436250Bを直接比較する。

first A frame/Proof/statsはmove保持、後続current即drop、最終reference drop。reference最大1枚478750B/live最大2枚957500B、encode成功直後のpeak記録、cloneなし、全process peakは未測定。比較/drop/JSONはcodec timer外。size合格4/warmup0/ABBA1/外部repeat0/inner timer0を維持する。

出力8MiB、EXE1MiB/report512KiB/予約1572864B、空き5GiB+予算を前後確認。最終EXE/report2件だけ。input/frame/plain/temp/bak/PDB/Cargo target/traceのディスク生成禁止。旧basisの全guard/hash/bytes/UTCticks/count/EXEと、codegen136前後/liveを継承する。旧identityの冗長再保存だけscalarにし、現在148before/after全identityを保持する。

全同値・拒否・capacity合格かつB平均encode/decodeがそれぞれA平均より短い場合だけ次の私的比較基点へ採用する。1周の観測は統計的な効果確定やformal gate達成と呼ばない。不合格なら旧基点を維持し、好都合な再試行や他候補混在をしない。

opopのPerformance/Hardening/Testerはalpha算術・独立oracle・拒否優先とcodegenをreadonly analyst cts_alpha_auditが確認し、親が現コードへ接続した。Modernizer/Normalizerは公開方式/依存変更不要、Cleanerは既存Proof/テンプレート再利用のみ、Asyncはchild/frame解放、Startup/Intelは非該当。複数module/type/body/validator/旧独立oracleが連動するためworker-highへ限定委任し、独立した新文脈のcode auditと親レビュー後にExecuteする。
