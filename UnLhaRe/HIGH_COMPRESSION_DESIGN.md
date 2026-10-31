# 独自高圧縮方式 KHC — 設計案 0

状態: **LZ改良・適応rANSと直接文脈の試作あり・性能目標未達成・製品形式未凍結**。KHC（Kagayoi High Compression）は作業上の仮称で、登録済み形式名ではない。[実験仕様と操作](experiments/khc/README.md)は本設計全体の完成版ではない。[固定した開発/holdout集合](experiments/khc/CORPORA.md)を使い、局所的な改善を全体目標の達成へ読み替えない。

2026-09-30の独立BWT/next-use binary rank-run＋4予測器混合試作は、固定Canterbury groupで505,046 bytesとなり、483,599-byteの開発screen上限を21,447 bytes超えたため不採用。42回CLI E2E・28チェックと独立artifact照合を通ったが、時間/holdoutは評価していない。外部libbscが同入力の参考screenで閾値を通ることと、独自codecの達成は別である。不採用sourceは再現専用経路へ隔離し、出力を変えない予測損失観測で次の設計仮説を反証している。文字別多値rank文法は診断上の符号長が既存rank処理を上回り、7決定種類の混合器状態分離も推定501,769 bytesで上限を18,170 bytes超えるため、新codecには進めない。既存32-bit context keyのslot alias除去は混合器分離と併用せず、推定504,165 bytesで上限を20,566 bytes超過したため同様に不採用。係数違いのsweep、製品codec/default変更、総合目標の縮小はしていない。再現経路・hash・採否は[開発記録](experiments/khc/DEVELOPMENT.md)を参照。

2026-09-26には、適応確率のjournalを約512KiBごとのplan境界で逆順rANS符号化する研究backendを追加した。固定Canterbury groupは483,197 bytes。Rangeとの内部codec比較を各順序7対行い、復号はpairごとの相対差中央値で25.31〜26.28%短縮した。圧縮時間の差は−1.76〜+1.62%と順序で反転し、圧縮の高速化は確認できない。journalの上限は18.25MiB、別の5反復でprocess private bytes中央値は約51.84MiB（Range約35.84MiB）。既定はRangeのまま。詳細は[開発記録](experiments/khc/DEVELOPMENT.md)を参照し、この内部比較時間を以下の起動・I/O込み7-Zip測定と直接比較しない。

同日の現行Release実体と7-Zip 26.03を起動・I/O込みnative-solidで各5反復比較した結果は、KHC/7-Zipが483,197/483,599 bytes、圧縮1,084.7545/626.2071 ms、復号44.4644/41.3077 msだった。11 fileの本文・名前・長さ・決定性を照合した。KHCは402 bytes小さいが圧縮約1.73倍、復号約7.64%遅く、圧縮時private memoryも53,747,712/37,044,224 bytesと多い。総合目標は未達であり、次の性能課題はBT/Beamの圧縮計算量とencoder memoryである。

Windowsの連続仮想領域・需要commit journalも評価したが、最終ビルドの逆順paired測定で復号が3.21%遅くなり、事前の2%基準を超えたため撤去した。private bytes約15.15MiB削減と通常/取消/panic後の全域解放は確認できたものの、採用の再現性は不足している。初回の速度gate通過だけを採用結果として扱わず、現行sourceは従来のVec journalである。同処方は再開せず、記録は[開発比較](experiments/khc/DEVELOPMENT.md)へ残す。

適応更新順とLZ tokenを変えず、eventを4個のrANS stateへ交互に割り当てる固定候補も評価した。独立実装照合を含む164件CLI E2Eと483,259-byteのsize gateは通過したが、同一Release exeの1state対4state・両順序各7対で復号は10.61〜11.33%遅化した。事前の復号10%以上短縮条件を満たさないため候補を撤去し、元source/通常exeのSHA一致を確認した。4state一般の否定ではないが、同じ逐bitモデルへlaneだけを足す構成は採用しない。native-solid/holdout測定は行わず、通常の1state rANSと既定Rangeは変えていない。

研究用の単一group入口（`experiments/khc/solid.rs` / `khc_lab group-bench`）では、平坦な名前・長さ表と本文を1ストリームへまとめ、ファイル間の履歴共有と全内容の復元を検証する。製品用solid group・索引・資源契約の完成ではなく、現在のcodec入力上限64 MiB内の段階実装である。

`group-encode` / `group-list` / `group-decode`と`experiments/khc/compare-solid.ps1`で、7-Zip自身の11ファイル単一solid blockとの名前・長さ・本文比較も行う。2026-09-24時点の研究線はBT5/Blended/W2/B8192/depth48で、通常Match最安親限定、境界外第2親省略、非境界Rep3省略、Literal payloadのblock共有、距離footer価格の4-bit部分和、`extend_match`のinline化、BT5内側ループの不変条件hoist、range encoder・decoderのchecked/unchecked分離、branchless確率更新など、出力同値または個別に測定した近似を使用する。最新のcurrent sourceから作ったRelease実体によるnative-solid 5反復ではKHC 483,130 bytes・圧縮中央値964.1873 ms・復号48.9495 ms、7-Zip 26.03 x64は483,599 bytes・545.7255 ms・38.8625 ms。KHCは469 bytes小さいが圧縮は約1.77倍、復号は約1.26倍遅く、総合目標は未達。比較reportは[開発記録](experiments/khc/DEVELOPMENT.md)に記録した。これは固定開発11入力の比較であり、属性・ディレクトリ・選択展開・同一hard memory上限を備えた実用書庫や未使用holdoutの結果ではない。

2026-09-24の幅探索更新では、同じRelease exeを使ったCanterbury開発11件の5反復で、速度重視W2 controlが483,312 bytes／圧縮985.3388 ms／展開52.7822 ms、W3境界親制限候補が481,746 bytes／1,380.7704 ms／50.8899 msだった。7-Zip 26.03は各runで483,599 bytes、W2比較時552.1021 ms／46.0403 ms、W3比較時547.6577 ms／41.9660 ms。W3は開発集合で7-Zipより0.383%小さいが圧縮2.521倍・展開1.213倍遅く、採用しない。幅2/3の詳細は[開発記録](experiments/khc/DEVELOPMENT.md)に記録した。これは小さな固定開発集合の候補比較であり、評価集合・全カテゴリ・ピークメモリ・未使用holdoutを含む目標達成ではない。

追加した共有phrase表＋独立KHC block候補は、1 MiB/2 MiBとも固定Canterbury groupのframeサイズが連続KHC基準より6.9〜11.6 KiB大きく、phraseなしblock候補よりさらに300〜837 bytes悪化したため撤去した。詳細は[開発記録](experiments/khc/DEVELOPMENT.md)を参照。独立block化やphrase辞書の有効性を示す結果ではなく、総合性能目標は引き続き未達である。

## XOR前の意味context診断 — 2026-09-30

BWT予測器の既存条件をXOR前のtupleで完全識別する単独診断は、旧exact-u32対照504,165 bytesより801 bytes改善したが、推定503,364 bytesで固定上限を19,765 bytes超過し不採用。条件を追加せず、全7,622,618 decisionsと旧frame/全group復元を照合した。normal28 checks/42 CLIと独立artifact照合は成功。新codec・速度・holdoutへ進めず、係数や別shadowとの組合せsweepもしていない。詳細は[開発記録](experiments/khc/DEVELOPMENT.md)を参照。

## 静的BWT区間cover診断 — 2026-09-30

別pipelineのsuffix-tree区間cover＋直接BWT symbol静的order-0符号化も、指定metadata費用を含む楽観total922,691.951 bytesで固定上限483,599 bytesを超え、不採用。7,782区間・理想payload673,096.951 bytes・metadata249,559 bytes・header36 bytesで、実coder丸め/終端は0としている。実frameや一般的な圧縮下限ではない。16 checks/21 CLI E2Eと独立source/artifact照合が成功し、固定11 entryと全byte復元を確認した。実coder・時間・holdoutへ進めず、既存製品/通常controlは変更していない。再現経路・hash・採否は[開発記録](experiments/khc/DEVELOPMENT.md)を参照。

## decision-class CTS診断 — 2026-09-30

固定D16/Q48のdecision-class CTS予測木も診断し、終端込みaux payload＋現headerが511,336 bytesで上限を27,737 bytes超えたため単独置換は不採用。自己検査6 cases/4,653照合、small7 checks/28 CLI、通常28 checks/42 CLI、独立source/artifact監査が成功した。文法・primary frameは不変。rank仮数には予測改善があったが、無料の事後class選択でも現header込み理想483,718.381 bytesで閾値外。この段階では新しい因果的切替と正準alphabet表現の可能性は限定計算に留まっていた。[開発記録](experiments/khc/DEVELOPMENT.md)を参照。

## 因果的Bayes / packed alphabet完全prototype — 2026-09-30

7 decision-classごとにprimaryとCTSの更新前Q15確率を、過去だけのcomponent尤度・prior1/2で混合する単一構成を実装した。CTS深さ/係数/contextを探さず、component更新は元式のまま。alphabet表は33-byte bitmapと厳密整数の順列順位へ変更した。全257 symbolsでは表245 bytes、基本header36と合わせ281 bytes。独立BigInteger復元、小順列873件、全サイズ両端514件、不正入力278件、閉形式loss照合が成功した。

研究用の新frame `KHBAY001` と同期decoderも完成し、終了済みpayload483,187＋表245＋基本header36＝**483,468 bytes**を完全復元した。36 checks/61 CLI、別最適化levelのencode/decode、不正入力のCRC修復後の意味検査・非正準range終端・既存出力保持、独立ソース/成果物確認が成功。製品LZH wire/API/defaultには統合していない。

初期full候補の同一セッションwarmup1＋9回交互測定では、encode中央値**4,937.9919 ms**、native 7-Zip **602.3128 ms**、paired ratio中央値**8.241765倍**。OS peak working set中央値は候補130,473,984対42,610,688 bytes。size gateを131 bytes下回る一方、固定encode条件<574.5624 msへ届かず、速度と資源の点で**採用no-go**。元groupを包む7z対照は484,190 bytes/593.1739 msで、nativeとは表現が異なる。復号出力は1group対11filesなのでdecode時間比を採用根拠にしない。カテゴリ/holdout・異CPU/OSのfloat決定性・製品統合は未達。

### 同値BWT高速化後の研究基準

minimal PDBのnearest-public名による誤帰属を訂正し、全frame一致を確認したdebug-info付き別pairをfresh採取した。全4980 CPU samplesのruntime inclusiveはBWT49.24%、CTS Model predict25.10%、update10.08%。割合は重複し、加算しない。別debug pairの値であり、元の機械語へRVAを移植していない。

`experiments/khc/causal-bayes-fast-bwt/`は末尾unique最小sentinelを保持し、初期symbol stable sort＋循環SA shift＋1回countsortと5本u32配列へ変更した。完成suffix順/全frameは元と同一。CTS/Bayes/文法/decoderは不変。36 checks/61 CLI＋独立suffix oracle・8MiB境界の58 checks/79 CLI、別役のraw出力/ソース/実exit/成果物監査に合格した。

新しい同sessionのwarmup1＋9回循環測定で、full encode中央値**3,449.5041 ms**、凍結元control **5,029.2708 ms**、native7z **577.6827 ms**。新旧paired比中央値0.691747（約30.83%短縮）、全frame483,468 bytes/SHA不変。OS peak working中央値は130,469,888→74,256,384 bytes（約43.09%減）だがsampled privateは双方232,312,832 bytesで不変。全メモリ改善やlifetime single-threadを保証しない。

同値な局所改善として研究基準へ採用する一方、native paired比5.914388、固定fullencode<574.5624msは未達。なお約83.34%のfull短縮が必要で、**総合7-Zip超過・製品採用はno-go**。次はCTSの整数除算/17-level traversalを完全数値同値で減らす単一案を、別failure-first契約で反証する。既存KT値再利用を見落として重複cacheを追加せず、size/速度条件やholdoutを緩めない。詳細とSHAは[開発記録](experiments/khc/DEVELOPMENT.md)に保存する。

## 現行圧縮経路の解析 — 2026-09-30

復号済み指数をBWT仮数のcontextへ追加する単独診断も、推定501,134 bytesで固定上限を17,535 bytes超過したため不採用。実decoder・時間・holdoutへ進めていない。次に現行LZのmatching Release EXE/PDBと新しい生ETLを採取し、全3,199 CPU samplesの実callstackを欠損なく照合した。BeamActiveのruntime包含は55.99%、BT prepare_restは30.38%だが重複し、排他時間として加算できない。見つかったRep状態の初回必要時生成は局所的な同値仮説に留まり、必要な37–43%短縮を説明できないためgate候補として実装しない。解析CLIの正常・拒否7 checksと独立raw/artifact照合は成功。新たな圧縮高速化や総合目標達成ではない。[新しいCPU解析記録](experiments/khc/NORMAL_RELEASE_CPU_PROFILE_20260930.md)を参照。

## 直近の復号最適化 — 2026-09-24

LZ matchの復号をbyte単位の重複コピーから、最大4 KiBごとの安全なoverlap copyへ変更した。対照・候補の各Release実体で同一483,312-byte frame（SHA-256 `EA3FD394E9F3F277293939C497A79A17AE110CDA22A6289979C0AE3E3DFDCA42`、復元2,811,006 bytes）を7対・各100回測定し、KHC decoder中央値は29.404827 msから28.679377 msへ2.47%短縮した。全11入力のencoder frame hash 22件も対照と一致した。統合solid 5反復ではKHC 483,312 bytes / 972.7697 ms encode / 46.7769 ms decode、7-Zip 26.03は483,599 bytes / 530.4491 ms / 37.9431 msで、KHCは0.059%小さい一方、encodeは約1.83倍、decodeは約1.23倍遅い。したがって局所的なdecoder改善であり、7-Zip超えではない。測定根拠・実行ファイルhash・pair値は[開発記録](experiments/khc/DEVELOPMENT.md)を参照。holdoutは未使用。

## 1. 目的と達成条件

64bit Windows/macOS、x64/ARM64の現代CPU向けに、汎用可逆圧縮方式と専用デコーダーを新規設計する。目的は高圧縮率。基準は7-Zipの7z/LZMA2最高圧縮設定とする。

「ゼロから」は、ビットストリーム、エンコーダー、デコーダーを自前設計・実装する意味とする。LZ77、確率モデル、レンジ符号化など既知の原理を利用する。LZMA2の呼び出しや既存形式の名称変更を独自方式とは呼ばない。学術的新規性・特許非侵害・優位性を証明したものではない。

可逆圧縮であらゆる入力を既存方式より小さくする保証はできない。次の二つを別々に判定する。

| 判定 | 未使用の評価データに対する条件 |
| --- | --- |
| 圧縮率目標達成 | codec比較は総出力サイズと独立圧縮したファイル別サイズ比の幾何平均がともに基準以下。solid書庫比較は書庫全体と事前固定した評価集合単位のサイズが基準以下。カテゴリ別集計も基準以下。個別の敗北は全件開示 |
| 総合性能で同等以上 | 上記に加え、同一CPU・スレッド上限・メモリ上限で圧縮時間、展開時間、ピークメモリも基準以下。測定ばらつきは反復結果から評価 |

圧縮率だけで勝って時間が増えた場合は「圧縮率で優位」と報告し、「7-Zip以上の性能」とは報告しない。追加の研究目標として総サイズ5%以上削減を置くが、予測値や約束ではない。

## 2. 推奨アーキテクチャ

データを固い小ブロックに切って別々に圧縮する方式ではなく、**長い履歴を共有するsolid groupの内部で、複数の符号化候補を比較する方式**を採用する。

```text
入力スナップショット・順序付きマニフェスト
  → 類似ファイルのsolid group化
  → 可逆変換候補（変換なしを必ず含む）
  → [長距離LZ + 文脈レンジ符号化 / 直接文脈符号化 / 無圧縮]
  → ヘッダー・モデル・変換情報を含む実サイズで選択
  → group索引・検査値・一時出力の確定
```

第1実装は長距離LZ経路に集中する。直接文脈符号化はテキスト等でLZ経路に残る差を検証する第2段階とする。単に全部の高度な手法を有効化するのではなく、個別に外した比較試験で寄与を確認する。

### 2.1 データの階層とsolid化

- 書庫 → solid group → coding block → tokenの順に構成する。
- group間には参照を張らない。各groupは独立して展開できる。
- group内ではファイル境界を越えて辞書と確率状態を継承する。ファイル名・長さ・時刻・group内位置は別のマニフェストへ記録する。
- 初期探索値は辞書64/256/1024 MiB、group256/1024/4095 MiB、coding block256 KiB/1 MiB。いずれも測定前の候補で、既定値ではない。辞書はgroup長を超えて確保しない。
- 拡張子だけでなく、サンプルの一致率とバイト分布からグループ候補を作る。小さいファイルはまとめる。既圧縮ファイルも内容の一致を試し、拡張子だけで圧縮不可と決めない。
- 同一内容の判定はハッシュ一致後のバイト比較で確定する。専用の重複除去形式は初期版では持たず、辞書範囲内のLZ一致で処理する。
- ストリーム入力では並べ替えを行わない。並べ替え可能な書庫作成では、入力を検査済みハンドルから一時スナップショットへ読み、圧縮に使った内容と測定内容を一致させる。
- solid化により選択展開時は対象の直前まで復号が必要になる。最悪でgroup全体を読み、最後の検査まで公開できないことを仕様に含める。

### 2.2 長距離LZと一致候補探索

辞書を大きくするだけでは速度とメモリが悪化する。近距離と長距離の索引を分離する。

1. 直近の4 MiBには短い一致用の密な索引を置く。4/8バイトのキーと32bitのgroup相対位置で候補を保存する。
2. 辞書全体には16/32バイトのキーによる疎な索引を置く。初期候補は4〜16バイト間隔で登録する。密度は圧縮側の探索設定であり復号形式には含めない。
3. キーのハッシュは候補選別にのみ使用する。実バイト比較で一致を確定し、衝突を圧縮誤りにしない。
4. 各位置から距離と長さの異なる候補を残す。最長一致だけに絞らず、短距離一致、直近距離の再利用、符号長境界付近で切る一致を含める。
5. 最大一致長の初期案は1 MiB。最小一致長は3バイト。繰り返し距離は直近4件を保持し、専用tokenで符号化する。
6. 1位置の候補探索数・比較バイト数に上限を設ける。長い反復列は専用のrun候補で処理し、同じ領域の比較を何度も繰り返さない。

group相対位置の32bit値には番兵とwrapの規則が必要。初期版ではgroupを4 GiB未満に制限し、64bitの書庫offsetとは別型にする。実装時に上限・番兵の具体値を凍結する。

### 2.3 符号コストを考慮した探索

tokenは`LITERAL(byte)`、`MATCH(length,distance)`、`REP(index,length)`。復号側ではtoken列を順番に実行するだけであり、探索を再現しない。

まず速い暫定parseを作り、その出力から符号コストを推定する。次に各位置のbeam状態を `(cost, last_token_class, repeat_distances[4], predecessor)` として保持する。

```text
best = encode(initial_parse)
for iteration in 0 .. iteration_budget:
    if キャンセル: return Cancelled
    model = estimate_costs(best.tokens)
    candidate = beam_parse(input, match_candidates, model, beam_budget)
    actual = encode(candidate)
    if complete_encoded_size(actual) < complete_encoded_size(best): best = actual
    if キャンセル: return Cancelled
    if 改善なし、または時間予算超過: break
if キャンセル: return Cancelled
return best
```

- 初期実験はbeam幅8/32、追加parse1/3回。速度とサイズの関係を測って選ぶ。
- costにはtoken種別、literal、length、distance、繰り返し距離、モデル更新の影響を含める。推定には固定小数点の`-log2(p)`表を使う。
- literalの文脈は既に復号される入力バイトから作る。token履歴とrepeat距離はparse依存なので、位置だけの動的計画法では正しく表せない。
- 確率状態全体をbeamごとに複製しない。parse中は前回のモデルを近似的に使い、実符号化後に評価する。したがって「大域最適」とは呼ばない。
- tracebackと候補をcoding block単位で保持し、前方のlookaheadを使って境界を決める。入力全体×beam幅の配列は確保しない。block端での候補切断による損失を測る。
- 繰り返し試行は最良出力を上書きしない。改善しない候補は捨てる。無圧縮候補にはヘッダーも含める。

### 2.4 文脈予測とエントロピー符号化

初期の主方式は**整数演算の適応binary range coder**とする。圧縮率重視で、少量ずつ変化する確率を扱いやすい構成を選ぶ。

- token種別、literalの各bit、長さ、距離を別モデルで扱う。
- literal文脈の初期候補は直前1〜4バイト、直前のtoken種別、予測一致位置のバイト、位置の下位bit。
- 文脈表は上限付きハッシュ表とし、衝突・置換・初期値・更新順序を復号仕様で固定する。入力に比例して無制限に増やさない。
- 確率はゼロと1を除く固定小数点整数で表し、初期案は15bit精度。更新率の異なる少数モデルの混合を比較する。丸め・飽和・オーバーフローを全CPUで一致させる。
- `High`は軽い混合、研究用`Max`は追加文脈と探索を試す。profile名と具体値はベンチマーク後に確定する。
- 直接文脈符号化経路は、LZ tokenを作らず同じ入力を文脈モデルで予測する候補。初期はorder 0/1/2/4/8とrun予測の小さな集合に限定する。エンコーダーとデコーダーが同じ更新を行う。
- 単一状態rANSと分割journalを研究backendへ実装した。適応modelを維持して復号を短縮したが、journalの追加メモリと圧縮時間の差が残る。rANSの複数状態による高速化や主方式への採用は未決定。

range coderのcarry処理、正規化、終端、確率更新式、混合表は次工程の**保存形式仕様**で具体化し、独立実装とgolden vectorで固定する。本書はその代わりになるbit単位の規格ではない。

### 2.5 可逆変換

変換なし、整数列のdelta、x64/ARM64コードの分岐アドレス変換を候補とする。変換の追加は元データとの完全一致試験を先に通す。

元データを完全復元できる変換だけを採用し、モデルID、パラメーター、例外情報の保存費用を含めて比較する。JSONの再整形、文字コードの正規化、画像や音声の再エンコードは行わない。ファイル境界で変換状態をリセットし、その境界を復号側にも伝える。

初期の実装・比較は変換なし。変換の効果を基礎codecの効果と混ぜない。7-Zipの実用設定と比較する際は、相手側の標準フィルターも有効にする。

## 3. 現代CPUでの実行設計

- x64はscalarを基準とし、AVX2を実行時検出して一致比較へ使用する。ARM64はNEONを使う。AVX-512は必須にしない。
- SIMDは範囲内の比較とハッシュ計算に限定して開始する。バッファ端を越えるロードは禁止。scalarと全経路で同一の結果を要求する。
- 圧縮候補・group単位にスレッドを割り当てる。同一groupの小blockを無条件に独立化し、辞書を捨てる並列化はしない。
- 同一groupの候補は読取専用の入力スナップショットを共有するが、辞書索引と確率表は候補別。共有によるメモリ削減と重複作業の削減は実測で確認する。
- 単一groupの適応レンジ復号は基本的に逐次。高速な並列展開には独立groupが必要で、圧縮率との交換条件になる。SIMDでこの依存を消せるとは仮定しない。
- 再現性モードは固定探索回数・固定tie-break・固定group順序を使う。時間制限モードはCPUと負荷で出力が変わり得るため区別する。どちらも復号結果は一致させる。
- GPU、ネットワーク推論、大規模学習モデルを必須にしない。通常のCPUとメモリだけで復号できる。

## 4. メモリとキャンセル

APIでは`memory_budget_bytes`、`max_decode_memory_bytes`、`workers`、`max_group_bytes`、探索予算、入力・出力上限を別々に指定する設計とする。既存の`Limits.max_entry_bytes`をメモリ予算の代わりにしない。

概算は次式で事前予約する。

```text
M_total = M_input_cache + M_manifest + M_output_queues
        + Σworkers(M_dictionary + M_dense_index + M_sparse_index
                 + M_context_tables + M_beam + M_candidate_buffers)
```

各配列の実要素サイズ、容量の丸め、allocatorの余裕を計上する。例えば32bitの前位置配列だけでも辞書1バイトにつき4バイトになる。辞書1 GiBを「メモリ1 GiB」と案内しない。

入力スナップショットと候補出力はメモリ上限を超えたら検査済み一時ファイルへ退避する。ページキャッシュとファイルマッピングも計測し、RSSだけを見て予算内としない。退避I/O時間をベンチマークから除外しない。

予算不足ならworker数、候補並列数、辞書サイズの順に下げ、実際の値を報告する。指定された最低条件を満たせなければ開始前にエラーとする。復号側では宣言値だけを信用せず、形式パラメーターから必要量を再計算して確保前に拒否できるようにする。

キャンセル点は入出力chunk、索引構築のbatch、一致探索の比較予算、parse位置のbatch、range coderのsymbol batch、候補の切替、公開直前。長い一致比較の内部にも入れる。制御可能な処理でp99 100 ms以下の応答を目標とするが、OSのブロッキングI/Oの時間保証とは分ける。

## 5. 保存形式と既存LZHの境界

KHCは別コンテナ・別magicとし、`-lhx-`、LH10、LH4〜7の識別子を流用しない。拡張子は未予約の仮称`.khc`とする。既存LHAデコーダーでの展開互換性はない。UnLhaReへの統合時はcodecと書庫形式の選択を別にする。

初期フレーム案:

| 部分 | 必須情報 |
| --- | --- |
| 固定ヘッダー | 固有magic、形式版、必須feature、ヘッダー長、ヘッダー検査値 |
| マニフェスト | 元の項目順、正規化名、長さ、時刻、group IDと復号位置。メタデータサイズにも上限 |
| groupヘッダー | 元サイズ、本文サイズ、辞書・モデル・変換のIDと全パラメーター、復号メモリ算出情報 |
| coding block | token数、圧縮／非圧縮長、方式、モデル状態の継承／reset、payload、破損検査値 |
| 終端と索引 | groupのoffsetと長さ、ファイル境界、元データのSHA-256、完了マーカー、索引検査値 |

整数はlittle-endian固定幅を基本とする。可変長整数を採用する箇所は最大byte数と非最短表現の扱いを固定する。ヘッダー長・offset加算・token数・距離・一致長を検証してから使う。MATCHの重複コピーは前方逐次コピーと同じ結果を要求する。

coding blockのstored切替でも履歴は入力バイトで更新する。確率状態は切替時にresetし、エンコーダーとデコーダーで明示的に一致させる。空入力・末尾の端数bit・ゼロ長block・未使用のpayload・trailing dataの規則を保存形式の凍結前に決める。

破損検査は認証ではない。暗号化・認証・SFX・追記更新は初期仕様の対象外。未知の必須featureやモデルIDは推測せず非対応エラーにする。書庫から任意の実行コードやモデルプログラムを読み込まない。

既存のno-follow、入力制限、検査済み親ハンドル内での一時作成、検査後のno-replace公開を引き継ぐ。group失敗時はそのgroupの未公開出力を破棄する。書庫全体の原子的展開を約束するものではなく、先に成功して公開済みのgroupの扱いも公開APIに明記する。

## 6. 7-Zipとの比較プロトコル

### 6.1 対象と固定条件

実行ファイルの版・SHA-256、OS、CPU、物理core数、ISA、RAM、電源設定、コンパイラー、git SHA、コマンド、スレッド数、辞書、solid設定、メモリ予算を記録する。`-mx=9`だけでは辞書・並列化の条件を固定できないため、実際の設定を記録する。

基準は当日確認できる安定版7-Zipを固定し、途中で更新しない。基本は7z/LZMA2、最高圧縮、辞書64/256/1024 MiB、1/2/物理core数スレッドのうち同一メモリ予算で実行可能な組合せ。KHCだけに大きな辞書や追加時間を与えた比較は別枠にする。

比較は2系統に分ける。

1. **codec比較**: 同じバイト列・同じ境界・変換なし。形式ヘッダー込みとpayloadのみを両方報告する。
2. **実用書庫比較**: 同じファイル集合・メタデータ要件。双方に並べ替え・solid・標準フィルターを許可し、最終書庫サイズで比較する。KHCだけsolidにする比較は不可。

7-Zip側の探索候補は事前登録し、入力ごとの最小サイズを基準にする場合は候補探索の全時間も同条件で集計する。単一設定同士の速度と、複数試行から選んだ最小サイズを一つの結果として混ぜない。LZMA2に勝っても7-Zip全方式に勝ったとは言わず、テキストでは7z/PPMdも補助比較する。

### 6.2 評価データ

開発用と未使用holdoutをファイル系列単位で分離し、manifestとSHA-256を固定する。同じデータの別圧縮版を両方へ入れない。

- 公開の混合コーパス: Silesia等。入手元と利用条件を確認してから取得する。
- UTF-8日本語・英語の文章、JSON、XML、ログ、ソースコード。
- x64/ARM64の実行形式、数値配列、DBの公開fixture。
- 大きい単一ファイル、微妙に異なる多数の小ファイル、空ファイル群。
- JPEG/PNG/動画/既存書庫、疑似乱数、短周期・長周期の反復。圧縮できない入力も除外しない。

ユーザーの私的ファイルは許可なくコーパスへ転用・公開しない。ランダムや反復だけの人工データの勝利を汎用圧縮率の達成としない。

### 6.3 計測と合否

各条件はwarm-up後に最低5回、実行順を交互化して測定する。wall time、CPU time、圧縮／展開のMiB/s、peak RSS、commit、退避I/O量を保存する。長い実行は温度とclock低下を記録し、同時に他の高負荷試験を走らせない。

同等の入力で圧縮サイズ、圧縮時間、展開時間の比を`KHC / reference`として記録する。空ファイルなど分母が0になるpayload指標は別扱いとし、最終書庫サイズでは必ず計上する。カテゴリ別、全体、中央値、幾何平均、最大の悪化を報告し、良い結果だけを抜き出さない。

元のSHA-256と展開結果が全件一致しなければ性能評価を無効とする。異常終了・メモリ超過・timeoutを結果から黙って除外しない。圧縮率の判定と速度・メモリの判定を分け、全項目を通過した場合だけ総合性能目標の達成を宣言する。

現在のローカル確認: AMD Ryzen 5 7640HS、6core/12thread、x64、物理RAM約25.8 GiB。通常インストールの7-Zipは見つからなかったため、公式26.03のportable x64実行ファイルをSHA-256確認後、専用buildディレクトリで使用する。このPC一台の結果をARM64/macOSの結果として扱わない。

## 7. 実装・採否の順序

| 段階 | 成果物 | 次へ進む条件 |
| --- | --- | --- |
| A | 形式案、scalar参照decoder、range coder、golden vector | bit単位の仕様と独立実装が一致。未凍結形式を配布用途に使わない |
| B | LZ、単純parse、stored fallback、資源予算 | 全入力のround-trip、割当上限、キャンセル、破損入力拒否を確認 |
| C | 二層索引、beam parse、反復コスト推定 | 標準経路からのサイズ改善を実測。時間・メモリの増分を記録 |
| D | solid、可逆変換、直接文脈符号化候補 | 各機能を外した比較で独立した寄与を確認 |
| E | AVX2/NEON、候補並列化、group並列化 | scalarとの一致、thread数変更の契約、Windows/macOS両ISAで測定 |
| F | 7-Zipとのholdout比較、保存仕様1の凍結 | 目標未達なら研究版のまま。実測に応じて設計を変更 |
| G | Rust/C/.NETと製品への統合 | 旧形式との識別、上限・途中失敗・公開契約、移行案内を検証 |

実装予定の責務は`codec/khc/{matchfinder,parser,model,range,encoder,decoder}`と専用container層に分離する。初期は実験用の別入口を使い、既存LHAの`Method`に仮番号を追加しない。現行のAPI level 6や配布版1.0.4へ未完成codecを混入させない。

サイズ改善が僅かでCPU負担が大きい機能、特定コーパスだけで勝つ機能、メモリを増やすだけで勝つ機能は採用を再検討する。LZ経路が基準を越えられない場合は直接文脈方式を評価し、双方が未達なら未達と報告する。

現在はA/Bのscalar試作を基点に、Cの一部（rep4・short rep・費用付きlazy parse・matched literal・有限beam・区間内暫定parseによる価格モデル学習・5-byte rootのBT5 matcher・幅2の疎Rep境界・境界外の第2親省略・`extend_match` inline化・BT5内側ループの不変条件hoist・range encoderのchecked/unchecked分離・branchless確率更新）とDの直接文脈候補を比較している。BT5/W2/B4096は固定開発solid groupで483,071 bytesとなり、最新同runの7-Zip 483,599 bytesを528 bytes下回ったが、圧縮中央値は1,376.3174対674.6334 msで約2.04倍遅い。変更前固定binaryとの11入力×5対ではencode合計を約8.0%短縮し、全frameを一致させた。総合差は依然大きい。これは単純な二層索引や完全LCP構造ではなく、長さ4の通常Match、一部のRep長、第2親経由の一部経路を失い得る近似である。mode 2は仕様から作った独立scalar decoderと照合した。実符号長を使った反復改良、完全な二層索引/LCP問い合わせ、完成solid書庫、SIMD、複数OS/ISAでの検証、資源予算のOS実測、holdout合格、製品API統合は未完了。試作の入力上限は64 MiBで、最終仕様の容量や達成条件をこの値へ縮小しない。[開発比較](experiments/khc/DEVELOPMENT.md)の部分的改善を合格扱いにしない。

同じB4096固定binaryの幅1は486,780 bytes / 1,292.50 msで、7-Zipの483,599 bytes / 669.54 msへサイズ・速度とも届かなかった。さらに、Warmとbeamが同じRep状態へ再合流する短区間だけを理想的に移植するprofile oracleでは、64-byte以下の修復が概算品質差の1.63%、block全長4096まででも46.64%しか回収できなかった。672 block中601 blockは末尾まで状態が異なる。従って第2状態の除去やWarmの短い局所修復を主な速度解として採らず、幅1にも残る全位置展開・Rep照合・BT準備の計算量を対象とする。

同長一致について近距離と推定価格優先を比較する研究設定も追加した。価格優先は合計サイズをさらに766 bytes縮めた一方、価格再利用後でも同時期の近距離優先比で圧縮時間が約13%長い。これは状態別のrep4や将来予測を含まない局所近似である。比較候補としてのみ保持し、既定の候補保持方針や保存形式は変更しない。

続く区間計測では状態展開と一致探索の負担が大きかった。保持候補が満杯で新候補の費用が現存の最大費用以上なら、同一状態の更新にも別状態の置換にもならないため、状態比較前に除外する。この出力不変の早期除外は旧処理との全フィールド照合と全11 frameのhash一致を通過し、KHC内部時間を約13%削減した。旧処理でも不採用となる候補だけを省くもので、探索幅や候補集合の削減ではない。研究用計測のinclusive時間と7-Zip比較のCLI時間は分離する。

さらに8 byte一致比較の不一致位置をLE整数のXORと末尾ゼロbit数で取得し、byte単位の再走査を省いた。論理比較予算・callback位置・候補列はscalar参照と一致し、通常CLIのLz/Nearest/PricedTieの全11出力も旧候補と同一。内部圧縮時間は観測した開発集合で約5.6〜6.8%短縮したが、通常CLIでの7z比はまだ約9.77倍であり、全体目標の合格ではない。

最長matchの最大長edgeを二度挿入していた処理も、旧処理との状態・計画・出力同値を確認して一度へ減らした。固定した旧実行ファイルとの交互比較では内部圧縮時間が約1.2〜1.8%短縮した。これは探索の削減ではなく同一edgeの重複計算の省略であり、圧縮率や要求容量式は変わらない。この段階の通常CLI比較でも圧縮時間は7z/LZMA2の約9.76倍だった。詳細と個別の悪化例は開発比較に記録し、7-Zip超えの合格とは扱わない。

次にbeam表の保存値だけをchecked u32表現へ変更し、1 nodeを80→48 bytesへ縮小した。費用はu64、計算用状態とdecoderはusizeを維持する。既定beam追加要求容量は65,664 bytes減り、固定旧版との交互比較で内部時間は近距離優先約3.61%・価格優先約1.10%短縮した。旧出力・候補順・探索範囲は不変。この段階の通常CLI圧縮時間比は7z/LZMA2の約9.50倍だった。nodeの40%縮小はプロセス全体のピークメモリ40%減を意味しない。CLI復号検証は両codec共通のSHA-256 sinkへ移し、不要な復元コピーを増やさずに検証する。

同じ位置のbeam状態間でliteral payload価格も共有した。予測byteとの共通prefix長0〜8と予測不能を分離した固定80-byte cacheで、前状態依存価格は各nodeで加算する。元の式・旧出力との一致を検証し、固定旧版との交互比較で内部時間を約1.63〜2.66%短縮した。最新の通常CLI圧縮時間は7z/LZMA2の約9.09倍で、圧縮率も個別payloadでは2勝9敗のまま。開発集合の局所改善であり、総合目標は引き続き未達である。

このliteral payload価格は凍結modelのblock内なら`previous_byte >> 5`、現在byte、共通prefix keyだけで同値になるため、位置単位80-byte表を20,480要素の`u16`表へ拡張して位置間でも共有した。要求容量は40,960 bytes増えるが、W2/B4096の固定旧版との5対で3.73%、W4で1.91%短縮し、全frameは一致した。完全同値な価格memo化であり、総合目標の達成ではない。

距離価格も凍結modelのblock内では、slot木＋全footer 0のbaseと4-bit単位の価格差部分和へ正確に分解できる。4距離文脈×32 slotと4×8×16 nibble値を1,536-byte表へ保持し、footerのbit単位走査を最大7 lookupへ置換した。最終exeの固定対照5対はW2/B4096で5.23%短縮、48/55勝、全frame一致。native solidは482,989 bytes / 1,199.65 msで、同runの7-Zip 483,599 bytes / 586.24 msより圧縮率は良いが約2.05倍遅い。W4の先行測定は合計0.37%短縮に留まり一部入力が悪化したため、全設定の速度保証ではない。

B8192はB4096より探索区間を広げる一方、境界処理とmodel学習の回数を減らす。同一最終binaryの交互5対では合計2.27%短縮、26/55勝、入力別平均6/11勝、個別frame合計3 bytes減となった。反復別合計は4/5で短縮し、native solidも335 bytes縮小したため研究基準へ採用した。最大区間に伴いRep境界表を852,072 bytesへ、固定作業枠を5 KiBへ拡張して要求容量へ計上した。wire、decoder、研究既定512、製品APIは変更しない。

続く幅別const generic化は旧出力を保ったが内部時間を4.43〜7.79%悪化させ、chain上限256→64はpayloadを3,701 bytes悪化させてLZMA2にも負けたため、いずれも撤去した。最良長byteによる高速拒否も旧出力を保ったが大幅に遅く、撤去した。プロファイルでは一致探索とnode展開が支配的だが、候補を単純に減らすこと、コードを幅別複製すること、hot loopへ追加の価格判定を入れることを速度達成の代用にはしない。

Warm/Blended暫定parseと本beamの重複探索は、最長更新・同長候補だけの小型traceで再利用した。位置・辞書・探索上限の完全一致、取消確認回数の再生、通常探索へのfallbackを条件とし、旧frame、候補順、探索予算、取消結果を維持する。固定旧版との交互比較では内部時間をNearest約1.14%、PricedTie約4.86%短縮した。既定区間のtraceは約1.012 MiBを追加し、通常CLIの圧縮時間は7z/LZMA2の約8.66倍。追加メモリとの交換であり、個別payload 2勝9敗、holdout等の総合目標は引き続き未達である。

node挿入内の3走査を1走査へ統合する案も旧出力を保ったが、固定trace版比で内部時間を6.45〜10.13%悪化させたため撤去した。支配区間に属する処理でも、幅4の短いiterator走査を追加分岐のある手書きloopへ置き換えること自体は利益にならない。

edgeごとの位置除算を外側へ移す案も旧出力を保ったが、同じ交互比較で0.25〜3.86%悪化したため撤去した。除算や構造体fieldがソース上で消えたことだけを高速化の根拠にはしない。

距離価格cacheの衝突走査を最大64枠から4枠へ制限し、miss時は正確な価格再計算と置換を行う変更を採用した。追加メモリなしで固定trace版との5対交互比較は内部時間を約1.79〜2.06%短縮したが、個別入力では最大7.90%悪化もある。frameは旧版と同一。7-Zipとの新しい直接比較は未実施で、総合目標は未達のままである。

## 8. 根拠と未確定事項

研究分岐のBWT rank/run＋因果Bayes/CTSは固定開発groupで483,468-byte全frameとなり、size gateのみ通過した。循環prefix-doublingの同値高速化に続き、CTSのwide quotientを正確なx64 DIVへ限定した案は、独立23,608数値ケース・全codec36 checks/61 CLI・最大batch8 checks/8 CLIを通過。凍結fast-BWTとの別session9対比較2回でpaired中央値6.12%/7.88%短縮し、局所研究基準へ採用した。しかし最新full encode中央値3,481.27 ms対native7z604.65 msで、固定strict<574.5624 msは未達。総合7-Zip超過、holdout、製品統合、macOS/ARM64 native検証の証拠ではない。通常LZ経路と区別し、正確な境界・ソース・全frame SHA・測定/清掃証拠は[開発比較](experiments/khc/DEVELOPMENT.md)に記録する。

現exact-divから別EXEの区間診断を取り、payloadの経過時間share中央値70.15%、BWT29.68%を確認した。BWTだけの短縮では固定時間へ届かないため、別研究magicのf64 CTSを実装し、全codec38 checks/63 CLIと独立decimal oracle40 checks/40 CLIを通過した。固定全frameは同じ483468 bytesだが、初回性能測定は他buildとCPU100%で競合しており通常性能の採否には使わない。新しい静穏性guard付き比較は未完了、float採用は保留し、exact-divを研究基準として維持する。数値モデル同値・cross-platform決定性・総合勝利の証拠ではない。詳細と清掃は[開発比較](experiments/khc/DEVELOPMENT.md)の区間診断節へ保存した。

続いて、確率モデルを変えずcomponent Q15尤度のlog2をstream所有256KiB表へ置換する別案を実装した。全Q15値の両bitを含む数値52 checks/52 CLIと全codec36 checks/61 CLI・独立照合を通り、固定全frameの同一SHAを保った。静穏preflightは競合CPUで拒否され、39 CLIの性能比較は未開始。表構築時間・追加メモリを含む採否は保留、研究基準のexact-divと固定条件は維持する。

CTSの等値短絡が使える頻度は固定fixture集計で約3.7%だったため、等値だけのbranchではなく全混合を厳密同値のsigned 1乗算へ変える別候補を実装した。負deltaを含む最大65536件の独立BigInteger数値20 checks/20 CLI、全codec36 checks/61 CLI・別担当のraw/CRC照合がPASS、固定全frameの同一SHAも維持した。頻度/乗算数は速度改善率ではなく、静穏性能比較前の採用は保留する。log2表/floatと組み合わせず、exact-div研究基準・固定gate・総合勝利未達を維持する。実行証拠と所有範囲追補は[開発比較](experiments/khc/DEVELOPMENT.md)へ保存した。

さらにBWTだけを独立SA-IS構築へ置換した候補を検証した。129小入力の直接suffix oracle、8MiB反復/周期を含む147 checks/301 CLIと全codec36 checks/61 CLI、別担当の全raw/CRC/metadata照合がPASS。モデル/全frameは同一で、この採用比較ではsigned/log2/floatを組み合わせていない。途中CPU拒否2sessionは失敗として保持し、時間経過後の新sessionで元guardのまま通常9回・39 CLI・初回最終復元を完了、全raw/統計の独立照合もPASSした。encode中央値2543.9207ms、凍結exact-divとの対応round比中央値0.7606804（約23.93%短縮）を根拠にSA-ISを次の研究基準へ採用する。全書庫483468Bはsize条件を通過するが、strict574.5624ms未満は未達。working peakは減少、sampled privateは823296B増加。単一開発corpus/sessionの研究採用で、製品採用・総合7-Zip超過ではない。固定gateは維持し、検証結果と再開地点を[開発比較](experiments/khc/DEVELOPMENT.md)へ残す。

再開後はSA-IS研究基準に対する一変数として、既存の数値同値確認済みBayes対数表を参照する別候補を作った。全codec36 checks/61 CLIと独立raw/CRC/11metadata照合を通り、同じ全frameを維持した。追加256KiBと表初期化を含む正常9回性能はpreflight CPU23%で拒否され未測定。候補は採用保留、研究基準はSA-ISのまま、float/signedは足していない。旧SAIS比較の同一中間36files/17406420Bだけをreceipt付き清掃、初回最終/入力/復元/proofと元reportを保持した。

再開ではSA-IS基点のCTSを固定Q32/u64へ変える別研究仕様を作成した。旧posteriorの単純精度縮小には重み越境の整数反例があるため、観測側ceiling分母を仕様化し、入力grammarから全u64算術の支持範囲を照合した。Q48同値や実数CTS保証は主張しない。独立BigInteger数値43 checks/43 CLI、全codec38 checks/63 CLIが成功し、固定全frame483469Bでsize gateを通過した。独立指摘の生成証拠readlock不足を補強し、全codec再実行と全raw/CRC/pinsの再監査も成功した。比較入口の静的監査後、開始前5観測は通過したが最初のCLI起動前CPU65%で拒否、圧縮性能samples0。通常性能未測定のため採用保留、研究基準SA-IS・固定条件・総合未達を維持する。詳細の契約・SHA・再開地点は[開発比較](experiments/khc/DEVELOPMENT.md)に保存する。

Q32の可変分母除算を、binary64商推定とchecked整数補正・残余証明に置換する別候補を追加した。証明できない商は元整数除算へfallbackするためモデルの近似化ではない。有限30937件の独立BigInteger数値E2Eと監査を通過し、codec組込みは46 checks/72 CLIで元Q32との7小fixture・固定全frameの全byte一致、別ビルドの相互復号を確認した。固定全frameは483469Bのまま。旧Q32との同形式対照とnative7-Zipの正常比較は独立監査後のpreflight CPU20%で拒否、normal samples0。速度・4環境・総合性は未検証、研究採用は保留する。詳細は[開発比較](experiments/khc/DEVELOPMENT.md)へ保存する。

商補正Q32を対照として、有限Q15のBayes対数表を加える一変数候補も検証した。既存全Q15両bitの保持rawを現在値照合し、新codec55 checks/82 CLIと独立source/raw監査はPASS、元Q32・商補正と同じ483469B全frameを維持する。通常比較はpreflightとround0〜8を通過したがround9候補encode後CPU29%で拒否、failedとして保存。全9回のmedianや採用結果は生成せず、部分時間を採用に使用しない。追加262144Bと表構築を全CLIへ含める条件は不変。性能・4環境・総合性は未判定、SA-IS研究基準を維持する。

凍結EXEの商処理が非inlineで残ることを確認し、数値仕様と整数残余証明・fallbackを維持したinline候補を追加した。全codec63 checks/106 CLI、旧LUT候補との7小fixture＋固定frameの全byte一致・双方向復号と独立監査を通過。最初の測定はCPU32%で失敗したが、ユーザーの静穏通知後の別sessionでは全9回比較が完了し、全83負荷観測は最大14%だった。同Q32+LUT対照に比べ同round時間比median0.85867（約14.13%短縮）、全CLI中央値は3361.9536ms、native7zipは626.6201ms。全書庫483469Bを保つが、native比は約5.40倍遅く固定速度gate未達。これはinlineの局所効果で、Q32・LUT単独効果や総合優位、4環境、製品採用を示さない。SAIS Q48基準との同session比較も未実施のため全体最良基準へ昇格しない。正常結果の追加独立監査もPASSし、全9回/全archive/初回最終復号/SLT/pins/median再計算を照合した。詳細は[開発比較](experiments/khc/DEVELOPMENT.md)へ保持する。

次に商の分子がsigned64範囲の場合だけsigned float変換へ切り替える候補を作った。56191境界入力の独立BigInteger数値E2E、opt2/3反復、異常拒否、独立商・flags監査は通過した。ただし凍結数値CLIの生成コードではsigned/unsigned両cast候補を計算後に選択し、狙った変換省略にならないため、この形のcodec組込みを保留した。数値正確性と計算削減を区別し、wide推定を非inline helperへ分離する次案を評価する。速度未測定、既存研究基準・固定gate・総合未達は維持する。証拠と推論範囲は[生成コード診断](experiments/khc/Q32_SIGNED_ESTIMATE_CODEGEN_20261001.md)へ保持する。

wide推定を非inline helperへ分離した次候補は、旧数値56191件の商/flags同bytesと独立監査を通過し、実codecでもsmall側がwide変換を実行しない生成構造を確認した。codec71 checks/130 CLI、旧版との全frame一致・相互復号と独立raw/pins監査も通過、全書庫483469Bを維持する。ただし正常比較は開始前5観測を通過後、round3候補の起動前CPU17%で拒否された。全9回未完のため速度・採用は未判定、部分値から改善率を算出しない。固定gateとSAIS Q48研究基準を維持し、次はpredict/update間の重複計算の厳密な省略可能性を調査する。総合7-Zip超過、4環境、holdout、製品統合は未達である。

- [7-Zip LZMA SDK](https://www.7-zip.org/sdk.html): 比較対象のLZMA/LZMA2、辞書、整数演算の復号についての一次資料。KHCの優位性を示す資料ではない。
- [7z形式](https://www.7-zip.org/7z.html): 複数方式とコンテナの区別の参照。
- [ANS原論文](https://arxiv.org/abs/1311.2540): エントロピー符号化候補の原理。rANSの採否やKHCの速度は未検証。
- [ZPAQ原作者の資料](https://mattmahoney.net/dc/zpaq.html): 文脈方式やsolid以外の設計を比較する参照。コードやVMを採用する決定ではない。
- [lzbench](https://github.com/inikep/lzbench): 圧縮／展開とサイズを同時に測る参考実装。書庫I/O・メタデータの実測は別途必要。

方式の基本構成、資源管理、評価と撤退条件は本案で決めた。最小試作のbit単位仕様は[実験仕様](experiments/khc/README.md)に分離した。製品の保存仕様、最終パラメーター、holdoutでの優位性は未確定である。設計完了とcodec実装完了、さらに性能目標達成を区別する。

Q32のpredict/update間で混合分母を再利用する候補は、weight snapshot一致時だけcached整数分母、不一致時は元計算へfallbackする。65536数値入力と11267実Model観測の独立oracle照合、codec79checks/154CLI、旧splitとの全frame一致・双方向復号と独立監査を通過した。固定frame483469Bは不変。実EXEで同weight側の分母用weighted_sum call省略を確認し、増加したPrediction544Bの費用も含む全CLI比較を完遂した。Windows x64の同session9回で新3075.1186ms、旧split3205.0955ms、native594.0059ms、同round比中央値は旧比0.95005（約5%短縮）・native比5.22208。39CLI/83負荷観測（最大13%）・全archive/復号/pins/中央値の独立追跡もPASS。局所改善であり固定速度gateは未達、SAIS Q48基準との同session比較やholdout、4native、総合7-Zip超えは未証明。詳細と清掃receiptは[開発比較](experiments/khc/DEVELOPMENT.md)に保存する。

次にCTSの等カウント状態だけ、合計overflow・観測cap検査後に厳密Q/2を返す短絡を追加した。直接KT65536/helper65536/Model11267の独立BigInteger照合、87checks/178CLIと旧79checks包含、全frame483469B一致・相互復号・公開安全性と独立監査を通過した。人工数値dataset中の等カウント割合は実書庫のhit率ではない。通常EXEの生成コード・同session速度比較は後段で評価し、追加分岐による悪化も棄却条件に含める。粗粒度phase診断は別quiet intervalでも開始前CPU23%で拒否され、CLI/phase0のためコスト内訳は未取得である。既存研究基準・固定gate・総合未達を維持する。

等カウントKTの実EXEではroot/後続16levelともoverflow/cap後に商経路を迂回する構造を確認したが、正式比較はpreflight CPU31%で拒否されsamples0。速度採用しない。別cfgの整数件数診断は7622618bitを実処理し、3frame/復号/公開安全性のE2Eと通常source対応を確認した。balanced KTは129584506計算中1.296841%、半重みのposterior identityは121961888計算中3.613093%だった。割合を所要時間削減率へ変換しない。次は既存next_weightのshift化済経路や少数条件の短絡を増やす前に、商u32境界を検査した64/32整数経路を数値だけで反証する。ISA限定の仮説であり速度・ARM64・総合性を証明していない。

guarded64/32商の実装は、数値46checks/49CLI（65536境界＋旧56191records）、Model57checks/54CLI（凍結独立oracle/11267records/4EXEs）、全codec34checks/57CLI（旧/通常/portable全frame・復号・相互互換・代表破損・no-clobber）まで進んだ。source対応/current hashes/layout/商・実残余・errorを保持し、固定frame483469Bも不変。通常codec実EXEにhigh32 guardとdivlの迂回経路を確認したが、人工数値hit率は実書庫hit率ではない。新しい独立作者監査、旧87項目の再監査、速度、ARM64/macOS native、holdout、製品統合、総合7-Zip超えは未証明。固定gateを維持して同session性能比較へ進む。証拠・失敗と修正の境界は[開発記録](experiments/khc/DEVELOPMENT.md)に保存する。

native32の同session比較は旧計測処理と全参照検証を保持して実装したが、warmupのnative一覧後CPU41%で失敗し、9回測定は0。guard・15%基準を緩めず採用しない。別方式のCPU二点差でも6区間すべて基準超えを確認し、formattedカウンターの不具合と断定する案を退けた。速度の結論は保留し、次は検査済みKT式の既知high/low register形状が現在EXEで既に最適化済みかを調べる。未検証候補や実装前の数学条件を7-Zip優位性と混同しない。

KT register形状は実EXEで既に専用divlへ折り畳まれていたため追加案を棄却した。次のexact reciprocal table候補は、実書庫のKT商計算127904001中77604411（60.67%）に小分母域が該当すると、通常source/全frameを保持するcfg件数E2Eで確認した。KT限定n<Q*d・d<=sqrt(Q)の証明により補正を要さず元floorを保持でき、新helperの36checks/42CLI（全d2..65536の境界・中間327675records＋旧KT65536等）で独立oracleの商/error/reciprocal一致を確認した。table枝の実high multiplyも確認したが、共有tableのModel接続・524296Bの構築/lookup/cache/peak memory費用・実速度は次段階。総合7-Zip超えは未証明、固定gateとquiet条件を維持する。

KT reciprocalはModel1個につき表1個を所有する実装へ接続し、Model62checks/59CLIと通常codec34checks/57CLIに成功した。元の予測値・更新・KT error順・書庫483469B・復号は全byte一致し、Node/Prediction layoutを保持した。通常EXEのtable枝も除算ではなくhigh mulqになったが、追加524296Bの初期化/cache費用を含む速度は未判定。固定比較はCPU preflight14%→19%で開始前に停止し、warmup/測定0なので改善率も7-Zip優位性も採用しない。ガードを維持し、holdout・4native・製品・総合性能の未達を保つ。[統合証拠と停止記録](experiments/khc/Q32_KT_RECIPROCAL_INTEGRATION_RESULT_20261001.md)に結果と再開条件を残した。

逐次Lazy LZのliteralだけにorder-2 expertを混合した研究cloneは、固定group531353B→523081Bと8272B縮小したがsize gateを39482B超過し不採用。有限CLI検証45checks/65CLIに成功しても速度や総合優位性は示さない。Beam/RANS非対応・追加model storage524288B・別研究magicを製品へ混入させず、設定sweepや速度測定は行わない。[結果・検証範囲・清掃記録](experiments/khc/LZ_LITERAL_MIX_RESULT_20261001.md)を保持する。

ユーザーの低負荷報告後のKT reciprocal別root比較は、preflightを通過し全proof/current/after照合へ到達したが、candidate warmup復号後のCPU27%で不採用。9測定0なので速度比を推定しない。固定frameと復号hashを保持し、guardと総合未達を維持する。[実行・失敗・保持範囲](experiments/khc/Q32_KT_RECIPROCAL_QUIET_HOST_2155_RESULT_20261001.md)を記録した。

CTSを観測数で選ぶ単一suffix KTへ置き換える別形式候補は、1bitの17KT/16posteriorを1KTへ減らすsource構成を実装し、native/portable全frame・復号等34checks/44CLIを通した。ただし固定書庫488592Bはgateを4993B超過し不採用。計算式数削減を速度や総合優位性へ換算せず、閾値調整・性能/holdout測定はしない。[一構成の契約・結果・保持範囲](experiments/khc/ADAPTIVE_SUFFIX_KT_RESULT_20261001.md)に保存した。

旧CTS/新suffixを変えない整数Q15 histogram診断は、元frame/encode反復/decode histogram/旧新primaryの全byte一致を17checks/13CLIで確認した。今回入力の圧縮率低下の近似loss差は99.1933%がrank mantissaへ集中し、他5classesではprimaryが両context expertより強かった。観測class0/3の固定routingは採用せず、prefix利得で重いexpertを止め、再開時に未処理履歴をreplayする因果的制御を次の未実装仮説とする。速度・一般化は未証明。[診断結果と次の支持範囲](experiments/khc/SUFFIX_CLASS_ENTROPY_RESULT_20261001.md)を保持する。

その因果的制御を新magicの独立研究codecに実装し、50checks/63CLIと固定frame483496B（gateより103B小さい）を確認した。heavy処理は7622618event中3223156へ減るが、light/journal/replayを含む実速度は別判定。連続heavy参照とのactive Q15一致は有限比較であって全state oracleではない。正式比較はpreflight成功後の7za起動前CPU17%で停止、warmup/速度samples0。ゲート/quiet条件を保持し通常候補をcorrectness/size証拠だけで保留する。[実装結果](experiments/khc/CAUSAL_EXPERT_SCHEDULING_RESULT_20261001.md)と[正式比較失敗](experiments/khc/CAUSAL_EXPERT_SCHEDULING_PERFORMANCE_RESULT_20261001.md)を分離して保存した。

次の幾何深度0/1/2/4/8/16CTSは、heavyのKT/混合/事後更新を6/5/5へ減らし、全16bit履歴のsuffix対応・57checks/69CLI/93identitiesを確認した。しかし484950Bは固定gateを1351B超過するためNO-GO。単純な深度間引きの構成を採用せず、設定sweepや速度測定を行わない。計算式数やstorage削減を時間/総合優位性に換算しない。[構成、harness修正境界、結果と清掃](experiments/khc/SPARSE_DEPTH_CTS_RESULT_20261001.md)を保持し、符号化event数やdense context学習の別構造を次の未実装検討領域とする。holdout/カテゴリ・同境界decode/資源・4native・製品を含む元の総合goalは未達。

17段を維持したQ16/min alpha1の別形式は、正常posteriorの分母を48bit exact reciprocal表で処理する構成として実装した。918707recordsのu128直接oracleとnative/portable全byte、59checks/71CLIの有限codec E2Eは成功。ただし完全frame483600Bは483599B上限を1B超えNO-GO。精度/alpha/headerの事後調整や速度測定へは進まない。既存担当の追跡確認は整数domain/等号/fallbackとsourceに不整合なしだが、全内部state・新独立作者・四native・実速度の証明ではない。[契約・結果・有限範囲と清掃](experiments/khc/Q16_DENSE_CTS_RESULT_20261002.md)を保持し、同精度Q32の可変分母をinteger reciprocal seed/refinementで処理する案を次の未実装仮説とする。固定gate・総合goalを維持する。




