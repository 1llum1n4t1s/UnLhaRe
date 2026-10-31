# 4lane posterior codec: 組込み前の失敗計画

数値仕様はSIMD_QUOTIENT_CONTRACT_20261002.mdを維持する。数値E2E report FE390BBE820107F32570BFC6E416E5FA947743848131F8EB8513BFC4E02E1EDE は32 checks / 87 CLI / 10 identities。9293629件×opt2/opt3×scalar/AVX2を独立u128商と比較し、各条件の matched 9293629、batches 2323408、fingerprint e5c97b90b4768836、certificate fallback 0を確認した。これはfull codec/速度/他native OSの証明ではない。

## 状態・拒否順の契約

- 変更対象はheavy Tree.updateの16 posterior商だけ。KT大型分母・alpha・next_weightは凍結整数helperを残し、wire、Bayes、scheduler、lightを変更しない。
- leafを旧式どおり更新してから、15..12、11..8、7..4、3..0の4件単位で入力を準備する。自分のグループ内のnodeはまだ変更されていない。predictが生成した木の深さ別indexは一意であり、後続グループへの更新前snapshotと現在node weightの意味を維持する。
- 入力検査の失敗はlane別Resultへ保存し、実際のleaf→root更新位置で返す。batch内の別laneの失敗を先に返さない。無効laneは安全な0/1へ置換する。旧node/count/next_weight検査と更新順は残す。private Predictionを捏造した重複indexや破壊状態までの内部部分更新同値は保証しない。
- schedulerの世代検査・失敗時poison処理を全文対応で維持する。外部CLIでは不正frame、missing input、no-clobberを確認する。private破壊状態/全拒否分岐の実行検証は今回の全文frame E2Eと区別し、未検証として残す。

## 先行E2Eと容量

1. helper/dispatch取り違え: compiler・数値proof・原codec証拠・原source・新source/EXEを前後SHA/bytesで固定し、明示置換の全文対応を要求する。
2. AVX専用命令の誤実行: backend autoとcfg khc_force_scalar_batchを別EXEにし、それぞれ通常/overflow-checks=yesで構築。検証環境ではAVX2 feature検出済みだが、ARM64/macOSは未実行。
3. 未来学習・frame/schedule変化: 7入力×4実行条件の完全frame byte比較、encode stdout比較、完全restore比較、旧decoderへの/旧frameからの双方向restore。固定frame483496B/CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12を維持。
4. 確定前公開/既存上書き: 5種の不正frameは出力なし、encode/decode sentinel保持、missing input拒否。normal autoを外部安全検証する。他variantは正常系/checked比較のみ。
5. 容量: 出力root build/khc-causal-simd-quotient-20261002、32MiB事前/事後guard。固定inputと旧frameを再利用し、新Cargo target、raw trace、数値配列dumpを作らない。4variantのEXEとframe/restoreは最大約26MiB、JSONは限定87件程度。MSVC linker /DEBUG:NONEを指定して不要PDBを生成しない。生成済み数値PDBは別途同定して清掃する。
6. 失敗/誤った採用判断: fresh root一回、child120秒、成功でもcorrectness_and_size_passed_not_timed。既存terminal性能試行は再実行しない。新候補の正式速度評価は別契約、固定CPU15%・483599B・encode median<574.5624msなどを維持する。

製品公開API/既存dirty changes/バージョンには触れない。総合7-Zip超え、holdout/カテゴリ、同境界decode、四native決定性、製品組込みは未達。
