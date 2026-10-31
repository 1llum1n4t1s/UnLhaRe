# direct static CDF：固定総和へのprefix再正規化の設計メモ

これは親による整数式の導出で、実coderの実装・E2E・速度の証拠ではない。static-direct-mdlのサイズ不合格を覆さず、新しい予測モデルがサイズ条件を通った場合だけ検証候補にする。

元CDFの総和Q=32768、valid limitまでのprefix総和M（1..Q）、symbolの元累積cとfrequency f>0とする。正規化CDF境界を `floor(c*Q/M)` とし、frequencyは `floor((c+f)*Q/M)-floor(c*Q/M)`。M<=Qなので元の正frequencyは正のまま、valid prefixの最後の境界はQ。未使用symbolのfreq0は0を維持する。

固定Qのslot（0..Q-1）から元CDFの位置へ戻す式は `p = ((slot+1)*M-1)>>15`。元のfull-CDF lookup[p]でsymbolを選ぶ。`p=ceil((slot+1)*M/Q)-1` なので `floor(c*Q/M)<=slot<floor((c+f)*Q/M)` と同じ区間になる。最大積はQ*Q-1でu32に収まる。p<Mなので選択symbolはvalid limit内。

この導出は、可変Mのcoderを直接実装せず、固定総和のcoderと元CDF lookupを組み合わせる可能性を示す。正規化されたc/f計算は可変M整数除算を含み、tokenごとに2回計算すれば重い。モデル×現在limitのlazy interval cacheを検討できるが、cache初期化/invalidations/peak RAMと速度は未測定。全slot/全boundaryの独立整数oracle、frequency0/1/Q、limit1/全limit、carry/renormalization/末尾/不正入力をfailure-firstで検証してから実coderへ使う。未検証の一般化ANS閾値式を採用しない。

rankのactive limitは終端symbolで単調に減り、length remaining limitが256未満になるのは末尾だけ。ただしmodel×limitで何区間が実際に使われるか、cache hit率、総初期化時間はこの入力でも未計測。lookup最大表をmodel×全limit分複製する案は容量・RAM・起動費用が大きいため採らない。これは実測勝利や必要予算の保証ではない。
