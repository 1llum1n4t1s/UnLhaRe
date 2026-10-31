# entropy LUT 先行失敗契約

親PLAN SHA6F8ABDEF080CB49362EEB4CA5AE5BD921350CD3B9682BBF672D45EB73A154ABAに従う。元Model/Math/pool/CTS、旧証拠は凍結。compile1、finite/selfcontrol/selfcandidate/pair各native1は親だけ実行する。本保存時は全て未実行。

## 有限入口（実装前固定）

- 表32769entryを旧式 `-(f64::from(f)/32768.0).log2()` とbits直接比較。実行前32769＋後32769＝65538比較。0は正Inf、32768は負zeroを別途2比較。
- 範囲外32769/u32::MAXの2fallbackを旧式bits比較。
- 有限Kahan入力は `[1,32768,2,32767,3,16384,7,8192,31,1024,32768,1]` を64周、768updates。各step value/correctionを各bits比較＝1536比較。0/Infは累算に入れない。旧加算式と同じ順、Table参照以外の演算を変えない。
- 同一reserve helperでusize::MAXを実try_reserve_exactし1拒否。要素bytesの算術overflowでありOS OOM注入ではない。表正常constructor1、表mut accessorなし。前後全entry比較を既存snapshotの表省略で代用しない。
- Table::newは既存Modelの全fallible構築成功後に実行。追加allocationエラーは新constructor失敗、旧失敗優先維持。容量のみTLS scalarに保存してAPI直後にreadback（数値状態・branch計数ではない）。各正常Model所有表1、32769f64 payload262152B。readonly容量取得で表変更なし。

## wire反証

既存selfcheck全文JSONを各側1回、14正常/34破損/4短headerと厳密reasonを旧成功に照合。新unitなし。pairはinput一read、control/candidate encode各1、decode各1、再encode0。全frame478856B直接Eq、各fullplain2811006B、各側typedProof14 Eq、型間Debug14同値、全4stats、CRC/header、validate_fixed4。旧plainは候補decode前drop、最大frame2/plain1、diskコピー0。異なれば診断失敗、都合のよい再実行なし。

## 資源と非主張

表actual capacity bytesを新Model bound/encoder bound/inverse保守boundへ1表加算。基礎21561264/45723494Bにpayload262152を加えた最小値21823416/45985646B。inverseはinputcap+2framecap+14*2811007+65536+4194304+tablecap。BWT旧142647787B、表構築前。model32MiB/phase64MiB、各native実WS/private160MiB（非null正値・APIerrorなし）を独立検査。finiteはTable1＋小scalarだけ。

sourceと計画300KiB、EXE1MiB/report256KiB、全出力8MiB/free5GiB、compile60s/native各120s。未使用build/khc-hard-cut-entropy-lut-20261004のみ。旧normal149組と旧pair174組はbefore/after/live、重複Identityは一pinへ統合。親の実行前に新8files停止/hash/全文復元ledger/graph/非書込構文を返す。速度単回control先行/warm0のみ、正式速度・非計測allocation・7zip総合達成・製品採用を主張しない。Git/外部write/delete/製品/x86/追加委任0。
