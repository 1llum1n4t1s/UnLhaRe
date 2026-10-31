# 次の構造判断：payloadだけでなくinverse BWTも固定展開条件へ届くか

## 読み取りで確認した証拠

旧Q32 stage診断の成功report `build/khc-quaternary-cts-stage-profile-cfg-20261003/report.json`（SHA `1A5D148CC5E7D2B46F7C30BB646FB8DDB8FECE72E9FDA37C2E8350DC184E3528`）では、candidate.profiles[1]のtransform bucketは123302800ns、started/ended/pairs各1、active=false。同total5968474500nsに包含されたinverse BWTの単発診断値で、正式比較・opt3の値・新モデルの下界ではない。

固定7-Zip展開条件47.3884msよりこの観測値が大きいため、payload軽量化だけを十分条件にしない。現在opt3で同transformが何msなのか、等価な内部layoutでどこまで減らせるかを別の限定診断で確かめる価値がある。未実測のCPU/cache速度を達成証拠にしない。

`lookup-float-profile/codec.rs:73`のinverseは、usize LF n要素、visited bool n要素、text u16 n要素、result byte n-1要素を構築する。復元loopは依存LF参照に加えvisited/last参照を行う。fixed n=2811007で、これら四作業配列のlogical bytesは約12n（usize8を前提）。allocator/peak/キャッシュmissは未実測。

## 内部layout候補（未実装・未採用）

n<=2^23の範囲では、LF next index23bit、元byte8bit、visited1bitをu32一要素へ格納する。sentinel位置は検査済みprimaryなので、そのrowのbyteはdummyとし、walker初回だけ出力を省く。sentinel count1、alphabet presence、全row range、n回の訪問で重複拒否、最終primary復帰を維持する。n個の異なるrowを訪れた場合に全row訪問が含意されることを検証し、visited全件scanを省けるかを確認する。reverse text u16を介さずresult[n-1-step]へstep>0だけ元byteを出力する。packed+resultは約5n、参考との差約7nだが実RAM/速度削減ではまだない。

n>2^23では元のusize実装へfallbackし、製品の対応長を削らない。packing境界/next範囲/mark bit/primary空入力/最後のsentinel/任意byte255/不正cycle/alphabet条件はコード前に失敗一覧を固定し、referenceとの全plain比較と拒否を実行する必要がある。保留中のモデルへこのlayoutを勝手に移植せず、新private source/outputで独立に診断する。

より高度なmulti-stream inverseやencoder生成anchorsはwire/metadataを変える別案であり、この候補には含めない。packed同値性、opt3同EXE限定比較を通しても、全CLI・同memory/thread・CPU15%・holdout/categories・完成書庫・4native・製品API条件は別途必要。現在の総合goalは未達。
