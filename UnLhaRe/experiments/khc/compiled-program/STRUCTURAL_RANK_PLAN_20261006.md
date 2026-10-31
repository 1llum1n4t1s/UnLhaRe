# 次の構造候補：rank先頭2段を7binへ集約

2026-10-06 JST。GOAL active。prebinding、因果joint、固定symbol root groupsを実検証して棄却した。root周辺の小変更は現5%率不足8980Bと約2倍native復号差を解消しなかった。次はsame-wireの参照調整でなく、grammar決定数自体を減らす構造を検討する。まだ実装・情報利益・性能・採用を確認した候補ではない。

## 固定案と反証

現rank rootの[0,1,2..3,4..256]と、4..256側の[4..7,8..15,16..31,32..256]を、一つの7bin [0]/[1]/[2..3]/[4..7]/[8..15]/[16..31]/[32..256]へ置換する。legal prefixはactive_lenから決める。元range区間のproduct合成は使わず、7値の整数CDFを独立学習する。remaining/length grammar・下位rank subtree・active list・BWT逆変換は維持する。

固定contextは、選択前の過去rank root2childと4..256 tail root2childの計8bit（(history[class0]&15)|((history[class1]&15)<<4)）。256contextに絞って保持・保存費を制御するが、旧5child履歴に対する情報欠落が最強反証。結果を見てcontextを増減しない。7bin復号から旧root childと旧tail childを再構成し、implicitを含む元class履歴更新をそのまま実行してから下位subtreeへ移る。rank2..3とrank>=32の継続nodeを省略しない。

旧Programからrootとtail root nodeを実際に辿って特定する。node番号を未確認のままハードコードせず、lo4/class1/forward/depthの証明と全257limit×全tokenを独立Treeへ照合する。root/tailの有料区間数と実bit lossを現在の保存frameで数える。旧CDFは比較対象のまま、新CDF total32768/min2・k2..7を費用学習する。ゼロprefix/k1/未観測/active退場・末尾を扱い、更新を未来情報へ依存させない。

情報診断に進む前に、既試行direct-token/static-direct-mdl/same-class compoundのどの制約がこの固定7bin案にも残るかを確認する。paid DPを一般化する必要があるため、既存k<=4型へ7値を押し込まない。4aryのcontext分割（4digit/256履歴）と7値leaf CDFのMDL費を別に定義し、uniform/pure/compact各leafの保存費・dominant width・minorコード・default flagsを全額計上。現在codebookを借用する場合は共用費を残し、新private模型の形式と最大費を先に記録する。

最初は定量的な成立性診断のみ。事前基準はモデル/宣言費込み8980B以上の節約機会、区間削減20%以上の可能性、codec64MiB内。どちらか未達なら実wire・性能測定なし。成立時だけ独立研究magicでactual encode/decode、正常・意味不正・相互magic拒否、全byte、整数・状態・allocation/timeout/CRC、全費用と公平速度を検証する。旧KHC1 wireを黙って変更しない。元7-Zip総合完了条件を緩めない。

## 続行時の資源

最新の成立性証拠はSTRUCTURAL_RANK_GEOMETRY_20261006.md。独立JS modelで257limit/33153合法rankのrouteと7168履歴更新を照合したが、実compiled Rustの新codec検証ではない。次は最小census（leaf count43008B/旧root-tail loss/paid吸収/全paid分母）から開始し、`rank>=4 && active_len>=9` を節約数として、全有料grammarとescape込みの両分母に20%を要求する。新DP/実wireはその前に書かない。

現Cargo6169422158B/cap6175228536B、残5806378B。新target-dir/downloadなし。次の診断生成見積は専用root8MiB（EXE2MiB/一時4MiB/report128KiB/生trace0）、free5GiB+8MiB、compiler512MiB/helper64MiB、child60秒/suite300秒/quiet15%60秒。保存corpus/既存EXE/report/共有cacheの削除や予算拡張で成立させない。
