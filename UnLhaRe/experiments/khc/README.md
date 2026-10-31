# KHC scalar lab — 実験形式 1

製品API・LZHではなく、単一バイト列の研究用codec。互換性は保証せず、唯一のコピーや長期保存には使わない。既存codecの呼出しではなく、自前のLZ探索・モデル・整数range符号器で圧縮と復号を行う。CRCだけは既存依存`crc-fast`を利用する。

速度測定には大きな変動がある。同一binary同士の5対比較でも、入力別中央値合計に−9.26%の差が出た。論理CPU固定では+0.18%だったが反復ごとの外れは残り、固定による安定化を立証したものではない。以下の過去の速度差は各runの観測値であり、数%の差だけを改良の確証にしない。[同一binary対照の記録](DEVELOPMENT.md#同一binary対照とcpu固定の診断--2026-09-20-jst)を参照。

## 復号だけの反復測定

`khc_lab decode-bench packed.khc --dictionary-mib 64 --decode-iterations 32 --repeats 5`は、既存frameを読み込んでwarm-up復号後、各batchで32回復号する。圧縮や入力I/Oを計測に含めず、frame CRC検査・warm-up出力との全byte比較・出力解放を含むbatch時間と1回あたり平均をJSONで返す。`--decode-iterations`は1〜1000、`--repeats`は1〜100。CPU時間はthread user+kernelで精度制限があり、取得不能はnullとなる。

これは温まったプロセスの内部比較用で、起動込みの7-Zip比較や独立した原文照合ではない。検証済みの同じframeを比較対象へ渡し、exe・frameのSHA-256、実行順、環境を別途記録する。1回のwarm-up出力を保持するため、codecの要求容量予算とは別に元サイズ分のメモリを使用する。従来の`bench`の単発decode時間と測定範囲を混同しない。

## 実装した最小範囲

- 既定の`lz`: 4バイトhash chain、直近4距離＋short rep、予測付きliteral、符号コストによる1 byte先読み。
- 研究用の`beam`: 同じmode 2を有限先読みで作る。既定は512 byte区間・幅4。比較用に`--beam-width`（1/2/3/4/8/16）と`--beam-block`（64/128/256/512/1024/2048/4096/8192）を指定できる。全体最適ではなく、圧縮時間は増える。
- 比較用の`standard`: 初版のgreedy LZ。研究用の`context`: 誤差学習付き階層文脈。`auto`: standard/lz/beam/contextの実出力が最小になるものを選ぶ（全候補の計算時間を含む）。
- 15bit適応確率とbyte正規化binary range coder。carry用golden vectorと、別のu64参照decoderによる照合。
- 実サイズでstored fallback。圧縮候補の容量超過だけをfallbackし、割当失敗やキャンセルはエラー。
- 入力・復号結果は最大64 MiB、辞書は1 byte〜64 MiB（CLI既定8 MiB）、最大一致65536 bytes。
- token単位で入力余裕を確認するunsafe高速経路とchecked tail、固定探索順、CRC32、厳密な長さ・終端、キャンセルcallback、資源検査。

製品用solid書庫・索引、反復コスト推定、可逆変換、並列処理、SHA-256付き書庫コンテナは未実装。長距離疎索引は`--beam-matches hybrid`の研究候補だけにあり、既定経路・製品APIには接続しない。複数ファイルを1つの入力へまとめる研究用groupは下記の限定範囲で検証する。この構成が7-Zip以上だとは主張しない。大辞書用の完成版でもない。

## 適応binary rANSの研究backend

`--entropy-backend rans`はBeam/Blended/BT5/W2/B8192、batchなしの研究候補。前向きの適応確率とbitをjournalへ記録し、約512KiBごとのparser plan境界で逆順rANS符号化する。辞書・適応model・Rep履歴はsegment間も連続する。journalの上限は18.25MiBで、圧縮の要求メモリへ加算する。

圧縮時・復号時の両方へ同じbackend指定が必要。外側の研究用mode 2内に`KRS1` markerとsegment長を持つ別payloadで、既存range payloadとの互換性はない。各segmentでtoken境界、全byte消費、正準rANS終端を検査する。未対応の`adapt-freeze-screen`と`distance-delta-screen`はrANS指定を拒否する。

`screen-entropy.ps1`は固定Canterbury groupでRange/RANSを順序ごとに7対測り、別runでprocess memoryを5回測る。`verify-rans.ps1`はCLI経由の正常・境界・不正payload検証を行う。どちらも新しい`build/`配下の作業先を要求し、入力・exeのSHAと結果を保存する。使用例:

```powershell
./experiments/khc/screen-entropy.ps1 -LabPath <release-khc_lab.exe> -GroupPath <all.group> -WorkDirectory ./build/khc-entropy-new
./experiments/khc/verify-rans.ps1 -LabPath <release-khc_lab.exe> -GroupPath <all.group> -WorkDirectory ./build/khc-rans-e2e-new
```

測定結果と制約は[開発記録](DEVELOPMENT.md)に記載する。現在は任意選択の研究backendで、既定のrangeや製品LHA圧縮方式を置き換えない。

## 2026-09-24時点のsolid比較メモ

同一Release exe・固定Canterbury開発11件のnative-solid 5反復では、BT5/Blended/W2/B8192が483,312 bytes／圧縮985.3388 ms／展開52.7822 ms、幅3＋境界親制限は481,746 bytes／1,380.7704 ms／50.8899 msだった。7-Zip 26.03は483,599 bytes／552.1021 ms（幅2比較run）または547.6577 ms（幅3比較run）／それぞれ46.0403 msまたは41.9660 ms。幅3は開発集合で最小だが速度が大きく劣るため採用せず、幅2も7-Zip同等以上の総合性能を満たさない。別run間の7-Zip timing差もあるため候補間の差は控えめに解釈する。詳細・hashは[開発記録](DEVELOPMENT.md)を参照。

## 研究用solid group

`prepare-group.ps1 -WorkDirectory build/<new>`は固定Canterbury 11ファイルのSHA-256を照合し、名前・長さ表＋連続した本文からなる`all.group`を生成する。ASCII basename昇順で全ファイルを含む。`khc_lab group-bench all.group --algorithm beam --beam-width 2 --beam-block 1024 --beam-model blended --beam-matches bt5 --dictionary-mib 64`は表を検証し、group全体を既存KHCの1 frameとして圧縮・復号する。ファイル境界で辞書やモデルをリセットしない。復号後に全byte、名前、境界、各内容を照合し、JSONの`solid_group`に名前・元サイズを返す。

内側の形式と比較結果は[開発記録](DEVELOPMENT.md#単一solid-groupの研究入口--2026-09-20-jst)を参照。外側のKHC revision 1は変更しない。

`group-encode all.group`は検証済みgroupを圧縮してバイナリstdoutへ返す。`group-list packed.khc --dictionary-mib 64`は復号・CRC・全metadataを検証し、`[{"name":"…","bytes":123},…]`を返す。`group-decode packed.khc --dictionary-mib 64`は同じ検証後、各本文だけを表順にstdoutへ連結する。不正なgroupでは本文を出さないが、出力先I/O失敗時のstdout巻き戻しは保証しない。圧縮設定は`group-bench`と共通で、encoderの既定は従来のLz。

全体64 MiB以下、最大1024件、名前1〜255 bytes、UTF-8 byte順で厳密に昇順。重複、`.`/`..`、slash/backslash/colon/NUL/制御文字は禁止。名前は平坦な識別子で、実パスとして使わない。空group・空fileは許可。全metadata・総長を検証後に借用viewを返し、末尾余剰・切断・割当失敗は拒否する。

メモリ内専用で、ファイルシステムへの展開、ディレクトリ・時刻・属性、group分割・索引・選択展開・streamingはない。準備・解析・照合はcodec計測の外で、parserのview用Vecは既存codecのメモリ予算に含まれない。OSのhard memory制限や新しいキャンセル保証もない。唯一のコピーや長期保存には使わない。

`compare.ps1 -InputFiles build/<prepared>/all.group ...`は両codecへ**同じ名前・境界表を含むbyte列**を渡す。ただし7-Zip自身の複数ファイルsolid書庫との比較ではなく、group byte列のcodec比較に限る。最終的なカテゴリ・solid書庫・holdout合格の代用にはしない。

`compare-solid.ps1`は別の入口で、7-Zipへ固定11ファイルを直接渡す。名前順・単一solid block、LZMA2最大設定、辞書64 MiB、時刻なし、既定のheader圧縮ありで比較する。7-Zipのthread上限は`-SevenZipThreads`で指定し、既定は1。KHCは現状1 threadで、reportでは両側のthread数を別々に記録する。KHCは上記groupを使い、`-BeamMatches bt4|bt5|hybrid`、探索幅、価格更新区間を明示できる。両者の名前・サイズ・順序と、元snapshotから独立計算した本文連結SHA-256を照合し、warm-up＋5反復を交互計測する。各反復の圧縮出力hashも一致させ、総書庫bytesを記録する。両CLIの復元stdoutは共通SHA sinkへ流し、復元コピーは作らない。これは平坦な名前と本文に限定した開発用比較で、属性・ディレクトリ・選択展開・同一hard memory上限を含む完成書庫比較ではない。stdoutへの転送も、codecが全復号結果をメモリへ保持する制約は解消しない。

```powershell
./experiments/khc/compare-solid.ps1 -LabPath build/cargo-final-depth48-b8192/release/examples/khc_lab.exe -SevenZipPath build/khc-baseline-20260918/x64/7za.exe -GroupPath build/khc-solid-development/all.group -WorkDirectory build/khc-final-depth48-b8192-native-solid -BeamMatches bt5 -BeamWidth 2 -BeamBlock 8192 -Repeats 5
```

実行前に現行Release exampleを固定して`LabPath`を指定する。`WorkDirectory`はbuild配下の新規パスだけを受け付ける。上記パスの固定binary・groupはローカル検証生成物であり、未生成なら先にビルドと`prepare-group.ps1`を実行する。旧`compare.ps1`は単一byte列の比較用途として維持し、native solidの結果と混ぜない。

`compare-solid.ps1 -BeamMatches bt5 -BeamWidth 2 -BeamBlock 8192`で最新の速度・サイズ両立候補を比較できる（区間は64/128/256/512/1024/2048/4096/8192、既定512）。指定値は子CLIとreportへ渡す。2026-09-21時点の研究採用候補は、BT5/W2/B8192＋疎Rep境界・境界外第2親省略・計測OFF高速経路・depth48・active/history分離・active幅2unchecked storage・active幅2 RepLengthCache 8枠・active cache価格経路のbranchless化・active固定条件分岐の除去・`extend_match` inline化・BT5内側ループの不変条件hoist・range encoderのchecked/unchecked分離・branchless確率更新・`RepLengthCache::length`/`length_fast_zero`の2箇所inlineに、BeamNode 32-byte packingを加えたもの。固定solid groupは483,312 bytesで7-Zip 26.03の483,599 bytesを287 bytes下回り、固定条件分岐除去後の同一binary内交互5対は候補4,964.1817 ms対基準5,134.6463 ms（−3.32%）、独立5対は4,913.5762対5,083.0831 ms（−3.33%）だった。native-solid 5反復は圧縮1,166.3404 ms、復号68.6335 msで、7-Zipの645.5505 ms／48.5370 msより圧縮約1.81倍遅い。サイズは287 bytes小さいが、復号は実行間の揺れが大きく改善を主張せず、7-Zip同等以上の総合目標は未達。詳細は[開発記録](DEVELOPMENT.md)を参照する。

## 現行Release CPU stack解析

`sample-current-release.ps1`で所有WPR録画だけを採取し、`analyze-current-cpu.ps1`でmatching EXE/PDBと生ETLのCPU/StackWalkを対応付ける。`verify-current-cpu.ps1`は解析CLIの正常reportと拒否契約を検証する。旧inline-only集計とphysical callersを含むruntime包含集計は別項目で、重複した時間を足さない。2026-09-30の全3,199 samples照合・環境・hash・再現手順・未達条件は[現行Release解析](NORMAL_RELEASE_CPU_PROFILE_20260930.md)を参照。診断時間は速度採否に使用しない。

## Parser decision census

`khc_lab parser-census INPUT --dictionary-mib 64 --beam-width 2 --beam-block 8192 --beam-model blended --beam-matches bt5`は、実際のStandard／lazy LZ／現行BT5 Beamのtoken列を同一入力位置で比較する研究診断。通常encodeのframe復号とtrace payload一致、tokenの連続性・copy再構成を検証し、traceごとに最大4,194,304 tokenへ制限する。出力はJSON。token判断の不一致率は修復可能量や速度向上を示すものではなく、7-Zip比較やhybrid採用の根拠には単独で使わない。[2026-09-28のCanterbury結果と制約](PARSER_CENSUS_20260928.md)を参照。

`khc_lab renorm-census INPUT`は、同じオプションで1回圧縮し、Range復号が1 bitあたり0・1・2 byteのどれを正規化したかを数える。2 byteがbit数の20%未満なら2 byteまとめ読みは実装しない。このJSONは速度比較でも7-Zip比較でもない。[2026-09-28の回数と、シフトなしの現行Range再測定](RENORM_CENSUS_20260928.md)を参照。

`khc_lab boundary-census GROUP`は、研究用solid groupのファイル境界でStandard・lazy LZ・Beamの終端payload増分を比べる。通常encodeのフレームとtoken再生payloadの一致、各フレームの往復を確認する。修復実装の関門は、7-Zip総量483,599 bytes以下かつ、別ファイル時間の比で縮約したsolid圧縮が574.5624 msの1.3倍未満である。両方を満たすまで修復parserは作らない。[2026-09-28の境界寄与](BOUNDARY_CENSUS_20260928.md)ではサイズだけ通り、速度は不通過だった。

## 操作と標準試験への接続

`UnLhaRe/`で実行する。

```powershell
cargo test --locked --example khc_lab
cargo build --locked --release --example khc_lab
cargo run --locked --release --example khc_lab -- bench README.md --algorithm lz --repeats 5
```

Cargo manifestの`[[example]] test = true`により、通常の`cargo test --workspace`と`scripts/build.ps1 -Test`も実験試験を実行する。配布bundleのビルドにはこのexampleを追加していない。

`bench`の各sampleは従来の`encode_ms` / `decode_ms`（wall時間）に加え、`encode_cpu_ms` / `decode_cpu_ms`とそれぞれの`*_cpu_status`を返す。Windowsでは[GetThreadTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadtimes)で現在の実行スレッドのuser＋kernel時間を各codec呼出しの前後で採取する。I/O・warm-up・出力照合・JSON化は対象外だが、ごく小さい計測境界の負担は含む。100 nsは取得単位であって分解能の保証ではなく、短い処理で成功時にも0を取り得る。取得失敗は`null` / `unavailable`、逆行は`null` / `non_monotonic`、Windows以外は`null` / `unsupported`。CPU計測には研究用exampleだけのWindows FFIを使い、codec本体のno-unsafeは維持する。

これは単一スレッドcodecの補助指標で、子プロセス全体のCPU時間や7-ZipのCLI測定とは範囲が違う。将来codecが他スレッドを使えばその分は含まれない。CPUとwallの差だけで待機・スケジューラ等の原因を断定しない。Windows x64実測では15.625 ms刻みの値が多く、数msのwallに対しCPUが0または15.625 msになる例があった。CPU値をwall以下へ丸めず保持し、短い処理の単発値で優劣を判定しない。古い固定binaryにCPU列がない場合は取得不能として扱い、0で埋めたり、新版だけの値でCPU改善を主張しない。

`profile INPUT --algorithm beam --beam-model blended --beam-matches priced-tie --dictionary-mib 64`は研究用の単発区間計測。計測無効のencodeと計測有効のencodeの出力一致・完全復元を確認してJSONを返す。索引構築、beam計画、モデル学習、一致探索、状態展開、rep一致長、token出力の呼び出し数とinclusive時間を記録する。入れ子の時間は重複するため加算できず、計測負担も含む。通常の`encode`/`bench`ではこれらの区間タイマーを読み出さない。状態はスレッドと計測世代ごとに分離し、panic後も残さない。7-Zipとの速度比較にはこの値を使わず、計測無効のCLI比較を使う。

`encode INPUT` / `decode INPUT`はバイナリをstdoutへ出す。ファイルパスの展開や既存APIへの登録は行わない。シェルのテキスト変換や上書きを避けるため、7-ZipとのCLI比較用`compare.ps1`は圧縮stdoutのBaseStreamを新規ファイルへ直接転送する。復号stdoutは両codec共通のSHA-256 sinkで検証し、復元コピーを作らない。このstreaming hashの時間もCLI復号時間へ含まれるため、旧file-sink版の復号時間とは直接比較しない。出力不変の内部比較用`measure-internal.ps1`はメモリ上で旧frameのSHA-256と照合し、JSON記録だけを作る。`-ReferenceLabPath`を指定すると固定した基点と候補を交互順で測定する。固定開発集合と既存baselineを使う手順は[開発比較の再実行](DEVELOPMENT.md#再実行)を参照する。

beam設定はencoderの探索だけに使い、フレームへ保存しない。すべて同じmode 2 decoderで復元でき、復号時に幅・区間長を指定する必要はない。Beam/Autoの不正設定は割当前に拒否し、使わないcodecの内部Optionsや復号処理には影響させない。CLIは明示した設定値の誤りを常に拒否する。

速度・サイズ両立の現行研究基準は`--algorithm beam --beam-model blended --beam-matches bt5 --beam-width 2 --beam-block 8192 --dictionary-mib 64`。decoder fast path後のnative-solid 5反復（`build/khc-current-decoder-fastpath-solid-20260924/report.json`）では固定開発groupが483,312 bytes、圧縮1,059.0383 ms、復号62.3212 msで、7-Zip 26.03の483,599 bytes、648.8743 ms、45.8969 msよりサイズは287 bytes小さい一方、圧縮は約1.632倍、復号は約1.358倍遅い。総合目標達成・製品推奨ではなく、既定設定は従来のLz、BT4も比較基準として維持する。詳細と過去の採否は[開発記録](DEVELOPMENT.md)を参照する。

`--beam-model current|warm|blended`は価格推定だけの研究用比較。既定`current`は区間開始時のモデルをそのまま使う。`warm`は現在の区間内を暫定greedy parseで走査し、コピーしたモデルだけを学習してから価格に使う。`blended`は学習前後の各確率の整数平均。実際にpayloadへ出すモデルとrep状態は変更せず、学習用出力バッファも作らない。長い一致の即時採用経路ではこの学習を省略する。圧縮率・速度の改善は比較結果で判定し、学習しただけで改善したとは見なさない。Warm/Blendedの暫定走査では、最長長さが増えた候補と同長候補だけを走査順に小型traceへ記録する。本beamは位置・辞書・有効上限が完全一致するtraceを再生し、記録不足・容量不足・key不一致では通常探索へ戻る。記録時と同数の取消確認を再生するため、候補順、探索予算、callback結果は非trace経路と一致する。

`--beam-matches nearest|priced-tie`は同長一致候補の保持方針を比較する研究設定。既定`nearest`は従来どおり近い候補を残す。`priced-tie`は現在の最長候補と同じ長さの候補が見つかった場合だけ、凍結価格モデルの距離費用が厳密に小さければ置き換える。同価格は先の候補を維持し、検索上限・早期終了・候補数・長さ順は変えない。Warm/Blendedの区間先頭は価格モデル確定後にtraceを再生し、traceを使えない場合だけ再探索する。暫定学習と長大一致の即時採用は従来方針を使う。通常matchの即時費用だけを比べる局所近似で、状態別のrep費用・後続のliteral予測・将来の最適性は保証しない。復号形式は変わらないが、Warm/Blendedだけはtrace用heapを要求容量へ加える。

同長比較に使う現在最長候補の価格は、1探索内だけ遅延計算・保持する。長さ更新時は破棄し、同長でより安い候補へ置き換えた場合は価格も更新する。非cache参照と出力は一致する。この設定はサイズと時間の交換条件を調べる比較候補で、既定への採用は見送っている。

beamの距離価格cacheは64枠を持ち、衝突時に調べる範囲を最大4枠へ制限する。chainは位置ごとに初期化する。BT4/BT5は価格modelが不変なblock内で位置間共有し、次blockで必ず初期化する。keyは距離と長さ文脈で、位置には依存しない。missでは凍結modelから正確な価格を計算し、先頭のhash枠を置き換える。キャッシュの命中率との交換条件であり、価格式・frame・容量式は変わらない。衝突・置換・再訪時の価格は非cache参照式と照合する。

位置ごとのrep一致長cacheは16枠を維持し、有効要素数を一つ保持する。照会は使用済みprefixだけを走査し、空きがあれば末尾へ追加する。満杯後の新しい距離は従来どおり再計算し、途中取消では追加しない。各要素の使用flagと空き探索をなくすが、cache内容・callback・保存形式・要求容量式は変更しない。旧flag配列の参照処理と、満杯・再訪・無効距離・途中取消後の継続を照合する。

同じ親・rep indexの長さ候補は一括展開し、長さに依存しない子状態・位置・token文脈・固定価格を共有する。各長さの価格cache更新、候補の順序と個数、bucketへの挿入は従来どおり。chain/BT4/BT5の全経路で使い、追加heapや保存形式変更はない。

BT4のRep候補長は、重複のない固定8値と末尾3長を別々に生成し、末尾だけ固定集合との重複を判定する。候補配列全体を毎回検索せず、旧処理の順序・内容を維持する。最大一致長までの全長さと整数上限付近を旧式に照合し、開発集合5対比較では出力不変のまま内部圧縮wallを幅4で約5.29%、幅2で約4.19%短縮した。別の直接CLI5反復では新版幅2の圧縮は7-Zipより約3.26倍遅い。以前の約3.52倍との差を変更だけの因果効果とはせず、個別の遅化も含め[開発比較](DEVELOPMENT.md)に記録する。総合目標は未達のまま。

`--beam-matches bt4`は別の研究候補。4-byte hashを根に持つ増分二分探索木で候補を探す。木の比較は固定128-byte prefix、1位置につき最大64候補・65536 byte実比較とし、候補長だけを必要範囲まで延長する。長い共通prefixを持つ古い候補を見逃す可能性がある近似で、完全な最長一致探索ではない。全位置を単調に挿入し、区間内の候補を距離順に保存する。block末尾で切った有効長が、それ以前の最大値以上になる候補だけを保存し、同長候補は距離価格の選択用に全て残す。Warm/Blendedはこの同じsnapshotを使い、beamは長さ上限で切った後に凍結価格で最大24件のfrontierへ絞る。長い一致の即時採用を判定してから残りの区間を挿入するため、区間より短い即時採用でも探索位置を逆行させない。既定のchainと保存形式は変更しない。BT4は別の探索経路なので、chainの計測区間・callback回数と同一とは扱わない。

`--beam-matches bt5`は同じ増分木・snapshot・frontierを使い、root hashだけを入力5 byteへ広げる研究候補。4 byteだけ一致する位置を別rootへ分散して木の訪問を減らす一方、長さ4の通常Matchを失い得る近似で、BT4の上位互換ではない。Rep一致、mode 2の符号化・復号形式、depth64、停滞打切り、比較予算は共通。BT4とBT5は同じ要求容量式を使い、どちらも既定のchainや製品APIへは組み込まない。ここでのBT5はKHC研究codec内のmatcher名であり、LHAのmethod名や既存の「LHX/LH10」圧縮レベルではない。

`--beam-matches hybrid`はBT4/BT5を置換しない別の研究候補。近距離はhash-5の直近4 MiBだけを`4 MiB+1`個のu32 ring linkへ保持し、入力長比例のchild配列を持たない。遠距離は絶対位置16 byte境界の16-byte keyを4-way bucketへ疎に入れ、query側で16通りのalignmentを補正する。距離4 MiB以下はnear、4 MiB超かつ辞書内で64 byte以上の完全一致だけをfar候補にする。4 MiBを超えるまではfar検索を行わない。候補は実byte列で再検証し、距離順にmerge/dedupする。同長候補はsnapshot容量内で保持し、nearは最大64-chainから既存BTと同じ48件を保存、farは最大64件、合計112件に制限する。near満杯後の同長候補を全て保持する完全探索ではない。near一致長比較とfar一致長比較は別予算で各位置最大65,536 byte。far側の予算は複数候補で共有し、近いfar距離から比較する。near候補がquery全長に達した位置ではfar照合を省略するため、同長のより安い距離候補を取りこぼし得る。どちらも圧縮品質を優先した完全探索ではなく、性能・品質は引き続き測定対象。

入力長または辞書サイズが4 MiB以下では4 MiB超のmatchが作れないため、Hybrid指定でもBT5 matcherへfallbackし、出力と要求容量式をBT5と同じにする。両方が4 MiB超の時だけHybridのnear-ring＋far-indexを使う。

far bucket数は`next_power_of_two(ceil(ceil(max(dictionary-4 MiB,0)/16)/4))`（最小1）で、64 MiB辞書では2^20 bucket・16 MiB。各bucketは辞書外へ出た位置を再利用し、有効な最古anchor 1件と比較的新しい3件を残す。long-token bypassで飛ばした位置も次block開始前に順にring/indexへ反映する。入力位置・linkはgroup相対u32、最大一致とwireは65536 byteのまま。これは長距離候補の品質・速度を測るための実装であり、圧縮率や7-Zip超えはまだ検証していない。

探索depthは開発比較に基づき256から64へ縮小した。木の打切りで候補と圧縮出力は変わり、個別入力の悪化もある。幅2・幅4の個別合計と単一solid groupでサイズ改善を確認したが、未使用holdoutや全環境での優位を保証しない。より速いdepth32は幅4 solidのサイズ悪化があるため一律採用していない。比較と制約は[開発記録](DEVELOPMENT.md)を参照する。

候補を採取する位置では、可視一致長の最大値が16訪問連続で改善しなければ早期打切りする。一致長が改善すれば回数をリセットし、query上限0の追いつき挿入には適用しない。固定prefix完全一致のchild継承を先に行い、それ以外の打切りでは未接続リンクをNONEで終端する。遠い同長候補の符号費用や後続の長い一致を捨て得る近似で、木と出力が変わる。depth64・比較予算・要求容量上限は維持するが、取消callback総回数は旧版と同一ではない。

BT4の通常Matchは、各位置の累積費用が最小の親状態1つからだけ展開する。同価格では先頭slotを選び、Literal・ShortRep・Repは全ての有限費用の親から従来どおり展開する。通常Matchの符号費用や将来の距離履歴まで比較した厳密な支配判定ではなく、探索量を減らす近似である。候補と圧縮出力は変わり、入力によって圧縮率が悪化する。形式、追加heap、要求容量は変わらないが、選択経路が変わるため取消callbackの総呼出し回数まで旧版と同一とは保証しない。

BT4の子リンクは親より古い入力位置だけを指し、探索経路の候補は既に距離の昇順になる。この不変条件を試験とdebug assertionで確認し、snapshot保存前の冗長なsortを省いている。候補数・順序・価格による選択は変えない。全体時間の差は小さく、これだけで安定した高速化を証明したとは扱わない。

候補採取の一時配列64件（512 bytes）はBlock内で再利用する。毎位置の初期化を省き、今回書き込んだ件数未満だけをsnapshotへ保存するため、前回の残りは公開しない。Blockの固定構造体も5 KiBの固定作業枠の型サイズ検査に含める。これはOSの実スタック量やhard memory上限の保証ではない。

snapshot保存時の候補削減は、clamp後に以前の最大長より**厳密に短い**候補だけを除く。同じ有効長は遠い距離の方が安くなる場合があるため全て保持し、保存値もraw lengthのままなのでblock先頭の長一致判定を変えない。Rep0..3は各消費経路で独立に実測する。木の更新、訪問数、停滞打切り、比較予算、取消callbackは保存可否から分離している。固定開発11入力の旧版との5対比較では全frameを同一に保ち、内部圧縮wallの入力別中央値合計を幅2で約1.91%、幅4で約0.95%短縮した。一方、候補生成後に同じ削減を行う案は走査とcopyの負担で幅2を約0.73%遅くしたため採用していない。予約容量と最悪時要求量は従来の64候補分を維持する。

長さ価格の2つのキャッシュはu16で保持する。最大区間1024・15bit確率の価格上限をコンパイル時に検査し、空値65535と有効価格を区別する。計算結果はu64へ戻すため、候補価格・飽和加算・復号形式は変わらない。B=512で要求容量を49,248 bytes削減するが、OS上のピークメモリが同量減る保証ではない。

## フレーム仕様（little-endian）

固定40 byteヘッダーの直後にpayloadを置く。連結フレームやtrailing dataは不可。

| Offset | 幅 | 値 |
| --- | --- | --- |
| 0 | 8 | `4b 48 43 30 4c 41 42 00` (`KHC0LAB\0`) |
| 8 | 1 | 実験revision `1`。初版revision 0のmode 0/1だけは復号可能 |
| 9 | 1 | `0` stored、`1` standard、`2` lz、`3` context |
| 10 | 2 | 予約: 0必須 |
| 12 | 4 | 最大参照距離、1〜67108864 |
| 16 | 8 | 元サイズN、0〜67108864 |
| 24 | 8 | payloadサイズP、P≦N、フレーム長=40+P |
| 32 | 4 | 復元バイト列のCRC32/ISO-HDLC |
| 36 | 4 | 先頭36 byteのCRC32/ISO-HDLC |

CRCの反射多項式は`0xedb88320`、初期値とxoroutは`0xffffffff`。ヘッダー検査後、サイズ・辞書・要求容量を検査してから出力を確保する。CRCは認証ではない。

storedはP=Nで本文をそのまま復元する。圧縮候補がNより小さくない場合、encoderはstoredを選ぶ。空入力はstoredの40 byteフレーム。mode 1/2/3はN byteを復元した後、符号器の終端・CRCの確認後だけ結果を返す。Autoはstandard→lz→beam→contextの順で逐次評価し、同サイズでは先の候補を維持する。lz/beamはどちらもmode 2でありdecoderは同じ。開発途中のrevision 0 mode 2/3は非対応として拒否する。

## Mode 1のモデルとtokenのビット順

全確率pは「0」の確率×32768、初期16384。1 bit処理**後**、0なら`p += (32768-p)>>5`、1なら`p -= p>>5`。この初期値と式ではpは1〜32767の内部に留まる。整数演算のみ。フレームごとに全状態をresetする。

1. 直前tokenがmatchだったか（初期false）の2文脈から`kind`を読む。0がliteral、1がmatch。
2. literalは直前の復元byte（先頭は0）を文脈として、8 bitをMSBからbinary treeで読む。各文脈256要素、root=1、次node=`2*node+bit`。要素0は未使用。
3. matchは1つの`repeat`確率で1 bitを読む。1なら直前match距離（初期1）、0なら距離を下記number形式で読む。続いて`length-2`をnumber形式で読む。距離状態はそのmatch距離へ更新する。
4. match長は3〜65536、距離は1〜辞書長かつ復元済みbyte数以下。残り出力サイズを超える長さは拒否。重複一致は前方逐次コピーする。

numberは正整数vを`slot=floor(log2(v))`と下位slot bitに分ける。length用とdistance用は独立した64要素のモデルを持つ。slotを5 bitのtree（要素1〜31）でMSBから符号化し、下位bitはMSBから`model[32+bit_position]`で符号化する。復号時はslotと値の両方を意味上の最大値で制限する。

## Mode 2のモデルとtoken

実装正本は[lz.rs](lz.rs)。確率更新はmode 1と同じ。token文脈は`4*previous_match+(出力位置&3)`、previous_match初期false、距離履歴は`[1,1,1,1]`。

1. `is_match=0`ならliteral。直前byte上位3 bitの8文脈、各768確率を使用。symbol=1からMSB順に木を進む。rep0位置が有効なら、そのbyteを予測し、prefixが一致している間だけindex=`context*768+256*(1+予測bit)+symbol`を使う。不一致後は`context*768+symbol`へ戻る。先頭は直前byte=0、予測無効。
2. `is_match=1`なら`is_rep`。falseなら通常match（長さ3以上）で長さ、距離を送る。距離は履歴先頭に挿入し、4件目を破棄する。
3. repなら`is_rep0`。trueなら`is_short_rep`がtrueで長さ1、falseで長さ2以上。rep0でなければ`is_rep1`、必要なら`is_rep2`で4距離を選ぶ。長さ2以上のrepは選択距離を先頭へ移動する。
4. 長さは最小値（通常3/rep2）を引いた値vについて、`first`でv≧8、必要なら`second`でv≧16を送る。v<8と8≦v<16は各3bit木、それ以上はmode 1のnumberでv-15を送る。rep/通常長さは別モデルで、token文脈ごとに状態を持つ。
5. 通常距離はnumber形式。長さ≦4、≦8、≦16、それ以上の4文脈でslot/下位bitの確率を分ける。境界検査・重複コピーはmode 1と同じ。

encoderは各候補とrepに対し、現在のモデルによる固定小数点の推定符号費用とliteral費用の差を比較する。長大一致のliteral費用は先頭8 byteの平均で近似する。1 byte先の差益が現在より64/256 bitを超えて大きければliteralを先に出す。これは局所近似であり、最適parseやbeamではない。3byte専用索引の追加は合計出力が悪化したため撤去済み。

別選択のbeamは、位置ごとに`(cost, rep4, previous_match, predecessor, token)`を4状態まで保持する。512 byte区間の開始時点のモデルで価格を凍結し、同じrep4/previous_match状態では最小費用だけ残す。literalとshort rep、各repの短長候補、通常matchのfrontierと最長候補の短長を比較し、区間末尾からbacktrackして実モデルで符号化する。区間開始時の128 byte以上の長い一致は直接処理する。探索・価格は有限近似であり、大域最適ではない。各区間を処理した後も辞書と実モデルはresetしない。

beam内部の一致比較は区間末尾で打ち切り、区間開始の長い一致探索は最大65536 bytesを維持する。hash-chainの打ち切りにより候補集合も変わり得るため、比較長制限の最適化前後でpayload完全一致を保証しない。独立した[仕様decoder](reference_lz.rs)で、Lz/Beamの圧縮frame、切り詰め・bit変更・余剰byteの受理条件を照合している。このdecoderは試験時だけ組み込み、製品bundleには含めない。

BT4の木探索は既知LCPから8 byte単位で一致を延長し、不一致chunkだけ最初の相違byteまで数える。残り長、65536比較予算、4096比較ごとの取消境界のいずれかを跨ぐ場合は従来の1 byte比較へ戻すため、比較数・取消順・木リンク・候補列・wireは変えない。little-endianのXORに対する末尾0 bit数から先頭一致byte数を得る実装であり、対象4環境はいずれも64bitを前提とする。

明示的なBT4研究候補ではRepの長さを`2..6, 9, 17, 32, maximum-2..maximum`から範囲内・重複なしで選ぶ。9/17はRep長さ符号のlow/middle木の末尾で、従来の8/16を置き換える。通常MatchとNearest/PricedTieは従来の候補列を保持する。符号化・状態更新規則は変えないが、探索経路と圧縮出力は変わる。開発集合では合計と幾何平均がわずかに改善した一方、個別5入力は悪化し、速度向上は立証されていない。詳細は[開発記録](DEVELOPMENT.md)を参照。

BT4/BT5のBlended幅4では、暫定greedyのtoken境界±2 byteだけ上記の全Rep長を展開し、それ以外では`max(2, maximum-1)..=maximum`を昇順で展開する。Blended幅2は同じ境界±2 byteで`2, 9, 17, maximum-1, maximum`を重複なく使い、境界外は末尾2長だけを使う。32は固定開発solidでサイズと時間の両方を悪化させたため幅2の疎集合から外した。通常Match、Literal、ShortRep、各親の最大長Repは全位置で維持する。候補順も変わり得る近似で、サイズ不変や最適性は保証しない。Current/Warm・chain・他幅は従来の候補を維持する。境界mask136 bytesと末尾配列16 bytesを既存固定作業枠へ算入し、追加heapとwire変更はない。

BT4の幅4では、各位置で最大16件となるRep履歴距離の先頭byteが不一致なら、長さ0をcacheへ保存せず即座に棄却する。cache容量16以内なので正長候補の保存可否は変わらず、0長cache hitと同じく取消callbackも呼ばない。chainと他幅は従来経路を維持する。固定開発集合の旧版との5対比較では全frameを同一に保ち、内部圧縮wallを約5.09%短縮した。

BT4のsnapshot参照は、呼出し側が既に保持するblock-local位置を直接受け取る。従来の絶対位置からのchecked subtractionを通常経路から除き、Recordとsliceの範囲検査は維持する。絶対位置版は境界試験だけに残す。候補値・順序・取消callback・wireは変えない。固定開発集合の旧版との独立した5対比較2回では全frameを同一に保ち、内部圧縮wallを約0.75% / 0.95%短縮した。

## Mode 3のモデル

実装正本は[context.rs](context.rs)。各byteをMSB順に符号化し、order 0/1の直接表、order 2/4の固定hash表、継続byteのタグ付き予測表を使う。合計モデル容量は3933184 bytes。hash衝突は状態共有（継続予測はtag不一致で置換）とし、表は増やさない。

各bit状態は確率u16、観測回数u8、誤差EWMA u8。確率初期16384、回数0、誤差128。bit更新前の誤った側の確率を7 bit右シフトし、誤差をその値へ1/16（差の切り上げ）近づける。確率の学習shiftは回数0〜3で2、4〜15で3、16〜63で4、それ以上で5。回数は255で飽和する。

予測はorder 0から開始し、利用可能な上位orderへ順に混ぜる。上位重みは`min(count,cap)*max(128-error,0)/8`、下位重み32、capはorder 1/2/4で16/32/48。継続byteの同一予測成功数は上限32で、最後に信頼度二乗を重みに混ぜる。予測確率は16384±496*信頼度。外れたbyteへ置換して信頼度1へ戻す。全更新順・hash定数はソースで固定し、浮動小数点は使わない。

現時点では開発11件すべてでmode 2より大きい。学習付き混合を高性能として既定化せず、明示選択・Autoでの実サイズ比較の対象に留める。mode 3全体の独立decoderによる相互照合は未完了。

## Range符号器

初期`range=0xffffffff`, `low=0`。分割幅は`(range>>15)*p`。0ならrangeを分割幅へ、1ならlowへ分割幅を加算しrangeから減算する。rangeが`1<<24`未満の間、rangeを8 bit左シフトしShiftLowする。

ShiftLowはlowの下位32 bitをL、上位をcarry（0/1）とする。初期cache=0、cache_size=1。L<`0xff000000`またはcarry≠0なら、cache+carryの下位8 bitと、残るcache_size-1個の`0xff+carry`の下位8 bitを出力する。その後cache=L>>24、cache_size=0とする。条件の成否によらずcache_sizeを1増やし、low=`(L&0xffffff)<<8`とする。

全token終了後にShiftLowを5回実行する。decoderは先頭0 byteを必須とし、続く4 byteをbig-endianのcodeとして読む。bit判定はcodeと分割幅の比較で行い、1ならcodeから分割幅を引く。正規化時はcodeへ次byteをシフト入力する。N byte復元後はpayloadを丁度消費し、**code=0**でなければ拒否する。

固定確率列に対するgoldenは`range.rs::tests::FIXED_CASE`、期待列は`00 40 00 3f ff 33 1a c7 37`。これはrange層の検証であり、書庫全体の他実装との相互運用性を示すものではない。

## 探索・メモリ・キャンセルの境界

mode 1のhashは24bit little-endianキー×`0x9e3779b1`の下位32bitから上位16bitを取る。各位置で最大256候補・合計65536 byte比較。長さ同点は最初の候補（近距離）を維持する。選択したtokenが覆う全入力位置を索引へ登録する。u32位置の番兵は`0xffffffff`で、64 MiB上限と衝突しない。mode 2は32bitキーから20bit hashへ写し、全位置の前位置索引を構築する。hash一致だけではmatchとせず、先頭byteから実照合する。

mode 2の一致比較は範囲内のimmutable sliceを8 byteずつlittle-endian整数へ読み、XORの末尾ゼロbit数から最初の不一致byteを求める。8 byte未満の末尾とFinderのcallback境界付近はscalar比較を維持する。探索上限65536は従来scalarと同じ**論理比較byte数**（最初の不一致も1と数える）であり、CPUが実際にロードするbyte数や命令数ではない。callback直前の範囲内の先行読取は最大7 byte。候補順・論理予算・4096境界のcallback回数とキャンセル結果はscalar参照と一致させる。`unsafe`や特定ISA命令は使わず、追加バッファも確保しない。

保守的な要求容量予算（bytes）は次のとおり。Nは入力/復元長、Fはフレーム長。入力slice、候補、親フレームを含む。

| mode | 圧縮 | 復号 |
| --- | --- | --- |
| standard / stored | `8*N+397312` | `F+N+397312` |
| lz | `7*N+4456488`（共有価格表65536 bytesを含む） | `3*N+196648` |
| beam | lz式＋`(B+1)*W*sizeof(BeamNode)+B*sizeof(Token)+2*8*(B+1)*2+4096`。B=区間長、W=幅。BeamNode=32、Token=24 bytes。BeamNodeの価格はu32、parentは上位bitに`previous_match`、下位31 bitに親indexを保持する。beam表とcacheの追加量は実装の`size_of`から算出する。Warm/Blendedは学習用モデル131072に加え、trace record `B*24`と最大候補`B*256*8`、合計`B*2072`を加算する。B=512のtraceは1060864 bytes。 | lzと共通 |
| context | `3*N+3937320` | `F+N+3937280` |
| auto | 圧縮4式の最大値+最良候補保持用N | 選択されたmodeの式 |

BT4/BT5のbeamは、上表の基本beam式へchild linkの差分`4*N`とsnapshot `B*(8+64*8)=B*520`を加える。Warm/Blendedはさらに学習モデル131072を加えるが、chain用traceの`B*2072`は確保しない。Currentでもsnapshotは必要。幅4ではRep候補長の共有定数表106600 bytesも計上する。他幅は従来の一覧生成を使う。表は最大長0〜1024の候補と順序を保存し、追加heapやキャンセル確認箇所を増減しない。静的な表の計上であり、OSの実常駐量の保証ではない。復号容量は従来と同じ。

Hybridのbeamは基本beam式に、near root `2^19*4`、near ring `(4 MiB+1)*4`、辞書依存far bucket `bucket_count*16`、snapshot record/candidate/scratch `B*8+B*112*8+112*8`を加える。さらにBT系と共通の距離価格表・Match候補長表、幅4だけRep候補長表を加える。全加算はcheckedで行い、要求容量が予算内と確認された後に固定配列とsnapshotを割り当てる。復号形式・復号容量は他のmode 2と同じ。

既定予算1 GiB。配列は事前に`try_reserve_exact`し、伸長を許可しない。出力候補はN byte以下。この値は**要求したバッファ容量の上限**であり、allocatorの管理領域・実行時・スタック・OSページキャッシュまで含むRSS/commitの硬い上限ではない。完成版の資源予算契約は未達。

beam表だけは距離・長さ・価格・親番号をchecked変換したu32で保存し、価格計算と復号のusize表現は維持する。入力・辞書・一致長・beam表の上限はu32範囲内をコンパイル時に検査し、parent u32の上位bitは`previous_match`、下位31 bitは親index、`0x7fff_ffff`はrootの親なし番兵に使う。表の小型化は保存形式・候補順・探索範囲を変えない。

探索のbit価格は従来の整数log2＋一次近似と完全に同値の定数表。価格cacheは凍結モデルの区間ごと、一致長cacheは入力位置ごとに限定して再利用する。beamのliteral payload価格も同じ位置の状態間で共有する。予測byteと実byteの共通prefix長0〜8と予測不能の計10種類に分け、前状態依存のis_match価格は各状態で加算する。cache miss時は既に求めたprefix keyから同じ8個の木indexを直接選び、prefixを再計算しない。key 0〜7は最初の不一致まで予測木、key 8は全bit予測木、key 9は全bit通常木で、従来式と同じ順序で価格を加算する。固定80 bytesで追加heapはなく、5 KiBの固定作業枠内の型サイズ試験を通すが、実stack使用量の保証ではない。価格をより精密にする案は実出力が悪化したため使わない。これらはencoder専用で、実際のrange確率や復号仕様を変更しない。

tokenごと、比較4096 byteごと、コピー4096 byteごと、frameコピー64 KiBごと、結果返却直前にキャンセルを確認する。mode 2の索引構築は65536位置ごと、mode 3は4096入力/復元byteごとに確認する。割当初期化やCRC内部のpreemption、p99 100ms、実行中のCLIキャンセル連携は未実証。callbackがtrueなら部分結果を返さない。

## BT4の価格予測診断

`profile INPUT --algorithm beam --beam-model blended --beam-matches bt4 --beam-width 2 --beam-block 1024 --dictionary-mib 64`は、既存の時間区間に加えて`profile.price_prediction`を返す。選択済みの各beam planについて、凍結モデルの最終node costと、初期モデルを複製し同じtoken列を`put_token`で再生した費用を比較する。後者は実際の確率更新順に従うが、どちらも共通の`bit_price`による**近似価格（1/256 bit単位）**であり、range coderの実出力bit数ではない。

記録はblock数・対象byte数・token数、両費用の合計、適応側−凍結側の符号付き差、block単位絶対差の合計と最大値/入力offset、過小/過大/同値の件数。巨大な集計値はJSON整数域を超える場合に十進文字列となる。区間冒頭の長大一致を即時採用した経路、BT4以外のplannerは記録対象外。対象byte数は入力全体のカバレッジを判断するために併記する。価格差本体は選択済みplanの集計で、tokenごとの誤差分布ではない。

`price_prediction.terminal_ranking`は、同じ終点bucketに残る全有限候補（最大beam幅）をbacktrackし、同じ初期モデルから個別再生して比較する。元の選択より推定費用が厳密に小さい候補があったblock数、仮想的な局所削減費用の和・最大値を記録する。同費用は改善に数えず、実際の選択planは変えない。途中で捨てた候補を復活させる全探索ではなく、次blockへ渡る距離履歴・実モデルの変化も反映しない。従って、この局所差の合計を実圧縮byte数や全体改善の上限/保証へ変換してはならない。

固定開発11件は`measure-profile.ps1 -LabPath <fixed.exe> -WorkDirectory <build/new> -MatchPolicies bt5 -BeamWidth 2 -BeamBlock 8192`で診断できる。区間指定は64/128/256/512/1024/2048/4096/8192、既定512。設定をCLIへ渡し、返却設定と照合してJSONへ保存する。実測と解釈の限界は[開発記録](DEVELOPMENT.md#bt4選択planの価格予測診断--2026-09-20-jst)を参照。

追加のモデル複製・再生はprofile有効時だけ。通常の圧縮出力は変更しないが、無効判定の分岐は残るため速度影響がゼロとは保証しない。診断時はモデル1組と再利用する代替token列（最大区間長）の追加heapが必要で、候補数に応じて再生時間が増える。codecの通常要求容量予算の保証外。キャンセルcallbackの追加呼出しはなく、診断中の応答時間も保証しない。失敗・panic・他スレッド・次captureへ集計を持ち越さない。既存profile同様、計測付き時間を7-Zipや通常codecとの性能比較に使わない。

## 7-Zipとの比較

`measure-profile.ps1 -MatchPolicies bt4`でBT4も診断できる。BT木の準備とfrontier絞り込みは従来の`find_matches`計測枠の外にある。`beam_plan`から`warm_model`と`expand_nodes`を引いた値は未分類残差であり、木だけの時間ではない。出力不変のBT4改良を比較するときは`measure-matcher.ps1`へ`-ReferenceMatches bt4 -RequireIdenticalFrames`を指定し、入力ごとに両binaryのframe SHA-256一致を追加検査する。既定の参考側は引き続き`priced-tie`。

CompactTokenはRep indexをu8、通常Matchの長さ−1をu16へ保存し、field順も含め8 bytesに収める。最大長65536は失われず、距離・費用・状態規則・wireは維持する。BeamNodeは現在32 bytesで、40 bytes版からB512/W4なら`(B+1)*W*8` bytesを削減する。価格u32化の上限は最大区間8192と価格上限のconst assertで検査し、親のprevious_match packingも専用試験で照合した。固定開発11入力・5対では同一binary内の内部圧縮時間中央値合計が2.93%短縮（7/11入力改善）、出力一致を確認した。これはプロセス全体のメモリ削減率や普遍的な速度向上率ではない。native-solid 5反復では圧縮1,428.9347対783.9407 msで約1.82倍遅く、総合目標は未達。詳細は開発記録を参照。

`measure-matcher.ps1`の各側の`process_observation`は開始UTC、起動から終了・出力回収までの`wall_ms`、子プロセス全体の`cpu_ms`を記録する。CPU時間が取得不能なら`cpu_ms=null`、`cpu_status=unavailable`とし、ゼロへ置換しない。warm-up・圧縮・復号などを含む補助指標であり、`samples[].encode_ms`を置き換えない。wallとCPUの差だけではスケジューラ待機などの原因を特定できず、短い処理ではCPU時間の粒度にも注意する。同一binary・同一方針を両側へ渡す対照試験の差は最適化ではなく測定変動として扱う。

matcher変更で圧縮出力が変わる候補の内部比較には`measure-matcher.ps1 -LabPath <候補binary> -ReferenceLabPath <採用済みbinary> -WorkDirectory <build以下の新規ディレクトリ> -Repeats 5`を使う。候補は明示的な`bt4`、基準は`priced-tie`、共通条件はBlended/幅4/区間512/64 MiB。固定11入力を交互順で起動し、各processのwarm-upと復元・決定性確認後の1標本を対にする。`-CandidateMatches priced-tie`では同一binaryを両側へ渡す対照試験も可能。旧出力のhash同値を要求する`measure-internal.ps1`とは用途を分け、総サイズ・個別サイズ・時間をreportから判定する。研究候補の選択肢が存在するだけでは採用・性能達成を意味しない。

内部の律速箇所を再確認する場合は、`./experiments/khc/measure-profile.ps1 -LabPath <固定したkhc_lab.exe> -WorkDirectory <build以下の新規ディレクトリ>`を使う。固定開発11入力、Blended/幅4/区間512/辞書64 MiB、NearestとPricedTieを既定計測し、`-MatchPolicies`でBT4/BT5/Hybridも指定できる。通常出力との一致と完全復元はCLI内部で検査し、実行ファイル・入力のhashと区間時間をJSONへ保存する。計測付きinclusive時間は入れ子が重複するため加算せず、7-Zipや計測なしの速度比較へ流用しない。現在のworking treeではなく指定binaryを測るので、そのbinaryの出自は別途確認する。

[設計書の合格条件](../../HIGH_COMPRESSION_DESIGN.md#6-7-zipとの比較プロトコル)を参照。`bench`はI/Oを除くKHC内部時間であり、7-Zip CLI時間との速度比較には使わない。`compare.ps1`は双方をCLIとして起動し、同じ単一入力・同じ指定辞書（既定8 MiB）・1 thread・変換なしで既定5回を交互計測する。`-Algorithms`で候補、`-DictionaryMiB`で共通辞書、`-BeamWidth`/`-BeamBlock`/`-BeamModel`/`-BeamMatches`で研究用探索設定を指定する。全設定はreportに記録する。warm-upを別枠にし、復元SHA-256と出力再現性を検証する。

これはholdout評価、完成書庫比較、全メモリ制約の公平な実証ではない。小入力ではプロセス起動/I/Oの影響が大きい。総合性能の合格判定には使用しない。

2026-09-18の[初回比較結果](BASELINE.md): 4入力すべてで7z/LZMA2より大きく、圧縮率目標は未達。

[開発11入力の反復比較](DEVELOPMENT.md): 既定Lzのpayload合計はLZMA2より8.045%大きい。研究用beamのCurrentは0.258%大きく、`--algorithm beam --beam-model blended`では合計を0.453%下回った。さらに`--beam-matches priced-tie`を付けると0.608%下回るが、個別9入力で負け、圧縮時間は7zの約10.35倍。状態候補の出力不変な早期除外でKHC内部時間を約13%短縮したが、総合目標は未達。PricedTieは比較研究用に限定し、既定や製品APIへの採用は見送る。合計サイズだけの部分勝利を目標達成に数えない。

[公開コーパスの固定条件](CORPORA.md)に基づき、開発11入力と未使用holdout12入力を分離した。合格条件を小標本の部分勝利へ変更しない。

2026-09-19のBT4研究候補は、同じ開発集合の5対比較でPricedTieよりpayloadを1,111 bytes減らし、入力別中央値を合計した内部圧縮時間を約30.76%短縮した。続くrep一致長cacheの使用済みprefix化は別の5対比較で約4.36%、Rep長さ候補の一括展開はさらに別の5対で約7.69%短縮し、出力は不変。ただし一括展開は8入力改善・3入力遅化で、plrabn12は約14.52%遅くなった。その後のRep候補8/16→9/17置換はpayloadをさらに176 bytes減らしたが、速度向上は立証されていない。置換後の7-ZipとのCLI 5反復ではpayload 489,138対493,427 bytes、圧縮時間6,484.05対1,211.81 msで約5.35倍の遅れが残る。別run間のCLI比率差を最適化の効果とはしない。個別サイズは2勝9敗、追加メモリも必要。研究候補として保持するが、既定や製品APIへ昇格せず、総合目標未達の判定を維持する。詳細は[開発記録](DEVELOPMENT.md#bt4-rep候補長の符号境界への置換)。
