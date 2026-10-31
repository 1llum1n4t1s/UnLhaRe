# 整数CTS mixtureのpow2専用化結果

## 判定・採否

Progress。variable u128除算を、分母Q²専用のshift/low32bit Hamiltonに置換した候補は整数同値・実frame・復元・異常E2Eを通過した。局所probeはold中央値5725900ns→fast4374100ns、約23.609%短縮。

ただし統合codecの速度改善は未証明で、採用は保留する。今回の一回診断encode14006.037msは前段12008.7067msより短くなっていない。別時点の単発値なので、劣化原因や統計的な劣化を確定しない。一方、局所probeだけをcodec全体の改善証拠にすることもできない。旧候補/通常経路を置換せず、新候補と証拠だけを保持する。正式574.5624ms/CPU15%/holdout/categories/4native/productは未達、full_benchmark_allowed=false。goal「7-Zip超えをするまで！」はactive・未完了。

## 基準・条件・identity

契約SHA3D942A6A32F267B469E55999E83E84DD9EFCA1B46B3442A589899B8FCA9C0ED0。コード前plan SHA2831CFE2D4430A6D76C3740F1C9BF1A64E389EFB0997A25BFECEDAA8F8D0A101。旧frame proof18B106BDB873BB5B1C82EBF7F7B9B6EBB17209C8E137D9332320941D0CBECB98と旧26identityを一回再照合し、旧Executeを重複しなかった。

新source quaternary-cts-pow2/：integer_cts.rs DCFD5CF8F9D408174840194CA3D0AF38F90EB938172C5A51EA2B85BA90427B28、comparison.rs 248400D4F1954F4CB4A3F7D759A26F4AD51C12FBCB3EA0CBE8021CE4AF43D24C、codec.rs 4D4FF38557860B9DF99F20F2CBC11D9B99D9C1D9D2593D071C1D936CDC60C0CE、runner F8B59FD01A776A1567A78AA16779B1BB9562C98C68ABD3A02A8CA1F21959C56F。

proof `build/khc-quaternary-cts-pow2-20261002/report.json`：71765B、D5F40FA03A3987605432D3E430F5BAAEA7C47AB628E046CC27723085B7D8D777。EXE321536B、92136CA3BE32D64768E5510ACB1AA2CD103B0B0608DFD7BD22EBE358F4F54F7B（before/after一致）。frame474730B、9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD。

Windows x64、rustc1.98.1/bundledpwsh7.6.5、edition2024、opt2/overflowyes/panicabort/debuginfo0/DEBUG:NONE、frame_audit/primitive_audit。compile/runは一条件一回、2026-10-02T03:20:25.3681121Z〜03:21:29.220291Z。36identity・11source/10rootedgeをpin/readlock。parent preflightとの照合、実行before/after、親の最終再hashは不一致0。未知module/include/extern crateを拒否。旧source/proof/frame/root・製品API/wire/version/公開/Git/x86/sharedcacheは変更しなかった。

## 同値性と局所計測

mass total=Q²で、floor(mass*Q/Q²)=mass>>32、旧剰余=(mass & (Q-1))*Q。したがってchild同点順位も同じ。rawmassはu128を維持し、posterior更新を変えない。一般normalize/KT/poolは旧helper、Snapshot/Kernel/Nodeも旧typeを使用。CTS.observeの全snapshot再計算一致検査、CAP、全prepared node後commitは維持した。

parentの独立BigInt計算4116件と剰余関係4116件が一致。その後Rustで正常4116件のmixed/rawmassを直接比較し全一致、非法12の具体入力とErr理由も一致。digestだけの正当性証明ではない。

実行前レビューで、同じuniform vector同士のscalarは剰余0/left0のため非zero同点を試さないと分かった。計画に具体値を先に記し、既存tie fixture groupを補強：prefix3、weightQ/2、own=[1,1,Q-2,0]、child=[2,2,Q-4,0]ではchild0/1のlow32剰余=Q/2、left1、mixed=[2,1,Q-3,0]。old/fast mixed/rawmass直接一致・child昇順配分を確認。normal4116/invalid12/時間用入力は変えず、scalar group数3（呼出し回数ではない）を保持した。

同4116cases×16pass×5paired round、side329280calls。alloc/構築をtimer外へ置き、関数/引数/結果にblack_box、偶数old→fast/奇数fast→old。同じdigest/countと全5個のnsを保存した。

| round | old ns | fast ns |
|---|---:|---:|
| 0 | 5934900 | 4343000 |
| 1 | 5891100 | 4343100 |
| 2 | 5725900 | 4374100 |
| 3 | 5659700 | 4421700 |
| 4 | 5650200 | 4552200 |

各round/side65856calls、digest全一致13768162428661050085。PowerShellはBigIntegerとして保持し、元child stdoutと保存reportの10digestを正確に照合した。JavaScript Numberの丸め値で照合していない。局所probe通過で後続E2Eを実行したが、正式codec speed/CPUの通過を意味しない。

## 統合E2E

旧frameとの全474730byte比較が一致、入力restore全2811006byte比較/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76一致、canonical全frame比較一致。header/payload281/474449B、plain/payload/header CRC433441561/3589341169/1741345118、grammar58735a2b7383d755、base-pool9128444225deabce、枝2725772/1099568、6class観測、CDF3788636.714502990bitsは旧証拠と一致。

RAM normal14/byte roundtrip14/canonical14/malformed30、model named14/assert16/CAP exact1、CRC32 fixture、CLI10（2成功/8拒否）がpassed。snapshot拒否時の全base count/total/weight/CTS raw+weight/history/observations/serial/auditを直接比較。既存16B出力不変と拒否出力不在も実測。17childは期待終了、成功stderr空、拒否8件は期待exit1/理由。一般heap/write/sync fault注入、一般handle-safe抽出、全8MiB一般入力対応は未検証。

今回の全入力診断wallはencode14006.037ms/decode13555.2683ms/canonical28646.0904ms。前段との単発比はencode約1.166倍だが、同時点のpaired codec比較や正式CPU観測を行っていないため因果・median・総合性能へ一般化しない。次は局所probeと統合経路で効果が一致しない理由を小容量のprofileで切り分ける。正式observer/protocol確認待ちと過去terminal条件は変更していない。

## opop観点台帳・担当

| 観点 | parent判定 | 根拠/対応 |
|---|---|---|
| Modernizer | 現状が最適 | compiler/runtime/dependencyを凍結して比較 |
| Normalizer | 証拠不足 | 同値pow2専用化は成立、通常経路移行は保留 |
| Performance | 証拠不足 | 局所23.609%改善、codec全体改善は未証明 |
| Cleaner | 現状が最適 | 参照された旧証拠保持、用途終了tempだけ清掃 |
| Hardening | 現状が最適 | fullsnapshot/CAP/拒否意味/commit順を省略しない |
| Tester | 改善を採用 | direct整数比較、非zero余りtie、全frame比較を保存 |
| Async | 現状が最適 | 単一thread、全成功後publish/資源解放を維持 |
| Startup | 現状が最適 | 初期化を変えずhot算術だけ比較、配布変更なし |
| Intel | 非該当 | 凍結ローカル算術で決着、外部現在仕様なし |

6基本観点と適用Async/Startup/Intel判定はparentが直接担当。実装は終了済みの既存worker-high担当へ新5fileの排他所有を委任し、編集停止を回収後parentが全source/runner・独立算術・採否・実行/統合を担当した。要求role worker-high（既定gpt-6.1-sol/high）；今回のツールには実効model/effort読出しがなく未取得として区別する。別担当の新規独立出荷レビューではない。opopは同値保持/測定による採否/全観点確認に影響した。

## 容量・清掃

fresh root8MiB、生成前peak予約5434775Bを実評価。実行後はEXE/frame/report3fileで868031B（約847.7KiB）、見積り1.25MiB以内。Cargo/PDB/cache/asm/rawtrace/table/入力copy無し。

台帳のexplicit絶対path/用途/削除条件/identityを保存し、生成したrestore.tmp2811006B・empty.input.tmp0B・empty.frame.tmp74B・empty.restore.tmp0B・sentinel.output.tmp16Bを使用後削除した。missing encode/decode出力2pathは生成されず不在。範囲/link/所有EXE process0/exclusive leaf/混在を確認し、単一PowerShellの非再帰Remove-Item LiteralPathを使用。親の最終確認もtemp残存0/所有EXE process0。削除物は再生成可能な検証一時物で、比較/identity証拠と圧縮結果は保持している。
