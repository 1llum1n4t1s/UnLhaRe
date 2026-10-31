# 固定時間partitionの読み取り調査

独立analystが node-history-information の grammar.rs/counts.rs/probe.rs/RESULT、class-selective-static-mdl/RESULT、PAYLOAD_BUDGET_REASSESSMENT を調査した。変更・compile・native・外部操作なし。これは次候補の情報診断であり、実codecの採用や7-Zip超えを示さない。

## 採る問いと成立条件

固定65536-run単位、889227 runsを13完全tileと37259-run末尾の14tileへ分ける。幅sweepなし。既存component/node/prefix/history10のkeyに時間partitionを加え、静的keyでは見えなかった局所性の情報利得を測る。

grammar.rs:39-49のcallbackは履歴更新前で、run増分はlength token完了後。更新前run番号を渡せば現在の未知childに依存しないkeyになる。rank/lengthと同runのbranchesを分割せず、tileを跨いでもprefix1を含むhistory更新を維持する。前tileは最初の新tile eventをrecordする前にflushし、非空末尾を一度だけflushする。

Denseは872448rows/13959192Bを1個reuseする。14個同時保持195428688Bは160MiBを超えるため禁止。1集計walkと14回のrow scan/clear（12214272rows）、有界なtile/component/node集計だけにする。全event traceは保存しない。scan/clearの実時間は未測定。

## 先行検証と最強反証

run単調性・tile範囲、全Meta（prefixes/final_historyを含む）と原raw結果の直接一致を要求する。有限E2Eは境界前後、同run複数branchとrank/length、prefix1、跨境history、境界ちょうどの終端、非空末尾、flush一回性を扱う。全row/childの独立算術とtile/component/node/wholeのcount/lossを突き合わせる。

既存の2walkによるevent Qloss再生検査を、1walk/clear方式で継承したと報告してはならない。empirical entropyのpartition改善は同event集合について成立するが、Q32768 lossの単調改善は保証されない。

旧無料Q screen504637Bから固定483599Bへは、無料モデルの段階でも21038B改善が必要。同じside3079BならQ token ceil<=480520Bが情報条件。ただし実frameの下界ではない。静的選別例は無料473039Bから剪定損失・bundle費用込み494389Bへ悪化した。時間partitionにも過学習、CDF保存・parse、共有・fallback・lookup、coder終端・frame費用が残る。

## 現在の判断

有限情報診断の次候補として成立。CRC付きanchored-wireの検証とは独立した問いだが、まだ実装計画・failure plan・実行結果はない。paid wire/holdout/再現decoder/4native/fullCLI/quietと固定全ゲートを緩和しない。
