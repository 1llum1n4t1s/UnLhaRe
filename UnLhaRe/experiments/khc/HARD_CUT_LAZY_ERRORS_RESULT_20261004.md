# Hard-cut遅延エラー構築の因果診断結果

親の単回runner exit0。compile1、native3（旧/候補selfcheck各1、同一process固定比較1）。原engineのok_or(String)2箇所だけをok_or_elseへ変更した別private候補であり、製品採用・正式速度成功ではない。

| 計測付きGlobalAlloc trait呼出し | 旧 | 候補 | 減少 |
| --- | ---: | ---: | ---: |
| encode全API calls | 76505261 | 7651337 | 68853924 |
| decode全API calls | 76505215 | 7651291 | 68853924 |
| encode要求bytes累積 | 1308972449 | 161407049 | 1147565400 |
| decode要求bytes累積 | 1274169483 | 126604083 | 1147565400 |

要求bytesは累積要求でありresident RAM・物理malloc bytes・ディスク使用量ではない。run_profile/run_restore内部のstats/Proof整形は含むがread/直接比較/Debug/reportは測定外。allocator instrumentationがcodegenへ影響し得るため、非計測binaryのallocation/正式速度へ一般化しない。計測付き時間は正式速度に使わない。

観測減少はcoded枝3825218×18calls＝68853924、同枝×(12×16B+6×18B)＝1147565400Bと完全一致。6node各2log+1priceの成功時エラーString構築を避ける因果と整合する。残る約765万callsを今回の2箇所改善に混ぜない。

両側の全frame478856Bをメモリ上で直接比較し一致。各側全2811006B plain一致、encode/decode typed Proof14全Eq、両側fullstats/Debug全14field一致。cross-type Debug比較をtyped Eqとは主張しない。旧wire成功の全statsとProof（cdf bits4705461279319865477）も再照合。各selfcheck正常14/破損34/短header4を通過し、全厳密reasonのJSONは旧成功と一致。固定入力再encode0。

pair実peak WS55541760B/private52129792B、selfcontrol WS15519744/private12763136B、selfcandidate WS14974976/private12701696B、3childとも160MiB以内。source boundはmodel21561264B/encode45723494B/inverse48522666B/BWT142647787Bで実peakとは別。

出力EXE518144B+report115933B＝634077B、disk input/frame/plainコピー0、owned process0、終了空き60065288192B。report SHA52B58473E868E882886E8A89E46CE910CD72FDACFBDFD5DBED0E96EA302DF953、EXE SHA604C538D01709DD01EB9C028E7DF63E9CD5EC2CFD7FF92C8048C4F7448350512。runner SHA0FF1547A4A7B2419E67F2B140D73E419ABEB30A0A16F564C8809179EE4C5F11E。

親verify-readonly SHA71B58C904E4CF4DE5CBAF6B7F4B987AE0E489CCEB2562842023DD89C9B8F7E29単回exit0：131組before/after/live、EXE、raw stdout3と保存JSON、全finite evidence、全fixed stats/Proof、counter算術とsource機構、3実peak、出力形状を再照合。追加compile/native0。source21/edge22/143743B。原engine2置換/両codec scope import各1、数値処理/更新順/error text不変。

次はcustom allocatorを含まない通常private wireの実圧縮/復元を確認し、単回診断時間を観測する。その後にquiet/warm1+9/全CLIの正式比較を判断する。速度/holdout/category/完成書庫metadata/API/4native/総合GOAL未達。製品dirty/Git/version/x86/外部不変、削除なし、GOAL active。
