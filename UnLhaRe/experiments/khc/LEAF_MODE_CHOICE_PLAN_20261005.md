# 固定短modeを葉CDF候補として評価する

基点paid-code-tree実測484286 B、report SHA1A244D67F80617B92812E715C2CA45394144CA51D59A45E6D1D8703F5711C116。全GOALは7-Zipを総合的に超えるまでactive。今回のprivate費用screen成功は全完成条件の代用にしない。

## 一候補と費用

各Hist nodeを既存compact_frequency(quantize(counts,k))先頭、旧uniform(k)、pure dominant0..k-1の順で評価する。候補は最大k+2（4/5/6）個、既存loss＋実wire bitsのstrict <だけで更新し、tieでは旧を保持。その後現split候補を同じstrict <で比較する。root uniform内部0、内部uniform3、pure k2で4/k3,4で5、compactは固定tableの料金、root split2/internal split1。pureは全childに2を与え、dominant32768−2(k−1)。実observed全countのlossを必ず支払う。

table、leaf符号、全834flags、134 B prefix、字典LUT/floor/Hamilton/Hist、low/high履歴反転、grammar/Meta、depth5、Node32 B上限は変更しない。候補をstackで逐次作り、Vec/Node/Forest容量を増やさない。固定少数の候補のみで、価格/幅/table再学習/sweepなし。候補計算を事前定数化する場合も最終rowlossの数式・有限一致・capacityを照合する。

no-worseの本入力基点は現在paid-code-tree選択木（loss1540684.988783758、payload21256bit、header2791 B、token478416 B）。旧paid低/高Fitを同Histで再構築し旧paid root wireをtyped parse、全node/rootで新目的<=旧paid木目的を直接比較。旧parsed leafを旧compact_frequency(quantize(hist.counts))へ照合し、新selected frequencyとの同一を要求しない。全旧parsed CDF/old Fit/CDFweightedloss/元report費用を確認し、baseline header/token/合計が保存値と一致すること。

元root-history-orderを使う旧finite fixtureは保持する。既存reprice_oldの新leaf同一assertも上記の旧compactCDF検査へ変更するが、旧レポートは変更しない。新Fit→serialize→parseの全CDFとrowlossは独立に照合する。同木Hamiltonとの差は「新CDF選択の損失差」であり、単なるfloor誤差ではない。legacy schemaを残す場合も対応する明示fieldを追加する。

## 実装所有

新leaf-mode-choice/{FAILURE_PLAN.md,model.rs,e2e.rs,probe.rs}4filesをworker-high一人が所有。親はPLAN/AUDIT/run-native/verify-result/RESULT/decisionを所有。既存paid-code-tree/{codebook,bundle,e2e}を凍結sourceとして直接参照する（bundle/e2eはcrate::paid_modelを新Fitへ接続、同wirefixtureを新実装へ再実行する）。旧paid modelはprevious_paid_model namespace、root旧model/bundle/frozen_e2eは元namespaceを維持。

まずFAILURE_PLANを保存してから実装。workerはapply_patchだけ、構文確認は固定rustfmt非書込 --edition 2024 --emit stdout --config skip_children=true。compile/native/全体テスト/Git/外部/削除/追加委任0。READYには4SHA/mtime/bytes、厳密逆ledger、全編集停止を返す。親レビュー後のみcompile1/native1。型/実行成功を非書込syntaxから主張しない。

## 先行有限E2E

全kで空、非uniform countからuniform、非pure countからpure全dominant、compact維持、同点旧保持、default内部0、内部uniform3、root/inner fee、low/high順、depth5、旧candidate no-worse。全候補の合法CDF/実loss/実wirefeeを独立式で比較し、default/split/table/ESC/raw/残余/切断/pad/trailingの凍結wirefixtureと拒否理由/同process復帰も再実行。先行列挙から必要な有限ケースだけを使い、post-code unit test追加なし。

本入力のread1/BWT1/walk2、新train556/旧paidbaseline556/verify556＝1668 Fitを全計上。有限E2E buildsは別集計。選択葉のlegacyCDF/新uniform/新pure区分、各CDF損失差、token/header/合計を表示。baseline root scans1668/CDF1708032、各node比較実counter、個別CDF854016/完成Forest再Fit854016、全Meta/原Q/replayを照合。報告JSON raw1、最大nodeJSON32000 B、report256KiB。

## 親実行と判定

出力unused build/khc-leaf-mode-choice-20261005/、EXE+reportの2filesだけ8MiB内、free5GiB以上。rawpacket/input/frame/code/CDFtraceのdisk copy0、共有cache/既存証拠/他作業を削除しない。source+PLAN+FAIL350KiB、helper固定60scompile/120snative、固定rustc1.98.1/pwsh SHA/CWD/Input2811006 Bを前後live lock/identityで照合。sourcegraph/closureは最終READYから確認する。

model32MiB/phase64MiB/scratch65536/OS WSとprivate各160MiB。旧paid/新Fit同時分、decoder/trie、候補stack、codecとJSONのphaseを実capacityと寿命で計上。Node<=32。表は129 B、prefix134 Bを全額支払う。header=134+ceil((834+Σroot internal)/8)、screen=ceil((teacher+selected loss)/8)+header+3079。実screen<=483599 Bで必要size条件を判定し、未達はtoken/header別に保存して棄却。同じ候補の幅・価格を盲目再試行しない。

親独立再検証は保存raw全文、基点の前後/live、CDF/費用/資源式/全新finite/2出力/残processを照合。基礎paid readonly172組を開始・終了で実行。結果/再現方法を保存し、全CLI速度/teacher/frame/holdout/4native未達を残す。今回成功しても製品採用やgoal completeにしない。
