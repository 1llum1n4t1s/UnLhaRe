# CTS整数式の等値頻度 — 実装前の診断契約

前turnのlog2表は全数値/full E2E・独立照合を通過したが静穏性能未測定、研究基準はexact-divのまま。再開時CPU37%でpreflight拒否。固定条件を緩めず、性能に依存しない構造診断としてCTSの厳密shortcut条件の成立頻度だけを数える。深さ/モデル/係数/wire/学習順を変更しない。まだshortcutを実装せず、元式を必ず最後まで実行する。

## 算術上の候補と反証

- validated weight in[0,Q], kt/child in(0,Q), Q=2^48について、kt==childなら `(weight*kt+(Q-weight)*child)/Q == kt`。元のchecked演算/確率検査を今回は実行したまま、等値だけ記録する。
- updateのvalid pk/qについてpk==qなら `floor(weight*pk/q)==weight`。補数時にも同値。qを先にprobability検査する点、weight範囲は将来shortcutにも必要。
- posterior==Q/2なら `alpha+floor((Q-2alpha)*(Q/2)/Q)==Q/2`。alpha/retainedの元検査を保持する必要があり、近似や浮動小数の同値ではない。

成立頻度が低ければ追加branchが速度を損なう可能性がある。counter割合は除算の時間割合でも速度改善率でもない。元式を削除しないので元のoverflow/error経路は保持される。prefix/count/history/class/観測順のsweepや既存不採用案の再名称化はしない。

## 所有と配線

新causal-bayes-equality-probe/{codec.rs,cts_model.rs}だけを作り、exact-div codec/CTSをcopy。BWT/exact_div/Bayes/range/packedは凍結sourceへの相対参照。codec変更はmodule参照、CTS diagnostic Statsのencode/decode payload戻り値からStats/JSONへの配線だけ。CTS変更はstream所有counter、predictの可変borrow、loop内checked counter加算、取得APIだけ。グローバル/atomics/Cell/時刻/配列追加/モデルstateの変更なし。counter更新はモデル計算を終えた成功イベントだけに対応させる。

各classにpredict_bits/update_bits、kt_calls/kt_fresh、mixture_calls/mixture_equal、posterior_calls/posterior_equal、retained_calls/retained_halfをu64で保持し、モデル全体へchecked合算。各成功encode/decode JSONへ同名cts_ fieldsを追加する。各streamで初期0、encodeとdecodeの全counterが同一でなければ失敗。元fieldとframeは維持。終わりのsuccess Statsは predict_bits==update_bits、kt_calls==bits*17、mixture/posterior/retained calls==bits*16、各hit<=callsを満たす。false/true bit双方、leafはposterior/retainedに含めない。

所有build root C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-equality-probe-20260930/。Rust1.98.1/edition2024/opt3/panicabort/debuginfo未指定。instrumented binaryの速度を採用せず、busy hostでもcorrectness/非時間counterだけを検証できる。

## 先に列挙する失敗と実証

source差分範囲超過/モデルstateや更新順変更、未検査q/weightから等値判定のshortcut、counter overflow/欠落/leaf off-by-one/条件の混同/stream共有、成功JSONの型/数値/式違反、encode/decode不一致、frame bytes/hash不一致、CRC修復負例拒否漏れ、既存output上書き、source/binary/proof途中変更、既存work上書き、無効schemaを成功扱いすることを拒否する。

元36 checks/61 CLIの全codec E2Eを凍結exact-div referenceとのcross/full byte hash/11metadata/CRC修復攻撃/上限/no-clobberで実行する。別counter proofは保存した全成功JSONに上記整数・合計検査を適用し、同じfixtureのencode/反復/decode全counterを比較する。固定groupのcounter割合をそのまま保存する。独立read-only担当がsource許可diff/算術identityとoverflow境界/実exit/JSON集計/現物/proofを照合する。新unitなし、診断を製品や通常codec hot pathへ入れない。

成立回数の証拠を得てから、十分な機会のある厳密shortcutだけの独立実装契約を別に固定するか、この案を不採用にする。counterだけでは性能採用・総合7-Zip超過・holdout・platform勝利にしない。静穏log-table/float比較も未完了であり、新candidateを黙って研究基準へ採用しない。新依存/Git stage/commit/push/version/公開、既存policy拒否/cache/UnLha32Re/registryへの操作なし。
