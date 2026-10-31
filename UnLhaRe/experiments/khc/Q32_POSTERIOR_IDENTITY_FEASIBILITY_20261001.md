# posterior一致時の厳密短絡候補（未実装）

現在sourceのTree::updateでは、node.weight<=Qを検査し、実cached_ceilingを求めてからposterior_ratioとnext_weightを実行する。Q=2^32、pkはcached_ceilingのprobability検査により1..Q-1。ここで実ceiling==pkかつnode.weight==Q/2なら、posteriorと次weightは厳密にQ/2のままである。

1. weight*pk <= (Q/2)*(Q-1) < 2^63で積overflowなし。
2. floor(weight*pk/ceiling)=weight=Q/2。
3. alpha=floor(Q/(after+1))、有効after>=1なので0<=alpha<=Q/2。retained=Q-2alpha。
4. floor(retained*(Q/2)/Q)=Q/2-alpha。alphaを足すとQ/2に戻る。積は2^63以下、加算もQ/2以内。

従ってTree::updateの既存node.weight boundsとcached_ceiling検査**後**にこの条件を満たす場合、weightをそのまま保持してposterior/next_weight計算を省ける仮説である。counts/total/cap/observations/history更新、alpha/retained計算、leaf順は省略しない。zero/one KTの等カウントとは別条件であり、実書庫件数で評価する。予測がstaleでも実ceilingで条件を判定するので、snapshot一致を無条件に仮定しない。

これはTreeの有効状態内の証明だけである。任意u64を取るprivate posterior_ratio helperを無条件にweightへ置換しない。そこではweight*pkのoverflowがposterior>Qより先に返る。pk不正/ceiling0/積overflow/次weight範囲の順、観測cap・countoverflow時の状態も旧契約を維持しなければならない。

現段階では実装しない。先に通常sourceを変更しない診断cfgで実ceiling==pkとweightQ/2の件数を数える。機械命令削減数、人工dataset、診断時間を速度向上率に使わない。実候補に進める場合は新しい失敗条件・数値/実Model oracle・全codec E2E・同session速度比較を別に定める。通常cfgでbranchの費用が非該当nodeを遅くする可能性も棄却条件として残す。
