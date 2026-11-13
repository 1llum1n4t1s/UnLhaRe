# LHC1形式仕様（開発版）

2026-10-20。実装はRust API `unlhare::lhc` とCLI `lhc-*`。LHA方式の追加・置換ではない。LHC＝LHA High Compression、旧称KHC。2026-11-13にmagicを旧`KHC*`から`LHC*`へ改めたため、旧称時代に作成した書庫・frameは読めない（`KRS*`・`KCS1`はKHCを含まないため据え置き）。既存LHA API/C ABI/.NET APIとpackage versionは変えない。既定`Mdl`はrevision 1を維持し、明示的なhybrid戦略はrevision 2、`RecordTrial`（`record-trial`）はrevision 3、`Gather32Trial`（`gather32-trial`）はrevision 4、`Delta16Trial`（`delta16-trial`）はrevision 5、`RecordFastTrial`（`record-fast-trial`）はrevision 6、`SpatialBitsTrial`（`spatial-bits-trial`）はrevision 7、`RecordAdaptiveTrial`（`record-adaptive-trial`）はrevision 8、`SpatialMdlTrial`（`spatial-mdl-trial`）はrevision 9、`PortfolioTrial`（`portfolio-trial`）はrevision 10、`PortfolioPpmTrial`（`portfolio-ppm-trial`）はrevision 11を作る。revision 1〜10の読取も維持し、未知のversionは拒否する。

CPUだけで自己完結して復元できる。外部モデル・辞書・学習環境・ネットワークは不要。浮動小数点はencoderの木選択だけに使い、選択した整数CDFを保存する。decoderは整数だけで動作する。異なるCPUでencoderが同じ符号列を作る保証はないが、保存したCDFで復号できる設計。4環境でのnative確認はWindows x64以外未実施。

## アーカイブ

多byte整数は、range streamの初期code以外little-endian。CRC32はISO-HDLC（反転多項式0xEDB88320、初期0xFFFFFFFF、最終XOR0xFFFFFFFF）。空列のCRCは0。CRCは改ざん防止や認証ではない。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `LHC1ARC` + NUL |
| 8 | 1 | revision=1〜10 |
| 9 | 3 | flags/reserved=0 |
| 12 | 4 | block limit=1,048,576 |
| 16 | 4 | entry count |
| 20 | 4 | manifest byte count |
| 24 | 4 | manifest CRC32 |
| 28 | 4 | header[0..28] CRC32 |

直後にmanifestを格納する。各entryは、名前長u16、kind u8（0=file、1=directory）、flags u8=0、元長u64、mtime i64、UTF-8名前byte列。mtimeはUnix秒へ切り捨て、i64::MINはunknown。directoryは元長0。名前長を含め固定部20B。manifestをentry count分正確に読み、余剰byteを拒否する。

名前はcanonical `/` 区切り、末尾slashなし。空、絶対名、`.`/`..`、`\`、制御文字、Windows特殊文字/device名、末尾dot/spaceを拒否する。名前最大32,000B、深さ128、Unicode lowercaseでの重複とfile/child衝突を拒否する（Unicode正規化の同一性までは保証しない）。全名前・entry/total長を展開先作成前に検査する。manifest上限4MiB、entry count上限100,000。呼出側Limitsでさらに制限できる。

fileは元長から決まるceil(size/1MiB)個のblockを順に格納する。各blockはu32 frame byte countと完全なframe（archive 1/2ではLHC1BLK、3ではKRS1BLK、4では下記のG32または非MDLのKRS、5ではDelta16、6ではKRS2BLKまたはLHC1 fallback、7ではKCS1BLK、8ではKRS3BLKまたはLHC1 fallback、9ではKCS1BLKまたはLHC1 fallback、10では下記のKCS1/KRS2/KRS3またはLHC1 fallback）。最後のblockだけ短く、他は1MiB。全file復元byteのCRC32 u32が続く。空fileはblockなし、CRC=0。directoryにはpayloadもfile CRCもない。全entry後に8B `LHC1END` + NULを置く。さらにbyteがあれば拒否する。別途index/共有dictionary/solid履歴はなく、blockごとに状態をresetする。

## 独立block

archive revision 1はblock revision 1だけを受理する。archive revision 2はblock revision 1/2を受理する。旧decoderはrevision 2を拒否し、新decoderは旧revision 1を受理する。method 0/1の意味は両revisionで同じ。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `LHC1BLK` + NUL |
| 8 | 2 | revision=1または2 |
| 10 | 1 | 0=stored、1=paid-static BWT rank/run、2=LZ3、3=LZ8（2/3はrevision 2だけ） |
| 11 | 1 | flags=0 |
| 12 | 4 | raw byte count（0..1MiB） |
| 16 | 4 | inverse BWT primary row |
| 20 | 4 | model packet bytes |
| 24 | 4 | range/stored payload bytes |
| 28 | 2 | alphabet symbol count（byte countではない） |
| 30 | 2 | reserved=0 |
| 32 | 4 | raw CRC32 |
| 36 | 4 | frame[0..36] + frame[40..end] CRC32 |

bodyはalphabet（u16×count）→model packet→payload。合計はframe extentに正確に一致する。storedはprimary/model/alphabet=0、payload=raw bytes。compressedはbody < raw（header40Bは両方式共通なので選択時にも含めて比較）、primary≤raw、alphabet count 2..257、model最低241B、range最低5B。非利益圧縮はstoredへ戻す。一般エラーをstoredで握り潰さない。encoderはraw≤250ではモデル最小費用からstoredを選ぶ。

method 2/3はprimary/model/alphabet=0、bodyはrange payloadだけ。payloadは5B以上かつrawより小さい。以下のBWT・保存モデル節はmethod 1だけへ適用し、range coderの整数演算・終端規則は全圧縮methodで共通。

### Revision 2のLZ token grammar

LZ3/LZ8は前byteの上位3bit/8bitをliteral文脈に使う。各blockで全確率p0=16384、前byte=0、前tokenのmatch状態=false、最近距離rep=[1,4,8,16]へresetする。確率総数32768、bit0のintervalは[0,p0)、bit1は[p0,32768)。復号後にbit0ならp0+=floor((32768-p0)/32)、bit1ならp0-=floor(p0/32)。浮動小数点・学習済み外部モデルは不要。

モデル配列base=(1<<context_bits)*256、全長base+20+2*1056。位置posのmatch flagはbase+(pos&7)+8*previous_match。flag0なら文脈previous>>(8-context_bits)の256要素bankでbyteのMSB順8bit treeを読む。binary treeのprefixは1から開始し、bank+prefixの確率を使ってprefix=2*prefix+bitへ更新する。

flag1ならbase+16のbitを読み、0ならbase+16をbankとして2bit treeでrep indexを読む。1なら新distanceをnumber class1で読む。続いてnumber class0の値+2をmatch lengthとする。numberのbankはbase+20+class*1056。まず5bit treeでlogを読み、log<=20を要求。値を1<<logで初期化し、下位log bitをMSB順にbank+32+log*32+bit_positionの各確率で読む。distance<=1MiB、length-2<=4094を要求する。

distanceは正で復元済みpos以下、lengthは宣言rawの残り以下を要求する。同じdistanceをrep先頭へ移し、未登録なら古い第4要素を捨てる。matchのbyteは距離分後方から1byteずつコピーし、重なりを許す。literal後はprevious_match=false、match後はtrue。前byteは直前に復元したbyte。raw byte countへ正確に達したらrange終端・消費長・raw CRCを検査する。各tokenは最低1byteを生成するため、token数はraw以下。

encoderは3byte hash、過去chain32候補＋rep4、match最大4096、byte比較総数64*rawまでのgreedy探索を使う。これらはencoder戦略で、decoderは探索しない。探索・確率符号化はLZ系既存技術の組合せであり、新しい圧縮原理や世界初とは主張しない。

### Encoder戦略と互換性

`BlockStrategy::Mdl`とCLI既定`--strategy mdl`は従来のrevision 1出力。`HybridTrial` / `--strategy hybrid-trial`はMDL、LZ3、LZ8を実際に実行し、40B header込みで最小frameを選ぶ。同点は先の候補を維持し、全試行費用を計測する。`BinaryAdaptive` / `--strategy binary-adaptive`は全rawを走査し、tab/LF/CR/ASCII32..126が90%以上ならMDL、それ以外はLZ8のみを試す。どちらも非利益時stored、選択frameをrevision 2として再封印する。

Rustの`compress_block_with_strategy`と`CreateOptions.block_strategy`で選ぶ。選択条件は復号側の入力ではなく、methodだけで復元できる。adaptive閾値は調整用データからの仮説で、未見データへの優位は未証明。trialは最小サイズを選んでもCPU費用が増えるため、7-Zip総合優位と同義ではない。

### 可逆変換とtoken grammar

raw各byteを1..256へ写し、末尾へ一意のsentinel 0を追加する。SA-ISでsuffix arrayを作りBWT last columnとprimaryを得る。last columnを同じsymbolの最大連続runへ分ける。alphabetはrun列でsymbolが初めて現れる順で、各symbolは一度だけ、sentinelを含む。sentinel runは必ず長さ1。

active listをalphabet順で初期化する。各runではhead symbolを出力対象とし、rank tokenとlength tokenを読む。rankは次回使用時の挿入位置、0は今後使用しない。headを除去し、rank≠0なら残ったlistのrank位置へ戻す。length token 0..254は長さtoken+1、255は長さ256+escape。escapeはuniform byte CDF（total256）で符号化した最短unsigned base-128 little-endian varint、bit7が続き。escapeは3byte以内、残り出力長以内、冗長な末尾0を拒否する。全run後にactiveが空で、raw+1 symbolをちょうど生成し、alphabetの初回出現順も一致する。

rank tree alphabet=257、length tree alphabet=256。Treeはdepth-first preorderでnode IDを割り当てる。区間[lo,hi)でlo=0ならcuts=[0,1,2,4,hi]、lo=4かつhi=alphabetなら[4,8,16,32,hi]、lo=32かつhi=alphabetなら[32,64,128,256,hi]。他はn=min(hi-lo,4)としてcut_i=lo+floor((hi-lo)*i/n)。空区間を除去し、幅>1のchildを再帰構築する。実limitよりloが小さいedgeのみをprefixとして使う。rank limit=active count、length limit=min(remaining symbols,256)。深さ16・総branch≤32*(raw+1)で制限する。

各treeのclassはlo=0で0、(lo=4または32)かつhi=alphabetで1、他2。rank/lengthの合計6classに10bit履歴hを持ち、初期0。branchのCDFはtree kind、node ID、prefix k、対応classの現在hで選び、branch後はh=((h<<2)|child)&1023へ更新する。k=1も履歴を更新するがrange符号は不要。各tree142node、k=2/3/4で284model・852rootを順に保存する。

### 保存モデル

packet prefix134B：byte0=codec1、[1..5]に後続bit数u32、[5..134]に257symbolのcanonical Huffman長（偶数indexは上位nibble）。最後の未使用nibble0。長さ0は未割当、最大11、ESC symbol256は必須、Kraftが完全木であることを検査する。長さ→symbol順でcanonical codeを与える。minor code 0..255に未割当長0がある場合はESCの後にcodeの8bitを置く。既定tableは[src/lhc/block/codebook.rs](src/lhc/block/codebook.rs)のLENGTHSで、table自体をpacketに保存するため外部費用ではない。decoderは妥当な保存tableを使用する。

rootはtree kind順、node ID昇順、k=2/3/4順。まずpresence 1bit：0はuniform、1は木。木nodeはsplit bit。split=1ならrootに限りhistory order bit（0=low-first、1=high-first）が続き、4childをdigit 0..3順で読む。最大深さ5。履歴は2bit digit単位でlowから参照し、high order rootは5digitを逆順にする。

leaf（split=0）のmode prefixは`11`=uniform、`10`=pure、`0`=compact。uniform total32768はk個へ均等分配、余りを先頭から配る。pureはdominant index（k=2で1bit、他2bit）、非dominant頻度2、dominant=32768−2*(k−1)。compactは同じdominant field、非dominantのminor codeをindex昇順に保存する。頻度LUTは最初64個が2..65、続くe=6..13・j=1..24がmin(16383,2^e+ceil(j*2^e/24))。dominantは32768−minor合計、2以上かつ他頻度以上を要求。無効dominant、split深さ超過、不足・余剰bit、末尾padding非0を拒否する。

encoderは整数量子化CDFを用い、leafの実Huffman/ESC費用とsplit/header費用を目的へ含めたMDL木を選ぶ。各rootの低・高履歴順を実wire費用で比較する。これはdecoderの必須学習ではなくencoder戦略。`HistoryMode::LowHistoryOnly`は同じwireを使う比較用ablationで、高順探索を省く。

encoderのleaf候補は整数量子化compact、uniform、最大countをdominantとするpure。符号長＋保存費用が厳密に低い候補だけを選び、同点は先の候補を維持する。root uniformの目的費用は0、通常uniform leafは3bit。これは既存wire内のモデル選択改善で、decoder・形式version・保存するCDFの意味は不変。encoder改良で圧縮物のbytesは変わり得るが、旧decoderでも保存されたCDFから復元できる。

### Integer rangeとinverse

range初期0xFFFFFFFF、encoder low u64=0/cache=0/pending=1、decoder input先頭byte=0、次4byteをbig-endian codeとして読む。unit=floor(range/total)、CDF interval[c,c+f)へlow+=unit*c、range=unit*f。range<2^24の間はbyte単位でnormalizeする。通常CDF total32768、escape total256。encoderのcarry/cache flushは[src/lhc/block/multi_range.rs](src/lhc/block/multi_range.rs)の`shift`（low下位32bit<0xFF000000またはcarryでpendingをflush）に従い、終端で5回shiftする。decoderはcode−=unit*c、range=unit*f、normalize時code=(code<<8)|byte。最後はinputを正確に消費しcode=0を要求する。rounding gapも拒否する。

復元したlast columnからstable symbol順のLF permutationを作りprimaryから逆BWTする。一意sentinel、全行visit、cycleと終端位置を検査する。行indexとbyteをu32へpackしvisited bitで二重visitを拒否する。sentinelを取り除いたraw長とCRCを確認する。任意byteをsymbol1..256へ一対一写像しているので、正当なstreamは元byte列へ完全復元できる。有限往復テストの成功は全入力の実測ではない。


## Archive revision 3：因果copy frame

archive 3はKRS1BLKだけを受理し、archive 1/2へKRSを混入させない。独立block APIではmagicで識別する。LHC1BLKとKRS1BLKは、同じ40B header長でもフィールド位置とCRC範囲が異なる。確保前にframe長40..raw+80を検査する。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII KRS1BLK + NUL |
| 8 | 2 | KRS frame revision=1（archive revisionとは別） |
| 10 | 1 | 0=stored、1=因果copy/rANS、2=完全LHC1BLK内包 |
| 11 | 1 | flags=0 |
| 12 | 4 | raw byte count（0..1MiB、archive期待長と一致） |
| 16 | 4 | model bytes（0..3080） |
| 20 | 4 | payload bytes |
| 24 | 4 | raw CRC32 |
| 28 | 4 | frame[0..28] + frame[32..end] CRC32 |
| 32 | 8 | reserved=0 |

bodyはmodel→payload、完全extent一致を要求する。storedはmodel=0、payload=raw。内包はmodel=0で完全なLHC1BLK frame revision1/2を含み、内側の長さ・raw長・method・wireCRCも検査する。因果copyではpayload>=5B、model+payload<raw。encoderはBinaryAdaptiveの完全frame試行を先に払い、その結果より短いrecord候補だけを選ぶ。不利益なら内包またはstoredへ戻す。旧frame内包の40Bも全料金に含む。

因果stateはblockごとにlast[65536]=未出現、votes[1025]=0、best=1、previous=なし、位置0へresetする。各byteの予測は位置-bestが存在すればその既復元byte、存在しなければ0。予測が一致する最大連続copy長を最小ULEB128（最大3byte）でclass0へ符号化する。copy終端がraw末尾でなければ、必ず非zeroのbyte XOR予測値を1個符号化する。予測値0の残差はclass1、255はclass2、その他はclass3。復号では各copy byteのたびに予測を再計算しstate更新する。残量を超えるcopy、非最小ULEB、末尾後のfield、zero残差を拒否する。

byte完成後、previousと現在byteの16bit pair（0000/FFFFを除く）の直近完成位置を参照する。再出現距離1..1024ならその距離の票を1増やす。最大票、同票なら最小距離をbestとし、lastとprevious・位置を更新する。現在byteを予測する前にobserveしてはならない。未知原文・外部学習・浮動小数点を復号に使わない。

モデルはclass0..3の順に、support u16＋昇順の(symbol u8,freq u16)をsupport個保存する。freq>0、support<=256、非emptyモデルtotal32768、emptyはsupport0/total0。残差classのsymbol0は禁止。metadataを完全消費し、使用fieldでemptyモデルを選んだら拒否する。encoderは出現symbolへ最低freq1を割り当て、残り32768-supportをcount比例の整数床関数で分配し、剰余の大きい順（同値はsymbolの小さい順）に不足分を1ずつ加える。正確な整数freqを保存するため、decoderは再学習しない。

rANSは単一u32 state、L=2^23、U=256L、scale15/total32768。forwardに得たfield intervalを逆順にencodeする。freq=f/cum=c、state>=65536fの間low byteをemitしてstate>>=8。その後state=floor(state/f)*32768+state%f+c。payloadは0 prefix＋最終stateのLEu32＋emit列を逆順にしたbyte列。decoderのslot=state&32767、対応[c,c+f)のsymbolを選びstate=f*(state>>15)+slot-c。state<Lなら次byteで(state<<8)|byte。全stateは[L,U)を要求し、終端で全payload消費とstate=Lを要求する。raw長とrawCRCも照合する。

encoderのみの安全なpruningは、第一scanのcountと保存整数freqから下界H=Σcount*(15-ceil(log2 f))とfield数Eを求め、32H-E-256 >=256*(payload_limit-5)なら第二scan/ANS journalを省略する。一般的な近似判断ではなく、固定rANSのstate・床関数損失に対する保守的下界である。条件外では使わず、計算/モデルエラーをfallbackで握り潰さない。[証明と再現結果](experiments/khc/row-copy-pruned-rans/RESULT_20261007.md)を参照。

実装はsrc/lhc/record.rs・record_bound.rs・record_entropy.rs・record_voter.rs。保持journal上限12MiB、一時再確保6MiB、4復号LUT131072B、予測state266372Bを最大同時生存phaseで課金し64MiB codec gateを維持する。source/output・manifestは別費用。一覧はANS本文の完全復号やplain CRCは検査しない。完全検証はverify/extractで行う。同期・cancel遅延・entry単位公開など既存I/O制限も引き継ぐ。

## Archive revision 4：Gather32 frame

明示的な`Gather32Trial`はrecord候補とfallbackの全試行費用を払い、MDLだけを独立`LHCG32B\0`へ変更する。archive 4はG32 method 1、または従来のKRS stored/copy/旧frame内包を受理する。KRSに内包する旧frameは非MDLだけで、旧MDL wrapperは禁止する。LZ fallbackは内包frameのmagicを従来の`LHC1BLK\0`へ戻し、CRCを再計算する。新規G32 frameはrevision 2/method 1で記録し、revision 1/method 1も旧形式として読取互換を維持する。他のG32 revision/method組合せは拒否する。archive 1〜3の意味は変えず、revision 4非対応decoderは拒否する。

G32 headerは40B。整数はlittle-endian、CRC方式は上記と同じ。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `LHCG32B` + NUL |
| 8 | 2 | frame revision=2（新規出力。revision 1もmethod 1に限り読取互換） |
| 10 | 1 | method=1（MDL） |
| 11 | 1 | auxiliary flag=0または1 |
| 12 | 4 | raw byte count |
| 16 | 4 | primary row |
| 20 | 4 | metadata bytes（anchor列を含む） |
| 24 | 4 | range payload bytes |
| 28 | 2 | alphabet symbol count |
| 30 | 2 | reserved=0 |
| 32 | 4 | raw CRC32 |
| 36 | 4 | frame[0..36] + frame[40..end] CRC32 |

bodyはalphabet（u16×count）→anchor列→従来の整数MDL model packet→range payload。BWT symbol、alphabet初出順、rank/run文法、保存整数CDFとrange終端は従来MDLを維持する。raw≤1MiB、primary≤raw、alphabet count 2..257、payload≥5Bを要求する。metadataは241+auxiliary bytes以上、model packetの上限にauxiliary bytesを加えた長さ以下。headerとbodyの合計はframe extentに正確に一致し、body≥rawの非利益MDLを拒否する。

`n=raw+1`、`q=floor(n/32)`とし、`anchor[j]=LF^(j*q)(primary)`（j=0..31）を保存する。anchor 0はheaderのprimaryから得るためbodyには書かない。n≥65,536（raw≥65,535）のMDLはflag=1が必須で、残り31行を各`ceil(log2(n))`bit、各行の下位bitから連続するLSB-first bit列で格納する。長さは`ceil(31*ceil(log2(n))/8)`B、末尾未使用bitは0。全32行は範囲内かつ互いに異なる。小さいMDLはflag=0でanchor列なし。閾値・長さ・flagの不一致、範囲外・重複・非zero paddingを拒否する。

SA-ISの既存走査でcheckpointを採取し、復号ではLF行indexとbyteをu32へpackする。大blockは32本のchainを進め、chain境界・sentinel・終端とraw CRCを検査する。x64はruntime AVX2検出後にgatherを使い、利用できないCPUは同じwireのscalar実装へfallbackする。小blockは単一chainで復元する。BWT、SA-IS、複数chainは既知原理であり、今回の貢献はcheckpoint採取・bit packing・AVX2 gather32とscalarの実装・組合せで、世界初の圧縮原理とは主張しない。

Windows x64の実Rust API・CLIでcreate/list/test/extract、既知11入力のblock一致とG32/KRS/LZを含む復元hashを確認した。空入力・既定revision 1・複数block・即時取消の有限確認も実施済み。現在のnative 7-Zip比較はCPU静穏条件を期限内に満たさず0 sampleで未実行。G32の性能優位は未確認で、強設定Zstd・未見入力・総合目標も未達。ARM64/macOSのnative動作は未検証。

## Archive revision 5：Delta16 frame

明示的な`Delta16Trial`は40Bの外側frameを常に保存し、未変換と許可された変換候補の完全frame長を比較する。同サイズは未変換を選ぶ。未変換の子はrevision 4と同じG32/非MDL KRS、変換の子は非MDL KRSだけを許す。子としてDelta16、直接のLHC1BLK、旧MDL内包KRSを受理せず、任意の入れ子再帰を許さない。revision 5非対応decoderは書庫を拒否する。既定戦略とrevision 1〜4の生成規則は変えない。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `LHC6Z16` + NUL |
| 8 | 2 | frame version=1 |
| 10 | 1 | mode：0=raw、1=未変換の子、2=変換の子 |
| 11 | 1 | filter：mode 2は2、それ以外は0 |
| 12 | 4 | raw byte count（0..1MiB） |
| 16 | 4 | payload byte count |
| 20 | 4 | 元のraw CRC32 |
| 24 | 4 | frame[0..24] + frame[28..end] CRC32 |
| 28 | 12 | reserved=0 |

bodyはpayloadだけ。mode 0はpayload長=raw長とし、そのbyte列のCRCを確保前に検査する。mode 1/2は完全な子frameを含み、40B≤payload長<raw長、子のraw長=外側raw長を要求する。外側のextent・version・mode/filter・reserved・wire CRCと子のfamily/構造/CRCを、子の復号用確保より前に検査する。書庫内のframe長上限はそのblockのexpected raw長+40B。復号後は元のraw長とraw CRCを検査する。

filter 2はbyte列を型推定せずLE u16として扱う。`w=floor(raw長/2)`個のwordを順に読み、初期previous=0、`d=current-previous (mod 65536)`、`z=(d<<1) XOR (0-(d>>15))`（すべてu16）を得る。低位byteを位置0..w、高位byteをw..2wへ分離する。奇数末尾のbyteはそのまま位置2wに置く。逆変換は`d=(z>>1) XOR (0-(z&1))`、`current=previous+d (mod 65536)`。word間のcarry/borrowを維持し、各blockでpreviousをresetする。差分・zigzag・byte planeは既知原理の組合せであり、新しい圧縮原理とは主張しない。

encoderは未変換のG32試行を完了してそのworkspaceを解放してから変換bufferを作る。変換byteのうちTAB/LF/CRまたは32..126の割合が90%以上なら、MDL workspaceとの重なりを避ける固定admissionとして変換候補を省く。それ以外はG32のbinary経路を試し、非MDL KRSの子であることを要求する。全試行費用と外側・子のmetadataを含めて評価する。外部辞書は不要。進捗なしのrevision 5 verify/extractは、検証済みの外側を一段だけ外してrevision 4と同じG32／非MDL KRSの条件で適格性を判定する。G32を含む適格な書庫だけを最大4workerで復号し、mode 0と有界KRSの混在を認める。4,096entry／名前合計512KiBを超える場合、G32がない場合、事前走査に失敗した場合は逐次経路へ戻る。進捗付きAPIは引き続き逐次処理し、wire・子family・公開順序・CRC・取消契約は変えない。

Windows x64の製品統合E2Eでは、実APIの25確認と45拒否、旧5戦略の書庫全byte一致、新CLIのcreate/list/test/extract、旧CLIのrevision 5拒否を確認した。全u16差分と奇数末尾、最大blockのrandom/all-byte/text、空書庫、三mode、CRC再計算済みの不正な子、Limits、取消、source交換、既存出力保持を含む。元のx-rayの先頭1MiBは製品と凍結prototypeの完全frameが一致した。最新sourceのv4再ビルド後、容量監視の二重列挙を修正した入口で全32子を一回で実行し、89.7901861秒で成功した。観測最大WS 27,353,088B／commit 29,102,080Bで64MiB制限内。既存6 Windows回帰ケースとlibrary Clippy・全targetのfmt確認も成功したが、workspace全targetのClippyや全テストsuiteではない。全Silesia 211,938,580B・207 blockの完全復元と64MiB以内を確認したが、完成書庫54,187,747Bは同制限の7z 49,307,880Bを9.8967%上回りsize条件は不合格。全量時間は1回の監視付きscreenで、反復受入れ性能や新しい未見入力は未評価。調整用prefixの改善だけでは7-Zip優位や全入力の64MiB実peakを証明しない。ARM64/macOS nativeは未検証。

2026-10-12のWindows x64では、revision 5の進捗なし並列復号を実際の製品経路へ統合した。同じ全Silesia書庫のverifyを3組（旧→新、新→旧、旧→新）で比較し、中央値5.169816sから1.472069sへ71.53%短縮した。新APIの31ケース、CLI入口、旧24グループのE2E、既存6戦略の書庫バイト一致、file CRC前の未公開・既存出力保持・進捗順序・取消を確認した。CRC正常の先行ファイルは末尾破損でも保持される従来契約を維持する。書庫54,187,747Bは不変で、圧縮時間は今回測定していない。観測最大WS 44,740,608B／commit 34,086,912Bは64MiB内だが全入力の上限証明ではない。library Clippy（警告をエラー扱い）と変更2ファイルのfmtは成功。workspace全suite／全target Clippy、worker panic/spawn失敗の注入、ARM64/macOS、新しい未見データ、7-Zipとの新しい公平な反復比較は未実施。詳細と再現用原本は[開発記録](experiments/khc/DEVELOPMENT.md#2026-10-12-追記-revision-5の進捗なし並列復号を製品統合)を参照する。

## I/O安全性と既知制限

source/archive/output親はfilesystem rootからnofollowで解決し、Windows reparse／macOS symlinkを拒否する。macOS entry openはNONBLOCKも指定し、writer不在FIFOで型検査前に待機しない設計（macOS native E2Eは未実施）。source scan/reopenは保持root handle、file identity/size/mtimeを照合する。ただし同一inode/handleへmetadataを戻しながら書き換える攻撃者に対するsnapshot isolationや認証ではない。読み終わりの長さとmtimeも照合する。

出力は同じparent内private stagingへ書き、frame/file CRCと長さ検証・sync後にno-replace公開する。entry原子性のみ。先行entryは後続の切断・末尾不正・取消で残り得る。directory作成も残り得る。既存file・リンクは上書きしない。OSのリンク交換・公開競合にも既存handle/no-replace helperを使用する。

同期API、1MiB block計算中cancel遅延、directory時刻は復元しない。通常のfile mtime復元はExtractOptionsで選択。manifest最大4MiBを保持し、visitorは返却Entry Vecを避けるが完全O(1)一覧ではない。codecの固定reservation64MiBはsource block・呼出側buffer・manifestを含まない。圧縮率が勝たないデータや高CPU費用がある。暗号化・認証・SFX・追記・solid・量子hardwareは対象外。C/.NETへの新形式APIは未提供。

## Archive revision 6：幅変更schedule付きcopy frame（実験候補）

`RecordFastTrial` / `--strategy record-fast-trial`は、幅schedule付き候補が厳密に勝つblockだけKRS2BLKを使い、それ以外はBinaryAdaptiveの完全LHC1BLK frameをそのまま使うarchive 6を作る。独立block APIもmagicで識別する。旧archive 1〜5はKRS2を受理せず、archive 6はKRS2またはLHC1 v1/v2 fallbackだけを受理し、KRS1/G32/Delta16の直接格納を拒否する。既存strategyとKRS1の出力・復号は変更しない。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII KRS2BLK + NUL |
| 8 | 2 | frame revision=2 |
| 10 | 1 | 1=schedule付きcopy/rANS |
| 11 | 1 | flags=0 |
| 12 | 4 | raw byte count（0..1MiB、archive期待長と一致） |
| 16 | 4 | model bytes（0..3080） |
| 20 | 4 | payload bytes |
| 24 | 4 | raw CRC32 |
| 28 | 4 | frame[0..28] + frame[32..end] CRC32 |
| 32 | 4 | schedule bytes（0..raw） |
| 36 | 4 | reserved=0 |

KRS2 bodyはmodel→schedule→payloadで、完全extent一致を要求する。method 1だけを定義し、payload>=5かつmodel+schedule+payload<rawを要求する。確保前のKRS2 frame上限は40..raw+40、独立blockでも最大1MiB+40。LHC1 fallbackはKRS2で包まず、BinaryAdaptiveの完全frameを直接格納する。KRS2モデル、payload、raw CRCは同じ原文をKRS1で符号化した場合とbyte単位で一致する。

scheduleは位置deltaの最小正ULEB128（最大3byte）とwidth LE u16の繰り返し。直前位置の初期値は0、width初期値は1。位置はzero-based raw出力位置で、すべて1..raw-1内へ厳密に増加し、widthは1..1024。encoderはKRS1と同じVoterをrawの順でobserveし、bestが変わったbyteの次の位置へeventを置く。最終byte後の変更は未来の予測に使わないので保存しない。delta=0、非最小/4byte ULEB、位置overflow/範囲外、不正幅、不完全event、宣言schedule長の過不足を拒否する。

decoderはVoterとlast[65536]を作らず、eventの位置へ達した時だけwidthを適用する。copy runの途中でもevent境界で分割し、新幅へ切り替える。width>既出力長なら予測値は0。それ以外のcopyは既出力の末尾width byteを重複可能なchunkで繰り返し、raw長を超えない。残差の直前にもeventを適用し、すべてのevent・payloadを完全消費してraw CRCを確認する。CRCは認証ではないため、scheduleが原文から再計算したVoterと一致することの再学習は行わない。

選択は既存BinaryAdaptiveの完全frame試行を先に払い、そのframeを正確なfallbackとする。schedule保持capacityはmin(raw長, legacy完全frame長)以内に固定し、event追加でその予算へ達する候補は省略する。KRS1と同じcount/CDF/下界pruningを使い、ANSのbody予算からschedule全byteを差し引く。KRS2の完全frameがmin(raw長, legacy完全frame長)より厳密に短い場合だけ採用し、同サイズ・情報下界・ANS出力/journal上限ではbaseline frameをそのまま返す。その他のエラーは伝播する。KRS1候補との最小比較ではないので、scheduleの費用だけKRS1より大きくなる場合がある。

encoderはschedule/voter・既存fallback・ANS journal・frame組立の同時生存を既存64MiB codec gateへ課金する。decoderの4 LUTは131072B、Voterの266372Bは不要。CreateOptionsの固定予約・Limits・非追跡の親解決・CRC後のentry単位no-replace公開を維持する。一覧はscheduleとモデルの構造・wire CRCまでを検証し、rANS本文・raw CRCの完全検証はverify/extractで行う。revision 6は現状のrevision 4/5専用並列復号の対象外である。

これは復号時のper-byte Voter費用を減らす実験候補である。公開API/実CLIと悪性wireの有限E2Eは`tests/lhc_record_fast_e2e.rs`に置く。実行時は既存の外部`UNLHARE_LHC_E2E_ROOT`を指定し、容量・実行・清掃はLHC実験のstorage lifecycle入口を通す。

### Revision 6の局所測定（2026-10-15）

`examples/lhc_record_fast_bench.rs`の`--synthetic-switching-pair-v1`は、1MiBの前半でbyte pair `[33,52]`を16byteごと、後半で8byteごとに置き、他byteをseed `0x6d2b79f5`のxorshift32で生成する固定入力である。CRC32は`3173957449`。Rust 1.98.1 / Windows x64 / releaseで3 warmup後に9回計測した単一block frameの結果：

| 戦略 | frame byte | encode中央値 (ms) | decode中央値 (ms) | peak WS (B) | peak paged memory (B) |
| --- | ---: | ---: | ---: | ---: | ---: |
| RecordFastTrial | 907,613 (KRS2、schedule 8B) | 239.380 | 12.185 | 20,312,064 | 24,121,344 |
| RecordTrial | 907,605 (KRS1) | 240.168 | 15.162 | 21,102,592 | 24,088,576 |
| BinaryAdaptive | 923,416 (LHC1) | 211.187 | 53.550 | 13,758,464 | 10,416,128 |

時間はベンチ例の9回計測中央値、peak memoryは同じCRC・同じround数の別プロセスをWindows高水位counterで採取した値である。この入力ではKRS2はBinaryAdaptiveより15,803B（1.71%）小さく、decode中央値は約77.2%短い。一方encodeは約13.3%長く、peakメモリも大きい。KRS1との比較ではframeが8B増え、decodeは約19.6%短い。この合成入力だけの診断結果であり、一般データや7-Zipへの圧縮率・速度優位は示さない。別途試した7-Zip 7zr 24.09/25.01実行ファイルではKRS2は選ばれず、両方ともBinaryAdaptiveのframeへ正確にfallbackした。

2026-10-15のCanterbury `ptt5`製品書庫screenではRelease CLI上でKRS2が全3回選択されたが、完全書庫46,274Bは7-Zip 26.04の42,199Bより大きい。したがってこのデータで7-Zipを超えたとは判定せず、明示strategyのまま既定化しない。2runの時間・高水位メモリ・実効dictionary・復元hashと保全reportは[候補選定と比較結果](experiments/khc/RESEARCH_SELECTION_20261005.md)に記録した。

再測定コマンド（Cargoはstorage lifecycle wrapper経由）：

```powershell
$cargoArgs = @('build', '--locked', '--offline', '--release', '--target', 'x86_64-pc-windows-msvc', '--example', 'lhc_record_fast_bench')
.\experiments\khc\run-serial-cargo.ps1 -CargoArguments $cargoArgs -TransientMiB 128
foreach ($strategy in @('record-fast-trial', 'record-trial', 'binary-adaptive')) {
    .\build\cargo\x86_64-pc-windows-msvc\release\examples\lhc_record_fast_bench.exe $strategy --synthetic-switching-pair-v1 9
}
```

## Archive revision 7：空間bit付き因果copy frame（実験候補）

Rust `BlockStrategy::SpatialBitsTrial` / CLI `--strategy spatial-bits-trial` の明示指定だけがrevision 7を作る。書庫header・manifest・block分割・entry CRC・終端は同じで、各blockは必ずKCS1 frame。revision 7内への旧frameや、revision 1〜6内へのKCS1 frameの混入は拒否する。旧形式のencoder選択・wire・既定出力は変更しない。block API `compress_block_with_strategy` と `decompress_block` でも扱える。

### KCS1 frame

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `KCS1BLK` + NUL |
| 8 | 2 | frame version=1 |
| 10 | 1 | method=0 stored / 1 copy＋空間bit |
| 11 | 1 | reserved=0 |
| 12 | 4 | raw bytes、0〜1,048,576 |
| 16 | 4 | count model bytes、最大770 |
| 20 | 4 | payload bytes |
| 24 | 4 | raw CRC32 |
| 28 | 4 | wire CRC32（frame[0..28]とframe[32..end]） |
| 32 | 8 | reserved=0 |

bodyはcount model→payload。frame長は厳密に40＋model長＋payload長、model長＋payload長はraw長以下。storedはmodel長0・payload長=raw長。method 1はraw>0、payload>=5、model＋payload<rawが必須で、圧縮が得にならなければencoderはstoredへ戻す。空block APIは40B stored、空entryは従来どおりframeなし。書庫ではmanifest由来の期待raw長と一致し、frame長<=期待raw長＋40を満たす必要がある。

### 因果copyと幅投票

blockごとに幅1、投票0、全65,536 pairの直近位置を未出現で初期化する。完成byteをobserveした後、そのbyteと直前byteのpair（0x0000/0xFFFFは除外）の再出現距離1〜1024に1票を加える。累計最多票の距離を次の幅に選び、同点は小さい距離を選ぶ。投票にeligibleなpairの再出現がなければ幅を保つ。現在byteは予測・符号化後にobserveする。既存のKRS因果投票と同じ決定規則で、copy中も各byteをobserveする。

各tokenはcopy長（最短のunsigned LEB128、最大3B）と、末尾に達していなければ1 literalから成る。copy予測は現在位置−幅の完成byte、まだその位置がないときは0。copyは重なりを許し、残りraw長を超えてはならない。literalは実byte XOR予測byteの非ゼロ残差であり、ゼロ残差をliteralとして保存する非最大copy、過長LEB128、3Bを超えるcountは拒否する。

count byte列のCDFだけを保存する。modelはsupport u16（1〜256）、昇順の(symbol u8,frequency u16)をsupport個。frequency>0、合計32,768。count histogram総数をN、supportをSとし、各frequencyは`1 + floor(count*(32768-S)/N)`、余りは大きい順・同点はsymbol昇順に配分する。復号終了後に同じhistogramから正規化し、保存CDFと完全一致しなければ拒否する。

### literal空間bitとrange

4096個のu16確率p0を16,384で初期化する。幅w、現在位置i、列i%wについて、1行上の左・真上・右を24bitの`first`（左が上位）、2行上の真上・右を16bitの`second`に詰める。該当行がなければ全て0、左右の列が行外ならそのbyteだけ0。行頭でleft=0、他は直前完成byteの下位4bit。

残差をbit7からbit0へ処理し、shift=sで`key=(left&15) | (((first>>(s+5))&63)<<4) | (((second>>(s+7))&3)<<10)`。bit0は区間[0,p0)、bit1は[p0,32768)。bit1の後は`p0 -= ceil(p0/32)`、bit0の後は`p0 += ceil((32768-p0)/32)`、結果を1〜32767にclampする。続けて`left=((left<<1)|bit)&15`。copy中はこの確率表を更新しない。

countとliteralは同じ整数range streamへ順に入れる。rangeの初期・正規化・5回flush・先頭byte・終端code=0・余剰byte禁止は[整数range規則](#integer-rangeとinverse)と同じ。CDF不整合、range state不正、truncated、余剰、raw/wire CRC不一致を拒否する。

### メモリと有限製品E2E

decoderはframe<=1MiB+40、raw出力<=1MiB、pair投票表<=266,372B、CDF lookup 32KiB、確率表8KiBと小さなmodel/stackだけを使う。decoderの余裕を含む基底見積りは `2*(1MiB+40)+voter::BOUND+32768+65536 = 2,461,908B`。encoderは一度のVoter走査でCount/Literalイベントを1件2B、入力長以下の件数にまとめ、元の符号順で再生する。Countはbit15とlow8、Literalはlow10に幅-1とbit14に直前Count0を保存する。正数copy長cのvarint件数はc以下、Count0はLiteralへ併合するため総記録数は入力長以下。histogramとStatsでは併合前の全Countを維持し、再生時はCount0をliteral bitsより先に符号化する。Countのvarintと元入力から位置・残差を復元する。予約bit・最大3byte・入力残量・未完了Count・併合待ちCount0・正常終了時の最終位置を検査し、range上限での早期終了は従来のstored fallbackへ戻す。入力10B以下には記録を確保せず、完成frame確保・stored fallback前に記録を破棄する。記録の最大2MiBを加えたcodecの保守的bound `4,559,060B` を64MiB以下とコンパイル時に照合する。実capacityを検査し、SpatialMdlでは保持するMDL frameのcapacityも合算する。wire・モデル・復号規則は変えず、raw確保前にmanifestの期待長・header・model・wire CRCを検証する。これらの論理boundはOS高水位やallocator込みの実測ではない。書庫作成時の既存64MiB reservation gate、安全な一時作成・CRC後のentry単位no-replace公開を維持する。

有限E2Eは`examples/lhc_spatial_e2e.rs`と登録済み`experiments/khc/product-spatial-e2e.ps1`。固定合成入力の正常frame・決定性・stored/coded・上限、悪性count/CDF/range/headerと同一process復帰、最大blockをまたぐ書庫のAPI/CLI作成・list/test/extract・byte/SHA一致、64MiB gate、破損時と既存出力の保持、archive revision 1〜6の同一実装内create/test/extract往復を扱う。revision 6のframe magicが`KRS2BLK\0`であることも確認する。これは旧実行ファイルが生成した凍結archiveの互換証明ではない。既存Canterbury full E2Eの18MiB下限は下げない。

```powershell
# 先に共有Cargo入口でCLIとexampleをビルドする。
.\experiments\khc\run-serial-cargo.ps1 -CargoArguments @('build','--locked','--offline','--release','--target','x86_64-pc-windows-msvc','--bin','unlhare-cli','--example','lhc_spatial_e2e') -TransientMiB 128
.\experiments\khc\run-storage-experiment.ps1 -ScriptPath .\experiments\khc\product-spatial-e2e.ps1 -ScriptParameters @{ LhcExecutable=(Join-Path $PWD 'build/cargo/x86_64-pc-windows-msvc/release/unlhare-cli.exe'); E2eExecutable=(Join-Path $PWD 'build/cargo/x86_64-pc-windows-msvc/release/examples/lhc_spatial_e2e.exe') } -MaxRunMiB 5 -MaxEntries 64 -TimeoutSeconds 300
```

製品経路での時間・OS高水位メモリ・コーパス比較は別途必要であり、この有限E2Eを圧縮率や速度の優位性の証拠とはしない。

## Archive revision 8：class適応CDF付きschedule copy frame（実験候補）

Rust `BlockStrategy::RecordAdaptiveTrial` / CLI `--strategy record-adaptive-trial` の明示指定だけがrevision 8を作る。各blockはKRS3BLKまたはBinaryAdaptiveの完全LHC1BLK v1/v2 fallbackであり、KRS1/KRS2/G32/Delta16/KCS1の直接格納は拒否する。revision 1〜7へKRS3を混入させても拒否する。既定戦略・既存revisionの出力と読取を維持し、revision 8のverify/extractは逐次処理する。

KRS3の40B headerとmodel→schedule→payloadの並び、scheduleの最小ULEB128・幅・位置規則は[revision 6](#archive-revision-6幅変更schedule付きcopy-frame実験候補)と同じ。ただしmagicは`KRS3BLK\0`、frame revisionはLE u16の3、methodは1だけ。flags/reservedは0。raw長はmanifestの期待長と一致し、frame長は厳密に40＋model＋schedule＋payloadかつ期待raw長＋40以下。model<=3080、schedule<=raw、payload>=5、model＋schedule＋payload<rawを要求する。raw CRCはoffset 24、wire CRCはoffset 28でframe[0..28]とframe[32..end]を覆う。frame長・header・model・schedule・wire CRCはraw確保前に既存scheduled validatorで検査する。LHC1 fallbackにも既存のextent・revision/method・wire CRC検査を適用する。

4つの初期CDFとclass選択、copy/count・literal残差・rANSの規則はKRS1/KRS2と同じ。適応状態は保存済み量子化frequencyで初期化する。各classのsymbolを符号化/復号した後、そのsymbolのcountとclass固有のevent数を1増やす。classごとに1024 eventを完了するたびに非ゼロcountをceil(count/2)へ減衰させ、既存の整数normalizeで合計32768のCDFを再構築し、次のsymbolから使う。decoderは該当classの既存LUTを上書きする。空classは未使用のまま、block間では状態を共有しない。

encoderはBinaryAdaptiveを先に完了し、scheduleと適応CDFの候補を完全frame長で比較する。候補がmin(raw長, fallback frame長)より厳密に短いときだけKRS3を採用し、同サイズ・情報下界・出力/journal上限では元のLHC1 frameを返す。適応状態と一時的なCDF再構築領域も既存64MiB codec gateへ課金する。archive header/manifest/file CRC、Limits、source identity検査、CRC後のentry単位no-replace公開は従来どおり。

revision 8の有限製品E2Eは上記と同じexample/登録runnerへ追加した。1023〜1027 symbol境界でKRS3選択を要求する既存block確認に加え、小さい3 file書庫でKRS3とLHC1 fallbackの両方、API/CLI create/list/test/extract・byte/SHA一致、CRC破損・異family・旧revisionへの混入拒否、失敗後の再利用と既存出力保持、revision 7の往復を確認する。2026-10-16のWindows x64 Release buildと5MiB/64 entry registered E2Eは成功した。API E2EはKRS3 frameを5個（643〜646 B）、fallbackを4 case選び、archive revision 8の異常系17 caseを拒否した。KRS3性能screenはCPU quiet gate不合格のため未実行で、圧縮率・速度・OS高水位メモリや未見コーパスでの優位は未評価。

## Archive revision 9：KCS1と既定MDLのblock単位完全frame選択（実験候補）

Rust `BlockStrategy::SpatialMdlTrial` / CLI `--strategy spatial-mdl-trial` の明示指定だけがrevision 9を作る。各1 MiB blockについて、`compress_block` の既定MDL完全frame（LHC1BLK、内側revision 1のmethod 0 storedまたはmethod 1 MDL）と、revision 7と同じ `SpatialBitsTrial` のKCS1BLK完全frameを別々に作る。KCS1BLKのframe全体が厳密に小さいときだけKCS1BLKを選び、同サイズなら既定MDLを選ぶ。manifest・block prefix・file CRC・終端の構造はrevision 1と同じで、候補間に追加辞書・model・metadataを共有しない。したがって各blockの保存長と同じ入力・metadataでの書庫長はrevision 1を超えないが、二方式を作る分の追加CPU時間と一時memoryが生じる。

revision 9では各blockにKCS1BLK、または既定MDLの完全LHC1BLKだけを格納できる。KCS1BLKは[revision 7](#archive-revision-7空間bit付き因果copy-frame実験候補)の40B header、CRC、stored/modeled payload検証を適用する。fallbackはLHC1BLKの通常のextent・wire CRC・canonical-field検証に加え、内側revisionが1、methodが0または1であることを要求する。revision 2のLZ3/LZ8、KRS1/2/3、G32、Delta16および他のKCS系外frameは拒否する。revision 1〜8のdecoder規則は変えず、revision 1〜8 archiveの既存出力・読取も維持する。revision 9非対応の旧decoderはこのarchive revisionを拒否する。

この選択は既存KCS1とMDLのexact complete-frame比較によるデータ別切替であり、新しい符号器原理ではない。各blockサイズのMDL以下という性質以外の圧縮率・速度・memory・7-Zip優位や未見入力への一般化は未立証で、default `Mdl` は変更しない。有限E2Eと再現入口は[事前登録済みrevision 9実験手順](experiments/khc/STORAGE.md)に記録し、性能比較は別途のscreenとheldout評価を通過するまで行わない。2026-10-19のWindows x64 Releaseで固定枠の有限E2Eは成功したが、これは性能優位の証拠ではない。結果と検査範囲は[研究選定記録](experiments/khc/RESEARCH_SELECTION_20261005.md)に追記した。

## Archive revision 10：4方式のblock単位完全frame選択（実験候補）

Rust `BlockStrategy::PortfolioTrial` / CLI `--strategy portfolio-trial` の明示指定だけがrevision 10を作る。各1 MiB blockでは、まずKCS1（`SpatialBitsTrial`）のcount-only経路を使って完全frameの正確な長さだけを得る（frame自体は構築しない）。次にKRS2（`RecordFastTrial`）とKRS3（`RecordAdaptiveTrial`）の長さを評価する共通passが、一度だけ共有record準備と4個の初期modelを構築し、それぞれ独立copyのmodelで候補を符号化する。各KRS候補の一時frame長へschedule byte数を足すことで正確な完成長を得るが、長さ評価時にはscheduleの再挿入とheader CRCの再計算を行わず、一時frameを破棄する。最後に既定MDLを完全frameとして符号化する。MDLが最小ならそのframeを返す。それ以外はMDL frameを破棄し、選ばれた候補を再符号化する。選択では候補frame長が現在の最小より厳密に短い場合だけ更新するため、同長時の優先順は評価実行順と異なりMDL、KCS1、KRS2、KRS3となる。候補workspaceと前の候補frameを同時保持しない。archiveのmanifest・block prefix・file CRC・終端はrevision 1と同じ。

revision 10では各blockにKCS1BLK、KRS2BLK、KRS3BLK、または完全なLHC1BLK fallbackを格納できる。LHC1 fallbackは内側revision 1 method 0/1、またはrevision 2 method 0/1/3に限る（revision 2 method 2のLZ3は不可）。KCS1/KRS2/KRS3は各revision固有のframe長・CRC・canonical payload検証を適用する。KRS1、G32、Delta16、BinaryAdaptiveの独立LHC frame、その他のframe familyは拒否する。revision 1〜9のdecoder規則は変えず、revision 1〜9 archiveの既存出力・読取も維持する。revision 10非対応の旧decoderはこのarchive revisionを拒否する。

このportfolioは既存の四方式のblock単位切替で、新しい予測器・entropy coderではない。既定`Mdl`は変更しない。revision 10の固定E2Eが通過しても、それは完全復元と形式境界の確認に限り、速度・最大memory・7-Zip優位・未見入力への一般化は別の事前登録評価なしに主張しない。[E2Eと再現手順](experiments/khc/STORAGE.md#revision-10-portfolio-integration-e2e-preregistration-2026-10-19)に評価条件を記録する。

## Archive revision 11：PPMII系テキスト候補を加えたblock単位完全frame選択（実験候補）

Rust `BlockStrategy::PortfolioPpmTrial` / CLI `--strategy portfolio-ppm-trial` の明示指定だけがrevision 11を作る。各blockでrevision 10と同じMDL、KCS1、KRS2、KRS3の長さを求めた後、PPMII（PPMd var.H相当）の完全frame（LPM1BLK）を符号化し、既存候補の最小より厳密に短い場合だけ採用する。同長時の優先順はMDL、KCS1、KRS2、KRS3、PPMとなる。PPMの利得がない（payloadがraw以上）blockでは候補にしない。archiveのmanifest・block prefix・file CRC・終端はrevision 1と同じ。

revision 11の各blockはrevision 10が許す全frame（KCS1BLK、KRS2BLK、KRS3BLK、同じ内側revision・methodのLHC1BLK fallback）とLPM1BLKを格納できる。LPM1BLKはrevision 11だけで受理し、revision 1〜10では拒否する。revision 10以前の旧decoderはrevision 11を拒否する。

### LPM1BLK frame

40 byte headerの後にrange coder payloadを置く。整数はlittle-endian。

| offset | 長さ | 内容 |
| ---: | ---: | --- |
| 0 | 8 | `LPM1BLK\0` |
| 8 | 2 | frame revision 1 |
| 10 | 1 | method 1（PPM）。storedは持たず、利得がないblockは他候補を選ぶ |
| 11 | 1 | 最大次数（2〜16。現行encoderは6） |
| 12 | 4 | raw長（manifestのblock長と一致、1〜1MiB） |
| 16 | 4 | model arena上限MiB（40固定） |
| 20 | 4 | payload長（raw長未満） |
| 24 | 4 | raw CRC-32 |
| 28 | 4 | wire CRC-32（offset 28〜31を除くframe全体） |
| 32 | 8 | 0 |

modelはLZMA SDKのPpmd7（public domain）と同じPPMII手順（SEE、情報継承、binary context、最大頻度124のrescale）で、range coderは7-Zip PPMd（Ppmd7z）と同じ方式である。ただしmemory配置は独自（8 byte cellの添字arena、1 unit 16 byte）で、上限unit数に達するとPPMdと同様にmodelを初期化し直す。7-Zipの書庫・PPMd streamとの互換性はない。decoderはframe長・CRCを確保前に検査し、復号後にpayloadの余剰byte、最終codeが0でない非正準な終端、raw CRC不一致を拒否する。decodeの作業memoryはmodel上限40MiBとtext・出力の各1MiBで、64MiB codec gate内に収まる。

テキストblockでは既存候補より小さくなる一方、PPMの復号はblock内で文脈modelを逐次更新するため、BWT系MDLの約2〜3倍の時間がかかる（2026-11-13のWindows x64開発測定で、Calgary book1の1 block復号が約80ms）。速度・7-Zip比較の評価条件と結果は[ゲート](experiments/khc/GOAL_GATE_20261113.md)に記録する。
