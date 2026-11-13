# UnLhaRe 新しい可逆圧縮形式の技術選定

本線は通常CPUで動く自己完結形式とする。最初の候補は、既存のBWTとrank/run文法を利用し、全決定を整数CDFによる静的モデルで符号化する方式である。モデルの記述費用を含めて選び、重い適応予測器を復号経路から取り除けるかを小規模試作で検証する。優位性は未証明であり、失敗した候補を無期限に調整しない。

量子実機を必要とする方式は採用しない。量子着想のMPSは確率モデルの研究候補だが、今回のCPU・資源・完全復元条件を満たす汎用ファイル圧縮の実証を確認できない。量子状態圧縮の結果を普通のファイル圧縮の改善率として使わない。

## 対象と調査日時

調査日は2026年10月5日、日本時間。外部資料は論文、公式仕様、著者実装の確認時点の版である。公開日と最終更新日を下表で区別し、日付が取得できない資料は不明とした。検索範囲内で見つからないことは、方式や先行研究が存在しない証明ではない。

対象はUnLhaReのRust 64bit版、WindowsとmacOSのx64とARM64である。UnLha32Reは対象外。新形式はLHAのLH0/LH4/LH5/LH6/LH7/LHXのmethod識別子を使用せず、別magicと形式versionを持つ。既存のLHA API、C ABI、.NET契約とdirty worktreeを維持する。

最新GOALは調査から本体統合・テスト・文書化までを許可している。直前の「提案だけ」の制限は撤回された。一方、公開・push・リリース・課金・既存データの破壊的変更は許可されていない。旧設計書の「性能目標未達」を維持し、完成条件は最新GOALに従って、実装完成と性能優位の達成を別々に報告する。既存の固定比較値を変更したり、過去の失敗を合格へ書き換えたりしない。

## ローカルで確認した既存設計

| 経路 | 確認できた構造 | 維持する条件と未達事項 |
| --- | --- | --- |
| 研究用KHC | `mod.rs`は64MiB入力上限、別magic `KHC0LAB\0`、revision 1。LZ、文脈、range、rANS、beamの複数経路がある | 製品APIではない。単独研究codecを製品統合済みとしない |
| LZ経路 | 辞書・一致探索・beam。`lz.rs`のAVX2比較はruntime検出とportable経路を持つ | AVX2の存在だけで本候補の高速化やARM64対応を証明しない |
| BWT経路 | 自前SA-IS、一意最小sentinel、rank/run文法、6種類の決定、class別10bit履歴 | `grammar.rs`の履歴は各決定後にchildを2bitずつ追加する。k=1の暗黙決定も履歴を更新する |
| 適応BWT研究codec | `anchored-wire/codec.rs`はpredict→range→observeを各branchで実行 | 一部classを静的化しても共有teacher状態の更新を省略できない。全静的化は別方式として検証する |
| 有料MDL木 | `paid-code-tree`は低位/高位履歴順、整数CDF、root/split/leaf/固定符号表の実費を共同目的へ課金 | 選択にfloat lossを使うがwireから復号するCDFは整数。実製品ではdecoderがfloatを再計算しない設計を維持する |
| 書庫安全性 | 新版AGENTSはrootからのno-follow、検査済み親handle、一時作成、CRC後no-replace公開を要求 | 新形式の展開でもこの経路を再利用し、直接path書込みを追加しない |

読取対象は`HIGH_COMPRESSION_DESIGN.md`、実験README、CORPORA、CORPUS_MANIFEST、`mod.rs`のencode/decode、`lz.rs`、`solid.rs`、BWT/frontend/grammar/counts、paidモデルと実metadata、既存結果、公開APIの定義である。実装変更前には呼出し元と安全な公開経路をさらに照合する。

固定開発データはCanterbury 11件、本文2,810,784B。既存group表現は2,811,006Bで、本文だけとの比較に混ぜない。Silesia 12件211,938,580Bは当初未測定holdoutとして登録されたが、後続で全量測定しMozilla/x-ray診断と設計変更にも使ったため、現在は開発・調整用であり今後の未見評価には使わない。最初のmanifestに残る`holdout-not-yet-measured`は登録時点の履歴ラベルである。公式公開は包括的な再配布許諾ではないので、入力そのものをcommitや配布物に含めない。

直近の`paid-code-tree/RESULT_20261005.md`と保存reportを確認した。screenはtoken 478,416B＋実metadata 2,791B＋side 3,079B＝484,286B、旧固定size target 483,599Bを687B超える。compile/nativeの診断成功とmetadataの復号一致はあるが、tokenは符号長からの試算で、完成frame、teacher-free decoder、CLI速度、holdout、4環境nativeの証拠ではない。保存report SHA256は`1A244D67F80617B92812E715C2CA45394144CA51D59A45E6D1D8703F5711C116`。

既存設計書には2026年9月26日の完成LZ/rANS比較がある。固定11件でKHC/7-Zipは483,197/483,599B、起動・I/O込み圧縮中央値1,084.7545/626.2071ms、展開44.4644/41.3077ms、圧縮時private memory 53,747,712/37,044,224B。これは過去の別構成で、現在の静的モデルの性能ではない。新方式の比較は同一セッションで取り直す。

## 候補の比較と順位

以下の期待効果は設計上の仮説で、改善率の約束ではない。全候補にstored保存を用意し、既圧縮・暗号化・ランダム入力に必ず圧縮効果があるとは仮定しない。

| 順位 | 方式と得意な入力 | 期待する効果と根拠 | 弱点と難度 | 依存と判断 |
| --- | --- | --- | --- | --- |
| 1 | 全決定の静的MDL文脈木＋BWT rank/run。テキスト、ソース、まとまった反復データ | モデル保存費を含む木選択と整数CDFを復号時にlookupし、CTS/pool/teacherの学習を除去する。既存有料metadata実装を土台にできる | 二段階処理、BWTメモリ、metadata過多、文法の逐次依存。難度高 | 新しい外部モデルなし。自前実装。最初に1構成だけ試作する。近い先行例はPTP-MDL[^1] |
| 2 | byte単位の可逆構造分離＋軽量辞書/静的符号。JSON、ログ、数値混在テキスト、実行コード | 数字や差分、分岐addressなど統計の違う情報を別streamへ分ける。STCの数字分離と既存BCJ/deltaが比較対象[^2][^3] | escape、並び順、例外、side情報の費用、型誤判定。難度中～高 | STCのGPLコードや固定M03表は取り込まない。必要なら独立実装。整形・文字正規化・再encodingは禁止 |
| 3 | 書庫内CDC重複除去＋小型共有辞書＋非重複chunk符号化。類似版、バックアップ、多数の小ファイル | 重複本文の再保存を参照へ置換。FastCDCとZstd辞書を基準とする[^4][^5] | index/辞書費、chunk依存、単体ファイルでは利得不足、hash衝突対策。難度中～高 | 外部バックアップがなくても復元できる書庫内参照に限定。既存phrase候補失敗の構成をそのまま再実行しない |
| 4 | 小型の整数byte予測器＋entropy coder。主にテキストの圧縮率優先枠 | 学習モデルの予測力を利用。RWKV/LLMの作者測定はテキストの可能性を示す[^6][^7] | 推論時間、重み配布、異種CPUのCDF一致、学習データ混入。難度高 | 巨大モデル取得とGPU必須は不採用。自前の上限付きinteger predictorを研究する場合も全model費用を含める。今は後順位 |

第1候補の差分は、既存のclass2/5だけの置換から全6classへ対象を広げ、teacherの共有状態に依存せず、モデルの実wire費用と符号化lossを同時に評価することにある。MDL、BWT、静的モデル、二段階符号化そのものは既知技術であり、新しい圧縮原理とは呼ばない。独自の技術的貢献は、rank/run特有の文法と履歴、root順選択、実metadata料金、資源予算、stored選択を組み合わせた実装・制御方法として検証する。学術的新規性は未確認である。

全静的化でも、次のsymbolやrunが判明するまで後続文脈が決まらない。ANS stateを4個に増やすだけで並列復号になるとは扱わない。共有モデルを使う独立block、boundary履歴、reset、再開情報を明示する場合に限り並列化を別段階で比較する。既存研究では4stateだけの追加は遅化しており、同じ候補を再採用しない。ANS interleavingの一般的な可能性と今回の文法依存を区別する[^8]。

## 先行研究と独自部分の検証

| 候補 | 最も近い先行例と共通点 | 今回検証する具体的相違点 | 工夫を外す比較 |
| --- | --- | --- | --- |
| 静的MDL | PTP-MDLは全入力から文脈木を選び、モデル共有で複数blockを符号化する[^1] | BWT rank/runの多値branch、class別履歴、wire料金を直接課金するCDF/木/順序選択、教師状態の全除去 | order-0、木なし、履歴順固定、header未課金の各対照。無料モデル結果は実サイズに使わない |
| 可逆構造分離 | STCはdigit runsをmain/sideへ分離し、安定bucket順で復元する[^2]。BCJ/deltaも既存 | 小型の複数型候補を実費と計算予算で選ぶ。必要な場合だけ採用し、同一codecに接続 | transformなし、型判定なし、side費未課金、標準BCJ/delta。STCの単純移植なら再実装として報告 |
| 重複/辞書 | FastCDCの内容依存chunk境界、Zstdの共有辞書は既知[^4][^5] | 書庫内に閉じた参照とdecode budget/選択展開の制御 | CDCなし、辞書なし、両方なし。外部dictionaryあり/なしを別集計 |
| 学習予測 | ts_zip、LLMZip等は予測＋算術符号を実装済み[^6][^7] | 小さい整数状態、学習環境なしのCPU復号、完全自己完結での総費用 | 同RAM/timeの従来context、shared weights費を含む/含まない別表。modelを隠した結果は不採用 |

これらの組合せが世界初という根拠はない。有限の検索で先行例を発見できなかった差分も「新規性未確認」と記す。論文のアルゴリズムの検討とコードのコピーは別の判断であり、特許非侵害もこの調査から保証しない。

## 量子技術の採否

| 区分 | 確認できたこと | 通常ファイルへの適用と採否 |
| --- | --- | --- |
| 量子状態の圧縮 | Schumacher/Jozsa系は量子情報源、von Neumann entropy、漸近的な忠実度を扱う[^9] | 任意byte列を必ず完全復元する古典ファイルcodecとは別問題。本線の採用根拠にしない |
| 実量子LZ/BWT | Gibneyほかは入力quantum oracleを前提にLZ因子数zを使う計算量Õ(√nz)を示す。一般最悪ケースは線形。作業memory用QRAMは要求しない[^10] | 圧縮率改善や通常PCの実測高速化ではない。入力oracle構築、状態準備、測定反復、古典出力、検証、誤り訂正、機材を含む総比較が未確認。本線不採用 |
| CPU上の量子着想 | MPS/Born modelは正規化した条件付き確率を計算でき、生成モデルの実験がある[^11] | MPSをentropy coderの予測器として使う案は成立し得るが、任意byteの可逆圧縮と総費用の優位は未確認。今回は実装しない |

量子実機を検討するなら、量子access可能な入力が既に存在し、準備と古典I/Oが優位性を相殺せず、誤り訂正を含む必要qubit・ゲート・時間・成功確率を見積もれることが前提になる。必要機材は量子processor、制御/readout、方式に応じた冷却等、入力oracle実装と古典hostである。機器仕様・費用は未確定で購入やサービス契約は行わない。qRAM資源論文は仮定を置く理論見積もりであり、2026年実機や量子LZへ数値を移せない[^12]。

CPU上のstate-vector simulationは量子計算の高速化をそのまま得ない。tensor networkの低rank近似は数値モデルを小さくするが、データを近似しただけでは可逆ではない。MPSを予測器に限定し、同じ整数CDFからentropy decodeするなら、予測誤差は符号長の問題になり得る。それでもCDF決定性、全symbolの非ゼロ支持、model/parameter費用、bond dimensionの時間とRAMを別途検証する必要がある。このcodec構成は提案上の推論であってMPS論文の実証結果ではない。

## 一次資料の版と評価条件

| 資料 | 公開日または確認版 | 確認した証拠と適用限界 | 利用条件 |
| --- | --- | --- | --- |
| PTP-MDL[^1] | 初稿2014-07-06、v4 2015-03-21 | 理論とprototype数値比較。O(N/B)の記述を実Bcoreの線形高速化保証としない。BWT/rank-runへの優位は未実測 | code/dataの許諾未確認。移植しない |
| STC[^2] | 初稿2026-06-02、v3 2026-06-15。repo版1.0、更新履歴2026-06-07等 | enwik9作者結果157,388,188B、decoder source package183,174B。digit分離ablationはarchive2,629,561B減。独立leaderboard認定ではない | code GPL-3.0、M03 table由来告知あり、同梱libsais Apache-2.0。data再配布許諾は別問題 |
| FastCDC[^4] | USENIX ATC 2016 | 著者のdedup benchmark。境界決定と重複検出の成果をcodec全体の速度倍率へ換算しない | 論文閲覧と実装/data使用条件は別。コードコピーなし |
| ts_zip[^6] | 配布版2024-03-02、ページ更新日不明 | RWKV169M v4、8bit weights。作者enwik8は13,825,741B、xzは24,865,244B。RTX4090最大1MB/s、RAM4GB。CPU速度は未確認 | code/weights/dataの個別条件をページだけで確定できず。不採用 |
| LLMZip[^7] | 初稿2023-06-06、今回最新全評価未確定 | 英語の予備実験。repoはbatch entropy算出結果をそのまま復号できない旨に注意。初期contextを外から渡す評価は別枠 | repo code GPL-3.0、LLaMA weights/tokenizer/dataは別条件。取り込まない |
| 量子LZ[^10] | 初稿2023-11-03、SODA2024 | query/gate/RAM操作の理論。通常fileからの総実機時間や圧縮率実験ではない | 実機codecコード/model/data条件未確認 |
| MPS[^11] | 初稿2017-09-06、v3 2018-07-19 | Bars and Stripes、binary patterns、MNIST等の生成/尤度評価。通常file entropy codecではない | 作者コードMIT、モデル・同梱dataは個別条件未確認 |
| Zstandard[^5][^13] | RFC8878 2021-02、実装v1.5.7リリース2025-02-19 | 当日release一覧のLatestを確認。公式READMEのi7-9700K/Ubuntu24.04/gcc14.2/Silesia速度は参考でローカル測定の代替にしない | BSD-3-ClauseまたはGPLv2。BSD側の著作権・条件を保持。辞書/dataは別 |
| 7-Zip/LZMA2[^3] | 26.03、2026-09-03 | 当日公式ページで確認。辞書、filter、solid、threadを明示してローカル比較する | 7-Zip本体は主にLGPLと一部BSD/unRAR制限。LZMA SDKはpublic domain。混同しない |
| ANS interleaving[^8] | 2014-02-14 | superscalar/SIMDへの符号器上の可能性。依存する予測モデルの並列化を自動的に保証しない | 論文と実装licenseは別。今回は理論参照 |
| libsais[^14] | v2.10.4、2025-09-01 | BWT/suffix構築、OpenMP対応。作者はmemory bandwidth依存を説明。現行Rust BWTの速度とは別 | Apache-2.0。最初の試作には追加依存しない |

新しいという理由で採用しない。最新のSTCは有用な対照だが、巨大enwik9と約10GiB級の作者peak memoryを小型CPU codecへそのまま持ち込まない。ACTW/PTW等の成熟した文脈分割も先行技術として確認したが、今回すべてを実装することは目的でない。

## 完全復元と保存形式の契約

新形式はversionを凍結する前にmagic、必須feature、header長、元長、payload長、block数、model/transform ID、model長、dictionary長、checksum、末尾規則をbit単位で文書化する。unknown必須featureやversionは非対応として拒否する。旧LHAと旧研究magicの内容を変更しない。

復号に必要なCDF/木/辞書/並び順/初期履歴/escapeは形式内に格納するか、versionで決まる小さい定数として明示する。整数CDFは支持・tail・総量32768・最小頻度・深さ・root数・bit長・paddingを検査してから使用する。encoderのfloatによる探索が出力を変えても、decoderはその探索を再現せず伝送済み整数CDFを読む。runtimeのlog/exp/FMAや外部modelサービスに復元を依存させない。

完全復元は各可逆変換の逆写像とentropy coderの同一区間・終了条件から設計として説明し、有限テストだけで全入力を証明したとは主張しない。任意byte列にはstored fallbackを持つ。最小限のcontainer overheadを隠さず、空/極小では拡大する可能性を説明する。

破損検出は認証ではない。CRCだけで悪意ある改変への認証やAI攻撃不能を保証しない。暗号化は初期範囲外のまま、必要なら標準AEADを別の仕様と脅威モデルで扱う。新書庫からcode/plugin/model programを実行しない。

length/offset加算、token総数、distance、run、model extentをchecked演算で検証し、上限の予約後だけ確保する。非正準・truncated・overlong・trailing、checksumを修復した意味不正も拒否対象にする。展開上限、entry数、name長、最大memory、作業量、取消を制約する。書庫出力は既存handle-relative一時領域から検査後no-replace公開し、path traversal/link/既存出力の上書きを拒否する。

総費用は次で報告する。

`総圧縮量 = frame + manifest + payload + model + dictionary + index + checksum + 必要な初期状態`

共有modelはbyte数とhash、配布方法、利用条件を記録する。自己完結1fileと、N件でmodel費を分担する`Σstream + shared_model`を別に示す。必要な情報を外部へ移して減ったstreamだけを圧縮率改善とは呼ばない。

## 段階的試作と資源上限

| 段階 | 実施内容 | 事前の判定と中止条件 |
| --- | --- | --- |
| A | 全6classの静的有料CDFを1構成で測る。まず小入力、次に既存固定group。packet parse/CDF/履歴/費用を直接照合 | teacher費を無料にしない。全field検査、元Meta一致、model32MiB/phase64MiB/OS peak各160MiB/scratch64KiB内。storedより大きい、資源超過、復号不一致なら構成を止める |
| B | 有望なら別magicの完成frame、整数range coder、逆BWT、storedを実装。小さい有限E2Eから始める | frame全費用/CRC/終了を確認。Aの費用screenだけを完成扱いしない。原子公開・取消・limitsが満たせないものは統合しない |
| C | current/新方式/Zstd/LZMA2を同sessionで比較し、ablationを実行する | 旧483599B/574.5624ms/47.3884msは目標基準として別記。速さとサイズ/RAMのParetoを報告。試作2構成まで、1構成の原因修正を除くblind sweepなし |
| D | 採用codecをUnLhaReの実Rust API・CLI create/list/extractへ統合。別formatとして明示 | 現行APIとLHA wire回帰なし。新公開C/.NET面が必要なら関連header/契約/AOTもまとめて確認する。単独実験で終了しない |
| E | 分類別holdout、native/portable、Windows/macOS x64/ARM64、既存build/静的検査、仕様/README | 実行できない環境は未実施。性能未達と実装完成を分ける。必要な検証不足を完了扱いしない |

研究記録の追加上限は1MiB。段階A/Bの各standalone出力上限8MiB、既存入力をコピーしない。後続Cargo buildは既存`build/cargo`を再利用し、実行前に増分を見積もり、実験規約の256MiB上限を適用する。追加target-dirや巨大model/cacheを作らない。全工程で空き5GiBに加えて予定予算を確保する。見積もりを超える拡大は事前確認し、既存成果物や共有cacheを消して続行しない。

実行時間予算は最初のscreen native120秒/compile60秒、各codec評価case60秒、評価suite全体30分以内を初期上限とする。超過は記録して該当構成を棄却または原因修正し、他候補へ無制限に波及させない。後段の範囲拡大は新たな上限を事前に記録する。

## 公平な評価と再現手順

比較は二枠とする。圧縮率優先は同じ上限内で各方式の事前登録した高圧縮設定を測り、探索したすべての時間を含める。時間・memory一致枠は同CPU、threads、wall上限、encode/decode memory上限をそろえ、予算を超えた設定は除外理由を記録する。Zstdの既定threadに依存しない。

codec比較は同byte列・transformなし・同boundary。書庫比較は同file集合と名前/順序/長さ/時刻の契約をそろえ、双方にsolidと標準filterを許す。KHCだけtransformや辞書費を省く比較はしない。Zstd単独frameと7z書庫はmetadata範囲をそろえない限り同じ列へ混ぜない。

設定例は、固定SHAの7za26.03で`a -t7z -m0=lzma2 -mx=9 -md=64m -mmt=1 -ms=on`、Zstd1.5.7で`-T1 -3`/`-T1 -19`を事前登録する。実際のコマンドはharnessが入力/出力絶対path、辞書/solid/filterと上限を加えたargvとして保存する。高memory設定は予算内のものだけを別枠で使用する。新codecのコマンドは実装後に版・hashとともに固定する。インストール/実行していないコマンドを測定済みとは報告しない。

開発入力には既存Canterbury、Silesia、過去にscreen・調整・設計判断へ使った全familyを含める。未見評価にはこれらと別のsource familyから、日本語/自然文、JSON/log、source/executable、raw整数、類似版、PNG/JPEG/zip、空/1B/小file、固定seedランダム、暗号化dataを含める。合成ランダムを実暗号化fileと呼ばない。暗号化fixtureがなければ、既存の利用可能な暗号実装で生成したものと手順を別途固定する。追加sampleは最初1MiB、次に総64MiBまでの読み取りwindowとし、巨大展開は行わない。

file hash/生成seed/切出しoffset/length/分類をmanifestに保存し、train/tune/holdoutを系列単位で分ける。同じ資料の別版・別圧縮版を両側に入れない。file内の自己完結model学習は許可しmodelを課金するが、holdoutを見たパラメーター調整と混同しない。評価したholdoutは以後未見と呼ばない。

warmup1＋9回、順番交互、同sessionで測り、全sampleを保存する。quiet CPU基準15%を維持し、超過sampleを都合よく除去せず中断理由を残す。start/I/O/metadata/model構築/終端/CRCを含むwall、MB/s、最大working set/private/RSS、allocator容量、必要に応じpage cacheを報告する。encode/decode別に計測し、中央値と範囲とpaired比を示す。

全caseで復元をbyte比較とSHA256で照合する。1件ずつ処理して圧縮物は1方式1件だけ保持し、復号は可能ならhash sinkへ流す。実ファイル公開は小さい安全性E2Eで検証する。失敗時の証拠は最小入力と上限付き理由だけを保持し、生trace・複数全展開物は保存しない。

テストは実装前に失敗条件を固定する。空、全256byte、反復、極端skew、境界±1、複数file、stored、取消、bad magic/version/長さ/model/depth/CDF/bit終端/checksum、全byte位置の小frame切断、意味不正、path traversal、reparse/symlink、no-clobber、検証後公開をE2Eで確認する。小domainの全列挙と時間制限付きfuzzを併用する。post-code unit大量追加ではなく、再現可能な有限E2E成果物を残す。

## 7-Zip最終超過判定の事前登録 — 2026-10-16

2026-10-16の開始前確認では、[公式Download page](https://www.7-zip.org/download.html)の先頭配布項目が7-Zip **26.04**（2026-10-05）であり、上記の事前登録版と一致する。`C:\Program Files\7-Zip\7z.exe`のFileVersion/ProductVersionはともに26.04、577,536 B、SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`で、事前登録hashと一致した（file metadata/hashだけを読み、実行はしていない）。Plumivox `scope=all` query `7-Zip latest stable release version compression benchmark 7-zip.org`（2026-02-23〜2026-10-16）は0投稿、`completeSearch=false`で非網羅的。新payloadのdownloadもholdout比較も行っていない。実測直前にはversionと実行file hashを再照合する。

この判定は未使用のholdoutだけに適用する。Canterbury（`ptt5`を含む）とSilesia全corpusは過去の比較で使ったため、全資料を開発データとして除外する。その他の過去screen・調整・設計判断入力と同一・近縁familyも除外する。holdoutの最初の圧縮前に、source family単位の分割、全入力のSHA-256・長さ・category・seed/offset、candidate strategy、tool hashをmanifestへ固定し、評価後の入替えをしない。対象categoryはnatural-language prose、日本語text、JSON/log、source code、executable binary、raw integer、similar-version release-artifact pairs、PNG、JPEG、ZIP、空/極小、固定seed random、encrypted dataを含む。各source familyは事前にちょうど1 categoryへ割当て、categoryごとに少なくとも3つの独立familyを用意する。各familyの固定file集合（1件以上）を1つのcaseとし、その集合を1つの書庫として測る。candidateと7-Zipへ同一のfile bytes、relative path、mtime、入力順を渡し、solidはfamily内だけに許す。複数file書庫の総bytesや時間を個々のfileへ配賦しない。3 familyは計算可能性の下限であって区間精度を保証しないため、family数・bootstrapで得た異なる推定値数・区間幅も報告し、この有限corpusを越えた母集団一般化はしない。

2026-10-16の既使用family監査で、Canterbury 11-file/solid group/`ptt5`、Silesia全12-file/`x-ray`先頭8×1 MiB/`dickens`・`mozilla`・`osdb`・`x-ray`先頭各256 KiB、`lcet10.txt`/`plrabn12.txt`、UnLhaReの`README.md`・`src/writer.rs`・`include/unlhare.h`、7-Zip `7za` 26.03、合成`empty`・1-byte `0xA5`・repeat4KiB・xorshift32（seed `0x6d2b79f5`）random64KiB・日本語JSON4KiB・.NET AES-CBC/NoPadding固定key/IV・Zstd3のrepeat4KiB frameがscreen・調整・方式選択に使われていたことを確認した。これらの固定入力、生成recipeおよび同一・近縁familyはdevelopmentとして除外する。PuTTY Plink 0.82→0.83と7zr 24.09→25.01は版間screenの事前登録を確認したが、現時点で実行reportを確認できていないため、artifact監査までは候補から除外する。

空fileと既使用の1-byte fixtureは性能screenにも使われたため、同じ0-byte/1-byte列を独立familyとして水増ししない。emptyはmandatory correctness/descriptive controlとして別記し、統計laneの「空/極小」categoryは2〜65,536 byteの新しい非空fileを持つ独立source familyを少なくとも3つ用意して集計する。tiny caseのsourceはJSON、xorshift、repeatの既使用recipeや同一・近縁familyを再利用しない。

7-Zip比較対象は公式配布の26.04 x64（開始直前に現行stable版を照合し、実行file hashをmanifestへ固定）とする。7z形式で最大圧縮level9、dictionary 64 MiB、1 thread、solid、標準method/filter選択、name順、mtimeのみを使い、実効method/filter/dictionaryを`-slt`で保存する。基準argvは`a -t7z -mx=9 -md=64m -mmt=1 -ms=on -mqs=off -mtm=on -mtc=off -mta=off -spd -sccUTF-8 <archive> @<sorted-list>`とし、明示的なcoder/filter置換はしない。実行fileは`C:\Program Files\7-Zip\7z.exe`、2026-10-16確認SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`。同形式はsolid圧縮とLZMA2のほか複数の標準filterを持つ[^18]。この基準設定の実効filterと160 MiB上限適合をholdout未使用の開発入力で事前確認し、必要な標準filterを追加する場合はその固定argvをmanifest前に追記する。適合を確認できない場合はholdout測定へ進まず、理由と再登録した設定を先に記録する。

全方式で1 thread、encodeまたは完全decodeの各process command当たり最大60秒、各process peak working set/private bytes 160 MiB、suite全体30分を共通の上限とする。1 warmup＋9 paired measured roundsを順序交互で同一session内に実行し、3方式A=KHC default（参考比較）/B=選択candidate/C=7-Zipの順をwarmup `ABC`、measured `ABC / BCA / CAB / ACB / CBA / BAC / ABC / BCA / CAB`へ固定する。各encodeと完全decode commandを個別に60秒制限し、wallにはprocess開始/I/O/metadata/model構築/終端/CRCを含める。decodeは実fileへの完全展開とし、展開後のbyte/SHA照合を行う。全書庫bytesにはheader/manifest/dictionary/model/checksumを含める。CPU `_Total`を各command前に記録し、15%超過または取得不能なら中断する。B/Cのどれかのcaseで上限超過・timeout・復元失敗したらcaseを選択的に除外せず、該当laneを不成立とする。Aの同種失敗は参考比較の失敗としてそのまま報告し、B対Cのlane判定には使わない。共有入力・tool・runnerのhash/version不一致やsuite全体の実行基盤破損は比較全体を無効とする。固定1GiB lifecycle budgetへの登録前preflightも必須とし、capやrootの迂回はしない。

一次判定のratioはB（候補）/C（7-Zip）だけから計算する。サイズは決定性確認済みの完全書庫bytesから各family比を求める。時間は各family・各測定roundのpaired B/C wall比を取り、9比の中央値をfamily代表値とする。各指標でfamily比の幾何平均をcategory内で計算し、そのcategory値を等重みで幾何平均してoverallを得る。`exp(mean(log(ratio)))`を用い、raw総bytes・総wallも併記する。peak memoryは各family・方式・方向について9 measured process中の最大値を使う。統計区間はfamily単位でcategory内を層化bootstrapし、各categoryのfamily数と同数を復元抽出する10,000反復（seed `0x4b484331`）でoverall幾何平均比の片側97.5%上限を求める。反復9回を独立familyとして扱わない。familyはcategoryを跨がせない。二laneのどちらか一方の通過を許すため、各laneに片側α=0.025を割り当てるBonferroni補正を使う（bootstrap近似の誤差制御であり厳密な有限標本保証とは主張しない）。A=KHC current defaultはreferenceとして同じ入力・上限で測定するが、A/Cの値と失敗は記述統計として別記し、primary laneの集計・confidence interval・合否には含めない。B=候補KCS1 revision 7（別候補を選ぶ場合はholdout前に凍結）、C=7-Zipとし、版・hash・method・全argvをmanifest確定後に固定する。

次の二laneを両方報告し、どちらか一つを完全に満たした場合だけ7-Zipに対する性能優位と判定する。

| lane | 事前登録した合格基準 |
| --- | --- |
| 圧縮率優先 | 両方式が同じ60秒/160 MiB上限を全caseで満たし、candidateのカテゴリ等重み幾何平均書庫bytes比が`≤0.95`（point estimateで少なくとも5%小さい）、片側97.5%上限が`<1.00`。どのカテゴリも平均比`>1.05`に悪化しない。 |
| 速度優先 | 両方式が同じ60秒/160 MiB上限を全caseで満たし、candidateのカテゴリ等重み幾何平均書庫bytes比`≤1.00`、その片側97.5%上限も`≤1.00`、どのカテゴリも`>1.05`に悪化しない。encodeと完全decodeの双方でcandidate/7-Zip paired wall比が`≤0.85`（point estimateで少なくとも15%高速）、各片側97.5%上限が`<1.00`、どのカテゴリもencode/decode平均比が`>1.05`に悪化しない。candidateの各方向のworking set/private bytesは全caseで`≤160 MiB`かつfamilyごとのpeak比が7-Zipの`≤1.10`。 |

いずれのlaneも通らない、holdout categoryを欠く、または信頼区間を算出できない場合は優位・GOAL達成を宣言しない。評価後に閾値を緩和せず、見たholdoutは以後tuningへ移し、新しいfamilyのholdoutが用意できた場合だけ別途再登録する。

## 2026-10-16 holdout source-family候補（manifest未凍結）

以下の表は既使用family監査後の初期暫定候補snapshotである。最終manifestでは13カテゴリ各3 family・計39件を目指すが、候補表には権利等で不採用となる場合に備えたoverflow候補も載せ、各カテゴリで適格な3 familyが揃うまではpayload取得や測定へ進まない。後続のreadiness／crosswalk監査で状態が更新された場合は該当する監査追記を優先する。source familyは独立した内容の作成元・project・datasetを単位とし、同じ内容の別URL・mirror・releaseを別familyとして数えない。この候補表は配布元・利用条件・source familyを絞るもので、入力file・version・member・metadata ID・取得物SHA-256・変換後sample SHA-256を固定したmanifestではない。payload取得・閲覧・hash・変換の有無は各監査追記に記録する。holdout候補は比較に使用していない。第一のholdout圧縮より前に全caseを一括して固定し、候補の入替えは固定前に限る。

### 候補採用とページ単位の権利確認（payload取得前に適用）

- 候補表のcategory順・各行の記載順を事前選択順とする。候補を数える前に、既使用familyとの独立性、公式配布元、公開条件を確認し、圧縮結果は採否に使わない。3 familyを確保できないcategoryは、payload取得や測定へ進まず、追加候補とその根拠を先に追記する。
- payloadへ触れる前に、公式の利用規約、個別の公表・配布ページ、版・公表日、正確なartifact/memberへのリンク、ページ上の著作権・第三者素材・引用・画像等の注意書きを記録する。規約の包括許諾だけで、個別資料に含まれる第三者要素まで許諾済みとはしない。
- HTML候補の標準recipeは、候補表で固定した単一canonical URLが返す`.html`応答bytesとする。markup、本文、表、caption、alt text、埋込み内容は残すが、別URLの画像・CSV・CSS・JavaScript・添付fileは含めず取得もしない。参照先が必要ならholdout取得前に個別artifact/member・権利根拠・必要表示を別途登録し、候補全体を再評価する。ページ表示後の文章だけの切出し・画像等の除外で権利問題を後付け回避しない。
- 前段の確認で取得候補として残したものに限り、選んだHTML/file/memberの権利表示・出典・埋込み要素を監査する。HTMLでは本文・表・ページ内に埋め込まれた図表・caption・alt textに加え、外部assetへの参照が何を示すかも確認する。別URLのasset本体は個別登録しない限り入力に含めない。配布物では選択memberと付随するlicense/NOTICEを対象にする。権利者・対象範囲・必要表示が不明な要素を含む候補は不採用とし、除外箇所だけを後から切り抜いて測定しない。
- 最終manifestは圧縮前に固定し、family/category、canonical source URL、artifactの版・日付、member path、取得物と入力bytesの長さ・SHA-256、展開・windowの有無とoffset/length、権利根拠URL・確認日・必要なattributionを記録する。容量上限で候補変更が必要なら測定前に表とmanifest案を改訂し、測定後の差し替えや見たholdoutの再利用をしない。

| category | 暫定候補family（一次配布元） |
| --- | --- |
| natural-language prose — overflow only (not counted toward the three-family target) | [Japan Fair Trade Commission press release, “株式会社シマノに対する勧告について”](https://www.jftc.go.jp/houdou/pressrelease/2025/sep/250917_kinki_shitauke.html), selected by title/date from the official [September 2025 press-release index](https://www.jftc.go.jp/houdou/pressrelease/2025/sep/index.html), dated 2025-09-17. Visible HTML contains agency narrative and numbered recommendations, plus a linked 288 KB print PDF (excluded from the single-HTML recipe); no raw HTML/PDF/assets were downloaded or hashed. The page footer says “Copyright © Japan Fair Trade Commission. All rights reserved”; its scope versus the site’s default PDL1.0 needs resolution. Third-party content and overlap remain unverified; not admitted to the holdout manifest. |
| natural-language prose — overflow only (not counted toward the three-family target) | [National Tax Tribunal Case Collection No.138, January–March 2025, first case](https://www.kfs.go.jp/service/JP/138/01/index.html), selected from the official [No.138 contents page](https://www.kfs.go.jp/service/JP/idx/138.html) by title and decision date before opening the case page. Candidate scope, page-specific third-party content, attachments, and overlap remain unverified; not admitted to the holdout manifest. |
| natural-language prose — overflow only (not counted toward the three-family target) | [National Archives of Japan, “国立公文書館デジタルアーカイブの2026年リニューアルについて―「Center for Archives」の実現に向けた新たなサービス基盤―”](https://www.archives.go.jp/publication/archives/no101/18790), selected from the official [『アーカイブズ』No.101 contents](https://www.archives.go.jp/publication/archives/), dated 2026-08-31; listed authors are 吉田敏也・一牛ゆかり・西山直志. The site policy permits attributed quotation/reprint/copy but rejects content-changing use; it is not PDL/CC. Only the contents index and policy were opened, not the candidate body; exact HTML scope, article-specific/third-party material, policy applicability, prior use and overlap remain unaudited. Plumivox `scope=all` query `国立公文書館 理化学研究所 日本語 記事 著作権 再利用`: 0 posts, `completeSearch=false`, non-exhaustive. Not rights-cleared or admitted to the holdout manifest. |
| natural-language prose — overflow only (not counted toward the three-family target) | [Financial Services Agency, Access FSA No. 276 HTML edition](https://www.fsa.go.jp/access/r8/276.html), dated 2026-08-27 and listed with HTML/PDF editions on the official [issue index](https://www.fsa.go.jp/access/index.html); the issue scope is the full HTML edition, not one article. Only the issue index and policy were opened; the issue body, PDF and assets were not. FSA's [website terms](https://www.fsa.go.jp/rules/) (updated 2025-10-09) assign copyright to FSA unless otherwise specified and apply [PDL1.0](https://www.digital.go.jp/resources/open_data/public_data_license_v1.0) where no specific rights notice is present; PDL1.0 permits reproduction, public transmission, adaptations and commercial use for covered material with source attribution and edit disclosure, but excludes logos/symbols and other specifically exempt material. It warns third-party rights may exist, may not be clearly marked, and are the reuser's responsibility. Exact issue-level rights marks, third-party material/assets, shared references, and prior-use overlap remain unreviewed; the candidate is overflow only, conditional and not admitted to the manifest. Plumivox `scope=all` query `金融庁 消費者庁 広報誌 コラム 著作権 再利用`: 0 posts, `completeSearch=false`, non-exhaustive. |
| natural-language prose | Project Gutenberg entries are withdrawn under the 2026-10-16 Japanese-source instruction. Provisional candidates in selection order: [Cabinet Office 2025 White Paper on Aging HTML](https://www8.cao.go.jp/kourei/whitepaper/w-2025/html/zenbun/index.html), [Environment Ministry 2025 Whitepaper HTML chapter](https://www.env.go.jp/policy/hakusyo/r07/html/hj25010201.html), and [MLIT 2025 White Paper HTML edition](https://www.mlit.go.jp/hakusyo/mlit/r06/hakusho/r07/index.html). A fourth overflow candidate, [Board of Audit of Japan FY2024 settlement inspection report, item (34)](https://report.jbaudit.go.jp/org/r06/2024-r06-0059-0.htm), was selected from the official contents index by title and report number before its body page was opened; its exact scope, rights/assets, and overlap remain pending. The MHLW [2025 Labor Economy Analysis page](https://www.mhlw.go.jp/stf/wp/hakusyo/roudou/25/25-1.html) lists PDF editions and is not counted as an HTML prose candidate. None is admitted to the holdout manifest; all candidates remain conditional pending page-scope, third-party-content, shared-data, and text-overlap checks. |
| 日本語text | 青空文庫の[No.2078『舞姫』](https://www.aozora.gr.jp/cards/000129/card2078.html)、[No.424『檸檬』](https://www.aozora.gr.jp/cards/000074/card424.html)、[No.752『坊っちゃん』](https://www.aozora.gr.jp/cards/000148/card752.html)を現行の暫定候補とする。No.2078は公式カードmetadataのみ確認し、ZIP/memberは未取得。No.424/752は後段の過去候補取得記録にbyte/hashを保持するが、最終選定前である。No.301『人間失格』は初出・没年の近接による権利期間懸念から撤回し、過去候補記録として保持する。選定後は公式ZIP内の唯一の非空`.txt` memberを無変換・byte-exactで入力するrecipeを適用する。公式規準は著作権切れ作品ファイルの再配布・形式変換を認める一方、底本編集要素や個別第三者権利は未解決なので条件付き。全credit・source URLを保持する。過去に取得したXHTML bytesは同一原著作物の代替表現であり、独立familyや別recipeとして重複計上しない。familyは原著作者＋原作品、ただし共通配布元・制作pipeline・Shift_JIS表現の相関を残し、この3作品だけからsource-family独立性やカテゴリ全体への一般化を主張しない。旧候補No.773『こころ』・No.127『羅生門』・No.456『銀河鉄道の夜』は検索結果snippetとの対応不確実により撤回済みで、再使用しない。 |
| JSON/log | [ESLint v9.0.0 `package.json`](https://github.com/eslint/eslint/blob/e0cbc50179adac1670f4e0bd9093387a51f4f42a/package.json)（commit `e0cbc50179adac1670f4e0bd9093387a51f4f42a`、5,659 B、Git blob SHA-1 `356bfbbc8c14ac7c853d63c6bd8d52933c193671`、[MIT license](https://github.com/eslint/eslint/blob/e0cbc50179adac1670f4e0bd9093387a51f4f42a/LICENSE)）、[Prettier v3.3.3 `package.json`](https://github.com/prettier/prettier/blob/52829385bcc4d785e58ae2602c0b098a643523c9/package.json)（commit `52829385bcc4d785e58ae2602c0b098a643523c9`、6,813 B、Git blob SHA-1 `89d3f495231a758e6f6b8952583829667ced40c9`、[MIT license](https://github.com/prettier/prettier/blob/52829385bcc4d785e58ae2602c0b098a643523c9/LICENSE)）、[Unicode CLDR JSON 45.0.0 `weekData.json`](https://github.com/unicode-org/cldr-json/blob/42d06bf369c1250447968ab070ba1c9d7ddf4282/cldr-json/cldr-core/supplemental/weekData.json)（commit `42d06bf369c1250447968ab070ba1c9d7ddf4282`、11,204 B、Git blob SHA-1 `3af8b154d2421f4dbfeb9a9d5c332ca6dd980555`、[package-level Unicode License V3](https://github.com/unicode-org/cldr-json/blob/42d06bf369c1250447968ab070ba1c9d7ddf4282/cldr-json/cldr-core/LICENSE)）。これらはGit metadataであり、取得物SHA-256ではない。ESLint licenseはOpenJS Foundation等、Prettier licenseはJames Long and contributorsのMIT許諾で、各copyright/permission表示を保持する。CLDRのcore LICENSE（Copyright © 2004–2024 Unicode, Inc.）はData Filesを明示的に対象とし、copyright/permission noticeを全copyまたは関連文書へ載せることを認め、権利者名による広告・推奨表現には事前許可を求める。これは固定packageの公式license文面に基づく適用判断で、未閲覧JSON payload内の例外・第三者noticeまでは確認していない。3 familyは異なるproject由来だが、ESLintとPrettierは同じnpm manifest構造なので、この相関を含む限定的なcategoryとして扱う。SchemaStoreはApache-2.0とNOTICEを確認できた一方、寄稿metadataの例外scopeを本文非閲覧の境界内で解消できず、3 familyの数には含めない保留候補とする。 |
| source code | [Caddy v2.8.4](https://github.com/caddyserver/caddy/releases/tag/v2.8.4)の`caddy.go`（32,087 B、commit `7088605cc11c52c2777ab613dfc5c2a9816006e4`、Git blob SHA-1 `27acabb1267af98e1684268c988bef678f62ebff`、[Apache-2.0](https://raw.githubusercontent.com/caddyserver/caddy/v2.8.4/LICENSE)）、[DuckDB v1.1.3](https://github.com/duckdb/duckdb/releases/tag/v1.1.3)の`src/main/database.cpp`（16,308 B、commit `19864453f7d0ed095256d848b46e7b8630989bac`、blob SHA-1 `0a82e4598eab560df00d57d927d6d6a6990168ef`、[MIT](https://raw.githubusercontent.com/duckdb/duckdb/v1.1.3/LICENSE)）、[Tree-sitter v0.24.7](https://github.com/tree-sitter/tree-sitter/releases/tag/v0.24.7)の`lib/src/parser.c`（74,236 B、commit `5e8760bf462ce7b19b3d2396d5b7860f3906a297`、blob SHA-1 `5fccc2ecc46b991f820ce1621a9e006e956b936d`、[MIT](https://raw.githubusercontent.com/tree-sitter/tree-sitter/v0.24.7/LICENSE)）。各候補はこの単一memberだけを固定byte順で選び、archive/vendor/fixtureは混ぜない。 |
| executable binary | [ripgrep 14.1.1](https://github.com/BurntSushi/ripgrep/releases/tag/14.1.1)の`ripgrep-14.1.1-x86_64-pc-windows-msvc.zip`（release metadata 2,058,893 B、[固定版workflow](https://raw.githubusercontent.com/BurntSushi/ripgrep/14.1.1/.github/workflows/release.yml)で選択member `ripgrep-14.1.1-x86_64-pc-windows-msvc/rg.exe`を同定）、[jq 1.7.1](https://github.com/jqlang/jq/releases/tag/jq-1.7.1)のstandalone `jq-windows-amd64.exe`（985,088 B、[固定版Windows workflow](https://raw.githubusercontent.com/jqlang/jq/jq-1.7.1/.github/workflows/ci.yml)でUCRT64／builtin static Onigurumaを確認）、[age v1.2.0](https://github.com/FiloSottile/age/releases/tag/v1.2.0)の`age-v1.2.0-windows-amd64.zip`（release metadata 5,192,969 B、[固定版workflow](https://raw.githubusercontent.com/FiloSottile/age/v1.2.0/.github/workflows/build.yml)でCGO無効・選択member `age/age.exe`を同定）をsource artifact候補とする。release metadataの全体sizeと選択exeの実sizeは区別する。ripgrepはMIT/Unlicense選択式でPCRE2をstatic link、jqはMITに加えてLucent・decNumber／ICUとOniguruma等、ageはBSD-3-ClauseとGo dependency noticeを保持する。memberはworkflowから特定したが、実配布payload／SHA-256／同梱notice全体は未取得・未検証で、3件とも暫定候補に留める。 |
| structured tabular data | [UCI Bike Sharing ID 275](https://archive.ics.uci.edu/dataset/275/bike+sharing+dataset)、[Steel Plates Faults ID 198](https://archive.ics.uci.edu/dataset/198/steel+plates+faults)、[UCI Abalone ID 1](https://archive.ics.uci.edu/dataset/1/abalone)。2026-10-16に公式page metadataを再確認。候補入力は配布ZIP内の元member `hour.csv`、`Faults.NNA`、`abalone.data` の全bytesを無変換で使う。公式ページのrounded sizeはそれぞれBike `hour.csv` 1.1 MB／全体17,389 instances（この件数をhour.csv単独の行数とは扱わない）、Steel `Faults.NNA` 292.5 KB／1,941 instances、Abalone `abalone.data` 187.4 KB／4,177 instances。取得した公式ZIPと選定memberの実測length／SHA-256は、Bike 279,992 B／`b70182d0d0508e9abbb79306ce5c0cec34869000f8220175ac83d11dbe845401`・`hour.csv` 1,156,736 B／`e03de4ee4ef4dc376ac6e04bf829673c6269e8eba5c60fa121640fa2f829504f`、Steel 100,890 B／`cb8eb9859198b63f053e443513036b401746fa517ef58bd17c846c6741c93919`・`Faults.NNA` 299,482 B／`08994f5b0185a8e6cc22afe9910fd36834990fb1ca30852ed79012a832fbff55`、Abalone 55,357 B／`755a6a67c5b266961a3f149ea13be2cfb6e6c727e48cee3c83bc0b4526210ee4`・`abalone.data` 191,873 B／`de37cdcdcaaa50c309d514f248f7c2302a5f1f88c168905eba23fe2fbc78449f`。ZIP central directoryで選定memberが各1件だけあることと、行数／field-countはBike 17,379×17（header含む17,380行）、Steel 1,941×34、Abalone 4,177×9を確認した。候補memberはhash・行/列構造確認のためbytesを読み取ったが、値を表示・変換・圧縮していない。Bike ZIPの`Readme.txt`（5,607 B）はpublication citationを求めるLicense節を含む。他ZIPに`LICENSE`／`NOTICE`名のentryはなく、Steel `Faults27x7_var`とAbalone `Index`／`abalone.names`にはlicense等のkeyword一致なし。これはsidecarの限定確認であり、条件根拠は各dataset pageの[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode.en)と、適切なcredit/citationを保持する前提とする。BikeはFanaee-T、Steel PlatesはBuscema／Terzi／Tastle、AbaloneはNash／Sellers／Talbot／Cawthorn／Fordの別dataset familyとして扱うが、UCI共通配布元だけを独立性の根拠にはしない。 |
| similar-version release-artifact pairs | [XZ Utils 5.6.3](https://github.com/tukaani-project/xz/releases/tag/v5.6.3)／[5.6.4](https://github.com/tukaani-project/xz/releases/tag/v5.6.4)の`xz-5.6.3.tar.xz`（1,328,224 B）／`xz-5.6.4.tar.xz`（1,340,516 B）、[libarchive 3.7.6](https://github.com/libarchive/libarchive/releases/tag/v3.7.6)／[3.7.7](https://github.com/libarchive/libarchive/releases/tag/v3.7.7)の`libarchive-3.7.6.tar.xz`（5,458,552 B）／`libarchive-3.7.7.tar.xz`（5,480,580 B）、[SQLite tools 3.46.0/3.46.1](https://sqlite.org/chronology.html)の[`sqlite-tools-win-x64-3460000.zip`](https://sqlite.org/2024/sqlite-tools-win-x64-3460000.zip)（5,035,461 B）／[`sqlite-tools-win-x64-3460100.zip`](https://sqlite.org/2024/sqlite-tools-win-x64-3460100.zip)（5,036,925 B）。各version pairの公式release artifact全bytesを一つのfamily caseにし、archive memberを選択・展開しない案。SQLite pairはZIP categoryと同じcontainer形式、XZ/libarchiveは既圧縮のtar.xzなので、その構造相関を残して独立一般データへ結論を拡張しない。これは実行ファイルpairでも未圧縮データの類似性評価でもない。6件すべての固定rawを2026-10-16に取得し、実byte数・SHA-256を下記に記録した。container内告知の完全確認は未了。SQLiteは他categoryで再使用しない。 |
| PNG | [Twemoji v14.0.2](https://github.com/twitter/twemoji/tree/7a3dad4a4da30497093dab22eafba135f02308e1)から`assets/72x72/1f60[0-9a-f].png` 16件（13,978 B、[graphics CC BY 4.0](https://github.com/twitter/twemoji/blob/7a3dad4a4da30497093dab22eafba135f02308e1/LICENSE-GRAPHICS)）、[OpenMoji 15.0.0](https://github.com/hfg-gmuend/openmoji/tree/13942cdd65134df8899ed5df62ccf47b36d643d7)から`color/72x72/1F60[0-9A-F].png` 16件（30,901 B、[CC BY-SA 4.0 and attribution](https://raw.githubusercontent.com/hfg-gmuend/openmoji/13942cdd65134df8899ed5df62ccf47b36d643d7/README.md)、[LICENSE.txt](https://raw.githubusercontent.com/hfg-gmuend/openmoji/13942cdd65134df8899ed5df62ccf47b36d643d7/LICENSE.txt)）、[Microsoft Fluent Emoji](https://github.com/microsoft/fluentui-emoji/tree/1ffb34c752ecf5d402f04cfb4b392c77f57c54bc)から各`assets/<directory>/3D/<directoryを小文字化し空白を_へ置換>_3d.png`の16件（metadata 671,129 B、[固定commitのroot MIT LICENSE](https://github.com/microsoft/fluentui-emoji/blob/1ffb34c752ecf5d402f04cfb4b392c77f57c54bc/LICENSE)）。各`metadata.json`の`unicode`はU+1F600–U+1F60Fと一対一。計48件／716,008 B。同codepointの統制セットであり、48件の独立した一般PNG標本ではない。2026-10-16に固定URLから取得し、実byte長・Git blob SHA-1・PNG署名・保存後SHA-256を照合した。画像の表示・寸法確認・変換・圧縮は未実施。Twemoji/OpenMojiのcopyright・license・attribution・変更表示を保持し、OpenMoji翻案の再配布にはShareAlike条件を適用。FluentのMITはroot LICENSEに基づく暫定候補評価で、個別画像の独立宣言とは区別し、Microsoft copyright・許諾文を保持する。source familyは3 projectだが共通題材・制作系列で相関するためPNG一般へ結論を拡張しない。Kenney Pixel Platformerは固定archive/member単位のrights/metadata未確定のため外す。 |
| JPEG | [The Met object 436535](https://collectionapi.metmuseum.org/public/collection/v1/objects/436535)（Van Gogh《Wheat Field with Cypresses》、個別`isPublicDomain=true`、[固定JPEG](https://images.metmuseum.org/CRDImages/ep/original/DP-42549-001.jpg)）、[Cleveland object 94979](https://openaccess-api.clevelandart.org/api/artworks/94979)（Copley《Nathaniel Hurd》、`share_license_status=CC0`、[固定JPEG](https://openaccess-cdn.clevelandart.org/1915.534/1915.534_web.jpg)）、[Getty object 103RJM](https://www.getty.edu/art/collection/object/103RJM)（Manet《The Rue Mosnier with Flags》、個別JSON-LD画像license=CC0、[固定JPEG](https://media.getty.edu/iiif/image/a0699238-b5fb-49c1-80d3-c66bba7e150d/full/!300,300/0/default.jpg)）。作者・作品・画像提供機関が異なる3候補だが、全て美術作品のデジタル撮影画像なので、一般画像への結論は拡張しない。3 URLはいずれもHEAD 200・`image/jpeg`。MetとClevelandのHEAD応答長は8,291,194 Bおよび405,819 B（Cleveland API記載の402,404 Bとは不一致）。Getty HEADに長さなし。2026-10-16に固定JPEGを3件取得し、実byte数とSHA-256を下記に記録した。未閲覧・未変換・未圧縮で、manifestは未確定。 |
| ZIP | [attrs 23.2.0 wheel](https://pypi.org/project/attrs/23.2.0/) `attrs-23.2.0-py3-none-any.whl` 60,752 B（公式SHA-256 `99b87a485a5820b23b879f04c2305b44b951b502fd64be915879d77a7e8fc6f1`、[MIT](https://github.com/python-attrs/attrs/blob/23.2.0/LICENSE)）、[JUnit Jupiter API 5.10.2](https://repo.maven.apache.org/maven2/org/junit/jupiter/junit-jupiter-api/5.10.2/) `junit-jupiter-api-5.10.2.jar` 210,956 B（sidecar SHA-256 `afff77c186cd317275803872fa5133aa801fd6ac40bd91c78a6cf8009b4b17cc`、[EPL-2.0](https://github.com/junit-team/junit5/blob/r5.10.2/LICENSE.md)）、[Newtonsoft.Json 13.0.3](https://www.nuget.org/packages/Newtonsoft.Json/13.0.3) `newtonsoft.json.13.0.3.nupkg` 2,441,966 B（[NuGet catalog entry](https://api.nuget.org/v3/catalog0/data/2023.03.08.07.46.17/newtonsoft.json.13.0.3.json) SHA-512 `mbJSvHfRxfX3tR/U6n1WU+mWHXswYc+SB/hkOpx8yZZe68hNZGfymJu0cjsaJEkVzCMqePiU6LdIyogqfIn7kg==`、[MIT](https://github.com/JamesNK/Newtonsoft.Json/blob/13.0.3/LICENSE.md)）。2026-10-16に3つのfixed package全bytesを取得し、local sizeと公式digestを照合した（詳細は下記）。ZIP系container間の相関を保ち、内部notice scopeとmanifestは未確定。 |
| ZIP — overflow only (not counted toward the three-family target) | Japan Post [UTF-8 postal data](https://www.post.japanpost.jp/service/search/zipcode/download/utf-zip.html) whole artifact `utf_ken_all.zip` (official page shows 2.04 MB); use the full ZIP bytes as an already-compressed input and do not select/extract a CSV member. The [official README](https://www.post.japanpost.jp/service/search/zipcode/download/utf-readme.html) disclaims copyright only for postal-code data and allows free distribution; it does not explicitly discuss the wrapper as a separate work. The latest-download URL is mutable, no immutable snapshot/hash is pinned, and no payload was acquired; not admitted to the holdout manifest. See the dated Japanese-source metadata audit below. |
| tiny | [fmt 10.2.1](https://github.com/fmtlib/fmt/tree/e69e5f977d458f2650bb346dadf2ad30c5320281)、[Catch2 v3.5.4](https://github.com/catchorg/Catch2/tree/b5373dadca40b7edc8570cf9470b9b1cb1934d40)、[libuv v1.48.0](https://github.com/libuv/libuv/tree/e9f29cb984231524e3931aa0ae2c5dae1a32884e)のroot `CMakeLists.txt`を全bytes・各1 caseとする。固定commitから取得したofficial raw fileは、fmt 16,673 B／SHA-256 `17b1dace7784dce06b97942af57a1ed385a58c0a3d8008e4219b1a957bbbcd37`（[raw file](https://raw.githubusercontent.com/fmtlib/fmt/e69e5f977d458f2650bb346dadf2ad30c5320281/CMakeLists.txt)）、Catch2 7,069 B／`10cd5b31c744a4e863c1ae0da5ab952f34c81a624d78b2f5c68025d63609e4c5`（[raw file](https://raw.githubusercontent.com/catchorg/Catch2/b5373dadca40b7edc8570cf9470b9b1cb1934d40/CMakeLists.txt)）、libuv 27,792 B／`65c532b75bf4e49dece79fe27ee4d8c30598c7ad2ffec7ce186c9d9316855b74`（[raw file](https://raw.githubusercontent.com/libuv/libuv/e9f29cb984231524e3931aa0ae2c5dae1a32884e/CMakeLists.txt)）。各版の[MIT＋object-code exception](https://github.com/fmtlib/fmt/blob/10.2.1/LICENSE)、[BSL-1.0](https://github.com/catchorg/Catch2/blob/v3.5.4/LICENSE.txt)、[MITおよび追加通知](https://github.com/libuv/libuv/blob/v1.48.0/LICENSE)に基づく暫定候補で、libuv `LICENSE-extra`も保持対象とする。 |
| fixed-seed random | [xoshiro256** 1.0 reference C](https://prng.di.unimi.it/xoshiro256starstar.c)（David Blackman／Sebastiano Vigna、2018、file headerにpublic-domain dedicationあり）、[Boost.Random 1.85.0](https://www.boost.org/doc/libs/1_85_0/doc/html/boost_random.html)の`boost::random::mt19937`、[Random123 v1.14.0](https://github.com/DEShawResearch/random123/releases/tag/v1.14.0)の`Philox4x32_R<10>`を各1 familyとする。提案recipeは各1,048,576 Bで、seed/key/counter・word順序を固定する（詳細は下記）。 |
| encrypted data | plaintextは[Kubernetes v1.30.0](https://github.com/kubernetes/kubernetes/releases/tag/v1.30.0)の`pkg/controller/deployment/deployment_controller.go`（24,654 B、commit `7c48c2bd72b9bf5c44d21d7338cc7bea77d0ad2a`、Git blob SHA-1 `a266bed2c85842c447f1f51e6ef721010296e8c2`、[Apache-2.0](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.30.0/LICENSE)）、[TypeScript v5.5.4](https://github.com/microsoft/TypeScript/releases/tag/v5.5.4)の`src/compiler/checker.ts`（3,027,281 B、commit `c8a7d589e647e19c94150d9892909f3aa93e48eb`、blob SHA-1 `c5cd771cfff19bdc10192291cd38f92aad52c283`、[Apache-2.0](https://raw.githubusercontent.com/microsoft/TypeScript/v5.5.4/LICENSE.txt)）、[Bitcoin Core v27.0](https://github.com/bitcoin/bitcoin/releases/tag/v27.0)の`src/validation.cpp`（296,410 B、commit `d82283950f5ff3b2116e705f931c6e89e5fdd0be`、blob SHA-1 `f8e1de55e9bd3f28cdbd85b65a0aa9f477708a0a`、[MIT](https://raw.githubusercontent.com/bitcoin/bitcoin/v27.0/COPYING)）。各source familyを別caseにし、他categoryと共有しない。 |

実行binary候補のversionとrelease artifact sizeに加え、ripgrep／ageのZIP内memberも各版の公式workflowから特定し、jqは直接配布exeと確認した。ただしこれらは実payload・個別exe SHA-256・実配布物への依存notice収録を検証した証拠ではない。ripgrepのworkflowはPCRE2 static buildと本体license類のpackagingを示すが、PCRE2を含む依存notice全体の収録は確定しない。jqの[固定版 `COPYING`](https://raw.githubusercontent.com/jqlang/jq/jq-1.7.1/COPYING)は本体・Lucent由来部分・decNumber／ICU等を記載し、[Onigurumaのpinned source COPYING](https://raw.githubusercontent.com/kkos/oniguruma/d2f1a14ced5d5d461acac0da0d477ab240a7ab5f/COPYING)でも通知条件を確認したが、実binaryに対する完全なnotice範囲は未解決。age workflowは`age/LICENSE`へage自身とGoのLICENSEを連結し、CGOを無効にするが、Go toolchainは`1.x`指定で、全依存・runtime通知との対応は未確認。similar-version群は実行binaryではなく公式release artifact全体を候補とする。XZの[5.6.4 `COPYING`](https://raw.githubusercontent.com/tukaani-project/xz/v5.6.4/COPYING)は複数licenseを含み、libarchiveの[3.7.7 `COPYING`](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.7/COPYING)はfile単位の条件・noticeを要する。SQLiteの[著作権説明](https://sqlite.org/copyright.html)はSQLite code一般のpublic-domain statusを説明するが、未閲覧のtools ZIP全体に含まれるnoticeの完全性までは確定しない。いずれも配布物内告知・hashの確認前は暫定候補であり、実行file間の類似性や未圧縮データ一般へ結論を拡張しない。

2026-10-16のmetadata-only executable監査では、GitHub固定tag/commitとasset IDをripgrep `14.1.1` (`4649aa9700619f94cf9c66876e9549d83420e16c`, asset `191354245`)、jq `jq-1.7.1` (`71c2ab509a8628dbbad4bc7b3f98a64aa90d3297`, asset `140521015`)、age `v1.2.0` (`bbe6ce5eeb1bb70cfc705d0961c943f0dd637ffd`, asset `174116357`)で固定した。公式[release metadata](https://api.github.com/repos/BurntSushi/ripgrep/releases/tags/14.1.1)、[jq release metadata](https://api.github.com/repos/jqlang/jq/releases/tags/jq-1.7.1)、[age release metadata](https://api.github.com/repos/FiloSottile/age/releases/tags/v1.2.0)のasset URL・公表全体サイズは上表の候補と一致し、APIの`digest`はいずれもnullだった。別publisher sidecarはripgrep ZIP SHA-256 `d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1`（[`.sha256`](https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-pc-windows-msvc.zip.sha256)）、jq EXE SHA-256 `7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab`（[固定版checksum manifest](https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt)）を掲載するが、いずれもpublisherの値でありlocal payload hashではない。jqの[detached signature file](https://github.com/jqlang/jq/blob/master/sig/v1.7.1/jq-windows-amd64.exe.asc)は存在するが検証未実施。age APIの同名`.proof`資産digestはproof自身のhashでありZIPのhashではないため、署名/proofの存在と検証成功を区別する。workflowから示されたripgrep `rg.exe`・age `age.exe`のmember pathとbuild設定は期待値で、配布ZIPのmember size/contentを見た結果ではない。ripgrep PCRE2/Rust依存、jq Oniguruma/静的runtime、age Go module/runtimeのnotice網羅性も未確認のため3件を暫定のまま維持する。対応するPlumivox全体検索はripgrep 1件・jq 1件・age 0件、すべて`completeSearch=false`で、非網羅かつ候補payload内容の裏付けではない。

source-code 3候補は固定tag・commit・member path・Git blob SHA-1・metadata sizeとproject-level licenseを照合した。Caddyのroot `LICENSE`はApache-2.0、DuckDBはMIT（root NOTICEなし。ただしthird_party以下は別license/noticeを持つ）、Tree-sitterはMIT（`lib/src/unicode/LICENSE`は別扱いで、選定pathとは別）。その後、2026-10-16に固定rawを取得し、実byte数と既記録のGit blob SHA-1が一致することを照合した。SHA-256はCaddy `caddy.go`（32,087 B）=`1de36cdff6eb662db001ddc430e10013a693455172ac9022aca12c65fe6d80fb`、DuckDB `database.cpp`（16,308 B）=`a5c5fb6f09226c3baca99a4dea35d2745a60d6ae08f797aabb27fc892df77f83`、Tree-sitter `parser.c`（74,236 B）=`5820d1cdfabb5316a3c7727acfaee4df590b84e51de1d3d291a6c536a12f51e7`。限定的なfile-level表示確認では、Caddyの1–13行に2015年の著作権表示とApache-2.0 headerがあり、SPDX・生成物・第三者ライセンス表示は検出されなかった。DuckDB／Tree-sitterの選定fileには先頭headerがなく、本文の限定語句scanでもSPDX・copyright・license・第三者告知・generated表示は検出されなかった。これは全ての権利者・第三者fragment・NOTICE適用範囲の確認ではなく、project-level licenseだけから各memberの完全な権利状態を断言しない。固定rawはTempの`Codex/UnLhaRe/01a0b076-4e26-7a71-ac35-32ed9259a871/source-code-review/`に3 fileだけ保持し、圧縮・計測・実行はしていない。source-codeは暫定候補のまま、全holdout manifestは未凍結である。

ZIP候補はfixed raw全体を取得・hash確認済み。2026-10-16に権利名を持つentryだけを確認したが、通常memberは未展開・未閲覧で、JUnit noticeの下位component条件が残るためrights scope未確定である。詳細は後述する。tiny候補は固定tagのroot `CMakeLists.txt`全bytesを取得してサイズ・SHA-256を照合済み。限定file-level scanではfmt/Catch2にcopyright/license/SPDX headerが見つからず、libuvにはLICENSE類のinstall指定があるが、これは全権利者・第三者provenanceの確認ではない。両categoryとも候補のままで、family prior-use auditと全体manifest凍結は未完了。

2026-10-16の追加metadata-only ZIP監査では、[PyPI attrs 23.2.0 metadata](https://pypi.org/pypi/attrs/23.2.0/json)のwheel URLと60,752 B、固定[MIT LICENSE](https://raw.githubusercontent.com/python-attrs/attrs/23.2.0/LICENSE)を確認した。attrs metadataのdependency宣言はwheel内同梱を意味しない。[JUnit 5.10.2 official Maven directory](https://repo.maven.apache.org/maven2/org/junit/jupiter/junit-jupiter-api/5.10.2/)は`junit-jupiter-api-5.10.2.jar` 210,956 Bを示し、固定[EPL-2.0 LICENSE](https://raw.githubusercontent.com/junit-team/junit5/r5.10.2/LICENSE.md)と[LICENSE-notice](https://raw.githubusercontent.com/junit-team/junit5/r5.10.2/LICENSE-notice.md)はsubcomponentごとに別notice/licenseがあり得ると明記する。固定[POM](https://repo.maven.apache.org/maven2/org/junit/jupiter/junit-jupiter-api/5.10.2/junit-jupiter-api-5.10.2.pom)はOpenTest4J 1.3.0、JUnit Platform Commons 1.10.2、API Guardian 1.1.2を依存指定するが、JAR内収録の証拠ではない。[Newtonsoft.Json 13.0.3固定catalog](https://api.nuget.org/v3/catalog0/data/2023.03.08.07.46.17/newtonsoft.json.13.0.3.json)と[registration metadata](https://api.nuget.org/v3/registration5-gz-semver2/newtonsoft.json/13.0.3.json)はNUPKG artifactを特定し、固定[MIT LICENSE](https://raw.githubusercontent.com/JamesNK/Newtonsoft.Json/13.0.3/LICENSE.md)はcopyright・permission noticeの保持を条件とする。catalogのtarget-framework dependenciesもpackage memberへの同梱を確定しない。2026-10-16にofficial fixed endpointからwheel／JAR／NUPKGの実artifactを取得し、各sizeは60752／210956／2441966 Bでmetadataと一致した。SHA-256はattrs `99b87a485a5820b23b879f04c2305b44b951b502fd64be915879d77a7e8fc6f1`、JUnit `afff77c186cd317275803872fa5133aa801fd6ac40bd91c78a6cf8009b4b17cc`、Newtonsoft `872fc189e638ab1056555b03aaa38f68bcb54286e221aa646eb1129babf63c77`。attrs PyPI hashとJUnit `.sha256` sidecarは一致し、Newtonsoftのlocal SHA-512をNuGet catalogのbase64 hashと照合した結果も一致した。3件とも先頭4 bytesはZIP local-file signature `50 4B 03 04`。containerを展開していないため内部notice scopeは未確認。異なるproject/ecosystemなので3 source family候補として維持できる一方、すべてZIP系containerでSQLite release ZIP等と形式上相関する。先行利用・family auditとmanifestは未完了である。対応するPlumivox公開検索`attrs JUnit Newtonsoft license package`は0件だが非網羅であり、不在の根拠ではない。

fixed-seed randomのrecipeは全件1,048,576 B、header・skip・分布変換・再seed・改行なしとする。xoshiro256** 1.0の初期stateは、UTF-8 BOMなし・改行なしの文字列`UnLhaRe fixed-seed random xoshiro256starstar v1`のSHA-256 `29ae318956413258d0532e418504dbdff85fc5c3e5b56bbdafe59278cb8f241f`をlittle-endian 64-bit word 4個へ分割した`{0x583241568931ae29, 0xdfdb0485412e53d0, 0xbd6bb5e5c3c55ff8, 0x1f248fcb7892e5af}`とする（全word非zero）。`next()`を131,072回呼び、各64-bit返値をlittle-endian出力する。xoshiroのSplitMix64 initializerは用いない。Boost `mt19937`はseed 5489から262,144個の32-bit outputを同じ順序で出力する。Random123 `Philox4x32_R<10>`はkey words `{0x243f6a88,0x85a308d3}`、counter `{i,0,0,0}`（`i=0..65535`）を使い、返値word 0→3をlittle-endian化する。2026-10-16に保持先`%LOCALAPPDATA%/Codex/TaskArtifacts/UnLhaRe/01a0b076-4e26-7a71-ac35-32ed9259a871/random-candidate-inputs-20261016/`へ再現script・manifest・3出力を作成した。3出力はいずれも1,048,576 Bで、SHA-256はxoshiro256**=`616f7e9cf690b990d52705ae9315e176ebe9de3a4f6323ea37958f08e8523d15`、Boost `mt19937`=`28a048ff4a1e702df4dd3a8d3a9cbb4c19932cada4e340a6a5bcd28916c2985a`、Philox4x32=`e6a3454b0c69c5486593a27fc2ac01e5a45a1d3ed84e31e1ef933b9657dcac1e`。generator起動時のKATはxoshiro state `{1,2,3,4}`→`0x2D00`、MT19937 seed 5489の先頭3値、Philox zero key/counterの既知4値を検査する。独立したPowerShellプロセスで`generate-inputs.ps1 -Verify`を再実行し、各出力の再生成SHA-256・長さとmanifest記録の一致を確認した。圧縮・展開・benchmarkには未使用。scriptとmanifestにsource URL・generation recipeを保持する。xoshiro reference Cは暗号用途向けではなく、source codeのpublic-domain dedicationは生成outputの権利を自動確定しない。Boost.RandomはBSL-1.0、Random123はBSD-3-Clause型のproject-level termsだが、generator licenseを生成outputへ自動適用も免除もしない。generatorを配布する場合のnoticeと生成dataの権利判断は分け、output rightsは未解決のままとする。2026-10-16の`xoshiro256 license public domain` X全体検索は0件・`completeSearch=false`で、投稿不存在の根拠にはしない。

encrypted-dataの提案recipeは[OpenSSL 3.5.0](https://github.com/openssl/openssl/releases/tag/openssl-3.5.0)の`enc -chacha20 -e -nosalt -K <key-hex> -iv <iv-hex> -in <plaintext> -out <ciphertext>`。per-family keyを`SHA-256(UTF-8("UnLhaRe holdout v1|chacha20|key|<family-id>"))`、IVを`SHA-256(UTF-8("UnLhaRe holdout v1|chacha20|iv|<family-id>"))`の先頭16 bytesとする案で、family-idは`kubernetes-v1.30.0`、`typescript-v5.5.4`、`bitcoin-core-v27.0`へ固定する。OpenSSL raw ChaCha20ではこの16-byte IVを先頭8 bytesのlittle-endian初期counterと後半8 bytesのnonceとして解釈し、処理中に64-bit counterがwrapする長さを拒否する。公式[enc manual](https://docs.openssl.org/3.5/man1/openssl-enc/)[^19]は`-K`と`-iv`のhex指定および`chacha20`を示すが、現環境では`Get-Command openssl.exe`でCLIをPATH解決できず、追加導入もしていないため、Windows executable・provider・設定の版/hash、実行前のrights、recipe実装・round-tripは未確認でciphertextも生成していない。暗号化後も元sourceのlicense/copyrightを保持する。Kubernetesはroot NOTICEなしだがvendor・第三者部分は別扱い、Bitcoinはroot NOTICEなしだがthird-party部分は別扱い。TypeScriptにはroot `ThirdPartyNoticeText.txt`があり、選定memberへの適用範囲が未解決。全member本文・headerを未閲覧のため、3件とも暫定候補とする。

JPEG候補の個別館metadataは、Met `isPublicDomain=true`、Cleveland `share_license_status=CC0`、Getty image JSON-LD `license=CC0`と各固定JPEG URLの一致を示す。これらは館側が表示する画像状態であり、各館の[Met利用条件](https://www.metmuseum.org/policies/terms-and-conditions)、[Cleveland利用規約](https://www.clevelandart.org/terms-and-conditions)、[Getty Open Content FAQ](https://www.getty.edu/projects/open-content-program/faqs/)はいずれも第三者権利を包括保証しない。対象metadataに固有の第三者権利者は見つからなかったが、これを権利連鎖の完全確認とは扱わない。GettyはCC0とは別に出所creditを要請するため保持する。固定URLのraw JPEGを2026-10-16に取得したが、館側のstatementを超える権利保証や、第三者権利の不存在は主張しない。候補familyは未凍結である。

旧日本語候補の中間調査記録（以下3作品は検索結果snippetとの対応が不確実なため撤回済み。現行候補は上表のNo.301・424・752）：当時は青空文庫の図書カードが示す全XHTMLをそのまま使う案として、『こころ』`773_14560.html` 618,230 byte（No.773）、『羅生門』`127_15260.html` 21,933 byte（No.127）、『銀河鉄道の夜』`456_15050.html` 124,623 byte（No.456）を確認した。各カードは日本語原著者と没年（夏目漱石1916-12-09、芥川龍之介1927-07-24、宮沢賢治1933-09-21）を記載している。文化庁の[保護期間延長Q&A](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)によれば旧来の原則は死後50年で、期間は死亡年の翌年から数え、2018-12-30より前に消滅した著作権は延長時に復活しない。この基準を適用すると3作品はそれぞれ1966、1977、1983年末までに保護期間が満了している。青空文庫の[取扱規準](https://www.aozora.gr.jp/guide/kijyunn.html)は著作権の切れた作品ファイルの複製・再配布・形式変換を許し、作品・著者・底本・入力校正等の由来情報を残すよう希望する。候補本文は未取得・未閲覧で、最終の長さ・SHA-256と告知同梱manifestは未固定。各作品の著者を別familyとする根拠は独立した原著作者であり、青空文庫という共通配布元自体を独立性の根拠にはしない。デジタル庁・文科省PDFは個別の第三者権利が未解決のため候補から外す。

旧prose候補の中間調査記録（以下3文書は選定pathと検索snippetの対応が不明で撤回済み。現行候補は上表のProject Gutenberg作品）：当時は別projectの3文書を各々全bytes・無変換で使う案として、`golang/go` commit `15da892a4950a4caac987ee72c632436329f62d5`の[`doc/go_mem.html`](https://raw.githubusercontent.com/golang/go/15da892a4950a4caac987ee72c632436329f62d5/doc/go_mem.html)は13,565 byte、blob SHA-1 `5f1eb68af395bfad9ee1550662f89a5cd4707c57`で、同commitのroot [BSD-3-Clause license](https://raw.githubusercontent.com/golang/go/15da892a4950a4caac987ee72c632436329f62d5/LICENSE)を保持する。`JuliaLang/julia` commit `48d4fd48430af58502699fdf3504b90589df3852`の[`doc/src/manual/getting-started.md`](https://raw.githubusercontent.com/JuliaLang/julia/48d4fd48430af58502699fdf3504b90589df3852/doc/src/manual/getting-started.md)は3,026 byte、blob SHA-1 `e972788022de6124247936f92308247a2f001d88`で、同commitのroot [MIT license](https://raw.githubusercontent.com/JuliaLang/julia/48d4fd48430af58502699fdf3504b90589df3852/LICENSE.md)がassociated documentationを含む。`rust-lang/book` commit `844ddcd4d6d7726143ed8165950e395ccfd1f155`の[`src/foreword.md`](https://raw.githubusercontent.com/rust-lang/book/844ddcd4d6d7726143ed8165950e395ccfd1f155/src/foreword.md)は2,804 byte、blob SHA-1 `706e4ab8e4f15a81283db68a5d602819f188d3a6`で、同commitの[COPYRIGHT](https://raw.githubusercontent.com/rust-lang/book/844ddcd4d6d7726143ed8165950e395ccfd1f155/COPYRIGHT)がMITまたはApache-2.0を選択許諾し、[MIT全文](https://raw.githubusercontent.com/rust-lang/book/844ddcd4d6d7726143ed8165950e395ccfd1f155/LICENSE-MIT)はdocumentationを含む。Juliaの[THIRDPARTY.md](https://raw.githubusercontent.com/JuliaLang/julia/48d4fd48430af58502699fdf3504b90589df3852/THIRDPARTY.md)の列挙例外には選定manual pathはなく、Julia配布物全体のlicense判断には拡張しない。本文内容は3件とも未取得・未閲覧であり、取得物SHA-256・license告知付きmanifestは未固定。indexed KHC metadata/runnerの照合では選定path/projectの過去入力を検出しなかったが、未見性の証明ではない。ECB speechesとUK Hansardは個別itemの権利未解決、World Bank WDR 2024 Forewordは第三者contentの権利未解決として候補から外す。NARA FDR 1941、Obama 2013、Clinton 1997の個別演説も検索結果に本文抜粋が表示されたため未見評価候補から除外する。

2026-10-16の候補名単位のローカル既使用screenでは、SchemaStoreを除外しPrettierを加えた39のprovisional source-family名について、KHC配下の照合対象文書・JSON/TXT metadata・runnerの固定入力定義に直接一致するsourceは検出されなかった。これは記録上の一致が見つからなかったという限定的な結果であり、未見性の証明ではない。今回の追加read-only searchでは、候補selection doc以外のKHC配下に`xoshiro`はなく、`SplitMix64`は既存の計測sample選択仕様に1件だけあったため、xoshiroはそれをseed initializerとして共有しないrecipeにした。現在提案したitem/member・version・generation recipeは、固定前に候補一式を既使用family一覧と再照合し、実装ごとのbyte順・長さ・権利条件を照合してから凍結する。Boost.Randomのengine案は`boost::random::mt19937`まで絞ったが、生成は未実施。PCG Minimal C 0.9は公式archiveのlicense binding未解決により候補から外し、file単位にpublic-domain dedicationのあるxoshiro256** 1.0へ置換した。selected memberのlocal header/third-party scope、未確認のexecutable noticeも未解決である。

未凍結の追加条件：UCI Bike Sharing・Steel Plates Faults・Abaloneは、無変換member bytesの正確なpath・length・SHA-256、行数／列数を確認した。Bike Readmeのpublication citation条件も確認済み。各dataset pageのCC BY 4.0 attributionと著者citationをmanifest・最終告知へ保持する。以前の列抽出・int32配列化案はholdoutから撤回し、圧縮入力に使わない。指定した`CORPORA.md`、`BASELINE.md`、product comparison runner／verifierへの候補名／ID限定検索では一致がなかったが、未見性の証明ではない。Online Retailの22.6 MB XLSXはstreamingの追加複雑さを避けるため候補から外した。CLDR 45.0.0の対象`weekData.json`はcommit `42d06bf369c1250447968ab070ba1c9d7ddf4282`のpackage-level Unicode License V3対象fileに固定したが、payload・SHA-256・manifestは未取得・未固定。SchemaStore catalogはApache-2.0/NOTICEの存在のみでは寄稿metadataのscopeを解消できず保留し、Prettier v3.3.3の`package.json`を代替候補に置いた。Air Quality ID 360は同じ公式ページ内で研究限定・商用利用不可条件も併記されるため候補から除外した。青空文庫XHTMLとJPEG3候補は個別metadataで権利・固定URLを絞ったがpayload・SHA-256・最終manifestは未取得・未固定であり、Gettyの長さは取得時に固定する。ClevelandはAPI記載の画像長とJPEGのHEAD応答長が一致しないため、実payloadの長さ・hashを正とする。再配布assetの告知、可変APIやsource archiveの固定version・length・SHA、sample変換後SHAも未確認である。MEXT/デジタル庁PDFは第三者権利の未解決により候補外である。2026-10-16のread-only readiness監査ではUCI取得前にmanifestへ進められるfamilyを0とした。今回のUCI source/member取得・構造／hash確認後も、他caseの選定と全familyの既使用照合が未完のため、最終manifestは未凍結でありholdout compressionへ進まない。

### raw integerカテゴリの候補充足監査 — 2026-10-17

事前登録の必須categoryは`raw integer`であり、上記UCI候補は元の区切り・header・数値表記を持つstructured tabular dataである。以前の列抽出／int32配列化recipeは撤回済みのため、この3件をraw integerへ読み替えない。readiness matrixはraw integer候補が未充足と判定した。

metadata-onlyで再調査した候補の状況を更新する。[Zenodo record 15240501](https://zenodo.org/records/15240501) v1（2025-04-18, Lorenzo Bellomo）はCC BY 4.0を示す。記録説明とZenodo公式metadata APIによれば、`normal_uint32`は50,000,000個のnormal分布uint32と64-bit件数preambleを含む200,000,008 Bの固定memberである。[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)は帰属表示を条件に商用を含む再配布・改変を許すため、creditにはrecord/title/creator/DOI/licenseと変更有無を含める。前回のcapacity exclusion（2026-10-16 23:37 JST、cap234,881,024 Bで残量86,045,735 B）は新しい1GiB lifecycle capに対して再評価できる。全fileはcap内だが、現行storage preflightなしに作業容量適合とはしない。公開metadataに固定部分range recipeはないためsliceせずwhole fileのみを条件付き候補とし、同recordの別配列を独立familyに数えない。prior-use照合、取得後の正確なbytes/hash、credit実装と容量preflightは未完了であり、holdout manifestには未採用。Plumivox `scope=all`のexact query `Zenodo 15240501 normal_uint32 integer dataset license`は0件・`completeSearch=false`で非網羅的だった。NASA/JPL [SRTMGL1.003](https://lpdaac.usgs.gov/products/srtmgl1v003/)のHGTは公式guideがsigned 16-bit integer rasterと説明し、granule metadataはZIPを約1.17 MBと示すため1 familyの条件付き候補に留める。選定memberの正確なpath／size／hash、現行再利用条件（案内policyは403）、void fill等に関する第三者由来範囲は未確認であり、複数tileを別familyに数えない。[MIT-BIH Arrhythmia Database v1.0.0](https://physionet.org/content/mitdb/1.0.0/)の`100.dat`は配布metadataで約1.9 MBとされるが、ODC Attribution 1.0は個別内容の権利を確定せず、対象recordの整数格納recipeも未確認のため数えない。

その他のmetadata-only leadも採用しない。[USGS GTOPO30](https://www.usgs.gov/centers/eros/science/usgs-eros-archive-digital-elevation-global-30-arc-second-elevation-gtopo30)はpublic domain・1996年完成の条件付き候補である。2026-10-20に[USGS公式README](https://d9-wret.s3.us-west-2.amazonaws.com/assets/palladium/production/s3fs-public/atoms/files/GTOPO30_Readme.pdf)を確認し、`.DEM`はheader/trailerのないrow-major 16-bit signed integer binary raster、`.HDR`の例は`BYTEORDER M`（big-endian）・`NBITS 16`・6000×4800だった。標準tileのraw length 57,600,000 Bはこの寸法からの計算値であり、選択tileのartifact/member identity・実length・SHA-256は未確認。全33 tileは同一GTOPO30 product familyであり、tile分割を独立familyに数えない。USGS FAQは取得窓口をEarthExplorerとし無料登録が必要と案内するが、固定tileのcanonical URI・取得条件は未確認。Plumivox `scope=all` query `GTOPO30 raw integer DEM binary format USGS`（2026-09-20〜2026-10-20 JST、終了排他）は0件・`completeSearch=false`で非網羅的。GTOPO30と既存Earth DEM候補のsource overlap・KHC prior-useも未監査のため、raw-integer eligible family数には算入しない。[Canada3D](https://open.canada.ca/data/en/dataset/042f4628-94b2-40ac-9bc1-ca3ac2a27d82)のOpen Government Portal metadataは、NRCanの2001年legacy DEMでCDED 1:250,000由来、30／300 arc-secondのASCII gridと説明し、標高値の表現をmetre・MSL・NAD83とする一方、整数か浮動小数かは示さない。catalogは旧productが現行政府標準に合わない可能性も明記する。従って、整数適合・固定member URI/size・利用条件確認がなく、raw integer familyには数えない。[Copernicus DEM](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM)にはsigned 16-bit DTED形式がある一方、公式source metadataにSRTMを含むgap-fillingが記載されるため、SRTMと独立したfamilyとして数えない。追加探索で現れたGovernment of Saskatchewan FRI DTM familyは、公式catalog検索snippetがdata-domain rangeを含んだため、値を保持せず候補から除外した。原file／header／payloadの取得・閲覧・hash・変換は行わず、追加のlink閲覧を停止した。Fashion-MNIST／KMNISTも、限定検索結果に第三者adapterのcode snippetが含まれたため候補から除外し、追加追跡を停止した。いずれのsnippet・data valuesもこの記録へ転記せず、データ本体／header／payloadを取得していない。Plumivox `scope=all`の関連query（raw integer／SRTM／PhysioNet、`Canada3D elevation DEM ASCII grid integer data license Canada open data`、続いてFashion MNIST／Kuzushiji MNIST integer labels）はいずれも0件・`completeSearch=false`で非網羅的であり、source rights、独立性、未使用性の証拠にはしない。現状raw integerはZenodo `normal_uint32`の条件付き1 familyとGTOPO30の条件付き1 familyの計2候補、適格確認済み3独立familyはない。holdout manifest／compressionへ進まない。

2026-10-17の追加metadata-only候補も採用しない。JAXA [AW3D30 dataset page](https://www.eorc.jaxa.jp/ALOS/en/dataset/aw3d30/aw3d30_e)は商用・非商用を無償利用できるとする一方、利用条件への従属とアカウント登録後のdownloadを定める。[v4.1 Product Description (Edition 1, April 2024)](https://www.eorc.jaxa.jp/ALOS/en/dataset/aw3d30/data/aw3d30v4.1_product_e_1.0.pdf)はsigned 16-bit little-endian GeoTIFF integer rasterを示すが、Copernicus DEM GLO-30-F等の外部DEMもsourceとして挙げる。個別tileの固定URI・size・v4.1内部compression・byte範囲およびtile単位のsource構成が未確定で、provider名だけを根拠に独立familyとは数えない。AW3D30の[専用Terms page](https://www.eorc.jaxa.jp/ALOS/en/aw3d30/terms.htm)は一般の"Terms for Use"へ参照するが、現在のリンク先は本文を取得できず、別ページの[JAXA Research Data Terms](https://earth.jaxa.jp/en/data/policy/)（JAXA／第三者source credit・商用利用の事前通知を規定）がAW3D30へ適用されるかを確認できていない。権利条件は未確定のまま候補外とし、JAXAへの照会・登録・payload取得はしていない。非圧縮を示すmetadataは旧v3.2／v3.1仕様であり、v4.1には外挿しない。[USGS GTOPO30公式format文書](https://www.usgs.gov/media/files/gtopo30-readme)はheaderless signed 16-bit big-endian DEMを定義するが、仕様検索の返却にsample header・統計・処理式が含まれたため、そのfamilyの追跡を即時停止した。値や式は記録せず、候補から除外する。いずれもpayload／個別headerを取得・閲覧・hash・変換していない。Plumivox `scope=all` query `AW3D30 JAXA data use terms license redistribution`は0件・`completeSearch=false`で非網羅的。raw integerはZenodo `normal_uint32`の条件付き1 familyのみで、適格確認済みfamilyは0。3独立familyの条件を満たさず、holdout manifest／compressionへ進まない。

### Zenodo DSB/TPC-DS sort-key archive — 2026-10-17

本項は直前のraw-integer監査にある「Zenodo `normal_uint32`の条件付き1 familyのみ」という同日先行時点の記述を更新する。追加metadata-only候補として[Zenodo record 22141653](https://zenodo.org/records/22141653) v1（2026-08-28, Johannes Pietrzyk）を確認した。公式page／metadata APIはCC BY 4.0、単一file `tpcds_keys.tar.GZ` 389,343,497 B（記録MD5 `1bc318076c464f335405bc12f9458e9e`）を示す。説明上、DSBのmodified TPC-DS generatorから5 queryのsort keyをprojectしたcolumn-major `uint32` integer arraysで、各memberは64-byte little-endian headerに続く固定列データ、sf1全体365 MB・sf10全体3.6 GBとされる。payload、archive member listing、member本文、hash、抽出、圧縮、計測はいずれも未実施であり、具体的member名・size・URIと固定1 GiB lifecycle preflightは未確認。

Zenodo page内の作成者NOTICEは、dataset compilation/extraction/dictionary encoding/container format自体をCC BY 4.0で公開し、DSBのMIT noticeを転載した上で、TPC-DS toolkit自体は配布せずmodified generatorのjoin/projection/dictionary encoding後の派生dataのみと説明する。NOTICEが参照する[公式TPC EULA v2.2](https://www.tpc.org/tpc_documents_current_versions/txt/tpc-eula_v2.2.0.txt)はWeb取得経路でopenできず、作者のCC BY宣言だけで上流EULAとのrights scopeを独立確認したとは扱わない。したがってrights-clearedではなく条件付き候補に留める。`normal_uint32`とは異なるDSB/TPC-DS生成系だが、全query／scale-factorは同一のsource familyであり、別memberを独立familyとして数えない。候補は個別の整形式memberを一つ丸ごと使えるか、raw-integer recipeへの適合、独立性、rights、prior-useが揃ってから再評価する。local exact-text screen（hiddenを含む`*.md`／`*.json`／`*.rs`／`*.ps1`、`.git`／build／target／artifacts／node_modules／本memoを除外）でrecord／DOI／archive／format識別語のhitはなかったが、これは限定された文書screenでありpayload未使用・source family非重複の証拠ではない。Plumivox `scope=all` queries `DSB TPC-DS projected sort key uint32 dataset Zenodo license` と `TPC-DS End User License Agreement dsdgen data generator DSB CC BY` は各0件・`completeSearch=false`で非網羅的。現時点のraw-integer metadata-only条件付き候補は`normal_uint32`、SRTMGL1.003、および本archiveの3件だが、独立family／member／rightsを確定できた候補はなく、適格確認済みfamilyは0。holdout manifest未採用・candidate payload未取得。

local screenの検索語は`22141653`、`10.5281/zenodo.22141653`、`tpcds_keys`、`TSLDSET1`、`Multi-column sort keys projected`。`rg --hidden`は既定のignore規則も適用するため、明示除外path以外でもignored file／directoryは対象外となり得る。

recordのexact file size／MD5は[Zenodo metadata API](https://zenodo.org/api/records/22141653)、DSBのMIT licenseは[Microsoftの公式LICENSE](https://github.com/microsoft/dsb/blob/main/LICENSE)でも照合した。

公式TPC EULA URLへのPowerShell GETはHTTP 200だったが、応答はTPC site navigationを含むHTML（108,961 characters）で、EULA本文とは確認できなかった。本文の条項や派生dataへの適用は未確認のまま維持する。

### MGS MOLA integer-grid metadata lead — 2026-10-17

NASA PDS Geosciences Nodeの[固定product XML](https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/meg004/megt90n000cb.xml)で、MGS MOLA `megt90n000cb.img`のLID `urn:nasa:pds:mgs_mola_topography_derived:data_meg004:megt90n000cb`、product version 1.1（2026-09-15）、offset 0、`SignedMSB2`、720×1440の整数配列をmetadata-onlyで確認した。NASA PDS [Registryの固定LIDVID](https://pds.nasa.gov/api/search/1/products/urn:nasa:pds:mgs_mola_topography_derived:data_meg004:megt90n000cb::1.1)は対応するIMGの公表長2,073,600 BとMD5 `e963c832905b40c1cb8636dab43bc382`を示す。これはpublisher metadataであり、取得fileのidentityやSHA-256を検証したものではない。

権利は未解決である。確認した[product XML](https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/meg004/megt90n000cb.xml)、[collection XML](https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/meg004/collection_data_meg004.xml)、[bundle XML](https://pds-geosciences.wustl.edu/mgs/urn-nasa-pds-mgs_mola_topography_derived/mgs_mola_topography_derived_bundle.xml)およびNASA PDS [bundle page](https://pds.nasa.gov/ds-view/pds/viewBundle.jsp?identifier=urn:nasa:pds:mgs_mola_topography_derived&version=1.0)から、当該productの複製・商用benchmark向け再配布を明示的に許可する条件は確認できなかった。確認したNASA Registry collectionはversion 1.0だが、collection XMLはversion 2.0を示しており整合確認も残る。NASA一般policyからCC0等を推定せず、MOLAはmetadata-only leadに留め、raw-integer候補・適格family数・holdout manifestへ算入しない。

Plumivox `scope=all`のmatching queryは`raw integer dataset MOLA LOLA EMNIST license`（2026-09-17 00:00〜2026-10-18 00:00 JST、終了排他）で、0投稿・1 API要求・`hasNextPage=false`・`completeSearch=false`。非網羅的であり、許諾・不存在の根拠にはしない。IMG・archive・member payloadは取得／閲覧／hash／変換／圧縮していない。

### LOLA `LDEM_4` integer-grid metadata lead — 2026-10-17

NASA PDS Geosciences Nodeの[固定product XML](https://pds-geosciences.wustl.edu/lro/lro-l-lola-3-rdr-v1/lrolol_1xxx/data/lola_gdr/cylindrical/img/ldem_4.xml)で、`LDEM_4` LIDVID `urn:nasa:pds:lro_lola_rdr:data_gridded:ldem_4::1.0`、PDS4 label version 1.0、offset 0、`SignedLSB2`、720×1440のsigned 16-bit little-endian整数配列をmetadata-onlyで確認した。[PDS3 label](https://pds-geosciences.wustl.edu/lro/lro-l-lola-3-rdr-v1/lrolol_1xxx/data/lola_gdr/cylindrical/img/ldem_4.lbl)は科学製品version V3.0、作成日2017-09-15を別途示す。NASA PDS [Registryの固定LIDVID](https://pds.nasa.gov/api/search/1/products/urn:nasa:pds:lro_lola_rdr:data_gridded:ldem_4::1.0)はIMGの公表長2,073,600 BとMD5 `ffca328bcd1ce43ab419d7c403294fb5`を示す。いずれもpublisher metadataであり、取得fileのidentityやSHA-256を検証したものではない。

[NASA PDS bundle page](https://pds.nasa.gov/ds-view/pds/viewBundle.jsp?identifier=urn:nasa:pds:lro_lola_rdr&version=1.0)と[gridded collection page](https://pds.nasa.gov/ds-view/pds/viewCollection.jsp?identifier=urn:nasa:pds:lro_lola_rdr:data_gridded)でbundle／collection ID version 1.0を確認したが、product・collection・bundle・README・GDR catalogからコピー・商用benchmark向け再配布を明示的に許す条件は確認できなかった。bundle page記載のauthors Smith／NeumannはMOLA bundleのSmith／Neumannと共通し、MOLA／LOLAは作成者系列とDEM構造も近い。月面という異なる対象・missionだけで独立familyと数えず、LOLAはrights未解決かつfamily independence未確定のmetadata-only leadに留め、raw-integer eligible family数・holdout manifestへ算入しない。NASA一般policyやcitation metadataをlicenseの代用にしない。

local KHC memoの`LOLA`／`LDEM`／`LRO`照合では既使用記録を検出しなかったが、限定された文書screenであり未使用性は証明しない。Plumivox `scope=all`のmatching queryは`LOLA LDEM_4 PDS license redistribution`（2026-09-17 00:00〜2026-10-18 00:00 JST、終了排他）で、0投稿・1 API要求・`hasNextPage=false`・`completeSearch=false`。非網羅的であり、IMG・archive・member payloadは取得／閲覧／hash／変換／圧縮していない。

#### Raw-integer candidate status update — 2026-10-20

前段のmetadata-only候補状況を更新する。ここでの列挙は候補の総数ではなく、具体的に記録した主要leadの一部である。`normal_uint32`、SRTMGL1.003、GTOPO30、ONCの固定product、DSB/TPC-DS派生候補などは、それぞれartifact/member identity・実bytes/hash・prior-use・rights・family independence等のgateが残る条件付きleadであり、別tile・同一recordの配列・同一生成系を独立familyと数えない。LOLA等の他leadも後続節の制約に従う。raw-integer適格確認済みfamilyは引き続き0で、holdout manifest／compressionへ進まない。

### SRTMGL1.003 raw-integer metadata update — 2026-10-20

2026-10-20に[NASA/USGS SRTM Collection User Guide](https://lpdaac.usgs.gov/documents/179/SRTM_User_Guide_V3.pdf)をmetadata-onlyで確認した。HGTはheader/trailerを持たないrow-majorのsigned 16-bit big-endian binary rasterと説明される。SRTMGL1の1-degree tile dimensions 3601×3601から得る25,934,402 Bは算術上の期待raw lengthであり、選択granuleの実artifact length・member path・SHA-256を確認した値ではない。[SRTMGL1 v003 product page](https://lpdaac.usgs.gov/products/srtmgl1v003/)に対応する条件付きleadは1 product familyとして扱い、複数tileを別familyに数えない。

公式guideはVersion 3.0について、初期SRTM voidをASTER GDEM2とGMTED2010（米国等ではNED）で補完したproductと説明し、Version 3.0にvoidはないとしている。したがって`.hgt`は整数rasterだが、未加工のmission-only measurementと同一視できない。選択tileのexact source provenanceは未確認で、再利用条件もこのraw artifactについて確定していない。browse mediaのpublic-domain表記をraw granuleのrights判定へ流用せず、固定granule URI/member・source lineage・license/attribution・prior-use・正確なbytes/hashが揃うまで候補から適格familyへ昇格しない。Plumivox `scope=all`のSRTM queryは0件・`completeSearch=false`で非網羅的。payloadを取得・閲覧・hash・変換・圧縮・計測しておらず、holdout manifestには未採用。

### Hayabusa2 ONC raw integer image metadata lead — 2026-10-17

本項は先行するraw-integer metadata-only候補3件・適格family 0の同日記録を更新する。[公式PDS4 product label](https://data.darts.isas.jaxa.jp/pub/pds4/data/hyb2/hyb2_onc/data_raw/transfer/20151222/hyb2_onc_20151222_144007_tvf_l2a.xml)のmetadataを取得し、LID `urn:jaxa:darts:hyb2_onc:data_raw:hyb2_onc_20151222_144007_tvf_l2a`、version 1.0、ファイル名 `hyb2_onc_20151222_144007_tvf_l2a.fit`、公表file size 2,122,560 B、offset 23,040 B、`SignedMSB2`、1024×1024、axis `Line` sequence 1／`Sample` sequence 2を確認した。raw integer window recipeは元FIT byte offset 23,040から2,097,152 B（1024×1024×2）をそのまま使い、header/trailerを除いて再シリアライズ・数値変換をしない案である。product labelに公表digestは見当たらず、FIT payload・header・画素値は取得／閲覧していないため、実bytes・offset・windowの一致とSHA-256は未検証。

[DARTS公式bundle catalog](https://darts.isas.jaxa.jp/en/datasets/darts:hyb2-00200/)はHayabusa2 ONC bundle version 1.0、publication date 2022-10-20、data distribution内の`data_raw` collectionを示し、copyright holdersにJAXAとISAS、licenseに[ISAS Data Policy](https://www.isas.jaxa.jp/en/researchers/data-policy/)と[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)をリンクする。[bundle XML](https://data.darts.isas.jaxa.jp/pub/pds4/data/hyb2/hyb2_onc/bundle_hyb2_onc.xml)も`urn:jaxa:darts:hyb2_onc:data_raw::1.0` collectionを含む。ISAS policyはopen dataについて商用・非商用の利用、複製・転送・改変を認め、originを`ISAS/JAXA`と示し、改変時にその事実・内容を記すよう求める一方、第三者が追加制限を課す場合があるとする。確認したbundle/product metadataに追加制限は見当たらなかった。候補のattributionにはISAS/JAXA、product ID・source URL、bundle DOI `10.17597/isas.darts/hyb2-00200`、CC BY 4.0、およびwindow cutを記す。

Hayabusa2 ONCの小惑星Ryugu観測画像は既存の地球DEM・火星／月面高度計・TPC-DS sort-key候補とは別mission・instrument・source productであり、tile分割ではないため、独立family候補として扱う。ただしKHC内の`*.md`／`*.rs`／`*.json`／`*.ps1`／`*.toml`に`hayabusa`／`hyb2`／`amica`／`ryugu`／`hyb2_onc`を照合してhitなしだったのは限定的text screenにすぎず、未使用性・payload同一性の証明ではない。Plumivox `scope=all` matching query `Hayabusa2 ONC raw PDS4 data CC BY license`（2026-09-17 00:00〜2026-10-18 00:00 JST、終了排他）は0件・`completeSearch=false`で非網羅的、権利や不存在の根拠にはしない。現時点では**権利条件と整数byte recipeをmetadata上で確認したraw-integer候補family 1件**だが、payload digest・実bytes・再現可能なsource manifestが未検証のため、eligible family数・holdout manifestにはまだ算入しない。

#### 取得前admission gate案 — 2026-10-20（metadata-only）

本gateは取得・測定の許可やholdout採用ではなく、次段で確認する拒否条件の固定案である。現時点のraw-integer eligible family数は引き続き0。取得前には、公式bundle/product labelが同一のbundle version、collection、LID、product version、filename、size、dimension、`SignedMSB2`、byte offsetを示すこと、ISAS/JAXAの帰属・CC BY 4.0・ISAS Data Policyおよび第三者制限の範囲を再確認すること、ONC/Ryugu familyを全KHC過去・現行・閉鎖済みsource familyと照合し、既使用・近縁・重複がないことを確認することを必須とする。これらのいずれかが未確認、矛盾、または不適格なら取得しない。正確なfamily prior-use監査が未完の間は、限定的な文書検索を未使用証明として代用しない。

取得する場合も対象は公式metadataが指す単一FIT artifactだけとし、期待全長2,122,560 B、byte offset 23,040、window length 2,097,152 B（1024×1024×2）、exclusive end 2,120,192 Bを固定する。metadataと実体のfile length・位置・dimension・符号化に少しでも不一致があれば、offset調整や再シリアライズをせず候補を拒否する。適合時は全FITの実長・SHA-256と、元fileからの無変換byte sliceの長さ・SHA-256を別々に記録し、画素表示・値の確認・抽出範囲の選び直しは行わない。attributionにはISAS/JAXA、product IDとcanonical source URL、bundle DOI、CC BY 4.0、window cutによる変更を含める。

category-level final holdoutにはraw-integerの独立familyを3件以上そろえ、各入力のsource/artifact/member/window・権利根拠・SHA-256・長さとcandidate/tool pinを最初の圧縮前にまとめてfreezeする。このONC候補単独ではfinal screen・aggregateへ進めない。取得前storage preflight、3 familyの選定、取得後の実bytes確認とprior-use照合、最終manifest freezeの全gateが通るまでは、download・marker・圧縮・計測を開始しない。

#### ONC label and prior-use correction — 2026-10-20

上記の「小惑星Ryugu観測画像」およびgateの`ONC/Ryugu`という説明は撤回する。2026-10-20に[公式PDS4 product label](https://data.darts.isas.jaxa.jp/pub/pds4/data/hyb2/hyb2_onc/data_raw/transfer/20151222/hyb2_onc_20151222_144007_tvf_l2a.xml)をmetadata-onlyで再取得した結果、`Target_Identification`には`Hayabusa2`／`Mission`と`Space`／`Calibration Field`があり、Ryuguを観測対象として示していなかった。取得・圧縮の前提ではこの正確なTarget_Identificationを固定し、解釈を追加しない。

読み取り専用のprior-use/near-family監査はKHC metadata 1,858 file、`<作業フォルダー>\TaskArtifacts\UnLhaRe` metadata 1,064 file、goal用TaskArtifacts metadata 22 file、計2,944 fileを検索し、監査時点で一致したのはこの選定台帳の6箇所のみだった。STORAGE、profile/runner、lifecycle/recovery、保持source manifestに一致せず、製品label XMLや取得manifestの保持物も見つからなかった。FIT/ZIP payload・member bytesは開いていない。archive内部、別名・変換・抜粋、除外directory、記録外利用、所在未確認の旧記録は漏れ得るため、hitなしは未使用性の証明ではない。

同台帳のAkatsuki UVI候補とは異なるmission/instrumentだが、creatorのYamada Manabu／Kouyama ToruとDARTS／PDS4／FITS distributionを共有するため、ONCとUVIを独立familyとして数えない。Plumivox `scope=all` query `Hayabusa2 ONC 20151222 144007 product label Ryugu raw image`（2026-09-20〜2026-10-20 JST、終了排他）は0件・`completeSearch=false`で非網羅的。ONCのprior-use・近縁family・source-family独立性gateは未完了で、eligible family数は0のままとする。

### Akatsuki UVI raw integer image metadata lead — 2026-10-17

[DARTS PDS4 product label](https://data.darts.isas.jaxa.jp/pub/pds4/data/vco/vco_uvi/data_raw/c0000/uvi_20100521_115634_365_l1b_v21.lblx)をmetadata-onlyで取得し、LID `urn:jaxa:darts:vco_uvi:data_raw:uvi_20100521_115634_365_l1b`、product version 1.0、filename `uvi_20100521_115634_365_l1b_v21.fit`、公表file size 2,119,680 Bを確認した。FIT領域はoffset 0 / length 2,880 Bとoffset 2,880 / length 17,280 Bの後に始まり、候補data windowはoffset 20,160 B、`SignedMSB2`、`Line`／`Sample`各1024要素である。無変換recipe案は元FITのoffset 20,160から2,097,152 Bをそのまま使う方法だが、labelにMD5／SHA／digest fieldはなく、payload未取得のため実bytes・window・SHA-256は未検証。

[DARTS bundle catalog](https://darts.isas.jaxa.jp/en/datasets/darts:vco-00300/)はraw imageを含むbundle version 3.0、publication date 2023-06-15と、[ISAS Data Policy](https://www.isas.jaxa.jp/en/researchers/data-policy/)および[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)へのlicense linksを示す。一方、配布側の[current bundle label v005](https://data.darts.isas.jaxa.jp/pub/pds4/data/vco/vco_uvi/bundle_vco_uvi_v005.lblx)はversion 5.0、modification date 2025-04-30を示し、catalogと配布版の対応関係は未整理である。ISAS policyは対象データにraw/source dataを含め、open dataの商用・非商用利用、複製・転送・改変を認める一方、第三者の追加条件と追加acknowledgmentに従い、originを`ISAS/JAXA`と表示し、変更内容を記すよう求める。候補sourceの版対応と追加条件が未解決なので、権利適格と確定しない。

UVIとHayabusa2 ONCは異なるmission／instrumentだが、両[公式catalog](https://darts.isas.jaxa.jp/en/datasets/darts:hyb2-00200/)のcreator listにYamada ManabuとKouyama Toruが共通し、同じDARTS／PDS4／FITS distributionでもある。mission差だけでindependent familyと数えず、source-family independence・版対応・payload identityを未解決のmetadata-only leadとする。Plumivox `scope=all` matching query `Akatsuki UVI raw PDS4 data CC BY license`（2026-09-17 00:00〜2026-10-18 00:00 JST、終了排他）は0件・`completeSearch=false`で非網羅的。local text screenに一致がなかったという限定的結果も未使用性の証明ではない。現時点でraw-integer eligible family数・holdout manifestへの追加はない。FIT／archive payloadは取得・閲覧・hash・変換・圧縮・測定していない。

### Solar Orbiter EUI Release 7.0 metadata lead — 2026-10-17

[公式Release 7.0 notes](https://www.sidc.be/EUI/data/latest_release_notes.html)は2026-06-01公開とし、L1／L2の大半がFITS内でRICE tile-compressionされることを明記する。したがってこの配布形をそのままraw integer inputとするrecipeは確認できず、個別製品の固定版・byte window・publisher digestもmetadata-only調査では特定できなかった。さらにRelease 7のデータ集合はRelease 8まで追加されるため、リリース名だけでは固定snapshotにならない。

[公式Terms of Use](https://www.sidc.be/EUI/data-analysis)はpublic/free download、citation、acknowledgmentを求めるが、確認した範囲ではbenchmark用の商用複製・再配布を明示的に許す条件を確認できなかった。DOI `10.24414/djgv-ff95`のrelease landing pageは[Release notes内リンク](https://doi.org/10.24414/djgv-ff95)で確認できる。product-specific rights・固定byte identity・整数recipeのいずれも未解決のため候補から除外し、raw-integer eligible family数・holdout manifestに算入しない。Plumivox `scope=all` matching query `Solar Orbiter EUI raw integer FITS data redistribution license`（2026-09-17 00:00〜2026-10-18 00:00 JST、終了排他）は0件・`completeSearch=false`で非網羅的。payload・image catalogueは取得／閲覧／hash／変換／圧縮／測定していない。

### Zenodo `normal_uint32` local prior-use text screen — 2026-10-17

nested `UnLhaRe/`全体（hidden filesを含み、`.git`／build／target／artifacts／node_modules／本memoを除外）で`normal_uint32`、record `15240501`、DOI `10.5281/zenodo.15240501`を検索し、該当hitなし。これは現行source/docsのexact-text screenに限られ、外部run履歴、除外directory、同種datasetの別名や同一familyを証明しない。候補は引き続き条件付きで、holdout manifest未採用・payload未取得。

### 東京大学附属図書館ハンドブック候補の検索snippet露出 — 2026-10-16

追加候補として同館『オープンアクセスハンドブック 第3版』（record 2014017、DOI `10.15083/0002014017`、発行2025-08-31、公開2025-10-08）をmetadata-onlyで確認した。[公式record page](https://repository.dl.itc.u-tokyo.ac.jp/records/2014017)への直接openは429で失敗したが、同repositoryの公式metadata／file-details検索結果には個別CC BY-SA 4.0、`OpenAccessHandBook-3rdEdition.pdf`、application/pdf、1.8 MB（別表示1.9 MB）、file version ID `1e454e9b-c8ac-4041-bc1b-6c4cbf046b97`があった。東京大学附属図書館発行という点では既存の青空文庫・政府文書と異なる作成元だが、NINJAL候補と同じWEKO系repository infrastructureである。日本語prose入力にするPDF text extraction recipeと、引用・画像等の第三者権利範囲は未確定。

親側の公式domain検索結果が当該PDFの表紙相当テキスト（書名・発行元・ライセンス）をsnippetとして返し、クエリは旧第2版recordの目次snippetも返した。PDF本体のdownload/open、hash、抽出、圧縮、測定はしていないが、本文snippetへの露出が発生したためこの文書および同一ハンドブック系列（旧第2版を含む）を未見holdout候補から除外し、今後のtuning／holdoutにも使わない。Plumivox `scope=all`の同テーマ検索は`Transport closed`で結果未取得、既取得の近接queryは0件かつ`completeSearch=false`であり、権利・網羅性・未使用の証拠にはしない。別途、日本生態学会誌は公式投稿規程が全記事CC BY 4.0とする一方、目次metadata検索が隣接する別記事の抄録まで返した。記事本文・PDFは未取得だが、非閲覧境界を守れなかったため同誌の当該候補も未見holdoutとして提案・採用しない。

### UCI tabular候補の無変換recipe決定 — 2026-10-16

公式metadataでは、[Bike Sharing](https://archive.ics.uci.edu/dataset/275/bike+sharing+dataset)の`hour.csv`は1,156,736 B、dataset全体は17,389 instancesと記載されるが、hour.csv単体の行数とは区別する。[Steel Plates Faults](https://archive.ics.uci.edu/dataset/198/steel+plates+faults)は1,941 instancesの`Faults.NNA`、[Abalone](https://archive.ics.uci.edu/dataset/1/abalone)は4,177 instancesの`abalone.data`を示す。取得元は公式の[Bike ZIP](https://archive.ics.uci.edu/static/public/275/bike+sharing+dataset.zip)、[Steel ZIP](https://archive.ics.uci.edu/static/public/198/steel+plates+faults.zip)、[Abalone ZIP](https://archive.ics.uci.edu/static/public/1/abalone.zip)。3 dataset pageはCC BY 4.0と作成者creditを示す。

採用する候補recipe：各source ZIPから`hour.csv`、`Faults.NNA`、`abalone.data`のmember bytesを取り出し、そのまま圧縮入力にする。入力に含まれるheader／区切り／改行／数値表記を保持し、column extraction、整数配列化、sort、正規化、再シリアライズを行わない。source ZIP全体とmemberのpath・length・SHA-256を記録し、行数・schema・member noticeをread-onlyで検証する。想定memberの不在、notice上の除外、schema／件数の不一致はcase不成立として、圧縮前に除外または再選定する。

この候補は元データmemberのfile-compression評価であり、source ZIP自体を入力に含めない。先行する列抽出・int32配列化案は元ファイルの区切りや表記を失うため撤回し、blind holdoutや7-Zip比較に使用しない。各datasetは異なる作成者系列だが同じUCI配布platformを共有し、統計的独立性や未使用性の証明ではない。ZIP/member SHA-256、bytes、member path、行数とfield countは記録済み。member固有noticeについてはZIP内の名前と非候補sidecarだけを限定確認し、完全な法律意見とは扱わない。source payloadはTemp stagingに保全されているが、他caseの選定・family既使用照合・全体manifestが未完のため、候補は最終凍結せず、圧縮・7-Zip比較はまだ行わない。

補助的な既使用確認として、今回のmember SHA-256 3件を`experiments/khc`内のMarkdown／JSON／TOML／PowerShell資料へ照合し、選定memo以外に一致はなかった。これは手元の追跡記録に対する限定検索であり、未記録の過去入力や同一source familyの未使用性を証明しない。

入力妥当性・archive integrityのread-only確認：ローカル7-Zipの`7z t`で3 source ZIPすべてexit 0。CSV-aware stream parseではBike 17,379 records／17 fields（`dteday`のみ非数値）、Abalone 4,177／9 fields（`Sex`のみ非数値）で、field count不一致・空欄・想定外の非数値値は0。空白区切りparseではSteel 1,941行／34 nonempty numeric tokens、field count不一致0。数値全体の観測rangeはBike 0–17,379、Steel −0.9989–12,987,692、Abalone 0–29。これはschema/range確認であってmemberの再シリアライズや圧縮ではない。各rangeは型・列単位の完全な統計を代替せず、値自体もholdout比較へ使っていない。

#### 条件付き補欠候補: UCI Dry Bean (ID 602) — 2026-10-17

読み取り専用metadata調査では、[UCI公式ページ](https://archive.ics.uci.edu/dataset/602/dry+bean+dataset)のDOI `10.24432/C50S4B`、寄託日2020-09-13、著者M. Koklu・Ilker Ali Özkan（2020）、13,611 instances、16 features、feature type `Integer, Real`を確認した。配布member一覧には`DryBeanDataset/Dry_Bean_Dataset.arff`（表示3.6 MB）、`.xlsx`（2.9 MB）、`.txt`（3.3 KB）があり、Download全体は表示4.5 MB（いずれも丸め値）。表形式候補として検討するmemberはARFFだが、固定version・正確なmember byte長・SHA-256はまだなく、recipe／manifestは凍結していない。公式ページはこのdatasetを[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)と明記し、適切なcreditを条件にsharing/adaptationを許可する。

既存メモ全文を`Dry Bean`／`DryBean`／著者名／DOI／UCI ID 602で照合した範囲では一致しなかった。ただし既存のBike Sharing／Steel Plates／Abaloneと同じUCI配布platformを共有するため、別のdataset-generation lineageを持つ条件付き補欠であって、統計的独立性や全過去入力に対する未使用性は証明しない。付随notice・個別第三者要素と固定配布物も未監査であり、holdoutの権利clear・admission・category countにはまだ含めない。candidate payload／ZIPは未取得・未閲覧・未hash・未変換・未圧縮・未測定。同テーマのPlumivox X検索`Dry Bean UCI dataset license`は0 posts、`completeSearch=false`で非網羅的。

### Project Gutenberg prose候補のrights／family境界監査 — 2026-10-16

公式metadataの候補は#11（Lewis Carroll, 1898没）、#345（Bram Stoker, 1912没）、#98（Charles Dickens, 1870没）で、各catalogの`Public domain in the USA`表示は日本での権利状態や現代の電子版全構成要素までは保証しない。日本の原作品保護期間については[著作権法51・57・58条](https://laws.e-gov.go.jp/law/345AC0000000048)、[戦時加算特例法4条](https://laws.e-gov.go.jp/law/327AC0000000302)、[文化庁Q&A](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)の経過措置を併せたscreeningで原作品の期間満了を支持する材料があるが、個別権利連鎖・死後の人格的利益・現代の編集物に関する法的クリアランスではない。各ebook metadataのcredits（#11 Arthur DiBianca／David Widger、#345 Chuck Greif／Online Distributed Proofreading Team、#98 Judith Boss／David Widger）は[PG permission guidance](https://www.gutenberg.org/policy/permission.html)に沿って出典情報として記録する。候補は「著者＋原作品」をfamilyとし、共通のPG編集・変換pipelineによる相関を残す。

[PG License](https://www.gutenberg.org/policy/license.html)はcatalog誤記の可能性を述べ、ebook内licenseの確認を求める。PG表示を保持して再配布する場合のlicense／別形式提供条件もあるため、無変換本文を取得する場合でもfile内告知を無条件に省略できない。候補一覧行の「本文未取得」は初期metadata-only時点の記録であり、2026-10-16に固定候補3件を全bytes無変換で取得した。`11-0.txt`は151,191 B／SHA-256 `a3a27f8edbf7fcd9b8ba8435494440e24952deaa3e2f2d65192d4cb7ca403754`、`345-0.txt`は870,683 B／`8cf05c0f0ac5b282d84f2fb36dbccd744bdb5bce7b5612438a63b43cbe27b472`、`98-0.txt`は771,600 B／`e3dfeb67feb904ac0f73a35204a175c58248422c2be8556802cb8820d958d67c`。全件が期待`Content-Length`・`Last-Modified`・`text/plain; charset=utf-8`と一致し、strict UTF-8でBOMなし。3件すべてにPG start/end markerがあり、本文中のliteral `Project Gutenberg License` markerは0件。`98-LICENSE.txt`は537 B／SHA-256 `781eff3f628c95b2a1cae38d73f1c2fa4672ffd6b08e38f65c1f5ca5a4e663ac`として別sidecar保存し、米国でのpublic-domain表示のみで米国外調査をしていない旨を確認した。#345本文には1897年米国copyright noticeとG. & D.の広告があり、現代電子版だけでなく旧版構成物の個別評価も未解決。取得物と再現scriptは`%LOCALAPPDATA%/Codex/TaskArtifacts/UnLhaRe/01a0b076-4e26-7a71-ac35-32ed9259a871/gutenberg-prose-candidate-inputs-20261016/`に保持する。`source-manifest.json`のSHA-256は`86a8080ea55ef396b3433848bba3163d5bf2758f23e430ed77679eb187602bd5`で、別PowerShell読取で各本文・sidecarのlength／SHA-256／strict UTF-8とmanifest一致を確認した。

日本の原作品期間は[文化庁Q&A](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)が翌年1月起算、2018-12-29に未消滅の権利のみ延長、戦時加算は1941-12-08から各国との平和条約発効前日までの日数と説明する。英国政府の[1952年法令資料](https://www.legislation.gov.uk/uksi/1952/1535/pdfs/uksi_19521535_en.pdf)は英国を連合国の一国とし、条約発効日を1952-04-28と記録するため、同じ起算日の差は3,794日。70年＋3,794日を一律に仮置く保守的screenでは、Dickens（1870没）1951-05-22、Carroll（1898没）1979-05-22、Stoker（1912没）1993-05-21に終了し、全て2018-12-29より前となる。これは原作品の概算screenであって個別の旧法・相互主義・権利連鎖・電子版編集物を法的に確定するものではない。#98 sidecarの米国外免責とPGのebook内告知要件を残し、再配布権や完全なclearanceを主張しない。Plumivox query `Project Gutenberg Alice Dracula 11 345 98 Plain Text UTF-8 download`は0件・`completeSearch=false`で非網羅的。3 source family候補は圧縮・計測しておらず、候補manifestは未凍結。

### Project Gutenberg prose候補と既使用corpusのfamily crosswalk — 2026-10-16

既使用familyの独立照合で、旧候補#11『Alice's Adventures in Wonderland』は、既使用Canterbury `alice29.txt` と同じ原作品familyとして自然文holdoutから撤回する。Canterbury公式の[corpus description](https://www.corpus.canterbury.ac.nz/descriptions/cantrbry/text.html)は`alice29.txt`を英語textとして掲載し、Aliceの物語の本文例を示す。Project Gutenberg公式[#11 record](https://www.gutenberg.org/ebooks/11)は同じ原作品名を示す。これは作品familyの交差判定であり、2取得物のbyte同一性を主張しない。

旧候補#98『A Tale of Two Cities』は、既使用Silesia `dickens` collection（`CORPUS_MANIFEST.json:74`）と**同一作品だとは確認しない**。Silesia公式[dataset description](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)は`dickens`をProject Gutenberg由来のDickens作品14件の連結とし、その列挙に『A Tale of Two Cities』はない。一方で作者・PG配布／変換系列の相関は残るため、既使用Dickens入力に対する保守的な近縁familyとして#98も自然文holdoutから除外する。

#345『Dracula』は引き続き暫定候補とする。旧置換案の#43936『The Wonderful Wizard of Oz』は、metadata検索結果が本文の一部を意図せず返したためblind holdoutから除外する。本文は分析・選定に使わず、fileのdownload／hashもしていないが、family単位の未見性を保つため同作は再利用しない。新候補はProject Gutenberg [#74 The Adventures of Tom Sawyer, Complete](https://www.gutenberg.org/ebooks/74)（Mark Twain, 1835–1910）と[#215 The Call of the Wild](https://www.gutenberg.org/ebooks/215)（Jack London, 1876–1916）。2026-10-16にsecure RDF metadata（[#74](https://www.gutenberg.org/cache/epub/74/pg74.rdf)、[#215](https://www.gutenberg.org/cache/epub/215/pg215.rdf)）を確認した。カタログ上のUTF-8 text path／sizeは#74 `https://www.gutenberg.org/ebooks/74.txt.utf-8`／434,357 B、#215 `https://www.gutenberg.org/ebooks/215.txt.utf-8`／199,757 B。旧ASCII候補はそれぞれ`https://www.gutenberg.org/files/74/74-0.txt`／405,783 B、`https://www.gutenberg.org/files/215/215-0.txt`／180,051 B。canonical UTF-8 URLへのHEADはHTTP転送先を返したため追従せず、同じcache pathのHTTPS版（`/cache/epub/74/pg74.txt`、`/cache/epub/215/pg215.txt`）だけをHEADし、200・`text/plain; charset=utf-8`・size一致を確認した。Last-Modifiedは#74 2026-10-01 07:48:22 UTC、#215 2026-10-01 08:42:43 UTC。2026-10-16に同HTTPS pathから本文全bytesを取得し、GETのContent-Length／Last-Modified／Content-Typeとカタログmetadataが一致、strict UTF-8・BOMなしを独立再検証した。#74は434,357 B／SHA-256 `74d77384b123a6360db9ab58463cff8b38df8525fbdc6000c81ee388e1f3cf10`、#215は199,757 B／`30f569c5671bba7bbc4a92ab6d8ee01a0d3be00f994819c77da62c28041eb8a2`。機械的marker scanでは各fileにPG start/end各1、literal `Project Gutenberg License` 6、`copyright` 20、`public domain` 2件を検出したが、本文内容・個別noticeの意味解釈ではない。raw files、取得script、manifestは`C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\01a0b076-4e26-7a71-ac35-32ed9259a871\gutenberg-sawyer-london-inputs-20261016\`に保持し、manifest SHA-256 `2e2c2672d86ca626272613cd881429b7586d2e43382aa1ec8605584340467e0f`、script SHA-256 `c050c9eda41db4ae0265e95ed9f7f51ba273f89617fc8fedfb747fb25b8bd638`。公式recordはいずれも米国内public-domain表示で、[#74](https://www.gutenberg.org/ebooks/74)のcatalog creditはDavid Widger、[#215](https://www.gutenberg.org/ebooks/215)はRyan, Kirstin, Linda and Rick Trapp／David Widger。PGの[license](https://www.gutenberg.org/policy/license)が国外ユーザーへ現地法確認を求め、file内license markerと電子版固有の編集・個別notice・file-specific scopeの詳細評価が残るため、両候補のrights clearanceは未完了。文化庁の[保護期間Q&A](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)は原則死後70年、米国等の対象著作権に戦時加算3794日、2018年改正の延長対象は施行前日にも保護中の著作物と説明する。Twainの1910年没から計算する原作品は、この戦時加算を含めても2018年より前に満了した可能性が高いが、これは法的clearanceではない。3作品は別author/work familyだがPG共通配布・変換pipeline相関は維持する。#74/Mark TwainはKHC内documentation／metadata／source検索で一致を検出しなかったものの、未使用の証明ではない。取得した#74/#215および旧#11/#98の取得物も圧縮・計測に使わず、候補manifestは未凍結。

同テーマのPlumivox `search_tweets(scope=all)` は、`Silesia corpus dickens Canterbury alice29 Project Gutenberg Alice's Adventures in Wonderland A Tale of Two Cities overlap`、旧置換案の`Project Gutenberg Wonderful Wizard of Oz The Call of the Wild 55 215 public domain source family compression corpus`、新候補の`Project Gutenberg Tom Sawyer Mark Twain Canterbury Silesia corpus compression benchmark holdout`、およびrights確認の`Project Gutenberg license 74 215 text UTF-8 file notice`を検索した。全queryは0件、すべて`completeSearch=false`（rights queryは1 API request）。X結果は非網羅的で、未使用・権利の根拠にはしない。自然文の3 family、exact file／edition、rights/notices、全体manifestが揃うまでholdout圧縮へ進まない。

2026-10-16に保持した#74／#215の境界だけを追加走査した。各fileは前書き26行、START markerは27行目、END markerは#74の8922行目／#215の3102行目、末尾は各351行。前書きのCredits値は公式recordと一致し、前書きにはPG license markerが各1、copyright／public-domain markerは0。末尾には各1件のfull-license heading、PG license marker 5、copyright marker 20、public-domain marker 2を検出した。markerの区分と個数だけの走査であり、license本文・文学本文の意味評価、個別rights clearanceではない。取得bytesは未変換のまま保持し、候補選定・圧縮・benchmarkには使用していない。

公式の[旧形式directory listing #74](https://www.gutenberg.org/files/74/)には`74-0.txt`、ZIP、HTML directory等があり、[同#215](https://www.gutenberg.org/files/215/)には`215-0.txt`、HTML directory等がある。いずれもlisting直下に個別`LICENSE.txt`はないが、nested directoryは未調査であり、file内に埋め込まれたlicenseとは別に付随告知がない証明ではない。[Project Gutenberg License](https://www.gutenberg.org/policy/license.html)は米国外利用者に現地法確認を求め、catalog表示が誤る場合はebook内licenseを確認するよう述べ、作品の一部を読む／使うことをlicense条件受諾として扱う。したがって、本件でPG候補をholdout評価に使う場合も、埋込license・creditsを保持し、ユーザーのlicense受諾範囲を確認するまで実使用と再配布を保留する。

日本の原作品期間だけを保守的にscreenすると、文化庁の[期間計算Q&A](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)に従い、没年内の12月31日没と仮定して翌年起算の死後70年を最大化し、さらに[戦時加算特例法4条](https://laws.e-gov.go.jp/law/327AC0000000302)に基づく最大3,794日を一律に加えると、Twain（1910没）は1991-05-22、London（1916没）は1997-05-21までに満了する計算となる。どちらも2018-12-29より前であり、同Q&Aの2018-12-30改正は施行前日に未消滅の著作物を延長対象とするため、原作品が延長された可能性を低く見る材料になる。ただしこれはauthor/death yearだけによる保守的screenであり、旧法・相互主義・実際の権利連鎖・電子版の編集／個別権利・license条件を確定せず、法的clearanceや再配布許可を主張しない。

### 青空文庫日本語text候補のread-only rights／family境界監査 — 2026-10-16

[公式図書カード](https://www.aozora.gr.jp/cards/000035/card301.html)ではNo.301『人間失格』は初出が『展望』1948年6～8月号、太宰治の没日は1948-06-13、底本は新潮文庫1952年初版、入力・校正は細渕真弓・八巻美恵。候補XHTML `301_14912.html` はShiftJIS・179,475 B、初登録2004-02-23、最終更新2011-01-09と記録される。[No.424『檸檬』](https://www.aozora.gr.jp/cards/000074/card424.html)は『青空』1925年1月初出／梶井基次郎1932-03-24没、底本は旺文社文庫1972年初版（入力・校正に1974年第4刷）、`424_19826.html` はShiftJIS・18,187 B、2005-10-11／2016-07-05。[No.752『坊っちゃん』](https://www.aozora.gr.jp/cards/000148/card752.html)は『ホトトギス』1906年4月初出／夏目漱石1916-12-09没、底本は筑摩書房1992年版、`752_14964.html` はShiftJIS・364,145 B、2004-02-28／2011-05-20。これらの長さ・日時は図書カードmetadataで、取得bytesの実測ではない。No.301の連載期間は没日をまたぐため、全編を生前公表済みと単純化せず、1952年の底本を原作品の初公表年とも扱わない。

文化庁の[保護期間延長Q&A 問1・問2・問4](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)は、通常の著作者死後50年から70年への変更、起算が死亡年の翌年1月1日であること、および2018-12-30施行前に既に消滅した権利は復活せず延長対象にならないことを示す。図書カードの没年をこの通常則で照合すると、太宰治（1948没）は旧期間が1998-12-31まで、梶井基次郎（1932没）は1982-12-31まで、夏目漱石（1916没）は1966-12-31までで、いずれも2018-12-29より前に満了したと見る根拠になる。これは日本における原作品のmetadata-only screeningであって法的clearanceではない。底本の編集要素、入力・校正による創作的寄与、個別ファイル中の第三者要素、[著作権の保護期間満了後も理論上残り得る著作者人格的利益](https://www.bunka.go.jp/seisaku/bunka_gyosei/kibankyoka/faq/index.html?s=09)、配布規準上のcredit保持は別途扱い、今回の候補ファイル全体の権利状態を確定しない。同日のPlumivox `scope=all`検索「青空文庫 太宰治 人間失格 著作権 保護期間」は0件、`completeSearch=false`で非網羅的であり、権利・未使用の証明ではない。

[青空文庫収録ファイルの取り扱い規準](https://www.aozora.gr.jp/guide/kijyunn.html)（2022-01-01更新）は図書カードからリンクされた個別ファイルを対象とし、著作権が切れた作品のファイルは複製・再配布・形式変換等に事前の対価や了解なく利用できる一方、著作権が有効な作品には別の制約を定める。入力・校正等に関する情報の保持は規準上「希望」、変更履歴は「期待」とされるため、法的条件として強めず、今回のraw-file recipeでは自然に保持される全bytesと出典・作業者metadataを保つ。[収録ファイルへの記載事項](https://www.aozora.gr.jp/guide/kisai.html)は入力ファイルを再利用した場合の注記例も示すが、当該3件にその注記や第三者由来素材があるかは本文未閲覧のため未確認。図書カード・書架metadataへのCC BY 4.0は作品XHTML全体のライセンスへ転用しない。

[文化庁の保護期間Q&A](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)は改正前の原則50年、期間の翌年起算、2018年延長が当時なお権利の消滅していない作品に適用されること、旧法期の作品では旧法・経過措置の確認が必要と説明する。没年に対する単純な死後50年screenでは3件とも2018年より前になるが、個別の旧法・連載・底本編集・権利連鎖を確認した満了判定ではない。現段階では3作品を「著者＋原作品」別の候補familyとして維持できる根拠はあるが、青空文庫の同一配布元、XHTML／ShiftJIS、共通template・注記・入力校正pipelineによる相関があり、3つの独立配布元とは数えない。No.752は撤回済み旧候補No.773『こころ』と作者が共通する点も相関として残す。

Plumivox `search_tweets(scope=all)` query `青空文庫 人間失格 檸檬 坊っちゃん 著作権`（2023-01-01〜2026-10-17 JST）は0件、`completeSearch=false`で非網羅的。metadata-only監査後の2026-10-16、3候補の公式XHTML全bytesを無変換取得した。`301_14912.html`は179,475 B／SHA-256 `ffc7978c345db28c001bccb64de7a4eb85bcfcfc41d02cb84e562cb39ac90d6b`、`424_19826.html`は18,187 B／`5e3e8a10842d7bea38106c953e30c353c295af9b0126abbf3f933b06f4b62a17`、`752_14964.html`は364,145 B／`b30b6f1cb8c8ab8ec71b4b37488ccc8450402d09090943500d121499b9a1eaa1`。各GETは事前HEADのContent-Length／Last-Modifiedと一致し、Shift_JIS宣言を確認してWindows code page 932でstrict decodeできた。independent local readで各SHA-256・長さ・manifest一致を再確認し、入力／校正者・底本・初出・青空文庫のcreditが本文内にもあることを確認。No.752の底本注記に作品原稿の字間指定および文字形に関する編集説明があるため、全bytesを維持し、該当箇所を切り出したり補正しない。取得物と再現scriptは`%LOCALAPPDATA%/Codex/TaskArtifacts/UnLhaRe/01a0b076-4e26-7a71-ac35-32ed9259a871/aozora-japanese-candidate-inputs-20261016/`に保持し、`source-manifest.json`のSHA-256は`45c1b6e91f8cd7daa960ea34f1559ef662bd73df5049de537255a33ec0b18a6a`。本文・sidecarの変換、圧縮、benchmarkはしていない。個別notice・第三者要素・原作品以外の権利連鎖は未クリアのため候補であり、holdout manifestは未凍結。

### 国税不服審判所の日本語prose候補 — metadata-only監査 — 2026-10-16

青空文庫とは異なる作成元の代替familyを探し、[国税不服審判所の裁決事例集No.138（令和7年1〜3月）の公式目次](https://www.kfs.go.jp/service/JP/idx/138.html)から最初に掲載された事例（「相続財産の総額を確定できなかったことが無申告加算税の正当な理由に当たらないとした事例」、令和7年1月17日裁決）をmetadataだけで選んだ。候補の単一HTML URLは`https://www.kfs.go.jp/service/JP/138/01/index.html`。候補本文は開いておらず、直接GET、保存、hash、変換、圧縮、計測をしていない。公開日・最終更新日・byte長も未確認であり、URLと裁決日だけでは不変版を固定しない。

[国税不服審判所の利用案内](https://www.kfs.go.jp/guide/index.html)は、特記・権利表記がない同所コンテンツを同所著作物とし、[公共データ利用規約（第1.0版）](https://www.digital.go.jp/resources/open_data/public_data_license_v1.0)に基づく利用条件を示す。出典と加工・編集の表示が必要で、個別に別ルールが適用されるコンテンツは規約対象外となる。候補ページ個別の第三者引用・埋込み・別紙・図版・法令テキスト等は未閲覧のため、権利clearとは判断しない。利用案内はサイト情報が予告なく変更・削除され得るとも注意する。家族境界は「同一の公的審判機関が公表する税務裁決」で、白書・会計検査院・文学作品とは生成元を分けられるが、裁決本文中の法令引用や共通テンプレートによる相関は未評価。

同テーマのPlumivox公開検索 `search_tweets(scope=all)` query `国税不服審判所 裁決 著作権 再利用` は0件、`completeSearch=false`。非網羅検索のゼロ件は、権利・未使用・独立性の証明に使わない。よって本件は日本語proseのoverflow候補に留め、本文監査、既使用family crosswalk、権利・第三者要素判定、byte固定を経てholdout manifestへ入れるか決める。外部調査後にこの候補記録を更新したが、candidate payloadは未取得。

### 公正取引委員会の日本語prose候補 — metadata-only監査 — 2026-10-16

[公正取引委員会の2025年9月報道発表一覧](https://www.jftc.go.jp/houdou/pressrelease/2025/sep/index.html)の題名・日付metadataから「株式会社シマノに対する勧告について」（2025-09-17）を選んだ。候補単一HTML URLは`https://www.jftc.go.jp/houdou/pressrelease/2025/sep/250917_kinki_shitauke.html`。当初のmetadata-only段階では候補本文を開かず、PDF・asset・raw payloadの取得／hash／変換／圧縮／計測もしていなかった。公取委の[利用案内](https://www.jftc.go.jp/kiyaku/index.html)は、特記・権利表記がないコンテンツをPDL1.0の下で再利用可とし、出典・加工表示を求める一方、シンボル・ロゴ等を除外する。ページ個別の第三者著作物・引用・画像・添付・正確なprose量は当初未監査で、権利clearや自然文holdout採用とは扱わない。familyは公取委が作成する行政措置の説明で、既存白書、会計検査院、KFS、文学とは作成元が異なるが、法令引用・行政定型文の共通性は未評価。

比較候補として[日本銀行の2025年講演一覧](https://www.boj.or.jp/about/press/koen_2025/index.htm)から2025-01-30の氷見野副総裁「金利のある世界」もmetadataで特定したが、日銀の[著作権案内](https://www.boj.or.jp/about/copyright.htm)は商用目的の転載・複製に事前相談を求め、転載禁止部分や写真・画像等にも個別条件を置く。今回の利用・再配布がその条件にどう当たるか未解決のため、現段階では置換候補に推奨せず、候補manifestへ追加しない。日本銀行の候補ページ本文は開いていない。

2026-10-16の後続可視ページ確認では、公取委の候補HTML本文に機関名・日付、説明文、番号付き勧告事項が表示され、単なるPDF landing pageではなくproseを含むことを確認した。同ページには「関連ファイル」として印刷用PDF（288 KB）がリンクされるが、単一-HTML recipeには含めず、PDF・画像等のassetは取得しない。表示footerに`Copyright © Japan Fair Trade Commission. All rights reserved.`がある。これがsite-wide定型表示か個別rights markerか、利用案内のPDL1.0との範囲関係は未解決。閲覧したページ表示はraw HTML全体・hidden markup・外部assetを保証しないため、第三者権利・引用・リンク先内容・法令引用・既使用textとの重複も未確認で、候補はconditionalのまま。候補ページをlocal download/hash/保存/変換/圧縮/計測していない。

同テーマのPlumivox公開検索 `search_tweets(scope=all)` query `日本銀行 公正取引委員会 講演 報道発表 著作権 再利用` は0件、`completeSearch=false`であり、未使用・権利適合の証拠ではない。公取委候補はoverflowに留め、single-HTML境界、可視／埋込み要素、第三者権利、共有法令text、既使用family重複の監査後に採否を判断する。

## OpenSSL暗号化recipeのローカルtool確認 — 2026-10-16

`Get-Command openssl.exe`ではPATH解決されないが、既存のGit for Windows配下`C:/Program Files/Git/usr/bin/openssl.exe`をread-onlyで調べたところ、FileVersion/ProductVersionは3.5.7、長さ1005028 B、SHA-256 `78340FB01DEA2DF5CAAB73DCF28833B31329226A4C9E02F717F1D399592265B9`、Authenticode `NotSigned`だった。実行fileとLibraryはOpenSSL 3.5.7で、`enc -list`に`-chacha20`を表示し、`version -a`はMSYS2 x86_64 / GCC buildを示した。candidate plaintextへの暗号化・復号はしていない。この環境観測だけでは配布元・信頼性・provider/module依存・再現recipeを確定できないため、固定案OpenSSL 3.5.0はまだ置換せず、同梱元とnoticeの一次資料監査を待つ。

外部一次資料との照合では、ローカル`etc/package-versions.txt`が`openssl`／`libopenssl` 3.5.7-1、`ReleaseNotes.html`がOpenSSL 3.5.7同梱を示す。公式[Git for Windows v2.55.0.windows.5](https://github.com/git-for-windows/git/releases/tag/v2.55.0.windows.5)は配布installerのSHA-256を掲載するが、このexe個別SHAとの照合にはならない。OpenSSL 3.5.7の[EVP ChaCha20仕様](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/doc/man3/EVP_chacha20.pod)では256-bit keyと128-bit IV（counter＋nonce）を使うため、IETF ChaCha20-Poly1305の96-bit nonceと混同しない。[`enc`仕様](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/doc/man1/openssl-enc.pod.in)上、`enc -chacha20`は認証tag付きAEADではない。OpenSSL 3.5.7は[Apache-2.0](https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.7/LICENSE.txt)で、ローカル同梱LICENSEを確認したが上流tagのNOTICE有無は未確定。Git for Windowsの現在のpackage recipeは別version 3.5.9で、3.5.7の厳密なbuild provenanceを証明しない。したがって現hashはローカルexeの同一性pinに使えるだけで、供給元・ソース対応・DLL/provider/config closureは未確定。3.5.7は仕様上置換候補だが、既存3.5.0 recipeから変更する判断と暗号化往復検証は保留し、candidate ciphertextは未生成とする。

## PNG候補のread-only rights／identity監査 — 2026-10-16

3つの固定Git treeはいずれも`truncated=false`で、対象48 pathの存在とmetadataを確認した。Twemoji v14.0.2のtagはcommit `7a3dad4a4da30497093dab22eafba135f02308e1`へ解決し、`assets/72x72/1f600.png`〜`1f60f.png`の16件を選んだ。OpenMoji 15.0.0の固定commit `13942cdd65134df8899ed5df62ccf47b36d643d7`では`color/72x72/1F600.png`〜`1F60F.png`の16件が固定[codepoint metadata](https://github.com/hfg-gmuend/openmoji/blob/13942cdd65134df8899ed5df62ccf47b36d643d7/data/openmoji.json)と一致する。Fluent Emojiの固定commit `1ffb34c752ecf5d402f04cfb4b392c77f57c54bc`では各`metadata.json`の`unicode` U+1F600〜U+1F60Fを照合し、対応PNGが各1件存在することを確認した。tree metadataのsize合計はTwemoji 13,978 B、OpenMoji 30,901 B、Fluent 671,129 B（計716,008 B）。

2026-10-16にraw bytes 48件を固定commit URLから取得し、各実byte長とGit blob SHA-1をtree entryに照合、PNG署名と保存後SHA-256を全件検証した。個別hash付き候補asset manifestは `C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\01a0b076-4e26-7a71-ac35-32ed9259a871\png-candidate-inputs-20261016\source-manifest.json`（manifest SHA-256 `2c7ce52fd73748fbd08b0449632e26ce032d1200bca78ed9e3c01aab254d56e4`）に保持する。これは候補素材の記録であり、評価用manifest凍結ではない。固定treeは[Twemoji](https://api.github.com/repos/twitter/twemoji/git/trees/7a3dad4a4da30497093dab22eafba135f02308e1?recursive=1)、[OpenMoji](https://api.github.com/repos/hfg-gmuend/openmoji/git/trees/13942cdd65134df8899ed5df62ccf47b36d643d7?recursive=1)、[Fluent Emoji](https://api.github.com/repos/microsoft/fluentui-emoji/git/trees/1ffb34c752ecf5d402f04cfb4b392c77f57c54bc?recursive=1)である。

権利根拠は個別に区別する。[Twemojiの固定README](https://github.com/twitter/twemoji/blob/7a3dad4a4da30497093dab22eafba135f02308e1/README.md)と[LICENSE-GRAPHICS](https://github.com/twitter/twemoji/blob/7a3dad4a4da30497093dab22eafba135f02308e1/LICENSE-GRAPHICS)は画像assetのCC BY 4.0を示し、root MITのコード用licenseと混同しない。[OpenMoji固定README](https://github.com/hfg-gmuend/openmoji/blob/13942cdd65134df8899ed5df62ccf47b36d643d7/README.md)と[LICENSE.txt](https://github.com/hfg-gmuend/openmoji/blob/13942cdd65134df8899ed5df62ccf47b36d643d7/LICENSE.txt)はemoji artworkのCC BY-SA 4.0と、コードのLGPL-3.0との区別を支持する。配布時は指定された作者・copyright・license・出典表示を保ち、OpenMoji artworkの翻案物を再配布する場合にはShareAlike条件を適用する。単なる可逆圧縮自体が翻案に当たるとはこの記録から断定しない。[Fluentの固定root LICENSE](https://github.com/microsoft/fluentui-emoji/blob/1ffb34c752ecf5d402f04cfb4b392c77f57c54bc/LICENSE)はMITだが、これはroot/project licenseに基づく暫定評価であり、各画像の独立した宣言や第三者権利の全面保証を確認したものではない。固定[README](https://github.com/microsoft/fluentui-emoji/blob/1ffb34c752ecf5d402f04cfb4b392c77f57c54bc/README.md)はcollection説明・連絡先・行動規範を記載するが、個別画像へのlicense適用範囲は説明しないため、その点の不確かさは残す。Microsoftのcopyright・permission noticeを保持する。

本セットは同じ16 emoji codepointを3 projectの図版表現で比較する統制セットであり、48件の独立した一般PNG標本ではない。各project内も共通制作工程で相関する。取得bytesは表示・寸法読取・変換・圧縮していない。個別asset内noticeと既使用familyとの重複、ならびにPNG全般への代表性は未確認のため、候補と権利評価は暫定で、評価用manifestは未凍結とする。Plumivox公開検索「Twemoji OpenMoji Fluent Emoji license」はscope=allで0件だったが、非網羅検索であり不存在の根拠ではない。

既使用参照の補助確認として、選定文書を除く`experiments/khc`配下のMarkdown／JSON／PowerShell／Rustファイルを、Twemoji・OpenMoji・Fluent Emoji・U+1F600・U+1F60F等の文字列で検索し、一致はなかった。これは記録上の限定検索であり、未取得の画像bytesや同一source familyの未使用性を証明しない。追加の同テーマPlumivox `scope=all` query `Microsoft Fluent Emoji individual asset license MIT CC BY 4.0 Figma`も0件・`completeSearch=false`で、非網羅的。

2026-10-16の代替source metadata screenでは、[Noto Emoji README](https://raw.githubusercontent.com/googlefonts/noto-emoji/main/README.md)がfontをSIL OFL 1.1、toolsと画像資産の大半をApache 2.0、`third_party/region-flags`を別扱いとしている一方、READMEからリンクされる[現行main root LICENSE](https://raw.githubusercontent.com/googlefonts/noto-emoji/main/LICENSE)の冒頭はfont向けSIL OFL 1.1であり、一般画像資産のApache適用根拠として整合しなかった。公式の[region-flags LICENSE](https://raw.githubusercontent.com/googlefonts/noto-emoji/main/third_party/region-flags/LICENSE)も個別の第三者素材を列挙する。同日、現行mainの`png/LICENSE`、`svg/LICENSE`、`fonts/LICENSE`、`2D/LICENSE`の各raw URLは404だった。これは別の場所や履歴にlicenseがない証明ではないが、PNG専用の根拠を確認できなかった。選定する正確なPNG member・pinned commit・当該memberのlicense範囲を確定できないため、Noto EmojiはPNG候補に追加せず、Fluent Emojiの置換候補とも認定しない。Plumivox `scope=all` query `Google Noto Emoji PNG assets Apache License 2.0 license scope third_party flags`は0件・`completeSearch=false`で非網羅的。PNG bytes/memberは開かず、取得・hash・manifest登録・圧縮・測定をしていない。

同日のGitHub tree metadata follow-upでは、現行mainのhead commitを`e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e`（2026-09-24）に固定し、画像assetの配置が`2D/png/{32,72,128,512}`であることを確認した。pinned [2D/svg/LICENSE](https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/2D/svg/LICENSE)はApache 2.0だが、pinned `2D/png/LICENSE`は404で、`2D/png`直下のtree metadataにもlicense fileはない。pinned [root LICENSE](https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/LICENSE)はfont向けSIL OFL 1.1であり、pinned [README](https://raw.githubusercontent.com/googlefonts/noto-emoji/e20cbc2bbec1926686be9f9bee7d1d2cfa1fea0e/README.md)の`./LICENSE`という画像資産への参照と整合せず、READMEの`fonts/LICENSE`配置もtree上の`2D/fonts`とは一致しない。したがってSVG用Apache LICENSEをPNGへ拡張適用せず、PNG資産の権利範囲は未解決としてNotoを候補に追加しない。確認はtree metadataとlicense文書だけで、PNG bytesは読んでいない。

## Google Material Iconsのmetadata-only overflow確認 — 2026-10-16

Google Material IconsのPNGを追加のoverflow候補として記録する。Googleの[Material Icons guide](https://developers.google.com/fonts/docs/material_icons)はicon setのApache-2.0適用と個別PNGの配布を明記し、pinned [repository LICENSE](https://raw.githubusercontent.com/google/material-design-icons/49d4db35df873165d6bd6ba09b063c7dafbac2f4/LICENSE)もApache-2.0。GitHub APIで`master`をcommit `49d4db35df873165d6bd6ba09b063c7dafbac2f4`（author date `2026-10-09T02:25:39Z`）へ固定した。root tree `2b881d40771515e109b49acd538dd8ec7c286437`には`png`（tree `64441c901236a2a154b7a7c640aa06906a404894`）と`symbols`が別々にあり、以下はclassic Material IconsのPNGだけを対象にする。

候補recipeは`png/action/<name>/materialicons/24dp/1x/baseline_<name>_black_24dp.png`の16 member。nameは`account_balance`, `account_circle`, `alarm`, `assignment`, `backup`, `build`, `cached`, `check_circle`, `dashboard`, `delete`, `favorite`, `home`, `info`, `search`, `settings`, `visibility`で固定する。以下はpinned tree metadata（sizeとGit blob SHA-1）であり、PNG bytesそのもののhash・内容確認ではない。

| name | tree size (B) | Git blob SHA-1 |
| --- | ---: | --- |
| account_balance | 124 | `ef5303a2793520d0ad785a69633cd3b739ceebb3` |
| account_circle | 296 | `1aa0e83854c7741d749dfdfdc382d5aa25885f2d` |
| alarm | 351 | `78c5e48ec0d7642520475a00885ab9ad0d1061eb` |
| assignment | 147 | `81b13703f08994a42ff556007119256fbb8e7048` |
| backup | 239 | `5f196aea60a6b2a564ad441d5ba80e744fa28412` |
| build | 225 | `9c066014a4c1dbae2962f3c7b1f433619561f228` |
| cached | 233 | `e4d236f4bd3d0ab3e511ca07be25b1c4eed9f784` |
| check_circle | 240 | `6724af52bc07d679dddfbd297393d88be770b175` |
| dashboard | 94 | `8595315fbf2e4e8d0dccd17e4b7eebc98089fbba` |
| delete | 113 | `66d7e7ac436b959201f689ca2a34f176a55e315f` |
| favorite | 254 | `baefeeb27fa8e7f434fa9deb0b365789f6a224c8` |
| home | 182 | `ee35b8464af52d3816c3fef2394ebfa2a3a78c54` |
| info | 194 | `b9cca56d29a6d7de2f3f35ce3489d1a1fd7c2cb1` |
| search | 213 | `aa8a2c4a98e53511b3d4701e3a7589d7d1502b98` |
| settings | 299 | `79c6b2688d0d3bcd25f0a54607f48b417fb6396f` |
| visibility | 229 | `138a0285fe329b8d023d3045aa09d4d98e5618a9` |

tree sizeの合計は3,433 B。`png`全体のrecursive tree応答は62,030 entriesで`truncated=true`のため総数根拠に使わない。`png/action` tree `38b8dc51ce1519fb83c181a400291a4d0e0d835f`は48,940 entries・`truncated=false`で、同じbaseline black 24dp/1x patternに468件を確認した。repository treeはpngの下に多数のicon groupとscaleがあるため、この16 member recipe以外へ選定を広げない。

既存`experiments/khc`の選定memoを除くtext source/docsを`google/material-design-icons`、`material-design-icons`、`materialicons/24dp`、`Material Icons`、`Material Symbols`および16 basenameで検索しhitなし。これは限定的な文字列screenで、未記録・binary・alias利用を証明しない。Plumivox同テーマ検索`Google Material Design Icons PNG assets license Apache 2.0`は0件・`completeSearch=false`で非網羅。individual assetの付随noticeと過去未使用性は未解決のまま。候補PNGの取得・保存・表示・hash・manifest登録・compression・measurementは行っていない。overflow候補は三family targetへまだ数えず、holdoutへ未登録。

## 2026-10-05時点の初期判断

量子方式は本線不採用。初回選定時点では全静的有料MDLを第1候補とし、完成frame、stored、整数decode、製品統合、比較性能を順に実装する計画だった。以下の追記には、その後の別candidate試作・実測と現在の証拠を時系列で記録する。各段階の小規模E2Eやdevelopment screenだけを、7-Zip超過の証拠へ読み替えない。

## 実行binaryの代替source監査 — 2026-10-16

追加候補としてfd v10.2.0、hyperfine v1.19.0、dust v1.1.1のWindows x64 memberを公式配布手順から特定したが、実payloadの個別hashと版固定の推移依存・runtime notice集合は未確認である。fdとhyperfineは同一作者の別projectでもある。したがって、既存のripgrep／jq／age案を置換できる、独立性と再配布noticeまで確認済みの3-family setは得られていない。候補payloadは取得・展開・実行しておらず、どの案も未確定のままとする。

## JSON/source code/tiny/ZIP/version-pair候補のread-only rights監査 — 2026-10-16

2026-10-16の初回read-only rights監査時点では、JSON候補3件（ESLint／Prettier／CLDR）はmetadata-onlyでpayload未取得だった。その後、固定commitのJSON本体と各LICENSE sidecarを取得し、byte length・Git blob SHA-1・SHA-256・strict UTF-8・JSON parseを検証済み（下記）。source code候補3件（Caddy／DuckDB／Tree-sitter）とtiny候補3件（fmt／Catch2／libuv）は指定raw fileを取得し、byte length／hash照合と限定rights marker scanを実施済み。ZIP container候補3件（attrs wheel／JUnit Jupiter API JAR／Newtonsoft.Json nupkg）は固定raw全体を取得・hash照合し、rights-named archive entryだけを確認した。通常archive member・class／codeやその他payload内容は未閲覧であり、限定確認を「全bytesのrights clearance」とは扱わない。どのcategoryも評価用manifestは未凍結である。

JSON候補の固定文書では、ESLint／Prettierのroot LICENSEがMIT、CLDR core LICENSEがUnicode License V3でData Filesを明示的に対象としていることを確認した。個々のJSON payload内の例外・第三者noticeは未調査であり、権利確認は暫定のまま。ESLintとPrettierは別projectだが、同じnpm `package.json`形式に由来する相関を含む。

2026-10-16に固定commitからraw JSONを取得し、入力bytesを変換せずに保持した。`eslint-package.json` 5,659 B SHA-256 `2b8026d77b33e1e345c45849146cf3f3e00f4214ea46c757e78cf73f72ad4b40`（Git blob SHA-1 `356bfbbc8c14ac7c853d63c6bd8d52933c193671`）、`prettier-package.json` 6,813 B SHA-256 `3b624b312314863f29fca5518664d82699e817a0029e87a22dc4bab0b6fc1d6c`（Git blob SHA-1 `89d3f495231a758e6f6b8952583829667ced40c9`）、`cldr-weekData.json` 11,204 B SHA-256 `31117b7d457c01df4b175bad27b4aaa13a27d9ce4293a79e7876743e541054cc`（Git blob SHA-1 `3af8b154d2421f4dbfeb9a9d5c332ca6dd980555`）。3件すべてstrict UTF-8 decodeとJSON parseに成功し、取得後の独立検証でもmanifest記載のsize・SHA-256・Git blob SHA-1が一致した。LICENSE sidecarはESLint 1,094 B SHA-256 `3b6be04f862a077a4b97929dbf247299360824d9365f8603c263769303ace18c`、Prettier 1,065 B `b0f2417199889f1c0d28ec4e0244eacf1a15de5819d61f641dd7d8f45153ac9c`、CLDR core 2,033 B `743308f92225393665b0722b73418b4d4061fd2163e8e9c38b3368904acf19d6`を別ファイルで保持した。全6取得物の出典URL・byte数・content-type・SHA・license欄を記録した`source-manifest.json`（5,239 B、SHA-256 `d940b36d1ced5703e93bc151f188c2a12432346b6c69d1fc99dbfe8ad1883815`）は `C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\01a0b076-4e26-7a71-ac35-32ed9259a871\json-candidate-inputs-20261016\` にある。取得・独立検証はidentity/JSON parseの証拠であり、payload内部の第三者provenance・例外を含むrights clearanceやholdout選定凍結を意味しない。圧縮・benchmarkは未実施。

source codeは固定project LICENSEに基づく暫定評価で、Caddy `caddy.go`はApache-2.0、DuckDB `database.cpp`とTree-sitter `parser.c`はMIT。限定scanではCaddyの先頭に2015 copyrightとApache-2.0 headerがあり、先頭13行にSPDX・generated・第三者license markerはなかった。DuckDB／Tree-sitterの候補fileにはheaderがなく、限定語句scanでもmarkerは検出しなかった。DuckDBはcore `src`配下、Tree-sitterはC library source領域で、`lib/src/unicode`の別条件領域は含まない。ただしこれらは全権利者・第三者provenanceの確認ではない。配布時は該当LICENSEと適用される帰属・変更・NOTICE条件を保持する。

追加のpayload-blind独立監査では、CaddyはGo製server、DuckDBはC++ database、Tree-sitterはC parser/runtimeという別projectの来歴を確認し、別source lineageとして扱うことを暫定支持したが、候補間の共通コード・転載がない証明ではない。Tree-sitterの固定commitにある[`lib/src/unicode/LICENSE`](https://raw.githubusercontent.com/tree-sitter/tree-sitter/5e8760bf462ce7b19b3d2396d5b7860f3906a297/lib/src/unicode/LICENSE)はUnicode/ICUおよびdictionary由来の第三者通知を含む。これは選定path `lib/src/parser.c`への適用を直接示さず、候補単体のMIT表示だけで同repositoryの全pathを扱えないという注意に限る。Caddyの固定commit root `NOTICE`とDuckDBの`third_party/README.md`はそれぞれ固定URLでHTTP 404となったが、取得不能は当該noticeや第三者要素の不存在を証明しない。2026-10-16のPlumivox公開X追跡検索 `Caddy license` は古い別話題、`DuckDB license` は質問投稿、`Tree-sitter license` は0投稿で、いずれも非網羅的・権利根拠外である。検索結果・閲覧ページに候補source file本文のsnippetは見つからず、READMEの操作／SQL例とlicense内commentは表示された。

tiny候補3件はいずれも固定projectのroot `CMakeLists.txt`で、fmt 10.2.1は[MIT](https://raw.githubusercontent.com/fmtlib/fmt/e69e5f977d458f2650bb346dadf2ad30c5320281/LICENSE)、Catch2 v3.5.4は[BSL-1.0](https://raw.githubusercontent.com/catchorg/Catch2/b5373dadca40b7edc8570cf9470b9b1cb1934d40/LICENSE.txt)、libuv v1.48.0は[MIT](https://raw.githubusercontent.com/libuv/libuv/e9f29cb984231524e3931aa0ae2c5dae1a32884e/LICENSE)を適用条件とする暫定評価である。fmtのobject-code exceptionとCatch2のmachine-executable exceptionはraw CMake textには適用しない。libuvの[追加告知](https://raw.githubusercontent.com/libuv/libuv/e9f29cb984231524e3931aa0ae2c5dae1a32884e/LICENSE-extra)は別path由来のBSD-2-Clause／ISC等も列挙するが、これらを選定CMakeLists.txtの第三者コードと結び付ける証拠はない。取得した3 fileは固定commit・root pathのmetadata sizeと実測byte数が一致し、fmt／Catch2はfile内license／copyright markerなし、libuvは`LICENSE`と`LICENSE-extra`のinstall行のみを含む。header確認は著作権者の完全な特定ではない。3 familyは異なるprojectだが、全てC/C++ projectのroot CMake設定でbuild-system構文の相関を含む。

ZIP候補はcontainer全bytesを比較する案である。2026-10-16のrights-only reviewで、attrs wheelの`attrs-23.2.0.dist-info/METADATA`（9,531 B, SHA-256 `5b0bc6ece1f22a310fa72154642098b759f413f09ca9d45bedb96218475c9be0`）はMIT `License-Expression`／`License-File: LICENSE`を示し、同梱`licenses/LICENSE`は1,109 B（`882115c95dfc2af1eeb6714f8ec6d5cbcabf667caff8729f42420da63f714e9f`）。JUnit JARは`META-INF/LICENSE.md`（14,235 B, `5aa4cd44c111add178d1c2e2fe36d58a484012c80167df925f826cd64d411bf0`）にEPL-2.0、`META-INF/LICENSE-notice.md`（316 B, `c7d843e0faf8a251278c9220f6b5326a42a01f08b855c1ec871bcef6211a7e2a`）に別条件の下位componentが含まれ得る旨がある。Newtonsoft.Json nupkgは`LICENSE.md`（1,104 B, `b98a397897ff55f76cddc380041507a95a896b2946e0188703bf0496793d6516`）と`Newtonsoft.Json.nuspec`（2,413 B, `64aeffca22289eeb3bd32cbe72722ac878d2eadcee9f8885f17daa2e8357c518`）を含み、NUSPECのlicense expressionはMITである。権利語を含むentry名のscanではこれら以外のlicense／notice／copying／copyright／EULA entryを検出しなかったが、これは通常member内に第三者成分がない証明ではなく、JUnitのsubcomponent scopeも未解決である。通常member、class／code本文は読まず、権利情報entryだけを読んだ。3 containerはZIP系packageでSQLite release ZIPとも形式相関するため、結果は圧縮済みcontainer間に限定する。3 raw archiveはTaskArtifactsの`UnLhaRe\01a0b076-4e26-7a71-ac35-32ed9259a871\zip-candidate-inputs-20261016\`へ同一size／SHA-256で保全し、Temp原本も残した。rights scopeは暫定のままである。

したがってJSON／source code／tiny／ZIPの各3件は候補として維持するが、全categoryのfamily prior-use auditと候補recipe・評価基準の固定、最終manifest凍結は未完了である。source code／tinyの限定scanとZIPのrights-only entry reviewは証拠として記録し、未解決のsubcomponent／個別provenanceはrights clearance済みと扱わない。これらは異なるprojectでも、共通file format・generator・コード構造による相関を含む。候補選択・recipe・notice確認・byte/hash identityを揃えるまではholdout compressionへ進まない。

一致テーマのPlumivox/X全体検索（`ESLint Prettier CLDR license`、`Caddy DuckDB Tree-sitter license`、`fmt Catch2 libuv license CMake`、`attrs JUnit Newtonsoft license package`）も実施したが、各queryは0件だった。これは非網羅検索であり、投稿・情報の不存在根拠には使わない。

similar-version候補はXZ Utils 5.6.3/5.6.4の`.tar.xz`、libarchive 3.7.6/3.7.7の`.tar.xz`、SQLite tools 3.46.0/3.46.1のWindows ZIPで、release artifact全bytesを各version pair 1 caseとする案である。XZの[5.6.4 COPYING](https://raw.githubusercontent.com/tukaani-project/xz/v5.6.4/COPYING)は主要部分0BSDのほか、GNU getoptのLGPLv2.1+、gzip由来scriptsのGPLv2+、Autotools build filesのGPL/permissive等、複数条件を明示する。libarchiveの[3.7.7 COPYING](https://raw.githubusercontent.com/libarchive/libarchive/v3.7.7/COPYING)は配布物全体に複数条件があるとし、個々のfile内の表示を優先する。SQLiteは[公式copyright説明](https://sqlite.org/copyright.html)でコード・文書のpublic-domain dedicationを示す一方、選定したtools ZIP全体のmember・build補助・告知対応は未確認である。2026-10-16に公式release URLから6件全てを取得。実byte数・SHA-256はXZ Utils 5.6.3 1,328,224 B `db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a`、5.6.4 1,340,516 B `829ccfe79d769748f7557e7a4429a64d06858e27e1e362e25d01ab7b931d9c95`、libarchive 3.7.6 5,458,552 B `0a2efdcb185da2eb1e7cd8421434cb9a6119f72417a13335cca378d476fd3ba0`、3.7.7 5,480,580 B `879acd83c3399c7caaee73fe5f7418e06087ab2aaf40af3e99b9e29beb29faee`、SQLite tools 3.46.0 5,035,461 B `adbefda5f92d471cbde9cb3232775485bd1bad61ba97376c9661c37dfd6ad027`、3.46.1 5,036,925 B `c86c0fe0b0b46cfaac40812a26c958bbf2378b6ef9d784d6354d9f5bd66e566b`。XZ先頭6 byteはmagic `FD 37 7A 58 5A 00`、ZIP先頭4 byteはlocal-file signature `50 4B 03 04`と一致する。これはarchive全体のdecode・完全性・内包noticeを検証したものではない。いずれも展開・一覧表示・実行・再圧縮・比較はしていない。配布物内告知の完全性とrights clearanceは未解決のままにする。

各version pair内は同じprojectの近縁releaseで強く相関し、XZとlibarchiveはともに既圧縮`.tar.xz`、SQLite ZIPは他のZIP container候補と形式が重なる。これは圧縮済みrelease-container群の比較に限定され、展開後の未圧縮sourceやbinaryのversion類似度とは別である。Plumivox/X全体検索`XZ Utils libarchive SQLite release`は0件だったが非網羅であり、不在根拠にはしない。6件のraw artifactの実byte数・SHA-256・基本magicは照合済みだが、archive memberのnotice／license全体を読んでおらず、rights clearance・manifest凍結・未使用family監査は未完了である。

## JPEG候補のrights・identity監査 — 2026-10-16

Met object 436535の公式APIは`isPublicDomain=true`と、候補URL `DP-42549-001.jpg`を`primaryImage`として同時に示し、館の[利用規約](https://www.metmuseum.org/policies/terms-and-conditions)はOpen Access画像をCC0とする。Cleveland object 94979の公式APIは候補URL `1915.534_web.jpg`を`images.web`として特定し、`share_license_status=CC0`を示す。[Cleveland規約](https://www.clevelandart.org/terms-and-conditions)はCC0をデジタル化したpublic-domain作品の画像にも適用すると説明するが、第三者権利を保証しない。Getty object 103RJMのJSON-LDは対象UUIDとサイズ指定URLを`thumbnailUrl`として列挙し、Painting recordに`license=CC0`・画像のcredit textを記録する。したがって選定画像との対応は支持されるが、`license`は独立したImageObjectのpropertyではない。Getty [Open Content FAQ](https://www.getty.edu/projects/open-content-program/faqs/)はOpen ContentのCC0と第三者権利の非保証を説明し、表示を残す場合は`Digital image courtesy of Getty’s Open Content Program.`を推奨する。関連する個別recordは[Met 436535 API](https://collectionapi.metmuseum.org/public/collection/v1/objects/436535)、[Cleveland 94979 API](https://openaccess-api.clevelandart.org/api/artworks/94979)、[Getty 103RJM](https://www.getty.edu/art/collection/object/103RJM)である。

固定JPEGを2026-10-16に取得した。実byte数とSHA-256はMet 436535 `DP-42549-001.jpg` 8,291,194 B `b46d02a42fd3bb13b022cefc5beaa997b1d7a28cd7b53e4413d940aa0dc4014d`、Cleveland 94979 `1915.534_web.jpg` 405,819 B `f370be05796fafde9609f5567e35f16aecbf87537b86a526262694abbce0fa2a`、Getty 103RJM `default.jpg` 28,366 B `1edd49aa8719ff5d80c55b6b14bb044d18b704eb7ac8de5b20e4eb1e5fcb043d`。Cleveland API filesize 402,404 Bと取得実bytes 405,819 Bは不一致。GettyのHEADに長さはなかったが、GETは成功した。3候補は異なる画家・作品・館の画像だが、すべて絵画のデジタル画像であり、一般的なJPEGや写真への代表性を主張しない。館のrights statementsも第三者の全権利を保証しないため、作者・作品名・館・識別番号・元record URLと各credit lineをprovenanceとして保持する。raw取得後も画像を表示・展開・変換・圧縮・計測していない。manifestは未凍結。

Plumivox/X全体検索はGetty Open Content、Cleveland Museum CC0、Met Open Accessの3語句を個別に確認した。Met queryでは一般利用者の関連投稿が1件返り、他2 queryは0件だった。いずれも個別権利の根拠に使わず、0件から投稿不存在は推定しない。固定画像URLへのHEADに加え、2026-10-16にGET・保存・SHA-256算出を行った。画像表示・decode・変換・圧縮・benchmarkはしていない。

## 2026-10-16時点のGOAL状態

KHC revision 7 / KCS1は製品API・CLIへ統合済みで、3 file（1 MiB file・空file・短file）のAPI/CLI create/list/test/extract、byte/SHA往復、no-replace、破損拒否を含む有限registered E2Eに合格している。追補run `dd7ef525c092448299644a4d37183656` はrevision 1〜6を各対応strategyで同一build内create/test/extractし、全byte復元を確認、revision 6のframe magicが`KRS2BLK\0`であることも確認した（API 9 normal / 28 malformed + 28 same-process recovery / 5 malformed archives）。これは同一実装内の有限read-path確認であり、旧binary製の凍結archiveを使った独立互換検証ではない。run report SHA-256 `2d30377f2844bccf4abe86582f754d39c2721e30d27c48e101e7cf17c0cd6347`、保全ZIP SHA-256 `914f84d4d00ca721cbb186685e83feea4bbce7949b01dbdf74db8f8318e77dfd`、manifest SHA-256 `c94c8c12256b852b6c93de9f16e292fffbe9dbceebb164cae047c7ad5a3618f6`。Prunlet段階清掃はoperation `798e0694d69e4c8ebabe6cb00783a39a`で完了し、Temp work不在・pending 0を確認。これは安全性・統合の証拠であり、性能優位ではない。ptt5製品screenは上の固定入力・設定で事前登録済み。2026-10-16 06:57 JST時点の5×1秒総CPU sampleは`[20.3, 36.6, 16.5, 52.1, 16.8]%`で全て15%基準を超えたため、screenは未起動である。この前の同turn sampleも`[25.3, 40.9, 19.5, 23.2, 22.2]%`で全て閾値超過だった。次回実行前にCPUと固定資源・hash preflightを再確認する。holdout suite、7-Zip最終判定、全カテゴリの性能評価とWindows/macOS x64/ARM64 native検証が残っており、本GOALは未完了である。

追記：2026-10-16 07:04 JSTに採取した次の5×1秒総CPU sampleは`[33.8, 31.9, 41.4, 41.4, 27.6]%`で全て15%を超過した。ptt5 screenは引き続き未起動であり、実行直前に新しいsampleと固定資源・hash preflightが必要である。

追記：2026-10-16 07:13 JSTの新しい5×1秒総CPU sampleは`[21.1, 20.2, 20.6, 20.2, 18.1]%`で全て15%を超過した。ptt5製品screenは未登録・未起動のままである。

追記：2026-10-16 07:23 JSTの新しい5×1秒総CPU sampleは`[13.4, 18.2, 18.4, 16.7, 16.9]%`だった。5 sampleすべてが15%以下ではないため、次のptt5 screenは開始していない。性能測定結果は追加されていない。

追記：2026-10-16 07:43 JSTの新しい5×1秒総CPU sampleは`[28.9, 38.9, 42.7, 30.1, 32.5]%`で全て15%を超過した。ptt5 product screenは開始しておらず、性能測定結果は追加されていない。

追記：2026-10-16 07:53 JSTの新しい5×1秒総CPU sampleは`[34.7, 27.5, 28.1, 25.1, 47.7]%`で全て15%を超過した。ptt5 product screenは開始しておらず、性能測定結果は追加されていない。

追記：2026-10-16 08:03:32 JSTの5×1秒総CPU sampleは`[35.6, 37.8, 22.2, 20.3, 21.5]%`で、15%ゲート不合格だった。ptt5製品screenは起動しておらず、性能測定結果は追加されていない。

追記：2026-10-16 08:13:45〜08:13:51 JSTの5×1秒総CPU sampleは`[57, 32, 31, 22, 74]%`で、5件すべて15%を超過した。ptt5製品screenは起動しておらず、性能測定結果は追加されていない。

追記：2026-10-16 08:42:06 JSTの5×1秒総CPU sampleは`[26, 9, 11, 14, 15]%`で、全件15%以下の条件を満たさなかった。ptt5製品screenは起動しておらず、性能測定結果は追加されていない。

## 最新文献の追補 — 2026-10-15

| 候補 | 仕組みと報告値 | 条件・弱点とUnLhaReでの判断 |
| --- | --- | --- |
| Nacrith: neural LM＋token n-gram＋adaptive skip＋32-bit arithmetic coder | 135M SmolLM2をFP32で使い、CDF総数を2^24へ広げる。著者はalice29.txtで17,458B (0.918 bpb)、2025年公開の英国政府報告から作った333,794BのOOD textで30,171B (0.723 bpb)を報告。後者では同一モデルのFineZip 40,747B、zstd -19 79,709Bより小さい。[^15] | 実験はGTX 1050 Ti、モデル重み約500MB、約1.2GB VRAM/worker、steady-state約20–30 token/s。7-Zipとの比較はなく、表は重みを除外。alice29/enwik8は学習データに含まれる可能性を著者自身が認める。コードとSmolLM2はApache-2.0表記だが、model配布・実行依存・GPU要件を含む総費用と4環境の再現性が未検証。単一ファイルへ重みを含めると報告対象より大きくなり、UnLhaReの自己完結CPU形式の本線には選ばない。共有インストール費用を別途明記するテキスト専用比較候補に限る。[^16][^17] |

同論文の「0/1/2次byte entropyより小さい」という記載は、有限次数のbyte n-gram統計が長距離の構文・意味依存を捉えないためであり、Shannon限界違反ではない。著者のH2を有限次数モデルの参照値として扱う解釈は妥当で、情報理論上の真の下限と混同しない。[^15]

**選定への影響:** CDF-24だけの利得をUnLhaReへ移植できる根拠はない。既存KHCはより小さいbyte alphabetの整数rANS/CDFを使い、Nacrithの主な利点は外部LLMの長文脈予測とtoken n-gram skipに結び付くためである。実装候補へ進める前に、モデル全費用を含む7-Zip比較・CPU/全対象環境の速度とメモリ・決定的復号を測る必要がある。したがって本追補は候補の調査であり、7-Zip優位やUnLhaRe統合の証拠ではない。

## RecordFastの製品書庫screen — 2026-10-15

Canterbury `ptt5`（513,216 bytes、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）をWindows x64で比較した。KHCは同一のRelease CLI（SHA-256 `d6728e3e40057ca1f4505afd8d17ec6b5076e47e2c445ed3c1334c68da889c84`）、7-Zipは26.04 x64（exe SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`）。各runは3回ずつ、完全書庫サイズとSHA-256、KHC/7-Zipのarchive test、全byte復元とSHA-256、起動・I/O込みencode/extract時間、高水位メモリを確認した。2回目は方式順を各位置へ一度ずつ回転した。両runとも37子コマンドが全て成功し、各方式の書庫はrun内で決定的、KRS2は3/3回選択された。

7-Zipには`-mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`を指定し、file時刻メタデータを無効にした。`-slt`の実効methodは`LZMA2:19`、すなわちこの小入力では512 KiB dictionaryだった。64 MiBは要求上限で、64 MiBを実際に使った比較ではない。時間は書庫作成と展開の個別プロセス起動・I/Oを含む。testは復元前に別途実行し、その時間はencode/decode欄に含めない。

| 方式 | 完全書庫 (B) | encode中央値 固定順 (ms) | encode中央値 順序回転 (ms) | extract中央値 固定順 (ms) | extract中央値 順序回転 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC BinaryAdaptive (revision 2) | 56,047 | 85.8281 | 94.0065 | 76.1697 | 75.9573 |
| KHC RecordFastTrial / KRS2 (revision 6) | 46,274 | 96.1565 | 90.1851 | 58.1426 | 66.0387 |
| 7-Zip 26.04 7z/LZMA2 | 42,199 | 162.8654 | 164.1892 | 96.2257 | 81.9857 |

各方式の2run×3反復、encodeとextractそれぞれ6プロセスで観測した最大値（WSはWorkingSet、pagedは`PeakPagedMemorySize64`）：

| 方式 | 最大WS encode/decode (B) | 最大paged encode/decode (B) |
| --- | ---: | ---: |
| BinaryAdaptive | 8,343,552 / 5,902,336 | 5,439,488 / 1,568,768 |
| RecordFastTrial / KRS2 | 8,339,456 / 5,419,008 | 5,459,968 / 1,409,024 |
| 7-Zip | 14,331,904 / 8,376,320 | 10,326,016 / 2,183,168 |

KRS2はこの入力でBinaryAdaptiveより9,773 bytes（17.43%）小さく、2 runとも7-Zipより短いencode/extract時間を観測した。一方、完全書庫は7-Zipより4,075 bytes（9.66%）大きい。従ってこの一ファイルでは圧縮率の目標を満たさず、総合的に7-Zipを置き換える候補として採用しない。時間差は小さな単一データ・Windows x64だけのscreenであり、他形式・OS・CPUへ一般化しない。strategyと既定値は変更していない。

方式順回転runのKRS2 frameはheader 40B + model 1,976B + schedule 5B + rANS payload 44,181B = 46,202Bで、archiveのmanifest/header/file CRCはさらに72Bだった。今回のサイズ不足はscheduleではなくmodel/payload領域にあり、scheduleだけの削減を次の候補理由にしない。

再現用の方式順回転runは`96fcbb50077d4a9eb69b81e457a6ad77`。保全`recovery.zip`のSHA-256は`0976ae791445749a54cb751c680519eab08aa5146f57903689c3638606d7647d`、内部reportは69,470 bytes / SHA-256 `126d45488105e2f688fb90d6420257fc1cb2b4c751d175cd4af19862d8269fac`。固定順の先行runは`93aa74eeec0643f6a4fe82d00b1b5abf`。両reportはstorage lifecycleに保全し、Temp作業rootはPrunlet staged cleanup後に消失・purgeを確認した。

## Canterbury prose pairの製品書庫screen — 2026-10-15

既知の開発データである`lcet10.txt`（426,754 bytes、SHA-256 `5314ba1dbb03f471df88bec6cd120a938ef60d0fd3511c5c1dce61bf7463245f`）と`plrabn12.txt`（481,861 bytes、SHA-256 `07e2e0b461af78c7c647cb53dab39de560198e16f799b4516eccf0fbd69f764c`）を、Windows x64上で完全書庫として比較した。合計入力は908,615 bytes。KHCは上記のRelease CLI（SHA-256 `d6728e3e40057ca1f4505afd8d17ec6b5076e47e2c445ed3c1334c68da889c84`）、7-Zipは26.04 x64（exe SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`）。公式配布ページでは26.04を2026-10-05版として掲載している（[7-Zip公式](https://www.7-zip.org/)）。方式ごとに3回測定し、起動・I/O込みのencode/extract時間、WSと`PeakPagedMemorySize64`、完全書庫サイズ・SHA、archive test、展開後の全byte/SHA一致を記録した。全9 sampleでarchive testと復元一致に成功し、各方式の書庫hashは3回で一定だった。

7-Zipの設定は`-mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`、file時刻メタデータ無効。要求辞書は64 MiBだが、各書庫の実効methodは`LZMA2:20`、実効dictionaryは1,048,576 bytes（1 MiB）だった。入力合計が888 KiBのこのscreenで64 MiB辞書を使った比較ではない。KHC CLIは`--strategy binary-adaptive`と`--strategy record-fast-trial`を使い、どちらもrevision 2の`KHC1BLK` frameを2つ出力した。RecordFastTrialではKRS2は選択されず、BinaryAdaptiveと同じ書庫サイズだった。

| 方式 | 完全書庫 (B) | encode中央値 (ms) | extract中央値 (ms) | 最大WS encode/decode (B) | 最大paged encode/decode (B) |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC BinaryAdaptive | 252,471 | 324.001 | 117.172 | 28,250,112 / 8,699,904 | 24,670,208 / 5,242,880 |
| KHC RecordFastTrial | 252,471 | 363.866 | 100.134 | 28,303,360 / 8,716,288 | 24,678,400 / 5,234,688 |
| 7-Zip 26.04 7z/LZMA2 | 282,852 | 371.338 | 89.561 | 19,030,016 / 9,052,160 | 14,540,800 / 2,854,912 |

KHC両strategyは7-Zipより30,381 bytes（10.74%）小さい完全書庫だった。BinaryAdaptiveのencode中央値は短い一方、extract中央値は7-Zipより遅く、encode時の最大WS/pagedも大きい。RecordFastTrialのextractはBinaryAdaptiveより短いが、7-Zipより遅く、書庫サイズは同じである。従ってサイズの改善だけでは、同程度の処理時間・メモリ条件での7-Zip優位を満たさず、strategyも既定値も変更しない。この2ファイルの既知Canterbury screenを未見データや一般的優位の根拠にしない。

再現・監査用runは`57151f4ddedc4e2894a6da3aecd5afa5`。保全`recovery.zip`（7,760,534 bytes）のSHA-256は`b9c40c5b21c22b1ea4afdf214e65d882756c1e64497c1f1a90bc307aa14aec1d`、内部`record-fast-7zip-screen.json`（75,120 bytes）のSHA-256は`3f2a34f790c83f77fb6561bdb6d0e5cc56b37d1302fa38cb8e24ee2c49ac95f1`。ZIPにはreport、入力、3回分の各書庫・展開結果が含まれる。

## Dense履歴ページ遅延割当の追試 — 2026-10-15

`Dense`の全履歴行を最初にzero-fillする13,959,168-byte配列を、`(component,node,k)`ごとに初回記録時だけ1024履歴分を確保するページへ変更した。形式・頻度値・符号器の選択は変えない。上記と同じ入力hash、7-Zip実行ファイル、圧縮設定を使い、変更前CLI（SHA-256 `d6728e3e40057ca1f4505afd8d17ec6b5076e47e2c445ed3c1334c68da889c84`）と変更後Release CLI（SHA-256 `acb57ca6fed5ab1bd7d722f29f171a279a40bc8ba538c7398888043aea9c1bd4`）を各3回screenした。7-Zipは同一の26.04 x64（SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`）。9 sample全てarchive test、完全展開と入力SHA一致に成功し、run内の方式別書庫は決定的だった。

7-Zip設定は前screenと同じ`-mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`（時刻メタデータ無効）。実効methodは`LZMA2:20`、dictionaryは1 MiBであり、64 MiBを実際に使った比較ではない。KRS2は0/3回選択されず、RecordFastTrialもBinaryAdaptiveと同じKHC1BLK frameへfallbackした。

| 方式（変更後run） | 完全書庫 (B) | encode中央値 (ms) | extract中央値 (ms) | 最大WS encode/decode (B) | 最大paged encode/decode (B) |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC BinaryAdaptive | 252,471 | 361.880 | 126.652 | 17,346,560 / 8,708,096 | 13,725,696 / 5,226,496 |
| KHC RecordFastTrial | 252,471 | 374.582 | 118.509 | 17,408,000 / 8,716,288 | 13,697,024 / 5,218,304 |
| 7-Zip 26.04 7z/LZMA2 | 282,852 | 428.612 | 101.827 | 19,038,208 / 9,048,064 | 14,540,800 / 2,846,720 |

同一入力の変更前screenに対し、BinaryAdaptiveのencode最大WS/pagedは28,250,112 / 24,670,208 bytesから17,346,560 / 13,725,696 bytesへ（38.60% / 44.36%減）、RecordFastTrialは28,303,360 / 24,678,400 bytesから17,408,000 / 13,697,024 bytesへ（38.49% / 44.50%減）となった。変更後runではKHC最大encode WS/pagedが7-Zipより8.56% / 5.61%低く、完全書庫は30,381 bytes（10.74%）小さい。一方、BinaryAdaptiveのextract中央値は7-Zipより24.38%遅く、RecordFastTrialは16.38%遅い。現screen内のencode中央値はそれぞれ7-Zipより15.57% / 12.61%短い。

変更前後でKHCの全書庫SHA-256は一致しなかったため、全書庫のbyte同一とは扱わない。ただし2方式・2入力の各KHC frameは長さとSHA-256が全て一致した（`lcet10.txt`: 106,821 bytes / `d6de2961bb2dfa669329dc7be6807ce1c1a88b116cafe5902b564e4c4ba654f1`; `plrabn12.txt`: 145,532 bytes / `9287f5e9db6317ca31c3ba606a73a71ecbaadf5336a5378ee38bf36590e61351`）。同一7-Zip実行ファイルのencode/decode中央値も変更前後で+15.42% / +13.69%動いているため、screen間の絶対時間差から今回の変更による速度回帰を主張しない。

この結果は全zero-fillを避けるメモリ改善の実測であり、新しい圧縮方式や一般性能の証明ではない。既知の開発用Canterbury pairであり、BinaryAdaptive/RecordFastTrialのstrategy・既定値を変えず、7-Zip優位のGOALは未達のままとする。

再現runは`26a0516a42ec4fcdacc6abdf02835f72`。保全`recovery.zip`のSHA-256は`6d5d17d34745827d69aec126d13923ea7df83ad11e099fa2dd2a8a9ad232a81c`、manifest SHA-256は`dcf7eecd6b3073bafdd199946f8bfa5598408dc63404d6dff2fff7b2d4c9aa4d`、内部screen reportは75,565 bytes / SHA-256 `e76d6cc8cac50212c6edea2f4c60f53266350fd53bc9b102e283ce4b604b40f8`。登録workの11,525,097 bytesはPrunletのdelete・purge・finalizeまで完了し、Temp残量0 bytesを確認した。

## Canterbury11製品書庫のサイズscreen — 2026-10-16

固定Canterbury11（11 files、2,810,784 bytes、manifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`）を製品 `khc-create --strategy binary-adaptive` と7-Zip 26.04 x64で別々の登録runから書庫化した。両reportのmanifestは一致し、7-Zip archive testと11 filesの名前・全byte・SHA-256復元検査は成功した。製品KHCは466,395 bytes（SHA-256 `0dcb76a2e1721504c28b13de38e05eca737c1b49423e83b6b345f3e8fa0a46a8`）、7-Zip solid 7zは483,599 bytes（SHA-256 `ea8b4b785c245001ab0e0fb5aa0a21d0339cdf74d8d62d5ccdee75b5f1b8e4299`）で、KHCが17,204 bytes（7-Zip比3.557%）小さい。

7-Zipには`-mx=9 -m0=LZMA2:d=64m -mmt=1 -ms=on -mqs=off`を指定し、mtime/ctime/atimeを無効にした。64 MiBは要求上限であり、このscreenは実効method/dictionary、処理時間、メモリを測っていない。サイズと完全復元だけの単一Canterbury screenで、一般優位や速度・memory一致条件での勝利を示さない。製品run `5bcfd544613c4752a1d2fcd04e3185e1` のrecovery ZIP SHA-256は`9cead2493632dce55f4f4c82583f44b85ed0ad1110c53fe6682acae8aac2b567`、7-Zip screen run `39565aef1c1a4623969830bf01e29262` のrecovery ZIP SHA-256は`f56a981dd436a19296ad959b2a851e0b2ad911106708d57cd524b1cf77f9cfa4`。後者のKHSGRP0 group frame 483,130 bytesは実験用別形式のため、製品書庫比較へ混ぜない。

## RangeSlot slot再利用screen — 2026-10-16

MDL token復号でCDF選択前に求めたslot/unitを選択後にも使う候補を、同じ既知Canterbury pairで各3回screenした。baseline Release CLI SHA-256 `19df553adbaed368fbb979e385a337a863b038733b4251d4bc4eb83bf427ce8c` に対するcandidate SHA-256 `f97c9a7854452dfb216ae8b430274d8ffeddcc44681dec82236260834003d809`、screen script SHA-256 `f67e6f6a1c825294f5c78c1dcbe56165ca3ec8927d33f74c3a310ee12b47f07a`。入力は前記と同じ `lcet10.txt` / `plrabn12.txt`（元入力ZIP SHA-256 `b9c40c5b21c22b1ea4afdf214e65d882756c1e64497c1f1a90bc307aa14aec1d`）。比較の7-Zipは両runで同じ26.04 x64、実行ファイルSHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`。

| 方式 | encode中央値 (ms) baseline → candidate | extract中央値 (ms) baseline → candidate | 書庫bytes baseline → candidate |
| --- | ---: | ---: | ---: |
| KHC BinaryAdaptive | 351.945 → 331.417 | 102.576 → 129.331 | 252,471 → 252,471 |
| KHC RecordFastTrial | 334.438 → 349.364 | 126.246 → 114.956 | 252,471 → 252,471 |
| 7-Zip 26.04 control | 360.530 → 381.424 | 80.266 → 108.001 | 282,852 → 282,852 |

baseline/candidateそれぞれでKHC 2 strategyと7-Zip controlを3回ずつ実行し、全18回でarchive test・全byte/hash復元確認が成功した。各run内で方式別の書庫サイズとhashは決定的だった。KHC frame長はbaseline/candidateとも`lcet10.txt`が106,821 bytes、`plrabn12.txt`が145,532 bytesのままだった。Peak working-set / pagefileの3回中央値は、BinaryAdaptive encodeが17,321,984 / 13,758,464 → 17,305,600 / 13,684,736 bytes、extractが8,695,808 / 5,218,304 → 8,704,000 / 5,230,592 bytes。RecordFastTrial encodeは17,068,032 / 13,643,776 → 17,096,704 / 13,639,680 bytes、extractは8,699,904 / 5,222,400 → 8,056,832 / 4,038,656 bytesだった。

速度は方式ごとに改善と悪化が分かれ、同じ7-Zip controlでもencode中央値が5.8%、extract中央値が34.6%変動した。memory差も方式・方向で一貫せず、このscreenからRangeSlot候補の速度・memory改善は認定しない。入力規模・既知corpusの制約もあり、実利用全般の優位を示さない。baseline run `4cc28c3895914e7abe1531ec0904cdb5` のrecovery ZIP SHA-256は`de33272b411dd2f135a4e34fdaf480ee6de8c6cf8565853d1aa8fb9b8f2ae9fa`、reportは74,675 bytes / SHA-256 `2f5c34d5347fd25438f67ed560e289c05da9ccb66358ff07832a0855414684dc`。candidate run `b1a9eed9c3624ca8aa4d1a4a018bfec4` のrecovery ZIP SHA-256は`7db7a98e09f9b186648502addda3006025b0961100ddcdbca57208e4762a72e3`、reportは74,692 bytes / SHA-256 `85cfc22d2317df86b1b2c80c08d97e358dd5ea7c9a274b445d9e9009e5de3087`。

## ptt5単体の7-Zip screen — 2026-10-16 JST（run UTC 2026-10-15）

既知Canterbury corpusの`ptt5` 1件（513,216 bytes、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）を、現行Release CLIと7-Zip 26.04 x64で各3回圧縮・展開した。全9サンプルで終了コードと復元byte/hashを確認し、各方式のarchive hashも決定的だった。時間はプロセス起動・I/O込みの中央値、memoryはOSが報告した各方向の最大working-set / pagefile値。

| 方式 | encode中央値 (ms) | extract中央値 (ms) | archive bytes | encode最大WS / pagefile (bytes) | extract最大WS / pagefile (bytes) |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC BinaryAdaptive | 83.7878 | 71.7535 | 56,047 | 8,310,784 / 5,451,776 | 5,894,144 / 1,568,768 |
| KHC RecordFastTrial（KRS2選択） | 116.0318 | 66.6460 | 46,274 | 8,323,072 / 5,443,584 | 5,750,784 / 1,478,656 |
| 7-Zip 26.04 LZMA2、1 thread、solid | 164.2801 | 102.6876 | 42,199 | 15,020,032 / 10,321,920 | 8,388,608 / 2,179,072 |

この1ファイルscreenでは両KHC方式の処理時間とOS process peakは小さい一方、RecordFastTrialの書庫は7-Zipより4,075 bytes（9.66%）大きく、BinaryAdaptiveはさらに大きい。7-Zipへ64 MiB辞書を要求したが、この入力でreportが記録した実効辞書は512 KiB。小規模・既知データ1件、各3回のscreenであり、一般的な速度・memory・圧縮率の優位や同等条件での総合勝利は主張しない。

Release CLI SHA-256 `24e5210620c2dbcb4481eef51fc36e6f374ea5b03ed3a194b00d5f7e0c6d5368`、7-Zip executable SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`。run `fbde36e56d8e462ca7ca1a3489b4f37c` のrecovery ZIP SHA-256は`8effa8411fed15c208ec9abea773535bfdbacd52e36d934e167097f7eaddfb89`、reportは69,499 bytes / SHA-256 `8fa853e008c84648417f3e0ce28eb2f09392343f95ea4559e731f85fee82fe4c`。

## KCS1 copy＋literal空間bitの固定ptt5試作 — 2026-10-16

既存KRS2のcopy文法を保ち、不一致literalのXOR残差だけを空間context付きbitで符号化する独立block候補KCS1を試作した。固定ptt5（513,216 bytes、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）の完全frameは39,889 bytes（40-byte header + 677-byte count CDF + 39,172-byte range payload）で、同一runの既存KRS2完全frame 46,202 bytesより6,313 bytes（13.6639%）小さい。copy 470,629 bytes・literal 42,587 bytesは既存censusと一致し、frame SHA-256は`8be3ad9895bef596223d056659f8e851ce55c041859a26a8d418ce7ec8e9205a`。

正常10ケースで完全往復と決定性、27個の破損frame拒否と同一processでの27回復、ptt5全byte/SHA復元を確認した。Rust codec/native E2EとKRS2比較コマンドはexit 0だが、登録runner全体は終了時にMSVC linker由来`VCTIP.EXE`がJob内に残ったためexit 1となった。runnerはこれを成功扱いせずJob停止・保全へ進み、清掃はPrunlet経路で完了した。よって候補frameの有限E2E/サイズscreenは観測したが、runnerの完全成功とは記録しない。

このstandalone screenの時点では候補はまだKHC書庫へ統合していなかった。その後revision 7として製品CLI/APIへ統合したが、以下の事前登録screenを含め、公平な製品pipeline比較は別途評価する。過去の同じptt5書庫値（KHC 46,274 bytes、7-Zip 26.04 42,199 bytes）は候補書庫の実測ではなく、frame比較にも7-Zip総合優位にも転用しない。候補の単発内部時間encode 9.1902 ms / decode 6.3693 ms、native process peak working set 7,458,816 bytesは公平な製品pipeline比較ではないため、速度・memoryの優位は未確認。詳細と再検証用保全hashは[`causal-row-copy-spatial-bits/RESULT_20261016.md`](causal-row-copy-spatial-bits/RESULT_20261016.md)。

## SpatialBits製品書庫screenの事前登録 — 2026-10-16

計測開始前に固定する対象は、製品CLIの`spatial-bits-trial`（KHC revision 7 / KCS1）と`record-fast-trial`（revision 6 / KRS2）、および7-Zip 26.04 x64の3方式である。入力は既知の開発データだけとし、既存recovery ZIP SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` の`input/ptt5`（513,216 bytes、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）に固定する。holdoutではなく、候補調整・選択を終えるための評価にも使わない。

各方式は同じ1ファイルを使い、1 warmup（各方式1回、round 0）後、9 measured roundを同一sessionで実行する。warmupも全標本・archive hashを記録するが集計から除外する。方式順はround 1–9の順に`BCA / BAC / ABC / ACB / CAB / CBA / BCA / BAC / ABC`（A=SpatialBits、B=RecordFast、C=7-Zip）とし、各方式が各位置へ3回ずつ入るよう固定する。すべての作成・完全decode/CRC検証の直前にWindows `_Total` CPUを採取し、15%超過または取得不能なら再試行せず中断する。

作成と完全decode/CRC検証を別々に計時する。wallにはprocess起動・I/O・標準出力/エラーの回収を含め、各commandを30秒で制限する。decode測定はKHC `khc-test`と7-Zip `t`であり、filesystem展開速度とは解釈しない。各timed processのCPU時間、OS peak working set、peak paged memoryも保存し、OS memory値が得られないsampleは成功扱いしない。各方式の全10書庫は同一byte/SHA-256であることを確認し、最後の書庫を各方式1回だけ展開して入力との長さ・SHA-256一致を検査する。

7-Zipは実行前後のhashとruntime versionを確認する。実行ファイルは`C:\Program Files\7-Zip\7z.exe`、FileVersion 26.04、SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`。作成argvは`a -t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off -spd -sccUTF-8 <archive> -- .\ptt5`とし、実効LZMA2 method/dictionaryも記録する。

登録workは5 MiB / 64 entries / 300秒に固定し、archive各64 KiB、JSON report 512 KiBを上限とする。機能上の成功条件は固定入力・tool hash、形式revision、各commandのexit code、決定性と最終byte/SHA復元の一致である。実行基盤はPowerShell 7.6.5、screen script SHA-256 `b36133ada52792d1f91c0902a28deff69840ed01e80d8fde4d92f4d98a05d567`、登録runner SHA-256 `ade2afd0605d81297d2571477f1930bf805c57c1c123e719986a75db71482eea`、lifecycle module SHA-256 `8ee659a121897bb3c9a5c30659f293a42bf13329ee9d186e53f771941ce65ca4`に固定する。事前に圧縮率・速度・memoryの勝利閾値は設けず、結果はこの開発入力1件における記述的screenとして報告する。holdoutや一般的優位性、7-Zip置換の証拠とは扱わない。

## ptt5製品screenのCPU中断 — 2026-10-16

固定5 MiB / 64 entries / 300秒の登録screenは、全preregistered hash・入力SHA/長さ・16 MiB storage reservationが一致した後に開始した。直前の外部5×1秒CPU sample（2026-10-16 07:19 JST）は`[11.6, 11.4, 7.9, 12.9, 11.8]%`だったが、screen自身の最初のcreate直前sampleが65%となり、`0-spatial-bits-trial-create`でfail-closedした。reportは`status=failed`、sample count 0で、比較・速度・sizeの計測値はない。自動再試行はしない。

run `0fb3acace494461085f887efdfe80017`はPrunlet direct-CMD preview/delete/preview/purge/finalize後に`complete`、work directory不在・after bytes 0。recovery ZIP（86,509 B、SHA-256 `cd1e918922a90a356bc1ccb780781602a23d4537412a705bde9fd591c2c0cb43`）とmanifest SHA-256 `07aff063ee0b704d14b92d32d9d3056cc41de639e32cb4834fd6c21bb05327aa`を保持し、ZIP内`spatial-bits-product-screen.json` SHA-256は`c41bab175737a9ec6841eab0e12bea3416f1d17fd57ded5a1c0bc01e1132f9cd`である。これは既知development inputのCPU guard失敗であり、holdout・7-Zip性能判断ではない。

## KCS1 ptt5 screen の実行環境差分 — 2026-10-19（計測前）

10/16のscreenは最初のcreate前CPU gate（65%）でsample count 0のまま停止し、圧縮・速度・memoryの測定値はない。新しいCPU状態を一度だけ再確認する手動実行を準備する。別途一度採取する外部5×1秒 `_Total` CPU sampleが全て15%以下の場合だけ登録・実行し、screen内部の各操作直前gateも維持する。どちらかが不合格ならそこで停止し、同条件で続けて再実行しない。既知入力、方式、7-Zip設定、順序、warmup/repeat数、時間上限、判定条件およびscreen script自体は元登録のまま（screen SHA-256 `b36133ada52792d1f91c0902a28deff69840ed01e80d8fde4d92f4d98a05d567`）。

元登録に記したrunner/lifecycle SHAは履歴値として変更しない。現行ファイルはrunner `05a2a825d95ce6791e66a46811b4fa018dd3d902a354e7531bc79cf94bd1f1c5`、lifecycle module `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3`で、原登録値と一致しない。これは現在のD-only task workspace / TEMP / Cargo / TaskArtifacts契約を反映する実行基盤差分であり、結果では元登録の完全なrunner/module hash再現と主張しない。計測対象のscreen script SHAは一致する。

実行候補CLIは`<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\release\unlhare-cli.exe`、SHA-256 `81bb1f3d0e0aa592317be13e0cc6c4224f19579e51a1382077ace884bb87c732`、`--version`は`unlhare 1.0.4` / exit 0。`run-serial-cargo.ps1`（SHA-256 `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f`）経由のoffline/locked Release buildはCargoが`Finished`したが、ラッパーは終了後Job内に一時的な`VCTIP.EXE`が残ったとしてexit 1を返した。停止後の照会ではCargo/rustc/link/VCTIPは残存せず、CLIを個別に実行してversionを確認した。これはラッパー成功とは数えず、実測reportにもこの状態を併記する。

## KCS1 ptt5製品screenの再実行結果 — 2026-10-19

外部5×1秒`_Total` CPUは`[0,0,4,0,0]%`で15%以下だったが、screen内部gateはround 0のSpatialBits create前`3%`・verify/decode前`13%`に続き、RecordFast create前に`16%`を検出してfail-closedした。run `f92888cacc3d4d8b92032b614b1d7885`、report SHA-256 `cb15333a8fccb934164a95febd30bb9439d4c4d0f4e396ad1a42839423d0b44d`、status `failed`、`determinism_verified=false`。KCS1のround 0 warmup書庫1個（39,961 B、SHA-256 `4552eea92906347db1e2f0645dfdb87277902465289f9c700d68a38ec26de113`、KCS1 frame 39,889 B）は作成され、`khc-test`で入力513,216 Bを完全検証した。RecordFast/7-Zipの書庫作成とmeasured roundは実行されず、集計・比較性能値はない。このwarmupサイズを7-Zip優位性・採用判定へ転用しない。同条件の再試行は行わない。

部分成果のrecovery ZIPは`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\f92888cacc3d4d8b92032b614b1d7885\recovery.zip`（SHA-256 `b343305e490751b5442e2a75dd2653c350a993033f0bd35ea2f02db4273487e5`）、manifest SHA-256 `0e50d6cbd6847aff9116221f5eba843907f4ea42969bc4e93cea80dd599daa4a`。Prunlet direct-CMDのdelete/preview/purge/finalizeでoperationId `03b53eec078243b2865eb0d97dd67682`を完了し、work 571,710 B→0、Temp残り0、pending run 0を確認した。

## Decoder active-rank rotationの製品E2E — 2026-10-16

decoderのactive-symbol rank rotation変更後、登録済みserial Cargo入口でRelease CLIと`khc_pipeline_e2e` exampleをbuildし、登録済み`product-pipeline-e2e.ps1`をCanterburyの既知development corpus 11 file（2,810,784 B、source manifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`）へ実行した。CLI SHA-256は`f2330d286ec0dc17b93a07b98d27451ab4647f0f0fd4a5994f788523db6f0633`、E2E example SHA-256は`6c8a6067ec51cd72bcaa9bf035b43a0f7a53384c78394cbbba81bb27fe5a157e`。create exit 0、KHC archive 466,395 B / SHA-256 `0dcb76a2e1721504c28b13de38e05eca737c1b49423e83b6b345f3e8fa0a46a8`、pipeline E2E exit 0で24 assertions/groups（Canterbury11 exactness、file-CRC publication、corruption precedence、cancellation、empty/directory/1MiB+17、repeat calls）がPASSした。これはdecoder変更後の機能・復元検証であり、性能比較ではない。

run `ed5fb28e7c5b4da68f3393e213d528b2`はPrunlet direct-CMDのpreview/delete/preview/purge/finalizeを全て検証し、work directoryを除去した。recovery ZIPは`C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\ed5fb28e7c5b4da68f3393e213d528b2\recovery.zip`（8,765,027 B、SHA-256 `165f254e4708cb95fde862a49cce98727dc3746a0980d45ace9815ca21e63cbf`）、manifest SHA-256 `21d6d406c7b3ef9f05b264ec1d53b81654f8d2b7654857e17c70b8fee18db47b`として、再検証用に保全している。ZIP内`report.json`（2,042 B）のSHA-256は`324f1f0bc889fb1ef9c770a063c9b988baaf9c4a4da9a7a1298de7c90f3559d3`。

### Decoder list-rotation変更後の再実行 — 2026-10-17

2026-10-17 02:54 JSTのCPU gate通過後に固定Canterbury11入力を再照合した。11 plain files、2,810,784 B、manifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`。Release serial buildは初回にcompile完了後の`vctip.exe`残存でwrapperがfail closed（deletions 0）したが、直後に関連processが自然終了したことを確認し、同一引数の1回限定再実行はexit 0。processを停止していない。

実行source/config snapshotは40ファイル（`src/**/*.rs`、`examples/khc_pipeline_e2e.rs`、`Cargo.toml`、`Cargo.lock`）について、相対path・bytes・lowercase SHA-256をtab区切りし、case-sensitive順にUTF-8 BOMなし・LFで並べた行をSHA-256集約した値 `f7671df2f3edabadcfa2fc89030588d8471aba763dd4ba8dcb5f3ff01d15f9d1`。toolchainはCargo 1.98.1（exe SHA-256 `c37545ec61d48d31bdefce53280ecab61c4ea54eaace372fac6a0316c6e165d9`）、rustc 1.98.1 / commit `48a229ceaefd4985c50990b14116b6d856af0985`（exe SHA-256 `ca9988af88b1463f6857fdfe909299fee50a63260b3e5f7dbcb5b4d3318b27bc`）。runner／実行script SHA-256は`run-serial-cargo.ps1` `263f57d4980adb9e5046b04b78e160ffa324c442eed4b0a1e4bf24c59776527a`、`run-storage-experiment.ps1` `32ea537c89d164c9a5f09cbfe0e59127e89fdb85211d9b8f02f57e02780e9ef6`、`product-pipeline-e2e.ps1` `18b977a09620ac1fa06e1aafc107e4af4c4200f1f5cf658a06c0db33d210ab57`、`storage-lifecycle.psm1` `4cf2564794573951e900fd53b057a88471bb6ab24925b7f074b86cef4ddc3c43`。

登録済み`product-pipeline-e2e.ps1`を18 MiB / 96 entries / 900秒の上限で実行し、run `2bb064d41a87469393ee75a4a2952a8f`は2026-10-17 03:00:54.065 JSTに成功した。Release CLI SHA-256 `fbfbad667cb2e9a03848c5b32a9f029577abf20003c9ad8af3a8a65e29baafa1`、example SHA-256 `8045b5e6435a9aac5c9dbb08a6d8b19024dfb7e88cbd9f6dd9cda757da16ac57`。作成exit 0（570.52 ms）、KHC archive 466,395 B / SHA-256 `0dcb76a2e1721504c28b13de38e05eca737c1b49423e83b6b345f3e8fa0a46a8`、pipeline E2E exit 0（1,682.636 ms）、24 assertions/groups PASS（Canterbury11 exactness、file-CRC publication、corruption precedence、cancellation、empty/directory/1MiB+17、repeat calls）、compressed BinaryAdaptive KHC1 method-1 frames=8。実測correctnessのみであり、これらのelapsed timeは性能benchmarkではなく、7-Zip優位性を示さない。

Prunlet direct-CMD preview/delete/preview/purgeとfinalizeを検証し、Temp workdirを除去した。回復用ZIPは`C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\2bb064d41a87469393ee75a4a2952a8f\recovery.zip`（8,765,123 B、SHA-256 `f9642360e01a34c9aace7dd1bf6a59b609193ce06dcfd3f484becd44a8bf679e`）、manifest SHA-256 `8b7a76ef52b0e0dcf28e4103804874fbca21a548673e7092eee0561304ee9a7c`を保持する。ZIP内`report.json`は2,091 B、SHA-256 `59ba485fa6ffd88af1dfc76d96bc26549c007f1fefef1b609cc5c7b90bdc11fb`。

## 2026-10-16 日本語データを優先するユーザー指定

ユーザーの「日本のデータで権利あまり気にしなくていいデータを使って」という指定に従い、Project Gutenbergの作品候補はholdout入力へ採用しない。以前の候補（#74／#215／#345、および候補表の#11／#98／#345）に関する権利・family監査と取得物は履歴として保持するが、比較・tuning・圧縮には使わない。青空文庫のNo.301『人間失格』、No.424『檸檬』、No.752『坊っちゃん』は日本語候補として保持し、全bytes・出典・入力校正者を保つ。青空文庫の規準は著作権が切れた作品ファイルの再利用を認めるが、個別版・第三者要素の法的clearanceと同一視しない。また、同じ3作品を自然文・日本語の2カテゴリへ重複計上しない。

より権利境界の明瞭な日本語の構造化データとして、e-Gov法令検索の「司法」XML一括データを追加取得した。公式[一括ダウンロードページ](https://laws.e-gov.go.jp/bulkdownload/)の司法区分（`category_cd=41`）を`only_xml_flag=true`で取得し、入力は外側ZIPではなく、展開したmember一式（相対パスと各bytesを保持）とする。取得元URLは`https://laws.e-gov.go.jp/bulkdownload?category_cd=41&file_section=2&only_xml_flag=true`。2026-10-16取得のsource ZIPは1,018,770 B／SHA-256 `b97a3f5f1b72d45934295297f5f9e40776e82fce8e4ae420a1960190a9a1fe31`。ZIPには99 XML、`41.csv`、およびdirectory entryがあり、100ファイルの展開サイズは9,527,638 B。再計算用file-set digestは、相対pathを`/`区切りにし、`path<TAB>decimal length<TAB>lowercase SHA-256`の行をpathのordinal昇順で並べ、UTF-8（BOMなし）・LF結合したbytesのSHA-256で、値は`332cb1043efa84127312da055bb8c03104b991cb8e0820195cb2aafa4bfefee3`。source ZIPと無変換展開物は`%LOCALAPPDATA%/Codex/TaskArtifacts/UnLhaRe/01a0b076-4e26-7a71-ac35-32ed9259a871/egov-law-xml-candidate-inputs-20261016/`に保持する。保持理由は以後の日本語データ評価と再検証、削除条件はholdout評価とその再現に必要な記録が完了した後のPrunlet経由清掃。

[著作権法第13条](https://laws.e-gov.go.jp/law/345AC0000000048)は憲法その他の法令等を著作権の目的とならない著作物として列挙する。[e-Gov Developer利用規約](https://developer.e-gov.go.jp/contents/terms)は、同サイトで権利表記のないコンテンツへ公共データ利用規約（第1.0版、PDL1.0）を適用し、出典記載を求める。このため法令本文は著作権保護対象外、e-Gov由来のデータ・metadataはPDL1.0の条件に従う候補として扱い、出典を保持する。これは個別ファイル内の第三者要素を全件精査した法的意見ではなく、無条件な再配布許可とも主張しない。

本データはe-Gov由来の1 dataset familyであり、それだけでは事前登録した全holdout category/family数を満たさない。青空文庫候補とのfamily重複もないが、両者の相関・カテゴリ・全候補のrights境界を確定する最終manifestは未凍結。`Plumivox`全体公開検索のquery `e-Gov 法令データ 著作権`は0件、`completeSearch=false`で非網羅的。ダウンロード・展開物の権利確認以外の内容評価、圧縮、benchmarkは未実施であり、7-Zip優位やGOAL達成を示さない。

2026-10-16に現行の[e-Gov Developer利用規約](https://developer.e-gov.go.jp/contents/terms)を再確認したところ、権利表記がないe-GovコンテンツにはPDL1.0が適用され、出典および加工主体の表示を要求する一方、ロゴや別ルール明示コンテンツは対象外だった。[著作権法の公式表示](https://laws.e-gov.go.jp/law/345AC0000000048?occasion_date=20260717)は2026-07-17時点を検索できたが、ページ本文は動的表示のためこの調査では現行条文本文を再取得できていない。2026-04-01時点の公式検索結果には第13条第1号「憲法その他の法令」が表示された。X公開検索は同日、語句 `e-Gov 法令データ 著作権法 第13条 PDL1.0 利用規約` で0投稿／1 API要求、`completeSearch=false`。これらは法令本文の権利境界の候補根拠であり、subset内の全要素の権利確認・法的意見ではない。

### 日本の公的データ代替候補（2026-10-16、メタデータのみ）

日本のデータを使うという指定に沿い、権利条件とデータ生成元が異なる候補を追加調査した。いずれも候補であり、全suiteの選択・manifest・変換手順は未凍結で、ここでは新しいpayloadを取得・閲覧・hash・変換していない。

- [e-Gov法令XML一括ダウンロード](https://laws.e-gov.go.jp/bulkdownload/)には「河川」分類があり、ページ表示はXMLのみ210KB、法令データ一式3MB。正確な分類コード、取得物名、展開後サイズは未確認。既に取得済みの「司法」subsetと同じe-Gov family／配信基盤として扱い、両方を独立familyに二重計上しない。一般検索結果に法令ID `345AC0000000048`（著作権法）の本文断片が偶発表示されたため、当該法令は候補から除外し、全法令一括データも使わない。保持済み「司法」subsetは2026-10-16にsource ZIP SHA-256 `b97a3f5f1b72d45934295297f5f9e40776e82fce8e4ae420a1960190a9a1fe31`を再確認し、ZIP directoryと無変換展開treeの相対path／長さを照合した。100 file members／9,527,638 Bで一致し、member pathに当該法令IDは0件だった。このfilename-only監査は本文検索や第三者要素の権利確認ではないため、subsetは引き続き暫定候補であり、最終holdout manifestへは未凍結。
- [e-Stat 令和2年国勢調査・表1-1](https://www.e-stat.go.jp/stat-search/files?cycle=0&layout=datalist&lid=000001283456&month=24101210&page=1&stat_infid=000032142402&tclass1=000001136466&toukei=00200521&tstat=000001136464&year=20200)は統計表ID `000032142402`、Excel／DB提供。正確なmember名・サイズ・採用するDB出力形式は未確認。2026-10-16にDB overviewを確認すると、このファイルは複数databaseに分かれ、下位表番号1-1-1等を持つ。manifestでは対象DB表・全地域範囲・CSV等の出力形式を1つに固定する必要がある（DBデータ値・payloadは未閲覧）。[利用規約](https://www.e-stat.go.jp/terms-of-use)は複製・送信・翻案と商用利用を認め、数値や簡単な表・グラフは著作権の対象外と説明する。第三者権利、出典・加工表示、API等の別規則は別途確認する。

2026-10-16の公式ページ再確認では、表1-1は2020年10月調査の全国・都道府県・市区町村別の人口／世帯統計で、現在EXCELとDBが表示されていた。[現行利用規約](https://www.e-stat.go.jp/terms-of-use)は複製・公衆送信・翻案と商用利用を認める一方、出典と編集・加工の表示を求め、第三者権利・個別の別ルールは利用者側で確認するよう定めている。表ページはファイルmember名・サイズやDB出力schemaを固定しないため、payload未取得の候補のまま。Plumivox X全体検索 `e-Stat 令和2年 国勢調査 表1-1 利用規約 再利用 CC BY 4.0` は0投稿／1 API要求、`completeSearch=false`で非網羅的。
同日の[e-Stat DB overview](https://www.e-stat.go.jp/stat-search/database?layout=datalist&stat_infid=000032142402)を再確認し、表番号1-1-1の表題が「男女別人口－全国，都道府県，市区町村（2000年（平成12年）市区町村含む）」、調査年月2020年10月、公表日2021-11-30であることを確認した。画面にはDB／API入口とCSV・JSON・XML形式の選択肢があるが、値を表示するDB/APIやダウンロード操作は行っていない。したがって表番号の候補は具体化した一方、全地域範囲の選択、最終出力形式、member/取得サイズ・SHA-256、第三者要素は未確定で、manifestは未凍結である。
- [気象庁「過去の気象データ・ダウンロード」](https://www.data.jma.go.jp/risk/obsdl/top/help3.html)は観測所・観測項目・期間からCSVを生成できる。具体的な観測所、期間、項目、生成日時、正確な出力サイズは未固定。[政府データカタログのresource metadata](https://data.e-gov.go.jp/data/dataset/mlit_20151130_0404/resource/55fb83d4-5c07-417d-8fd7-5235cd6349b7)は政府標準利用規約第2.0版を表示する一方、気象庁[利用規約](https://www.jma.go.jp/jma/kishou/info/coment.html)は権利表記のない公開情報にPDL1.0を適用するため、対象CSVの表示と適用条件を採取時に照合する。

この3系統は、法令の階層XML、国勢調査の地域別統計表、気象観測時系列という異なる生成過程の優先候補である。e-Govは[サイト規約](https://www.e-gov.go.jp/terms)の出典・加工主体表示およびPDL1.0適用外コンテンツを確認する。2026-10-16のPlumivox公開X検索 `公共データ利用規約` は20件・続頁あり・`completeSearch=false`で非網羅的であり、権利根拠には使用しない。KHC `experiments/khc`内（本selection memoを除く）の公式ID・候補名に対する対象拡張子の文字列検索は一致なし。ただしこれは文書化された既往利用が見つからなかっただけで、未記録データや別名・近縁familyの未使用を証明しない。候補の最終採用、rights clearance、学習・調整側との重複、凍結manifestは未完了で、圧縮・測定結果を示さない。

### e-Gov法令データの規約・API境界の再確認（2026-10-16）

現行[e-Govポータル利用規約](https://www.e-gov.go.jp/terms)は`e-gov.go.jp`とサブドメインの公開情報について、権利表記がない場合にPDL1.0を適用し、出典と編集・加工主体の表示を求める。ロゴ等と別ルールを明示したコンテンツは対象外である。[デジタル庁のPDL1.0本文](https://www.digital.go.jp/resources/open_data/public_data_license_v1.0)は複製・公衆送信・翻案と商用利用を認め、CC BY 4.0と互換とする一方、個別法令・別ルールの制約を残す。取得手順は旧[法令API v1仕様書](https://laws.e-gov.go.jp/file/houreiapi_shiyosyo.pdf)ではなく、現行[e-Gov法令API Version 2](https://laws.e-gov.go.jp/api/2/swagger-ui)のOpenAPI仕様（確認版2.1.139）で確認する。同仕様は法令本文・履歴・添付・ファイル取得を別endpointとして定義し、XMLは`law_file`経路で取得できる。これは取得手順の説明であり、データ利用条件そのものとは区別する。APIの法令履歴IDは対象revisionを指す識別子で、byte hashではないため、候補を実際に固定するときは選定済みの取得物を一度だけ保存し、長さ・SHA-256をmanifestへ記録する。[著作権法第13条](https://laws.e-gov.go.jp/law/345AC0000000048?occasion_date=20260523)は「憲法その他の法令」を著作権の目的とならない著作物に含める。これらは既存の「司法」XML subsetとe-Gov法令本文の権利境界を支持する資料であり、個々のXML内の第三者要素・別ルール、PDL帰属表示を検査済みとはしない。2026-10-16のPlumivox全体公開検索 `e-Gov 法令データ 著作権 再利用 利用規約` は0投稿、`completeSearch=false`で非網羅的。今回、新たな法令本文/API payloadは取得・保存・hash・変換・圧縮・計測していない。著作権法の法令ID `345AC0000000048`自体はholdout候補へ戻さず、既存の「司法」subsetのみを単一e-Gov familyの条件付き候補として維持する。

同じ公式[e-Gov XML一括ダウンロードページ](https://laws.e-gov.go.jp/bulkdownload/)は「XMLのみ」と「法令データ一式」の選択肢、全件一括は287MBで一括ダウンロード不可との注意、分野別categoryを掲載する。現行一覧の「司法」は994KBと4MB、最近の更新法令一覧は令和8年10月15日分を4MBと70MBで表示するが、レンダリング上で個々のサイズ列と上記2選択肢の対応は確定せず、日次更新物の含む法令・member・bytesも未確認。候補packageの概算情報としてのみ扱い、downloadリンクはクリックしていない。同日のPlumivox `scope=all`検索 `e-Gov 法令API XML 利用規約 著作権 オープンデータ` は0件、1 API要求、`completeSearch=false`で非網羅的。取得・展開・hash・変換・圧縮・測定はしておらず、候補のまま。

### 青空文庫候補の文書化された既往利用検索（2026-10-16）

日本語候補の青空文庫 No.301『人間失格』、No.424『檸檬』、No.752『坊っちゃん』について、`experiments/khc`内の本selection memo以外に対し、Markdown/Rust/PowerShell/CSV/TOML/JSONを対象として作品名・「青空文庫」の文字列を検索したが一致はなかった。さらに2026-10-16、現行の`src/`、`examples/`、`tests/`、`README.md`、`AGENTS.md`に対して作品名とmember名 `ningen_shikkaku`・`lemon.txt`・`bocchan.txt`を検索したが一致はなかった。これは限定した文書・ソース群で文書化された参照が見つからなかっただけで、未記録入力、binary、alias、近縁family、学習・調整への非文書利用がない証拠ではなく、holdout適格性や未使用を確定しない。

[青空文庫収録ファイルの取り扱い規準](https://www.aozora.gr.jp/guide/kijyunn.html)は2022-01-01更新とし、「ファイル」を図書カードからリンクされた全形式の個別作品ファイル、「青空文庫側」を入力者・校正者・点検者・ファイル作成者を含む関係者として定義する。著作権が切れた作品のファイルについて、有償・無償の複製・再配布・共有、形式変換等を認め、了解や対価を不要とする一方、作品・著者・底本・入力者・校正者等の記載事項を削除しないことを希望する。著作権存続作品は別扱いで、翻訳作品には訳者の権利も残り得るため、本候補は翻訳ではない原作品に限定する。この規準は対象作品の権利が切れていることを前提としたファイル再利用根拠になるが、個別の底本編集要素や第三者内容まで権利処理済みとは示さない。公式図書カードのZIPサイズと実取得したsource archiveのbyte数は一致し、入力はZIP memberの`.txt`本文そのもの（archive byte数とは別）である。

| 候補 | 公式metadata | source ZIP（実測byte / SHA-256） | 採用`.txt` member（実測byte / SHA-256） |
| --- | --- | --- | --- |
| [No.301『人間失格』](https://www.aozora.gr.jp/cards/000035/card301.html) — 旧候補。初出・没年の近接に関する権利期間の懸念から差替え、以下の保全物は過去候補記録のみ | 太宰治、1948-06-13没。初出1948年。 | [`301_ruby_5915.zip`](https://www.aozora.gr.jp/cards/000035/files/301_ruby_5915.zip) — 68,596 B / `fb37d694f86687f9e84e26643804fa84b4346895f5f56a90dd8843a12e2bc9c8` | `ningen_shikkaku.txt` — 153,317 B / `786e6a1a4a031a846887f4d43923cb2cb4a984a858d888b87e76d994fe0450b0` |
| [No.424『檸檬』](https://www.aozora.gr.jp/cards/000074/card424.html) | 梶井基次郎、1932-03-24没。初出1925年。 | [`424_ruby_19825.zip`](https://www.aozora.gr.jp/cards/000074/files/424_ruby_19825.zip) — 6,792 B / `c1bf570b1852ad970329c35a671cc5dfeca623ac721d81518a0bb98701fdcf1d` | `lemon.txt` — 12,019 B / `979e3e94b2537ef922851023bef4c32530ba4b7eef2e3c15bf66c80a495a5512` |
| [No.752『坊っちゃん』](https://www.aozora.gr.jp/cards/000148/card752.html) | 夏目漱石、1916-12-09没。初出1906年。 | [`752_ruby_2438.zip`](https://www.aozora.gr.jp/cards/000148/files/752_ruby_2438.zip) — 94,410 B / `53c4d86033d0e4590c0354df5fec2709820ef21c09fa402826ff33376ec21228` | `bocchan.txt` — 209,990 B / `8b1087162da44dbf54705c15f5ba62c7c07db86bb6f38caacd4f5beb62e4618b` |

同日のPlumivox全体公開検索 `青空文庫 作品ファイル 利用条件 著作権 再利用` は0投稿、`completeSearch=false`で非網羅的。著者の没年は原作品の権利期間を評価するmetadataに留まり、各近代底本の編集要素、個別カードの追加権利表示、member内の同梱metadataまでは未照合である。各ZIPの唯一の非空`.txt` memberを抽出し、member名・byte数・SHA-256を含むmanifestへ記録した。別プロセスの再検証で各ZIP memberをstreaming SHA-256し、展開済み入力fileのbyte数・SHA-256と全3件で一致すること、ZIPごとに非空`.txt` memberが1件であることを確認した。

取得状態は`candidate-only-not-benchmarked`（`benchmarked=false`）。TaskArtifacts保持先は`C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\01a0b076-4e26-7a71-ac35-32ed9259a871\aozora-holdout-candidate-20261016\`、`manifest.json` SHA-256 `caa078a5053669dfd0fb90ebe9d3941b69a76a36600dec2579495f0de58c516d`。保全treeは7 files / 548,793 B（3 archive、3 extracted input、manifest）。入力bytesは未変換・未圧縮・未測定で、最終holdout manifestには未採用である。以前取得した公式XHTML候補3点（上記別記録）は同じ原著作物の別表現であって追加familyではなく、今回の`.txt` recipeとの重複評価も行わない。著作権・個別notice・第三者要素の最終確認、全categoryのsource-family独立性とprior-use照合、全体manifest凍結は未完了で、rights clearanceや7-Zip優位を確定しない。

### 青空文庫候補の保守的な差替え（2026-10-16）

旧候補No.301『人間失格』は、初出年と著者没年が近接し、metadataだけでは権利期間を安全に確定できない懸念があるため、現行候補選択から撤回した。上記の取得・保全済みNo.301 ZIPと抽出`.txt`は過去候補の記録として保持し、ベンチマークおよび最終manifestには使用しない。代替の第一候補は青空文庫[図書カードNo.2078『舞姫』](https://www.aozora.gr.jp/cards/000129/card2078.html)：同カードは初出を「國民之友」1890年1月、森鴎外の没年月日を1922-07-09、ルビ付きShift_JISテキストZIPを21,233 Bと記録する。予備候補は[図書カードNo.42206『初孫』](https://www.aozora.gr.jp/cards/000038/card42206.html)：初出「太平洋」1900年12月、国木田独歩の没年月日1908-06-23、ルビ付きShift_JISテキストZIP 3,575 Bである。今回開いたのは公式カードmetadataと[青空文庫収録ファイルの取り扱い規準](https://www.aozora.gr.jp/guide/kijyunn.html)のみで、両候補のZIP/memberは取得・閲覧・hashしていない。

同規準（2022-01-01更新）は、著作権の切れた作品の個別ファイルについて有償・無償の複製・再配布・共有・形式変換を認め、対価・了解は不要とする一方、由来・著者・底本・入力者・校正者等の情報を削除しないことを希望している。これは基礎作品の権利が消滅している場合の利用条件であり、各候補の法的な満了判定、底本編集要素、個別notice、member内の第三者要素まで確認したものではない。No.424『檸檬』およびNo.752『坊っちゃん』は既存の条件付き候補として残すが、No.2078/424/752のsource-family独立性も未確定である（青空文庫の共通配布・電子化工程と、カードに記載された共通校正者が相関要因となり得る）。No.42206は予備候補で、三作品の選択・権利確認・未使用確認・全体manifest凍結は未完了。候補差替え後もholdout取得・圧縮・測定は開始しない。同テーマのPlumivox公開X検索 `青空文庫 舞姫 初孫 著作権 初出` は0投稿、`completeSearch=false`で非網羅的であり、権利根拠や未使用の証明には使わない。別途、2026-10-16の限定的なローカルprior-use text searchでは、`UnLhaRe/experiments/khc`配下の`.md`、`.json`、`.rs`、`.ps1`を対象に、通常の`rg -l`で`2078_ruby_15898`、`42206_ruby_34460`、`card2078`、`card42206`、`国木田`、`森鴎外`、`森 鴎外`を検索し、一致ファイルはなかった。hidden/ignored filesは対象外であり、この範囲の記録に文字列一致がなかったというだけで、候補bytesの未使用や独自性を証明しない。

### No.424/752 の記録済みprior-use再照合 — 2026-10-20

公式カードの著者・初出metadata（[No.424](https://www.aozora.gr.jp/cards/000074/card424.html): 梶井基次郎、1932-03-24没、初出1925年。[No.752](https://www.aozora.gr.jp/cards/000148/card752.html): 夏目漱石、1916-12-09没、初出1906年）と[文化庁Q&A問4](https://www.bunka.go.jp/seisaku/chosakuken/hokaisei/kantaiheiyo_chosakuken/1411890.html)の「2018-12-30前日に既に保護期間が切れた著作物は延長で復活しない」という説明を照らした結果、基礎作品は通常の著作者死後期間の単純計算では改正施行前に満了していたとみられる。[青空文庫の規準](https://www.aozora.gr.jp/guide/kijyunn.html)は著作権切れ作品に対応する個別ファイルの複製・再配布・形式変換を認める。これは低い権利懸念を支持する一次資料上の確認であり、個別底本の編集要素、第三者notice、本文中の別権利までは法的に確定しない。

2026-10-20の読み取り専用照合は、現行UnLhaReリポジトリ、`<作業フォルダー>\TaskArtifacts\UnLhaRe`、`<作業フォルダー>\UnLhaRe\goal-restore-20261019`を対象に実施した。通常の文書・JSON・manifest・receipt等3,358ファイルでは候補名・全SHA・サイズの一致は既存の`manifest.json`と本選定記録だけで、記録本文検索の一致もこの2ファイルに限られた。外側ZIP 175個、メモリ上で再帰確認したZIP 1個の計3,071 entryを確認し、記録本文を含む354 entryも候補名・SHA・サイズで検索した。ZIP内一致は保全済みNo.424/752の元ZIPと各`.txt` member、およびそれらを記載するmanifest／本選定記録だけで、run JSON・receipt・計測reportに実験使用を示す一致はなかった。したがって、この照合範囲ではNo.424/752の圧縮・測定・training/tuning利用記録は見つからず、未使用の証明とは扱わない。

この結果によりNo.424/752を日本語textのdevelopment/tuning用候補として維持するが、本記録時点ではmanifest登録や本文の実験使用は開始していない。No.301の元ZIPは照合対象外、未取得のNo.2078/42206は対象外。20 recovery ZIP内のネストした7z 44個・zstd 2個、改名・抜粋・変換済み本文、記録されていない使用、作品familyの独立性は未確認である。候補本文・元ZIPに対する作成・変更・展開・圧縮・測定は行っていない。

次段階のデータ分離方針として、取得済みNo.424/752は日本語textのdevelopment/training/tuning用に限定し、holdoutには転用しない。未取得の[No.2078『舞姫』](https://www.aozora.gr.jp/cards/000129/card2078.html)と[No.42206『初孫』](https://www.aozora.gr.jp/cards/000038/card42206.html)は、実装・調整の終了まで本文を取得・閲覧・処理せず、将来のholdout候補として分離する。両作品は同じ青空文庫配布・電子化familyのため、異なる作品でも独立したsource familyとは数えない。

development入力packageを `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\` に固定した。`input.zip` は222,247 B、SHA-256 `9772d6af224028a70c2d50af8f64faebf03de9a487a08fee566de4c1128cb0b6`。package manifestは`e7ba78c324e97d677f1e1c9aa0371234666a643227fccfbab4c2d70db1204307`、展開後file-set digestは`4d9ded91fe0a2e7657cce870f7fd39a4c83c8b7fe5e26f7230ebd8e53c1d2ea6`、元候補manifestは`caa078a5053669dfd0fb90ebe9d3941b69a76a36600dec2579495f0de58c516d`。packageには`input/bocchan.txt`と`input/lemon.txt`のみを格納し、元の2 memberのbyte数・SHA-256との一致を確認した。現状は`development-only-input-frozen-campaign-preregistered`、`benchmarked=false`である。campaign-start markerは固定済みだが、start gate・run registration・圧縮・測定はまだ行っていない。

No.2078/42206の本文取得前の追加読み取り専用prior-use監査も2026-10-20に実施した。3対象rootでhidden/ignoredを含む通常ファイル11,455件の名前・サイズ、ソース・文書・JSON/receipt等4,059件の記録、外側ZIP176個とネストZIP1個の3,072 member名・サイズを確認した。指定ZIP名・card ID・作品名・作者名・想定member名・既知hashに合う使用記録はなく、記録参照の一致は本書のmetadata・選定に関する3行のみだった。No.42206 ZIPと同じ3,575 Bのreceipt JSONが1件あったが、これはサイズのみの一致で本文・ZIPではない。取得・変換・圧縮・測定・training/tuning利用を示す記録は検出しなかったが、未取得本文hashがないため未使用を証明しない。ネストした7z 44個・zstd 2個、任意本文TXT、改名・抜粋・変換済み本文、記録外利用は対象外である。同監査ではNo.2078/42206本文の閲覧・download・展開、build、benchmark、削除は行っていない。

### NDL「本の万華鏡」日本語prose候補の除外 — 2026-10-16

国立国会図書館の[公式コンテンツ一覧](https://www.ndl.go.jp/kaleido/) metadataから、第32回「鉄道が変えたコト・モノ」第4章「旅行・観光」の[解説HTML](https://www.ndl.go.jp/kaleido/entry/32/5.html)が追加候補として挙がった。展示固有の[利用案内](https://www.ndl.go.jp/kaleido/about)は掲載画像・解説を申込み不要・商用利用可とし出典記載を求める。全館の[利用規約](https://www.ndl.go.jp/sitepolicy/terms)は別ルールを除いてPDL1.0準拠だが、第三者権利コンテンツは個別確認を要する。本ページは候補本文の未見境界を保つべき段階で、親側が公式URLを一次資料確認のため開いた際、Web取得結果に本文が含まれてしまったため、未見holdoutおよび開発用調整入力から除外する。本文はこの記録へ転記せず、候補familyにも数えない。ローカルdownload/save/hash、asset取得、圧縮、測定は行っていないが、本文は既に露出したものとして扱う。同テーマのPlumivox全体公開検索 `国立国会図書館 国立公文書館 日本語 コンテンツ 著作権 再利用` は0件、`completeSearch=false`であり非網羅的。候補の具体的な個別rights/third-party要素監査は行わず、今後もholdoutに再利用しない。

### 国立公文書館の情報誌記事候補 — 2026-10-16

公式の[『アーカイブズ』No.101目次](https://www.archives.go.jp/publication/archives/)は、2026-08-31発行号の記事として「国立公文書館デジタルアーカイブの2026年リニューアルについて―「Center for Archives」の実現に向けた新たなサービス基盤―」を掲載し、国立公文書館所属として吉田敏也・一牛ゆかり・西山直志を記載する。目次HTMLのlink metadataから個別URL https://www.archives.go.jp/publication/archives/no101/18790 を照合したが、候補本文・PDF・assetは開いていない。公式[サイト利用規則](https://www.archives.go.jp/sitepolicy/)は個別情報とサイト全体を著作権対象とし、出所表示付きの引用・転載・複製を認める一方、本文内容を変える利用を断る。PDL/CCではないため、byte-exact復元を含む圧縮物の扱いは条件付き候補にとどめる。著者所属は全HTML要素の権利帰属を証明せず、記事固有notice、第三者引用・画像・埋込み、規則の適用範囲、本文量、他候補との重複、既存利用を未確認とする。2026-10-16 Plumivox全体公開検索 `国立公文書館 理化学研究所 日本語 記事 著作権 再利用` は0投稿・`completeSearch=false`で非網羅的であり、未使用・権利の証明ではない。raw取得・保存・hash、manifest追加、圧縮・測定は実施していない。記事は別作成元の日本語prose候補としてoverflow枠に記録するが、独立familyとして未確定で、holdout manifestには未採用。

### 気象庁の過去観測CSV recipe境界（2026-10-16）

現行[気象庁ホームページ利用規約](https://www.jma.go.jp/jma/kishou/info/coment.html)は権利表記がない公開情報にPDL1.0を適用し、出典と加工・編集主体の表示を求める。また一部の気象情報には気象業務法上の制約があり、ロゴ等と別ルール明示のコンテンツは対象外とするため、候補は過去の実観測値CSVに限定し、予報・警報・図・ロゴは含めない。[過去データCSVの形式説明](https://www.data.jma.go.jp/risk/obsdl/top/help3.html)では、出力に取得時刻、複数行の表題、データ行が含まれ、選択によって品質・現象なし・均質番号情報が加わる。将来のrecipeでは観測所・期間・観測項目・表示/品質オプションを固定し、取得日時と取得後の全CSV bytes/SHAを記録する。今回は規約とCSV形式metadataだけを再確認し、CSV data/API payloadは取得・保存・hash・圧縮・計測していない。Plumivox全体公開検索 `気象庁 過去の気象データ CSV 利用条件 PDL1.0` は0投稿、`completeSearch=false`で非網羅的。JMAはe-Gov/e-Statと重複しない時系列観測familyの候補であり、station/period/member/size/SHAを含むmanifestは未凍結。

### 日本語公的白書候補（2026-10-16、規約・family metadata audit）

自然文prose候補表のProject Gutenberg 3件は、上記の日本語データ指定に従い撤回し、次の3件を置換候補として記録する。候補family数は発行機関・報告書単位で3件だが、本文重複と第三者要素が未監査のため、独立holdout family数にはまだ加算しない。

- 内閣府：[候補章「高齢化の現状と将来像」HTML](https://www8.cao.go.jp/kourei/whitepaper/w-2025/html/zenbun/s1_1_1.html)（[全体版目次](https://www8.cao.go.jp/kourei/whitepaper/w-2025/html/zenbun/index.html)）。[内閣府ホームページ利用規約](https://www.cao.go.jp/notice/rule.html)はページ上で令和7年3月25日現在とし、権利表記がないコンテンツにPDL1.0を適用する。[ホームページ案内](https://www.cao.go.jp/notice.html)は内閣府ホームページを内閣府運営のウェブサイトと定義し、ドメインが明示された場合はその範囲に限ると説明する。白書HTML内の引用・第三者要素は未確認。
- 国土交通省：[令和7年版国土交通白書HTML版](https://www.mlit.go.jp/hakusyo/mlit/r06/hakusho/r07/index.html)の候補章は[第I部第1章第1節](https://www.mlit.go.jp/hakusyo/mlit/r06/hakusho/r07/html/n1110000.html)。[著作権案内](https://www.mlit.go.jp/link.html)は特記・権利表記がないコンテンツへPDL1.0を適用し、[別紙](https://www.mlit.go.jp/page/kanbo01_hy_003657.html)はロゴ・地理データ等の別ルール対象を列挙するが白書自体を挙げない。候補章には文章と図表画像・ロゴへの参照があるため、単一HTMLのみを候補bytesとし外部assetを取得しない前提でも、全markupと個別権利表示の未確認を残す。
- 環境省：[令和7年版環境白書のHTML章候補](https://www.env.go.jp/policy/hakusyo/r07/html/hj25010201.html)。[環境省利用規約](https://www.env.go.jp/mail.html)は権利表記がないコンテンツにPDL1.0を適用する。[白書総合案内](https://www.env.go.jp/policy/hakusyo/index.html)は白書に掲載した一部の写真の権利が通信社等にあると注意するが、この一般注記は2025年版の個別要素一覧ではない。[令和7年版公表資料](https://www.env.go.jp/press/111155_00003.html)は2025年6月6日の閣議決定・公表を示す。

共通条件：[PDL1.0](https://www.digital.go.jp/resources/open_data/public_data_license_v1.0)は複製・公衆送信・翻案等を認め、出典と加工主体・加工事実の表示を求める一方、第三者の著作権や肖像権等は、権利処理済みと明示されたものを除いて利用者側で確認するよう定め、第三者要素が明示的に特定されない場合もある。CAO章が総務省統計局・社人研の統計を出典表示するだけで、各機関の規約が白書HTML全体へ自動適用されるとは読めない（各規約文面からの適用範囲についての判断）。ただし、保護される表現の転載・埋込みやHTML内assetは個別に確認する。したがってHTMLファイルだけを対象にしても、引用文・図表・代替テキスト等の権利確認を省略できない。CAO・環境省・MLITは別省庁・別テーマの候補familyとして扱うが、統計の共有、引用元、定型文、内容重複は未検証であり、統計的独立性を主張しない。

同テーマのPlumivox公開X検索 `日本政府 白書 著作権 利用規約 PDL1.0 PDL2.0 再利用` は2026-10-16の結果（0件、1 API要求、`completeSearch=false`）を再利用した。検索は非網羅的で、権利根拠には使わない。候補表作成時の調査は公式規約、一覧ページ、出版・公表メタデータに限定し、白書章payloadを取得・閲覧・hash・変換・圧縮していなかった。個別候補の完全なmarkup、第三者注記、family重複監査、取得物・member・サイズ・manifestは未確定であり、3候補は採用・rights clearance・holdout凍結済みではない。

### 日本語proseの追加候補探索 — 2026-10-16

既存の青空文庫、金融庁、政府白書、JFT、KFS、NDL、国立公文書館のfamilyを再利用せず、追加の日本語prose候補を公式metadata／利用条件だけで探索した。日本語prose categoryへ数えられる新規familyは確認できず、3-family要件を維持する。Godotの翻訳POは権利根拠付きの日本語text予備候補として下記に記録するが、英日混在のgettext構造であるためproseには加算しない。候補本文・corpus bodyは開かず、download、hash、変換、manifest登録、圧縮、測定も行っていない。

- 防衛研究所の研究解説は候補にしない。[公式利用条件](https://www.nids.mod.go.jp/utility/index.html)は一般コンテンツにはPDL1.0準拠の自由利用を認めるが、URLが`/publication/`配下の「調査研究コンテンツ」を明示的に適用対象外とし、長文転載の事前連絡、内容改変・私的利用以外の複製・公衆送信を断っている。対象となる研究解説はこの例外に入るため、holdout全体を再配布・変換できる許諾として扱わない。
- 情報科学技術協会（INFOSTA）の2026-02-26公式[セミナー案内](https://www.infosta.or.jp/seminars/semi20260226/)は、開催報告へのリンク表示を`CC BY`とするが、リンク先はnoteで、公式案内だけでは報告の発行日、CCライセンスの版、執筆者、第三者素材への適用範囲を確定できない。協会の2021-04-01付[会誌CC方針](https://www.infosta.or.jp/wp/wp-content/uploads/2021/03/CC_license_policy.pdf)は記事ごとに執筆者が複数のCC条件または非付与を選べるとし、CC-BYは書評・協会記事に限り原則付与、会員限定期間の再頒布も制限する。従って会誌一般や報告リンクを一律のCC-BY familyとして採用しない。
- Godot Engineの[固定commit README](https://github.com/godotengine/godot-docs-l10n/blob/d9933c37775ac255ddb9977b02a173305c3b5b3c/README.md)は翻訳内容の`msgid`・`msgstr`全体をCC BY 3.0 Unportedとし、`Juan Linietsky, Ariel Manzur and the Godot community`への帰属を指定する。候補は同commitの`sphinx/po/ja/LC_MESSAGES/about/introduction.po`（gettext PO、Git tree metadata 11,113 B）。POには英語原文・日本語訳・gettext構文が混在するため、自然文proseの代表例としては採らず、Japanese textの補欠候補に限る。英語原文と他言語訳は同じGodot文書familyの派生としてまとめ、別familyに数えない。READMEの[固定LICENSE](https://github.com/godotengine/godot-docs-l10n/blob/d9933c37775ac255ddb9977b02a173305c3b5b3c/LICENSE.txt)も確認した。個別PO header・翻訳完成度・コード例や引用の有無は未確認で、確定payloadを取得する前に再確認する。同familyはKHC候補記録の限定`rg`照合で見つからなかったが、未使用の証明ではない。本文POの取得・閲覧・hash・変換・圧縮・測定はしていない。

同テーマのPlumivox公開X検索 `日本語 公的解説 学会誌 CC BY 再利用 著作権` は2026-10-16に0件、1 API要求、`completeSearch=false`。検索は非網羅的であり、候補不存在・権利状態・独立性の証拠には使わない。今回の探索で日本語natural-language proseの適格family数は増えていないため、payload取得・測定・holdout凍結を引き続き保留する。

同じmetadata-only候補監査で国立国会図書館の[データセット一覧](https://lab.ndl.go.jp/data_set/dataset/)を確認した。国会会議録のテキストデータは7.8GBと表示され、著作権法の権利制限範囲内での利用、営利目的の利用には要申請と記載される。[公式API仕様](https://kokkai.ndl.go.jp/api.html)も、館職員発言等を除く各発言の著作権は発言者に帰属し、原則許諾が必要で、例外は著作権法上の条件に従う利用者自身が判断し、問題の責任も利用者が負うとする。したがって許諾不要の日本語prose holdout familyとしては採用しない。APIは手続不要でもそれ自体で発言著作権の許諾を置き換えず、大容量一括データはこの評価の資源枠とも不整合である。本文・API応答・ファイルは取得していない。同テーマのPlumivox `scope=all`検索 `国会会議録 API 利用規約 著作権 再利用`（2026-10-15〜17 JST）は0件、1 API要求、`completeSearch=false`で非網羅的。

### 日本の公的表データ候補の識別・rights再確認 — 2026-10-16（メタデータのみ）

日本郵便の[UTF-8郵便番号CSV配布案内](https://www.post.japanpost.jp/service/search/zipcode/download/)と[形式・利用説明](https://www.post.japanpost.jp/service/search/zipcode/download/utf-readme.html)を再確認した。全国一括の公式artifact名は `utf_ken_all.zip`、1レコード1行のCSVをZIP圧縮した配布で、2026-09-30更新分が掲載されている。説明はUTF-8（BOMなし）・CRLF等の形式を定め、郵便番号データに限って日本郵便は著作権を主張せず、自由な配布を認める。これは郵便番号データの表示でありサイト全体の許諾ではない。ZIP内CSVの正確なmember名・取得物SHA-256・版固定可能な不変URLは公開説明だけでは確定できず、ZIP取得・展開・member確認は未実施。住所や自治体名／コードは他の公的表候補と共有し得るため、別producerであることだけで統計的独立性は確定しない。

同じ[配布案内の差分欄](https://www.post.japanpost.jp/service/search/zipcode/download/utf-zip.html)は、2026-09-30更新分として `utf_add_2609.zip` と `utf_del_2609.zip` を各1kB表示で掲載する。日付を含む名前の月次差分があることは確認できたが、リンク先URLの固定性、実バイト数、ハッシュ、member、権利表示の適用範囲は未確認であり、全件版や不変スナップショットの代替とは扱わない。取得・展開・閲覧はしていない。同テーマのPlumivox `scope=all`検索 `日本郵便 郵便番号 UTF-8 差分 2026年9月`（2026-10-15〜17 JST）は0件、1 API要求、`completeSearch=false`で非網羅的。

国土地理院の[全国都道府県市区町村別面積調](https://www.gsi.go.jp/KOKUJYOHO/MENCHO-title.htm)は2026-09-25更新、令和8年7月1日時点の調査を同日に公表し、[技術資料リストE2](https://www.gsi.go.jp/REPORT/TECHNICAL/gsirgijutsu4.htm)は該当回をE2-No.93（完成年度2026）として載せる。公式候補artifact URLは[`R8_07_mencho.csv`](https://www.gsi.go.jp/KOKUJYOHO/MENCHO/backnumber/R8_07_mencho.csv)だが未取得である。直URLのWeb previewは `400 Unsupported content-type: text/csv` となり、CSV本文は返らず、サイズ・hashも確認していない。過去分ページの「令和6年4月以降 CSV:341KB」は複数回分の別の集約CSVであり、この単回候補のサイズとして転用しない。面積調ページは面積調を測量法第12条の基本測量長期計画に基づく公表とし、国土地理院技術資料とも明記する。技術資料の提供案内はウェブ掲載資料について提供申請不要・国土地理院コンテンツ利用規約適用・商用利用可とする。現行コンテンツ規約は特記がなければPDL1.0、出典と加工表示を要求し、第三者権利は個別に確認するよう定める。ただし、このCSVを本評価の無変換入力として再配布する際に別個の測量法手続・個別ルールが適用されないか、E2-No.93そのものの権利表示と共有元データの関係は未確定であり、rights-clearedや候補採用とは扱わない。

同テーマのPlumivox `scope=all`公開X検索 `日本郵便 郵便番号CSV 国土地理院 面積 CSV 利用条件 PDL 再利用` は0件、1 API要求、`completeSearch=false`で非網羅的。どちらのartifactも取得・閲覧・hash・変換・圧縮・測定しておらず、最終manifestは未凍結。次段階ではmember・個別規約・法令条件・prior-useとfamily重複をpayloadに触れる前に解消し、候補のまま追加検討する。

## KRS3 adaptive-CDF候補（事前登録と状態）

KRS2は4つの全体histogramから静的CDFを作る。既知ptt5の製品比較ではKRS2/RFT書庫46,274 B、7-Zip 26.04 LZMA2書庫42,199 Bであり、速度はKHC側が速い一方、書庫は4,075 B大きい。この候補はlocal frequency driftに対する実験であり、改善は未実証。KRS2を一切変更せず、明示的な `KRS3BLK\0` / frame version 3の試験形式を別経路で追加する。

KRS3 block-onlyの次段screenは開発専用の既知Canterbury `ptt5` に限定し、未見holdoutへ一般化したとは扱わない。入力は保全ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`（SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`）の`input/ptt5` memberだけを登録work内へstreamし、513,216 B / SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`を再確認する。Release `khc_record_fast_bench`でKRS2 `RecordFastTrial`とKRS3 `RecordAdaptiveTrial`を同一block API・同一rawで比較する。各processは3 warm-up後に3回のencodeとdecodeを計測し、3組のpaired batch（実行順KRS2→KRS3、KRS3→KRS2、KRS2→KRS3）から各9 sampleのmedianを出す。全batchでframe長とSHA-256が一致し、全encodeのdeterminism、decode byte/SHA復元を満たすこと。KRS2側は46,202 B / CRC32 `2710226762`であることを固定開発基準とし、KRS3がfallback・不正なidentity・run上限超過・process peak working set 64 MiB超過ならpromotion no-goとして記録する。7-Zip比較可能な採用前の強いsize gateはKRS3 block frame **42,127 B未満**とする（既知KRS2書庫の72 B outer overheadを据え置いた場合だけの上限推定）。このgate未達なら製品archiveへ進めない。gate達成でもそれはblock-only見込みにすぎず、revision 8以降の完全製品書庫・完全復元・実測時間/メモリを7-Zip 26.04と直接比較するまでは候補採用・優位性を主張しない。各screenの直前に5×1秒CPU sampleが全件15%以下であること、5 MiB / 64-entry / 300秒runの固定容量予約とhashが一致することを要求し、失敗ならそのrunを保存・清掃して同条件の再試行をしない。

このscreen専用runnerと保全設定を追加した時点では性能測定は未実施で、当初のRelease `khc_record_fast_bench.exe`（`build/cargo/release/examples/`、Rust 1.98.1）は1,326,080 B、SHA-256 `337281256be17a9ed0f99f221d7bfee64c125294c0bc4a2a84b94ebc0a2ef5ee`をscript内pinとしていた。build初回はCargo compile完了後にMSVC `VCTIP.EXE` PID39132がJobに残りwrapper exit1（observed Cargo peak 1,042,856,898 B）。PID消失後の1回限定warm retryはexit0/0.98秒、deletions=0で、実行対象processは残っていない。x86_64 target配下の旧exampleは別SHA・旧timestampだったため使わず、host-targetのRelease pathを固定した。この当初のbinaryでbenchmarkやscreenは起動していない。

2026-10-16 22:52 JSTの外部5×約1秒CPU sampleは`[10.3,9.3,10.0,8.0,11.7]%`で通過した。これを受けた直列Cargo Release buildではcompile自体が完了したが、wrapperはJob内に残ったMSVC `VCTIP.EXE` PID34268を検出してexit1とした（Cargo root 1,152,587,638 B開始、observed peak 1,159,155,367 B、終了1,152,677,780 B、fixed cap 6,175,228,536 B、deletions=0）。PID消失を確認した後の1回限定warm retryはexit0/1.115秒、容量増分0 B、deletions=0。現行の未追跡source `src/khc/record.rs`（SHA-256 `4f65cffe3d318a653e5691912513ae60e664459c65d95daf8577b9464932426c`）、`src/khc/mod.rs`（`21a2feda8a6f80ca9dbfd686df6425535e4c901fa42c0341b2c03c773546b694`）および`examples/khc_record_fast_bench.rs`（`cca5a8e24e26fb13222667c27de63b9a7ab7425ba0ed01c6db2ddee09288921b`）をRust 1.98.1のpinned `x86_64-pc-windows-msvc` toolchainでbuildしたRelease executableは1,326,080 B、SHA-256 `abcf5cbd839f059a8f633634eb1bc2c0cc49fdef2bd6b3f39e5168a6be019bbb`となり、旧337281… pinを置き換える。screen scriptのbinary guardと`STORAGE.md`の現行pinをこの測定前に更新した。入力`ptt5`/baseline、3 warm-up＋3 paired batch、42,127 B未満・64 MiB以内の採用条件、5 MiB/64 entry/300秒のrun上限は変更していない。測定は未開始であり、KRS3性能の結論はない。

この事前測定amendment後の`record-adaptive-screen.ps1` SHA-256は`c6377d4574c18bfa4d2f6b2a8e62998aa53e855e349b810802bd53175a9f8c56`。今回もscreen runner `32ea537c89d164c9a5f09cbfe0e59127e89fdb85211d9b8f02f57e02780e9ef6`、容量計算script `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`、lifecycle module `1c5ca9c2657012a005d3af7e35dcb3f57b7f35985bd574d480bed3399081e2cf`は固定pinに一致した。build入力の識別用に`src/**/*.rs`・`examples/khc_record_fast_bench.rs`・`build.rs`・`Cargo.toml`・`Cargo.lock`の41 fileをSHA-256し、相対pathをordinal順、各行を`path<TAB>length<TAB>file-SHA256`、LF区切り、UTF-8・末尾LFなしで連結したmanifest digestは`8ee15d33b8350c23f9285073a93078af8b2e50981196ae0f6720f034f28e74f2`（Cargo.toml `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac`、Cargo.lock `0e1e33cc2ae1bf9bb2abfc870f0a6a6e0d20a99536bbfa7d398fa99bc9f64865`）。外部CPU sampleの実時刻は22:52:07.995–22:52:13.505 JST。`record-adaptive-screen.ps1`は新しいbinary SHAだけを許し、既存baseline integrity・input identity・run limits・candidate gateを据え置く。まだscreen用runは登録していない。

2026-10-16 22:59–23:00 JSTの再度の登録前容量確認で`Assert-KhcStorageBudget -ReserveBytes 16,777,216`は通過した。build 1,152,677,780 B、external Temp 70,150,998 B、通常保全169,585,803 B、両者合算239,736,801 B（2 GiB枠内）、Cargo 1,152,677,780 B（6 GiB枠内）、lifecycle 148,826,083 B（224 MiB枠内）、build+Temp+保全合算1,392,414,581 B（30 GiB枠内）、最終preflight時のC:空き61,484,765,184 Bである。5 MiB runに64 KiB entryを64件以上予約できることも確認し、計算上の空きは1,201件。run未登録・未起動。

2026-10-16 23:00:38.080–23:00:43.695 JSTの登録直前の外部5×約1秒総CPU sampleは`[32.5,60.7,40.2,14.3,31.4]%`、最大60.7%で15%以下条件に失敗した。直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動で、失敗後のartifact hash・storage preflight・計測processの起動はしていない。processは停止・変更せず、同一負荷の再試行はせず、次のsampleは23:10:43.695 JST以降とする。

2026-10-16 23:11:17.872–23:11:23.560 JSTの外部5×約1秒総CPU sampleは`[28.2,16.3,43.4,60.8,60.3]%`、最大60.8%で15%以下条件に失敗した。直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動で、失敗後のartifact hash・storage preflight・計測processの起動はしていない。processは停止・変更せず、同一負荷の再試行はせず、次のsampleは23:21:23.560 JST以降とする。

2026-10-16 23:21:40.479–23:21:46.392 JSTの外部5×約1秒総CPU sampleは`[20.2,24.2,20.8,20.3,24.6]%`、最大24.6%で15%以下条件に失敗した。直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動で、失敗後のartifact hash・storage preflight・計測processの起動はしていない。processは停止・変更せず、同一負荷の再試行はせず、次のsampleは23:31:46.392 JST以降とする。

- 4つの初期モデル・wire metadata・width schedule・40-byte headerをKRS2と共通化し、payloadだけを適応CDFで符号化する。新しいside informationは増やさない。rANS totalは既存と同じ32768に固定し、6-byte/event journalを使う。
- 各class/symbol countはwireへ直列化した初期`Model.freq`でseedし、decoderもwire modelだけから同じstateを再構成する（encoderだけが見られるraw histogramからseedしない）。eventは「現在CDFでrANS区間を使用 → active classのsymbol countとclass-local event countをchecked increment → そのclassの1024 eventごとに、そのclassのcountだけceil(count/2)へrescale → `Model::normalize()`でそのclassのCDFを再構築」の順にする。初期頻度0のsymbolは0のまま。未観測のclassは初期CDFを保つ。encoder/decoderは同じ手順・既存のsymbol順tie-breakを共有し、adaptive stateをframeへ保存しない。既存`information_bound::impossible()`は固定CDFの下限なのでKRS3の枝刈りに流用しない。
- 初期段階はcandidate-only block E2Eと既知開発データscreenに限定し、holdoutはmanifest全体のrights・source-family・prior-use・recipe・判定条件が凍結するまで使わない。製品archive revision/APIへ採用するのは、候補が通常の製品経路で完全復元し、既知ptt5の完全書庫で42,199 B以下となった場合に別途判断する。未達ならno-goとし、採用・7-Zip優位を主張しない。

実装前に追跡する失敗モード： (1) initial modelがstreamを表さずsymbol frequency=0またはsupport=0で失敗する、(2) encoderだけraw histogramからseedし、decoderのwire `Model.freq` seedと分岐する、(3) encoder/decoderのevent順・class決定・class-local 1024境界が1つずれてpayloadを誤復号する、(4) global event counterを誤って使いrare classを未観測のまま変質させる、(5) static CDF前提の`information_bound::impossible()`がadaptive candidateを誤って枝刈りする、(6) rescale時のゼロsymbol復活、tie-break差、frequency total !=32768、(7) count/event counterのoverflow、(8) `scan()`とscheduleの幅更新位置が一致しない、(9) event journal 2,097,152上限またはmodel/schedule/payload bound超過、(10) adaptive state/LUT/rescale scratchを含む64 MiB論理memory boundの過少計上、(11) header magic/version/reserved/length/CRCまたはtrailing bytesの不正を受理する、(12) KRS3 magicを明示dispatchせず別codecへ誤送する、(13) empty・短小・stored/fallback・multiple classを処理できない、(14) 破損frame後に同一processで次の正常frameへ復帰できない、(15) KRS2既存revisionの出力bytes/復号互換を壊す、(16) block frameだけ小さくなりouter archive/manifest費用込みで7-Zipを下回れない、(17) candidateが遅い・memory負荷を増やす、またはCPU/storage gateを外す。最初のE2Eはcandidate-only block経路とし、raw生成時に正確に数えたclass0/class3の1023・1024・1025 event、class1/2を含む複数class、再encode決定性、破損復帰、固定KRS2入力frameのbyte/SHA維持を通す。製品archive revision/APIへの統合は候補評価後の別段階とする。unit testは追加しない。

KRS2既存出力の固定基準は、KRS3変更前に完了した登録済みProduct KCS1 E2E `dd7ef525c092448299644a4d37183656` の保全ZIP（SHA-256 `914f84d4d00ca721cbb186685e83feea4bbce7949b01dbdf74db8f8318e77dfd`）内`api/legacy-6.khc`から得た。入力は`b"legacy format compatibility\n"`を32回連結した896 B（SHA-256 `b44eed3ac742f6c6ac9a39309d2c8f60b7f1cd1b1ea84b930bf5473c7d06451b`）、revision 6のKRS2 frameは148 B（SHA-256 `ae1dbbf3d204b3fee9bd0a68242c5e5aa0811cf2910584868353e6a4d8b07d6e`）。候補E2Eはこの入力の`RecordFastTrial` frame全byteが一致することを要求する。

class境界用rawは、始端255の後に頂点`v ∈ [64,127]`、有向辺`v → v XOR k`（k∈{1..17,32}）の決定順Euler cycle（頂点64から開始）を連結して作る。このグラフは18-regularで連結、1152辺を持ち、N≤1027で使う隣接pairは一度ずつである。width=1を保ち、長さN=1023..1027ではclass0 event=N、class1=1（pred=0の初期literal）、class2=1（pred=255の2番目literal）、class3=N−2となる。class3 residualは最大18 symbolに限る。E2Eはpair重複なし・隣接byte不一致と、このfield構造から導くevent数を検査する。よってclass0とclass3がそれぞれ1023/1024/1025で境界を越える。frameが全caseでKRS3になること、反復encode byte一致、decode raw bytes一致を要求する。

KRS3 codec本体・block dispatch・archive作成拒否guardとcandidate-only E2Eは実装・Release build・登録済みE2Eまで完了した。次は事前登録のCPU条件を満たした後にのみ既知ptt5 screenへ進み、通常archiveへの統合はKRS3 block/complete archiveが7-Zip比較条件を満たす場合に別途判断する。holdoutは権利・family・prior-use・recipe・判定条件のmanifest全体が凍結するまで使用しない。
2026-10-16にRelease `unlhare-cli`と`khc_spatial_e2e`を`run-serial-cargo.ps1`経由でbuild（exit 0、serial、transient14MiB枠内）。登録済み`product-spatial-e2e.ps1`／5MiB・64-entry runnerの最終E2E runは`59dede9a234e47f38326c68540353142`、保全ZIP 37,202 B・SHA-256 `3080564aee5c09860f524727fc8ceb4ae83cfad27e8f110a77ad833740900e34`、manifest SHA-256 `8f6f076a0e424a8196f90cd52a98065201e155591019976dbac7b1409992dcf1`、`result.json` SHA-256 `fed9a96b7de5c885660c725fc3272270f6e0c4a6be64cd64263fa2364ce6fa85`。保全物は`%LOCALAPPDATA%/Codex/TaskArtifacts/UnLhaRe/storage-lifecycle/runs/59dede9a234e47f38326c68540353142/recovery.zip`。CLI SHA-256 `76a28dd6c61617d9888d8a4e7c6adafd8cc4226d0d7f60ed0cbcb154e70beccd`、E2E SHA-256 `3b1a585ea01a171ea94e8250b31a5ef8a11b25e5fd6e1230b5a842ce9e14ebe0`。

`api-e2e`成功：synthetic raw長1023〜1027 Bの全5入力がKRS3を選択し、frameは`[643,644,644,645,646]` Bで各入力へbyte完全一致で戻り、再encodeも決定的。class0は1023/1024/1025 event、class3は1021/1022/1023/1024/1025 eventを通り、class1/2を含む。KRS2固定golden 148 Bはframe SHA-256 `ae1dbbf3d204b3fee9bd0a68242c5e5aa0811cf2910584868353e6a4d8b07d6e`でbyte一致。17 malformed-frame rejects後すべて同一processで正常frame復帰、4 fallback cases、archive作成は明示拒否。既存製品KCS1 E2Eの正常frame9件・malformed28件回復・revision1〜6確認も成功。初回run `8fd37e9ed23f4bcab6865856069c0b88` はtest generatorのEuler graphが分断され、codec呼出し前に辺数assert（実545/期待1089）で停止したため、delta graphを連結化して再実行した。失敗runと最終runのTemp一時領域はいずれもPrunlet直CMDで削除・purge・finalize済み（operationId `4732678e76ee4ae8b4623c0bfa5496c0`／`a212c1c7b0df4002a9719f22c7572592`、AfterBytes=0）。

上記KRS3 frame bytesは合成境界入力だけのcorrectness診断で、KRS2/7-Zip比較でもbenchmarkでもない。E2E JSONの`memory_gate:true`は既存spatial/product経路のgateであり、KRS3 process peak memory測定を意味しない。KRS3 codeには64MiB論理gateを追加済みだが、KRS3の大入力runtime memoryは未検証。製品archive revision/APIは未統合・拒否状態のまま。2026-10-16の新しい5×1秒CPU sample `[18.2,21.2,21.1,18.8,20.3]%` は事前登録15%上限を超えたため、ptt5性能screen・holdout・7-Zip比較は行っていない。日本語holdout manifest/rights/source-familyも未凍結で、7-Zip優位・目標達成は主張しない。

追記：2026-10-16 11:58:12 JSTに採取した新しい5×1秒総CPU sampleは`[25.9,19.7,20.7,21.0,20.5]%`で、全件15%以下の事前条件を満たさなかった。KRS3性能測定・ptt5 screen・holdoutは開始していない。その後のread-only容量preflightでは、5MiB/64-entry run用16,777,216 B予約が通過し、lifecycleは139,596,703/167,772,160 B、共有Cargoは1,035,592,783/6,442,450,944 B、build+Temp+TaskArtifacts合算は1,265,551,411 B、Temp70,150,998 B・TaskArtifacts159,807,630 B、空き容量93,194,469,376 Bだった。容量は通るがCPU条件未達のためrun未登録。

2026-10-16 12:11:50 JSTの5×1秒総CPU sample`[20.6,21.0,19.6,19.8,20.0]%`、12:18:12 JSTのsample`[20.1,19.3,19.6,21.9,22.7]%`、12:23:58 JSTのsample`[25.1,20.9,21.7,21.2,19.9]%`、12:37:27.761 JSTのsample`[18.7,23.6,24.4,19.3,24.7]%`はいずれも15%上限を超えた。12:48:32.325 JSTのsample`[11.6,10.3,9.1,10.2,15.4]%`も最後の1 sampleが上限を超えたため不合格。12:58:48.850 JSTのsample`[19,9,10,10,22]%`も2件が15%超過して不合格。いずれの不合格時もKRS3 screenは未登録・未起動で、容量・hash preflightもせず、processは停止・変更していない。

2026-10-16 13:09:25.017 JSTの新しい外部5×1秒総CPU sampleは`[10,7,4,8,10]%`で15%以下を通過した。13:10:34.161 JSTの再preflightでは5MiB/64-entry run用16,777,216 B予約が通過し、build 1,038,235,320 B、Temp 70,150,998 B、TaskArtifacts 159,807,630 B、Cargo 1,038,235,320 B、lifecycle 139,596,703 B、build+Temp+TaskArtifacts合算1,268,193,948 B、空き85,638,828,032 B、未完了run 0件だった。実行前hashはscreen `982b0b54bdf78e13837c9e2573c80acf41fa4a7951db517c2596decb8bc89706`、module `224ec8024fa114a6f3a8e7f97e211b149aeb49ae7529659e2119779c81d26130`、runner `d4e88ac0c5a5fadd9541888624bfab7917b2ea84a252ed85197d310c030b854c`、disk-budget `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`、Release benchは既定pinと一致する`337281256be17a9ed0f99f221d7bfee64c125294c0bc4a2a84ebc0a2ef5ee`、recovery ZIPは既定pinと一致する`882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`、`input/ptt5` memberは513,216 B / SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`だった。

登録run `436424585f28435cacb5c7ba56e9599a`（work path `C:\Users\IMT\AppData\Local\Temp\Codex\UnLhaRe\run-2d05c0416679498d9bcdb0d2bec75c56`）は子screenの内部5×1秒CPUゲート不合格分岐で`Write-Report`を呼んだが、その時点でwork rootがまだなく`record-adaptive-screen.json`の作成に失敗しexit 1となった。CPUゲートが5 sample後に不合格分岐へ入ったことは分かるが、書込み失敗により各値は保存されていない。測定処理・bench起動前で、性能値・サイズ値はない。cleanup requestは`requires_prunlet=false`、0 bytes・0 entries、work不存在だったため、所有PID/bench process消失を確認後、Prunlet削除なしで`storage-cleanup.ps1 -Stage Finalize`が`complete`（Before/After 0）を返した。故障箇所に対し`record-adaptive-screen.ps1`の`Write-Report`が報告前に許可済みwork rootを作るよう修正し、PowerShell AST syntax parseはPASS。修正版script SHA-256は`ed33e59641b29ec2241a4221d9174451d4fcba4a80c05a4e0b173dcc5d850c9f`。同一CPU負荷で再試行せず、次のscreen試行は13:22 JST以降の新しいCPU sample・hash・容量preflight通過後とする。

2026-10-16 13:23:03.906 JSTの新しい外部5×1秒総CPU sampleは`[25,26,21,16,22]%`で、全件15%以下の条件に失敗した。修正版KRS3 screenは未登録・未起動で、fresh hash・storage preflightも行っていない。processは停止・変更せず、同一条件での再試行はしない。次のsampleは13:33:03.906 JST以降に限る。
2026-10-16 13:33:19.945 JSTの次の外部5×1秒総CPU sampleは`[18.5,17.5,20.2,20.9,15.9]%`で、最大20.9%のため同じ15%以下条件に失敗した。修正版KRS3 screenは未登録・未起動で、fresh hash・storage preflightも行っていない。processは停止・変更せず、同一負荷で再試行しない。次のsampleは13:43:19.945 JST以降に限る。
2026-10-16 13:43:35.448 JSTの次の外部5×1秒総CPU sampleは`[18.2,16.9,14.7,23.0,18.7]%`で、最大23.0%のため同じ15%以下条件に失敗した。修正版KRS3 screenは未登録・未起動で、fresh hash・storage preflightも行っていない。processは停止・変更せず、同一負荷で再試行しない。次のsampleは13:53:35.448 JST以降に限る。
2026-10-16 13:53:58.192 JSTの次の外部5×1秒総CPU sampleは`[20.2,18.4,19.7,18.5,22.5]%`で、最大22.5%のため同じ15%以下条件に失敗した。修正版KRS3 screenは未登録・未起動で、fresh hash・storage preflightも行っていない。processは停止・変更せず、同一負荷で再試行しない。次のsampleは14:03:58.192 JST以降に限る。
2026-10-16 14:06:10.590–14:06:17.357 JSTの外部5×1秒総CPU sampleは`[19,20,16,19,20]%`、最大20%で15%以下条件に失敗した。アクティブリスト復号変更後の製品pipeline E2Eは、Release build・run登録・実行のいずれも未開始で、KRS3 screenも未登録・未起動。hash・storage preflightも行わず、processは停止・変更していない。同一負荷で再試行せず、次のsampleは14:16:17.357 JST以降に限る。
2026-10-16 14:17:32.335–14:17:37.825 JSTの外部5×1秒総CPU sampleは`[27,30,24,19,20]%`、最大30%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後にrun用storage preflightも行わず、processは停止・変更していない。14:13 JSTのread-only確認時点でscreen/runner/module hash、固定recovery ZIP、Release bench hashはそれぞれpinと一致していたが、今回のscreen実行preflightではない。同一負荷で再試行せず、次のsampleは14:27:37.825 JST以降に限る。
2026-10-16 14:27:49.903–14:27:55.459 JSTの外部5×約1秒総CPU sampleは`[20.0,19.8,18.5,20.7,22.7]%`、最大22.7%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、fresh artifact hash・run用storage preflightも行わず、processは停止・変更していない。同一負荷で再試行せず、次のsampleは14:37:55.439 JST以降に限る。
2026-10-16 14:38:06.001–14:38:11.543 JSTの外部5×約1秒総CPU sampleは`[21.6,19.4,21.8,21.6,22.8]%`、最大22.8%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後にfresh artifact hash・run用storage preflightも行わず、target processは停止・変更していない。同一負荷で再試行せず、次のsampleは14:48:11.543 JST以降に限る。
2026-10-16 14:48:46.499–14:48:52.039 JSTの外部5×約1秒総CPU sampleは`[23.2,25.4,17.0,14.1,18.4]%`、最大25.4%で15%以下条件に失敗した。`vctip` PID26616の稼働を確認した。KRS3 ptt5 screenは未登録・未起動で、fresh artifact hash・run用storage preflightも行わず、processは停止・変更していない。同一負荷で再試行せず、次のsampleは14:58:52.039 JST以降に限る。
2026-10-16 14:59:24.236–14:59:29.796 JSTの外部5×約1秒総CPU sampleは`[23.8,22.2,20.9,11.5,10.6]%`、最大23.8%で15%以下条件に失敗した。`vctip` PID26616の稼働も継続していた。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後にfresh artifact hash・run用storage preflightも行わず、processは停止・変更していない。同一負荷で再試行せず、次のsampleは15:09:29.796 JST以降に限る。
2026-10-16 15:09:46.784–15:09:50.815 JSTの外部5×約1秒総CPU sampleは`[15.9,9.4,10.8,10.9,10.3]%`で、最大15.9%のため15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後にfresh artifact hash・run用storage preflightも行わず、processは停止・変更していない。同一条件で再試行せず、次のsampleは15:19:50.815 JST以降に限る。
2026-10-16 15:20:05.692–15:20:11.217 JSTの外部5×約1秒総CPU sampleは`[30.2,29.6,34.8,39.7,27.2]%`で、最大39.7%のため15%以下条件に失敗した。`vctip` PID34180を確認した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のfresh artifact hash・run用storage preflightも行わず、processは停止・変更していない。同一条件で再試行せず、次のsampleは15:30:11.217 JST以降に限る。
2026-10-16 15:33:11.741–15:33:17.439 JSTの外部5×約1秒総CPU sampleは`[18.7,19.0,23.7,8.8,29.2]%`で、最大29.2%のため15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、計測用processは起動・停止していない。次のsampleは15:43:17.439 JST以降に限り、条件を満たした場合だけexact artifact hashと固定5MiB/64-entry/300s storage admissionを再確認する。
2026-10-16 15:44:18.952–15:44:24.492 JSTの外部5×約1秒総CPU sampleは`[17.7,17.4,24.6,18.1,11.4]%`、最大24.6%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のartifact hash・storage preflightも行わず、計測用processは起動・停止していない。同一条件で再試行せず、次のsampleは15:54:24.492 JST以降に限る。
2026-10-16 15:54:59.344–15:55:04.834 JSTの外部5×約1秒総CPU sampleは`[17.8,21.0,18.6,17.8,19.5]%`、最大21.0%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のartifact hash・storage preflightも行わず、計測用processは起動・停止していない。同一条件で再試行せず、次のsampleは16:05:04.834 JST以降に限る。

2026-10-16 16:06:00.944–16:06:06.426 JSTの外部5×約1秒総CPU sampleは`[34.9,18.8,17.3,18.2,18.5]%`、最大34.9%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のartifact hash・storage preflightも行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは16:16:06.426 JST以降に限る。

2026-10-16 16:16:16.672–16:16:20.684 JSTの外部5×約1秒総CPU sampleは`[25.7,25.5,26.5,28.3,24.4]%`、最大28.3%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のartifact hash・storage preflightも行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは16:26:20.684 JST以降に限る。

2026-10-16 16:26:55.994–16:27:00.005 JSTの外部5×約1秒総CPU sampleは`[47.0,36.2,34.9,46.7,22.2]%`、最大47.0%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のartifact hash・storage preflightも行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは16:37:00.005 JST以降に限る。

2026-10-16 16:37:11.443–16:37:17.095 JSTの外部5×約1秒総CPU sampleは`[26.6,55.8,53.8,51.7,18.8]%`、最大55.8%で15%以下条件に失敗した。KRS3 ptt5 screenは未登録・未起動で、CPU失敗後のartifact hash・storage preflightも行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは16:47:17.095 JST以降に限る。

### 2026-10-16 アクティブリスト復号の製品E2E

15% CPU条件は性能screen用であり、時間・資源上限を持つ製品correctness E2Eには適用しないことを`STORAGE.md`の登録条件とscriptで確認し、性能測定は行わず登録済みCanterbury11 E2Eのみを実行した。初回のserial Release buildはCargo側でcompile完了した後、drain猶予後も`vctip.exe`子processが1件残ったためwrapperがexit1で失敗扱いにした。processは停止せず、その後自然終了したことを確認してから一度だけbounded incremental retryし、`run-serial-cargo.ps1`がexit0を返した。build後のRelease CLI SHA-256は`f1070c813264dcaf981c6eb99c993c5035b10061a5538583be26997966059c00`、E2E exampleは`f78d0333b5b48095258e7046a0fe533f550444e31164455c872793a61c14ca08`。

Canterbury入力は11 file / 2,810,784 Bで固定manifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`と一致。run `5e93ed1e99ca4f5ab29d490db421e50b`は24 assertions/groupsで成功し、全11 fileの作成・復元byte/CRC、破損優先度・取消・空directory・1MiB+17境界・連続呼出しを検証し、BinaryAdaptive KHC1 rev2 method-1 frameを8個通過した。生成archiveは466,395 B、SHA-256 `0dcb76a2e1721504c28b13de38e05eca737c1b49423e83b6b345f3e8fa0a46a8`。report内のcreateとE2E経過は573.149 ms / 1,560.149 msだが、これは性能benchmarkではなく、7-Zip比較・速度・資源優位性の主張に使わない。

work directoryはPrunlet直接CMDのdelete preview/result、purge preview/apply、`storage-cleanup.ps1`各validatorを通して除去した。Run state `complete`、80 items / 15,823,838 B、AfterBytes=0。保持recovery ZIPは8,765,120 B / SHA-256 `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb`、manifest SHA-256 `8ed36aad362091bc637e6411d2bde40f61bff58f4111f555124a73634bcb0e02`、ZIP内`report.json` SHA-256 `0fc26f33b26638e926829b71629cd2cbf5f6b4c900333801fa62b06f4f0b7045`で、3値を要求記録と照合済み。KRS3/ptt5性能screenはCPU gate不合格のまま未実行。

### 2026-10-16 KRS3 archive revision 8の製品統合E2E

`run-serial-cargo.ps1 -TransientMiB 256`経由でReleaseの`unlhare-cli`と`khc_spatial_e2e`をx86_64-pc-windows-msvc向けにbuildした（jobs=1、exit 0、59.09 s、target使用量1,038,318,976→1,038,381,474 B、peak1,044,887,832 B、deletions=0、残量5,136,847,062 B）。CLI SHA-256 `fbfbad667cb2e9a03848c5b32a9f029577abf20003c9ad8af3a8a65e29baafa1`、example SHA-256 `acf59f0983609679452ccfd367a01c3c99cc1cf0c8d154a58589b4e664865314`。

固定5MiB/64entry/300秒の`product-spatial-e2e.ps1`を登録runner経由で実行した。run `b9cfe59cce554609bd111b91ce7a1ae2`は26 checkをすべて期待どおりに完了。API E2EはKRS3 frame 5個（643, 644, 644, 645, 646 B）、fallback 4 case、frame malformed recovery 17、revision 8 archive malformed recovery 17、revision 1〜7読込を報告し、`memory_gate=true`。CLI revision 7/8双方でcreate/list/test/extract、byte/SHA一致、既存archive/output不変更、破損test/extract拒否後の再検証を通過。revision 8 archiveは839 B、revision 7 archiveは307 B。これは correctness E2Eで性能benchmarkではない。

work directory `C:\Users\IMT\AppData\Local\Temp\Codex\UnLhaRe\run-8ff35f49e51844838946aaaf0cd9ce8b`はPrunlet直接CMDのdelete preview/result、purge preview/applyと各lifecycle validatorを通して清掃した。operation `494d5303e8334263a86307098f69a46e`、59 items / 42 files / 3,168,852 B、run `complete`、AfterBytes=0。再現用recovery ZIPは `C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\b9cfe59cce554609bd111b91ce7a1ae2\recovery.zip` に保持し、45,072 B / SHA-256 `9f910dfa7e34f4f4b43c9b136969f63b60f3fb06a8c78c72792fc057e13eff03`。manifest SHA-256 `44e5ccf110d5e0b8ba9b7bdfb487b61cc85d35a2cc5d222c20a73f014c9a31ca`。ZIP内`result.json` 6,972 B / SHA-256 `582277162d29fb4ccc2feccf7c5b7a2f56293f53933cc63c25e42762ca72f003`をcleanup manifestの期待値と照合済み。候補比較screenは直前のCPU gate不合格により未実行で、性能優位は未評価。

KRS3の製品書庫比較に備え、`record-fast-7zip-screen.ps1`へ明示的な`IncludeRecordAdaptiveCandidate` modeを追加した。通常のBinaryAdaptive/KRS2/7-Zip screenを保持しつつ、このmodeでは同じ固定開発ptt5だけを受け付け、KRS3 revision8・frame magic選択を記録する。登録runnerは12MiB/64-entry/900秒を固定し、script内CPU gateも追加した。`STORAGE.md`にKRS3 block gate通過後の手順を記載した。両PowerShell scriptのAST parseはerrors 0、対象3ファイルの末尾空白0。registered E2E/product comparisonは未実行で、性能結果ではない。現在の外部CPU gateは2026-10-16 16:37:11.443–16:37:17.095 JSTに`[26.6,55.8,53.8,51.7,18.8]%`、最大55.8%で失敗。block screen未登録・未起動、hash/capacity preflightなし。次回CPU sampleは16:47:17.095 JST以降で、product comparisonはblock-size gate合格後の別測定として扱う。

### 2026-10-16 選択ページの監査（条件付き候補・非凍結）

厚労省の[2025年版本文ページ](https://www.mhlw.go.jp/stf/wp/hakusyo/roudou/25/25-1.html)は、全体版PDFと分割版PDFへのリンクを掲載するreport landing pageで、確認した表示範囲にHTML本文は見当たらなかった。このため以前の「HTML prose」候補としては不適合とし、PDFの本文は取得・閲覧せず、natural-language proseの3 family目にも数えない。

候補採用・権利確認手順を記載した後、内閣府の[白書目次](https://www8.cao.go.jp/kourei/whitepaper/w-2025/html/zenbun/index.html)から候補章[高齢化の現状と将来像](https://www8.cao.go.jp/kourei/whitepaper/w-2025/html/zenbun/s1_1_1.html)を閲覧した。章には総務省「人口推計」を出典とする表、図の画像、CSVへのリンクがある。厚労省の[公表ページ](https://www.mhlw.go.jp/stf/newpage_63870.html)から2025年版のHTML本文[25-1.html](https://www.mhlw.go.jp/stf/wp/hakusyo/roudou/25/25-1.html)へ到達できたが、当該ページは全体版・分割版PDFへのリンクを載せるlanding pageでHTML本文を確認できず、自然文候補から除外した。環境省の[候補章](https://www.env.go.jp/policy/hakusyo/r07/html/hj25010201.html)はIRP 2024報告書とIPBES評価を含む説明を掲載する。CAOの[利用規約](https://www.cao.go.jp/notice/rule.html)は権利表記がない内容にPDL1.0を適用し、白書は別ルール対象一覧にない。総務省統計局の[利用規約](https://www.stat.go.jp/info/riyou.html)と社人研の[利用条件](https://www.ipss.go.jp/site-ad/link/anlink.html)も、各機関が公開する自身のコンテンツへPDL1.0を適用する。出典表示・リンクのみで、各規約がCAOの白書HTML全体へ自動適用されるとは読めない（規約文面からの適用範囲についての判断）が、保護される表現の転載・埋込みや図表・CSV・assetの個別権利は別途確認を要する。MLITの[著作権案内](https://www.mlit.go.jp/link.html)は特記のない情報にPDL1.0を適用し、[別紙](https://www.mlit.go.jp/page/kanbo01_hy_003657.html)の別ルール対象に白書は列挙されていない。一方、閲覧したCAO／環境省／MLIT各章には表・図・第三者出典またはロゴ・画像への参照があり、全markupと個別の権利表示は未確認のため、いずれも単一HTML候補として条件付き、manifest非凍結とする。同一テーマのX全体検索結果（前段で取得した「日本政府 白書 著作権 利用規約 PDL1.0 PDL2.0 再利用」、0件・`completeSearch=false`）を再利用した。raw payloadのlocal download・hash・抽出・変換・圧縮は行っていない。

2026-10-16に自然文候補表へ追加してから[国土交通白書HTML版](https://www.mlit.go.jp/hakusyo/mlit/r06/hakusho/r07/index.html)を開き、候補頁[第I部第1章第1節](https://www.mlit.go.jp/hakusyo/mlit/r06/hakusho/r07/html/n1110000.html)を閲覧した。本文には文章と「国土交通省」を出典とする図表画像がある。[国土交通省の著作権案内](https://www.mlit.go.jp/link.html)は特記のないコンテンツにPDL1.0を適用する一方、組織のシンボル・ロゴ等を適用対象外とし、[別紙](https://www.mlit.go.jp/page/kanbo01_hy_003657.html)は別ルールの対象を列挙するが白書自体は挙げていない。選択頁には国土交通省ロゴ画像も表示されるため、HTML内のasset参照と図表の利用範囲を解決するまでは条件付き候補に留める。Web閲覧のみで、raw payloadのlocal download・hash・抽出・変換・圧縮はしていない。Xは同日取得済みの同テーマ検索結果を再利用した。

選択ページの具体的な共有データ・asset境界を再確認した。内閣府の表1-1-1は総務省「人口推計」令和6年10月1日確定値を明記し、図1-1-2～4の画像・CSVリンクと、国立社会保障・人口問題研究所の2023年将来人口推計を参照する。環境省の候補節はIRP「世界資源アウトルック2024」、IPBESの2024年ネクサス評価、UNDESA・UNFCCCの活動を記述する。国土交通白書候補節は少子高齢化・人口減少を背景に、建設・運輸等の担い手不足とサービス供給制約を説明し、図表Ⅰ-1-1-1の画像、国土交通省ロゴ画像、ページナビゲーションを含む。CAO章の表示本文は高齢化率・人口構成と将来推計、MLIT章の表示本文は担い手不足・供給制約が中心であり、確認できる共通項は人口動態という背景文脈に留まる。ただし図表画像を含む正確な文章重複・同一数値列は未確認のため、独立familyとは断定しない。これらは公式HTMLの表示上で確認した参照・文章であり、画像・CSV等の実体は開いていない。表示結果だけでは全markup・埋込み要素・第三者権利を網羅できず、3候補とも条件付き・manifest非凍結のままとする。全HTML bytesを入力にするか、参照先assetを取得しないかというrecipeも、holdout取得前に明示する必要がある。再確認ではraw payloadのlocal download・hash・抽出・変換・圧縮・測定を行わず、同日取得済みの同テーマX検索結果（0件、`completeSearch=false`）を再利用した。


2026-10-16 FSA candidate review: the [official Access FSA issue index](https://www.fsa.go.jp/access/index.html) identifies No.276 as issued 2026-08-27 and lists HTML/PDF editions; No.276 is therefore a single-issue HTML candidate, not a selected article or PDF. FSA's [website terms](https://www.fsa.go.jp/rules/) were updated 2025-10-09 and state that copyright belongs to FSA unless otherwise specified, with PDL1.0 applying absent a rights notice; the terms require source attribution and a separate edit notice. [PDL1.0](https://www.digital.go.jp/resources/open_data/public_data_license_v1.0) allows reuse/adaptation and commercial use for covered content, subject to attribution. A browser-rendered review of the official [No.276 HTML](https://www.fsa.go.jp/access/r8/276.html) showed article prose and at least one graph image captioned as sourced from a separate FSA quantitative-data collection; the exact page-level rights marks, HTML markup, image rights, embedded/linked assets, shared references, and text overlap remain unexamined. Plumivox `scope=all` search `金融庁 消費者庁 広報誌 コラム 著作権 再利用` returned 0 posts with `completeSearch=false`, which is non-exhaustive and not rights or prior-use proof. No candidate bytes or PDF/image assets were downloaded, hashed, transformed, compressed, frozen into a manifest, or measured. The FSA issue remains overflow-only and conditional.

The Board of Audit fallback was identified from the [official FY2024 report contents](https://report.jbaudit.go.jp/org/r06/2024-r06-mokuji.htm) by the exact case title/item number before the specific report page was opened. During direct-URL resolution the official search result surfaced a short snippet after this title-based selection; that snippet was not used to choose or assess the candidate. Its [site terms](https://www.jbaudit.go.jp/general/term.html) state PDL1.0 applies absent a specific rights marker, require source/edit attribution, and exclude logos/marks; their example explicitly cites the `report.jbaudit.go.jp` report database. After the candidate was added to the table, the exact [HTML report page](https://report.jbaudit.go.jp/org/r06/2024-r06-0059-0.htm) was opened for visible-content review. It contains explanatory prose and an HTML table of the reported case, names the program and companies, and lists subsidy/expense amounts. The rendered page shows no figure/image or item-specific copyright/attribution notice; those negative observations do not certify unreturned markup or linked assets. This overflow candidate remains conditional pending exact raw-HTML/markup, rights and overlap checks. No report/PDF payload was downloaded or locally processed. Same-day Plumivox search `裁判例 検査報告 政府 公的記録 著作権 再利用` returned 0 posts with `completeSearch=false` and is not legal evidence.

2026-10-16 follow-up: reopening the official terms and selected HTML page confirmed that the terms explicitly apply PDL1.0 to site content absent a specific rights marker, ask for source and edit attribution, and exclude organizational/project logos and marks; the terms' attribution example specifically references the report database. The selected HTML visibly contains the explanatory narrative and table but no explicit page-level copyright notice in the returned text. The page display cannot certify full raw markup, hidden/embedded content or every linked element, so the candidate remains conditional and is not frozen. No report payload was acquired, hashed, extracted, transformed, compressed or measured; the already-recorded same-day X search was reused.

### 2026-10-16 KRS3 registered screen internal CPU gate

外部5×約1秒CPU sample `2026-10-16 16:47:25.967–16:47:31.576 JST`は`[12.7,9.1,11.2,9.2,9.5]%`、最大12.7%で15%以下を通過した。fresh artifact/input hashesは一致した。screen `record-adaptive-screen.ps1` SHA-256 `ed33e59641b29ec2241a4221d9174451d4fcba4a80c05a4e0b173dcc5d850c9f`、runner `run-storage-experiment.ps1` `32ea537c89d164c9a5f09cbfe0e59127e89fdb85211d9b8f02f57e02780e9ef6`、disk-budget `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`、storage module `1c5ca9c2657012a005d3af7e35dcb3f57b7f35985bd574d480bed3399081e2cf`、Release bench 1,326,080 B `337281256be17a9ed0f99f221d7bfee64c125294c0bc4a2a84b94ebc0a2ef5ee`、recovery ZIP 769,634 B `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`、`input/ptt5` 513,216 B `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`はいずれも固定値と一致した。登録runnerの5MiB/64-entry/300秒admissionを通過してrun `ed8fd486c70d4b3d937baed574df212e`を登録したが、子内16:48:20.114 JST CPU gateは`[16.8,21.7,36.7,19.3,38.6]%`で不合格、status `skipped-cpu-gate`、`measurements_started=false`となった。benchmark executableは起動していない。

保全reportは265 B / SHA-256 `d2c4c2b0c6099ccad4ca96882ca6c5f1c5c9a2b528ab4c3cf71ffd3b628940d9`。recovery ZIPは359 B / SHA-256 `c2e4b9a3d2602caf30cb71fb2106d983ca1b46f6ae4ab5c3271668d2028870dc`、manifest SHA-256 `4c91ef7944c89eedc48a271a3034e9d64f611d9f7917054c135e042f78478ff7`で、request期待値と一致。Prunlet direct-CMD staged cleanup operation `824c8a4b834d444c9051441758d4c132`はFinalize `complete`、AfterBytes=0。work root不在、pending runなし。測定なしのskip reportだけをTaskArtifactsに保持し、同条件のretryはしない。次回CPU sampleは17:39:47.037 JST以降。

2026-10-16 16:58:31.144–16:58:38.509 JSTの外部5×約1秒総CPU sampleは`[18,34,16,20,16]%`、最大34%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは17:39:47.037 JST以降に限る。

2026-10-16 17:08:49.221–17:08:55.022 JSTの外部5×約1秒総CPU sampleは`[16,18,16,31,21]%`、最大31%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは17:39:47.037 JST以降に限る。

2026-10-16 17:19:12.338–17:19:19.405 JSTの外部5×約1秒総CPU sampleは`[24,27,30,16,16]%`、最大30%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは17:39:47.037 JST以降に限る。

2026-10-16 17:29:41.178–17:29:47.037 JSTの外部5×約1秒総CPU sampleは`[31,24,19,18,21]%`、最大31%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは17:39:47.037 JST以降に限る。

2026-10-16 17:39:57.665–17:40:03.344 JSTの外部5×約1秒総CPU sampleは`[29.1,22.4,37.7,17.7,17.7]%`、最大37.7%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは17:50:03.344 JST以降に限る。

2026-10-16 17:50:22.555–17:50:28.080 JSTの外部5×約1秒総CPU sampleは`[28,26.9,35.9,18,17.8]%`、最大35.9%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは18:00:28.080 JST以降に限る。

### 2026-10-16 KCS1/KRS3 revision 8 製品correctness再確認

登録runner経由の`product-spatial-e2e.ps1`（5 MiB / 64 entries / 300秒）run `6f5274da439f46ada48c912cb4beb359`は、保全reportに26 invocationを記録した。各呼出しはscriptの成功/失敗期待値と照合され、通常操作・revision 1〜7読込・破損拒否後の再利用はexit 0、no-replace拒否と破損archiveの拒否は意図したexit 1で、予期しない結果はなかった。revision 7/8のcreate/list/test/extract、復元byte/SHA、既存archive/output不変更を確認した。API側はKRS3 frame 5個（643, 644, 644, 645, 646 B）、fallback 4 case、malformed recovery 17、revision 8 archive malformed recovery 17、`memory_gate=true`を報告。CLI archiveはrevision 7が307 B、revision 8が839 B。これは製品correctness E2Eのみで、benchmarkや7-Zip比較ではない。

実行CLI SHA-256 `fbfbad667cb2e9a03848c5b32a9f029577abf20003c9ad8af3a8a65e29baafa1`、E2E example SHA-256 `acf59f0983609679452ccfd367a01c3c99cc1cf0c8d154a58589b4e664865314`。report `result.json`は6,972 B / SHA-256 `29988cc4014c6d37a9ff80bb2d14a2647a73f22708cf0a23712822fafc934321`。

一時work tree `C:\Users\IMT\AppData\Local\Temp\Codex\UnLhaRe\run-f987b5e8112e42a295509ccb5f8f3c41`はPrunlet直接CMDのstaged cleanupでのみ除去し、run state `complete` / 59 items / 3,168,852 B / AfterBytes=0を確認した。work root不在、pendingなし。復元用recovery ZIPは45,073 B / SHA-256 `c2ae5c646a5b94cd2e5e8ada5246217f7e4b24840c8cb0cc4a7226f70788bf81`、`recovery.json`は42 files / SHA-256 `3524bba8d492bd0545fa3a4600dcbee2578ca93079a5ae076218b626a247bc51`。ZIP、manifest、report各hashを実ファイルと照合した。screenはCPU gateと固定tool/input/storage preflightを通るまで起動しない。

### 2026-10-16 日本郵便・国土地理院候補の公式metadata再確認

日本郵便の[UTF-8郵便番号データ説明](https://www.post.japanpost.jp/service/search/zipcode/download/utf-readme.html)は全国一括ZIP名`utf_ken_all.zip`、12万件規模、可変長CSVの15項目構成、UTF-8（BOMなし）・CRLFを掲載する。郵便番号データに限り日本郵便は著作権を主張せず自由配布を認めるが、これはサイト全体への許諾ではない。最新全データZIPは[配布ページ](https://www.post.japanpost.jp/service/search/zipcode/download/utf-zip.html)上で2.04 MBと表示され、月次差分には2026-09-30更新分がある。READMEはZIP内部のCSV member名を示さず、取得物SHA-256・不変スナップショットURLも未確定なので候補のままとする。payloadは未取得。

国土地理院の[面積調ページ](https://www.gsi.go.jp/KOKUJYOHO/MENCHO-title.htm)は2026-09-25に令和8年7月1日時点を公表したことを示す。[E2技術資料リスト](https://www.gsi.go.jp/REPORT/TECHNICAL/gsirgijutsu4.htm)は該当資料を完成年度2026・E2-No.93と確認できる。[技術資料案内](https://www.gsi.go.jp/REPORT/TECHNICAL/technical.html)ではウェブ掲載資料は申請不要・商用利用可、現行[コンテンツ利用規約](https://web2.gsi.go.jp/kikakuchousei/kikakuchousei40182.html)では特記がなければPDL1.0を適用し、第三者情報や法令制約は個別確認を求める。面積調ページ自体は測量法第12条の基本測量長期計画に基づく公表と説明する一方、CSV候補を測量法上の測量成果手続の対象外と断定できる資料は確認できていない。したがって権利クリアとはせず、共有データ、法令上の扱い、exact bytes/hash・prior-useを未解決のまま保持する。CSV本体はWeb previewも含め取得・閲覧していない。

同じテーマのPlumivox X検索は先行調査の`scope=all`検索（0件、`completeSearch=false`）を再利用した。これは非網羅的な検索であり、候補の適法性・非使用を証明しない。

### 2026-10-16 国税庁法人番号サンプルの利用条件確認（payload未取得）

国税庁の[基本3情報ダウンロード案内](https://www.houjin-bangou.nta.go.jp/download/)は令和4年4月版サンプルZIPを867KBと表示し、Web-API応答を含むと明記する。[利用規約](https://www.houjin-bangou.nta.go.jp/riyokiyaku/)は特記がなければ[公共データ利用規約（PDL1.0）](https://www.digital.go.jp/resources/open_data/public_data_license_v1.0)を適用し、出典記載と加工表示を求める一方、個別コンテンツに第三者の権利が含まれ得て、対象の特定がない場合も利用者が確認・許諾を得る責任を負うとする。さらに[サンプル説明書（令和4年4月版）](https://www.houjin-bangou.nta.go.jp/pc/download/images/k-sample-explain-r0404.pdf)は、名称は架空でも所在地に実在地名を用い、法人番号が実在の指定番号と一致する場合があるため、法人番号を利用するシステムの開発・改修以外での利用を「ご遠慮」願うとしている。圧縮性能ベンチマークはその用途に該当しないため、一般のPDL1.0表示とは区別して `k-sample-dl-r0404.zip` を評価コーパス候補から除外する。metadata-onlyのPlumivox X検索 `日本語 コーパス 頻度表 法人番号 オープンデータ ライセンス 再利用` は0件・`completeSearch=false`。payload取得・展開・閲覧・hash・圧縮・測定はしていない。

2026-10-16 18:02:01.786–18:02:09.982 JSTの外部5×約1秒総CPU sampleは`[24,46,19,12,20]%`、最大46%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは18:12:09.982 JST以降に限る。

2026-10-16 18:12:27.094–18:12:33.051 JSTの外部5×約1秒総CPU sampleは`[41,30,31,11,9]%`、最大41%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは18:22:33.051 JST以降に限る。

2026-10-16 18:23:11.299–18:23:16.904 JSTの外部5×約1秒総CPU sampleは`[31.2,28.3,44.5,19.6,18.5]%`、最大44.5%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは18:33:16.904 JST以降に限る。

2026-10-16 18:33:38.895–18:33:44.455 JSTの外部5×約1秒総CPU sampleは`[49.4,50.9,18.4,20.3,22.3]%`、最大50.9%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは18:43:44.455 JST以降に限る。

2026-10-16 18:43:54.776–18:44:00.424 JSTの外部5×約1秒総CPU sampleは`[37.8,27.1,43.9,26.1,19.3]%`、最大43.9%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは18:54:00.424 JST以降に限る。

2026-10-16 18:54:15.481–18:54:21.101 JSTの外部5×約1秒総CPU sampleは`[30.3,26.5,45.9,22.4,17.3]%`、最大45.9%で15%以下条件に失敗した。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflightは行わず、計測用processは起動・停止していない。同一負荷で再試行せず、次のsampleは19:04:21.101 JST以降に限る。

2026-10-16 19:04:10.342–19:04:15.934 JSTの外部5×約1秒総CPU sampleは`[28.3,26.6,26.5,44.2,20.7]%`、最大44.2%。前回sample終了後10分を満たす19:04:21.101 JSTより約10.8秒早く開始したため、これはCPU gateとして無効で採用しない。参考値自体も15%以下条件に失敗している。KRS3 block screenは未起動のまま、artifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のvalid sampleは今回の終了から10分後の19:14:15.934 JST以降に限る。

2026-10-16 19:14:32.712–19:14:38.306 JSTの外部5×約1秒総CPU sampleは`[28.1,25.7,21.6,48.2,15.8]%`、最大48.2%で15%以下条件に失敗した。10分以上のsample間隔は満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは19:24:38.306 JST以降に限る。

2026-10-16 19:25:13.569–19:25:19.311 JSTの外部5×約1秒総CPU sampleは`[25.7,27.9,24.3,36.9,13.8]%`、最大36.9%で15%以下条件に失敗した。10分以上のsample間隔は満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは19:35:19.311 JST以降に限る。

2026-10-16 19:35:32.318–19:35:37.899 JSTの外部5×約1秒総CPU sampleは`[18.4,17.8,36.1,30.0,15.7]%`、最大36.1%で15%以下条件に失敗した。10分以上のsample間隔は満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは19:45:37.899 JST以降に限る。

2026-10-16 19:45:51.242–19:45:56.923 JSTの外部5×約1秒総CPU sampleは`[21.0,35.0,47.0,19.6,12.2]%`、最大47.0%で15%以下条件に失敗した。10分以上のsample間隔は満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは19:55:56.923 JST以降に限る。

2026-10-16 19:56:36.299–19:56:41.989 JSTの外部5×約1秒総CPU sampleは`[66.5,69.2,38.8,40.5,46.7]%`、最大69.2%で15%以下条件に失敗した。10分以上のsample間隔は満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは20:06:41.989 JST以降に限る。

2026-10-16 20:06:50.680–20:06:56.275 JSTの外部5×約1秒総CPU sampleは`[23.6,17.1,35.7,9.2,8.4]%`、最大35.7%で15%以下条件に失敗した。10分以上のsample間隔は満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは20:16:56.275 JST以降に限る。

同じ失敗後のCPU非依存確認として、`Assert-KhcStorageBudget -ReserveBytes 536870912` が成功した（合算1,278,118,275 B、Cargo target 1,038,381,474 B、lifecycle 148,826,083 B、空き71,127,715,840 B、予約512 MiB）。共有直列wrapperで `cargo check --release --lib --target aarch64-apple-darwin`、`--target aarch64-pc-windows-msvc`、`--target x86_64-apple-darwin` を各1回コンパイルし、Cargoはいずれも `Finished release` を返した。最初の2ターゲットはwrapperが終了後2秒のJob drain中にMSVC `VCTIP.EXE`を1プロセス検出してexit 1としたが、各PIDは診断時点で既に終了済みで、同一コマンドの一度だけのcache-backed再確認はwrapper exit 0（各0.13秒）。3番目のx86_64 macOS checkは初回からwrapper exit 0。Cargo結果とwrapper結果を分けて記録する。次に `--bin unlhare-cli` を同3ターゲットで確認し、wrapper/Cargoとも各初回exit 0。3ターゲットのlib/CLI静的check後の共有Cargo targetは1,152,587,638 B、固定cap6,175,228,536 B以内。Windows x64の直近native Release build/E2Eは別項に記録済み。どれも静的compile checkだけで、各OS/architecture上の実行、追加product E2E、performance測定はしていない。wrapperの初回drain超過は再現時に残る観察事項。

2026-10-16 20:17:16.354–20:17:21.982 JSTの外部5×約1秒総CPU sampleは`[30.8,27.7,28.1,41.3,43.9]%`、最大43.9%で15%以下条件に失敗した。10分以上のsample間隔を満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは20:27:21.982 JST以降に限る。

2026-10-16 20:27:30.690–20:27:36.310 JSTの外部5×約1秒総CPU sampleは`[26.5,25.9,45.5,19.3,17.3]%`、最大45.5%で15%以下条件に失敗した。10分以上のsample間隔を満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは20:37:36.310 JST以降に限る。

2026-10-16 20:37:45.565–20:37:51.212 JSTの外部5×約1秒総CPU sampleは`[32.8,30.0,57.3,50.5,30.5]%`、最大57.3%で15%以下条件に失敗した。10分以上のsample間隔を満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは20:47:51.212 JST以降に限る。

2026-10-16 20:48:04.588–20:48:10.201 JSTの外部5×約1秒総CPU sampleは`[34.4,26.7,30.6,42.6,19.8]%`、最大42.6%で15%以下条件に失敗した。10分以上のsample間隔を満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは20:58:10.201 JST以降に限る。

2026-10-16 20:58:45.508–20:58:51.132 JSTの外部5×約1秒総CPU sampleは`[34.0,27.4,50.3,55.9,32.2]%`、最大55.9%で15%以下条件に失敗した。10分以上のsample間隔を満たした。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは21:08:51.132 JST以降に限る。

2026-10-16 21:10:01.357–21:10:07.051 JSTの外部5×約1秒総CPU sampleは`[21.2,19.5,21.8,21.3,28.9]%`、最大28.9%で15%以下条件に失敗した。前回sampleから10分以上経過している。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは21:20:07.051 JST以降に限る。

2026-10-16 21:57 JSTの再開時容量確認では、開発用`UnLhaRe`ツリー2,525,885,151 B、`%LOCALAPPDATA%\Temp\Codex\UnLhaRe` 70,150,998 B、`%LOCALAPPDATA%\Codex\TaskArtifacts\UnLhaRe` 169,585,803 B、合計2,765,621,952 Bを確認した。C:空きは同時刻帯の直前照会で63,803,965,440 B。これは開発環境の占有容量であり、圧縮後サイズとは別。予定するKRS3開発screenと後続pipeline E2Eの追加量は各16,777,216 B、45,154,304 Bの順次実行として別々に見積もっている。復元backup・清掃台帳の224 MiB lifecycle上限は独立して適用し、既存物は変更・清掃していない。

2026-10-16 21:59:37.292–21:59:43.044 JSTの外部5×約1秒総CPU sampleは最大44.6%で、15%以下条件に失敗した。直前の関連`cargo`/`rustc`/`unlhare-cli` processはなし。取得shellが配列値を省略表示したため5値全体は保存できていない。最大値で不合格は確定しているため再試行せず、KRS3 block screenは未起動、artifact hash・実験storage preflight・計測processの起動なし。次のsampleは22:09:43.044 JST以降に限る。

2026-10-16 22:06 JSTの再開時容量確認では、開発用`UnLhaRe`ツリー2,525,889,333 B、`%LOCALAPPDATA%\Temp\Codex\UnLhaRe` 70,150,998 B、`%LOCALAPPDATA%\Codex\TaskArtifacts\UnLhaRe` 169,585,803 B、合計2,765,626,134 Bを確認した。C:空きは62,385,532,928 B。21:57の確認から対象作業領域は4,182 B増え、C:空きは1,418,432,512 B減っていたが、対象外の変化要因は特定していない。今回分のscreenと後続pipeline E2Eの上限見積り16,777,216 B、45,154,304 Bは引き続き順次適用し、既存物の清掃・変更はしていない。

2026-10-16 22:10:03.276–22:10:08.788 JSTの外部5×約1秒総CPU sampleは`[10.3,14.0,18.2,22.4,20.9]%`、最大22.4%で15%以下条件に失敗した。前回sampleから10分以上経過し、直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・実験storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは22:20:08.788 JST以降に限る。

2026-10-16 22:21:06.259–22:21:11.797 JSTの外部5×約1秒総CPU sampleは`[22.3,38.1,23.2,27.8,23.2]%`、最大38.1%で15%以下条件に失敗した。前回sampleから10分以上経過し、直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・実験storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは22:31:11.797 JST以降に限る。

2026-10-16 22:31:20.162–22:31:25.615 JSTの外部5×約1秒総CPU sampleは`[8.1,17.1,35.4,54.0,17.2]%`、最大54.0%で15%以下条件に失敗した。前回sampleから10分以上経過し、直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未起動のまま、CPU不合格後のartifact hash・実験storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは22:41:25.615 JST以降に限る。

2026-10-16 22:41:58.125–22:42:02.146 JSTの外部5×約1秒総CPU sampleは`[18.0,21.0,23.0,9.7,8.0]%`、最大23.0%で15%以下条件に失敗した。前回sampleから10分以上経過し、直前の関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動のまま、CPU不合格後のartifact hash・実験storage preflight・計測processの起動なし。同一負荷で再試行せず、次のsampleは22:52:02.146 JST以降に限る。

### 2026-10-16 開発環境storageと製品limitsの分離監査

`[src/lib.rs](../../src/lib.rs)`の製品API `Limits::default()`は100,000 entries、1 entry 256 MiB、展開後合計2 GiBで、`[README.md](../../README.md)`はCLI・Rust・C JSON APIから値を変更できることと、1 fileをmemoryに保持する実装上の注意を明記する。`git blame`ではこの2 GiB既定値は2026-09-17の初期Rust製品commitに既に存在する。現在の実験契約にあるscreen 5 MiB/64 entries、external Temp 2 GiB、Cargo 6 GiB、復元backup・清掃台帳1GiBは`[STORAGE.md](STORAGE.md)`と実験用`storage-lifecycle.psm1`側の容量管理であり、現行`src/`・`include/`に1GiB lifecycle枠やscreen容量値の転記は見つからなかった。

製品側の`[KHC format](../../KHC_FORMAT.md)`と`[khc/mod.rs](../../src/khc/mod.rs)`では1 MiBは自己完結blockの単位、4 MiBはmanifest上限、64 MiBはcodec scratchの実行時memory reservationであり、どれも開発PCのdisk容量とは別である。製品の2 GiB既定値はexternal Temp枠と数値が一致するが初期製品commitからの既定値で、CLI/Rust/JSONから上書きでき、READMEはmemory上の注意も示す。既定値の選定根拠自体は当時の資料だけでは完全に復元できないため、現時点で容量制約の誤転記とは判定せず、必要な安全性既定値を一括で緩める変更もしない。製品コードの変更なし。

2026-10-16 23:31:54.379–23:31:59.947 JSTの外部5×約1秒総CPU sampleは`[9.6,10.9,9.8,11.3,9.4]%`で、15%以下の条件を満たした。直前に関連する`cargo`/`rustc`/`unlhare-cli` processはなかった。fresh artifact pin・input ZIP member・source fingerprintの確認と、screen 16 MiB分の容量予約を含む`Assert-KhcStorageBudget`は成功した（build/Cargo target 1,152,677,780 B、Temp 70,150,998 B、保持領域169,585,803 B、lifecycle 148,826,083 B、対象作業領域合計1,392,414,581 B、C:空き59,832,385,536 B）。ただし登録runner内の再確認CPU gateは23:32:33.162 JSTに`[49.8,26.0,11.2,29.3,27.4]%`、最大49.8%で失敗し、`measurements_started=false`だった。KRS3の計測は始まっておらず、性能結果はない。run `1a6b20b6c4fd4a9d8b0d43aa89c141c1`の265 Bの一時reportは、既定のPrunlet staged cleanupを完了し、work pathは消失、復元用`recovery.zip`（361 B、SHA-256 `9c10270593e90a316644b5194c03412561558e3e6d7cc820f22b27ab746261bb`）、`recovery.json`（889 B、SHA-256 `07ba8092a54d1f30365dfdaca8f19a9334bb131bdc2e7e265623f41ae57b7c25`）と`complete.json`は保持・確認した。clean後のbudget確認も成功（build/Cargo target1,152,677,780 B、Temp70,150,998 B、保持169,595,009 B、lifecycle148,835,289/234,881,024 B、全作業領域合計1,392,423,787/32,212,254,720 B、C:空き59,827,683,328 B、Cargo cap6,442,450,944 B）。従ってこのscreenはCPU gateで無測定終了し、次回のsampleは23:42:38 JST以降に限る。

2026-10-16 23:37 JSTの作業再開時budget照会では、build/Cargo target 1,152,677,780 B、Temp 70,150,998 B、通常保全169,595,009 B、external total239,746,007/2,147,483,648 B、lifecycle148,835,289/234,881,024 B、全作業領域1,392,423,787/32,212,254,720 B、Cargo cap6,442,450,944 B、C:空き59,285,151,744 B、予約0 Bだった。前回clean後snapshotから作業領域は不変だが、C:空きが542,531,584 B減少しており、原因は特定していない。関連`cargo`/`rustc`/`unlhare-cli` processはなかった。screen分の16 MiB予約を含めた新たなpreflightは、次のCPU条件通過後にだけ行う。

2026-10-16 23:43:11.170–23:43:15.200 JSTの外部5×約1秒総CPU sampleは`[20.6,19.5,19.2,47.3,33.1]%`、最大47.3%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動はしていない。同一負荷で再試行せず、次のsampleは23:53:15.200 JST以降に限る。

2026-10-16 23:53:28.832–23:53:32.863 JSTの外部5×約1秒総CPU sampleは`[26.6,21.5,19.1,20.8,22.2]%`、最大26.6%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動はしていない。同一負荷で再試行せず、次のsampleは2026-10-17 00:03:32.863 JST以降に限る。

2026-10-17 00:03:48.760–00:03:52.794 JSTの外部5×約1秒総CPU sampleは`[28.8,30.5,19.4,41.2,32.3]%`、最大41.2%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli` processはなかった。KRS3 block screenは未登録・未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動はしていない。同一負荷で再試行せず、次のsampleは2026-10-17 00:13:52.794 JST以降に限る。

2026-10-17 00:14:08.378–00:14:13.900 JSTの外部5×約1秒総CPU sampleは`[19.1,21.2,21.4,21.4,21.5]%`、最大21.5%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli`/`7z`/`vctip` processはなかった。KRS3 block screenは未登録・未起動のまま、CPU不合格後のartifact hash・storage preflight・計測processの起動はしていない。同一負荷で再試行せず、次のsampleは2026-10-17 00:24:13.900 JST以降に限る。

2026-10-17 00:24:34.868–00:24:40.409 JSTの外部5×約1秒総CPU sampleは`[18.6,21.4,18.0,19.0,18.3]%`、最大21.4%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli`/`7z`/`vctip` processはなかった。KRS3 block screenとdecoder変更後の製品E2Eはいずれも未起動で、CPU不合格後のartifact hash・storage preflight・計測processの起動はしていない。同一負荷で再試行せず、次のsampleは2026-10-17 00:34:40.409 JST以降に限る。

2026-10-17 00:34:57.240–00:35:01.298 JSTの外部5×約1秒総CPU sampleは`[22.8,20.7,20.1,20.7,17.6]%`、最大22.8%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli`/`7z`/`vctip` processはなかった。KRS3 block screenとdecoder変更後の製品E2Eはいずれも未起動で、CPU不合格後のartifact hash・storage preflight・計測processの起動はしていない。同一負荷で再試行せず、次のsampleは2026-10-17 00:45:01.298 JST以降に限る。

2026-10-17 00:48:16.061–00:48:20.107 JSTの外部5×約1秒総CPU sampleは`[44.1,31.7,30.9,29.3,26.3]%`、最大44.1%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli`/`7z`/`vctip` processはなかった。固定lifecycle枠を1GiBへ更新したが、CPU不合格のため現行storage preflight、artifact hash、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動である。同一負荷で再試行せず、次のsampleは2026-10-17 00:58:20.107 JST以降に限る。

2026-10-17 00:58:38.550–00:58:44.112 JSTの外部5×約1秒総CPU sampleは`[21.3,21.4,18.7,20.4,19.0]%`、手計算の最大21.4%で15%以下条件に失敗した。開始前に関連`cargo`/`rustc`/`unlhare-cli`/`7z`/`vctip` processはなかった。取得後のPowerShell配列最大値表示だけがoverload errorになったが、5値は出力済みでありsampleを再実行していない。CPU不合格のため現行storage preflight、artifact hash、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動である。同一負荷で再試行せず、次のsampleは2026-10-17 01:08:44.112 JST以降に限る。

2026-10-17 01:08:52.797 JSTに次の外部5×1秒総CPU sampleを試みた。開始前の関連processはなかったが、wrapperがsubprocess stdoutだけを返しsession idを保持しなかったため、取得したのは`RELATED_PROCESSES_NONE`のみで5値を得られなかった。follow-up時（01:09:31 JST）には該当PowerShell processもapp terminal sessionもなく、同一sample結果を回収できない。これは15%以下の合格証拠にならないためgate未通過として扱うが、値不明のまま再sampleはしない。storage preflight、artifact hash、KRS3 screenおよび製品E2Eは未実施・未起動。次のsampleは保守的に2026-10-17 01:19:31.730 JST以降とする。

2026-10-17 01:19:53.758–01:19:59.651 JSTの外部5×約1秒総CPU sampleは`[27.7,24.6,19.9,21.0,24.1]%`、最大27.7%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のため現行storage preflight、artifact hash、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動である。同一負荷で再試行せず、次のsampleは2026-10-17 01:29:59.651 JST以降に限る。

2026-10-17 01:30:11.168 JSTのCPU gate precheckでは関連process `vctip.exe`（PID 33772）が稼働中だったため、Get-Counterは呼ばず5値を取得しなかった。gate未通過／値取得不能として扱い、processは停止していない。artifact hash・storage preflight・KRS3 screen・decoder変更後の製品E2Eも未実施・未起動。次のsampleは少なくとも2026-10-17 01:40:11.168 JST以降に、関連processがない場合だけ行う。

2026-10-17 01:31:47 JSTまでPID 33772を`Wait-Process -Id 33772 -Timeout 60`で待ったが`PROCESS_STILL_RUNNING`だった。processの状態変更・終了操作はしていない。

2026-10-17 01:33:05 JSTまでPID 33772をさらに`Wait-Process -Id 33772 -Timeout 60`で待ったが、結果は`PROCESS_STILL_RUNNING`だった。processは停止しておらず、CPU sampleは未実施。

2026-10-17 01:34:24 JSTのPID照会では`vctip.exe`（PID 33772、process start 01:19:59.120 JST）が引き続き存在した。CPU値は採らず、processも停止していない。

2026-10-17 01:35:34 JST時点でPID 33772への追加`Wait-Process -Timeout 45`後も結果は`PROCESS_STILL_RUNNING`。processの終了操作・CPU sampleは行っていない。

2026-10-17 01:40:44.886–01:40:53.945 JSTの外部5×約1秒総CPU sampleは`[95.2,98.8,94.9,99.3,94.1]%`、最大99.3%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 01:50:53.945 JST以降に限る。

2026-10-17 01:51:03.119–01:51:09.054 JSTの外部5×約1秒総CPU sampleは`[31.4,27.5,26.9,12.4,10.3]%`、最大31.4%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 02:01:09.054 JST以降に限る。

2026-10-17 02:01:17.380–02:01:23.265 JSTの外部5×約1秒総CPU sampleは`[10.9,10.5,10.0,10.9,20.5]%`、最大20.5%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 02:11:23.265 JST以降に限る。

2026-10-17 02:11:34.189–02:11:40.088 JSTの外部5×約1秒総CPU sampleは`[32.3,19.8,13.5,9.7,9.7]%`、最大32.3%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 02:21:40.088 JST以降に限る。

2026-10-17 02:21:52.057–02:21:58.084 JSTの外部5×約1秒総CPU sampleは`[24.6,26.7,11.8,13.5,11.0]%`、最大26.7%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 02:31:58.084 JST以降に限る。

2026-10-17 02:32:48.202–02:32:54.182 JSTの外部5×約1秒総CPU sampleは`[28.9,28.5,30.6,28.6,28.6]%`、最大30.6%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 02:42:54.182 JST以降に限る。

2026-10-17 02:43:39.858–02:43:45.937 JSTの外部5×約1秒総CPU sampleは`[15.6,15.2,15.0,37.0,28.1]%`、最大37.0%で15%以下条件に失敗した。開始前に関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。CPU不合格のためartifact hash、storage/current-usage preflight、KRS3 screenおよびdecoder変更後の製品E2Eは未実施・未起動。processは停止しておらず、同一負荷で再試行せず、次のsampleは2026-10-17 02:53:45.937 JST以降に限る。

2026-10-17 02:54:19.202–02:54:25.154 JSTの外部5×約1秒総CPU gateは`[10.1,10.7,11.7,11.0,11.7]%`で最大11.7%、開始前の関連processなし、15%以下を通過した。このgate後に固定Canterbury入力・tool/source/script hashとstorageを再照合し、decoder list-rotation変更後の登録製品E2Eを実行した。

2026-10-17 03:04:44.749–03:04:50.321 JSTの外部5×約1秒総CPU gateは`[13.3456,11.3581,42.1652,39.3547,17.3606]%`、最大42.1652%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflightも実施していない。processは停止しておらず、次のsampleは2026-10-17 03:14:50.321 JST以降に限る。

2026-10-17 03:14:58.807–03:15:04.440 JSTの外部5×約1秒総CPU gateは`[21.5426,16.3679,12.3066,10.5030,9.9921]%`、最大21.5426%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflightも実施していない。processは停止しておらず、次のsampleは2026-10-17 03:25:04.440 JST以降に限る。

2026-10-17 03:25:56.692–03:26:03.887 JSTの外部5×約1秒総CPU gateは`[98.3495,99.1602,92.2301,89.4236,75.3940]%`、最大99.1602%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflightも実施していない。processは停止しておらず、次のsampleは2026-10-17 03:36:03.887 JST以降に限る。

2026-10-17 03:36:54.903–03:37:00.471 JSTの外部5×約1秒総CPU gateは`[11.0799,15.4028,13.6765,9.6669,33.2543]%`、最大33.2543%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflightも実施していない。processは停止しておらず、次のsampleは2026-10-17 03:47:00.471 JST以降に限る。

2026-10-17 03:47:41.742–03:47:47.354 JSTの外部5×約1秒総CPU gateは`[21.7469,22.6804,40.2707,27.2761,21.4649]%`、最大40.2707%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflightも実施していない。processは停止しておらず、次のsampleは2026-10-17 03:57:47.354 JST以降に限る。

2026-10-17 03:58:00.236–03:58:05.807 JSTの外部5×約1秒総CPU gateは`[11.6349,11.8377,12.2627,11.9650,10.4078]%`、最大12.2627%、関連processなしで通過した。登録前preflightでは、固定recovery ZIP 769,634 B / SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`、member `input/ptt5` 513,216 B / SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`、Release bench 1,326,080 B / SHA-256 `abcf5cbd839f059a8f633634eb1bc2c0cc49fdef2bd6b3f39e5168a6be019bbb`を再確認した。40-file source/config snapshot SHA-256 `6f084005ffce3343a59345e662ce9cd94afe47ba6da7aa7f6cea5231a9d37daa`。固定5 MiB/64 entries/300秒予約16 MiBのlifecycle admissionは成功し、lifecycle使用157,748,855 B/1 GiB、incomplete run 0。

`record-adaptive-screen.ps1`を登録runnerで3 rounds起動したが、測定直前の内部5×1秒CPU gateが03:59:39 JST頃に`[18.3,20.1,12.8,10.4,42.2]%`（最大42.2%）となり、status `skipped-cpu-gate`、`measurements_started=false`を出した。benchmark測定は未開始で、KRS3 block screen結果は未取得。run `7bf873230c55499890e8343ca1cc7732`をPrunlet direct-CMD preview/delete/preview/purge/finalizeで清掃・検証し、265 B workdirを除去した。復元ZIP 364 B / SHA-256 `eea6a10595990e0332a6bd58cda7e9e83a58ab73fe549f82d3979b259aae4397`、manifest SHA-256 `62560659bf04cafea3258035d550e6bc4a3a92c0e4f0583a6f420fa0d7aaff85`、ZIP内skip report 265 B / SHA-256 `7c3eaa138c8553fc9d3f0ef4b96176390d78ddd023fef147038a102953142b13`を保全した。次の外部CPU sampleは保守的に2026-10-17 04:09:39.823 JST以降とし、pass時は全hashと5/64/300 preflightを新たに行ってから同じscreenを登録する。

2026-10-17 04:09:58.538–04:10:02.569 JSTの外部5×約1秒総CPU gateは`[27.6762,37.4747,24.2955,12.8969,9.7409]%`、最大37.4747%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflight・benchmarkは実施していない。processは停止しておらず、次のsampleは2026-10-17 04:20:02.569 JST以降に限る。

2026-10-17 04:20:15.430–04:20:19.466 JSTの外部5×約1秒総CPU gateは`[44.8195,53.2575,31.6532,23.6973,17.5432]%`、最大53.2575%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動であり、この不合格後に同screen用artifact hash・storage preflight・benchmarkは実施していない。processは停止しておらず、次のsampleは2026-10-17 04:30:19.466 JST以降に限る。

2026-10-17 04:30 JSTの次回gateでは関連process precheckが`vctip.exe` PID10244を検出したため、CPU sample自体を開始しなかった。processは停止していない。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、artifact hash・storage preflight・benchmarkも未実施。次のprecheckは少なくとも2026-10-17 04:40:44 JST以降とする。

2026-10-17 04:41:05.589–04:41:09.749 JSTの外部5×約1秒総CPU gateは`[90.5465,99.1409,99.1076,93.8088,98.9026]%`、最大99.1409%で15%以下条件に失敗した。開始前の関連processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、次のsampleは2026-10-17 04:51:09.749 JST以降に限る。

2026-10-17 04:51 JSTの次回gateでは関連process precheckが`vctip.exe` PID2256を検出したためCPU sample自体を開始しなかった。processは停止していない。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、artifact hash・storage preflight・benchmarkも未実施。次のprecheckは少なくとも2026-10-17 05:01:32 JST以降とする。

2026-10-17 05:02:19.987–05:02:25.845 JSTの外部5×約1秒総CPU sampleは`[78.7,67.5,28.9,10.6,9.3]%`、最大78.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、artifact hash・storage preflight・benchmarkも未実施。processは停止しておらず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 05:12:25.845 JST以降とする。

2026-10-17 05:12:32.009–05:12:37.745 JSTの外部5×約1秒総CPU sampleは`[39.4,20.0,21.1,22.7,23.1]%`、最大39.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、artifact hash・storage preflight・benchmarkも未実施。processは停止しておらず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 05:22:37.745 JST以降とする。

2026-10-17 05:23:48.793–05:23:54.629 JSTの外部5×約1秒総CPU sampleは`[19.8,20.6,18.8,21.1,17.9]%`、最大21.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、artifact hash・storage preflight・benchmarkも未実施。processは停止しておらず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 05:33:54.629 JST以降とする。

2026-10-17 05:34:03.627–05:34:09.182 JSTの外部5×約1秒総CPU sampleは`[22.9,21.9,18.9,21.4,21.3]%`、最大22.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 05:44:09.182 JST以降とする。

2026-10-17 05:44:18.918–05:44:24.494 JSTの外部5×約1秒総CPU sampleは`[19.8,20.3,18.8,21.6,19.3]%`、最大21.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 05:54:24.494 JST以降とする。

2026-10-17 05:54:30.614–05:54:36.165 JSTの外部5×約1秒総CPU sampleは`[25.6,27.1,18.4,19.9,19.0]%`、最大27.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 06:04:36.165 JST以降とする。

2026-10-17 06:04:55.733–06:05:01.368 JSTの外部5×約1秒総CPU sampleは`[30.0,28.8,28.2,29.1,47.5]%`、最大47.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 06:15:01.368 JST以降とする。

2026-10-17 06:17:18.043–06:17:23.616 JSTの外部5×約1秒総CPU sampleは`[51.3,62.1,46.0,51.1,52.4]%`、最大62.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 06:27:23.616 JST以降とする。

2026-10-17 06:27:31.835–06:27:37.405 JSTの外部5×約1秒総CPU sampleは`[20.3,19.2,18.7,19.5,19.5]%`、最大20.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 06:37:37.405 JST以降とする。

2026-10-17 06:38:09.874–06:38:15.446 JSTの外部5×約1秒総CPU sampleは`[29.5,27.2,29.1,27.7,52.1]%`、最大52.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 06:48:15.446 JST以降とする。

2026-10-17 07:20:14.990–07:20:20.843 JSTの外部5×約1秒総CPU sampleは`[21.3,21.2,22.0,24.1,22.8]%`、最大24.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 07:30:20.843 JST以降とする。

2026-10-17 07:30:57.003–07:31:02.541 JSTの外部5×約1秒総CPU sampleは`[19.6,20.0,23.9,20.5,23.9]%`、最大23.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 07:41:02.541 JST以降とする。

2026-10-17 07:41:36.473–07:41:42.114 JSTの外部5×約1秒総CPU sampleは`[19.8,23.5,19.2,17.8,22.3]%`、最大23.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 07:51:42.114 JST以降とする。

2026-10-17 07:52:18.361–07:52:23.946 JSTの外部5×約1秒総CPU sampleは`[18.6,37.5,39.4,33.9,28.0]%`、最大39.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 08:02:23.946 JST以降とする。

2026-10-17 08:03:59.822–08:04:05.408 JSTの外部5×約1秒総CPU sampleは`[33.6,27.2,47.0,29.6,26.5]%`、最大47.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 08:14:05.408 JST以降とする。

2026-10-17 08:14:41.844–08:14:47.434 JSTの外部5×約1秒総CPU sampleは`[30.8,19.2,13.0,16.0,12.6]%`、最大30.8%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 08:24:47.434 JST以降とする。

2026-10-17 08:25:21.631–08:25:27.256 JSTの外部5×約1秒総CPU sampleは`[38.5,30.1,23.8,23.8,22.7]%`、最大38.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 08:35:27.256 JST以降とする。

2026-10-17 08:36:01.976–08:36:07.557 JSTの外部5×約1秒総CPU sampleは`[23.3,21.7,19.2,25.7,33.8]%`、最大33.8%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 08:46:07.557 JST以降とする。

2026-10-17 09:17:56.897–09:18:02.732 JSTの外部5×約1秒総CPU sampleは`[22.4,20.2,22.5,24.3,22.2]%`、最大24.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 09:28:02.732 JST以降とする。

2026-10-17 09:28:38.441–09:28:44.550 JSTの外部5×約1秒総CPU sampleは`[41.7,27.9,26.0,30.3,31.6]%`、最大41.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 09:38:44.550 JST以降とする。

2026-10-17 10:00:11.179–10:00:17.071 JSTの外部5×約1秒総CPU sampleは`[23.5,21.9,21.3,22.3,15.2]%`、最大23.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 10:10:17.071 JST以降とする。

2026-10-17 10:10:56.001–10:11:01.564 JSTの外部5×約1秒総CPU sampleは`[22.5,19.9,19.5,21.4,28.0]%`、最大28.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 10:21:01.564 JST以降とする。

2026-10-17 10:21:38.088–10:21:43.677 JSTの外部5×約1秒総CPU sampleは`[11.8,9.6,12.8,14.4,17.4]%`、最大17.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 10:31:43.677 JST以降とする。

2026-10-17 10:53:22.006–10:53:28.266 JSTの外部5×約1秒総CPU sampleは`[22.8,20.1,22.6,20.5,20.3]%`、最大22.8%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 11:03:28.266 JST以降とする。

2026-10-17 11:04:06.245–11:04:11.807 JSTの外部5×約1秒総CPU sampleは`[22.3,20.9,18.7,19.8,19.8]%`、最大22.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 11:14:11.807 JST以降とする。

2026-10-17 11:14:50.125–11:14:55.714 JSTの外部5×約1秒総CPU sampleは`[34.7,32.1,27.0,18.2,21.5]%`、最大34.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 11:24:55.714 JST以降とする。

2026-10-17 11:25:36.497–11:25:42.080 JSTの外部5×約1秒総CPU sampleは`[28.1,23.1,26.1,23.3,26.7]%`、最大28.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 11:35:42.080 JST以降とする。

2026-10-17 11:36:19.470–11:36:25.071 JSTの外部5×約1秒総CPU sampleは`[25.5,21.1,20.1,21.4,18.4]%`、最大25.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 11:46:25.071 JST以降とする。

2026-10-17 11:49:38.205 JSTに登録済みKRS3 childが採取した内部5×約1秒総CPU sampleは`[22.7,24.4,17.5,16.1,21.1]%`、最大24.4%だった。直前の外部gateは通過したが、child内部gateで`skipped-cpu-gate`となり`measurements_started=false`。KRS3 benchmarkは開始していない。run `87f4d117ca3c4099b64c3264e06a823c`の一時workはPrunlet段階清掃operation `eb70f4eea1494f50b9019fcd0ff2ccd8`でcomplete、AfterBytes 0を確認した。この内部gate失敗後、性能artifact hash・容量preflight・benchmarkは行っていない。次の外部precheckは少なくとも2026-10-17 11:59:38.205 JST以降とする。

2026-10-17 12:00:21.876–12:00:27.747 JSTの外部5×約1秒総CPU sampleは`[50.4,25.9,25.9,32.0,24.6]%`、最大50.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 12:10:27.747 JST以降とする。

2026-10-17 12:11:15.306–12:11:21.663 JSTの外部5×約1秒総CPU sampleは`[12.9,18.7,16.9,14.6,12.3]%`、最大18.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 12:21:21.663 JST以降とする。

2026-10-17 12:22:06.435–12:22:12.044 JSTの外部5×約1秒総CPU sampleは`[34.9,29.2,29.1,24.1,23.2]%`、最大34.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 12:32:12.044 JST以降とする。

2026-10-17 12:32:56.401–12:33:01.976 JSTの外部5×約1秒総CPU sampleは`[26.0,26.3,22.1,24.5,20.0]%`、最大26.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 12:43:01.976 JST以降とする。

2026-10-17 12:43:24.968–12:43:30.606 JSTの外部5×約1秒総CPU sampleは`[29.6,43.9,49.8,52.6,41.6]%`、最大52.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 12:43:24.954 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 12:53:30.606 JST以降とする。

2026-10-17 12:54:10.124–12:54:15.695 JSTの外部5×約1秒総CPU sampleは`[21.9,23.1,19.6,20.9,18.6]%`、最大23.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 12:54:10.110 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 13:04:15.695 JST以降とする。

2026-10-17 13:04:55.221–13:05:01.323 JSTの外部5×約1秒総CPU sampleは`[20.6,22.7,18.9,16.8,19.6]%`、最大22.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 13:04:55.201 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 13:15:01.323 JST以降とする。

2026-10-17 13:15:36.814–13:15:42.431 JSTの外部5×約1秒総CPU sampleは`[21.0,22.3,19.0,19.9,19.1]%`、最大22.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 13:15:36.801 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 13:25:42.431 JST以降とする。

2026-10-17 13:26:18.974–13:26:24.705 JSTの外部5×約1秒総CPU sampleは`[41.0,28.4,33.4,30.3,30.1]%`、最大41.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 13:26:18.957 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 13:36:24.705 JST以降とする。

2026-10-17 13:36:58.633–13:37:05.013 JSTの外部5×約1秒総CPU sampleは`[21.7,17.3,30.4,36.3,30.0]%`、最大36.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 13:36:58.610 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 13:47:05.013 JST以降とする。

2026-10-17 13:47:39.290–13:47:44.907 JSTの外部5×約1秒総CPU sampleは`[27.2,25.6,20.4,22.8,24.7]%`、最大27.2%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 13:47:39.275 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 13:57:44.907 JST以降とする。

2026-10-17 14:29:39.840–14:29:45.633 JSTの外部5×約1秒総CPU sampleは`[70.6,28.4,16.7,14.1,15.5]%`、最大70.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 14:29:39.824 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 14:39:45.633 JST以降とする。

2026-10-17 14:40:23.644–14:40:29.991 JSTの外部5×約1秒総CPU sampleは`[11.1,11.9,12.1,15.2,12.2]%`、最大15.2%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 14:40:23.614 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 14:50:29.991 JST以降とする。

2026-10-17 14:51:09.048–14:51:14.622 JSTの外部5×約1秒総CPU sampleは`[9.5,14.6,11.7,15.2,14.9]%`、最大15.2%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 14:51:09.033 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 15:01:14.622 JST以降とする。

2026-10-17 15:33:06.851–15:33:12.630 JSTの外部5×約1秒総CPU sampleは`[39.9,30.8,25.4,24.2,21.9]%`、最大39.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 15:33:06.836 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 15:43:12.630 JST以降とする。

2026-10-17 15:43:50.263–15:43:56.307 JSTの外部5×約1秒総CPU sampleは`[18.9,26.5,21.8,21.1,19.3]%`、最大26.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 15:43:50.246 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 15:53:56.307 JST以降とする。

2026-10-17 15:54:34.172–15:54:39.711 JSTの外部5×約1秒総CPU sampleは`[19.2,18.7,19.0,21.3,18.8]%`、最大21.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 15:54:34.159 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 16:04:39.711 JST以降とする。

2026-10-17 16:05:17.408–16:05:22.942 JSTの外部5×約1秒総CPU sampleは`[22.5,14.1,30.7,21.9,20.1]%`、最大30.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 16:05:17.394 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 16:15:22.942 JST以降とする。

2026-10-17 16:16:03.915–16:16:09.427 JSTの外部5×約1秒総CPU sampleは`[17.6,20.2,18.9,19.6,19.3]%`、最大20.2%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 16:16:03.901 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 16:26:09.427 JST以降とする。

2026-10-17 16:26:53.107–16:26:58.630 JSTの外部5×約1秒総CPU sampleは`[22.4,24.7,18.4,20.4,18.9]%`、最大24.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 16:26:53.094 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 16:36:58.630 JST以降とする。

2026-10-17 16:37:38.592–16:37:44.267 JSTの外部5×約1秒総CPU sampleは`[28.7,30.5,27.1,26.2,28.4]%`、最大30.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 16:37:38.578 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 16:47:44.267 JST以降とする。

2026-10-17 16:48:20.955–16:48:26.767 JSTの外部5×約1秒総CPU sampleは`[11.3,11.4,13.1,11.4,37.2]%`、最大37.2%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 16:48:20.938 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 16:58:26.767 JST以降とする。

2026-10-17 16:59:08.768–16:59:17.302 JSTの外部5×約1秒総CPU sampleは`[98.6,99.5,99.7,100.0,96.8]%`、最大100.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 16:59:08.717 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 17:09:17.302 JST以降とする。

2026-10-17 17:31:04.774–17:31:11.104 JSTの外部5×約1秒総CPU sampleは`[14.0,11.4,10.0,14.7,23.4]%`、最大23.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 17:31:04.761 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 17:41:11.104 JST以降とする。

2026-10-17 17:42:38.726–17:42:44.547 JSTの外部5×約1秒総CPU sampleは`[15.8,14.9,14.0,15.4,16.6]%`、最大16.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 17:42:38.712 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 17:52:44.547 JST以降とする。

2026-10-17 17:53:29.991 JST開始の外部CPU sampleは失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 17:53:29.871 JST）が、sample commandは開始時刻だけ返し、`CPU_SAMPLES`／`SAMPLE_COUNT`／`CPU_MAX`／`SAMPLE_END`を返さなかったため値を確認できない。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この失敗後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同じ条件の即時再試行をせず、次のprecheckは少なくとも2026-10-17 18:03:29.991 JST以降とする。

2026-10-17 18:04:53.472–18:04:58.960 JSTの外部5×約1秒総CPU sampleは`[17.8,18.4,17.8,17.9,17.6]%`、最大18.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 18:04:53.460 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 18:14:58.960 JST以降とする。

2026-10-17 18:15:39.111–18:15:44.712 JSTの外部5×約1秒総CPU sampleは`[23.3,18.8,19.4,20.7,18.6]%`、最大23.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 18:15:39.099 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 18:25:44.712 JST以降とする。

2026-10-17 18:26:27.879–18:26:33.403 JSTの外部5×約1秒総CPU sampleは`[28.9,22.0,18.4,16.1,15.6]%`、最大28.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 18:26:27.865 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 18:36:33.403 JST以降とする。

2026-10-17 19:08:40.643–19:08:46.132 JSTの外部5×約1秒総CPU sampleは`[19.0,18.1,16.8,32.6,31.6]%`、最大32.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 19:08:40.630 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 19:18:46.132 JST以降とする。

2026-10-17 19:19:31.089–19:19:36.571 JSTの外部5×約1秒総CPU sampleは`[17.9,19.6,19.6,17.2,16.9]%`、最大19.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 19:19:31.077 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 19:29:36.571 JST以降とする。

2026-10-17 19:30:16.201–19:30:21.683 JSTの外部5×約1秒総CPU sampleは`[18.2,20.6,18.4,17.4,19.3]%`、最大20.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 19:30:16.188 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 19:40:21.683 JST以降とする。

2026-10-17 19:41:00.588–19:41:06.076 JSTの外部5×約1秒総CPU sampleは`[23.9,15.3,18.3,17.2,18.4]%`、最大23.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 19:41:00.574 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 19:51:06.076 JST以降とする。

2026-10-17 19:51:57.394–19:52:05.248 JSTの外部5×約1秒総CPU sampleは`[100.0,97.7,100.0,100.0,98.3]%`、最大100.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 19:51:57.337 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 20:02:05.248 JST以降とする。

2026-10-17 20:02:51.495–20:02:57.040 JSTの外部5×約1秒総CPU sampleは`[25.0,22.4,25.1,25.7,24.5]%`、最大25.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 20:02:51.481 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 20:12:57.040 JST以降とする。

2026-10-17 20:13:45.301–20:13:50.823 JSTの外部5×約1秒総CPU sampleは`[16.9,18.1,16.8,19.4,10.2]%`、最大19.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 20:13:45.288 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 20:23:50.823 JST以降とする。

2026-10-17 20:24:50.765–20:24:56.231 JSTの外部5×約1秒総CPU sampleは`[15.0,17.2,19.2,17.7,37.0]%`、最大37.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 20:24:50.753 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 20:34:56.231 JST以降とする。

2026-10-17 20:36:33.389–20:36:39.029 JSTの外部5×約1秒総CPU sampleは`[8.9,10.8,10.1,12.5,16.7]%`、最大16.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 20:36:33.375 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 20:46:39.029 JST以降とする。

2026-10-17 20:47:27.179–20:47:32.695 JSTの外部5×約1秒総CPU sampleは`[22.3,16.9,18.7,17.1,10.5]%`、最大22.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 20:47:27.168 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 20:57:32.695 JST以降とする。

2026-10-17 20:58:16.488–20:58:21.955 JSTの外部5×約1秒総CPU sampleは`[12.8,19.0,15.7,16.3,15.1]%`、最大19.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 20:58:16.477 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 21:08:21.955 JST以降とする。

2026-10-17 21:09:05.806–21:09:11.250 JSTの外部5×約1秒総CPU sampleは`[9.0,14.2,18.2,16.4,17.6]%`、最大18.2%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 21:09:05.794 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 21:19:11.250 JST以降とする。

2026-10-17 21:22:02.316–21:22:07.790 JSTの外部5×約1秒総CPU sampleは`[16.6,18.1,16.3,16.0,8.9]%`、最大18.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 21:22:02.305 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 21:32:07.790 JST以降とする。

2026-10-17 21:34:07.525–21:34:13.043 JSTの外部5×約1秒総CPU sampleは`[18.1,17.6,23.4,22.0,54.0]%`、最大54.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 21:34:07.513 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 21:44:13.043 JST以降とする。

2026-10-17 21:44:58.979–21:45:04.756 JSTの外部5×約1秒総CPU sampleは`[61.0,67.1,53.0,49.2,17.3]%`、最大67.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 21:44:58.960 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 21:55:04.756 JST以降とする。

2026-10-17 21:55:52.074–21:55:58.420 JSTの外部5×約1秒総CPU sampleは`[67.7,69.7,76.6,92.5,100.0]%`、最大100.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 21:55:52.051 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 22:05:58.420 JST以降とする。

2026-10-17 22:07:14.411–22:07:26.898 JSTの外部5×約1秒総CPU sampleは`[100.0,95.1,98.1,100.0,100.0]%`、最大100.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 22:07:14.379 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-17 22:17:26.898 JST以降とする。

2026-10-18 00:05:56.834–00:06:02.722 JSTの外部5×約1秒総CPU sampleは`[28.3,27.1,29.8,27.2,30.0]%`、最大30.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 00:05:56.819 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 00:16:02.722 JST以降とする。

2026-10-18 00:16:56.452–00:17:02.196 JSTの外部5×約1秒総CPU sampleは`[31.6,31.9,28.0,34.4,37.3]%`、最大37.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 00:16:56.432 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 00:27:02.196 JST以降とする。

2026-10-18 00:28:00.527–00:28:06.204 JSTの外部5×約1秒総CPU sampleは`[26.2,24.4,26.4,25.9,26.9]%`、最大26.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 00:28:00.511 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 00:38:06.204 JST以降とする。

2026-10-18 00:38:12.146–00:38:17.840 JSTの外部5×約1秒総CPU sampleは`[33.1,26.9,28.0,41.7,65.3]%`、最大65.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 00:38:12.131 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 00:48:17.840 JST以降とする。

2026-10-18 00:48:28.839–00:48:34.679 JSTの外部5×約1秒総CPU sampleは`[16.9,16.1,16.3,13.8,11.9]%`、最大16.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 00:48:28.825 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 00:58:34.679 JST以降とする。

2026-10-18 00:58:42.780–00:58:48.328 JSTの外部5×約1秒総CPU sampleは`[19.3,18.4,19.7,17.6,18.0]%`、最大19.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 00:58:42.767 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 01:08:48.328 JST以降とする。

2026-10-18 01:08:58.609–01:09:04.753 JSTの外部5×約1秒総CPU sampleは`[79.1,53.5,46.3,46.5,48.9]%`、最大79.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 01:08:58.593 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 01:19:04.753 JST以降とする。

2026-10-18 01:59:50.880–01:59:56.703 JSTの外部5×約1秒総CPU sampleは`[9.4,20.0,20.3,39.2,47.7]%`、最大47.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 01:59:50.867 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 02:09:56.703 JST以降とする。

2026-10-18 02:10:04.105–02:10:09.760 JSTの外部5×約1秒総CPU sampleは`[21.8,18.8,18.9,17.9,17.8]%`、最大21.8%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 02:10:04.089 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 02:20:09.760 JST以降とする。

2026-10-18 02:40:39.871–02:40:45.891 JSTの外部5×約1秒総CPU sampleは`[30.7,28.7,29.7,33.5,37.0]%`、最大37.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 02:40:39.838 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 02:50:45.891 JST以降とする。

2026-10-18 02:50:57.465–02:51:03.258 JSTの外部5×約1秒総CPU sampleは`[24.1,21.3,19.5,21.5,19.6]%`、最大24.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 02:50:57.444 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 03:01:03.258 JST以降とする。

2026-10-18 03:01:12.469–03:01:18.499 JSTの外部5×約1秒総CPU sampleは`[65.9,52.3,61.0,63.3,54.4]%`、最大65.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 03:01:12.450 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 03:11:18.499 JST以降とする。

2026-10-18 03:11:28.700–03:11:34.588 JSTの外部5×約1秒総CPU sampleは`[35.6,33.5,38.1,38.6,69.4]%`、最大69.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 03:11:28.682 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 03:21:34.588 JST以降とする。

2026-10-18 03:21:45.054–03:21:50.755 JSTの外部5×約1秒総CPU sampleは`[20.0,20.6,17.3,20.3,18.8]%`、最大20.6%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 03:21:45.034 JST）。KRS3 `record-adaptive-screen.ps1`は未登録・未起動で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 03:31:50.755 JST以降とする。

2026-10-18T03:33:13.0607083+09:00に記録されたKRS3 `record-adaptive-screen.ps1`内部5×約1秒CPU sampleは`[25.8,25.9,20.8,17.6,20.6]%`、最大25.9%で15%以下条件に失敗した。reportは`measurements_started=false`。外部ゲート通過後に登録したrun `6333fb5495194ba191ce1da33f39f5a6` はpending (`awaiting-prunlet`); 候補benchmark測定は開始されなかった。runは登録済みPrunlet清掃を完了後、次のCPU gateは少なくとも2026-10-18 03:43:13.061 JST以降とする。

2026-10-18T03:45:57.9778386+09:00に記録されたKRS3 `record-adaptive-screen.ps1`内部5×約1秒CPU sampleは`[19.1,19.2,9.3,12.5,9.9]%`、最大19.2%で15%以下条件に失敗した。外部ゲートは03:43:48.449–03:43:54.164 JSTに`[11.5,9.4,11.9,11.0,11.0]%`、最大11.9%で通過し、固定SHAと容量判定後に5MiB/64-entry/300秒で登録したrun `a9321a8f4d1e4141bfec798709c95a71` の内部guardが測定前にskip (`measurements_started=false`)。候補benchmark測定値はない。Prunlet staged cleanup完了、work directoryは不在。回復ZIP SHA-256 `9e52fe2be83067fcdf13b77385e6d43a8e23c83a3cca0c4344ac5d855f607723`、manifest SHA-256 `a01673e1ec9ec17fc29100417f5a44259d471fafc24d1acfccb7485ee518e6a7`、report (`record-adaptive-screen.json`) は263 bytes / SHA-256 `f4af0b63498226e427152b6b49821971758c3153daa1b1a59d3260b61d0f9271` を外部TaskArtifactsに保持する。processは停止せず、次のprocess-first precheckは少なくとも2026-10-18 03:55:57.978 JST以降とする。

2026-10-18 03:57:13.961–03:57:19.551 JSTの外部5×約1秒総CPU sampleは`[21.4,18.1,19.2,19.3,43.8]%`、最大43.8%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 03:57:09.154 JST）。前回のKRS3 `record-adaptive-screen.ps1` run `a9321a8f4d1e4141bfec798709c95a71` は内部gate skip後にPrunlet staged cleanupを完了済み。今回の不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 04:07:19.551 JST以降とする。

2026-10-18 04:08:04.499–04:08:10.248 JSTの外部5×約1秒総CPU sampleは`[20.9,25.3,18.8,19.6,18.6]%`、最大25.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 04:07:59.832 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 04:18:10.248 JST以降とする。

2026-10-18 04:18:50.706–04:18:56.538 JSTの外部5×約1秒総CPU sampleは`[35.8,21.6,17.4,19.1,18.5]%`、最大35.8%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 04:18:46.459 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 04:28:56.539 JST以降とする。

2026-10-18 04:29:31.778–04:29:37.459 JSTの外部5×約1秒総CPU sampleは`[40.7,28.2,19.3,19.9,18.1]%`、最大40.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 04:29:27.305 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 04:39:37.459 JST以降とする。

2026-10-18 04:40:09.529–04:40:15.053 JSTの外部5×約1秒総CPU sampleは`[15.7,35.5,25.2,16.4,13.8]%`、最大35.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 04:40:05.505 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 04:50:15.053 JST以降とする。

2026-10-18 04:50:45.858–04:50:51.427 JSTの外部5×約1秒総CPU sampleは`[18.7,20.8,17.3,37.2,57.5]%`、最大57.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 04:50:41.734 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 05:00:51.427 JST以降とする。

2026-10-18 05:01:28.487–05:01:34.014 JSTの外部5×約1秒総CPU sampleは`[18.4,14.5,14.4,13.1,15.5]%`、最大18.4%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 05:01:24.215 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 05:11:34.014 JST以降とする。

2026-10-18 05:12:07.973–05:12:13.531 JSTの外部5×約1秒総CPU sampleは`[21.1,19.3,21.2,41.0,30.8]%`、最大41.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 05:12:03.766 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 05:22:13.531 JST以降とする。

2026-10-18 05:22:48.245–05:22:53.764 JSTの外部5×約1秒総CPU sampleは`[18.2,19.1,17.8,19.0,19.0]%`、最大19.1%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 05:22:43.994 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 05:32:53.764 JST以降とする。

2026-10-18 05:33:30.636–05:33:36.179 JSTの外部5×約1秒総CPU sampleは`[23.9,17.1,16.4,17.4,19.2]%`、最大23.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 05:33:25.976 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 05:43:36.180 JST以降とする。

2026-10-18 05:44:11.234–05:44:16.816 JSTの外部5×約1秒総CPU sampleは`[46.4,48.9,26.6,22.0,18.3]%`、最大48.9%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 05:44:07.130 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 05:54:16.816 JST以降とする。

2026-10-18 05:54:52.715–05:54:58.243 JSTの外部5×約1秒総CPU sampleは`[14.1,14.6,16.4,30.5,38.3]%`、最大38.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 05:54:48.662 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 06:04:58.243 JST以降とする。

2026-10-18 06:05:35.583–06:05:41.149 JSTの外部5×約1秒総CPU sampleは`[17.6,19.9,18.3,20.5,17.8]%`、最大20.5%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 06:05:31.441 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 06:15:41.149 JST以降とする。

2026-10-18 06:16:17.261–06:16:23.038 JSTの外部5×約1秒総CPU sampleは`[37.1,37.3,39.7,31.4,23.4]%`、最大39.7%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 06:16:12.927 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 06:26:23.038 JST以降とする。

2026-10-18 06:26:59.534–06:27:05.109 JSTの外部5×約1秒総CPU sampleは`[26.5,28.0,27.6,27.7,27.8]%`、最大28.0%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 06:26:54.991 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 06:37:05.110 JST以降とする。

2026-10-18 06:37:45.306–06:37:50.910 JSTの外部5×約1秒総CPU sampleは`[45.5,46.9,59.2,51.9,59.3]%`、最大59.3%で15%以下条件に失敗した。開始直前の関連`cargo`／`rustc`／`unlhare-cli`／`7z`／`vctip` processはなかった（precheck 06:37:40.762 JST）。KRS3 `record-adaptive-screen.ps1`は前回runの内部gate skip・Prunlet staged cleanup完了後で、この不合格後にartifact hash・storage preflight・benchmarkは実施していない。processは停止せず、同一負荷で再試行せず、次のprecheckは少なくとも2026-10-18 06:47:50.910 JST以降とする。

### KRS3 block-only screen結果 — 2026-10-19

2026-10-19 05:55 JSTに測定前条件を満たした。関連processのprecheckは0件、外部5×約1秒総CPU sampleは`[2.1,0.5,2.8,2.1,1.2]%`（最大2.8%）。screen内部の5×1秒sampleも`[4.7,4.2,1.4,0.8,0.8]%`で全件15%以下だった。入力は既存D上の読み取り専用保全ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`（SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`）をそのまま使用した。実行run `ae7e32c020e94a80ab0a50a0f331c6f8`、recovery ZIP SHA-256 `a248e121761082e2e5c5bb5a61a70e3291f4cb82aa819e4898c375d00eb0751f`、recovery manifest SHA-256 `c5d1d1f9fb941ade2bb38c96cae710b965ae9f16749ae44e54b1c8c1ba4f248c`。runはFinalized、登録workは削除済み（800,505 Bから0 B）。

同一`ptt5` raw（513,216 B、CRC32 `1259857308`）で3組のpaired batchを完了し、全frame hashの反復一致とdecode後のbyte/SHA復元を確認した。KRS2は46,202 B / SHA-256 `ee12c4ce473615c7aa40c5786825ac79cb7cebd5e59680aa9e8e19df809d57be`、median encode 20,174,400 ns / decode 1,210,800 ns。KRS3は47,284 B / SHA-256 `48a3ecdce5ec345da3f74d2e650fd2828bb71bff4f4f6d7af82b494bc5dc8727`、median encode 20,479,100 ns / decode 1,786,500 ns。候補はKRS2より1,082 B（2.34%）大きく、encode 1.51%・decode 47.6%遅い。強いsize gateの42,127 B未満を5,157 B超過したため`block-size-no-go`であり、製品archiveへ進めない。

全6件の`PeakWorkingSet64`値は0で、process peak working setは計測できていない。従って64 MiB memory gateは未検証であり、合格扱いしない。このscreenはKRS2/KRS3のblock frame比較のみで、完全製品書庫の比較・7-Zip 26.04との再比較・製品統合は行っていない。これらの結果から一般的な圧縮優位性は主張しない。

## ASCII digit-run構造分離のsize-first pilot事前登録 — 2026-10-19

KCS1/ptt5とKRS3の実測条件を再実行せず、候補表2位の可逆構造分離（`:41`、先行比較`:54`）を独立した候補として一構成だけ試す。これは開発用Canterbury入力でのblock-level pilotであり、製品統合・代表性・holdout・7-Zip優位性・速度・最大メモリの証拠にはしない。

固定入力は`CORPUS_MANIFEST.json`の開発family `canterbury-development`にある`cp.html`、24,603 B、SHA-256 `e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61`。固定sourceはD上の既存保全run `0acc17d780a142dcafe88645a07205a5\recovery.zip`（SHA-256 `27030319c3938bdec7df681d8113df43318d9a01ee40eef36e43af3e6f86e898`）、entry `pipeline-e2e/canterbury/cp.html`。測定前照合でentry長・SHAはmanifestと一致した。登録runner枠は3 MiB / 64 entries / 120秒に固定する（entry下限はlifecycle契約の最小値）。

候補transform `KDR1` は、最大1 MiB block中の連続するASCII decimal digit（`0x30..0x39`）runのうち長さ8以上だけを、byte streamから取り除いて位置付きside streamへ格納する。ヘッダーはmagic/version・元長・run数、各descriptorは昇順の絶対offsetとlength、数字は上位nibbleからBCD値0..9を詰め、奇数末尾の下位nibbleは0に固定する。残余のliteral bytesは元順で一度だけ格納する。復号器は元長・run数・offset/lengthの範囲と非重複・最小run長・nibble値・padding・literal長・終端一致をchecked arithmeticで検査し、不正なら拒否する。入力を正規化・再encodingせず、全byteを保持する。

primary metricは、`KDR1`全header/descriptor/digit/literalを含む変換frameを既存`BinaryAdaptive`で符号化した**完全KHC block frame bytes**と、同じ`BinaryAdaptive`によるraw blockの完全frame bytesとの差。再現性とbyte/SHA復元が必須で、candidateがbaselineから5%未満しか縮まらない、runがない、または安全検証が一件でも失敗ならこの構成をno-goにする。5%はこのpilotを続けるための早期停止線であって、7-Zipに対する合格線ではない。サイズ以外は測定しない。勝っても次段階は複数の固定開発familyでのsize/time/memory評価と7-Zip比較であり、本候補を未見holdoutへ直接調整しない。

実装前のsystem/E2E失敗シナリオ: 空・極小・数字なし・全数字・8 byte境界・連続数字と非数字交互・高bit任意byte・block上限、決定性不一致、run数過大、offset逆順/重複/範囲外、length不足/範囲外、BCD nibble 10..15、奇数padding不正、header/descriptor/digits/literalの各切断、余剰trailing bytes、未知version、整数overflow、baseline/candidate frameの破損・切断、およびdecode後byte/SHA不一致。これらは外部入力を伴う一つの限定E2E実行に含め、単独unit testは追加しない。実測前にコード・fixture・閾値を固定し、結果で変更しない。

## 書庫内CDC完全一致参照のsize-first pilot事前登録 — 2026-10-19

候補表3の「CDC重複除去」を限定検証する。これは過去screenで既に使われたPuTTY Plink 0.82/0.83の開発用pairであり、holdout・未見データではない。既存recoveryに`7zip-pair.7z` 397,939 Bと`candidate.khcd` 557,059 Bがあり、以前の比較でKHC候補が小さくなっていないことを確認済みである。同じpairを一般性能・過去screenの再現・7-Zip比較に使わない。ローカルpilot限りとし、入力をcommit・配布しない。以前の探索で得た41 cross-version exact chunks / 75,871 B（raw pairの4.40%）はtableが固定されていない発見値であり、今回の採否根拠にしない。

固定入力はsource run `1547e376c0654f75baa4628242d672eb`のrecovery ZIP（8,265,238 B、SHA-256 `defd57199689ea58e6c74afc1b1879eab35bc66ac9d15abb64ebca5f9a4b49a3`）内の`source/plink-0.82.exe`（856,688 B、SHA-256 `a86180e9a7ac473ad52fbab2842a1554581c536dd6e112fae9c824dd1041af20`）と`source/plink-0.83.exe`（868,976 B、SHA-256 `7308e9d356f14aa1f08cab1af363f71a077bf35dcb49e50b363418044758cd1e`）だけ。入力順は旧版、新版に固定し、ZIPからはこの2 entry以外を展開しない。各fileは1 MiB以下、raw総量は1,725,664 B。`MaxRunMiB=8`、64 entries、300秒の登録枠を使用し、比較子プロセス以外への出力・TEMPはrun work内だけにする。実行前に未完了lifecycle runがないことと通常/Cargo/保全容量枠を再検査する。

### 固定Gear CDCと実験wrapper

これはこのpilot用の固定Gear-CDCであり、FastCDC実装とは呼ばない。`mix64(z)`はu64 wrapping演算で、順に`z=(z^(z>>30))*0xbf58476d1ce4e5b9`、`z=(z^(z>>27))*0x94d049bb133111eb`、`z=z^(z>>31)`。`gear[b]=mix64(0x4b48435f47454152 + b*0x9e3779b97f4a7c15 mod 2^64)`。file開始時とchunk切断時の`h=0`から、各byte後に`h=(h<<1)+gear[byte] mod 2^64`（64-bit左shiftで上位bitを捨てる）とする。chunk長が512 B以上かつ`(h & 2047)==0`になったbyteの直後、または長さ8192 B到達時に切り、順序は各byteをhashへ追加した後に判定する。EOFの非空tailを出し、空fileは0 chunk。`min=512 / target=2048 / max=8192`、file間でhash stateを共有しない。

比較A/B/Cはすべて同じbuildの`khc::compress_block_with_strategy(..., BlockStrategy::BinaryAdaptive)`完全frameを使う。Aは各fileを単一full-file child frame、BはCDC chunkごとにchild frameを作り参照なし、CはBと同じ境界でfile0のchunkだけを参照表としてfile1を符号化する。file0内・file1内のdedup、同一file参照、再帰参照、外部辞書・暗黙modelは使わない。chunk IDはfile0の出現順ordinalで、完全一致候補が複数なら最小IDを選ぶ。検索は`(length, CRC32)`を候補bucketに使ってもよいが、必ずraw全byteを比較して一致を決める。

全比較に共通の実験wrapper `KCD1` を使う（このscreen専用で製品magic/API/formatではない）。全整数はlittle-endian。16 B headerはmagic `KCD1`、version u16=1、mode u8（A=0/B=1/C=2）、file count u8=2、raw total u64。各file descriptorはname length u16、ASCII basename、raw length u64、raw CRC32 u32、record count u32。nameは32 byte以下のASCII basenameで、空・`.`・`..`・slash・backslash・重複を拒否する。各recordはkind u8（KHC child=0、file0 reference=1）、raw length u32、payload length u32、payload。child payloadはその完全KHC frame、reference payloadはfile0のchunk ordinal u32のみで長さ4。Aの非空fileはchild 1件、B/CはCDC境界record列、Cの参照先はfile0に既に現れたordinalだけ。file名と順は`plink-0.82.exe`、`plink-0.83.exe`。完全一致chunkでもreferenceの4 B payloadがchild frameより小さい場合にだけ参照へ置換する。header、descriptor、name、record、reference ID、KHC frameをすべて含むserialized archive全長で比較する。CRC32は破損検出用で認証ではない。

decoderはheader/file数/name長/chunk数/archive長をallocate前に固定上限検査し、各raw length 1 MiB以下・raw総量2 MiB以下、B/Cのchunk countを各fileの`ceil(raw_length/512)`以下（0 lengthは0、pair全体4,096以下）、B/C child raw 8,192 B以下、A child raw 1 MiB以下、wrapper 8 MiB以下とする。checked arithmeticで全extentを検証し、未知magic/version/mode/kind、切断・余剰tail、record countとraw長総和の不一致、bad child frame、decoded length/CRC不一致を拒否する。referenceはCのfile1からfile0の既復元chunkへだけ許可し、ID・chunk length・payload長を照合する。encoder側のhash collision試験はhashを一定値に強制し、それでも別byte列を参照扱いしないことを確認する。

primary size gateは`20*C <= 19*A`（wrapper込み5%以上縮小）かつ`C < B`（CDC segmentationだけでなく完全一致参照の実削減があること）。さらにA/B/C全ての決定性、完全decode、input全byte/SHA一致、下記E2E全checkの成功を必須にする。失敗・閾値未達はこの一構成をno-goにし、同入力での調整・再試行をしない。勝っても候補表3全体の評価完了や製品採用を意味せず、共有辞書符号化、選択展開、実書庫の仕様は未評価のまま。サイズonlyで、7-Zip、速度、最大memory、製品優位性、holdout性能の主張はしない。

実装前のsystem/E2E失敗シナリオ: 空fileと極小tail、境界長511/512/8191/8192/8193、hash reset漏れとfile境界state共有、強制hash collision、同一chunkの複数候補から最小ID選択、基底file内重複、空・`.`・`..`・slash/backslash・重複name、unknown magic/version/mode/kind、header・descriptor・name・child/reference payload各切断、余剰tail、整数overflowとu32::MAX countのallocate前拒否、raw/chunk/archive上限超過、descriptor count・raw length合計・total rawの矛盾、511-byteの内部chunk、child frame破損とdecoded length mismatch、CRC mismatch、referenceのforward/out-of-range ID・別file由来・length違い・payload長違い・child payload混入、非reference modeでのreference、decoder再封印後も不正なwire構造、全byte/SHA不一致。固定synthetic bytesは、長さ`0,1,511,512,8191,8192,8193`で`byte[i]=(131*i+17) mod 256`の2 file fixture、`0x00..0xff`反復fixture、CDCで得た`0xa5`反復入力の最初のfull chunkを2回連結した基底と同chunkの新版、同長chunkの1 byteだけを変更したforced-collision対照に固定する。これらは固定pairを使う一つの登録E2E実行内だけで検証し、単独unit testを追加しない。測定前にalgorithm/layout・threshold・fixture・source hash・binary hashを固定し、結果を見て変更しない。

実装・実行経路の事前pin: Rust probe `examples/khc_cross_file_dedup_probe.rs` SHA-256 `69eda7f701f829ce35f3d10f5aa8971a977bc5264b3ee14e000ed8ba0fde48df`、固定pair runner `experiments/khc/cross-file-dedup-size-probe.ps1` SHA-256 `a456cf61d7a5e1c141b3fa1b657ef4322716df06a21fcf24d5a21ff654ebfa19`、登録wrapper `experiments/khc/run-storage-experiment.ps1` SHA-256 `d0c552fbe139d2dc4a8130053d7f8f7236da329eb494d178b894fa9a178674bd`、lifecycle module SHA-256 `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3`、Cargo helper SHA-256 `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f`、`Cargo.toml` SHA-256 `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac`、`Cargo.lock` SHA-256 `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554`。Rust `1.98.1 (48a229cea 2026-09-01)` / `x86_64-pc-windows-msvc` release buildに固定する。probe childは240秒、登録outer runnerは300秒の上限とする。build実行ファイル`<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_cross_file_dedup_probe.exe`は1,428,480 B、SHA-256 `f0376e23c15e5fda8b145ad7241abed7f7c97a504dd11bba325173155dc2b299`としてpilot実行前に固定済み。

## 2026-10-19 candidate screen results

### KCS1 / SpatialBits rev7 product screen

固定開発入力`ptt5`（513,216 B、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）のscreen report（SHA-256 `cb15333a8fccb934164a95febd30bb9439d4c4d0f4e396ad1a42839423d0b44d`）は`failed`。内部CPU gateは`[3,13,16]%`で、上限15%を`16%`が超えたため`0-record-fast-trial-create`の前に停止した。存在するのは1件のuntimed SpatialBits trial archiveのみで、RecordFastの決定性確認・候補比較・7-Zip比較は成立していない。圧縮性能の標本・go/no-go判定として扱わない。同run `f92888cacc3d4d8b92032b614b1d7885`の登録work 571,710 BはPrunletで削除済み（operationId `03b53eec078243b2865eb0d97dd67682`、finalize成功）。保全ZIPはSHA-256 `b343305e490751b5442e2a75dd2653c350a993033f0bd35ea2f02db4273487e5`で保持する。

### KDR1 ASCII digit-run size-first pilot

固定開発入力`canterbury-development/cp.html`（24,603 B、SHA-256 `e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61`）のpilotで64 E2E checksが成功し、raw `BinaryAdaptive`完全KHC block frameは7,887 Bだった。KDR1は適格runがなく、候補frameは生成されず`no-go`。これは事前登録済みの早期停止条件による当該入力・構成のno-goで、KDR1一般や他familyへの結論ではない。time、memory、7-Zipは比較していない。workはrun `ff7152186db24d4aa2f00469fe219498`としてPrunlet cleanup/finalize済み（26,685 Bから0 B、operationId `0c7f344d10f9421e916420dc3c2f093f`）。再現用recovery ZIP（SHA-256 `1d14e15b6d1a7cddd9774726951c05432228d7581297df93cb13168109aa0b0b`）とmanifest（SHA-256 `1cc0bc0703e706575a83a681a21001d15ddd95068cb4af93180d8fc95a70808e`）は保持する。

### KCD1 固定Gear CDC / file間完全一致参照 size-first pilot

事前登録済みの開発専用Plink 0.82/0.83 pair（raw合計1,725,664 B、SHAは上記pin）で293 E2E checksが成功し、A/B/Cすべてが決定的に完全復元し、入力byte列・SHA-256が一致した。wrapper込みarchive全長は、A（fileごとのfull-file `BinaryAdaptive` frame）846,860 B、B（固定Gear CDC・参照なし）1,093,808 B、C（file0からfile1への完全一致参照）1,032,207 B。CはBより61,601 B（5.63%）小さいが、Aより185,347 B（21.89%）大きく、事前登録primary gate `20*C <= 19*A`に失敗したため、このpair・構成は`no-go`。後から閾値を変えた再試行は行わない。これは共有辞書・方式一般・製品に関する結論ではなく、size-only測定で速度、最大memory、7-Zip、holdout性能は未評価。

run `a9ac1919733c4ebea92385b4098cf206` はPrunlet delete/purge/finalize済み（1,728,126 Bから0 B、operationId `27fa9900ceb344fd85ec5b74d26847ee`）。`probe.json`（583 B、SHA-256 `5cfdf2893b83805399fe840e86e138fee71a9f248d7576bf391c47197cf33438`）、`result.json`（1,879 B、SHA-256 `6f1d667dccd098fffaf923dba6abd05d07b7107b1f2c096aec2921ba8dcef6ed`）を含むrecovery ZIP（SHA-256 `2515f2f7cd97f42a8ac47fb0152f6c21537d31939c1c4c9b89dd38232f76a7b4`）とmanifest（SHA-256 `0e0ea7d63b2b93e3871e600446432385f03d9fd3385167cb6545542b586c1d06`）は再検証用に保持する。

## KHT1 HTML tag/text byte-span separation size-first pilot preregistration — 2026-10-19

候補表2位の「byte単位の可逆構造分離」を、HTMLのmarkupと本文を別streamへ分ける一方式だけで試す（候補表`:41`、近接技術とablation`:54`）。KDR1 digit-run、plane/delta filters、BCJ/E8/E9、CDC exact-referenceとは異なる候補であり、製品形式・API・decoderは変更しない。結果は固定済み開発入力でのsize-first選別であり、未見データ・代表性・製品性能・速度・最大memory・7-Zip比較を意味しない。`cp.html`はKDR1で既に使ったdevelopment入力のため、未見/holdoutとして扱わない。

固定入力は `canterbury-development/cp.html`、24,603 B、SHA-256 `e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61`。既存保全run `0acc17d780a142dcafe88645a07205a5` の `recovery.zip` は8,737,339 B、SHA-256 `27030319c3938bdec7df681d8113df43318d9a01ee40eef36e43af3e6f86e898`；entry `pipeline-e2e/canterbury/cp.html` をD task workへ一件だけ展開する。測定前にentry length/SHAを再照合し、source archiveを変更・再圧縮・配布しない。

### 固定KHT1 transform

入力上限は既存KHC blockと同じ1 MiB。byte scannerはtext状態で最初の`<`を見つけるとcandidate tagの先頭とし、その後の`>`のうちASCII single/double quoteの外にある最初のものを終端として両端を含むtag spanにする。引用状態はcandidate tag内だけで有効で、同じquote byteで閉じる。閉じたtagの間はtext spanとする。終端`>`がEOFまでなければ、candidate `<`以降のsuffix全体をtextとして扱う。コメント・script・DOM意味解析、escape・正規化・文字再encodingはしない。隣接する同kind spanはmergeし、empty spanは作らない。

変換frameは `KHT1` magic (4 B)、元raw長u32LE、span count u32LE、span descriptor列（各 kind u8: `0=text`, `1=tag`、length u32LE）、全text spanを順序通り連結したtext stream、全tag spanを順序通り連結したtag streamとする。全span長は正、種類は交互、countは元長以下、kind別長の合計は元長、全extentはchecked arithmeticで境界内、入力は厳密終端でなければ拒否する。空入力はspan count 0。decoderは元長を1 MiB以内に制限し、count/descriptor/payloadを確保前に検査する。header・descriptor・payload欠損、unknown magic/kind、zero length、長さ/合計不一致、整数overflow、切断、余分なtrailing bytesを拒否する。KHT1変換frameが1 MiBを超える場合は候補を使用不可にし、baselineのraw経路だけを保持する。

Primary metricは、同一Release executableの `BinaryAdaptive` で符号化したraw cp.htmlの完全KHC block frame `A` に対する、KHT1全metadata/streams込みtransformを同じ `BinaryAdaptive` で符号化した完全KHC block frame `C`。合格は各E2Eが成功し、2回ずつのbaseline/candidateがbyte-identicalであり、decode後raw bytesとSHA-256が入力に一致し、かつ整数式 `20*C <= 19*A`（最低5%縮小）を満たすこと。認識したtag bytesが0、candidate変換不可、またはどれかの条件不成立は当該入力/構成のno-go。測定はsize-onlyで、閾値や方式を結果後に変更しない。

実装前から固定するE2Eは、empty/plain/no-tag、単純tag、quoted `>`、text中の`>`、隣接tag、tag内`<`、未終端`<`とunmatched quote、high-bit/arbitrary bytes、descriptorで1 MiB frame cap超過、決定性、完全往復を含む。子KHC blockを介したKHT1 parser negative casesとして、unknown magic/kind、zero/overlong span count、overflow/overrun、header/descriptor/stream切断、sum mismatch、trailing bytesを拒否し、corrupt/truncated child frameも拒否する。unknown versionはKHT1 magic不一致として拒否する。unit testは追加せず、登録probe一回のsystem/E2Eだけを行う。run budgetは3 MiB / 64 entries / 120秒（child 90秒）。source/runner/lifecycle/common runner hashesはコード固定後・測定前に追記し、probe executable SHAはbuild後かつrun前に追記する。

実装凍結（2026-10-19、source・runner hashはbuild前、probe executable hashは唯一の登録run前に記録）：probe source `examples/khc_html_span_probe.rs` 15,193 B / SHA-256 `953ac75d18e14de57894a90615477d1f8e8d6259328e1f25570a86bccb47dfba`、実行script `experiments/khc/html-span-size-probe.ps1` 10,257 B / SHA-256 `973982ac7245b8035788e13c35b653a312b1d5087d505b938a05ae287bb032de`、登録runner `experiments/khc/run-storage-experiment.ps1` 13,544 B / SHA-256 `f1d6cbe277c21f3e780b6c76fb293039baaf8948f73cb2b4e52f57721e79acff`、lifecycle module `experiments/khc/storage-lifecycle.psm1` 73,285 B / SHA-256 `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3`、serial Cargo runner `experiments/khc/run-serial-cargo.ps1` 9,859 B / SHA-256 `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f`。Release probe executable `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_html_span_probe.exe` は1,358,336 B / SHA-256 `18338e41b5fe7be919603e453b1bac3e60b31a5e3a5ee8d8d7e5888b1c20ed3b`。Cargoは13.91秒で`Finished`を報告したが直列runnerは終了2秒後も`VCTIP.EXE`子process 1件を検出してexit 1になった。そのPID 4504は事後確認時に終了済みで、成果物の実在・hash・3MiB未使用容量枠を確認したため同条件buildを再試行せず、このhashの成果物で唯一の登録runへ進む。

固定run `005de05f0e234e2587866ae3f824f55a` は全29 E2E、決定性、完全roundtrip、SHA照合に成功したがno-go。raw cp.html 24,603 B（SHA-256 `e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61`）に対しbaseline完全KHC frame `A=7,887 B`（SHA-256 `9953688992bb7d86e018d873def391e08d94baef7942ceb99a97e548da6df615`）、KHT1 transform 34,915 B（SHA-256 `647646491e8f7627796ef83ed044c47baabf9d7f1e737a26bcc7463289e87421`）、candidate完全KHC frame `C=9,620 B`（SHA-256 `25c9b82a83de28a962535fd874f1bd46a9e427025bdc210ce850625efbc1acd7`）、recognized tag bytes 14,340。`20*C <= 19*A` を満たさず同一入力の再試行はしない。これは既使用の開発入力一件だけのsize-only結果であり、holdout・速度・memory・7-Zip比較・製品性能・一般化を示さない。Prunlet清掃はoperation `55308015ce8341dfb64f5be3712cb7d0`で完了（31,388 B→0 B）。再検証に必要なfull `result.json` / `probe.json` / `cp.html` は lifecycle record `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\005de05f0e234e2587866ae3f824f55a` の `recovery.zip` 13,971 B / SHA-256 `f051f15d643d569ee4aaea75e931d08dcda4783648055667f1822c27aac66c64` と `recovery.json` SHA-256 `4763203cdcdd69731b51158ebaf3a7af0bef03874fab7060b9f0d27a6c6d3422` に保持する。復元時は新しい外部Tempへzip展開しmanifest記載file SHAを照合する。

### 2026-10-19最新の古典的圧縮手法 screen

[2026 AITDCC challenge preprint](https://arxiv.org/abs/2606.17712)（2026-06-16）は117提出を16種類の訓練／隠しtest fileで評価し、選択した手法を各250,000,000-symbolの外部file Q–TでもLZMA-9等と比較している。外部全体のG9-V1は4.565 b/B、LZMA-9は4.616 b/B（約1.1%差）だが、中央値時間は圧縮2,323.5秒対785.0秒、展開2,203.7秒対17.7秒で、登録済み5%サイズ基準および同程度時間・memory条件を満たさない。G9はhashed byte n-gramのsparse GLN、学習付きcascade logistic mixer、固定小数点・量子化を組み合わせるため候補4に具体的な予測機構を与えるが、論文の原理説明だけではこの大きな演算費を解消しない。[著者のpinned source](https://github.com/Mycsina/compaq/tree/bcce088e7cc0b1f966c9d2bf43b1a30dbefeebe4) はREADMEでStrong profileを約520 MiBと記載する一方、そのrevisionの`LICENSE` raw pathは404で利用条件を確認できない。したがってコード移植・依存採用はしない。

同じTable 4でG7-V10の外部全体は4.722 b/B、圧縮73.9秒・展開10.5秒でLZMA-9より速いが圧縮サイズは約2.3%大きく、速度優先の「同等以上の圧縮率」を満たさない。G2-V3のtype-aware preprocessingは全体4.622 b/BでLZMA-9より僅かに大きく、特定のfile Rでのみ顕著な利得を示す。いずれもLZMA-9は本GOALの7-Zip 26.04 LZMA2ではなく、同等設定・時間・memory比較の代わりには使えないため、これらの公開結果だけで採用しない。

[公式AITDCC dataset page](https://aitdcc.github.io/dataset.html)は16 file全体38,289,319 B、元challengeでhiddenだったI–Pのtest subset 25,153,011 BとSHA-256を公開し、再現・商用検証の利用条件とattributionを示す。将来、候補を固定できた場合の未見評価セットに使えるが、今回は未取得・未評価であり、test結果を調整に再利用しない。2026-10-19のGrok X検索ではAITDCC/G9-V1/G7-V10の作者・研究者の該当投稿を確認できず、これは状況証拠であって方式採否の根拠にはしない。

#### WZIP / WLZ4 (2026-10-19)

同日追加確認した [WZIP/WLZ4研究](https://arxiv.org/abs/2610.06530)（Wu、2026-10-05公開）は、match lengthごとに最大backward windowを変えるWLZを理論解析し、指定されたi.i.d. sourceでのboundを示す。paper自身が、windowだけの利得ではなくtoken codeも重要とし、窓方式の先行形は2017年特許・2021 DCC reportにあると記す。著者repoの [WZIP/WLZ4 READMEと再現可能な測定表](https://github.com/icodywu/WZIP) によると、WZIPはHuffman-coded LZ77で、level 7以降はx86/table/audio/image領域へ試行選択filterも使う。測定はEPYC 9334単thread、2.7 GHz制限、Ubuntu 22.04、GCC 14.2 `-O2`で、各configurationを2回測り、decode値はtrusted decoderである（bounds-checking decoderはWZIPでSilesiaの4–6%遅い）。

| 作者測定 | WZIP-13 | xz -9e |
| --- | ---: | ---: |
| Silesia ratio / encode / decode / encode memory | 4.209 / 0.77 / 1,089 MB/s / 998 MiB | 4.374 / 2.41 / 149 MB/s / 505 MiB |
| enwik9 ratio / encode / decode / encode memory | 4.761 / 0.47 / 939 MB/s / 1,911 MiB | 4.722 / 1.43 / 165 MB/s / 674 MiB |

ratioは入力／出力なのでSilesiaではWZIPの出力が約3.9%大きく、encodeが遅くメモリも約2倍である。enwik9ではWZIPの出力が約0.8%小さい一方、encodeは約3倍遅くmemoryは約2.8倍である。どちらも7-Zip 26.04との同条件直接比較ではなく、強い設定を上回る再現根拠にはならない。したがってWZIPは今回の5% size改善・同等資源ゲート候補として実装・buildせず、KHCの新規案として採用しない。repo licenseはBSD-2-Clauseだがコードは取り込まない。

2026-10-19のGrok X検索では、作者@CodyWueqsによる10-14と10-16の告知（[投稿1](https://x.com/CodyWueqs/status/2110401942463856673)、[投稿2](https://x.com/CodyWueqs/status/2111164911812521991)）が見つかった。内容はWZIPのZstandard比較等の作者主張で、強い7-Zip LZMA2の同条件比較や第三者の再測定を含まない。検索期間中、通常CPU・小メモリで強い7-Zip 26.04 LZMA2を実用的に上回ると独立再現された新方式は確認できなかった。

#### KRS2速度・サイズフロンティア較正（事前登録・2026-10-19）

既知Canterbury `ptt5` の前回製品書庫screenでは、KRS2は7-Zip 26.04 `-mx=9` より書庫が9.66%大きい一方、起動・I/O込みencode中央値が90.1851 ms対164.1892 ms、extract中央値が66.0387 ms対81.9857 msだった。`-mx=9` だけとの比較では、速度優先条件（同等以上の圧縮サイズ）でのKRS2優位を判定できない。そこでKRS2の候補選択は変更せず、既知 `ptt5` 上で7-Zip側の速度・サイズPareto frontierを一度だけ較正する。この開発用screenは未見評価ではなく、結果を一般化せず、後続7-Zip優位判定にも使わない。

固定入力は保全ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`（769,634 B、SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`）の `input/ptt5`（513,216 B、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）。KHCは同一Release CLI（SHA-256 `81bb1f3d0e0aa592317be13e0cc6c4224f19579e51a1382077ace884bb87c732`）で `binary-adaptive` を対照、`record-fast-trial` / revision 6・KRS2を候補とする。7-Zipは公式配布ページが示す26.04 x64（2026-10-05、実体SHA-256 `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`）を使い、`.7z` / LZMA2、要求辞書64 MiB、1 thread、solid on、`-mqs=off`、時刻metadata無効を固定し、`-mx=1,3,5,7,9` の5点を記録する。各点の `-slt` 実効method/dictionaryを保存し、要求辞書と実効辞書を混同しない。[公式配布ページ](https://www.7-zip.org/?dl=1)。2026-10-19にGrok X検索した過去30日は圧縮levelの速度・サイズ比較投稿0件。翻訳者の自己申告をする@7zipは2026-10-06に「7-Zip 26.04 released」と投稿したが、測定はない（[投稿](https://x.com/7zip/status/2107407009817780657)）。

全7方式（BinaryAdaptive、KRS2、7-Zip 5 levels）を5 round順序回転し、各書庫をtest後、展開物のファイル名・全byte・SHA-256を入力と照合する。同方式の書庫hash/sizeの決定性を確認する。各方式のencode/extract起動込みwall timeを計測し、最大WorkingSet/paged memoryも記録する。speed-priorityのscreen passは、(a) 書庫サイズがKRS2以上の7-Zip設定のうちencode+extract median合計が最小の設定を基準とし、KRS2書庫がそれより大きくなく、(b) KRS2の5 round encode・extract中央値が双方5%以上速く、最大WorkingSet・最大paged memoryも双方以下、かつ(c) 7-Zip 5設定のいずれにも「書庫サイズがKRS2以下でencode/extract時間と両memory peakもKRS2以下」というKRS2を支配する点がない場合だけとする。基準は7-Zipの5設定すべてを開示したうえで機械的に選び、結果を見た後の設定選択をしない。これを満たさない場合はKRS2のspeed frontier no-goとし、同条件を再実行しない。CPU gateはrun前および各round開始前の `_Total` 5×1秒sampleすべて15%以下。gate失敗、時間・容量超過、非決定性、復元不一致、計測不能が一つでもあればrunを失敗/no-goにし、同じ条件でretryしない。

Runは既存 `run-storage-experiment.ps1` のみで登録し、固定上限は28 MiB / 128 entries / 900秒。入力・5 roundすべての書庫・展開出力・reportを登録work内に保持し、上限を超える中間出力、登録外の展開、入力選別、7-Zip設定の事後変更はしない。Prunlet lifecycle cleanupの完了前に次のscreenへ進まない。条件を通った場合にのみKRS2を固定し、AITDCC 2026の隠されたI–P全8ファイルを別の事前登録済みheldout実書庫評価へ進める。pass前にI–Pを取得・閲覧・評価しない。現時点でAITDCC I–Pは未取得・未評価。

実行前に固定する実験コードSHA-256：`record-fast-7zip-screen.ps1` `6e66fe705c90e4f1634d17a891d9cec94446ab9b6fb7d9540a1a1c88444c16a5`、`run-storage-experiment.ps1` `87538d50914cefa5b5271c59dcb3ffdb5981dab464de855982f101e6eb6f4552`、`storage-lifecycle.psm1` `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3`、`disk-budget.ps1` `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`。これらのいずれかが異なる場合はrun前に停止する。

#### KCS1と既定MDLの完全frame選択（事前登録・2026-10-19）

次の開発候補として `SpatialMdlTrial` を実装する。各1 MiB blockについて、既定の有料MDL `KHC1BLK` frameと `SpatialBitsTrial` の完全な `KCS1BLK` frameを独立に作り、frame全体のbyte長が厳密に小さい側だけを採用し、同長ならMDLを選ぶ。これにより各blockの出力sizeはMDL以下になる。archive revision 9はKCS1またはMDLの完全KHC1 fallbackだけを許可し、既定revision 1とrevision 1〜8のwire・encoder・decoder動作は維持する。各blockの完全frame込みで比較し、辞書・metadataは追加しない。この比較は新しい符号器ではなく、KCS1と既存MDLのデータ別切替の試作であり、新原理や7-Zip優位の主張はしない。

実装前に固定する失敗条件：空、1 byte、全byte alphabet、repeat/skew/text/固定seed random、BLOCK_BYTESの±1・同値境界、複数fileと2 block以上のfileでbyte/SHA/CRCが一致しない、選択が `min(KCS1, MDL)` でなくtie時にMDLを選ばない、同じ入力でframeが非決定、revision 9がKCS1/MDL以外のfamilyを受理、KCS1/MDLの破損・不正長・checksum・切断・trailing data・未知revisionを拒否しない、旧revision 1〜8の読取または既定MDL出力が変わる、失敗時に既存archive/outputを破損または公開、manifest/path/limit/memory guardを迂回する、CLIが新strategyを作成できない、のいずれかでE2Eを不合格とする。E2EはAPIとCLIのcreate/list/test/extract、全byte/SHA一致、双方のframe family選択、異常archive拒否、旧revision roundtrip、no-clobberを実施し、統計的性能試験や7-Zip優位の判定には使わない。

候補がblock sizeをMDLより増やさないこと以外は未立証であり、追加encode時間・memoryはあり得る。 correctness E2Eが通っても性能候補としての採用・既定化・AITDCC I–Pへのアクセスは自動承認されない。KRS2 speed-frontierの未達条件を成功扱いせず、未見評価へ進むには別の全category事前登録が必要である。

revision 9のfallbackは既定`Mdl`が生成する内側revision 1 / method 0または1のKHC1BLKに限定する。revision 2のLZ frameを「MDL fallback」と誤認しない。実行はWindows x64 Release、`rustc 1.98.1 (48a229cea 2026-09-01)` / `cargo 1.98.1 (797e8a9bc 2026-08-05)`、offline、5MiB / 64 entries / 300秒の登録E2Eで、性能測定ではない。入力はrecovery ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`（769,634 B、SHA-256 `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`）内の`input/ptt5`（513,216 B、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）のみ。`I`〜`P` heldoutにはアクセスしない。

最初のbuild前に、実装・検証入口と容量管理の以下のSHA-256を固定する。いずれかが違う場合はbuildまたはE2Eを開始せず、本登録を追記修正する。

| ファイル | SHA-256 |
| --- | --- |
| `src/khc/mod.rs` | `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa` |
| `src/main.rs` | `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `src/khc/block/mod.rs` | `861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748` |
| `src/khc/spatial.rs` | `8b508ee1c876c0b581af1bba66cecb0e1b183db3eae31349033fa8a0ec374982` |
| `examples/khc_spatial_mdl_e2e.rs` | `9790473fd9e5eb63ac7e841cec3a195eba1cf9c905b816fb1910402035da8e26` |
| `experiments/khc/spatial-mdl-e2e.ps1` | `b3418a894905a35c80c02f8f6746de56b73c570a80256e81ed2bb57193e2b895` |
| `experiments/khc/run-storage-experiment.ps1` | `b65fa9b6b2b25202d69401514b6a909a48c8bf937a55a548feb9b361b1018835` |
| `experiments/khc/run-serial-cargo.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `experiments/khc/storage-lifecycle.psm1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` |
| `experiments/khc/disk-budget.ps1` | `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `experiments/khc/STORAGE.md` | `b22a2d59e19d0b306c0b9017c3e2e7d902c0830df852c3cc8481742c69ed562a` |
| `KHC_FORMAT.md` | `2c7578c047e20234e66d3ea8097c1e54810cdbcbe7fc879f49595207efa67d67` |
| `README.md` | `d4f0bc6bbc8631f07d872497c66c5a630844b71d6390363f2a73caefa1740613` |
| `Cargo.toml` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` |
| `Cargo.lock` | `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |

Build前の`cargo fmt --check`およびPowerShell AST parseは成功済み。build後・E2E前に、Release CLIとexample executableの実hashをこの節へ追記してから一度だけ実行する。E2Eが一度でも失敗した場合は同条件を再実行せず、この候補をno-goとして結果を記録する。

2026-10-19 build amendment (before the second build, no E2E or performance samples): the first pinned build attempt failed to compile the new example with Rust E0382 because the expected-frame branch moved `mdl` / `spatial` before later length assertions. `run-storage-experiment.ps1` was not invoked, so no E2E run was registered or started. The reported `VCTIP.EXE` PID was absent from CIM on the immediate follow-up process check. The example now compares borrowed slices; this updated source hash replaces only the example pin for the next build attempt. All other source, script, manifest, and run-budget pins above remain unchanged.

| Updated file | SHA-256 |
| --- | --- |
| `examples/khc_spatial_mdl_e2e.rs` | `635bb48af49fb8da34e1c4bcf4c0e656b78b7a168a8bdaf89043355d05943b65` |

`rustfmt --check` passed again after the correction. The amended source is the one to build; do not treat the compile failure as an E2E result.

2026-10-19 Release build/E2E input amendment: the second `run-serial-cargo.ps1` invocation compiled successfully and Cargo printed `Finished release profile`, but the wrapper returned exit 1 because its 2-second Job drain found `VCTIP.EXE` PID 28432 still alive. The immediate post-run CIM check found neither that PID nor its parent PID 32476; there were no remaining `cargo`, `rustc`, `VCTIP`, CLI, or E2E processes. The build wrapper failure remains a failure and is not relabeled as a clean wrapper pass. Cargo's completed artifacts are pinned below and will be used for the single correctness E2E; this is not a performance sample.

| Release executable | Bytes | SHA-256 |
| --- | ---: | --- |
| `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe` | 2,557,952 | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_spatial_mdl_e2e.exe` | 1,602,560 | `c1c63ffc96967def1d87f46fbc26dbae4d7d4f9d9c7ef501a73dd4ff2d8fc73e` |

The E2E command in `STORAGE.md` now contains these hashes; its pre-run SHA-256 is `697c06e74c2c1961c31f194623157bc55db29170d24ee092ec1547a02255254e`, superseding only the earlier documentation hash. No executable or candidate-source pin changed after build.

2026-10-19 pre-build capacity amendment: the planned E2E tree was conservatively counted at 66 entries because each of seven rejected-archive cases created its own sentinel directory, exceeding the registered 64-entry cap. The example now retains all seven `verify_archive` rejection checks but exercises extraction non-publication with one representative corrupt KCS1 frame and one sentinel directory. This lowers the planned stable tree to approximately 54 entries without changing the archive matrix or raising the fixed cap. No registered E2E was started. The updated example hash, superseding the prior example-only amendments for the next build, is `b1f7dc873eec74a7e1d775332948f07c7f3dac8d1cbdbe8d6ca3fe8fb039cb94`.

2026-10-19 final pre-build capacity amendment: although ptt5 block selection was already exercised directly, storing it in both the API and CLI source trees added two 513,216-byte file copies and their restored output. The API archive now retains the full synthetic multi-file/multi-block matrix, while the CLI archive uses the pinned ptt5 member plus the tiny `short.bin` fallback case. This keeps CLI integration on the actual fixture and ptt5 block-level exact-frame checks, while reducing expected stable entries from 54 to 52 and the uncompressed input/output footprint by about 1 MiB; the fixed 5MiB/64-entry reservation remains unchanged. No E2E was started. These latest pre-build source hashes supersede only the earlier example and E2E-script amendments:

| Updated file | SHA-256 |
| --- | --- |
| `examples/khc_spatial_mdl_e2e.rs` | `5718f9045bc74bd076ee22724ce067d48bb9b533acb5f793cc990c7c51407c0c` |
| `experiments/khc/spatial-mdl-e2e.ps1` | `c719c271658efda043cad189d3023d1e4d137bf3297fb6a27a396133e768b00c` |

`STORAGE.md` was clarified before build to distinguish the four-file synthetic API archive from the CLI archive containing ptt5 plus the fallback input; its latest pre-build SHA-256 is `2aff6951997d0074c7b7dbd8ce03a0d5f0b8a1bebc14edb6e16bce2bbfd2ea7b`, superseding prior documentation-only hashes. All executable, implementation, runner, manifest, and task-budget pins otherwise remain unchanged.

2026-10-19 final Release artifact amendment, before the single registered E2E: Cargo printed `Finished release profile` for the current preregistered sources, but `run-serial-cargo.ps1` again returned exit 1 because `VCTIP.EXE` PID 32384 survived its 2-second drain. Immediate CIM inspection found neither PID 32384 nor parent 26956; the target binaries exist and the Cargo process is gone. The wrapper failure remains recorded and is not called a clean wrapper pass. The exact binaries for the E2E are:

| Release executable | Bytes | SHA-256 |
| --- | ---: | --- |
| `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe` | 2,557,952 | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_spatial_mdl_e2e.exe` | 1,601,536 | `d3a70fdfbedc9017e7a1c65f880b6f593c277f0eb423d59634ce26a84aff3c2f` |

`STORAGE.md` now carries these binary pins and has pre-E2E SHA-256 `e5b4f33f6daf25bca98453cc6534c4ea8383c66336c5f524c525d1005daffad5`, superseding earlier documentation-only hashes. At this pre-run checkpoint, no E2E or performance sample had been started.

2026-10-19 post-run amendment — the single preregistered revision-9 correctness E2E completed successfully under the fixed 5MiB / 64-entry / 300-second registration. This is correctness evidence only, not a performance or 7-Zip comparison. The executed source pins were `src/khc/mod.rs` `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa`, `src/main.rs` `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa`, `src/khc/block/mod.rs` `861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748`, the E2E example `5718f9045bc74bd076ee22724ce067d48bb9b533acb5f793cc990c7c51407c0c`, and registered PowerShell entry point `c719c271658efda043cad189d3023d1e4d137bf3297fb6a27a396133e768b00c`. Executables and pinned fixture are listed above.

- Run `e60b9d1bbec149d68208c27485165d9b`; API E2E exited 0 with four frames, both `KCS1BLK` and `KHC1BLK` selected, seven malformed archives rejected, legacy revisions 1–8 read, the codec-memory gate enforced, and a 33,153-byte synthetic archive. API corruption checks included corrupt KCS1/MDL frames and verified no publication over a sentinel.
- CLI create/list/test/extract and exact byte/SHA roundtrip exited 0. The CLI archive SHA-256 is `4abe41073bd9a3098b5cde58585d4f54c434c04e1514c72d533de61972f45fe6`; roundtrip SHA-256 values are ptt5 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` and short.bin `073f8a6663fc49fd74e1e6dfd4d18d0bffb6e9a2af848e7adfbd4a567fbf732c`. Existing-destination create/extract and foreign-frame rejection also returned the expected nonzero status without replacing the sentinel.
- Scope caveat: the JSON check named `cli-rejects-corrupt-extract` used the same `api/bad.khc` fixture as `cli-rejects-foreign-frame`; the example writes that fixture after substituting a `KRS1BLK` foreign frame. Its observed error was `revision 9 fallback is not default MDL`. Count it only as another foreign-frame rejection, not as CLI corruption coverage. Corruption and sentinel-preservation coverage was provided by the API example. A distinct CLI corrupt-frame extraction case remains untested.
- Lifecycle run is complete; the 3,825,146-byte work tree was removed through the direct Prunlet CLI procedure and its temporary Prunlet recovery copy purged after receipt validation. The task recovery ZIP remains at `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\e60b9d1bbec149d68208c27485165d9b\recovery.zip` (453,632 B, SHA-256 `e20d93ace231af1192153a4cadc0feb43a6922687d2e32a02dcb3ac608c97f28`); manifest SHA-256 `b3ff388ab9a6eb73d289f36aeed11ab98a283b608d1c276cf0d959029de45bd5`. Prunlet operation ID: `bd0f390a01c0461687d5c37ad0a1bd76`.

## 2026-10-19: revision 9のptt5製品screen（事前登録・開発用）

candidateはRust API/CLIの`SpatialMdlTrial`（archive revision 9）に固定し、既に使用したCanterbury `ptt5` 1件だけでscreenする。比較対象は現行7-Zip 26.04 x64、7z/LZMA2、`-mx=9 -md=64m -mmt=1 -mtm=on`。圧縮・実展開の両方を1 threadで実行し、実効method、argv、tool/source/input hashをreportする。heldout I–Pの内容は使わず、測定前にアクセスしない。

各方式は1 warmup + 9 paired measured rounds。測定順はroundごとに反転する。各archiveを新規pathへ作り、各測定archiveから新規directoryへ実展開し、毎回513,216 Bと固定SHA-256を確認する。`khc-test` / `7z t`は実展開の計時に代用しない。CPUは各create/extract直前にWindows `_Total PercentProcessorTime`を照会し、15%超または取得不能なら即中止し、待機retryしない。各command 30秒、外側run 300秒とし、測定したprocess peak working setが160 MiBを超えたrunは不合格とする（OSによるhard memory capではなく事後の受入れ条件）。全20 archiveのsize/hashと全20復元物を保持し、archive sizeは各方式でround間一致することを確認する。

このsingle-input screenを通過する条件は、全復元一致・決定性・resource boundを満たしたうえで、revision 9の完全archiveが7-Zipより少なくとも5%小さいこと。満たさない場合はこのcandidate/configをno-goとし、同条件で再試行しない。通過してもptt5だけの結果であり、方式の一般優位・速度優位・既定化の根拠にはならない。通過した場合に限り、同じ凍結candidateを使う全category heldout評価の登録可否を別途判断する。

固定容量枠は16 MiB / 96 entries / 300秒。上限を64 KiBとした20 archive、input 1個、20 restored file、512 KiB reportの最低必要量は`21*513,216 + 20*65,536 + 524,288 = 12,612,544 B`。staging/TEMP/log余裕を残し、実測workは登録枠内に全保持する。初回実行前にscript、candidate source、CLI、7-Zip、fixture、共通runner/lifecycleの完全SHA-256をこの記録と`STORAGE.md`へ追加し、固定run cap・既存storage budget・no-pending-runを再確認する。hash未記録、容量不足、CPU gate失敗なら実測を開始しない。

実測に使用する固定pin（2026-10-19、run前再照合必須）：

| 対象 | SHA-256 |
| --- | --- |
| `experiments/khc/spatial-mdl-7zip-product-screen.ps1` | `3ce500d4115653d340afa5b54f667ff5b89d6e5e19a5d32502344b4d1e23f3f4` |
| `src/khc/mod.rs` | `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa` |
| `src/main.rs` | `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `Cargo.toml` / `Cargo.lock` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Release CLI `unlhare-cli.exe` | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| 7-Zip 26.04 x64 `7z.exe` | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| pinned `recovery.zip` | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |
| `run-storage-experiment.ps1` | `6fe4460a23e0fca7539a73937a6ee54af8b2e9d3935c5d596975f21bc51af2ad` |
| `storage-lifecycle.psm1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` |

CLI path: `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe`; 7-Zip path: `C:\Program Files\7-Zip\7z.exe`; fixture path: `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip`.

### 実行結果 — CPU gateで測定開始前に中止（2026-10-19）

登録run `0f3d5e93ba2b42a8985bebad500e6a00` は 16 MiB / 96 entries / 300秒で開始した。外部CPU事前確認は5回とも15%以下（`1, 7, 10, 8, 12%`）だったが、最初の `spatial-mdl-trial` archive create直前に内部 `_Total` sampleが17%となり、事前基準超過で即中止した。reportのstatusは`failed`、`samples=[]`、`candidate_screen_passed=null`、`candidate_decision=null`、`determinism_verified=false`。7-Zipのversion照会以外にcreate/extractは実行されず、比較サイズ・速度・memoryの測定値はない。これは候補のサイズ判定ではなく、ptt5比較は未評価である。同じ登録screenの再試行は禁止条件に従い行わない。

report `spatial-mdl-7zip-product-screen.json`（17,655 B、SHA-256 `9d268797881538b0ea0c77b14804239baa45816af4608037e32149165c878fce`）は次の復元ZIP内に保持した。入力は事前登録どおり `input/ptt5`（513,216 B、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`）、7-Zipは26.04 x64。復元ZIPは87,691 B、SHA-256 `f8915a9710f92d037494a8a9c37c5aa08571ef9f37b0b0ec65aa8e6f4bdbd837`。

`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\0f3d5e93ba2b42a8985bebad500e6a00\recovery.zip` は中断結果・復元に必要な保持物である。Prunlet direct-CMD lifecycleは`complete`し、work treeは530,871 Bから0 Bへ清掃した。未測定なのでこのscreenは7-Zip優位の成立・不成立いずれも示さず、heldout評価へ進む条件も満たしていない。

## SpatialMdlTrial Canterbury11 size-only screen（事前登録・2026-10-19）

前項のrevision-9 `ptt5` performance screenは候補archiveを作成する前にCPU gateで中止したため、サイズ・速度のどちらも未測定である。その登録条件は再実行しない。別条件の次候補として、既に開発・調整へ使用した標準Canterbury11 corpus全体で、revision-9 `spatial-mdl-trial` と7-Zip 26.04 x64のarchive size・決定性・完全復元だけを比較する。これは未見評価ではなく、計時・memory・CPU比較も行わない。結果から性能優位・一般化・既定化を主張しない。

入力は保存済み復元ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip`（8,765,120 B、SHA-256 `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb`）の`pipeline-e2e/canterbury/`直下の11ファイルのみ。実行前のZIP member stream検査で、総2,810,784 B、ordinal filename orderのmanifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`を確認済み。個別memberは次の通り。

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `alice29.txt` | 152,089 | `7467306ee0feed4971260f3c87421154a05be571d944e9cb021a5713700c38f0` |
| `asyoulik.txt` | 125,179 | `eaa3526fe53859f34ecdf255712f9ecf0b2c903451d4755b2edaa2e2599cb0fc` |
| `cp.html` | 24,603 | `e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61` |
| `fields.c` | 11,150 | `85d73e354cc50cec76cb5a50537cf8dc035f8cbb8480f9e1cbe2f7d6c23393c7` |
| `grammar.lsp` | 3,721 | `1b0805dfc0ae706b35aac2bb4e15f02485efd24dda5dbd29de7b2f84d1a88c15` |
| `kennedy.xls` | 1,029,744 | `9af47239ca29dfe20e633f80bbbb9a4cc9783d0803d7b2b5626f42e4c3790420` |
| `lcet10.txt` | 426,754 | `5314ba1dbb03f471df88bec6cd120a938ef60d0fd3511c5c1dce61bf7463245f` |
| `plrabn12.txt` | 481,861 | `07e2e0b461af78c7c647cb53dab39de560198e16f799b4516eccf0fbd69f764c` |
| `ptt5` | 513,216 | `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` |
| `sum` | 38,240 | `ee5733cd76ecc2f9d8ff156adc3c02a7a851051dcf43a2d56ff4ee4ff606bdb3` |
| `xargs.1` | 4,227 | `c58aeb5d2d1e12751d47e7412b45784405fc30a5671b03d480fa05776e183619` |

候補は既存Release CLI `unlhare 1.0.4`の`khc-create --strategy spatial-mdl-trial`、archive revision 9。7-Zip controlは7z/LZMA2、`-mx=9 -md=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off`。有効method/dictionary、版、全tool/input/source pinをreportへ記録する。候補・controlを2回ずつ別名archiveへ作成し、同じ方式のarchive SHA/byte長が一致すること、全4 archiveのtestと実filesystem extract後の11件全byte/SHA一致を確認する。順序はround 1でKHC→7-Zip、round 2で7-Zip→KHCに固定する。

失敗条件はinput/member/manifest pinの不一致、tool/version/source pin不一致、create/test/extractの非zero、archive sizeまたはSHAの非決定、restoreの名前・個数・長さ・SHA不一致、archive限度超過、候補がcontrolより5%以上小さくないことのいずれか。サイズgateは丸めを介さず `candidate_bytes * 100 <= seven_zip_bytes * 95` とする。失敗後は同じ条件を再試行しない。gate通過も開発corpus上のsize-only継続判断に限り、速度・memory・heldout評価・product default化には別の事前登録と直接測定が必要である。

全入力展開、4 archive、4個の復元tree、最大20個の各64 KiB tool log、512 KiB reportと一時公開stagingを含む固定上限は32 MiB / 96 entries / 300秒。保守的容量見積りは、`U=2,810,784 B`、1 archive上限`U+65,536 B`として`U + 4*(U+65,536) + 4*U + 20*65,536 + 524,288 + (U+65,536) = 30,270,528 B`で、32 MiB内に収める。外部入力ZIPは既存保持先から読み取り、実験workへの複製はしない。結果と全出力は登録work内に保持し、清掃はPrunlet staged lifecycleだけを使う。

本登録の実行前に、script、runner、revision-9 source、CLI、7-Zip、入力ZIP、lifecycleとstorage-budget scriptの全hashをこの節と`STORAGE.md`へ追記する。28 MiB等の小さいrun枠へ後から縮めたり、他rootへ分散して合算を避けたりしない。事前budget・no-pending-run・plain path検査のいずれかが失敗したら登録前に停止する。

実行前固定pin（2026-10-19。登録直前に全件再照合する）:

| 対象 | SHA-256 |
| --- | --- |
| `experiments/khc/spatial-mdl-canterbury-size-screen.ps1` | `28db2ed65ff254378aaa811fde43ae3017601ca9239a2a30d8b0eac04911e1ba` |
| `experiments/khc/run-storage-experiment.ps1` | `b68a005dc949f08eba5ec6cea4601a1558da29e269fea2ae81560268c49c7593` |
| `src/khc/mod.rs` / `src/main.rs` | `c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa` / `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `src/khc/block/mod.rs` / `src/khc/spatial.rs` | `861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748` / `8b508ee1c876c0b581af1bba66cecb0e1b183db3eae31349033fa8a0ec374982` |
| `Cargo.toml` / `Cargo.lock` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| Release CLI `unlhare-cli.exe` | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| 7-Zip 26.04 x64 `7z.exe` | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Canterbury recovery ZIP | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` |
| `experiments/khc/storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `experiments/khc/STORAGE.md` | `2cc46e8d5afe4301c3976c358328b0746cffb65f349031cf154a3f629455576a` |

The executable paths are `<作業フォルダー>\UnLhaRe\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe`, `C:\Program Files\7-Zip\7z.exe`, and the input ZIP path listed above. The same fixed values and runner policy appear in `STORAGE.md`.

実行登録前の照合で`src/khc/mod.rs`のSHA-256転記に1文字の誤りが見つかったため、実ファイル値`c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa`へ訂正し、screen・runner・両登録表のpinを再計算した。Canterbury11のrun登録・candidate process起動前の修正である。

### Canterbury11 size-only screen結果（2026-10-19）

- Run `480164ae489b426d811db8fb03cc15cf`。KHC revision 9 `khc-create --strategy spatial-mdl-trial` と7-Zip 26.04 LZMA2 level 9、solid、1 thread、要求辞書64 MiBで2 roundを実行し、順番を反転して決定性を確認した。7-Zipの実効method表示は全memberで`LZMA2:3m`。
- 対象は開発用Canterbury11の11 files・2,810,784 B、input manifest SHA-256 `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`。KHC archiveは両roundとも484,829 B / SHA-256 `648f04505ac91aa1e4e96d82ed26bb85a6ebafcd318bf00273e53ee5fc75cea9`、7-Zipは483,599 B / SHA-256 `ea8b4b785c245001ab0efb5aa0a21d0339cdf74d8d62d5ccdee75b5f1b8e4299`。
- 11-file完全復元と全4 restore manifest一致、両方式の2 round決定性、15 commandのexit code 0を確認。KHCは7-Zipより1,230 B（0.2543%）大きく、`candidate*100 <= 7zip*95`の事前登録gateは不成立。決定はこのCanterbury11 size screenに限ったno-go。
- このscreenはサイズ・決定性・復元のみで、時間・CPU・memoryを測定していない。Canterbury11は開発corpusであり、heldout・一般化・性能優位性の証拠ではない。
- Report SHA-256 `8468136309e434e719390d1186251411203b2b7b47e5d4f6725b0e883a18a099`。Recovery ZIP `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\480164ae489b426d811db8fb03cc15cf\recovery.zip` は7,816,293 B / SHA-256 `531716f5ac879073834328d9a40aad103372b32a30b93de81ac4e337fe7e2ebc`、manifest SHA-256 `026ecae64dca7ab839da5900513d96f307ff37ba0c3a710dfb91dfab4856e46a`。Prunlet staged cleanupはoperation `ceeaddfbf00346758e340e7b36a486fe`で完了し、work 16,021,887 Bを0 Bにした。

## 2026-10-19 追加研究と次候補

### 近年の古典的候補の適合性

- PETRAの施設データ研究（2026-07-31）は、10 beamtimes・5種のデータカテゴリ・9 compressorを対象に、合計212 TiB超で多数の設定を探索し、カテゴリ別validationで設定を再評価した。カテゴリごとに強い圧縮器が異なるという観察は、固定方式よりデータ適応の検討を支持する。ただし対象は粒子加速器施設の研究データで、ここからKHCが7-Zipを上回るとは推論しない。[論文](https://arxiv.org/html/2608.00168)
- BOA Constrictor（2025-11-14提出）はMamba次byte予測とrange codingを組み合わせ、主にCMS/ATLAS/HEPMC等の構造化科学データを評価する。配布ソースには外部モデルとGPU/CUDA依存があり、論文の学習コストは測定時間から除外される。独自の自己完結CPU codecをUnLhaReに導入する候補にはしない。[論文](https://arxiv.org/html/2511.11337v1)、[公式実装](https://github.com/boa-collaboration/boa-constrictor)
- AgentGC（2026-01-20提出）はDNAのk-mer向けcodec組合せと、設定選択用LLMを扱う。評価は4×RTX 4090の専用環境であり、著者設定間の報告差も平均約0.168%にとどまる。一般バイト列、CPU/ARM/macOS、外部モデル不要の要件には適合せず、公開リポジトリで明確な再配布ライセンスも確認できなかったため採用しない。[論文](https://arxiv.org/html/2601.13559)、[著者実装](https://github.com/dingyanfeng/AgentGC)
- WZIP/WLZ4（2026-10-16版）はLZ4由来parseに長さ別距離符号等を組み合わせる。著者のEPYC 9334・1 thread測定では、enwik9のWZIP13はZstd22よりratioが4.759対4.676、encode throughputが0.47対1.41 MB/s、encoder RSSが1911対649 MiB。Silesiaではratioも4.090対4.045で劣る。checked decodeは使える一方、理論論文が著者のUS9,577,665B2を引用し、LICENSEには明示的特許許諾がない。性能費用と特許適用の未解決から現時点で移植しない。[理論論文](https://arxiv.org/html/2610.06530v1)、[工学論文](https://arxiv.org/html/2610.14079v1)、[固定版ソース](https://github.com/icodywu/WZIP/tree/34fca6279e6e0077d40543afe5abef3695e7c55f)

上記の量子着想・量子状態圧縮に当たる候補はなく、通常PC上の新しい量子高速化があるとは扱わない。各論文の性能数値は著者報告で、UnLhaRe環境で独立再現していない。

### Canterbury11後の次候補判断

2026-10-19の登録screenでKHC revision 9 `SpatialMdlTrial` は484,829 B、7-Zip 26.04 LZMA2 mx9は483,599 Bだった。固定gate（7-Zipより最低5%小さい）を満たさず、これはCanterbury11だけのsize no-goである。次に検証する候補は既存frameのblock単位exact-size portfolio（MDL/KHC1、KCS1/SpatialBits、KRS2/RecordFast、KRS3/RecordAdaptive）とする。PETRAはデータ適応の動機に限って参照し、portfolioの独自性・実用性の証拠とはしない。G32/Delta16はG32系の高い探索・一時memory費用、BinaryAdaptive/HybridTrialはKRS2/3内の重複baselineから初回候補集合へ含めない。

まず[事前登録済みblock-size pilot](STORAGE.md#existing-codec-portfolio-block-size-pilot)で、全11ファイルの全blockについて4方式を完全frameで符号化・復号し、最小frameを選ぶ。これは性能測定・製品形式の統合ではない。candidate archive sizeが固定7-Zip比較の5%縮小gateを通る場合だけ、別のrevision 10統合・有限E2E・時間/memory込み製品評価へ進む。失敗、時間超過、非決定性、復元不一致、候補frame検証不成立、既定revisionへの影響はno-goとし、同条件を再実行しない。

#### Portfolio pilot実装・入力の事前pin（Cargo build前）

2026-10-19に候補ソースと固定入力を次のように凍結した。KHC source tree manifestは、全27個の
`src/khc/**/*.rs`について、相対path（`/`区切り）・byte長・各SHA-256をordinal順にUTF-8で連結し、
そのSHA-256を求めた値である。実行時に同じ集計を再計算する。`portfolio-size-pilot.ps1`は
Canterbury11、既存CLI/7-Zip、Cargo manifests、source tree、lifecycleを検査し、outer runnerは
登録前に入力・実行binary・example/CLI sourceとCargo pinsを検査する。

| 対象 | SHA-256 |
| --- | --- |
| `examples/khc_portfolio_size_pilot.rs` | `3f8bf9b6b8aaaca679f70822ec87e4c73d34f14a1542627d2c69b78141922707` |
| all 27 `src/khc/**/*.rs` source manifest | `e24f0502e7ecccdd4933fcfc08217bfe11771eb6c229dc46877364a5754ec424` |
| `src/main.rs` | `35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa` |
| `Cargo.toml` / `Cargo.lock` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` |
| existing Release CLI `unlhare-cli.exe` | `50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3` |
| 7-Zip 26.04 x64 `7z.exe` | `95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53` |
| Canterbury recovery ZIP / 11-file manifest | `b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb` / `bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438` |
| `run-serial-cargo.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| `portfolio-size-pilot.ps1` | `b429ff4e9bff43a3c2021022c36986fc7f21cad95dacffb78ce3de29c80569ad` |

Cargo output is not treated as a preregisterable input. After build, the generated probe SHA-256 and
final outer-runner SHA were recorded before any registered pilot. This is only an artifact pin; the
already-fixed method, source, data, limits, and decision gate did not change.
The first offline Release probe build stopped before registration because its size-gate expression
multiplied `u128` by `u64`; the source was corrected to use `u128` for the complete comparison.
This is a compile-only correction and did not run the pilot or alter its candidate, input, limits,
or threshold.

The corrected `--locked --offline` Release example build compiled for `x86_64-pc-windows-msvc`,
one Cargo job, under a 256 MiB transient reservation. Cargo completed; one wrapper exit 1 was caused
by `VCTIP.exe` surviving the drain grace and then exiting naturally. A single recovery invocation
with unchanged source returned 0 (0.94 s, no rebuild). The probe is 1,357,312 B. Its binary SHA,
final registered-runner SHA, and final `STORAGE.md` SHA are pinned below before run registration.

#### Portfolio pilot post-build pins (before registered run)

| 対象 | SHA-256 |
| --- | --- |
| Release `khc_portfolio_size_pilot.exe` | `fb595c1c8ab5b08135fa634c5d6b9e00ea6a2c7d3da8049f4d0aab06f52f6012` |
| final `experiments/khc/run-storage-experiment.ps1` | `589f29f9b85e22f900e6a6b11040b88bb2812340d282c347551f9ccfa3059ac3` |
| final `experiments/khc/STORAGE.md` | `bb3e11e8a45f949afc74f3313336030bdbc38ee46c31b01e772bef8eea2be80a` |

#### Portfolio pilot result and cleanup (2026-10-19)

The one registered run `b35233c621ef4f7fb8bf7651690cdc20` completed with decision
`go-to-separate-revision-10-integration-and-performance-evaluation`. Its report SHA-256 is
`cec9a17ddc5ed9929060371fa75bf09f780e4f68fb1cba9daa8a606e3549a128`; it is retained inside
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\b35233c621ef4f7fb8bf7651690cdc20\recovery.zip`
(1,667,875 B, SHA-256 `dabaf9fd5ab4792a95570cf8dea84a200bbec84576232772b2c231ba3f0c6324`). Its recovery
manifest SHA-256 is `9044ae1792e221ea4636fa5285635b9612a809a0f20b69639e4de2026bca605a`.

For the fixed development Canterbury11 input (11 files, 2,810,784 B, 1 MiB maximum block size;
each file happened to be one block), four complete-frame candidates passed twice-encoded byte
determinism, full-frame round-trip, and the revision-9 per-block invariant. The hypothetical
candidate archive was 450,309 B, against 484,829 B for revision 9 and 483,599 B for fixed 7-Zip
26.04 LZMA2 mx9. The preregistered `20*C <= 19*A` gate passes (`9,006,180 <= 9,188,381`): 33,290 B
(about 6.88%) smaller than 7-Zip and 9,110 B below the integer threshold 459,419 B. Frame counts:
MDL 8, KCS1 1, KRS2 2, KRS3 0. The largest observed deltas were `kennedy.xls` (47,654 B candidate,
80,858 B revision 9) and `sum` (11,872 B candidate, 13,188 B revision 9).

This is a size-only result on known development data, not an actual revision-10 archive, speed or
memory result, independent holdout, or general superiority claim. It authorizes only separate
revision-10 integration, finite E2E validation, then a separately registered fair performance
evaluation; no same-condition retry is warranted.

The run directory (20 entries, 3,308,747 B) was cleaned via the installed Prunlet CLI in direct
`cmd.exe` calls. Operation `7bb14822c72e45bea6b39a0d91c0f7fc` passed all four stages: delete preview,
delete result, purge preview, and purge apply. `complete.json` records `complete`, 3,308,747 B before,
and 0 B after. The standalone recovery ZIP/manifest were re-hashed after purge and remain available.
The post-result `STORAGE.md` SHA-256 is recorded below after updating that file.

## Revision-10 integration gate preregistration

The size-only gate authorizes one bounded correctness E2E before performance work. Revision 10
will expose `PortfolioTrial` / CLI `portfolio-trial`, selecting the shortest complete frame among
MDL, KCS1, KRS2, and KRS3 in fixed order with stable ties; revision 1 remains the default and
revisions 1–9 remain readable. KRS2 and KRS3 may return their existing BinaryAdaptive KHC1
revision-2 fallback; those complete frames remain eligible in the same comparison as in the
passing pilot. The reader allowlist is KHC1 revision-1 MDL methods 0/1, KHC1 revision-2
BinaryAdaptive fallback methods 0/1/3, KCS1, KRS2, and KRS3. The finite E2E covers deterministic
candidate frames, exact round-trips, actual API and CLI revision-10 archives, the strict
allowed-family matrix, malformed
and unknown-revision rejection, sentinel preservation, and legacy compatibility. It is not a
performance or superiority test. Exact fixture, run limits, failure/no-retry rule, build route,
and cleanup protocol are preregistered in [STORAGE.md](STORAGE.md#revision-10-portfolio-integration-e2e-preregistration-2026-10-19).
Final source/script/build pins must be recorded in both documents before the Release build and
E2E execution; only a clean E2E pass allows a separately preregistered fair-performance screen.

#### Revision-10 build and run preregistration pins (before Release build)

The 42-file Rust/build-input manifest uses every `src/**/*.rs` file plus `build.rs`,
`rust-toolchain.toml`, `Cargo.toml`, `Cargo.lock`, and `examples/khc_spatial_mdl_e2e.rs`; each row is
`relative/path<TAB>lowercase-file-SHA256`, ordinal path order, UTF-8 without BOM and a final LF,
then SHA-256 over the complete manifest. The same input/source pins, fixed recovery member, and
tool scripts are recorded in `STORAGE.md` before the offline Release build.

| Target | SHA-256 |
| --- | --- |
| 42-file Rust/build-input manifest | `33d3ca8895ea039d4b2987548d437c3786fa3ff267e526ef258299999f0160ca` |
| `examples/khc_spatial_mdl_e2e.rs` | `ebc51fd0fedc559480b60fb95ea1d668272e9df23836fb14e5186ea5533aa08a` |
| `src/khc/mod.rs` / `src/main.rs` | `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` / `01c21dcd0b3e5a13d997fe2538ffb2f048072f59c40448f32e0249a49effef7c` |
| `KHC_FORMAT.md` / `README.md` | `3565ae18e60587fdc0fa3627aad423a8752af6fd4ece8a0fa1c5d6ef29803fbd` / `05c975fb20e29696d56f082bcbf2309d9b062a07b4b8583cc4cd8e03cda6fdaf` |
| `Cargo.toml` / `Cargo.lock` / `rust-toolchain.toml` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` / `887f9be066a15585a2c583578e84b0fcb541126d81546276bad3d2ff00d61167` |
| `spatial-mdl-e2e.ps1` | `1f748812f536ab85f01ce5a20a2fc1143de09dc3c9465d47a3b914803641550d` |
| `run-serial-cargo.ps1` / `run-storage-experiment.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` / `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| ptt5 recovery ZIP / member | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` / 513,216 B, `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` |

The one registered run is fixed at 8 MiB / 96 entries / 300 seconds total, with 240 seconds per
child; Cargo targets the existing D-drive task directory, uses Rust 1.98.1 and `--locked --offline`
with one job and 256 MiB transient reservation. Release CLI and E2E executable SHA-256 values are
recorded below and in `STORAGE.md` after build and before registration; the input, condition, and
no-retry rule remain fixed.

##### Revision-10 post-build pins (before E2E registration)

The offline Release build completed for `x86_64-pc-windows-msvc` after one no-rebuild recovery from
the known VCTIP drain condition. Binary hashes and exact output sizes were captured before run
registration; the matching build command and E2E invocation are in `STORAGE.md`.

| Target | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,640,960 | `f4793249b19b7f93331889e082922c7c9d5f29939e9200b11042f0c1e4474c1a` |
| Final pre-run `experiments/khc/STORAGE.md` | — | `11d4de584651027aabfaf43d54ecca04e1a5b246d3d011dedad485031efd375b` |
| Final `experiments/khc/run-storage-experiment.ps1` | — | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |

#### Revision-10 E2E harness failure and corrected follow-up preregistration (2026-10-19)

The first registered run (`b0edb4338a0d4b39bc8c2aaaa83d4464`) stopped before the malformed-input
matrix completed. For the first corrupt-frame fixture, API `verify_archive` and `extract_archive`
both returned errors and the existing sentinel remained unchanged; eight previously completed
entry files also remained. `README.md` explicitly documents entry-by-entry no-clobber and that
earlier completed entries remain after a later failure. Therefore the failing `read_dir == 1`
expectation tested archive-wide rollback that the product does not promise. The CLI loop also reused
one destination across malformed archives. This was a harness defect; it establishes neither a KHC
codec failure nor successful completion of the remaining API/CLI/legacy checks. The registered run
was cleaned with the staged Prunlet workflow; the recovery ZIP and manifest remain retained.

One new corrected correctness run is preregistered, not a retry of the unchanged condition. The
Rust E2E now generates a valid single-entry revision-10 archive containing one full 1MiB zero
block, patches the nine invalid cases into that compact base, and isolates each API extraction
under a fresh output directory. The PowerShell CLI loop likewise uses a fresh output directory per
invalid archive. Both assert the expected rejection and an unchanged pre-existing sentinel without
requiring transaction rollback. This preserves full-block frame-family probes while avoiding
cross-case output contamination and the storage cost of repeatedly extracting unrelated entries.
The cap stays 8MiB/96 entries/300s with 240s per child; one corrected run only, no performance
claim, and no same-condition retry. The exact rationale and command are in
[STORAGE.md](STORAGE.md#revision-10-e2e-harness-correction-follow-up-preregistration-2026-10-19).

| Corrected follow-up pre-build pin | SHA-256 |
| --- | --- |
| 42-file source/build-input manifest | `b9f403b69ade1a4ef4861ea047be6b038026e0bd2b9ee80016c7ccce4c4817e6` |
| `examples/khc_spatial_mdl_e2e.rs` / `experiments/khc/spatial-mdl-e2e.ps1` | `9d84e46c1e4c1ef1260cbb04ab04411fd4abeedf8a0149650cbeefc13c734c39` / `23922e92875d9c5af8eef5dd85dbe65f41183782fa65b9bc97dd39260e11da03` |
| `src/khc/mod.rs` / `src/main.rs` | `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` / `01c21dcd0b3e5a13d997fe2538ffb2f048072f59c40448f32e0249a49effef7c` |
| `Cargo.toml` / `Cargo.lock` / `rust-toolchain.toml` | `3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac` / `d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554` / `887f9be066a15585a2c583578e84b0fcb541126d81546276bad3d2ff00d61167` |
| `run-serial-cargo.ps1` / `run-storage-experiment.ps1` | `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` / `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| `storage-lifecycle.psm1` / `disk-budget.ps1` | `511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3` / `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd` |
| pinned ptt5 recovery ZIP / member | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` / 513,216 B, `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650` |

The final pre-run `STORAGE.md` hash and rebuilt CLI/E2E executable hashes must be recorded here
after the Release build and before the corrected run. The historical first-run hashes above remain
unchanged and identify only the failed harness condition.

The first compile of the corrected harness failed before run registration: Rust reported E0382
because `default_mdl` had been moved into the allowed-frame fixture list and was then reused for
the malformed-MDL case. The fixture list now clones that compressed frame; no production source or
test matrix changed, and no E2E run was started. This final pin amendment supersedes only the
manifest/example hashes in the initial corrected-harness pin table above.

| Final pre-build source pin after the compile diagnostic | SHA-256 |
| --- | --- |
| 42-file source/build-input manifest | `c0ad0f86a684ef5afdbf36b81c2401db5fe2dada4057f5293765e2fdebaf0900` |
| `examples/khc_spatial_mdl_e2e.rs` | `1e4469f44934eebebfb6c879ec087085485c6a01c0466e1adab86277e7e0d2ef` |
| unchanged `experiments/khc/spatial-mdl-e2e.ps1` | `23922e92875d9c5af8eef5dd85dbe65f41183782fa65b9bc97dd39260e11da03` |

#### Corrected follow-up post-build verification pins (before run registration)

The Release build completed for both targets. Its first wrapper call observed the known VCTIP drain
condition; PID 32696 exited naturally, and one bounded no-rebuild call confirmed Cargo `Finished`
with wrapper exit 0. The final preregistration was checked against these exact binaries and the
unchanged pinned input ZIP.

| Target | bytes | SHA-256 |
| --- | ---: | --- |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,643,008 | `588bc81b9bfb6f39f32f942fe488593457b01e12d266785c8426298a13aa787d` |
| Final pre-run `experiments/khc/STORAGE.md` | — | `5a09518087376bea0912f63a5e6e18bfc0afdb96cef09b369af01463f3caebf6` |
| Final pre-run `experiments/khc/run-storage-experiment.ps1` | — | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |

The corrected run was later registered as `1d844efed19145eb9e4029b46302202a` and stopped in the API
malformed-input matrix before CLI or legacy checks. The run-specific cause and the next permitted
condition are appended below; the pre-run hashes above remain historical and are not pins for the
next attempt.

#### Second malformed-G32 fixture correction and next preregistration (2026-10-19)

Run `1d844efed19145eb9e4029b46302202a` failed at the harness assertion that `Gather32Trial` on a
1MiB zero block must produce `KHCG32B`. It correctly produced `KRS1BLK`; the intended foreign-frame
case was not reached. API malformed cases 0–5 passed, while the G32/later API cases, CLI matrix,
and legacy checks remain unverified. This is a fixture selection error, not evidence of a product
failure or a completed correctness matrix. Staged Prunlet cleanup operation
`a126462266f541aab1ed9f2c6b3e3527` removed 7,196,852 bytes; no run work remained. The retained
recovery ZIP has SHA-256 `bb55201dd11c634aaab16f2cadf7f87e3bdcfd4e1ff2252c49f790bc665bb034`; the
recovery manifest SHA-256 is `54d9d7ce54c736cab039cca83b6ac4eee48dc7411e74a7d855f5d68141012471`.

One final corrected correctness run is preregistered under the unchanged 8MiB / 96-entry /
300-second cap, with 240 seconds per child and no same-condition retry. It reuses the existing
65,536-byte skewed `g32.bin` input, builds a separate one-entry base archive from that same data,
and patches a `Gather32Trial` frame produced from identical bytes. The Rust E2E asserts the
`KHCG32B` magic before using this fixture. The other invalid-frame cases use the existing
one-entry `a-main.bin` base; no extra 1MiB source is added. No performance claim follows from this
correctness run.

| Next corrected run pre-build pin | SHA-256 |
| --- | --- |
| 42-file source/build-input manifest | `f3e87c63e65725b5524f408238dd5cffcaf19ac790ef168fcfea8faceb0240d7` |
| `examples/khc_spatial_mdl_e2e.rs` / `experiments/khc/spatial-mdl-e2e.ps1` | `aa0a0a097cb85d174595b4489ace098daa4be0a313cb4feb3d32b8893f2c3a15` / `23922e92875d9c5af8eef5dd85dbe65f41183782fa65b9bc97dd39260e11da03` |
| unchanged `src/khc/mod.rs` / `src/main.rs` | `3dca2ae01cc4eccde0df05c39bfee3ae6a53fd884a5fc9c01d83f93598347dec` / `01c21dcd0b3e5a13d997fe2538ffb2f048072f59c40448f32e0249a49effef7c` |
| pinned ptt5 recovery ZIP | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

The final source pin supersedes only the prior next-run fixture and example hashes.

#### Final pre-registration build and capacity verification (2026-10-19)

The offline, locked Release build succeeded through the serial Cargo wrapper (exit 0, 14.39s,
one job). The 42-file manifest and every harness/helper/input pin matched. `rustfmt --check` and
the PowerShell AST parse passed; the CLI reported `unlhare 1.0.4`. No Cargo/Rust/CLI/E2E process or
pending lifecycle reservation remained. The fixed storage preflight measured 1,789,420,627 B total
against 32,212,254,720 B, 1,597,693,061 B Cargo against 6,442,450,944 B, 636,748,567 B external
against 2,147,483,648 B, 170,967,770 B lifecycle against 1,073,741,824 B, and 547,780,222,976 B
free on D:. The registered build's sampled peak was 450,180,292 B within its 256MiB reservation.

| Final pre-run artifact | bytes | SHA-256 |
| --- | ---: | --- |
| 42-file source/build-input manifest | — | `f3e87c63e65725b5524f408238dd5cffcaf19ac790ef168fcfea8faceb0240d7` |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,645,568 | `c0d3866586c504f830fddf8c931623f1d964fc25baa226e75bce2afc99f97c2c` |
| Final pre-run `experiments/khc/STORAGE.md` | — | `2ddcb6186f06ee9392e1328a167a6664d1fa3e203ce5ca62beb14925002383cf` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

These exact pins were verified immediately before registration. They identify this single changed
correctness condition; a failure is not eligible for a same-condition rerun.

#### Revision-10 E2E fixed-tree-cap correction and next preregistration (2026-10-19)

Run `f26e7d189380473d881d1bf602aa3bd1` was registered with the preceding exact pins and stopped
when the E2E work tree reached 97 items against its fixed 96-entry cap. Its 7,245,793-byte tree
was still below the 8MiB limit. The API malformed matrix (including G32) and revision 1–9
compatibility outputs were present, but the final report was absent and the CLI matrix had not
completed. This is a run-cap failure, not evidence of codec failure or a complete E2E pass.

A targeted diagnostic of the saved truncated archive made both CLI test and extraction return exit
1, preserved the sentinel, and left a payload byte-identical to the source (1,048,833 bytes,
SHA-256 `5a257432083de2353c16bc0937134e4dc56ce2fb1e959fff1f85e4c68081c3d6`). This diagnostic is
not part of the registered run. The abandoned run was recovered using the lifecycle helper after
adding this registered E2E entry point to its recovery allowlist, then cleaned through staged
Prunlet operation `226b9eb30c9b4d88950829944b0c543d`. Finalizer recorded 8,294,626 bytes before and
0 after; recovery ZIP/manifest hashes are recorded in [STORAGE.md](STORAGE.md#revision-10-fixed-tree-cap-e2e-correction-2026-10-19).

One new correctness run is preregistered with the same 8MiB / 96-entry / 300-second cap and all
nine malformed cases. The API and CLI harnesses share a sentinel destination for the seven
invalid-frame cases that must not write a payload. The two archive-trailer cases that can leave a
fully completed, byte-identical entry receive independent destinations; any resulting output must
match the source. The old partial tree plus its six remaining CLI rejection destinations and final
report projected about 110 items. Grouping both API and CLI destinations is projected to about 86,
below the unchanged 96-item cap. This is an estimate from the recovered inventory, not an executed
result; no performance claim follows.

| Next fixed-tree-cap run pre-build pin | SHA-256 |
| --- | --- |
| 42-file source/build-input manifest | `8a23554ebea6590f3198db430913944827d0f8ca27e6155e513b3b60e89426c7` |
| `examples/khc_spatial_mdl_e2e.rs` | `560905920af192ac77be18fcb908f87a97aea6d8dd7bc4adee99b07a666a2b31` |
| `experiments/khc/spatial-mdl-e2e.ps1` | `b2374919aa504335ca9eb08cab5fd27f138b90f2a1791285a4c392153ef34bbc` |
| recovery helper `experiments/khc/storage-lifecycle.psm1` | `cdc969afd996a75882be0111301c336a85f1e3519c9952fdda800dc44f2a9be3` |
| `run-storage-experiment.ps1` / `run-serial-cargo.ps1` | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` / `053532f8fa0266b23a6dcc02e60bfb54e94d5d58d874a71692df51dec16a158f` |
| pinned ptt5 recovery ZIP | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

#### Reduced-tree final pre-registration verification (2026-10-19)

The offline/locked Release build succeeded. The initial wrapper returned 1 only because VCTIP PID
31612 survived its drain grace; it exited naturally, and one bounded no-rebuild invocation returned
0 with Cargo `Finished`. `rustfmt --check`, the E2E and helper PowerShell AST parses, and the 42-file
manifest check passed. CLI version is `unlhare 1.0.4`; there are no target processes or pending
lifecycle reservations. Storage remains within fixed limits: 1,790,238,086 B total, 1,597,696,133 B
Cargo, 637,566,026 B external, 171,782,157 B lifecycle, and 547,556,679,680 B free on D:.

| Exact next-run pre-registration artifact | bytes | SHA-256 |
| --- | ---: | --- |
| 42-file source/build-input manifest | — | `8a23554ebea6590f3198db430913944827d0f8ca27e6155e513b3b60e89426c7` |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,640 | `d4bb3554a070d8abaffe0338683bf28bfacb13d47ffc4d2b3d6e095631f28d01` |
| Final pre-run `experiments/khc/STORAGE.md` | — | `e85abf17b3a3960d634d4142499b813685d88a041257d18e2127972ebb78c969` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| `experiments/khc/storage-lifecycle.psm1` | 73,377 | `cdc969afd996a75882be0111301c336a85f1e3519c9952fdda800dc44f2a9be3` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

These pins were rechecked with no pending run immediately before registration. One reduced-tree
correctness E2E is now permitted; a failure is not eligible for a same-condition replay.

## 出典

[^1]: Nikhil Krishnan、Dror Baron、[A Universal Parallel Two-Pass MDL Context Tree Compression Algorithm](https://arxiv.org/abs/1407.1514)、2014-07-06、v4 2015-03-21。
[^2]: Jingyang Du、Yang Shen、Anling Xiang、[STC Reversible Digit-Context Decomposition for BWT-Family Text Compression](https://arxiv.org/abs/2606.03570)、2026-06-02、v3 2026-06-15。[著者コードとlicense](https://github.com/thu-nmrc/STC-for-BWT-FamilyText-Compression)。
[^3]: Igor Pavlov、[7-Zip公式](https://www.7-zip.org/)、26.03（2026-09-03、前段のscreenで使用）および26.04（2026-10-05、2026-10-16に現行版として確認）。[LZMA SDK](https://www.7-zip.org/sdk.html)、[本体license](https://www.7-zip.org/license.txt)。
[^4]: Wen Xiaほか、[FastCDC a Fast and Efficient Content-Defined Chunking Approach for Data Deduplication](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia)、USENIX ATC2016。
[^5]: Yann Collet、Murray Kucherawy、[RFC8878 Zstandard Compression](https://www.rfc-editor.org/rfc/rfc8878.html)、2021-02。[辞書API](https://github.com/facebook/zstd/blob/dev/lib/zdict.h)、dev版更新日不明、releaseとは区別。
[^6]: Fabrice Bellard、[ts_zip Text Compression using Large Language Models](https://bellard.org/ts_zip/)、配布版2024-03-02、ページ更新日不明。
[^7]: [LLMZip Lossless Text Compression using Large Language Models](https://arxiv.org/abs/2306.04050)、2023-06-06。[著者実装](https://github.com/vcskaushik/LLMzip)、更新日不明。
[^8]: Fabian Giesen、[Interleaved entropy coders](https://arxiv.org/abs/1402.3392)、2014-02-14。
[^9]: Richard Jozsa、Stuart Presnell、[Universal quantum information compression](https://arxiv.org/abs/quant-ph/0210196)、2002-10-29。Schumacherの[Quantum coding](https://doi.org/10.1103/PhysRevA.51.2738)、1995年は理論の背景。後者本文は今回親の取得が失敗したため、具体的な数値主張は使わない。
[^10]: Daniel Gibneyほか、[Near-Optimal Quantum Algorithms for Bounded Edit Distance and Lempel-Ziv Factorization](https://arxiv.org/abs/2311.01793)、2023-11-03。[本文2節の計算モデル](https://arxiv.org/html/2311.01793v1)。
[^11]: Zhao-Yu Hanほか、[Unsupervised Generative Modeling Using Matrix Product States](https://arxiv.org/abs/1709.01662)、2017-09-06、v3 2018-07-19。[作者MITコード](https://github.com/congzlwag/UnsupGenModbyMPS)。
[^12]: Olivia Di Matteoほか、[Fault tolerant resource estimation of quantum random-access memories](https://arxiv.org/abs/1902.01329)、2019-02-04、v2 2020-01-23。
[^13]: Meta、[Zstandard v1.5.7 release](https://github.com/facebook/zstd/releases/tag/v1.5.7)、2025-02-19。[公式reference実装](https://github.com/facebook/zstd)、[固定版BSD license](https://github.com/facebook/zstd/blob/v1.5.7/LICENSE)。
[^14]: Ilya Grebnov、[libsais](https://github.com/IlyaGrebnov/libsais)、2.10.4、2025-09-01。
[^15]: Roberto Tacconelli、[Nacrith: Neural Lossless Compression via Ensemble Context Modeling and High-Precision CDF Coding](https://arxiv.org/abs/2602.19626v2)、arXiv:2602.19626v2、2026-02-24。評価条件・結果・制限は本文4〜6節。
[^16]: 著者の[Nacrith-GPU実装](https://github.com/robtacconelli/Nacrith-GPU)、確認日2026-10-15。GitHub表示licenseはApache-2.0。
[^17]: Hugging Faceの[SmolLM2-135M model card](https://huggingface.co/HuggingFaceTB/SmolLM2-135M)、確認日2026-10-15。表示licenseはApache-2.0。モデル重み・実装の再配布時は実際の配布物に添付されたlicenseも確認する。
[^18]: Igor Pavlov、[7z形式の公式仕様概要](https://www.7-zip.org/7z.html)（solid、LZMA2、BCJ2等の標準filter）および[公式FAQ](https://www.7-zip.org/faq.html)（solid書庫の既定name順と`-mqs`のtype順）。7-Zip 26.04の公式配布確認は[download page](https://www.7-zip.org/download.html)。
[^19]: OpenSSL Project、[openssl-enc 3.5 manual](https://docs.openssl.org/3.5/man1/openssl-enc/)、確認日2026-10-16。`-K`と`-iv`の16進値を明示でき、対応cipher一覧に`chacha20`がある。手順書の根拠であり、今回のexecutable/provider/config/hashや暗号化outputを検証した証拠ではない。

### 2026-10-19 correctness-E2E resource amendment

The registered revision-10 correctness E2E `6099198442bf4f70a2002977dfa3c1e8` stopped without a
final report at 9,343,435 B against its unchanged 8,388,608-B / 96-entry / 300-second cap; it
exceeded only the byte cap, by 954,827 B, while four rejected truncated/trailing archives had
left 1,048,833-B partial payloads. It is not a correctness pass, performance result, or evidence
against the format. The failed work was fully SHA-256-preserved and cleaned through the registered
Prunlet lifecycle; `STORAGE.md` records the manifest, recovery ZIP, and receipts. A recovery-only
1-MiB overshoot allowance was added for preserving this sampled-run overrun; the original
registration and future experiment cap remain unchanged, and the allowance cannot admit a new run.

The next correctness condition changes only the invalid-archive base used for the two trailer
corruption cases from the 1-MiB `a-main.bin` to the already-present 65,536-byte `g32.bin`. API and
CLI still verify rejection and byte-exact partial outputs, all nine invalid cases remain, and the
main archive, round-trip, and revision-1–9 checks are unchanged. The measured performance protocol,
datasets, 7-Zip settings, thresholds, and holdout criteria are untouched. This is a new
resource-bounded correctness condition, not a replay of the failed condition or a performance
claim.

The updated 42-file Rust/build-input manifest is SHA-256
`82373547f52adf611a6d1bb56b805b7082577887ecdd02372bc04a0a8950047e`. Updated source hashes and
the exact storage-document pre-run hash, Release binaries, and E2E registration parameters are
now pinned below before registration. The offline locked Release build finished successfully via
the serial Cargo wrapper; CLI version remains `unlhare 1.0.4`.

| Exact modified-fixture pre-registration artifact | bytes | SHA-256 |
| --- | ---: | --- |
| 42-file Rust/build-input manifest | — | `82373547f52adf611a6d1bb56b805b7082577887ecdd02372bc04a0a8950047e` |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,640 | `f2776733fa522278c9c5123d07f782ccb2cb9e698a56b876b5a7ea220c76d20d` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `1b7183d12676b5c573a85c2d49e0c99e8a3ac1bc0f7b859f4e03d4d9901554e5` |
| `experiments/khc/spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `experiments/khc/storage-lifecycle.psm1` | 73,844 | `b6b6adaff2d887a43e7f8a3a3412029d130873e7b8e687988fb76c9508c95caf` |
| final pre-run `experiments/khc/STORAGE.md` | — | `d44e54662f54947d9f9f26da18dd4c5bb61499e164ee34af7d6f81f616df8684` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

Register only with `spatial-mdl-e2e.ps1`, parameters `InputRecoveryZip` set to the pinned ZIP,
the two exact Release binary paths and hashes above, and `ChildTimeoutSeconds=240`; the outer
`run-storage-experiment.ps1` limits remain 8 MiB / 96 entries / 300 seconds. Immediately before
registration, the storage ledger had 0 reserved bytes and all fixed budgets were within limits;
no Cargo, rustc, CLI, or E2E process was running. Detached Visual Studio `VCTIP.EXE` PID 9584
remained at 0 ms CPU over a 2-second sample; it is documented in `STORAGE.md` because this
correctness run makes no performance claim. All benchmark and holdout conditions remain untouched.

#### Result of the 65,536-byte correctness attempt

The registered run `adba876cae654be1a35642faf3a58425` failed before the CLI matrix because the Rust
E2E still asserted that its now-65,536-byte invalid-base archive contained two frames; the
observed correct count was one. The tree was 4,059,113 B / 33 entries, within the unchanged cap,
but no final report was written. It is not an E2E pass or performance evidence. Its verified
recovery ZIP and Prunlet cleanup operation are recorded in `STORAGE.md`.

The Rust E2E assertion is corrected to expect one frame for this 65,536-byte fixture. The next
run is a failure-driven code correction so the full unchanged nine-case API/CLI matrix can execute;
it does not change the format, datasets, performance protocol, or acceptance thresholds. The
updated locked offline Release build finished through the serial Cargo wrapper, and all exact
inputs are pinned below before registration.

| Exact corrected-fixture pre-registration artifact | bytes | SHA-256 |
| --- | ---: | --- |
| 42-file Rust/build-input manifest | — | `85a8e995cbabb3ccf941b1995087c71374cc5bceadd42299237fd3fab4441c02` |
| Release `unlhare-cli.exe` | 2,558,976 | `4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403` |
| Release `khc_spatial_mdl_e2e.exe` | 1,648,128 | `5dc4331196cac4ecf79bfac005792f4f3d8cf8a8781e9d85e3bde7c2cdacf4d0` |
| `examples/khc_spatial_mdl_e2e.rs` | 22,744 | `9d834c3c255fe2e14b920c47fca309bb1cb8d4e517b19ffc4221ede6faffd07c` |
| `experiments/khc/spatial-mdl-e2e.ps1` | 11,596 | `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b` |
| `experiments/khc/storage-lifecycle.psm1` | 73,844 | `b6b6adaff2d887a43e7f8a3a3412029d130873e7b8e687988fb76c9508c95caf` |
| `experiments/khc/run-storage-experiment.ps1` | 31,417 | `1e82897117deac3cea5933741eab7eb59a634db7fb0a3ac93702b6b27182fa44` |
| final pre-run `experiments/khc/STORAGE.md` | — | `604de62bc69e4d7772631126d04676da5451e631c655e01242fd0c3210774e5c` |
| pinned ptt5 recovery ZIP | 769,634 | `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75` |

Register only `spatial-mdl-e2e.ps1` with the pinned recovery ZIP, exact CLI/E2E paths and hashes,
`ChildTimeoutSeconds=240`, and outer limits 8 MiB / 96 entries / 300 seconds. Immediately before
registration, lifecycle reserved bytes were 0 and all fixed storage budgets were within limits;
no Cargo, rustc, CLI, or E2E process was active. Detached `VCTIP.EXE` PID 9584 remained at 0 ms
CPU in a 2-second sample; this correctness-only run makes no performance or memory claim.

#### Completed revision-10 correctness E2E

The corrected run `2358ef6daec7423d968be896e2452803` passed the entire finite correctness matrix
under the unchanged 8 MiB / 96-entry / 300-second cap. The API E2E exited 0 with eight frames,
nine malformed archives rejected, legacy revisions 1–9, and the reservation-guard check. The CLI
matrix completed all 34 recorded commands (14 expected success exits and 20 expected rejection
exits), including create/list/test/extract, no-replace, the nine malformed archives, and legacy
revision reads. Both extracted input files matched their input SHA-256 values. The complete report
is retained in the registered recovery ZIP and detailed in `STORAGE.md`; this result makes no
performance, compression-ratio, or memory comparison claim. The remaining GOAL still requires
fair 7-Zip measurements on representative and held-out data and may not treat this correctness
pass as performance evidence.

#### Revision-10 Canterbury11 product screen pre-registration (2026-10-19)

The integrated Release CLI `unlhare 1.0.4` is now screened once against the complete fixed
Canterbury11 development set using `PortfolioTrial` revision 10 and 7-Zip 26.04. The official
download page identifies 26.04 (2026-10-05) as the current Windows version; checked 2026-10-19:
<https://www.7-zip.org/download.html>. This screen is not a holdout or a GOAL completion claim.

The pinned input recovery ZIP is 8,765,120 B, SHA-256
`b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb`; its complete 11-file raw
manifest is 2,810,784 B, SHA-256
`bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`. Candidate CLI SHA-256 is
`4f9fa4e293404c82335ace434271fd646ed62468fb32365d6fcf3e1d0641a403`; 7-Zip 26.04 x64 SHA-256 is
`95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`. The revision-10 runner,
screen, lifecycle module, disk-budget script, Cargo manifests and complete 37-file Rust source
manifest are hash-pinned in the accompanying storage preregistration. The CLI's registered
42-file Rust/build-input manifest remains
`85a8e995cbabb3ccf941b1995087c71374cc5bceadd42299237fd3fab4441c02`.

Protocol: one warmup plus nine paired measured rounds in alternating order; full archive creation
and filesystem extraction for each 7-Zip `-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off`
archive and each KHC `khc-create --strategy portfolio-trial` revision-10 archive. Timestamps are
disabled and the same sorted eleven-name list is supplied explicitly. The listing verifies actual
7-Zip format, one solid block, all eleven members, effective LZMA2 dictionary and timestamp
properties. Every extraction must reproduce the fixed names, lengths and SHA-256 values; archive
byte length and SHA-256 must be deterministic across all ten runs of each product. Each timed
command requires five one-second `_Total` CPU readings <=15%, has a 60-second timeout and a 160 MiB
process memory ceiling. The registered storage cap is 128 MiB / 512 entries / 1,800 seconds, scoped
only to this fixed screen; other experiment registrations remain capped at 32 MiB. The conservative
output estimate is 117,077,152 B, below 128 MiB. No same-condition retry is permitted after a
failed preflight, measurement or correctness check.

The development screen decision requires all nine pairs, deterministic archives and exact restores,
candidate total archive size <=95% of 7-Zip, and candidate creation **and** extraction wall-time
medians no greater than their 7-Zip counterparts, matching the rate-priority gate in
`GOAL_GATE_20261005.md`. Passing only allows a separately registered reversed-order reproduction;
the independent held-out corpus and all-category requirements remain outstanding.

The storage preregistration, including the exact runner command and per-file pins, had SHA-256
`6e58304d40dd3808b736d724abca895a32583a3965dcb00ff9dc3f3abf4d709e` immediately before this
research entry was appended. That hash identifies the pre-run storage contract; a later result
amendment must not replace it.

#### Revision-10 product screen work-root correction and follow-up preregistration (2026-10-19)

Registered attempt `8d672b458eec4fc69aa17b7f2b2deed8` failed before any compressor/archive command:
the worker enumerated the registered work root before creating it, while registration creates only
the lifecycle record. The report write then failed against the same absent root. This attempt has
zero expected files, entries, bytes and product samples, so it is not performance evidence. The
empty record was safely finalized after verifying the owner had exited and the work root was absent;
`BeforeBytes=0`, `AfterBytes=0`, with no deletion required.

The worker now creates the validated run root as one direct child of the validated task root,
without overwrite, before the first inventory. If setup fails, it avoids writing under a missing
root; later report/inventory errors are secondary and preserve the first failure. No codec,
candidate, input, tool, measurement protocol, limit or acceptance criterion changed. This is a
separately preregistered harness correction, not an unchanged rerun. The single corrected run uses
the same Canterbury11 development screen, 1 warmup plus nine alternating measured pairs, pinned
7-Zip 26.04 LZMA2 and the existing 128 MiB / 512-entry / 1,800-second envelope. A failure stops this
condition; it must not be retried unchanged.

The corrected worker SHA-256 is
`ce284ce0b506e635b604afa630ef9b9da01b415f7d869179c1b65551ea3e6d9c`. The unchanged runner,
lifecycle module, disk-budget helper, CLI, 7-Zip executable, Canterbury11 input and 37-/42-file
source/build manifests are pinned in the additive follow-up section of `STORAGE.md`. The updated
`STORAGE.md` SHA-256 immediately before this research amendment was
`1bfb3273ef43dc198dd05a3ee7e509bac28c89eeb6ecdc1b24f066d5d8c9d5b9`; it identifies the corrected
pre-run contract and does not replace the preceding historical pin. The follow-up has not yet been
registered or executed.

#### Revision-10 product-screen wrapper-pin pre-registration stop and amendment (2026-10-19)

The attempted registration of the corrected worker was rejected by the runner before lifecycle
registration because its screen-specific exact worker pin still named the preceding worker SHA
`7dcab75d9811dc1b5af8bb23d4594995de3a2e3ed290a679643a9eb8a01203b7`. No run record, work root,
archive, timed command or product sample was created. This pre-registration stop is not performance
evidence. The runner now pins the corrected worker SHA
`ce284ce0b506e635b604afa630ef9b9da01b415f7d869179c1b65551ea3e6d9c`; its SHA-256 is
`83bb8f1e29b9a732b224dd89fb50e90b3e13fc7a5f18376de2eeba12ca80a361`. No generic resource cap,
path validation, codec code, compression input, measurement protocol or pass criterion changed.

The rejected attempt is closed. One new registration may proceed only after verifying the exact
runner/worker pair and refreshing the documented pre-run checks; any failure stops without an
unchanged retry. The updated `STORAGE.md` SHA-256 immediately before this amendment was
`917378dbe051a47c78d0d2571595ae0c2c9578c3c6bf942738bac18fdab6ba9e`. That is the newest
pre-registration contract; the earlier fixed hashes remain historical and unmodified.

#### Revision-10 product-screen per-counter memory gate correction (2026-10-19)

Before the remaining follow-up registration, independent review found that an untimed version or
archive-list command skipped all memory recording and limit checks when any one counter was missing.
The worker now records and checks each positive working-set, paged-memory and private-byte counter
independently, identifies missing fields, and reports partial sampling accurately. Timed
create/extract requirements and all command arguments, caps, inputs, output bounds, timeout,
acceptance criteria and product code remain unchanged. No registration or product command was run
after this correction.

The corrected worker SHA-256 is `57f85cc3fda72ca940d5a28c909bea592cbc64705a76886c4a05343e1b376b8b`
(32,024 B); the matching fixed runner SHA-256 is
`d78c09bccd36bc509029e49687d6305922517c7fb9d226bc83b57bd33076b470` (35,588 B). The storage
preregistration immediately before this amendment has SHA-256
`b9e0107188941b6970370927524b74bca183aa2e8960849e6331913d6301b138`. This is the current
pre-registration contract; all earlier hashes remain historical. One registration remains after a
fresh full pre-run check of this exact worker/runner pair and the documented process, lifecycle,
budget, input/tool/source and CPU conditions. Any failed check stops without an unchanged retry.

#### Revision-10 product-screen live-memory sample accounting correction (2026-10-19)

The follow-up registration using the per-counter worker (`9df233fe994b4af08db05acbf666bfc9`) failed
in its first `portfolio-trial` create command. The child exited 0 after 2,257.1765 ms (2,187.5 ms
CPU), and the report contained 62 complete positive memory observations with maxima of 24,637,440 B
working set, 20,893,696 B paged memory, and 16,224,256 B sampled private memory. It still reported
`Missing memory counter: 0-portfolio-trial-create` and partial sampling. Per-poll process-exit state
was not recorded, so a post-exit polling race is a hypothesis, not a verified cause. The run wrote a
450,309 B archive but stopped before format/size/determinism validation, test, extract, or restored
manifest comparison; it provides no product comparison or performance evidence. The recovery and
staged-cleanup record are retained in the corresponding additive incident entry in `STORAGE.md`.

The worker now maintains a distinct `live_memory_samples` counter. It increments only when all three
counters are positive and the child is confirmed alive immediately before and after the read. Timed
commands require at least one such complete live sample plus positive maxima for every required
counter. Missing live counters remain fatal; after-exit missing fields are tolerated only after a
complete live sample already exists. Each positive observation still passes through the independent
160 MiB checks. This correction changes measurement accounting only; codec, inputs, timing,
commands, resource envelope, acceptance criteria, and product code are unchanged. This registered run
supersedes the earlier per-counter entry's "not yet run" status, which was accurate when written.

The corrected worker is 33,153 B with SHA-256
`de1ddd49dd0f0ba5606c1d247839387337ae3e0d94e3c0eff65b658a1c32eac1`; the fixed runner is 35,588 B
with SHA-256 `4815a60909cb1265496fbd1ce5f637a533cf91f6dc5a9bec844d32f83cbc0258`. The
`STORAGE.md` SHA-256 immediately before this amendment is
`77fd5b233ba9995570ee8510cb73cacda1b3449063782d254e0ee9ebb9e3ec87`, identifying the complete
updated pre-registration contract. One registration with this exact worker/runner pair remains after
a fresh full pre-run check of the input, source/build/tool pins, lifecycle state, process inventory,
storage budgets, and five-reading CPU gate. Any failed check stops without an unchanged retry.

#### Revision-10 product-screen internal CPU-gate stop and cleanup (2026-10-19)

The one authorized follow-up registration was used as run
`039411b01e4c49f0a7c18b475b58f462` with the documented `de1ddd49…` worker and `4815a609…` runner.
Its external five-reading CPU preflight passed at `[1.7, 2.9, 0, 2.2, 2.2]%` (maximum 2.9%). The
round-0 warmup created and restored a 450,309 B PortfolioTrial archive and created a 483,599 B
7-Zip archive, but the internal `_Total` CPU gate stopped at 16% (limit 15%) before the first
7-Zip extraction. The report has no paired measured round or candidate decision; size/time/product
pass fields are null, `summary` is empty, holdout was not evaluated, and no general superiority is
claimed. The two warmup archive sizes are not performance evidence. This execution stop closes this
exact condition; do not retry it unchanged, and do not treat it as a candidate no-go or pass.

The run report SHA-256 is `c69a0d26830f9a07bee0867bcb4735d85d9e5ed2f11eb7ac0466f97b99c8ff9d`.
Its recovery ZIP remains at
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\storage-lifecycle\runs\039411b01e4c49f0a7c18b475b58f462\recovery.zip`
(3,299,468 B, SHA-256 `34731667812c2fe8c5808071f10082b5e085aeae267e4d354ed05473a7012962`); the
recovery manifest SHA-256 is `79ac8ac216e5d1f10bf580bc69ab05f1936c6ea96fb9838b393672e6e225b2c0`.
Staged Prunlet cleanup completed with operation
`19d09c148c68416eb518a302c006a57d`, 6,595,431 B before and 0 B after; all 19 lifecycle records
are complete and no target process remains. The updated `STORAGE.md` SHA-256 immediately before
this amendment is `ac2e684b294f5701c2929b7a88872df4faab33a4c606a33ea79c8c9158f718ad`. This
amendment supersedes the preceding statement that the follow-up registration remained available;
it records the stopped execution without changing any acceptance criterion.

#### Revision-10 final-candidate frame-reuse correctness E2E preregistration (2026-10-19)

The KRS3 (`RecordAdaptiveTrial`) final-candidate path now returns its already encoded frame only
when it is strictly smaller than the earlier MDL/KCS1/KRS2 candidates. This removes one redundant
KRS3 encoding in that winning case; candidate precedence and format bytes are unchanged. The
existing correctness E2E is preregistered once to verify candidate determinism, strict-minimum
selection, archive compatibility/rejection and byte-exact extraction. It is not a performance or
memory measurement and cannot establish superiority to 7-Zip.

Pinned inputs and artifacts:

- `src/khc/mod.rs`: 35,762 B, SHA-256
  `4777b32d96973312b5fe379a11e61acf740bb92c8a52eddff039409baa7685f0`.
- 37-file Rust source manifest: SHA-256
  `1e215cc07f044f0758b30ef05dd59dc6855e42e473a6dc453484314e486a7c5a`.
- Release CLI: 2,558,976 B, SHA-256
  `871308ae01e39e44bb5ad2d9c2dc4fe059fff6f46a48b9accd50688423d309ef`.
- Release E2E binary: 1,648,128 B, SHA-256
  `4ac4408471293847ff61ce5fcbd90775ac3fceb5496cd888413170c7e934d64f`.
- E2E script: 11,596 B, SHA-256
  `099153c0493f6e8d1736f52cebdbf044c50baf64f0310c55f0bcdb0ab0177b8b`.
- Storage runner: 35,588 B, SHA-256
  `4815a60909cb1265496fbd1ce5f637a533cf91f6dc5a9bec844d32f83cbc0258`.
- Lifecycle module / disk budget script: 74,194 / 2,004 B, SHA-256
  `9686b6b258b4fc7b64e538dda7d32a0c3a355dbfa3ce12daa801395e51f942a0` /
  `506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd`.
- Pinned ptt5 recovery ZIP: 769,634 B, SHA-256
  `882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75`.
- Pre-registration `STORAGE.md`: SHA-256
  `5fe317fc325728da612e0e98815da2ba11eb48e17d0f00dae930618f20d87d64`.

`rustfmt --check --edition 2024 src/khc/mod.rs` passed. The Release Cargo command printed
`Finished`, but `run-serial-cargo.ps1` returned 1 because job PID 16908 (`VCTIP.EXE` under the
Visual Studio MSVC toolchain) survived its drain grace. The new binaries' sizes and hashes were
read and pinned; no Cargo, rustc, CLI or E2E process was active at preflight. Register exactly one
`spatial-mdl-e2e.ps1` run with the pinned recovery ZIP and binaries, `ChildTimeoutSeconds=240`, and
8 MiB / 96 entries / 300 seconds. Any failed preregistration or execution stops this condition;
do not retry it unchanged. Earlier screen records and acceptance criteria remain unchanged.

#### Completed revision-10 final-candidate frame-reuse correctness E2E (2026-10-19)

Run `734aac55e9064d22abe8de2d5b2553e8` passed the preregistered revision-10 API/CLI correctness
E2E with outer exit 0: eight known frame families, nine malformed archives rejected, revisions
1–9 readable, memory-reservation guard exercised, exact ptt5 SHA-256 round trip, and all
no-replace/invalid-archive assertions passed. This is not speed, memory or 7-Zip superiority
evidence. Its 89-entry / 5,453,097 B work tree was removed through direct Prunlet operation
`a3443ea3192944e1b398babe08af47a9`; lifecycle completion records 0 B remaining. Recovery ZIP
SHA-256 is `8719fd8458ab3f2db3043aed34f4359b2f16cfc44bc59182dac76b6556f0ed41`; report SHA-256 is
`e5e83627350791b612cfd30920c90dba72a22eef1980dc2f090fca3f32d3cdf9`. Details and fixed pins are
in the additive E2E entries in `STORAGE.md`.

#### Revision-10 MDL-last candidate-order E2E preregistration (2026-10-19)

After the prior correctness E2E, `PortfolioTrial` was changed to encode KCS1, KRS2 and KRS3 before
MDL, while explicit ranks preserve the prior MDL-first minimum-size/tie result. This permits reuse
of the MDL frame when it wins without retaining earlier output across a later bounded codec
workspace. The prior E2E passed against a different candidate order and source hash, so it does not
verify this revision. The latest additive preregistration is recorded in `STORAGE.md` (SHA-256
`d22c305e096b375e691591a167f18edd5f395abe704d86fe161d9262a0c6242f`). Its fixed input, Release
binary, runner and source-manifest pins must match immediately before one run of the existing
revision-10 correctness E2E (8 MiB / 96 entries / 300 seconds; child timeout 240 seconds). A
read-only lifecycle budget check for the 24 MiB reservation passed before preregistration. This
run is correctness/compatibility evidence only; no inference about speed, memory or 7-Zip
superiority follows from it. If this exact run fails, do not retry unchanged. All prior benchmark
conditions and historical hashes remain untouched.

#### Completed revision-10 MDL-last candidate-order correctness E2E (2026-10-19)

The preregistered run `0b371cf18d2f4165840a9995ef00f9ed` passed with outer exit 0 against the
current MDL-last source and pinned Release artifacts. API checks covered eight frame families,
nine malformed archives, legacy revisions 1–9 and the memory-reservation guard. CLI create/list/
test/extract restored two files totaling 513,225 B with matching hashes; all 20 expected nonzero
no-replace/invalid-archive checks passed. The 89-entry / 5,453,097 B work tree was removed by
Prunlet operation `c69e6740df95451b938df9734f6d3ea8`; the lifecycle record is complete at 0 B, and
the recovery archive/manifest/report remain hash-verified. This is correctness evidence only—not
a performance, memory or 7-Zip superiority result. The current `STORAGE.md`, including the
preregistration and full artifact/cleanup details, is SHA-256
`a12c2c473b9f49ed0a8c0adf5a631d55cf46ad2a69436b98296d25e2babe20dc`. No prior acceptance
criteria or historical record was changed.

#### Revision-10 MDL-last Canterbury11 screen preregistration update (2026-10-19)

The MDL-last revision-10 correctness E2E passed, but it provides no performance evidence. An
additive preregistration now records the current source manifest, Release CLI, 7-Zip, input,
screen worker and runner pins for one development-only Canterbury11 comparison. It does not
replace the earlier fixed acceptance criteria or turn Canterbury11 into a holdout. The latest
`STORAGE.md`, including this current pre-run pin set and unchanged screen protocol, is SHA-256
`a7134432061c2f4c933d60ef2965e9175c1f31bc7fc2c7e97e74e99554fa72f6`. No new screen run has yet
been registered; proceed only after the documented final pin, lifecycle, process, budget and CPU
preflight. If a precondition or runtime gate fails, stop without an unchanged retry.

#### Revision-10 MDL-last Canterbury11 screen stop and cleanup (2026-10-20)

The one registered run stopped during its warmup at the fixed internal CPU gate (31% before
7-Zip extraction); no measured paired rounds, summary, or candidate decision were produced. Its
warmup outputs are not performance evidence, so neither a pass nor a candidate no-go is claimed.
The work tree was removed through the required Prunlet lifecycle and the recovery archive,
manifest and report remain hash-verified. The current `STORAGE.md`, with the preregistered pins,
stop evidence and cleanup record, is SHA-256
`bca4ad38438f9cd49bcebe832346df6d96cfa4b4b558a9a8e7595dd5e1af1b71`. Do not repeat this exact
screen condition unchanged; Canterbury11 also remains a development corpus, not the required
held-out evaluation.

#### KRS2/KRS3 shared-preparation revision-10 correctness E2E preregistration (2026-10-20)

The current implementation shares the common baseline and voter-position schedule used by KRS2
and KRS3, while preserving their separate coder behavior, exact frame-length comparison, ranking,
and fallback paths. This registered run is correctness/compatibility evidence only; it cannot
establish speed, memory improvement, compression superiority, or holdout performance. Its 37-file
Rust-source manifest is `76521abb786b256dab218f1e555a216d4a82b53eeda28f06ee800e765543e172`; the
42-file build-input manifest including `khc_spatial_mdl_e2e.rs` is
`4090db4055f4849711ed215f088ba25d944227fce43c5b6bde03d3e9fea75981`. The source files, scripts,
toolchain, lockfiles, input recovery ZIP and pre-build storage check are pinned in the additive
entry in `STORAGE.md`.

Build only the Release CLI and E2E example through the pinned `run-serial-cargo.ps1`, with the
fixed `x86_64-pc-windows-msvc` target, `--locked --offline`, 256 MiB transient reservation, and
all target/temp outputs under `<作業フォルダー>\UnLhaRe\goal-restore-20261019`. Before one registration,
verify the new CLI/example hashes, all current source/build/script/input pins, no pending lifecycle
run or target process, and the storage budget. Then run `spatial-mdl-e2e.ps1` with the pinned
recovery ZIP, D-drive binaries, `ChildTimeoutSeconds=240`, and its fixed 8 MiB / 96-entry / 300
second outer cap. If build, registration or E2E fails, do not retry this exact condition unchanged.
At preregistration the existing D-drive binaries were stale MDL-last outputs and are explicitly
not valid inputs for the changed KRS2/KRS3 source. The latest `STORAGE.md` preregistration is
SHA-256 `3231791303b1f49a627dc38d9171f852c2cc3344a5a03cd59fb04ff35f9a8c2c`.

#### KRS2/KRS3 shared-preparation E2E materialized binaries and pre-registration update (2026-10-20)

The preregistered 42-file input manifest remained
`4090db4055f4849711ed215f088ba25d944227fce43c5b6bde03d3e9fea75981`. The first Release compile
finished, but the serial wrapper returned 1 while `VCTIP.EXE` PID 1384 was still in its drain
check. That process was absent on the subsequent read-only check. One bounded follow-up through
the same wrapper completed in 0.10 seconds with exit 0; no further build retry is authorized for
this condition. The resulting binaries are pinned as follows:

| Release artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `unlhare-cli.exe` (`unlhare 1.0.4`) | 2,560,000 | `1742b3e28e70b1a2c105ce3c0268332c712a97b0f94a3fda717809859cc81064` |
| `khc_spatial_mdl_e2e.exe` | 1,650,176 | `b9aacd015e7b288339c4b74f7085b2ac6b2feadf361662551c7a526fc490b0c3` |

These are the only valid Release inputs for the single 8 MiB / 96-entry / 300-second E2E with
the pinned `ptt5` recovery ZIP and 240-second child timeout. The post-build budget check passed;
its exact capacity and process results are recorded in `STORAGE.md`. The current
`STORAGE.md` preregistration, now including the materialized binaries, is SHA-256
`bd3b490c4e17aa829c2d4906909dfdd4b79e12b5e3ff0b72de3b795291bf0683`.

#### Completed KRS2/KRS3 shared-preparation revision-10 correctness E2E (2026-10-20)

Registered run `15296b966ea04dfa80d63ce4a8a62b54` completed the fixed revision-10 correctness
E2E. All 34 child-command outcomes matched the harness expectations: 14 successful create/list/
test/extract/API/legacy-read checks and 20 intended no-replace or malformed-archive rejections.
API validation reported 8 revision-10 frames, all allowed frame-family groupings, 9 malformed
archives rejected, revisions 1–9 readable, and the memory-reservation guard exercised. CLI
round-trip restored both `ptt5` and the short fixture byte-for-byte. This is correctness and
compatibility evidence only; it makes no performance, memory, 7-Zip or holdout claim.

The CLI archive is 40,051 B (SHA-256
`83b474b04fc269f5f77ed159b0e86df5a2be76bc2146ccaaa5aca613ac3837f6`); the retained E2E report is
7,162 B (SHA-256 `7c93e16bef19c67f807f20a355386225dd37678757ce7dc25d7b8474a084d108`). Recovery
artifacts are `recovery.zip` 746,808 B (SHA-256
`a9755812accd161382f27510bae936836f2c96fd714357f4e736d16d653e2f2a`) and `recovery.json`
21,644 B (SHA-256 `0bcc7fe0b7bdc8b8c7bf2d2437c141baa64d40afacbfdf45d2ca1c93dacc0bbb`). The exact
work root was deleted and its Prunlet backup purged after verified 89-item delete and purge
previews; the lifecycle run is complete with zero bytes remaining. All 23 runs are complete and
no target process remains. The surrounding PowerShell command's added `$LASTEXITCODE` guard
reported 1 after invoking a PowerShell script with that variable unset; the saved report and
lifecycle record show the E2E itself completed, and no rerun occurred. Detailed lifecycle and
post-cleanup budget evidence is in the additive `STORAGE.md` result section. Its current
SHA-256, including the E2E outcome and cleanup, is
`74dde64795bc70914b347fa30d4919846def2a35ee2e929241b84b59c8552ea4`.

#### Shared-preparation Canterbury11 screen preregistration stopped before registration (2026-10-20)

The proposed current-source screen pins matched, and the 290 MiB storage reservation passed with
all 23 lifecycle runs complete and no target process. Five fresh external one-second `_Total`
CPU readings at `2026-10-19T15:32:38.3613811Z` were `[13.4, 5.0, 19.6, 9.9, 4.4]%`; the 19.6%
maximum exceeded the fixed 15% gate. No screen was registered or executed, no new lifecycle record
was created, and there is no 7-Zip result or candidate decision. Preserve the prior MDL-last
screen's independent CPU-gate stop; this source revision is a separate attempted preregistration,
not a pass/no-go and not permission to retry unchanged or lower the threshold. The temporary
current-source runner pins were restored because registration did not proceed. Detailed capacity,
pin and cleanup context is in the additive `STORAGE.md` stop record. Its current SHA-256, including
this pre-registration stop, is `35a5e1e93fc9c88cb1b49a89a063c341bcadf2099eea8272ed93dee62566da5b`.

### Revision-10 shared field/model preparation correctness E2E preregistration (2026-10-20)

A distinct development candidate now reuses the initial KRS field histogram, normalized models,
and serialized metadata between the KRS2/KRS3 portfolio trials while cloning model state for each
coder. The 37-file source manifest is `071c49fe1d3159082cade2a32d95a0b4e99603999bf28e3d0f500bd1fca0c517`; the
42-file build-input manifest is `02350ce5494a6857762a4c649ba99f4f31391854e41dad04ac17d383c52da161`.
This one registered 8 MiB / 96-entry / 300-second revision-10 E2E is for correctness and
compatibility only, not a performance result or byte-identity claim against the prior executable.
The Release CLI (`unlhare 1.0.4`) is 2,572,288 B, SHA-256
`ba314a942cf5ca17ca4106464b0e753d950ff45a2ff1b493fb83cc54f70d5076`; the registered E2E
executable is 1,661,952 B, SHA-256
`bc0396f96797110226bdd07e897bab50cbd2532f90f00a733d09cbb3401247f4`. The current
`STORAGE.md` SHA-256, including these artifacts and the pre-E2E storage check, is
`a2fd994ec12917d7f0de04325ac6e6fa67245cc6ae52fdb8cf5c2067c2f42694`. At preregistration the one
run was pending; its outcome is recorded below. Do not repeat a failed exact condition unchanged.

#### Completed KRS2/KRS3 shared-preparation correctness E2E and cleanup (2026-10-20)

Registered run `abb76bfa2b254424be836b8c259561f6` passed all 34 expected checks, including revision-10
frame/decoder validation, malformed-input rejection, revisions 1–9 reading, memory-reservation
guard, and exact CLI restoration. The result is correctness/compatibility evidence only; no speed,
memory, 7-Zip, holdout, or byte-identity claim follows. The final receipt-backed Prunlet cleanup
completed under operation `7897d2c69b034403bf5d1ac7e412d669`, leaving 24/24 lifecycle runs complete
and no task work root. Full result, recovery and cleanup hashes are in `STORAGE.md`.

At that point, `STORAGE.md` including the completed correctness E2E and cleanup had SHA-256
`14a01753caedde3d8e7471e7603dd3185bd64d88e8a48ffa9448e0c0c8f75290`. A distinct source change is
built below, but its Canterbury11 performance screen did not reach registration; neither the
correctness-only E2E nor a pre-registration gate reading is a performance result or permission to
relax the fixed gate.

#### Revision-10 PortfolioTrial scheduled-length screen stopped before registration (2026-10-20)

The new `scheduled_lengths` path reuses the encoded inner-frame length and omits only the
discarded outer-frame copy and CRC; actual archive encoding remains unchanged. Release CLI SHA-256
is `3e2dda254e25c6260f6762155b82147ddea3c7d2a1fd843050bcbe2bf567edaa`; source manifest
`a76be523eda227c4518e06e92fcb5ee02da2d68bb08aec4e559d19e908f3fa31`. The first runner
invocation stopped before run creation because the provisional source-manifest hash used
culture-sensitive rather than ordinal sorting; corrected pins now match the exact source and
script hashes. A fresh CPU gate after that correction read `[12, 58]%`; the second sample exceeded
the fixed 15% limit, so no Canterbury11 run was registered and no 7-Zip comparison or candidate
decision exists. The earlier passing five-sample set preceded the pin failure and did not authorize
a run. Preserve the CPU stop: do not retry this unchanged source/input condition or change the
threshold. The 290 MiB budget, all 24 lifecycle records, no-process check, full pin details, and
gate timestamps are in `STORAGE.md`. This remains neither a holdout evaluation nor GOAL completion.
The current `STORAGE.md` SHA-256, including the corrected pins and both pre-registration outcomes,
is `1f4c499f2bdcf01befc28430168c7882c5c4b00b98b9b65ac640c0fa31a606e8`.

### Revision-10 scheduled-length candidate correctness E2E preregistration (2026-10-20)

The source change skips constructing the scheduled outer frame when `PortfolioTrial` needs only a
candidate length. A fresh locked/offline Release build is pinned by source manifest
`a76be523eda227c4518e06e92fcb5ee02da2d68bb08aec4e559d19e908f3fa31`, CLI SHA-256
`0b81fc135a010d57bd8bf42ef46868a60b55ae1c7bdc5288e0886b7207e01719`, and E2E example SHA-256
`d3496cbd81b384d833d1671350dd0c3cd101eb1f11dfaecdd4a897d6c003c2ee`. Register one bounded
revision-10 correctness E2E against the fixed ptt5 fixture and compare its CLI archive hash to the
previous shared-preparation result (`1ac4122f904fdc95420a63317261705e16d6bfd3b4299880208890c26cc602aa`).
This checks exact output identity only for that fixture; it is not a performance or holdout result.
The pre-registration storage evidence and full pins are in `STORAGE.md`, whose SHA-256 is
`7ce1f9f18943378d1fa6fc4219cbcfea178563c71a5e1b2fe6b8feaf9a1fe891`.

#### Completed scheduled-length candidate correctness E2E and cleanup (2026-10-20)

Run `f66bb7133a5e46888d54003e3b594ff4` passed all 34 expected checks, including revision-10 archive
creation, malformed-input rejection, revisions 1–9 reading, the memory reservation guard, and exact
CLI restoration of both files. The previous and current CLI archives were both 40,051 B but their
full SHA-256 values differed because the two recorded modification times and dependent manifest/
header checksums differed. Exactly 12 bytes differ; the 39,962-byte data suffix is identical
(`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`). This is not full-archive
byte identity and provides no speed, memory, 7-Zip, or holdout evidence. Prunlet cleanup operation
`db1d2c0f6c244d95a6a50ca46eac9c77` completed; all 25 lifecycle runs are complete and no work
directory remains. Full receipts and hashes are in `STORAGE.md`, whose SHA-256 is
`63f0a94bfcfae6c73c0076a0e9cb6f8c22cd3477c9872f775867bcc062ee3812`.

### Revision-10 schedule-replay candidate correctness E2E preregistration (2026-10-20)

The new schedule-replay candidate is distinct from the stopped scheduled-length source and is
being checked for revision-10 correctness, prior-revision readability, malformed-input rejection,
memory-gate behavior, and CLI byte round-trip. Its fixed source, build, input, runner, and output
data-suffix pins plus the exact single-run command are recorded in `STORAGE.md` (SHA-256
`1be0c368c868d4840d26a43a1cd3f0916eca6d4e2b5ed5646450f55d85784020`). The result is not a
performance or holdout evaluation. Do not register a second run if the preregistered condition
fails; preserve its recovery evidence.

#### Accounting-harness interruption and one repaired-run authorization (2026-10-20)

The registered run `3e44744ddf604d959fc05b042f4694f6` stopped during live directory accounting
while an accepted-output extraction removed its temporary staging directory. No E2E report was
produced, so this is neither a candidate pass nor a candidate failure. The partial recovery was
verified and the work tree was cleaned through the recorded Prunlet lifecycle. A bounded retry was
added to `run-storage-experiment.ps1`: at most three retries with 10 ms delay, only for an exception
chain containing `DirectoryNotFoundException`; all capacity, entry, path, reparse, and other I/O
failures remain immediate. The repaired runner is 36,311 B, SHA-256
`4c091b2f56f952450848d048ff9aa54e523fe953a484d10be7b386683f8c5c32`.

This permits exactly one follow-up registration of the same candidate/input because the prior
attempt ended in the accounting harness before producing correctness evidence and the runner hash
has changed. Candidate source manifests, E2E script, fixed ZIP, and Release binaries are rechecked
at the pins in `STORAGE.md`; the 8 MiB / 96-entry / 300-second outer limits and 240-second child
timeout remain unchanged. The refreshed read-only preflight passed the 25 MiB reserve, pending-run,
process, and reparse checks. The one follow-up must use the existing exact invocation in `STORAGE.md`;
if it fails, preserve evidence and do not repeat this source/input. This remains correctness-only,
not performance, 7-Zip, holdout, or GOAL-completion evidence.

The updated pre-registration record in `STORAGE.md` is pinned by SHA-256
`6fada062a160c4dc63e7ccf1c00d878b308a8dcaa6d9bcd191b660bae79eeb0d`.

#### Repaired schedule-replay correctness E2E completed (2026-10-20)

The single authorized follow-up `22244102afa34627b750d52fb6cf0a98` passed all 34 expected checks
(14 exit 0, 20 intentional exit 1), including revision-10 creation, malformed-input rejection,
revision 1–9 readability, memory reservation, and exact CLI restoration of both files. The
preregistered 39,962-byte encoded-data suffix matched exactly (`5f66e0e3552647ce66ce6020dca6c1abae889e9bfcd3ef5b94669d5fb4364977`). Full archive hashes differed by
12 timestamp-dependent manifest/header bytes, so this is not full-archive identity and provides no
performance or holdout result. Prunlet cleanup operation `78f9c305714d431495406755d0f89668` finalized
the 5,453,097-byte work tree to `AfterBytes=0`; no pending lifecycle record or target process
remains. Recovery and receipt details are retained in `STORAGE.md`, whose SHA-256 is
`3bcf542eb59034822d37411269c577ba808ed7af9b8b40d3df9d9c584f8443aa`.

### Schedule-replay revision-10 Canterbury11 / 7-Zip product-screen preregistration (2026-10-20)

The next development screen evaluates the distinct schedule-replay source (`0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`) and Release CLI (`3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`) against the fixed 11-file Canterbury corpus (`bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438`) and 7-Zip 26.04 (`95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`). This differs from the prior `scheduled_lengths` source whose pre-registration CPU gate stopped at 58%; that prior stop and its threshold remain unchanged.

The screen is fixed to one warmup plus nine alternating pairs, solid 7-Zip LZMA2 level 9 / 64 MiB dictionary / one thread, common 60-second / 160 MiB child caps, and 128 MiB / 512-entry / 1,800-second outer caps. A pass requires candidate archive size at most 95% of 7-Zip and KHC create/extract median wall time no slower than 7-Zip, with deterministic output and exact restoration. Each timed command has its own five one-second `_Total` CPU gate at 15% maximum. The read-only 290 MiB reservation and no-pending/process/reparse preflight passed. The one fresh pre-registration CPU gate passed with readings `[3, 6, 2, 0, 0]%` from `2026-10-19T17:21:23.9951291Z` to `2026-10-19T17:21:29.1408634Z`, authorizing exactly one registration; every per-command gate remains in force. Full pins, command, and the exact budget snapshot are in `STORAGE.md`, whose SHA-256 is `e86c9fac5ff872329ebf2315d8440ba22f8677b0b748fd84a2393c9f9cf62883`. This is a development screen, not the independent holdout evaluation or GOAL completion.

#### Schedule-replay Canterbury11 product screen stopped at its timed-command CPU gate (2026-10-20)

The single registered run `6286e3c1acdf4f50a28b25b1dac330b0` stopped before its first timed KHC command: its fresh `_Total` CPU sample was 32%, above the fixed 15% ceiling. `Process.Start()` was not reached; the report records zero paired rounds and `candidate_decision=null`. No timed KHC or 7-Zip result exists, so this is neither a candidate pass nor a format-level no-go. Do not retry this schedule-replay/Canterbury11 source-input condition or relax the threshold. Prunlet cleanup `aea618299bc84d9d805758892f71e507` completed with `AfterBytes=0`, preserving the report, recovery archive, manifest, and receipts. The full failure and cleanup record is in `STORAGE.md`, SHA-256 at the time of recording `2fe8685dabef6d594e9953b1dfc9b7a76a2125f25e9daad02bf4ae085824708e`.

### e-Gov XML/CSV revision-10 / 7-Zip fixed product screen preregistration (2026-10-20)

The next distinct development screen uses the fixed e-Gov law XML/CSV set (100 files, 9,527,638 B),
not Canterbury11 and not an independent holdout. Campaign `a42eb7bfbedf4fa780c4d210385b24c6` is fixed
to 2026-10-19 19:00–19:30 UTC. The immutable start manifest SHA-256 is
`1ec16512fc8b342407c391c80693598e506136f7b76dfff5e67d24df96e95afe`; its complete pins, paths,
resource snapshot procedure, invocation and aggregation procedure are in `STORAGE.md`.

The registered design is 20 serial one-sample runs (rounds 0–9, both `portfolio-trial` revision 10
and 7-Zip 26.04 per round), alternating the first strategy by round parity. Round 0 is warmup;
rounds 1–9 are measured. Each run is limited to 32 MiB / 512 entries / 300 seconds, each child to
160 MiB / 60 seconds, and the full campaign to 1,800 seconds. Before the first registration, repeat
the read-only reserve, no-pending-run, process, path/reparse checks and a fresh five-sample external
CPU gate at or below 15%; before every timed command the same five-sample gate applies. No failed
gate, sample, cleanup, or deadline may be retried. Each completed run must pass the normal full
Prunlet lifecycle before the next registration. Aggregate only after the immutable 19:30 UTC
deadline so the aggregator can verify the complete fixed registration window.

The 7-Zip settings are solid LZMA2 level 9, 64 MiB dictionary, one create thread and four extraction
threads. Acceptance requires deterministic archives, format validation, exact restoration, candidate
size at most 95% of 7-Zip, and no-slower candidate create/extract medians. Source, executable, input,
worker, lifecycle, disk-budget, runner, aggregator and campaign-start hashes are pinned in
`STORAGE.md`. The earlier unregistered 128 MiB all-round design was not registered; it is replaced
by this recovery-compatible 32 MiB single-sample protocol. This screen cannot establish independent
holdout superiority or complete the GOAL.

#### e-Gov fixed screen stopped before registration at the CPU gate (2026-10-20)

The required fresh external `_Total` CPU gate failed on sample 4: readings were 10%, 11%, 10%, then
31% against the fixed 15% ceiling. The gate stopped immediately; no fifth reading was taken. There
were zero lifecycle registrations in the campaign window, no candidate or 7-Zip execution, and no
performance result. No cleanup was needed. This is not a codec no-go, and this exact e-Gov source/input
condition must not be retried or have its threshold relaxed. The preflight and failed-gate record is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\egov-screen-20261020\pre-registration-stop.json`
(SHA-256 `75a1cc84649bcfe5b9fb48039f0ed7f5fe9b693be4c9c09d2f4f9c28e1356f5b`); details and budget
snapshot are in `STORAGE.md`.

#### Aozora development profile campaign stopped before registration at CPU gate (2026-10-20)

The fixed development package combines only the official Aozora No. 424 『檸檬』 and No. 752
『坊っちゃん』 source files ([No. 424 card](https://www.aozora.gr.jp/cards/000074/card424.html),
[No. 752 card](https://www.aozora.gr.jp/cards/000148/card752.html)). They remain one Aozora
distribution/e-digitization family, for development and tuning only; the content-rights screening
and attribution caveats above still apply. The not-yet-acquired No. 2078 『舞姫』 and No. 42206
『初孫』 remain separate from this development input and are not yet a frozen independent holdout.

The package and member hashes are fixed in `STORAGE.md`. The four PowerShell integration files
now accept `AozoraDevelopment20261020`; task binding is checked against the executing task, and
the worker and Aozora aggregator agree on the unique effective 7-Zip dictionary range (greater
than zero and at most 64 MiB). The requested 7-Zip option remains `-m0=lzma2:d=64m`; its effective
dictionary has not been observed because no sample has run. Static PowerShell parsing and
independent review of the task-binding and dictionary fixes passed.

An immutable marker for campaign `f3d12bcb02bb4e3c97f6417062d6d5a7` was created and validated:
SHA-256 `1c2e4fb5f96a420a769ac255751deec64008e211968194d7557f1285a1adbaff`, fixed to
2026-10-19 19:50–20:20 UTC. The pre-registration budget, process, path/reparse, source, CLI, 7-Zip,
and input checks passed. The start gate failed before registration: external `_Total` readings were
29%, 18%, 19%, 19%, and 19% against the 15% ceiling. The collector continued for four additional
samples after the first reading failed; this procedure deviation is recorded. No run directory,
registration, profile-specific build, timed compression/extraction, cleanup, or aggregate exists.
This exact Aozora source/input condition and fixed window are closed; do not retry, rebase, or
relax the threshold. The retained stop record is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\aozora-dev-20261020\pre-registration-stop.json`
(SHA-256 `4409ee3a6d5656293bcba320bdb341d077cb4230343ebab32da6ea3bda6c0821`). Complete pins,
preflight snapshot, and protocol are in `STORAGE.md` (SHA-256
`04c24d5fd947752797f2d5df391bce90d26a86973d082ceafea07430efd542e0`). The e-Gov screen's earlier
pre-registration CPU stop remains closed; this distinct Aozora profile does not revive that
condition. There is no performance result, and neither this development profile nor its
integration establishes independent-holdout superiority or completes the GOAL.

### 独立holdout条件の事前manifest v1.0：気象庁の日別観測CSV — 2026-10-20（条件固定後の単回取得）

Profile ID `JmaTokyoDaily2010_2025Holdout20261020` を未見holdoutとして事前固定する。入力は気象庁「過去の気象データ・ダウンロード」の単一CSV：地点「東京」（地点番号 `47662`）、日別値、2010-01-01〜2025-12-31、項目「気温（日平均気温）」と「降水量（降水量の日合計）」。出力オプションは注意情報と観測環境変化による不均質情報を含め、値は数値形式、日付は日付リテラル、曜日と都道府県名は追加しない。ダウンロード時刻行と全表題行を含む取得CSVを加工せず入力にする。公式ヘルプは地点・項目・期間を選んだ日別CSV出力とこの項目の利用例を示し、観測地点ページで東京の地点番号を示す。これはAozora文学・e-Gov法令や郵便番号と異なる気象時系列familyで、語彙・データ形状の双方が独立する。

リクエストの再現仕様は、取得前に確認した気象庁公式フロントエンド `/risk/obsdl/web/dist/top.bundle.js` のシリアライザーに合わせる。POST先は `/risk/obsdl/show/table`、`Content-Type` は `application/x-www-form-urlencoded`。フォーム値は `stationNumList=["s47662"]`、`aggrgPeriod=1`、`elementNumList=[["201",""],["101",""]]`、`interAnnualType=1`、`ymdList=["2010","2025","1","12","1","31"]`、`option={"list":["obs"],"nyear":0}`、`downloadFlag=true`、`rmkFlag=1`、`disconnectFlag=1`、`csvFlag=1`、`ymdLiteral=1`、`youbiFlag=0`、`fukenFlag=0`、`kijiFlag=0`、`jikantaiFlag=0`、`jikantaiList=[]`。地点ID `s47662` は公式地点metadataのstation markerから、項目ID `201`（平均気温）と `101`（日別降水量合計）は日別値選択UIの値から確認した。このmetadata確認自体では気象値を取得していない。観測値を返す単回取得と受信metadataは次段落に記録する。

気象庁ホームページの利用条件では、権利表示がないコンテンツは公共データ利用規約（第1.0版）に従い、出典表示と、編集・加工時の明記を求めている。過去データのページも掲載値を遡って修正する可能性を明示する。現行候補・7-Zip・screen/runner/lifecycleのhashはAozora開発campaign markerで固定済みと照合した後、2026-10-19 20:10:43.8894586Z〜20:10:45.2373298Z（JST 2026-10-20 05:10:43.8894586〜05:10:45.2373298）に公式出力を一度だけ取得した。HTTP 200、Content-Type `application/octet-stream`、Content-Disposition `attachment; filename="data.csv"`、raw CSV 169,060 bytes、SHA-256 `a17d1a8cca49f958ce417624a77416e04113da412bf42f68c559c96745d37885`。8 MiB admissionをサイズだけで通過した。出典・条件・取得時刻・長さ・hashをこのmanifestに記録し、候補実装のチューニングには使用しない。

この事前manifestの固定範囲はsource family・地点・期間・項目・CSVオプション・無加工入力の役割までである。raw CSVは `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\jma-holdout-20261020\jma-tokyo-daily-2010-2025.csv` に保全した。評価用wrapper `input.zip` は同じdirectoryの `input.zip`、169,228 bytes、SHA-256 `bf89c170af85418f9911be0b2a547fae2029755ef06091b4209ca446841805f8`、無圧縮で単一member `input/jma-tokyo-daily-2010-2025.csv` を含む。member bytes/hashがraw CSVと一致し、basename順の `name<TAB>bytes<TAB>sha256` file-set SHA-256は `36d982b198c5557acb383b3fbe4df2aa74d08336705005916e25138973000dab`。このfixed snapshotのみを使い、上限超過を理由に期間・項目を縮めて再定義しない。利用時は出典とPDL 1.0の要求を保持し、仮にmemberを加工した場合は本manifestを無効とする。出典表示は「気象庁『過去の気象データ・ダウンロード』（地点：東京、期間：2010-01-01〜2025-12-31、日別値、2026-10-20以降取得）」とする。

観測データ・CSV本文は受信stream上でサイズ上限を適用しつつ保存・SHA-256計算をしただけで、閲覧・parse・変換・圧縮測定には使用していない。ZIP wrapper作成時もraw memberを無圧縮で転送し、memberのSHA-256で完全一致を確認した。出典・CSVオプション・形式metadataは取得前に公式資料とフロントエンドから確認済み。実行前に別のimmutable JMA campaign markerと現行storage admissionを固定し、5回CPU gateを全通過させる。過去に閉じたe-Gov/Aozora条件は再実行しない。

比較対象として再確認した日本郵便のUTF-8郵便番号データは、公式説明が全国約12万件の15項目CSVをZIP配布し、郵便番号データに限る著作権不主張を記載している。ただし現在の全件ZIPは圧縮済みの配布wrapperで、CSV member名と取得物hashが未確認である。全件ZIP自体を未圧縮の代表コーパスとして扱わない。月次差分は小さく全件コーパスの代替にしないため、今回のholdout候補には選ばない。

2026-10-13〜20 JSTのPlumivox `search_tweets(scope=all)` は、日本郵便検索 `日本郵便 郵便番号データ UTF-8 CSV 利用 著作権` と気象庁検索 `気象庁 過去の気象データ CSV 利用条件 再利用` が各0投稿・各1 API要求、いずれも `completeSearch=false`。X結果は非網羅的であり、権利や候補の適格性を判断する証拠には用いない。

一次情報：気象庁[利用規約](https://www.jma.go.jp/jma/kishou/info/coment.html)、[過去の気象データ・ダウンロード](https://ds.data.jma.go.jp/risk/obsdl/)、[CSV形式と出力オプション](https://ds.data.jma.go.jp/risk/obsdl/top/help3.html)、[地点・項目・期間選択例](https://ds.data.jma.go.jp/risk/obsdl/top/help2.html)、[東京の地点番号47662](https://ds.data.jma.go.jp/obd/stats/etrn/index.php?block_no=47662&day=&month=&prec_no=44&view=p3s&year=)。日本郵便は[配布ページ](https://www.post.japanpost.jp/service/search/zipcode/download/)と[UTF-8 CSV仕様・権利表示](https://www.post.japanpost.jp/service/search/zipcode/download/utf-readme.html)を照合した。payloadは受信stream上で一度だけ取得・hash固定済みだが、内容の閲覧・parse・変換・圧縮測定には未使用。JMA専用profile/marker検証は4 scriptへ統合済みで、marker作成・run登録・timed command・集計は未実施。この入力は独立した気象時系列holdoutであり、169,060 Bという小ささから一般的な代表性能を示すものとは扱わない。

JMA専用markerでは7-Zipの要求上限を `maximum_effective_dictionary_bytes=64MiB` と固定し、実際の単一dictionary値はworkerと集計器で `0 < d <=64MiB` を検証する。作成argvの `-m0=lzma2:d=64m` は変更しない。単一member時は、実際の `Solid` 表示が `+` か `-` かを記録し、`-ms=on` の固定argv・1 block・LZMA2辞書上限を検証する。複数memberでは従来どおり `Solid=+` を要求する。Aozoraの小入力条件は維持し、e-Govの64MiB実効辞書完全一致は変更しない。全4 scriptの現在pinとcampaign実行条件は `STORAGE.md` に記録する（現行SHA-256 `1e70b79f675ef174c420cf88dc76442a2d1aa99f5519acedf839bf21b491f8fe`）。

#### JMA独立holdoutは登録前CPUゲートで停止（2026-10-20）

完全な事前確認は通過したが、新規の外部CPUゲートは1件目で37.49%となり、固定上限15%を超えたため直ちに停止した。5件中残り4件は取得せず、campaign marker・run登録・候補/7-Zip実行・時間/サイズ測定・集計は一切行っていない。これはコーデックの評価結果ではなく、今回のJMA入力・候補・閾値条件は再試行しない。記録は `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\jma-holdout-20261020\pre-registration-stop.json`（2,910 B、SHA-256 `00848fe5204696ad6eff1db160a6a5fbfbe6958977f8b180878296ac68e79e34`）。当該データの内容は未閲覧・未parse・未圧縮のまま保全する。

#### 次の独立holdout候補の調査（2026-10-20）

| 候補 | 一次情報で確認した内容 | 採否上の限界 |
|---|---|---|
| 東京都「住民基本台帳による東京都の世帯と人口」令和3年1月・第5表 | 町丁別の世帯数・男女別人口のCSVが公式ページに288.1KBと表示され、公式APIカタログはCC BYと実CSV URLを掲載する（[統計表](https://www.toukei.metro.tokyo.lg.jp/juukiy/2021/jy21q10501.htm)、[APIカタログ](https://spec.api.metro.tokyo.lg.jp/spec/t000003d2000000818-f9ced66f9dcb572a175c81b9833cfd48-0?lang=ja)）。JMA気象・青空文庫・e-Govと異なる行政統計の構造化CSV候補。公式CSV GETはHTTP 200、295,022 B。raw SHA-256 `24f90c92c90500bef3e7e2170691a7bcc4fa0f22ecfe8f20cb9e1586e49af1a8`。無圧縮1-member `input.zip` は295,190 B、SHA-256 `a4c2fadb51d768dd91032f4dc629f8ccab032fb6ddd8bdf640d722b438600f1f`、file-set manifest `8609ace479ba6f0c8fb86985db4a40e486bdd9b35901baa6acb185018a6589cb`。取得・hash・無変換wrapper作成のみで、CSV本文は未表示・未parse。 | 288.1KBは独立したデータ種別のscreenには使えてもthroughput代表性は弱い。カタログにライセンスの版番号がなく、全利用履歴と入力規模見積りは未確認。screen profile/campaign markerは未作成。 |
| livedoorニュースコーパス（通常テキスト） | 提供元は2012年収集の9カテゴリ記事を配布し、記事ファイルにCC BY-ND、カテゴリ別の`LICENSE.txt`にcredit条件があると説明する（[提供元配布・条件](https://www.rondhuit.com/download.html#ldcc)、[CC BY-ND 2.1 JP](https://creativecommons.org/licenses/by-nd/2.1/jp/)）。通常テキストの固定URLは `https://www.rondhuit.com/download/ldcc-20140209.tar.gz`。HEADは200、Last-Modifiedは`2014-02-09 03:03:33 GMT`だがContent-Lengthは返らず、ETag `"871e96-4f1f077e84b40"`をbytes/hashと解釈できない。自然文の別family候補。 | member一覧・件数・raw bytes・展開総量・全カテゴリのLICENSE/creditは未確認で、payloadは未取得。KHC内1,857ファイルの識別子検索では過去の圧縮・調整・測定記録を検出しなかったが、全履歴の非使用を証明する監査ではない。CC BY-NDは無改変の再配布まで一律禁止する条件ではない一方、改変物の頒布を制限する。現在のscreen workerは32 MiB/512 entriesを厳密要求するため、その枠内で偏りの少ない固定subsetを作れるか、内容を読む前にmemberとLICENSEを確認して採否を決める。 |
| デジタル庁・町字マスター | 公式CSVとPDL 1.0の利用条件が候補となる。 | 固定版・取得URL・member・raw bytes/hashを特定できず、今回は保留。 |

東京都の実CSV URLへのHTTP HEADは400、Web閲覧機能は `text/csv` 非対応だったが、後続のサイズ上限付きGETは成功した。保存先は `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\tokyo-population-holdout-20261020\`。`acquisition-record.json` に出典、ライセンス表示、bytes/hash、stored ZIP memberを記録する。CC BYの版番号は推測しない。

Plumivox X検索では `livedoor ニュースコーパス` が5投稿返却（続きあり）、東京都町丁人口・町字マスターは各0件かつ `completeSearch=false`。これは法的条件・全利用履歴・適格性の証拠ではない。livedoor payloadは未取得。関連調査でKHCの記録済みソース/文書を候補識別子検索した結果は0件だったが、未記録の過去利用を排除する監査ではない。

#### livedoor holdout input profile prepared (2026-10-20)

This section supersedes the earlier candidate row's unacquired-payload status. The official
ordinary-text distribution is the 8,855,190 B archive at
https://www.rondhuit.com/download/ldcc-20140209.tar.gz (Range response HTTP 206; Last-Modified
2014-02-09 03:03:33 GMT; ETag "871e96-4f1f077e84b40", not treated as bytes/hash). The downloaded
archive SHA-256 is b17606ed8c670013a3809100a9e6104701baab62cc019abc262111bd2acf1063. The tar contains
7,388 entries: 7,378 regular files, 10 directories, no special entries, and 25,895,663 total
regular-file bytes. This includes 7,367 articles across nine categories, nine category LICENSE
files, and two root metadata files. No unsafe member paths were found.

All nine LICENSE files were read and retained in the sample. Each states CC BY-ND 2.1 JP, requires
credit to the original author, prohibits modification of article text, and identifies the category
content provider. This is not a blanket prohibition on redistribution of unchanged material, but
the benchmark artifacts remain local and are not published. Article text itself was not displayed
or parsed.

The holdout-only sample uses a deterministic proportional stratification: assign 180 article slots
among categories by the largest-remainder method, breaking equal remainders by category ordinal;
within each category choose the smallest lowercase SHA-256 values of UTF-8 tar-member paths in
ordinal order. Include all nine category LICENSE files and both root metadata files. Preserve every
selected article byte, use ZIP stored entries, and pin all member timestamps to 1980-01-01T00:00:00Z.

| Category | Population | Selected |
|---|---:|---:|
| dokujo-tsushin | 870 | 21 |
| it-life-hack | 870 | 21 |
| kaden-channel | 864 | 21 |
| livedoor-homme | 511 | 13 |
| movie-enter | 870 | 21 |
| peachy | 842 | 21 |
| smax | 870 | 21 |
| sports-watch | 900 | 22 |
| topic-news | 770 | 19 |

The fixed input is
<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\livedoor-holdout-20261020\input.zip:
191 files, 629,588 raw bytes, 661,042 wrapper bytes, SHA-256
e9d770628225650dd1b28a355f908cdf3c54b0ae68bf397776d6757cfc4a3209. Its KHC file-set manifest
SHA-256 is 4c23d4dbdd312c4d7c9efa4199ccfff30c36a33671f53421e27a0578b57beec1. All 191 entries,
stored lengths, paths, and wrapper hash were validated. No article bytes were changed. Local search
of 1,857 KHC files found no compression/tuning/measurement record for this corpus; this is not an
all-history audit. At acquisition stage, profile wiring, immutable campaign marker, registration,
codec invocation, and benchmark remained unstarted; profile wiring has since completed as recorded
below. The archive and input wrapper are retained because the fixed inputs are required for
reproducible evaluation.

#### 後続の選定：東京都・令和3年1月第5表を独立holdout screenとして採用（2026-10-19）

Profile ID TokyoResidentRegister202101Holdout20261020をholdout-onlyとして固定する。用途は行政統計の小規模構造化CSVに対する独立screenであり、開発・学習・tuningには使わない。入力は上記の公式raw CSV 295,022 B（SHA-256 24f90c92c90500bef3e7e2170691a7bcc4fa0f22ecfe8f20cb9e1586e49af1a8）をbyte-preservingでZIP化した単一member input/tokyo-population-2021-01-table5.csv。screen wrapperは295,202 B、SHA-256 7c5fa47e7c58cc2512024c6491af4589837e9395b8171ce84dd3d0193757c511。memberはstored、295,022 B、compressed bytesも295,022 B、member SHA-256はraw CSVと一致し、固定timestampは2020-12-31T15:00:00Z。KHC screen `Manifest()` と同じbasename file-set manifest（UTF-8、name<TAB>bytes<TAB>sha256、LF区切り、末尾LFなし）は 60964784dba36f8f7d3f63e71dda413aec4dbf501bf493dd19f9a1f85311159b。取得記録は初期wrapperの別manifest（末尾LFあり）と区別している。

比較はPortfolioTrial revision 10と7-Zip 26.04を固定設定で行う。7-ZipはLZMA2 level 9、solid、要求dictionary上限64 MiB、圧縮1 thread・展開4 threads。候補の圧縮サイズは7-Zipの95%以下、圧縮・展開の測定中央値は双方7-Zipより遅くないことを事前判定基準とする。20 registered runs（round 0 warmup、round 1–9を交互順で測定）、各process 160 MiB、command 60秒、全体30分、各command前の外部CPU 5 samplesすべて15%以下を維持し、結果後に条件を緩めない。最新の候補・source・tool・script pinsを別immutable campaign markerに固定し、storage/process/reparse/CPU preflightがすべて通るまではrunを登録しない。CPU gate等が失敗した場合はその固定条件を停止し、値を変えた再試行をしない。

元のCSV内容は表示・parseしていない。raw bytesのhash確認とZIP wrapperへのbyte-preserving転送のみを行った。公式カタログに表示された利用条件は版未指定のCC BYであるため版を推測せず、出典を結果に残す。全利用履歴の監査は未完了。screen結果はこの行政統計の小入力に限り、一般的な速度・圧縮率優越性やGOAL達成の証明には使わない。選定は済んだがcampaign marker未作成・run未登録・benchmark未実施。

#### Tokyo holdout profile integration status (2026-10-20)

`TokyoResidentRegister202101Holdout20261020` is now connected to the existing worker, serial runner,
lifecycle, and aggregator. The profile pins the campaign wrapper (295,202 B, SHA-256
`7c5fa47e7c58cc2512024c6491af4589837e9395b8171ce84dd3d0193757c511`), its single stored member, and
the screen file-set manifest
`60964784dba36f8f7d3f63e71dda413aec4dbf501bf493dd19f9a1f85311159b`. Source URL, official catalog,
attribution, CC BY label, null license version, and the no-inference note are fixed in the profile
and required in the immutable marker and result reports. The content is not parsed or transformed;
only the stored ZIP wrapper/member path is added. The JSON acquisition record, raw CSV, initial
wrapper, and profile wrapper remain in the D-drive TaskArtifacts folders noted above.

Four-script PowerShell AST parsing succeeded; the fixed profile and wrapper/member hashes passed
`Assert-KhcPortfolioInput`; a read-only integration review reported no actionable issue. This does
not constitute a benchmark. The Tokyo campaign marker is not yet created, no runs are registered,
and no size/speed result exists. The corpus is one small structured-statistics holdout family and
cannot support general superiority or complete the broader performance-evaluation goal by itself.
The full all-history audit remains incomplete.

#### Tokyo holdout campaign preregistration (2026-10-20)

The immutable marker is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\tokyo-population-holdout-campaign-20261020\campaign-start.json`,
campaign `130beb8a0bd84ac4a763b719457e421b`, SHA-256
`903fa128a77e8dbfab2cd914bc391b79d26dd234ae04b6668642ebbc2f8e48d5`. It fixes the
registration window to 2026-10-19 21:00–21:30 UTC / 2026-10-20 06:00–06:30 JST and was accepted by
the lifecycle validator before start. The 290 MiB storage/process/source/input/tool preflight passed;
there are still no registrations, candidate/7-Zip invocations, or measurements. The next step is the
fresh 15% external CPU gate at or after the fixed start. Any failure closes this exact condition
without retry. The all-history audit remains incomplete and this single small-data holdout cannot
establish broad superiority.

#### Tokyo holdout campaign stopped at the pre-registration gate (2026-10-20)

The fixed gate began at `2026-10-19T21:00:23.6419329Z` and stopped on its second
external `_Total` CPU sample: 8.97% at `2026-10-19T21:00:25.3930677Z`, then 57.04% at
`2026-10-19T21:00:26.4202499Z`. It stopped immediately above the preregistered 15%
limit, without taking the remaining samples. This closes campaign `130beb8a0bd84ac4a763b719457e421b`
for this exact source/input/profile/window without retry. No run was registered, neither compressor
was invoked, and there are no performance measurements. The immutable start marker remains
unchanged (SHA-256 `903fa128a77e8dbfab2cd914bc391b79d26dd234ae04b6668642ebbc2f8e48d5`); immutable
stop evidence is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\tokyo-population-holdout-campaign-20261020\pre-registration-stop.json`
(SHA-256 `c4fd8a647b9c84ebe718b5833663d0bf76a31c4705dfe75c4b0daf704e7e3ffd`). The prospective
gate instructions above are historical, not a pending run or a result.

#### Livedoor holdout profile integration status (2026-10-20)

LivedoorNews2012Holdout20261020 is wired through the worker, runner, lifecycle validator, and
aggregator. The profile pins all 191 member records internally and verifies them against the fixed
wrapper and full file-set manifest. The compact campaign marker uses an empty input_entries array
to stay below the existing 32 KiB bound; exact names, sizes, and hashes remain enforced by the
profile validator. It also pins source provenance, category quotas, no-training/no-tuning status,
and the Livedoor-only 7-Zip listing caps. The fixed input remains in the same D-drive TaskArtifacts
directory; no copy was made.

The 7-Zip metadata listing was the only 7-Zip action: 60,541 stdout bytes and 0 stderr bytes, within
the 262,144 / 2,048 byte profile-specific caps. The compact marker validation measured 5,603 bytes.
PowerShell AST parsing, whitespace scanning, and Assert-KhcPortfolioInput passed for all 191 member
paths, sizes, hashes, stored representation, timestamp, manifest, and wrapper SHA. This is setup
validation only. No marker was written, no run registered, and no compression or decompression
comparison occurred. The four script pins and complete setup evidence are in STORAGE.md, SHA-256
e6218d7564c321fbb458eae560ec8fa24e2340d77d39facaa0a1714662c5d988. The full all-history audit
remains incomplete; the profile is one source family and cannot establish broad superiority alone.

#### Livedoor independent holdout fixed campaign preregistration (2026-10-20)

Campaign `e54b2fcd559640d583e3e89e631bca50` is fixed for 2026-10-19 21:40:00–22:10:00 UTC
(2026-10-20 06:40:00–07:10:00 JST), using the unchanged 191-member Livedoor holdout, Rust source
manifest, Release CLI, 7-Zip 26.04, and four script pins recorded in `STORAGE.md` (current SHA-256
`5e46c17b6939d0dd45e2e36eae577108d3a805a8ff3a325583509fb51bcf304a`).
The marker path is
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\livedoor-holdout-20261020\campaign-start.json`;
its SHA-256 is `5f53c86c7eb3c54cc33c9a08a71dbb5fdd46ff96767d6c9f1b2944476310ee2c` (5,299 bytes),
and the marker passed static lifecycle validation before campaign start. No run is registered yet.
The 20-run schedule warms both methods in round 0; even rounds candidate-first and odd rounds
7-Zip-first, with rounds 1–9 measured. Fixed 7-Zip options, size/speed criteria,
290 MiB reserve, process/command/run bounds, 15% five-sample CPU gates, and no-retry stop rules are
preregistered in `STORAGE.md`. This is one independent text corpus only; no broad superiority claim
or overall-goal completion follows from this screen alone.

#### Livedoor fixed campaign stopped at the internal CPU gate (2026-10-20)

The five-sample external start gate passed (1.23%, 6.46%, 3.19%, 3.34%, 0.92%). The first and only
registered sample, round 0 candidate, failed its internal create gate on sample 4 at 19%, above the
fixed 15% limit; it did not start the timed create command. No 7-Zip timed comparison, size/speed
measurement, or aggregate result exists. The campaign is closed with no retry; the receipt-backed
Prunlet cleanup completed. The run ID, gate readings, recovery archive/report hashes, lifecycle
receipts and detailed stop evidence are documented in `STORAGE.md` (current SHA-256
`5e46c17b6939d0dd45e2e36eae577108d3a805a8ff3a325583509fb51bcf304a`). This one-source-family
screen yields no broad-superiority or overall-goal claim.

#### UCI tabular sources are development-only; execution and holdout evaluation remain closed (2026-10-20)

The UCI Bike Sharing `hour.csv`, Steel Plates Faults `Faults.NNA`, and Abalone `abalone.data`
candidate recipes remain development/tuning data only. Their metadata and source/member hashes
are recorded in the UCI candidate sections above. Prior-use and independence evidence is
incomplete, so these files are not blind holdouts and must not enter the final 13-category
aggregate or a broad-superiority claim.

The new `UciTabularDevelopment20261020` profile is metadata-only and hard-disabled with
`ScreenReady=false`. The required article is identified as Fanaee-T, H., & Gama, J. (2014),
“Event labeling combining ensemble detectors and background knowledge,” *Progress in Artificial
Intelligence*, 2(2–3), 113–127, DOI [10.1007/s13748-013-0040-3](https://doi.org/10.1007/s13748-013-0040-3).
The [UCI page](https://archive.ics.uci.edu/dataset/275/bike+sharing+dataset) labels the
introductory paper 2013; [Springer](https://link.springer.com/article/10.1007/s13748-013-0040-3)
records online publication on 2013-11-26 and volume/pages as 2014. The citation is now recorded in
the profile, but no fixed input wrapper or manifest exists and member-level notices/rights remain
unresolved. Do not create a campaign marker or run the screen until those remaining blockers are
closed. The four-script integration and its exact pins are documented in `STORAGE.md`;
AST/schema and reject-order checks passed, and an independent review found no actionable P1/P2
issue. No payload was opened, and no build, registration, benchmark, 7-Zip run, aggregate, or result
exists for UCI.

The same integration pass corrected future abandoned-run recovery dispatch so the Livedoor
holdout uses its own campaign validator; JMA and Tokyo continue to use their dedicated validators.
Independent static review found no P1/P2 issue, but no recovery run was needed or performed. This
does not reopen or alter the already closed Livedoor campaign. See `STORAGE.md` for the exact
implementation pins; the current storage reference is recorded in the latest section below.

#### NICT京都Wikipedia日英対訳コーパスを次の限定screen候補に選定（2026-10-20）

[NICT公式ページ](https://alaginrc.nict.go.jp/WikiCorpus/)はVersion 2.01を2011-01-13に公開、
配布アーカイブを約74MBと記載し、利用・再配布をCC BY-SA 3.0と指定クレジットの条件下で
許諾している。[公式README](https://alaginrc.nict.go.jp/WikiCorpus/src/readme.pdf)によると、
日英対訳は1記事1 UTF-8 XMLで、15カテゴリ別ディレクトリ、カテゴリコードと5桁連番の
ファイル名を持ち、記事ごとにWikipedia編集履歴由来の著作権者リストを含む。原資料は
2008/2009年のWikipedia dump。NICT自身が誹謗中傷・差別用語・個人情報への注意を明記する。
権利判断ではなく、公開再配布をしないローカル評価に限る。NICT指定の出典・ライセンス
クレジットを保持し、入力本文やタイトルをログ・コード・レポートへ出さず、集計値・件数・
ハッシュのみを記録する。

既存の同テーマPlumivox検索 `日本語 コーパス オープンデータ` は0件・
`completeSearch=false`で、非網羅であり不在の根拠ではない。`<作業フォルダー>\TaskArtifacts\UnLhaRe`、
`<作業フォルダー>\UnLhaRe`および本書・STORAGE.mdの読み取り専用検索では同コーパス／Wikipediaの
過去入力記録が見つからなかったが、全履歴の独立性監査は未完了。NDL国会会議録API案は
会議録・発言の検索取得APIで、API仕様に固定データ版/配布hashの入力項目はなく、これは
再取得時にsnapshot差が起き得るという推定である。またNDLのAPI条件では、NDL職員発言と
DBを除く発言の著作権は各発言者に帰属し、原則許諾が必要（著作権法上の例外を除く）と
される。[API仕様](https://kokkai.ndl.go.jp/api.html)、[NDL利用規約](https://www.ndl.go.jp/sitepolicy/terms)。
固定archive版と明示ライセンスを持つNICTを、権利・再現性の未解決リスクを記録したうえで
内部screen用の次候補として優先する。

公式v2.01 tarは取得済み。`wiki_corpus_2.01.tar.gz` は74,096,805 bytes、SHA-256
`456172bdd1d7a32dbe68ae3e55e0a6de25a4f40582636fd7712a5404319a10e5`。メタデータだけで
記事XML 14,111件と15カテゴリを確認し、先行する512件wrapper（14,014,059 payload bytes、
14,069,377 ZIP bytes、SHA-256 `5e5c790274d4ada68e3750160255cdf28d08f96d704ca85deb01aa8fb33e55a3`）を
作成・各member hash検証した。ただし512件wrapperは評価入力として不採用にする。workerは
作業ツリー全entryを512件以内（rootとreport予約を含む）に制限し、入力展開と復元出力の
同時保持で少なくとも1,024ファイルentryを要するため、比較開始前に枠を超える。

容量枠を緩めず標本設計を変更する入力recipeをここで固定する。公式archiveから15カテゴリの
記事XMLだけをpath/size metadataで選び、各カテゴリ内を正規化UTF-8相対pathのSHA-256順
（ordinal pathを同値時tie-break）に並べる。カテゴリコードordinal順に13 roundをround-robinで
選び、計195件（各カテゴリ13件）とする。合計payloadは32 MiB−128 KiB以下でなければ拒否し、
内容を見て再選択しない。member bytes/pathは変換せず`ZIP_STORED`し、全entry timestampを
1980-01-01、root prefix・comment・extra fieldなしの決定的wrapperを作る。source archive SHA、
選択metadata manifest、member SHA manifest、wrapper SHAをTaskArtifactsに保存し、repoへ
データをコピーしない。選択metadata manifestは選定bytesを開く前に生成・hash固定し、最終
packagerはそのhashとpath/size集合を再照合してから選定bytesを読む。metadata-only passで
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\selection-manifest.json`
を生成した。195件・5,236,133 payload bytes・各category 13件、36,730 bytes、SHA-256
`c575b295d3afff9e057fc078688caf71b5d9edae849d1d9bc637fd2b4db73e09`。内容はpath・category・
path SHA・sizeのみ。最終packagerはこのmanifest SHAを必須入力とし、source archiveから再計算した
path/size集合との完全一致を確認してからmember bytesを読む。候補の正確な入力/member manifestは
wrapper生成後に追記し、campaign開始前にworker・runner・lifecycle・aggregatorとともに新規
immutable markerへ固定する。

評価はローカルの圧縮・展開だけとし、NICT指定の出典・CC BY-SA 3.0 creditをprovenanceへ
保持する。本文・記事名は表示、ログ化、公開しない。NICTが注意喚起する第三者権利・個人情報に
関する法的判断や公開再配布を意味しない。既存同テーマPlumivox検索
`日本語 コーパス オープンデータ`は0件・`completeSearch=false`で非網羅。今回の同テーマ検索は
Toolport接続拒否で再取得できず、既存結果のみ参照する。

最終packagerはmetadata選択manifestのSHAとpath/size集合を照合してからmember bytesを読み、
`input.zip`（195件・5,236,133 payload bytes・5,257,215 ZIP bytes、SHA-256
`aee6335bc9f43f35e5c29c3944cb8067eefed618578c02c8faac4ff4112c5ecd`）を作成した。member manifest
SHA-256は`21cab6251284f8b020c66756e9a96e711fa76abf4fea1f8342ef83d894504748`、file-set manifest
SHA-256は`cad92e76db4142c15c32b924f8906320a38fff42638d1cdc69e5a9ed157b66f5`、inventory SHA-256は
`f9cccf4b35220e8b95e33477778d5636dc71c58072ef319dee9b7b181d40217e`、attribution入りacquisition
record SHA-256は`4a2dcd95379f4af5aab54fcb04d97e9cd733ef23fa2e841ea0d7b0c2f4e3f8ae`。全memberのpath/
size/SHA、stored長、1980-01-01 timestampを独立照合し、7-Zip 26.04 `t -tzip` はexit 0。
まだprofile wiring、campaign marker、実行登録、性能比較はない。採用後も1つの独立source familyに
過ぎず、広範な優位性やGOAL完了の根拠にはしない。STORAGE.md SHA-256は実験profile記録の更新後に
同期する。

#### NICT holdout profile配線を検証（2026-10-20）

前項を更新する。`NictWikiCorpusHoldout20261020`をworker、runner、lifecycle validator／recovery
dispatcher、aggregatorの4ファイルへ配線した。Profileは195件・15 category各13件の固定入力を
holdout-only／1 source familyとして扱い、training／tuningには使わない。frozen metadataとmarkerを
payload読取り・run登録より前に照合し、markerには個別member行を複製せず、固定ZIP SHAとordinal
file-set SHAで全体を拘束する。レポートは本文・member ID・パスを出さず、console、argv、inventoryを
匿名化しつつargv SHAと集計に必要な計測値を保持する。

レビューで見つかったNICT worker終了処理のエラー匿名化漏れは、final inventory／storage validation／
report saveの各catchと最終throwを固定メッセージに置き換えて修正した。修正後の読み取り専用レビューで
P1/P2なし。4 scriptすべてのPowerShell構文解析と、合成path-bearing例外によるNICT匿名化・通常profile
動作維持の検証に成功した。現時点でcampaign marker、run登録、圧縮・展開、性能測定はない。

Profile実装pin: `storage-lifecycle.psm1` SHA-256
`f4b082ccee1abfa14616410b4319e66386b05ab8405e32108dd518146ac23d42`、`run-storage-experiment.ps1`
`55bbcea28bb2230d7e546c3915530164258ef020e1134734bd5092e058c9c134`、
`portfolio-7zip-product-screen.ps1` `ac1d99edf74a065db86b87b42626802878b7312576941d3199e0888e51849332`、
`aggregate-portfolio-7zip-product-screen.ps1`
`73cb52f02e9cfde35e6bb2fe918e63f75ddf661b2f3cd2d943241ff585a7b481`。Rust source manifestは37件で
`0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404`、CLIは
`3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b`、7-Zip 26.04は
`95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53`。現行campaign protocolと未実行条件は
[`STORAGE.md`](STORAGE.md) SHA-256
`729e401900f80e1566d4dddaefac89b5503357c6abba3c809906d65e01bfa51c`に記録した。
この限定sampleは広範な代表性や優位性の証明ではなく、holdout測定もまだ存在しない。

#### NICT holdout screenの固定campaignを事前登録（2026-10-20）

profile、権利・出典provenance、匿名化出力、比較設定を固定し、campaign
`9dd033d334034bbeaa1861acd9b98e0f`を作成した。immutable markerは
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\campaign-start.json`、
5,291 bytes、SHA-256 `cbc2724fe152bf070ee46c8c58a5593cbbb81af4796008aff2a829731c622d8b`。
実行可能時間は `2026-10-19T22:50:00Z`–`2026-10-19T23:20:00Z`（JST 07:50–08:20）。

条件は32 MiB／512 entries／300秒の単発登録20回、総時間1,800秒、各child command 60秒・160 MiB、
登録前と各timed command前に5点の外部CPU gate（全点15%以下、最初の失敗で即停止・retryなし）。
round 0をwarmup、round 1–9を測定し、round parityでstrategyの先行順を交替する。7-Zip 26.04は
solid 7z/LZMA2 level 9、辞書64 MiB、create 1 thread、extract 4 threads。採用基準は7-Zip比
圧縮サイズ95%以下かつ圧縮・展開の中央値が双方no-slower。各登録後にPrunlet lifecycle cleanupを
完了するまで次runを開始しない。CPU・容量・時間・入力検証の失敗時はこのsource/input/windowを
閉じ、条件や閾値を緩めない。

開始前提としてfresh process／path／reparse／pending-run／storage preflightとCPU gateを行う。固定
window開始後のpreflightは通過したが、gateにより登録前に終了した（詳細は次項）。この条件では
run登録、timed圧縮・展開、性能結果はない。仮に実行しても結果は単一のstratified source familyに
よる独立holdout screenに限定され、代表データを含む全体評価や広範な優位性・GOAL完了を示さない。
固定条件とscript pinは[`STORAGE.md`](STORAGE.md) SHA-256
`d718dfec282e227239bdf2c986b25ba244623e3a0254371a101e88884727f5e8`に記録した。
独立性はこれまでの評価とは別の配布元・source familyとして区分した意味であり、全履歴の完全な
member-level重複監査は未完了である。したがって、内容の重複が一切ないとは断定しない。

#### NICT holdout fixed campaign stopped at the external CPU gate (2026-10-20)

Campaign `9dd033d334034bbeaa1861acd9b98e0f` opened at `2026-10-19T22:50:00Z`; its 30-minute
window is closed for this source/input condition. The read-only metadata/path/resource preflight passed;
no pending run, relevant process, or run directory had been created. The external `_Total` CPU gate
returned 10%, 14%, 13%, then 19% at `2026-10-19T22:51:28.7369312Z`, above the fixed 15% cap. It
stopped at sample 4 without collecting sample 5. No run registered and no compression, extraction, or
payload evaluation occurred; the condition will not be retried or rebased. Machine record:
`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry\pre-registration-stop.json`
(1,760 bytes, SHA-256 `efd25d722d716c47a0f90423b04aa96830fbd7681d87649bd446ad66f81fbfb4`). This is
an environmental-gate stop, neither a performance result nor a codec no-go. NICT remains a single
Japanese Wikipedia-derived stratified family with incomplete member-level overlap audit; it cannot
establish representative 7-Zip superiority by itself.

### Count-only rANS candidate sizing (correctness E2E completed)

The scheduled KRS2/KRS3 candidate-size path now counts rANS renormalization output and computes the
validated packed-frame length without materializing the discarded payload/frame. Normal archive
encoding still materializes output through the shared finalization and pack validation. Candidate
selection, fallback, output limits, and the conservative 64 MiB memory gate remain unchanged. The
locked/offline x64 Release build completed. The one preregistered revision-10 E2E passed all 34
checks, restored both CLI inputs exactly, and matched the fixed 39,962-byte compressed-data suffix
baseline. Run `b2494857ce574ce497f3a5331af99b02` was cleaned through Prunlet and finalized with
`BeforeBytes=5,453,097` / `AfterBytes=0`. This is fixed-input correctness/byte-identity evidence only,
not speed, memory-efficiency, 7-Zip, holdout, or GOAL-completion evidence. Full pins, recovery, and
receipts are in [`STORAGE.md`](STORAGE.md), SHA-256
`5efee1b07880e161f8944d4c67aef02a50d7018aded9624783e62355a61169e7`.

### Count-only KCS1 candidate sizing (correctness E2E completed)

`PortfolioTrial` の KCS1 候補長を、実フレームを生成せず正確に数える経路へ変更した。range
encoder の状態遷移・flush・出力上限・最後の5回のshiftは通常符号化と共用し、計数時だけ
payloadの確保・書込みとframe packingを省く。候補順位、fallback、64 MiB memory gate、decoder、
出力形式は変更していない。

locked/offline x64 Release build、`rustfmt --check --edition 2024`、KHC既存7統合対象の9 test
casesが成功した。1つ目の8対象一括呼び出しはwrapperの180秒compile deadlineでtest開始前に停止し、
成功扱いにはしていない。固定 `ptt5` revision-10 E2Eは34 child checksが全て期待結果となり、
CLI/API完全復元とmalformed拒否も確認した。CLI archive data suffix 39,962 B（offset 89）は
事前登録hashと一致した。これは固定入力上のbyte identity/correctnessのみで、時間・メモリ改善、
7-Zip優位、代表データまたはindependent holdoutの結果ではない。

全pin・E2E結果・Prunlet cleanup receiptsは [`STORAGE.md`](STORAGE.md) SHA-256
`aaa2d4ff9965ea91161f05f4314520ade215e3b428e36d7715dce5992903cdfd` に記録した。

### Count-only KCS1 Canterbury 7-Zip development screen（事前登録）

KCS1候補長のcount-only化後に、以前のschedule-replay CPU停止とは異なる固定source conditionで製品書庫を比較する。入力は既使用のCanterbury 11件（2,810,784 B、固定member manifest）で、開発・調整用のみ。holdoutや一般的な7-Zip優位判定には使わない。campaign `1473558eb3cd40b584259586378602db`、immutable marker `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\canterbury-development-kcs1-count-length-20261020\campaign-start.json` は4,475 B、SHA-256 `9c47f2eff1217a68e8d036f026d5b1679601f1f1c5f909695fbb1e563bbc45d5`、固定windowは`2026-10-20T01:30:00Z`–`02:00:00Z`。登録前にmarker/source/tool/input hash、input再照合、資源・pending/process/path preflightと5×1秒CPU gate（各値≤15%）を通す。

20件のserial one-sample registrationでround 0をwarmup、1–9を測定し、round parityでstrategy先行順を交替する。7-Zip 26.04 solid 7z/LZMA2 level 9・64 MiB dictionary、create 1 thread、extract 4 threads。合格基準は候補complete archive size≤7-Zipの95%、候補create/extract中央値がともに7-Zip以下。各run 32 MiB／512 entries／300秒、各child 60秒／160 MiB、総計1,800秒。timed childの5点CPU gateも各点≤15%、最初の超過・失敗で停止し、retryや閾値緩和はしない。KHCがfile mtimeを保存するため、workerは固定入力ZIPの更新時刻を復元しrun間書庫SHAを安定化する。7-Zipは`-mtm=off`のためKHC側がtimestamp metadata分を負担する保守的なサイズ比較で、同一metadata条件の方式比較ではない。

現時点では事前登録のみで、run・性能結果はまだない。全source/runtime/input pins、script hashes、lifecycle条件は[`STORAGE.md`](STORAGE.md) SHA-256
`b801eb9ac50fadebf8169fedebf616159e0c5ee7909de05337b1040ba495e5aa`に記録した。

#### Count-only KCS1 Canterbury screen: external CPU gate stop（2026-10-20）

固定window内のmarker・input・source・CLI・7-Zip・script pin、input hash検証、storage予約、pending-run・process・reparse確認はすべて通過した。開始gateの最初の`_Total` CPU標本が`27.0%`（`2026-10-20T01:32:32.1529155Z`）で15%上限を超えたため、登録前に停止した。同一条件の再試行はしない。

registration、run directory、timed candidate/7-Zip command、性能測定はいずれも0。input validationでは固定された11件のpayload hashを照合したが、候補・7-Zipの性能評価や7-Zip優位/no-go判定は行っていない。環境gate停止であり、候補性能の結論ではない。

停止記録は `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\canterbury-development-kcs1-count-length-20261020\pre-registration-stop.json`（2,120 B、SHA-256 `49f321cc8123c74987dde4cf634d00ae6dd467f13f7554e92314021d63a3df49`）。結果・資源・停止条件は[`STORAGE.md`](STORAGE.md) SHA-256 `946d7a17b2b22a9362a4029a539fe3d83b160399b495a2a7bb7febdad687da11`（265,408 B）へ追記した。

#### Count-only KCS1 NICT single-family holdout preregistration（2026-10-20）

Canterburyの外部CPU gate停止とは別の、新しい固定NICT holdout conditionを事前登録した。195ファイル・5,236,133 Bの既存入力を変更・複製せず、holdout-only（development/training/tuning不可）で評価する。旧NICT campaignや旧profileの再開・時間窓変更ではない。profile/source conditionは`NictWikiCorpusKcs1CountLengthHoldout20261020`。

markerは`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-kcs1-count-length-holdout-20261020-v2\campaign-start.json`（5,012 B、SHA-256 `136ee134727ced18f6c24314349180b1f87c3d3af9579b4e1b05d130550b151e`、campaign `5f4eae64b259422bb79f00055c789ace`）、固定windowは`2026-10-20T02:30:00Z`–`2026-10-20T03:00:00Z`。実験は未開始で、性能結果・優位判定はない。開始時と各timed command前に5点すべて15%以下のCPU gateを要求し、失敗時は即停止・再試行なし。合格条件はcomplete archive sizeが7-Zipの95%以下、かつcreate/extractの両medianが7-Zip以下。7-Zipは26.04 solid 7z/LZMA2 level 9、64 MiB dictionary、create 1 thread、extract 4 threads。

新markerと固定入力metadataのprofile validatorは`2026-10-20T01:52:25Z`に通過した。Rust source manifest `2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21`、KHC source manifest `16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088`、CLI `e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d`を固定した。前段のmarker schema不足は登録前に検出され、旧marker・stop receiptとも保全済み。全source/script/input pins、資源上限、失敗記録は[`STORAGE.md`](STORAGE.md) SHA-256 `7c2e77d800f6fc661e49de7029b733bff5db5dc4e3d4469415259960a22176e1`（271,130 B）に記録した。NICT単一source familyだけでは一般的優位性を主張しない。

#### Count-only KCS1 NICT screen: external CPU gate stop（2026-10-20）

固定window内のmarker、provenance metadata、source/script/tool pin、290 MiB storage予約、pending-run/process/reparse/output-root確認は通過した。しかし開始CPU gate第1標本は`16.9474%`（`2026-10-20T02:30:32.5890533Z`）で15%上限を超え、残り4標本を取らず停止した。登録、run directory、候補/7-Zip timed command、性能測定はすべて0。runnerの入力検証へ達していないため、このwindowでは入力ZIP/member payload hash検証も行っていない。環境gate停止であり候補性能の結論ではない。同一conditionは閉鎖し、再試行しない。

停止記録は`<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\nict-wiki-kcs1-count-length-holdout-20261020-v2\pre-registration-stop.json`（2,864 B、SHA-256 `9f0caad00ee6d2ef707726742af31202add2fd2f182ae8bd359194023df071a7`）。

### UCI Dry Bean: dedicated one-family holdout screen integration (2026-10-20)

UciDryBeanHoldout20261020 adds only a separate conditional single-family screen of the
frozen count-only KCS1 candidate against 7-Zip 26.04. The acquisition lock is preserved at
<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\uci-dry-bean-holdout-20261020\acquisition-lock.md
(SHA-256 4d1b0d8cbcec51cd9feb7107566865cc37bce39dee605f67dfdc847d78cb7393).

Use UCI Dry Bean ID 602, DOI 10.24432/C50S4B, M. Koklu and Ilker Ali Özkan (2020),
under the UCI page's explicit CC BY 4.0 grant with appropriate credit; preserve the research
DOI 10.1016/j.compag.2020.105507. Only the .txt rights/provenance sidecar was read and the
distribution contains no LICENSE/NOTICE/COPYING. The exact raw ARFF and stored wrapper pins,
source/toolchain identities, dedicated admission/campaign validators, immutable marker schema
and report/recovery dispatch are recorded in [STORAGE.md](STORAGE.md), SHA-256
`d4a16c3c9bd1fc942229ba4b1fdb89eb73ebce18237ff6ef5dc93f58a4e56fd6` (277,932 B).
The immutable marker `campaign/campaign-start.json` is SHA-256
`aeb22cb2ec810b9ca1ba8a09bec68c1ba75cbbede4ee2befdc848e2cd37cc284`, campaign
`b4b82fe9e40c4c4ab0d659752a04cbb3`, with a fixed 2026-10-20 03:30:00–04:00:00 UTC
window. The source ZIP and wrapper remain outside the separate campaign and transient cleanup
roots. At 03:30:23.9118654 UTC the open-window marker validation, 290 MiB storage reserve,
115 completed lifecycle-record check, process check and non-reparse path check passed. The
fresh external CPU gate then stopped on sample 3 at 18% (`2026-10-20T03:30:38.5320346+00:00`),
above the fixed 15% limit. The condition is closed with no retry or window rebase. The retained
stop record is `<作業フォルダー>\TaskArtifacts\UnLhaRe\goal-restore-20261019\uci-dry-bean-holdout-20261020\pre-registration-stop.json`
(1,753 B, SHA-256 `d7c878eaed02d39510642549cfd8a8177bb9d79506b6038045832f7227f34342`).

This is holdout-only with no development/training/tuning, parsing, normalization, feature
selection or threshold adjustment. Category contribution is zero; results cannot enter the
final 13-category/three-family aggregate or establish broad superiority/final-GOAL completion.
UciTabularDevelopment20261020 remains metadata-only and hard-disabled. No NICT or Canterbury
campaign is reopened. The candidate and thresholds are fixed before the screen.

Precommit: 20 serial single-sample runs / 10 alternating-order pairs; pair 0 warmup,
pairs 1–9 measured. KHC create1/extract4; 7-Zip 26.04 solid LZMA2 mx9 d64m create1/extract4,
metadata flags off. Complete KHC archive <=95% of 7-Zip and both create/extract medians
<=7-Zip, exact raw-member restore and deterministic complete-archive SHA. Caps are
32 MiB / 512 entries / 300s per run, 60s / 160 MiB per command, campaign 1800s.
Five fresh external CPU samples must all be <=15%; stop on first failed/missing sample,
with no retry, rebase or closed-condition reuse.

The profile was checked by PowerShell Parser, literal-profile schema/manifest and static
dispatch/guard inspection. Runtime marker and resource admission passed, but the environmental
CPU gate closed the fixed condition before registration. No lifecycle run, worker/aggregator,
codec or 7-Zip command, build, member extraction/inspection, timed command, restoration or
performance result exists. This is not a codec no-go or a 7-Zip comparison; the candidate remains
unassessed on this corpus. The source ZIP itself was hash-verified, but its ARFF member was not
opened for evaluation.

### Scheduled KRS frame single-seal candidate — 2026-10-20

The materializing KRS2/KRS3 path now omits the intermediate KRS1 wire-CRC scan that was
immediately superseded after schedule insertion. Normal KRS1 packing still seals, and
the existing scheduled header seals every final KRS2/KRS3 frame. Static review confirmed
that no caller consumes or exposes the unsealed intermediate frame. No extra buffer,
candidate-order change, wire-format change, or decoder change is introduced.

This is an implementation-cost improvement hypothesis, with no measured speed claim.
One fixed-input correctness E2E and a 24-archive data-suffix comparison against the previous
verified recovery ZIP are preregistered in `STORAGE.md` (281,213 B, SHA-256
`f4c40800097f559bb960f38f4b3fa83f0bc70b969feb6aedbb82f3d4639f8201`). Rust/KHC source
manifests are `3b87f833af8ccd1daadd1e2f0fbfe4b8974c5776726207936ed7339b362ab04f` /
`bda2fa7fa3978d786f5877640fc28daf1d440570766c33cd8b5cf2ed8db21326`.
The initial build compiled successfully but failed its Job-drain check on `vctip.exe`;
the wrapper terminated that process and a subsequent no-op freshness build passed.
All previous closed performance and holdout conditions remain closed.

The single-seal correctness run `138e9e5ec2e04c6085a6e3ffefff700e` completed successfully:
34 expected child outcomes (14 success / 20 expected rejection), exact API/CLI restores,
revision 1–9 reads and 9 malformed-archive rejections. All 24 archive data suffixes,
including actual KRS2/KRS3 and ordinary KRS1 frames, match the preregistered prior-output
manifest `57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
The 5,453,097 B temporary tree was removed with verified Prunlet receipts; recovery ZIP
`448f2c9fff97489fda72731c5eb7be7ea8db321b05fc8366f8acc5287881f696` remains in the D:
TaskArtifacts lifecycle run directory. Final `STORAGE.md` is 283,291 B, SHA-256
`bd75f325e3f7b130f1831f2de898094c03fd8329c3a929305411c511c4b8ad94`.
This advances implementation cost and output-preservation evidence. It does not establish
a measured speed/memory benefit, a comparative result, or final GOAL completion.

The final lint cleanup changes the source manifests to
`4011127d02a1d0f97fb37937e9cb8159fa792bddc0ae2ab0185ab2a2577f1350` /
`d3871acfe3aa4e398b35e6f0a575a5d5099630cffa29b323ac5875180e1f79b6`.
Rustfmt and Release Clippy `-D warnings` now pass after three behavior-preserving edits.
A final fixed-input E2E with the same 24-suffix byte-identity criterion is preregistered
in `STORAGE.md`, 284,788 B, SHA-256
`47a418c85bd0480a0bee69c5c2d1541f1c463d21a92c8c99ec8a71f9841b2847`.

Final run `7ca5b9931bcf4b9d9861b0d71f0130ab` passed the same 34 outcomes and 24-suffix
byte-identity criterion with the lint-cleaned source. Recovery ZIP is 746,800 B,
SHA-256 `9c2fd73251bb6dcf6f22552e54ee6c24cf2f716b05cbe5c3caf21b7cffb7ddab`, in its
D: TaskArtifacts lifecycle run directory. Four cleanup receipts verify state complete
and the temporary tree is absent; no pending run or relevant process remains.
Final `STORAGE.md` is 286,019 B, SHA-256
`1cbace1eb16435abd1211f3db3ceddc89badca354f9fabdfaedc6329129f76ba`.
The next performance question is the real cost saved when KRS2/KRS3 is materialized;
size/candidate selection evidence alone does not answer it. Existing closed campaigns
are not reused, and current code is not evidence of general superiority over 7-Zip.

### Single-seal KRS2 development speed-frontier condition — 2026-10-20

The historical fixed ptt5 screen gave KRS2 46,274 B versus 7-Zip mx9 42,199 B; the
single-seal change preserves wire bytes and cannot close that size gap by itself.
The next local screen therefore discloses all mx1/3/5/7/9 LZMA2 settings and mechanically
selects the fastest baseline satisfying at least the candidate's compression rate. Its
size, both time medians, combined and directional memory, and domination criteria are
frozen before evaluation. Actual single-frame KRS2 materialization is required for every
candidate sample, ensuring that this source change reaches the measured code path.

The single-use marker `krs2-single-seal-frontier-20261020/campaign-start.json` under the
current D: TaskArtifacts task root is 2,390 B, SHA-256
`9a3109f0b11f5f35b627982f494bd09888d3f070e47c17ee8329ea15d76aab77`, campaign
`a424e51c266b492193c354ca6a40379b`, fixed UTC window 04:45–05:00 on 2026-10-20.
It is development-only and cannot contribute holdout/general superiority/final GOAL proof.
The preregistration version of the final harness protocol was `STORAGE.md`, 292,101 B, SHA-256
`8cfd965f83b730c379205ae73ceb204edc339ea738e0e6fe30dd0e6d519a20f1`.

Static checks and independent review passed after correcting case-variant dispatch and
premature publication of pass before final gates. Read-only preparation and negative
admission checks passed without a run, claim, member extraction or codec command.
At this preregistration point comparative timing remains unperformed. Fresh in-window
CPU/storage/process admission is still required, and failure closes this condition without retry.

#### Single-seal fixed-window disposition

At 04:45:10 UTC on 2026-10-20, the fresh open-window source/tool/input/harness pins
and pending-run check passed, but the no-relevant-process gate found `vctip.exe`
PID 25184. Admission stopped before CPU sampling or registration. The later read-only
process/capacity diagnostic confirmed that process and sufficient unchanged storage
budgets; it did not constitute a second admission. The retained marker-directory
`pre-registration-stop.json` closes `SingleSeal20261020` without retry or rebasing.
There were zero registrations, CPU samples and codec commands, and no claim or new
work tree. No candidate/baseline performance was obtained: this is an environmental
incomplete result, not a codec no-go or a superiority claim. The Rust/CLI candidate
remains correctness-verified as recorded earlier, but its comparative performance
remains unproven. The unrelated process was not terminated.

### KCS1 bounded event replay implementation-cost candidate (2026-10-20)

The KCS1 encoder performed the same Voter walk once for the count histogram and once
for encoding. The candidate retains the first walk's Count/Literal events in explicit
8-byte records and replays them after normalization. Count events <=N and literals
<=N bound the transcript to 2N records / 16 MiB at the 1 MiB block limit. Inputs <=10 B
do not allocate it. Actual transcript/model/range capacities are checked, transcript
storage is dropped before final-frame allocation or stored fallback, and SpatialMdl
charges the retained MDL frame's actual capacity against the unchanged 64 MiB gate.
Conservative spatial workspace increases from 2,461,908 to 19,239,124 B: this is a
proposed CPU/memory tradeoff, not a compression principle or an established speed win.
No wire/model/decoder/version change is intended. Portfolio still counts complete
lengths and preserves MDL/KCS1/KRS2/KRS3 tie ordering.

Independent static review passed. The registered MSVC-binary E2E
`9bfc7212c63c4154939758c47ac1e33c` passed all 34 outcomes and the frozen 24-suffix
manifest `57f34e63ea849913853d2487008121635d0a5416656101624a5f50fb6eb22b71`.
The finite checks do not establish allocator-failure injection, all possible Stats,
OS peak memory or speed superiority. Compile and Clippy processing finished, but both
MSVC wrapper invocations failed on surviving `vctip.exe` processes; the guarded Jobs
were cleaned up. The task-local LLD build passed the same complete wrapper in 102.24 s.
LLD Clippy and runtime E2E are being verified separately. Default MSVC repair and
comparative performance remain incomplete. Full pins, budgets and receipts are in
`STORAGE.md`; no failed result is relabeled as successful.

For the narrowly bounded build-environment investigation, Microsoft Learn code-sample
search did not establish a task-local VCTIP opt-out. The
[Visual Studio CEIP documentation](https://learn.microsoft.com/en-us/visualstudio/ide/visual-studio-experience-improvement-program)
describes product-wide privacy/registry settings, not a verified fix for this MSVC
14.51.36231 Job-drain symptom; no such setting was changed. X search `vctip.exe`
returned three historical reports (2016/2017/2024), including
[Yaser Zhian's 2024-01-16 report](https://x.com/i/status/1747224080531501314).
These are historical context, not evidence for the current version or a repair.
The local Rust 1.98.1 toolchain's `rust-lld.exe` reports LLD 22.1.8; the
[official rustc linker options](https://doc.rust-lang.org/rustc/codegen-options/index.html#linker-flavor)
support explicit linker selection and `lld-link`. This supports the task-local isolation
attempt without tool installation or global changes, not the claim that MSVC is fixed.
Preserved old/new MSVC binaries must be used for source-only ablation so that a linker
change is not mistaken for the event replay's effect.

The subsequent LLD Clippy wrapper passed (20.59 s). LLD runtime E2E
`e026e44168d0497287db2bb92a90be83` also passed all 34 outcomes and the same 24-suffix
manifest, with native child exit 0 / complete pipe drain / no remaining Job member.
Both E2E temporary trees were Prunlet-cleaned and finalized with verified receipts;
only small restoration/reproducibility evidence remains. These results validate the
unchanged finite semantics under the explicit LLD condition; the ordinary MSVC
environment and comparative performance are still not established by them.

The separate replay source-cost / five-level 7-Zip protocol was frozen after independent
harness review and metadata readiness fixes. Its actual 2026-10-20 05:22 UTC external
CPU admission sampled 6%, 12%, 26%; the third exceeded the preregistered 15% ceiling.
The same-mutex stop helper closed the condition before registration or codec execution.
Final protocol SHA-256 is `ed993052935ba26b3825c22535d05a10d9336941846e3abb6776be7d8bb34cec`,
stop receipt SHA-256 `c854dbf5e604599b1dd60a9a5fc6a7e6faf6018a815b5fe8fbd3825e96692603`.
Read-only revalidation confirmed refusal of the closed condition; no performance
sample or eligible baseline was obtained. Do not call this a codec failure, measured
speed win, memory win or 7-Zip superiority. The implementation remains a correctness-
verified CPU/memory tradeoff proposal under the explicit LLD condition. Any next code
candidate must have a substantive new benefit, not merely a changed source hash or a
reopened timing window. Reducing the additional transcript workspace is a separately
motivated design direction; its benefit to speed and OS memory still requires evidence.

The next substantive candidate replaces the 8B transcript with 2B records, reconstructing
position and XOR residuals from Count varints, the saved width and immutable raw input.
Its maximum transcript is 4MiB rather than 16MiB; the conservative spatial bound is
6,656,212B rather than 19,239,124B. This is an accounting/representation reduction, not
an OS peak or speed measurement. Independent static review, LLD release build and
Clippy passed. Registered native run `01ea4f624410461b87cc7540611dada4` passed the same
34 outcomes and exact 24-suffix manifest, with child exit0/EOF/Job0. Its temporary tree
was Prunlet-cleaned and finalized. Details, source/executable pins and explicit finite
coverage limitations are in STORAGE.md. The closed 8B timing admission stays closed;
no 7-Zip or source-cost performance claim follows from this correctness result.

The S2 timing protocol was subsequently frozen with same-toolchain/features LLD8B/2B
artifacts, independent harness review and an additional premeasurement observed-range
guard beyond the5% median gate. Its one external admission on2026-10-20 05:50 UTC
sampled7%,9%,47%; point3 exceeded15%. It closed before registration/claim/any codec,
with protocol SHA `e972887689551b2d6a0a34cc93491ddde18503a269ba7a8eb00510aa9f07cda2`
and stop SHA `ae9f8a7c9b89e852ae9a37eade84cfecdc9d5a60d6a2813256d259d57d7dcb85`.
This supplies no timing/OS-memory/7-Zip result and cannot be retried after load falls.
Do not reinterpret source representation savings or finite correctness as completion
of the requested representative/holdout performance advantage.

On2026-10-23, S3 folds standalone Count0 into its following Literal's bit14 while
retaining2B records. Positive-copy varint records charge at most their copy length,
so total records<=N rather than2N. This reduces maximum transcript4→2MiB and the
conservative spatial bound6,656,212→4,559,060B without changing wire/model/decoder.
Independent static review found no P1/P2. Before production edits, extended finite
E2E baseline `3e8983eeee7146fe8729467941ab7b25` supplied three complete frame goldens;
postchange `2e2e12f4afea4dbe8028bbb7b0f4ad9e` passed those goldens,34 outcomes and the
same24-archive suffix manifest. Same-toolchain1.98.1/LLD release build and isolated
Clippy passed. An initial Clippy dispatch instead selected repo-default1.99.1 and hit
the128MiB transient guard; it remains a failed attempt, not a successful1.99.1 lint.
Default-toolchain validation, actual peak memory and CPU/7-Zip advantage remain open.
Details/pins and retained before-image are inSTORAGE.md; prior timing campaigns stay closed.

Before S3 timing, current stable7-Zip was reverified from the official download page
and release as26.05(2026-10-21), replacing only the unexecuted new draft's26.04 pin.
Official Extra x64 standalone7za.exe was isolated with matched release asset SHA and
license; installed26.04 and historical records stayed unchanged. X search returned2
unofficial matching summaries, used only as supplementary pointers, not version authority.
Final independently reviewed55-setting protocol729b58df...8833fa retained every full
7Zip median/range/memory/frontier gate. Its one admission on2026-10-23 03:28 JST
sampled7%,37%; point2>15% closed it before registration/any codec timing. Stop SHA
`66c33ae80f1ba027a37a695eda726b1a95d9d8ee9bcb01ee3830f9538e34b1fa` is preserved.
Therefore neither actual S2→S3 memory/CPU tradeoff nor7Zip superiority is established.
No retry of S1/S2/S3 closed conditions is authorized by a later low-load observation.

## 2026-10-27: 追加のニューラル圧縮先行例

調査時点 2026-10-27。[Tacconelli, *Nacrith: Neural Lossless Compression via
Ensemble Context Modeling and High-Precision CDF Coding*](https://arxiv.org/html/2602.19626v2)
は2026-02-23公開、確認本文のv2は2026-02-24改訂。著者は事前学習言語
モデルとオンラインN-gramを用いた予測、算術符号化と高精度CDFを組み合わせ、
高確信のN-gram予測時には言語モデル推論を省く。個々のstreamには逐次依存が
あり、独立chunkを並列処理する構成も説明している。予測の切替や高精度CDF
自体を今回の新原理とは扱わない。

論文の`alice29.txt`は152,089B、報告値は0.918 bits/byte。比較対象には
`xz -9`、`zstd -19`などが含まれ、GTX 1050 Tiを使用したと記載されている。
これは著者の測定であり、KHCとの直接比較でもCPU速度の根拠でもない。論文は
双方に約500MBの事前学習モデルが必要とし、比較サイズには共有モデルの費用を
含めていない。作者は学習データ混入の可能性と、約21 token/sという処理速度も
制約として挙げる。実用条件でモデル配布費を含める本目標とは条件が異なり、
この方式を今回の通常CPU向け本線へ採用する根拠は不足する。

arXivの表示は[非独占的な配布許諾](https://arxiv.org/licenses/nonexclusive-distrib/1.0/license.html)であり、
コードやモデルの再利用許諾を確認したものではない。本文は原理・制約の参考に
留め、コードやモデルは取り込まない。OpenAlexで見つかったHEP向けのBOA
Constrictorについては一次本文にアクセスできなかったため、詳細・効果・利用条件
は未確認。関連語の日本語・英語によるPlumivox検索はともに0件で、先行例がない
証拠にはならない。Canterburyは調整済みで、未見評価には使わない。
