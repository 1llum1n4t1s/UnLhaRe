# 整数CDF案の棄却と実全書庫比較

2026-10-06 JST。GOAL active、元の全archive/真正未見/公平7-Zip総合優位/研究・独自性/実装統合という要件は未達で維持。CDF_PLANを先に保存して実装・比較し、両順条件不成立で製品へ接続しなかった。未達の全書庫評価を実行し、次の調査対象を圧縮側micro処理から実全書庫の展開側へ変更した。製品Rust/API/形式/version/Cargo生成物は変更なし。

## 整数CDF候補

prefix/tail→raw/CAP検査後のraw==0だけ元Hamiltonと同じ3CDFを返す。valid_frequencyを残し、非zero・paid/Fit・float・同点・decoderは不変。2codecのpath/public診断指定以外、2modelのCDF FAST範囲以外が現本線に一致することをrunnerで確認。global/heap cacheなし。

cdf_compare.ps1 -Attempt cdf-a、session72638 exit0。逆順は -Attempt cdf-reverse-a -Reordered -ReuseReportSHA256 2EF809566FFDE238A7C29C545DED670CFCF90E3B9D22DEFF1A953AAF52B7084C、session89149 exit0。同EXEでinput/pair順を反転、両回normalized_current_product/live_pins_unchanged=true。

各回quantize21654件（成功14675/同Err6979）、成功CDFのleaf_mode/compact_frequency、別の不正CDF7件が完全一致。3zero/全small/全境界/4096seed各kを含むが全u32/全Histの総当たりではない。同値CDFと同じ演算/選択を維持する構造の確認を併用。各回13入力warm1+9pairedで同frame/method、自己/交差byte復元、1440変異の結果/同エラー一致（1372拒否、68は原frame等へ戻る既知受理）。入力は既知developmentで未見ではない。

| encoder namespace screen | 旧median合計ms | 新median合計ms | 変化 |
| --- | ---: | ---: | ---: |
| 通常順 | 551.2483 | 521.1555 | -5.4590% |
| 独立逆順 | 529.3937 | 529.0360 | -0.0676% |

逆順で事前の両回2%以上短縮へ届かず**不採用**。MDL各入力5%悪化条件は両回通るが部分条件だけで採用しない。非MDLのLZは不変でもkennedy/sum時間が変動、微小差・呼出回数87%をCPU時間比へ読み替えない。第三の再測定で都合のよい回を選ばない。

compile7244.1448ms、観測private243400704B/WS201117696B。EXE1133056B SHAE3E145286C217225625360BF4507BA149D3C72C8BCB45F85DB87D7B01005F80E。短い数値childのRAM観測0は採取不能で0B使用ではない。

| build内report | B | SHA256 |
| --- | ---: | --- |
| khc-model-cost-cdf-a-20261006/report.json | 14524 | 2EF809566FFDE238A7C29C545DED670CFCF90E3B9D22DEFF1A953AAF52B7084C |
| khc-model-cost-cdf-reverse-a-20261006/report.json | 23067 | 29DA0A833B30D7C40024B734FFBF538D3B200DE341DF795F1C3E5C5053269441 |

## 実native全書庫

固定11file/2810784Bを実製品CLI binary-adaptiveのKHC、固定7za26.03のnative7z/LZMA2/solid/mx9/md4m/mfb273/mmt1へ保存。実listing Solid+/Blocks1/Method LZMA2:3mを確認。指定4MiBに対しproperty3MiB、全入力をカバーする。CLI SHA9CAF52385AE3EDEC09D16D6D431F1146B8F1D2FB43A75E9AB0F58D97EAA38820、7za SHAEDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0。現source同一と既存E2Eの継続性は確認、今回CLIを再buildしたprovenanceは作っていない。

| 全metadata込みarchive | B | SHA256 |
| --- | ---: | --- |
| khc-native-archive-native-a-20261006/current.khc | 466395 | C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE |
| khc-native-archive-native-a-20261006/native-solid.7z | 481490 | F26CA2BA262964FC601D544D860280BCC07A984243828F02DC6DFDC5849F8A78 |

KHCは3.1351%小さいが固定率ゲート5%未達。KHCはentry独立block、7zは実solid。5%条件のKHC整数上限457415Bに対し少なくとも8980Bの追加削減が必要。ただし他強設定/真正未見でこの値が成立する保証はない。

単発create KHC600.4743ms/7z966.2922ms、native test KHC174.1217ms/7z56.5378ms。9paired/別順/誤差/最大RAMの合格証拠ではない。create観測private24973312B/37027840B、test5414912B/5509120B。短いchildの0観測は欠測。実extractはKHC時刻保存API192.192ms/7z73.7776msだがCLIとhelperの起動経路も違い勝利判定には使わない。遅い方向の所見を次の原因切分けの仮説とする。

## 診断失敗を是正して復元確認

native-a（session18486 exit1）はcreate/list成功後、guardがLZMA2:22表記を決め打ちし失敗。v2は同じ成功archive/report/source/EXEをSHA照合して再利用、create重複/コピー/旧report書換えなし。実property3MiBが全入力以上/指定4MiB以下を確認。公式LzmaEncProps_NormalizeのreduceSize処理と実listingを区別し、一次出典はNATIVE_ARCHIVE_CHECK_FIXに記録した。v2生成時の引用符/重複tail構文エラーもparserで発見し、work不存在を確認して実行前に修正した。

native-b exit1は双方test/extract exit0後、KHC既定CLIのmtimeで失敗。現ExtractOptions::default().preserve_timestamps=falseという契約で、製品を変更せず検査も削除しなかった。NATIVE_RESTORE_PLANを保存し、archive_restore.rsを実Release rlibにリンクしてpreserve_timestamps=trueの公開APIで確認。builder exit0/report601BDB694B94EEB78A321D5682652D993316CF18250B7B51F87E6DF0D92A5E0D、EXE1058304B SHA865B7652CF7C12B19D52D9B043A9E5A080AEAB25D5997C97826B1D8FA410AABB。

native-c exit0。同じ作成済みarchiveで11file×2の全extent/SHAと可逆base64全byte比較、全mtime（KHC秒/7z100ns）を確認。余分なfile/reparseなし、native test/実restore成功。両failureも保持し成功へ上書きなし。manual URL404は未取得で、根拠には使わずactual CLI/sourceで確認した。

| build内report | B | SHA256 |
| --- | ---: | --- |
| khc-native-archive-native-a-20261006/report.json failed | 15101 | C2C97D61C9B55BD3311DEB326C65AD44AEA4EB393212B680A99310B227555197 |
| khc-native-archive-native-b-20261006/report.json failed | 26542 | D0E3201E9AD388FB6B3E78A266AD8D3F587FDFC0A8AAD8DECB5E5EF66B42240F |
| khc-native-archive-native-c-20261006/report.json completed | 41305 | 18E70562A567D520B57C4CD7FDC11F5B67C502C218933E6E5B2419DFBCB83D3A |

## E2E・容量・観点

開始LOG_RESULTの9E2Eとcurrent mod/model/paid同SHAを引継ぎ、終了同7targetのEXE SHAを照合、--test-threads=1で9件全成功（8.2311701秒/exit0）。固定all.group/envはRESULTと同じ、normalのみ未使用build/khc-cdf-native-public-e2e-20261006。56×3/CLI/複数block/空/archive、最大split、30故障/回復、CRC前公開拒否/no-clobber/limits/cancel/source差替えを確認。新unit/Cargo buildなし、棄却候補の製品統合成功ではない。

cleanup-cdf-native.ps1は更新AGENTSに従いCodexCleanup.psm1を直接呼び、今回PDB2本＋生成restore directory4個だけ、計14028416B（約13.38MiB）をrecycle→今回分purge→元/$R/$I不在確認。UTC/byte/リンク/使用中/restore11fixture SHAを事前確認、6module台帳complete/既存bin不変を再照合。summary build/khc-cdf-native-cleanup-20261006.json SHA B0CBFC718635A2B080624EDDA36D97524BBEAC0E1BF12E3F16F8859C04EE5EDF。再生成可能symbol/復元コピーはごみ箱から復元不可だが元corpus/2archive/2EXE/report/sourceは保持。削除hook変更なし。

専用6work清掃後3269741B（約3.12MiB）。normal E2E2099617B、hybrid7143386B/product6439199Bも各8MiB内。Cargo6163555929B、固定cap6175228536B、残11672607B、増加0。free48303833088B。scope source467444B（本結果等追記前）、追加source約140KiB。診断是正codeは再現に必要で保持するが製品通常経路へ並存方式を追加しない。

opopは親が全必要観点を確認。Modernizer/Intel（CDF）非該当、Normalizer/Hardeningはguard/同点/エラー維持、PerformanceはCDF不採用・全書庫ボトルネックへ移る、Cleanerは無関係整理なし、Testerは差分/悪性/E2E/診断前提是正、Asyncは資源寿命/状態維持、Startupは無用定数を製品へ追加せず維持。7Zip辞書は一次sourceとlistingを照合。局所調査で独立した大きな担当がなく新agentなし、親が所有。

## 次の実行

保存全archiveで9paired＋別side順のnative testを行いdecoder不足が再現するか確認する。起動/IO込み・process CPU・RAM欠測を分け、public APIでframe種別とdecode段階を分解。BWT逆変換/range/forestのどこが差を支配するかを現sourceで確認する。原因成立後、圧縮率を維持する大きなdecode改善または方式見直しを実装・交差検証する。元GOALのnative強設定/真正未見/独自性・量子/Zstd/4native等は残り、complete/pausedにはしない。
