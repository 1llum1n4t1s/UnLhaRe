# 現greedy終端を覆うshadow parse：独立の是正仮説

2026-10-06。固定16byte窓は全11frame536620B（+15.1666%）で失格。PROFILE v3はcounterを外せばfrozen v2本文一致、全frame byte/全復元再一致。kennedyの12byte matchは現73378→beam11445回、match総数83577→132929回。長16以上は旧9→新1回しかなく『長4096が大量に切れた』という説明は成立しない。比較global budget枯渇0。固定終端が12byte主体のtoken分布を壊し、near-distance/rep stateも変えたという仮説は支持するが、寄与の全因果分解は未証明。

係数、window上限16、beam4、offer8、モデル、wire、match探索global64*rawをsweepしない。新案は以下の不変条件を変える：各短greedy matchの終端（length3..15）を全pathが共通して覆い、greedyそのものを候補として必ず残す。root literalは1byte、root length16以上は元greedy維持。したがって16の固定格子でgreedyを強制分割せず、候補集合からgreedyを距離同点で消さず、Q8同点はgreedy優先。未来matchがその終端を超える場合は切るので最適parseではない。root short検索済み比較数はspan*64以下（36*(span+1)≤64*span for span≥3）；root literalは追加未来探索0で従来通りglobalだけ。短window全commitとshadow sparse証明を維持する。

新source別名greedy_span_lz.rs/block/probe/runnerで作り、frozen source/report/EXEは変更しない。最初にQ8選択cost≤greedycostを全windowでassertする（実range符号長や未来外modelの優位の証明ではない）。既存33626数値/49有限/672異常/全11の旧新public全byte復元を同じ条件で必須とする。baseline465951Bから総frame1%以上削減、各file悪化1%以下、changed>0の事前screenは不変。落ちたらこの案も打ち切り、総合7-Zip達成や新原理とは言わない。

1work8MiB、source1MiB、report128KiB、compiler512MiB/60s、helper64MiB/60s、suite180s、free5GiB+work。追加source約55KiB/EXE約1.4MiBを見積る。Cargo0/raw frame plain trace disk0。profile_v3で実測したtemp archive消滅DirectoryNotFoundExceptionだけを含むIO例外の最大3回再列挙を使用し、他の例外/持続失敗は終了、容量/RAM/deadlineを緩めない。前2失敗の中間4.624677MB/4.623517MBは規定のrecycle→purge→不在確認済み、reportは保持。
