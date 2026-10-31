# Q32 CTSの予測・更新間の混合再利用（実装前調査）

調査対象はsplit候補のCTSとcodec実呼出。速度測定前の限定探索で、まだ実装・数値E2E・採用をしていない。

## 整数式と支持範囲

Q=2^32、0<=w<=Q、1<=k,c<Q。predictで既に検査した混合をs0=w*k+(Q-w)*c=Q*z+r（0<=r<Q）とする。Prediction.zero[level]はzであり、Prediction::zero()のQ15値ではない。

- bit0のposterior分母はceil(s0/Q)=z+[r!=0]。
- bit1はs1=w*(Q-k)+(Q-w)*(Q-c)=Q^2-s0なので、ceil(s1/Q)=Q-z。
- Q<=s0<=Q*(Q-1)。既存ceil offset加算の最大もQ^2-1=u64::MAX。
- 実装でQ^2を生成しない。checked z+remainder又はQ-zで計算する。分母は1..Q-1。

16段の更新側weighted_sum（各2乗算等）を省略できる可能性がある。static演算数であり、CPU時間短縮率ではない。predict側weighted_sum/probabilityとupdate側weight/pk/posterior/count/capを保持する。remainderはu16 bitmaskで保存する案が最小だが、Rust layout、戻り値copy、追加mask操作は未実測。

## 必須の呼出条件と反例

codec.rsのStream.bitは同じclassでCTS predict→coder→Bayes update→CTS updateを一度だけ呼ぶ。Bayesは別状態であり、leafからrootの各node更新は別nodeのweightを変えない。この経路なら再利用時点のweightは予測時点と一致する。

ただしprivate Predictionのfieldsを捏造できなくても、現Model::updateはclass/世代の対応を検証せず再利用も型で禁止しない。k=3,c=7、予測時w=Q/2なら分母5、更新時w=Q/4なら旧式は6。cached式はstale/differentclass誤用の旧挙動を保持しない。この例は整数引数での反例で、実codecから到達する履歴は未提示である。

したがって、後続実装前にprivate APIを直前・同class・一回のPredictionとして扱う条件を明示するか、誤用時にも旧分母を保つ検査/fallbackを設計する必要がある。消えるchild補数/weighted_sum/ceilエラー枝は有効な直前Predictionでは到達不能だが、内部誤用まで同じエラー順序を保証するなら単純置換は不可。公開製品APIの契約変更はしない。

## 実装前の失敗条件

- Q15 rootだけを比較し、丸めに隠れる分母/posterior/次weight差を見逃す。
- stale反例を無視し、全private API入力で厳密同値だと宣言する。
- remainder=0とnonzero、weight0/Q、確率両端、両bitの境界が不一致。
- 旧全frame・opt2/3・双方向復号・異常系・no-clobber・readlocksが欠落。
- stack/copy増加やbranchで遅くなる可能性を除外する。
- 部分測定やstatic乗算削減数を速度改善へ読み替える。

独立BigInteger oracleで境界および全class・長い交互/偏り履歴の分母/posterior/次weightを比較し、実codec全frame同値と相互復号を先に確認する。通常性能は同sessionで凍結対照/native7zipと比較し、元gateとquiet15/warm1+9/circular条件を維持する。この探索は既存数値監査担当への追加であり、新実装の最終独立監査ではない。原典の行根拠はsplit CTSのweighted_sum/mixture/Prediction/predict/updateとcodec Stream.bit。
