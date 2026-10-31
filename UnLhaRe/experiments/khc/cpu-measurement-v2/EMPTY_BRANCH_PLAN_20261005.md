# 空頻度枝：失敗先行計画

2026-10-05。対象はRust KHCのpaid_model::Fit::build_nodeのみ。FILL_RESULTまでのソースと旧fill EXEを基準とし、形式・revision・decoder・モデル選択の結果を変えない。旧fill SHA256 3F9E8ABA9500D0DF085A49DB071DBAF09DE3FE8FE4BB25C2C9263EB13FD2F63Fを保持する。

仮説：空頻度枝はuniform leafのloss=0、root bits=0/その他bits=3。splitは少なくとも1+4*3 bitを要し、strict lower判定では選ばれない。全descendantがゼロと確認できた枝は、子ごとの量子化・compact化・leaf/CDF検査・split比較を省いても完全に同じ選択になる。countsは非負u32だが、親ゼロだけで子ゼロを仮定しない。全子孫のゼロ検査は継続し、非ゼロがあれば拒否する。非空枝の処理は変更しない。

失敗候補：不整合な親ゼロ/子非ゼロの見逃し、depth/id境界、k3丸め、tail/CAP、未初期化Nodeがlookupやwriterから参照される、splitの同点選択が変わる、非空枝への影響、frame差、RAM/時間超過。空枝のuniform/leaf構築は従来関数を使い、descendant検査は既存NODES/深さ5の4分木を全走査する。ゼロdescendantはtailもCAPも自明に満たす。lookup/writerは非splitで終了し、子Nodeには到達しない。

検証：新empty probeのみ共有Cargoでbuild、旧fillは再構築しない。Paid/Low各7fixture warmup1＋9の全frame一致・自己/相互復号、固定3block、30故障/30回復、最大split E2E、clippy/fmt。内部Histは非公開で、公的入力から不整合Histを注入できないため、その拒否経路の直接実行検証は未実施と明記する。新unit testは追加しない。

採用判定はbyte不変、回帰成功、64MiB内、7fixtureの実測で性能削減の根拠が得られること。効果がなければ追加最適化を重ねず候補を見直す。GOAL_GATEは緩めず、局所互換成功で7-Zip優位とはしない。

Modernizer/Normalizerは依存・API変更なし、Performanceは空枝の反復量子化削減、Cleanerは同原因、Hardening/Testerは上記検査。Asyncの寿命維持、Startup/Intelは非該当。全観点と編集は親担当、外部照会なし。

容量：共有Cargo累計追加209508700 B、残り58926756 B/256MiB。新build48MiB以内を予約。各report8MiB/256KiB、raw/frame disk0、free5GiB、child64MiB/60s、suite900s、CPUquiet15%。buildとnative比較を重ねない。削除、Git、公開、version、追加依存なし。
