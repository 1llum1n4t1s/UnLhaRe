# 有料符号費DPの独立設計監査

temporal_paid_model_audit はroot-history-order model/bundle/RESULT、header-minor-census census/probe、保存reportの6資料を読み取りのみ調査。編集/compile/native/Git/外部/削除0。前のlossless固定木familyは棄却したうえで、木/token共同選択の1候補を成立と判定。サイズ達成や速度改善の保証ではない。

## 根拠と反証

現model leaf_bitsはminorを一律8bitで課金してDPを選ぶ。元hist256＋ESC擬似weight1で決定的Huffmanを構築するとknown費14638bits、ESC長11、最大長11。未知minorは19bitになる。compactの構造費split1/prefix1/dominant幅にこの料金を加え、uniform/pure/default/rootorderの費用を明示すれば固定tableの加法的DPが成立する。新木からtableを再学習すると支払費がずれるので行わない。

旧木のままではpayload19914bit、flag1＋長4＋table129＋padding込みheader2624B、screen484306B、gate+707。未知コードが増える場合の19bitで逆効果になる可能性が最強反証。新DP目的<=再課金旧low/high木の目的を確認し、token/header/ESC件数の増減を別に測定する。byte切上げまでの完全最適ではない。

固定max11/ESC+8の料金なら完全展開3group129026bits<=現MAX_BITS142338。ただし一般max15を許すと153602bitsで現上限を越える。この試験でmax11をassertし、一般化/幅sweepしない。木/符号表構築には有界513node/257heap、reportとの非重複phaseで実capacityを計上する。

readerはheader tableで復元し、compiled tableを無料情報として利用しない。flag、257length nibble/末尾pad、最大長、ESC存在、canonical/Kraft、trunc/ESC raw、冗長ESC（既登録symbol）、bit長/bytes/pad/trailing、depth/order、dominant/残余largest/min2を検証する。実wire bit数とDP内部費＋834flags、134Bの全費用一致が必要。

## 事前証拠と実行条件

全256minor料金・canonical往復・allk/leaf/dominant・ESC境界・深いsplit・DP料金境界をfailure-first有限E2Eへ定義。新Fit→serialize→parse全CDFと完成Forest再Fit全CDF、元Denseのrow loss、新replay、新全Meta/freeQを比較する。新lossを元loss不変と表示しない。実metadata費screenがgate/資源を通ったときだけ実frame/teacher状態/全CLI速度の別工程へ進む。

親は独立PowerShell優先ソートを257要素に展開して再算術。length257、known14638/total14649、ESC11/max11、Kraft32768で一致。最初のメモリ上scriptblockにparamを重複付与した照会は失敗し、定義の既存paramを使用する修復後に一致。source/report/native変更とcompile/nativeは0。

## 所有と進行

親PLAN SHA8DD5902777BD58A56B224C154C1006B1A1EF90A8D766605313A923AA65EED803にlength257と費用/資源/拒否を固定。新 paid_code_tree_impl(worker-high)は専属6filesだけ実装しREADY完全停止、親がレビュー/runner/compile/native/結果を所有する。前担当は停止済み、旧全source/report/EXEと製品dirty/x86/Git/外部/削除境界を維持。worker-highは実DPとtable wireの多ファイル不変条件が複雑であるため選択した。起動要求role=worker-high、ツールはagent名/root/paid_code_tree_implを返した。外部の実効モデルを別に検証したとはしない。

全GOAL active/未達。新stageのコード/実runtime結果はこの監査文書保存時点では未検証。
