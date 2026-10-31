# CTSの完全同値wide quotient — 実装前failure-first契約

前turnは同値BWT・独立E2E/実比較を完了したprogress。現在の研究基準はfast-BWT EXE `4B1191EC94B5945874EEC1B08A55E62CEC0D984AE9B00BD84209A2C57FAEE898`、frame483468B/SHA `B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A`、fullencode中央値3449.5041ms、固定strict<574.5624msは未達。必要な83.34%短縮を約束しない。BWT変更前のdebugpairのCTS比率を現在pairの比率として使わない。

既存CTSはKT/child予測をPredictionに保存してupdateが再利用済み。cache追加・深さ/Q/prior/context変更・モデルsweepをしない。debugpairのKT call siteには128-bit値のstack転送と広い商を返すcompiler builtin呼出が存在することをdisassemblyで確認したが、その命令数や古いサンプル割合から現候補の削減量を推計しない。full比較が改善しなければこの一案は不採用。

## 一案だけを固定

新研究directory `causal-bayes-exact-div/`へfast-BWT codecの別copyと元CTSの別copyを作り、CTSのratioだけをexact_div moduleへ委譲する。BWT/Bayes/range/packedは元path参照。primary/文法/CTSモデルの整数式・更新順・history・bit前予測・Bayesの累積尤度・全frame/decoderは変更しない。単一改善は「u128/u64の商がu64に収まる契約を使う正確な除算」で、近似/reciprocal model/量子化変更はしない。

- d=0は従来と同じzero denominator Err。u64×u64のproductはu128に常に収まるが元checked_mulを保持する。
- product = hi*2^64+lo。d>0ならfloor(product/d)<2^64 iff hi<d。hi>=dは従来と同じquotient overflow Errを返し、hardware divideへ進まない。
- d=Q=2^48はproduct>>48の正確な商をchecked u64で返す。x64の他の非zero d・hi<dではDIVでRDX:RAX/dのu64商を得る。RAX/RDXは明示inout、divisorは別in(reg)、FLAGS preservedを宣言しない。pure/nomem/nostackは直接整数入出力だけ・memory/stackアクセスなし・trap条件の事前拒否を理由に限定する。
- 非x64と研究cfg `khc_portable_div`は元のu128除算へfallback。同じx64でportable cfgを強制buildして同値比較するが、ARM64/macOS native検証済みとは呼ばない。constant Q分岐とhardware分岐は同じquotient specializationの一案であり、複数パラメータ探索をしない。

参照一次資料は[Rust inline assembly reference](https://doc.rust-lang.org/nightly/reference/inline-assembly.html)のoperands/options/rules、[AMD64 APM](https://docs.amd.com/api/khub/documents/68GKiN0gMEd6bMddsmhPwg/content)のunsigned DIV。全文fetchは制限で失敗したが公式search抜粋でoperand/quotient/remainderとpure/nomem条件を確認した。安全性のhi<d証明と仕様同値性は独立の整数計算/ソース検証で確認する。性能の証拠は資料ではなく実測とする。

## 先に失敗条件

d0/商2^64境界/hi==d/hi=d−1/prod0/a,b=Max64/d1/dMax64/Q±1、register overlap/未宣言clobber/undefined flags/除算trap、signed化/丸め変更、portableとhardwareの不一致、元数式/CTS state/decoder同期の変更、入力/出力長やcountのoverflow/割当失敗、壊れた数値batch/不正argv/既存output上書き/失敗後公開を拒否する。

新unit testは追加しない。研究audit CLIはinput/outputをとり、最大65536 triplesのbounded little-endian binary batchを読み、各(a,b,d)の実結果をtag/u64商のbinary outputへ公開、JSONで成功/zero/overflow数を返す。親harnessは別実装のPowerShell BigIntegerのproduct/divisionで全triplesを検証する。small grid（0/1/2/3/16/32/48/63/64bit境界）、全power-of-two divisor、固定seedのfull64bit乱数、構成したhi境界を含める。nativeとportableの別process全出力一致/反復、タグ/商/JSON/上限/破損/no-clobberを照合し、zero/overflowがhardware trapではなく正常な結果tagになることを実測する。

numerical E2E後に元全36checks/61CLIを新codec/native、portable cfg/opt2 referenceで再実行。fixedgroup本文SHA/11metadata、483468全frame SHA、相互decode/再encode/破損CRC修復/上限/no-clobberを維持する。新ratio以外のcodec/CTS残部は独立diff、asm register安全性/整数証明/全数値結果/現物SHA/実exitを別役が確認する。

全E2E後のみfast-BWT frozen control/新candidate/native11file7zのwarmup1+9測定・3系列循環順を行う。全process wall/CPU/OSpeak/sample-privateとargv/exit/前後hash、初回最終decodeを保存する。fixedsize<=483599/strict fullencode<574.5624ms/単一codec threadは維持。recording/build/別benchmarkと非重複。既存control/source/report/EXEを更新しない。旧CPUプロファイルや部分除算速度だけで採用しない。

所有root `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-exact-div-20260930/`。Rust1.98.1/edition2024/opt3/panicabort/debuginfo未指定（referenceのみopt2+portable cfg）。新module/audit/harness/source/toolchain/argv/exitと全成果物のSHAを保存し、existing work拒否。必要な再現proofは保持、不要中間archiveは独立監査後の安全確認で清掃。過去policy拒否対象を再試行/回避しない。製品/UnLha32Re/registry/共有cache/deps/version/外部公開/Git/holdoutへ操作しない。
