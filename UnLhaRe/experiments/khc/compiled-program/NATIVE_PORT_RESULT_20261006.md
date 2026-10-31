# 製品compiled decoderのE2Eとnative全書庫実測

2026-10-06 JST。前GOAL質問応答は状態確認だけ/no progress。本工程は7件の現製品E2E、最大全可変Forest、全11fileの実CLI復元・全byte比較と新native（warm1+9paired、通常・逆順）を実行したprogress。GOAL active/7-Zip総合優位未達、固定ゲート不変。

## 製品native実測

Windows x64 / Ryzen5 7640HS / fixed Cargo Release CLI SHA256 `71EF1B98BC3CDF3477E39C6C4B823E10291A77DBA1590007F4667C687C266295`。公開Release rlib `9D3BAEC4C907A80B043E7CE2DFDA2CC8AC0C483FE18DD82070E7DF7E085659BF`。同一CLIと書庫を両順でpin、終了SHA/mtime/bytes全一致。データは既知Canterbury開発11file/2810784B、真正未見でない。

KHC書庫466395B（frame465951B+container444B）、7z481490B。7za26.03/mx9/mfb273/md4m/mmt1、実LZMA2辞書3MiB/solid1blockは全入力を覆う。全費用でKHC3.135%小さいが、率5%ゲート457415Bには8980B足りない。

性能は `khc-test` 対 `7za t -mmt1 -bd -bso0 -bsp0`、全復号+CRC。warm1+9pair/各順、全sample保存、外れ値除外なし。process start/exit wallとharness wallは別記録。抽出書込時間の比較ではない。

| 順序 | KHC median/min/max ms | 7-Zip median/min/max ms | KHC/7Zip |
| --- | --- | --- | ---: |
| KHC→7Zip | 83.3478 / 81.5088 / 85.7733 | 40.8648 / 38.8921 / 42.6801 | 2.0396 |
| 7Zip→KHC | 83.2266 / 82.2744 / 86.2151 | 41.5265 / 40.6515 / 42.4319 | 2.0042 |

過去pre-port149.4961/149.2002msより約44%短い値だが、旧CLIと同sessionでpaired比較した結果ではない。試作namespaceの両順約52%をnative短縮へ転用しない。今回から製品経路も大きな短縮を支持するが、なお7-Zipの約2倍の復号時間。encode新測定もなく総合優位を宣言しない。

全有効sampleでmemory採取あり。KHC最大観測private4915200/4943872B・WS8601600/8552448B、7Zip5517312/5521408B・WS9695232/9240576B。private sampled/OS peak WSで全瞬間peak保証ではない。CPUはOS tick粒度が粗く、細かい倍率には使わない。child64MiB/60秒、suite300秒、quiet15%/最大60秒、work8MiB/free5GiBを維持。Cargo追加0。

各順で先に現CLI `khc-extract --output ... current.khc` を実行し、全11元fileと65536B bufferの逐次全byte比較、件数/総byte数も照合。元書庫の過去CRCだけを現在の完全復元証拠にしなかった。

成功report（build配下）:

- `khc-native-program-paired-b-20261006/report.json` SHA256 `57386BB884619708E478F26AAB4FE6D57A304B59BBDFD142E4AA29CE3F11711D`。
- `khc-native-program-reverse-b-20261006/report.json` SHA256 `CBDF60EB24607C57406951FC1C46FB3C5D59A5C960CE2C674BAACF691B8ADD2E`。

runner `native-port-compare-b.ps1` を保存。初版はCLI outputオプション欠落でexit2、測定pair0件の失敗report `khc-native-program-paired-a-20261006` を保持し、初版を上書きせず派生bで是正。これを製品不具合や成功測定と数えない。

## E2E更新と最大モデル

前PORT_PROGRESSのnormal2件に加えて現Releaseライブラリを使用する既存6入口/7件が実行成功、Windows計9件。公開API/実CLI、破損30件と回復、書庫破損/切断/余剰と失敗entry非公開、names/limits/cancel/no-replace/race、56×3strategy/CLI/no-clobber、source交換・負時刻丸めを確認。

| 入口 | 件数 | runtime report SHA256 |
| --- | ---: | --- |
| khc_block_normal / b | 1 | 3E926B5F8CABE44730DBFEFAFC0E57F7300B40968211BDD014E3752218BF2821 |
| khc_block_adversarial / a | 1 | E4D3A5CA1C33F86404D090005EC756C64FABCA15F63EB5F70DBFA8B7FFA8A5A6 |
| khc_adversarial / b | 2 | EE1C099374D20A5A5C0B9C799C6F3378C0B89A407F4DC94CC090D137D8BDA701 |
| khc_hybrid / a | 1 | F6E47E9E1A5E6A6C161514D9DC94C6678605511FB0D7F0787C50CAF04B8B80A6 |
| khc_state_safety / a | 1 | 66DF42E77F00AA1550A69942A2AAD5BE947BD2073E141083334EB22DCEA3A0A9 |
| khc_model_boundary / a | 1 | 9CFE56D3EB71F7BCA0905D876F57A98D3A6C611A5F6399C00AEFF7C2641C0D94 |

各rootは `build/khc-program-runtime-{入口}-{suffix}-20261006`。block normalはfixed all.group SHAを実際に指定し、3frame156483/237176/119861B、固定基準157149/237852/120312B以下・全byte復元。encoder変更による今回の率改善とは数えない。

既存khc_model_boundary入口を拡張し、新unitは追加しない。独立wireの全852root/fullsplit/履歴1023のみpure、他uniformで全descriptor variableにする。製品encoder payloadは借用せず独立uniform Rangeを使用。

- uniform model363832B、公開復号31.0032ms/1MiB完全一致。
- full-variable model364009B、872448行/6979584B frequency、公開復号36.3593ms/1MiB完全一致。
- descriptor保持10264B、再確保旧buffer最大4194304B/scratch24576B、Program78000B/transient65536Bを既存64MiB gateへ計上。その場CDF化で2つ目の巨大frequency配列なし。容量値はコード・wire幾何の計算であり、sampled process privateと混同しない。

分析担当compiled_model_memory_audit（要求/役割実効gpt-6.1-sol/medium、readonly）がHardening実害穴なし/Tester全可変公開経路未検証を返し、親が実装・実行して穴を埋めた。担当は編集/compile/Git/外部通信なし。

block normalのみCargo Release no-runも成功。残5入口は製品Cargo Release rlib/CLIをsource・SHA確認後、単体rustc --test/opt3/codegen1/lto=off/debuginfo0でcompile。試験harnessのLTOだけ切り、製品library/CLIは不変。これはfull Cargo bundle/AOT/clippy全targetの成功ではなく、現製品実API/CLIのRuntime E2E。最適化設定の異なるharness時間を性能比較に使わない。短命テストでRAM値0は未観測（sample countが正でも0なら不明）、0B peakを意味しない。

## 資源・監視の失敗と清掃

開始Cargo6169422174B。khc_block_adversarial Cargo compileはLTO一時objectの生成5991047Bで、観測6175413205B/cap6175228536Bを184669B超えてowned treeを終了。予測4MiB以下は誤りだった。samplingはハードquotaではなく、一瞬も超えなかったとは言わない。finallyのGuard再throwで元stdout/stderrは未保存、失敗を手動回収reportに明記。source/objectsのhashと生成時刻を残した。Cargo失敗を成功へ置換せず、容量上限も広げなかった。

今回生成6objectだけを各絶対path/hash/時刻/no-reparse/停止確認し、共通CodexCleanup moduleでrecycle→今回分purge→元/$R/$I不在。台帳のIDは49ec3920e1674b34b303b3d8cc60b3b5、4e2db4d0d4724667b638d753e4f73d16、22bd485958a048dcbbc51f055fda537e、d953a24fbd954888aaedb7307e5e85df、c65e9e118f7d4d18b07e59e51f90ca82、19a94d401575473ebe933bedfb235587（C:/Users/IMT/.codex/artifacts/recycle-cleanup/cleanup-{ID}.json）。全complete。共有依存/固定EXE/過去成果を削除しない。終了Cargo6169422158B、cap内/残5806378B、開始より16B減。

監視側の空directory Size.Sumとpolicy result.json誤要求も失敗として保持し、是正後の別attemptで成功。生成rootをPID単位で守り、既存shared test root全体を8MiBへ無断で削らない。harness source修正はapply_patch、Rustfmtは成功。

native両順の今回復元copy22file/5621568Bだけを全byte/hash/report完了確認後に同窓口で清掃。台帳cleanup-2ddd061179c54ab5973430a6e510a658.json、cleanup-9b2a7d7f26744c67ae10378580977d32.jsonはcomplete/元/$R/$I不在。report SHA不変、固定corpus・書庫を保持。完全消去後はごみ箱から復元不可だが元書庫から再生成可能。

新生成E2E EXEは再実行用に保持、各専用root8MiB内。新build群約9MiBと小さいfixture/ソースを保持（Cargoと過去実験とは別）。大規模download/cache削除/new Cargo target-dir/version/Git/公開なし。

## 次の根拠ある工程

旧phaseはpre-port CompactTreeの診断であり、現Programのphase比として引用しない。まず現modと正規化一致を検査する別の診断profileを作り、新製品公開APIと全frame復元を照合してから、現在のtoken/run・inverse・method3の費用を測る。なお約2倍の速度差と8980Bの率不足、encode/真正未見/Zstd/独自性一次研究/4native検証をGOALから外さない。採用基準を緩めず、同じ棄却候補の無根拠再試行をしない。
