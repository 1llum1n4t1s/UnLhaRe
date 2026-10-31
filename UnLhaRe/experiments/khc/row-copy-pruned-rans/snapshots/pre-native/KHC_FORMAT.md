# KHC1形式仕様（開発版）

2026-10-05。実装はRust API `unlhare::khc` とCLI `khc-*`。LHA方式の追加・置換ではない。既存LHA API/C ABI/.NET APIとpackage versionは変えない。既定はrevision 1を維持し、明示的なhybrid戦略だけrevision 2を作る。未知のversionを黙って解釈しない。

CPUだけで自己完結して復元できる。外部モデル・辞書・学習環境・ネットワークは不要。浮動小数点はencoderの木選択だけに使い、選択した整数CDFを保存する。decoderは整数だけで動作する。異なるCPUでencoderが同じ符号列を作る保証はないが、保存したCDFで復号できる設計。4環境でのnative確認はWindows x64以外未実施。

## アーカイブ

多byte整数は、range streamの初期code以外little-endian。CRC32はISO-HDLC（反転多項式0xEDB88320、初期0xFFFFFFFF、最終XOR0xFFFFFFFF）。空列のCRCは0。CRCは改ざん防止や認証ではない。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `KHC1ARC` + NUL |
| 8 | 1 | revision=1または2 |
| 9 | 3 | flags/reserved=0 |
| 12 | 4 | block limit=1,048,576 |
| 16 | 4 | entry count |
| 20 | 4 | manifest byte count |
| 24 | 4 | manifest CRC32 |
| 28 | 4 | header[0..28] CRC32 |

直後にmanifestを格納する。各entryは、名前長u16、kind u8（0=file、1=directory）、flags u8=0、元長u64、mtime i64、UTF-8名前byte列。mtimeはUnix秒へ切り捨て、i64::MINはunknown。directoryは元長0。名前長を含め固定部20B。manifestをentry count分正確に読み、余剰byteを拒否する。

名前はcanonical `/` 区切り、末尾slashなし。空、絶対名、`.`/`..`、`\`、制御文字、Windows特殊文字/device名、末尾dot/spaceを拒否する。名前最大32,000B、深さ128、Unicode lowercaseでの重複とfile/child衝突を拒否する（Unicode正規化の同一性までは保証しない）。全名前・entry/total長を展開先作成前に検査する。manifest上限4MiB、entry count上限100,000。呼出側Limitsでさらに制限できる。

fileは元長から決まるceil(size/1MiB)個のblockを順に格納する。各blockはu32 frame byte countと完全なKHC1BLK frame。最後のblockだけ短く、他は1MiB。全file復元byteのCRC32 u32が続く。空fileはblockなし、CRC=0。directoryにはpayloadもfile CRCもない。全entry後に8B `KHC1END` + NULを置く。さらにbyteがあれば拒否する。別途index/共有dictionary/solid履歴はなく、blockごとに状態をresetする。

## 独立block

archive revision 1はblock revision 1だけを受理する。archive revision 2はblock revision 1/2を受理する。旧decoderはrevision 2を拒否し、新decoderは旧revision 1を受理する。method 0/1の意味は両revisionで同じ。

| offset | bytes | 内容 |
| --- | ---: | --- |
| 0 | 8 | ASCII `KHC1BLK` + NUL |
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

packet prefix134B：byte0=codec1、[1..5]に後続bit数u32、[5..134]に257symbolのcanonical Huffman長（偶数indexは上位nibble）。最後の未使用nibble0。長さ0は未割当、最大11、ESC symbol256は必須、Kraftが完全木であることを検査する。長さ→symbol順でcanonical codeを与える。minor code 0..255に未割当長0がある場合はESCの後にcodeの8bitを置く。既定tableは[src/khc/block/codebook.rs](src/khc/block/codebook.rs)のLENGTHSで、table自体をpacketに保存するため外部費用ではない。decoderは妥当な保存tableを使用する。

rootはtree kind順、node ID昇順、k=2/3/4順。まずpresence 1bit：0はuniform、1は木。木nodeはsplit bit。split=1ならrootに限りhistory order bit（0=low-first、1=high-first）が続き、4childをdigit 0..3順で読む。最大深さ5。履歴は2bit digit単位でlowから参照し、high order rootは5digitを逆順にする。

leaf（split=0）のmode prefixは`11`=uniform、`10`=pure、`0`=compact。uniform total32768はk個へ均等分配、余りを先頭から配る。pureはdominant index（k=2で1bit、他2bit）、非dominant頻度2、dominant=32768−2*(k−1)。compactは同じdominant field、非dominantのminor codeをindex昇順に保存する。頻度LUTは最初64個が2..65、続くe=6..13・j=1..24がmin(16383,2^e+ceil(j*2^e/24))。dominantは32768−minor合計、2以上かつ他頻度以上を要求。無効dominant、split深さ超過、不足・余剰bit、末尾padding非0を拒否する。

encoderは整数量子化CDFを用い、leafの実Huffman/ESC費用とsplit/header費用を目的へ含めたMDL木を選ぶ。各rootの低・高履歴順を実wire費用で比較する。これはdecoderの必須学習ではなくencoder戦略。`HistoryMode::LowHistoryOnly`は同じwireを使う比較用ablationで、高順探索を省く。

encoderのleaf候補は整数量子化compact、uniform、最大countをdominantとするpure。符号長＋保存費用が厳密に低い候補だけを選び、同点は先の候補を維持する。root uniformの目的費用は0、通常uniform leafは3bit。これは既存wire内のモデル選択改善で、decoder・形式version・保存するCDFの意味は不変。encoder改良で圧縮物のbytesは変わり得るが、旧decoderでも保存されたCDFから復元できる。

### Integer rangeとinverse

range初期0xFFFFFFFF、encoder low u64=0/cache=0/pending=1、decoder input先頭byte=0、次4byteをbig-endian codeとして読む。unit=floor(range/total)、CDF interval[c,c+f)へlow+=unit*c、range=unit*f。range<2^24の間はbyte単位でnormalizeする。通常CDF total32768、escape total256。encoderのcarry/cache flushは[src/khc/block/multi_range.rs](src/khc/block/multi_range.rs)の`shift`（low下位32bit<0xFF000000またはcarryでpendingをflush）に従い、終端で5回shiftする。decoderはcode−=unit*c、range=unit*f、normalize時code=(code<<8)|byte。最後はinputを正確に消費しcode=0を要求する。rounding gapも拒否する。

復元したlast columnからstable symbol順のLF permutationを作りprimaryから逆BWTする。一意sentinel、全行visit、cycleと終端位置を検査する。行indexとbyteをu32へpackしvisited bitで二重visitを拒否する。sentinelを取り除いたraw長とCRCを確認する。任意byteをsymbol1..256へ一対一写像しているので、正当なstreamは元byte列へ完全復元できる。有限往復テストの成功は全入力の実測ではない。

## I/O安全性と既知制限

source/archive/output親はfilesystem rootからnofollowで解決し、Windows reparse／macOS symlinkを拒否する。macOS entry openはNONBLOCKも指定し、writer不在FIFOで型検査前に待機しない設計（macOS native E2Eは未実施）。source scan/reopenは保持root handle、file identity/size/mtimeを照合する。ただし同一inode/handleへmetadataを戻しながら書き換える攻撃者に対するsnapshot isolationや認証ではない。読み終わりの長さとmtimeも照合する。

出力は同じparent内private stagingへ書き、frame/file CRCと長さ検証・sync後にno-replace公開する。entry原子性のみ。先行entryは後続の切断・末尾不正・取消で残り得る。directory作成も残り得る。既存file・リンクは上書きしない。OSのリンク交換・公開競合にも既存handle/no-replace helperを使用する。

同期API、1MiB block計算中cancel遅延、directory時刻は復元しない。通常のfile mtime復元はExtractOptionsで選択。manifest最大4MiBを保持し、visitorは返却Entry Vecを避けるが完全O(1)一覧ではない。codecの固定reservation64MiBはsource block・呼出側buffer・manifestを含まない。圧縮率が勝たないデータや高CPU費用がある。暗号化・認証・SFX・追記・solid・量子hardwareは対象外。C/.NETへの新形式APIは未提供。
