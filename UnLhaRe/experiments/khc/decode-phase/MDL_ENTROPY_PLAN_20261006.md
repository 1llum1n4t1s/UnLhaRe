# 次候補：静的MDL文法を保つ多値rANS（実装前契約）

2026-10-06。native_compare両順の約149ms対39〜40ms、現Forestでのtoken/run74.3259ms（MDL89.3864ms中83.15%）を受けた次の実装候補。現codecへの採用も優位も未証明。製品sourceは不変、GOAL総合条件も不変。

## 現方式と今回の相違
旧研究LZのbinary rANS/backend、4stateだけの追加（遅化済み）を再実行しない。
今回の対象は採用済み全静的MDLのk=2..4文法決定とescape256。モデル/文脈/履歴/grammar/metadata/逆BWTを固定し、payloadのエントロピーbackendだけを多値の単一state rANSへ替えるアブレーションである。
候補比較は現rangeとこの1構成。rangeのruntime除算をrANSのmask/shift/multiplyへ変えられるが、Forest lookup、CDF支持検査、grammar逐次依存は残る。性能改善率を未測定で約束しない。rANS自体は既知技術であり新しい圧縮原理とも学術的新規性とも呼ばない。旧backendの作者・出典は既存研究選定に従い、独立実装時も一次仕様を確認する。

## 失敗を先に定義
1. 製品KHC1BLKを別payloadに黙って置換する：研究用8B magic KHA1BLKと終端NULを別識別子として使用。既存publicは拒否必須、候補も旧magic拒否。既存frame/API/version/LHAは編集しない。
2. LZまでcoderを替える：現multi_range子moduleはそのまま、MDL mainの型参照だけ別mdl_entropyへ置く。LZは旧range、stored/非MDLの挙動を参照比較する。
3. forward文脈をreverse rANSで再計算：前向きgrammarから(cumulative:u16,frequency:u16,scale:u8)をjournalへ保存し逆順符号化。CDFとhistoryはdecoderで現順に再現する。変数totalは256/32768だけ、他totalは拒否する。
4. journal無制限：1frame最大2097152 event/構造体6B=12582912Bを固定。checked length/reserve_exact/capacity guard、range output上限と区別。上限のためのstored選択は理由を保存し、allocation failureを成功へ変換しない。
5. journal費を隠す：実capacityをencoder live phaseへ追加、codec64MiB/harness64MiB以内。BWT/modelとの同時寿命を改修前に照合。decoderにはjournalなし。
6. rANS式・escape混合の誤り：L=2^23、state<L*256を不変にし、CDF scale15/escape8を毎event照合。normalization byte順、initial/final state、exact endを検証。全CDFsupport/total/tail、range interval containment相当検査を残す。
7. 不正state/truncation/余分byte/overflow/CRC/意味不正で受理・panic：有限E2Eで正常tiny/全256/反復/random/11development、自前encodedの切断・改変・再封印、拒否後正常復帰を同process確認。新unitなし。
8. decodeだけのspeedを採用根拠にする：warm1+9 pairedと入力・pair逆順、全frame費用・encode/decode・sampledRAMを比較する。出力byte一致と旧新cross-format拒否を確認してからtiming。
9. 寸法やコードの外部依存が揺れる：rustc/deps/source/corpus/EXE/結果SHAとreadロック、終了再確認。Cargo build0、専用rustc先8MiB/free5GiB、child60秒/compiler512MiB/suite300秒/quietCPU15%。
10. 局所改善で総合達成：5%率条件、10%圧縮/復号速度条件、strong-full archive/真正未見/all metadata/4nativeを維持。単なるANS変更では追加8980B削減が保証されない。

## 局所候補を打ち切る条件（GOAL合格とは別）
全復元/安全性/資源guard不成立で即棄却または再現原因の一修正。正常性通過後の2順でMDL decode中央値合計15%以上短縮、encode悪化10%以内、各MDL frame増加8B以内を満たさなければ製品へ移植しない。単一入力の良い差だけで採用しない。成立しても公開full archiveの固定ゲートに達するまで完成扱いにしない。

次に行うのはjournal寿命・型参照の照合、一次rANS式確認、上記の別namespace実装と有限E2Eであり、現rangeの検査削除・slot融合・active移動・LF visited省略の再試行ではない。親が全編集と実行を所有、外部書込/Git/版変更/新サービス0。

