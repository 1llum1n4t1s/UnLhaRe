# 全決定静的モデルの小規模試作

最新GOALの段階A。研究選定はRESEARCH_SELECTION_20261005.mdに保存した。これは完成形式・製品統合・性能優位の達成ではない。全静的化の保存費用とCDF再現性を先に測り、完成codecへ進める1構成を選ぶ。

## 所有権と禁止事項

workerは新しい`all-class-static/FAILURE_PLAN.md`、`probe.rs`、`packet.rs`、`finite.rs`、`adversarial.rs`の5ファイルだけを所有する。親はrunner/verifier/RESULTと本計画を所有する。既存source、leaf-mode-choice、public src、文書、manifest、過去report/EXEは変更しない。Git書込み・削除・download・追加委任・workerによるcompile/nativeを行わない。failure-first契約を先に保存し、その後でRustを書く。ststに従い正常系はfinite.rs、異常系はadversarial.rsへ分け、境界・型/形状・状態回復・資源の故障モデルと観測結果を対応づける。ファイル数の変更でsource合計64KiBの上限は増やさない。

## 一構成

既存SA-IS/frontend/grammar/Dense/Hist、有料paid-code-treeのFit/Selected/parse、固定257symbol表を参照する。未native検証のleaf-mode-choiceは参照しない。全2component×142nodeの284モデル、3prefixで852rootを固定順で格納する。全6classを対象とし、teacher確率や共有poolを呼ばない。k=1は符号bitなしでもclass履歴を更新する。

Denseのcoded branchのみを記録し、各component/nodeに対して元Histをlow/high履歴順で作り、paid Fitを選ぶ。支持/tail/CAP、選択lossとserialized metadata料金を検査する。空のnodeや未使用prefixも既定rootとして省略flagを払う。モデルpacketはcodebook table134Bを実際に保存し、rootflag852bit、選択root wireのbit長、padを全て払う。Readerはpacket内のtableを使い、852root/284model/深さ/支持/総量/最後のbit/trailingを検査する。

全packetをRAM内でparseし、各root k=2,3,4×1024履歴のCDFをFitと直接比較する。Forest再生もgrammarの実branchからlossを再加算し、全Meta/prefix/final-historyを元walkと直接比較する。Dense/Fit/parsedCDF比較とreplayは別に数える。元class2/5の固定paid構成のlossとbitsは、同入力で従来結果に直接照合し、新方式全体のlossと混同しない。

encoderの木選択にfloatを使うが、decoderがlog/expを再現する方式ではない。wire整数CDFだけで復元可能なことを確認する。payload entropy coder、逆BWTを含む完成frameは次段階。cost screenには、理想token ceil、実packet、escape、alphabet/primary/header/終端のside仮定を分解して保存する。前段の3079Bを使うなら借用固定値と明示し、actual complete frameと呼ばない。

## 失敗と有限E2E

先に全classを通る小入力、空、1byte、全256byte、反復、skew、prefix2/3/4、k1履歴、全root/default、低高履歴順、packet費用、model coverageを列挙する。packetの切断・余剰・bad table/bit長/root数/深さ/tail/総量/paddingを拒否し、同processで次の正常packetが成功することを確認する。適用しない破損項目は理由を説明する。

有限E2Eは入力32KiB以内、逐次処理、RAMのみ。固定groupは既存2,811,006B、SHA256 18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。読込1/BWT1、後続walk数を実censusし、小入力の累計と固定入力の累計を分ける。source/report/input/trace/CDF/rawpacketを複製しない。

## 資源と判定

新source合計64KiB以内、閉じたsource graph350KiB以内。親のstandalone出力は8MiB以内、空き5GiBに8MiBを加えた余裕を確保する。追加Cargo target/cacheなし。Dense1/Forest1、fit pairはnode単位で解放、逆CDF巨大表を作らない。model32MiB、phase64MiB、scratch64KiB、OS working set/private各160MiBを守る。動的capacityと同時寿命を式と実測で記録する。packet writer/reader/trie/finite結果Stringも課金する。

親の初回compileは60秒、native120秒、1構成のみ。version/compile/nativeのexitとtimeoutを保存する。sourcegraph/pins/リンク/出力shape/残存processを検査し、sourceは実行前後で不変を照合する。失敗の原因修正以外の再実行やblind sweepはしない。

第1段階の採否は、完全費用とCDF一致、資源上限、storedより縮むかで判断する。旧483599Bは優位性のsize目標として維持し、その値を超えるscreenは目標未達と明示する。完成性能は全frame/CPU/holdout/同条件比較を行ってから判定し、静的化率や式数を速度短縮率へ変換しない。raw screenだけで製品に採用しない。

## 後続統合

有望なら別magic/versionの完成range frameとstoredを実装し、有限E2Eで逆BWT・元byte一致・破損拒否を検証する。製品は独立`pub mod khc`とKHC用CLIを追加する案を選択し、LHA Method/CreateOptions/Entryは変更しない。既存directory/pathname/readerのhandle-relative staging/publishを利用する。dirty lib/main接続は親が所有し、codec/containerは1担当に固定する。形式仕様と実Rust/CLI往復、Zstd/LZMA2比較とablationが完成するまでGOALは未完了。
