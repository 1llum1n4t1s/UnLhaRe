# LF置換性によるread-only packed24：コード前の一設定計画

問いと一般導出はPERMUTATION_INVERSE_QUESTION_20261004.md。前packed23はreport SHA68487A979DE0E9FEFD05A50368016F8DD0A734E3ED2B6C730FB943B80146ABBAの凍結証拠。全goal固定size483599B/encode574.5624ms/decode47.3884ms、CPU15%/同資源/holdout/category/完成書庫/API/4nativeは変えない。

## 実装前の失敗一覧

LF構築の置換前提が欠ける、早期primaryを見逃す、終端だけで約数cycleを受理、byte0/255とsentinel混同、空plain/n1誤り、symbol/alphabet/count/range/checked和の拒否漏れ、24bit切詰め、MAX_N+1のwrapper拒否を本体安全性と混同、旧root書換え、全plainでなくhashだけ比較、出力/timeout/peak超過、比較/caller dropの片側計時、有利な再実行、部分inverseを全decode達成と呼ぶ。

## 固定範囲と所有権

新permutation-inverse/と未使用build/khc-permutation-inverse-20261004/だけ。親は計画/採否とhappy.rs/adversarial.rsの設計・編集・実行担当。再利用workerはpacked.rs/probe.rs/run-native.ps1と事後RESULT/verifierだけ、初稿FAILURE_PLANの具体fixtureをコード前に記載。凍結packed23 root/参考reference/body/contract/memory/BWTは読み取り専用。親テストをworkerは編集しない。compile/nativeは全実装source停止後、親が一度だけrunner実行。

## 一設定

countsとchecked prefixからLF permutationを構築。u32はnext24bit+元byte8bit、訪問済みwriteなし。step>0でrow==primaryなら短cycle拒否、n回後row==primaryを要求。全row範囲とsentinel1/alphabetを維持。単に終端を確認する実装は禁止。private上限n8388609を維持し全部packed24、範囲外は共通wrapper拒否。理論maskの上限+1はpack handだけで拒否し巨大16MiB fixtureを作らない。

参照は同EXEの凍結original inverseとpacked23、候補packed24。元reference全文/pub-only ledgerを実行前・事後に照合し、旧body/sourceの変換はしない。小正常9件は前packed23と同じ元BWT/reference/packed23/packed24全plain比較。adversarialは前11内部/3wrapper＋cycle長2/3の約数例をRAM列挙から固定し、参照3方式の受理/拒否と受理時全plain一致を比較する。小列挙n1..8、sentinel位置全通り、他symbol1/2全1793件（受理255/拒否1538）でearly-primaryの反証を追加。これはprivate standalone E2E、unit testsではない。

巨大境界n8388607/8388608/8388609は一件ずつ全1/最後0、primary n-1、alphabet[0,1]を合成。原版/新方式を全0/全plain比較しcandidate route packed24を確認、旧packed23は前の凍結成功からの推測にせず今回必要なら同順に実行する。大きな期待plain/inputコピーなし、前のcaseを破棄。MAX_N+1の16,777,220B拒否fixtureは計時前の独立scopeで解放。

## 計時と資源

固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一read/BWT。3方式各warmup1、9round各3calls計27times。round%3でreference→packed23→packed24、packed23→packed24→reference、packed24→reference→packed23を固定ローテーション。全結果比較・caller dropは計時外、関数scratch allocate/init/walk/freeまで計時内。raw27とmedian/順別を保存、CPU quiet未確認なら限定診断のみ。コード前に固定し順序/回数/設定変更しない。

同phase RAM：固定でinput(n-1)+last2n+保持結果最大2(n-1)+reference作業(12n-1)+4MiB=17n-4+4MiB=51981419B。巨大caseは比較を二方式ずつにしてlast2n+保持reference(n-1)+reference作業12n-1+4MiB=15n-2+4MiB、最大130023437B。BWT別phase141598926B推定。配列capacity/logical/実peakを区別、共通Windows80B ABI helperで最後一回peakWS/commitを記録。160MiB見積/実peak条件を緩めない。行先24bitに拡張しても容量4n+resultは同じ。

rustc1.98.1 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE/cfg frame_audit+primitive_audit。compile60s/native120s、一compile/native、失敗は保持して親へ。source300KiB/EXE1MiB/report256KiB/stdout64KiB/stderr16KiB、全出力8MiB、空き最低5GiB。Cargo/PDB/rawtrace/input/frame/plain diskcopyなし、Git/依存/版/製品/wire/x86/外部write/削除なし。source/input/tools/plan前後pins、実owned process0、結果readonly verifier、編集停止/ownership返却まで。別新context独立監査は未実施。
