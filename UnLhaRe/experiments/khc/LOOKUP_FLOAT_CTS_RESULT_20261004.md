# Lookup-assisted f64 CTS/pool：固定screenと内部診断

## 結果

一構成depth5・private `KHQCFP01` は数値/standalone E2E/固定size screenに合格。旧・新・新・旧の一周では両方向の内部時間平均が短く、研究候補として保持する。製品採用・正式性能合格・7-Zip総合超えではない。旧Q32基点、公開API、version、依存、x86版は変更していない。

| 単発内部診断 | 旧Q32 | 新lookup f64 | 変化 |
| --- | ---: | ---: | ---: |
| 完全frame | 478750 B | 478750 B | 同じ長さ、異なるmagic/payload |
| encode平均 | 6460.97140 ms | 3727.53740 ms | −42.306858% |
| decode平均 | 6195.55540 ms | 3945.27895 ms | −36.320819% |

warmup0・各2回だけの診断。旧encode 5884.0172/7037.9256ms、新3551.3304/3903.7444ms。旧decode5809.1083/6582.0025ms、新3517.8825/4372.6754ms。変動があり、静穏CPU・OS資源・全CLI・同session7z比較は未実施。固定encode574.5624msへの達成を主張しない。旧normal BT5/Beamの既往約1001.5msとも同条件ではなく、新float候補を既存最速と呼ばない。

## 実装と検証

canonical integer l/e/count gridをstreamごとに生成し、CTS KTとposterior・pool score/gradientを順序固定f64へ変更した。KTとsoftmaxは分母の逆数を一回計算して各childへ乗算。hot modelのln/expはgrid補間、audit entropyは旧と同じ直接log2。integer Q32軌跡への同値は要求しない。

- numeric：ln17ケース、exp105ケース（cutoffの各整数倍と隣接f64を含む）、拒否14。KT/CTS・観測前posterior・pool/gradientを独立式と比較。絶対誤差上限ln/exp2e-7、pool1e-6。非対称fixtureのCDF8331/3154/10811/10472。
- standalone E2E：14正常inputの全byte roundtripとrepeat frame、33malformed、26モデル拒否の全state直接比較、CAPちょうどの成功1、短いdepth header4、CRC既知値。OOM/I/O故障注入・一般8MiB入力保証・4nativeは未検証。
- fixed group：2811006Bを各方式で全byte直接復元。screen新2encode/2decode、repeat frame478750B全比較、全Proof14・statsとCDF entropyのbits比較。ABBA4encode/4decode、全plain4件、方式別repeat frame2件、全Proof14一致。旧decoderの新magic拒否も直接確認。
- 新frameのplain CRC433441561、payload CRC17854043、header CRC2461320180、grammar digest58735a2b7383d755。旧frameと長さは同じだが全byte同値ではない。

## 実行経路の修正

初回 `verify.ps1 -Execute` はcompile3118.4676ms/exit0まで成功したが、`CLI` がPowerShell標準の `Clear-Item` aliasへ解決し、numeric child起動前に失敗した。対象numericの不存在エラーで、圧縮モデルの失敗ではない。元runner/失敗report/EXEを凍結した。

親が新 `run-native.ps1` を作り、元runnerの固定hashから6関数ASTだけを取得。CLI定義名を一意名へ、Source内のPSScriptRootを明示した源泉rootへ束縛した（CreateしたScriptBlockではPSScriptRootが空）。最初のこの束縛漏れはnative root作成前に検出し修正。元entry pointは再実行せず、作成済みEXEをreuseして追加compile0、4native CLIすべてexit0/stderr0で完了した。旧失敗root/reportは上書きしない。

元runnerは失敗済みの凍結証拠で通常の検証入口ではない。保持EXEの検証入口は `lookup-float-cts/run-native.ps1`（使用済みnative-validation rootは拒否）。有利な時間を選ぶ再実行、係数/depth sweep、priority/affinity/power変更、他process停止は行っていない。

## 識別値・容量

最終report `build/khc-lookup-float-cts-20261004/native-validation/report.json`：44523B、SHA `ED68C60740B751F8C02118A778F1330B207F37AECE42EEB6362AFC02BF97CD52`。

compile後の旧失敗report：24094B、SHA `7C584FBBE7E1FE3AFBBE5A0720284E39B15F3BFAD73C44F4980B99CD230A1D15`。EXE401920B、SHA `3274FF23398853F7214D0FAAA68BAD16E90272E0AB904461866D245A389BE05C`。run-native SHA `02BC803318126E3537E36BB8A8072FB23C64E4E1084F44A8DDEA53553F16D472`。

19source・18edgeの閉包とrunner/旧runner/旧report/EXE/input/guard/両planの27identitiesを親が実行後live照合し、SHA・bytes・UTCticksの差0。固有EXEの残存process0。compilerはRust1.98.1、Windows x64、opt2・overflowyes・panicabort・debuginfo0・DEBUG:NONE。compile警告3（新codec未使用import2、旧CTS re-export1）でエラーなし。

最後のreport保存後に親がdisk-budgetを再実行：生成物3file合計470537B（約460KiB）、8MiB上限以内、C:空き72209039360B。report内disk_after456724Bは最終report serialize前の観測で、最終使用量ではない。source/planは生成物容量とは別。frame/plain/input copy・Cargo target・PDB・rawtrace・削除なし。成果物は再現証拠として保持する。

独立readonly analystも、初期失敗→native before→afterの76identity対と現在27identityの差0、Proof14/CDF bits、平均・短縮率、最終3file容量とprocess0を再確認した。重大な矛盾なし。数値誤差の最大実測値はreportに保存しておらず、保存されたのは上限を実際に検査した成功である。今回の検証は別数学関数実装や4nativeの同値性まで保証しない。

担当要求は実装worker-high（役割設定上gpt-6.1-sol/high）、設計・結果のreadonly analyst（同sol/medium、独立文脈）。実行時のmodel IDを別経路で観測してはいない。編集所有権はworker停止後に親へ移管した。親と独立担当は製品全体のbuild/testを再実行しておらず、private candidateの単体経路だけを検証した。最終git diff --checkは成功。

## 次の主経路

数秒かかるため、現floatモデルの予測/学習・snapshot/validation・coder/BWTのどこが支配的かを新モデル自身で帰属させる。旧integer CTS診断の割合を新floatへ流用しない。内部predictとobserveを同じ非公開transactionへまとめるなら、Snapshotコピー・再検査を省ける可能性があるが、因果順序/拒否前非mutationの維持と出力全同値を新しい先行契約で反証してから実装する。現状の短縮だけを根拠に大きな正式比較や製品統合へ進めない。

独立holdout/category、同thread/memory境界、完成書庫、同境界decode、静穏full CLI、4native/opt間のfloat軌跡と相互復号、製品APIは未完了。goalはactiveのまま。
