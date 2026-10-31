# log係数単独ablationと次の整数CDF診断

2026-10-06 JST。GOAL active。前turnは現費用診断とfloor両順不採用のprogress。今回はLOG_PLANの既定判定に従い、計画・code・数値/正常/不正/費用の両順検証を完了した。新形式の製品実装・全archive/真正未見・Zstd等との公平比較・独自性/量子研究・4native OS・7-Zip総合優位という元の要件は未達のままで、namespace screenへ置換していない。製品Rust/API/version/Cargo生成物/Git/外部/他版は変更なし。

## log候補の契約と独立確認

LeafCostsは同じlog2式のuniform/pure係数だけをFit構築内で保持、型のsizeは144B。compact初期leafはNoneで旧式、cached候補でも0count skip/i順の個別乗算加算、strict<、compact→uniform→pure→split、候補重複skip、dominant同点先頭/low同点優先を維持。既存shape/allocation/empty全子孫/parent-sum/CAP/CDF/writer/CRCを残した。追加global/runtime cache/heapなし。ただし型144B＋6参照48Bは全stackの厳密上限ではなく、Option/candidate/spillまで含むpublic実生成コードの確認は採用前に必要。今回は不採用なので製品のSCRATCH_BOUNDを変更せず、厳密stack検証を済ませたと主張しない。

opopの独立read-only analyst log_cost_contract_auditがHardening/Testerを5files/10分以内で確認し、cache本体の採用阻害は静的範囲で見つからず、診断probeの不正kが旧Errから新panicへ変わる点を指摘した。新probeにuniform(k)?の同じ拒否を戻し、k0/1/5/usize::MAX×pure false/trueを比較した。これは診断の修正で製品不具合ではない。leaf probeは本番compact初期のNoneを直接覆わないので、Fit全nodeと全frame/cross復元を併用。要求analyst/fork none/上書きなし、tool roleとローカルanalyst.tomlの設定はgpt-6.1-sol mediumで一致。子からruntimeモデル識別メタデータは取得不能で、実際に確認した作業は読み取り専用/編集・build・外部通信・追加委任なし。

## 両順の数値・frame・費用

log_compare.ps1 -Attempt log-a、session64720 exit0。逆順は -Attempt log-reverse-a -Reordered -ReuseReportSHA256 528B1503F136BA6FE0CA791668CCE0AB0CF6385C98A44E330E4F52197CB443B9、session73497 exit0。同EXEを使用し入力順とpair順を反転、モデル/path/probe差分を逆変換すると現本線に一致することをrunnerが確認。両回normalized_current_product/live_pins_unchanged=true。

各回係数12vector/48slot bit一致、係数拒否8、leaf目的値4320件bit一致/拒否7、4seed×low/highの32760全node frequency/split/loss bit/bits一致、shape/parent/empty/tail/CAPのFit拒否10一致。全任意Histの総当たりではなく、同じ係数・演算順の保持とこの境界/seedの実測を区別する。短い数値childの観測RAM0は採取不能であり0B利用の証拠ではない。

各回既存11development＋空/1B、warm1+9paired。全測定frameが旧新で同じbyte/method、どちらのencoder出力も両decoderで復元一致。各回1440切断/CRC再封印変異の正常/エラーが一致、1372拒否。68受理は空body切断とheader CRC等の変異が原frameへ戻る既知ケースであり、全変異拒否を主張しない。これら11件は未見ではない。

| namespace screen | 旧encoder合計median ms | 新encoder合計median ms | 変化 |
| --- | ---: | ---: | ---: |
| 通常順 | 540.2359 | 522.7403 | -3.24% |
| 独立逆順 | 514.4468 | 509.9574 | -0.87% |

通常順では改善したが、逆順は0.87%改善で、事前の両回2%以上に届かないため**今回のOption係数実装は不採用**。一部MDL入力や通常順だけの改善を一般的性能利益へ読み替えず、同条件を盲目的に追加再測定しない。libm削減が全時間の支配項だとも断定しない。public/7-Zip速度は今回測っておらず、製品へ接続していない。

compile7782.0276ms、観測private245260288B/WS203534336B、512MiB内。log_compare EXE1148416B SHAD2D448E510AA276CCB919B4957E6E63AB1148C6AB865318CF3CBCF557581EDA4。

| build内report | B | SHA256 |
| --- | ---: | --- |
| khc-model-cost-log-a-20261006/report.json | 14896 | 528B1503F136BA6FE0CA791668CCE0AB0CF6385C98A44E330E4F52197CB443B9 |
| khc-model-cost-log-reverse-a-20261006/report.json | 23436 | 3CCC3784A0E72E3418188B4E5D24BBAAC617046D1EC238588EA7A8E599A41C9B |

## 次の問いへ移した整数CDF診断

同式係数だけで費用削減が十分に再現しなかったため、現在のmodel.quantize/zero経路/leaf_mode/floor回数を数えた。UNIFORM_DIAGNOSTIC_PLANを先に保存し、現mod/modelにPROFILE/path以外の変更なしをrunnerで検査。paid/model/decoder/形式は旧本線、診断counter時間は性能優位証拠ではない。

uniform_count.ps1 -Attempt uniform-count-a、session77040 exit0、13入力×warm1+9の130frame/自己復元と4counter/method安定、全byte一致、normalized/pins true。

| MDL入力 | quantize総回数 | zero-count経路 | leaf_mode回数 |
| --- | ---: | ---: | ---: |
| alice29.txt | 301034 | 260893 | 186328 |
| asyoulik.txt | 287231 | 249173 | 177518 |
| cp.html | 236112 | 206186 | 143829 |
| fields.c | 165347 | 145151 | 99738 |
| grammar.lsp | 103045 | 91066 | 61064 |
| lcet10.txt | 422169 | 365394 | 262518 |
| plrabn12.txt | 372186 | 322320 | 231330 |
| xargs.1 | 114405 | 100672 | 68418 |

合計quantize2001529回、zero1740855回（86.9763%）、leaf_mode1230743回、floor734178回。非MDL3件＋空/1Bは0。floor集計が前の正本診断と同じであることも確認。**これはsource経路の回数であり、実際のsorting/libmの機械命令回数や総encoder時間の87%ではない。** LLVM共通化の可能性は残る。

compile4292.2391ms、観測private198443008B/WS158437376B。EXE1056256B SHABAB209CE394EB672F34DD0F5251D51D7AE4FA996E301B28048E43A2441EECB9E。report13733B SHA4B86B503095BF62398447B45E212CB8D5B21B30B2255BAAB03E87D5325A696DE。

## 基礎E2E・台帳・清掃

元scopeの9E2E成功とcurrent source SHA同一を開始証拠として引継ぎ、終了時も7target/同9件を--test-threads=1で直列再実行、7580.6207ms全成功。固定all.groupとUNLHARE_KHC_FIXED_INPUTはRESULT_20261006.mdと同じ、normal出力のみ新規build/khc-log-public-e2e-20261006へ分離し2099617Bを保持。hardcoded hybrid7096466B/product6434048Bも実際に走査し各8MiB以内。新unit/Cargo再buildなし。このE2Eは現本線の維持を確認したもので、棄却候補の製品統合証拠ではない。

Modernizer/Intel非該当（local固定契約、依存/外部仕様変更なし）、Normalizer/Hardeningは現本線が最適でCDF等全guardを維持、Cleanerは無関係整理不採用、Performance/Startupは係数案不採用・現方式保持、Asyncはcacheのローカル所有/Drop/操作分離を確認し現状維持、Testerは不正k probeを修正・数値/frame/拒否証拠を追加。次のcanonical CDF案はまだ証拠不足で採用済みではない。

cleanup-log-symbols.ps1で今回のlog/uniform診断PDB2本、計2818048B（約2.69MiB）だけをごみ箱へ移動→今回分を完全消去→元/実体/管理情報不在を確認。ledger build/khc-log-cost-symbol-cleanup-20261006.json state complete/Count2/既存bin不変。EXE2本/report3本/旧成果物/sourceは保持。再生成可能なsymbolの清掃であり既存/sharedcache/x86を扱わない。

最後に8Rust全fileの固定rustfmt check、3PowerShell parser、関連文書git diff --checkがexit0。mod/model/paid/packetと成功3reportのSHAは開始/測定値から不変。専用追加診断build2256737B（約2.15MiB）、今回normal E2E2099617B、scope全source326998B（この最終追記前）。Cargo6163555929B/固定cap6175228536B/残11672607B、増加0B。free48437882880Bで5GiB条件を満たす。他作業による大きなfree変動を本清掃の効果とはしない。再取得GOALはactive、update_goal pause/completeは呼んでいない。

## 次の実行

次はzero-countで得る固定CDFの再利用を独立ablationにする。k2=[16384,16384,0,0]、k3=[10923,10923,10922,0]、k4=[8192,8192,8192,8192]が元のHamilton結果と一致するかを先に比較し、等重みの剰余同点時先頭2個へ加算するk3も保持する。quantizeのprefix/tail/CAP/valid_frequency拒否と非zero計算を残す。counts総和0なら全要素0という整数条件でのみ再利用し、public/API/形式は変えない。旧新版の数値・拒否/全frame/self-cross/capacityと、計測器なし両順を見て採否を決める。速度利益がなければ棄却し、強い全archive/真正未見/7-Zip gateへつながらない微小改良を同一条件で反復しない。

