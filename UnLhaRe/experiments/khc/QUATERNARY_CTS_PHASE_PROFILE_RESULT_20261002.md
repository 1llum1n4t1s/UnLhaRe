# 同一process ABBA・整数CTS phase診断結果

## 結論・採否

progress。固定ABBA旧/pow2/pow2/旧の4encodeが一度のCLIで完了し、各474730Bを凍結frameへRAM全byte比較して一致。全固定stats、3736枝×7sample phase/run、7whole phase/runもpassed。pow2は同process・計測付きの両回で旧両回より短い。H1（mixture改善が実CTS経路にも現れる）は今回の診断で支持された。計測付きencode平均11.7983994s→10.3586973s、12.20252045%短縮は診断値であり正式中央値ではない。前段の別時点・単発14.006s対12.009sによる反証懸念を同条件で切り分けたが、無計測の正式比較は依然未検証。

payload loopがfull encodeの98.57～98.73%。候補の選択sampleでCTS predictはouter model predictの68.72～68.88%、CTS observeはouter model observeの83.09～83.31%。H2（CTSを優先する）は観測subsetでは支持。ただしKT/mixture/posteriorの内部段別時間は未測定。次の優先候補はKT正規化の同値な狭幅算術であり、速くなることはまだ未実証。Snapshot全再検証、CAP、準備後commitを削除して速さを得る方式は採用しない。

採用したのは計測経路と再現証拠だけ。pow2は次の研究比較基点として有望、製品通常経路への採用は保留。旧source/proof/default、公開API/wire/version、正式gateを変更していない。7-Zip超え全goalは未達・active。

## 固定環境・一度の実行

- 契約 `QUATERNARY_CTS_PHASE_PROFILE_CONTRACT_20261002.md` SHA256 `128DFCF78987C1F3F9F8960DF452B905A4AD4C26CE1CCA6FEE1630FEB81BA80A`。
- 事前失敗計画を実装前保存。親はplan、timing、profile全文、model/wireの凍結旧sourceとの差分、runner全文を確認してから一度Execute。
- 実装担当は既存worker-high、要求/継承profileはgpt-6.1-sol/high。新規起動なし。7file完成・編集停止を回収。モデル実効値の外部観測はしていない。親が6基本観点とAsync/Startupを調査・採否・統合・実行。
- 親nonExecute preflight passed、48identity前後一致、12unique source/12import edge（root10＋同じmodelへのwire2）、static CTS alias、旧basis36再hash一致、出力root未作成0B。旧Executeの再実行なし。
- runtime: `C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe` 7.6.5、SHA256 `362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139`。
- compiler: `C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe`、`rustc 1.98.1 (48a229cea 2026-09-01)`、SHA256 `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`。
- Windows x64、AMD Ryzen5 7640HS/6cores/12logical。CPU/OS/compiler/runtime/CWD/source path/hash/mtimeは計測前reportへ保存。
- one build: edition2024、frame_audit/primitive_audit、opt2、overflow-checks=yes、panic=abort、debuginfo=0、DEBUG:NONE。compile1207.8927ms、exit0。凍結pow2 reexportのunused imports warning1件、実行stderrは空。警告解消目的で凍結sourceを変更していない。
- wrapper UTC 2026-10-02T03:48:56.2159487Z～03:49:43.9205696Z。profile CLI44403.7678ms、exit0。4encode、warmup0、追加repeat0、timeout120秒以内。再試行なし。
- child TotalProcessorTime44218.75msは診断のみ。machine CPU15%の観測・達成証明ではない。

## 全時間phase（ms）

| run | 方式 | full | BWT | setup | model init | loop | digest | metadata/CRC/frame |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | old | 11748.4782 | 109.1263 | 28.0536 | 4.0950 | 11597.6841 | 2.7233 | 5.6043 |
| 1 | pow2 | 10288.9510 | 102.5366 | 27.0559 | 4.0465 | 10145.6935 | 2.7431 | 5.7282 |
| 2 | pow2 | 10428.4436 | 105.8390 | 27.4371 | 4.1275 | 10279.7592 | 2.7456 | 7.3938 |
| 3 | old | 11848.3206 | 107.2296 | 29.1477 | 4.3378 | 11697.6619 | 2.7215 | 6.0678 |

fullは他のwhole phaseを包含。他の6phaseは互いに非包含。range.finish/戻り/一部drop/clock aggregation等の残差があり、phase和一致を要求していない。平均は診断整理だけで採用gateには使わない。model init約4msなので今回は初期化cache/事前巨大tableを優先しない。

## 選択sample（3736枝の集計ms、全入力時間ではない）

| run | model predict | CTS predict | pool predict | range interval | model observe | pool update | CTS observe |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | 6.8316 | 4.9738 | 1.0631 | 0.1273 | 5.2078 | 0.2507 | 4.4497 |
| 1 | 6.2012 | 4.2616 | 1.0604 | 0.1334 | 4.5180 | 0.2565 | 3.7641 |
| 2 | 6.2880 | 4.3311 | 1.0792 | 0.1350 | 4.5338 | 0.2531 | 3.7670 |
| 3 | 6.9699 | 5.0105 | 1.0768 | 0.1294 | 5.2367 | 0.2585 | 4.4761 |

serial0mod1024、first0/last3824640、7phase各count3736、合計26152/run・104608/4run。inner CTS/poolはouter model内を含むため7列を足してCPU総時間とはしない。model predict外側はreturn copyを含む。rangeは通常intervalのみ、escape除外、forcedも計測対象だが今回選択subsetにはprefix1が0件。

全4runのsample components=[2783,953]、prefixes=[0,469,26,3241]。component sample比74.49/25.51%対全枝71.26/28.74%、prefix sample比0/12.55/0.70/86.75%対全枝0.0032/12.73/0.55/86.72%。偏りがある。clock/aggregation/配置/CPU schedulingも未分離であり、全入力の確定CPU時間へ外挿しない。

## 同値E2E・固定観測

入力2811006B SHA256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76` とbaseline frame474730B SHA256 `9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD` を各1回bounded read。全4frameは1件ずつRAMで474730byte直接比較→drop、全一致。disk frame/restore/input copyなし。decodeは今回重複せず、先行の復元/canonical E2Eとは別の保証。

各run frame/header/payload474730/281/474449、plain/payload/headerCRC433441561/3589341169/1741345118、runs889227、primary1762795、alphabet257、rank/length tokens各889227、escape742、枝2725772/1099568、grammar58735a2b7383d755、base-pool9128444225deabce、class[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990±1e-4一致。digestはbase count/pool値だけで全state保証ではない。全run progress JSONをflushし、final/raw/parsedをvalidator前に保存。proof statuspassed/profile_validated=true。

48identity（新source/contract/旧proof/results/frame/compiler/runtime/input/guard）前後path/hash/bytes/mtime一致。EXE_before/afterも一致、旧basis36不変、未知importなし。数値module、Snapshot再検証、全CTS.observe再predictを変更していない。

## 容量・保持証拠

fresh root `UnLhaRe/build/khc-quaternary-cts-phase-profile-20261002/`。事前0B、8MiB予算、scalar peak予約1572864B。保持は2fileのみ、432567B（約422.4KiB）で予測1.25MiB以内。

| 証拠 | bytes | SHA256 |
|---|---:|---|
| profile-o2-yes.exe | 307712 | FC938C42314383EC09EB35DA032AFDDD99A084F0E4A59B28C8805AF9193ECD2C |
| report.json | 124855 | 359A98D303CC898354AB346BD0A3EAB896B49D03C721EEAD46A3CA4A692B0B7F |

source profile.rs5716B/7FA9557A7F5438FB18366E0D9554296919EAE929AE2508DDF0A4E6DB6F0E0092、timing.rs3623B/7E0E44040DCFB0739EAEB8C3810C6E042644FBF10FE61D332C1322E5933C15DB、model.rs12452B/F599961210F42C6B2DE9CF07146DE6CF9118858CA4119B3AA3D97B4EFB6D6F40、old_wire.rs19020B/292417BF89C57CDEAD4D18E80015AB54AF17C51832F13D4D69BC70C4595F3117、pow2_wire.rs19015B/22BB6FD2963E9E403321567767F6A5707B76327B59482DC2F289D99A03CB021A、verify-profile.ps125378B/178C0D5B7F73A5C96D9EAF75B1AB624184CDCF30B946996E865D4D450E1B4260、FAILURE_PLAN.md5337B/02BC42C61925B43695C6195B336C818504F718EABE331424FC542792B3511B0E。

終了時owned profile process0、2files、link/混在なし、temps0。新しいCargo/PDB/cache/asm/rawtrace/table生成なし。削除したファイルなし。固定証拠・共有cache・x86未変更。容量guardは前後確認でありOS書込み強制quotaではない。

## opop観点・残作業

| 観点/親担当 | 結論 | 根拠 |
|---|---|---|
| Modernizer | 現状が最適 | 凍結toolchain/依存維持、更新不要 |
| Normalizer | 現状が最適 | static aliasと共通model、数値意味混在なし |
| Performance | 改善を採用（計測） | 全loopとCTS subsetを切り分け、pow2/H1支持。製品性能採用は未検証 |
| Cleaner | 現状が最適 | 旧proof保持、再生成copy/tempなし |
| Hardening | 現状が最適 | CAP/Snapshot/commit保持、bounded output/120s/noRetry |
| Tester | 改善を採用 | 4全RAM frame比較、固定stats/countと48identity前後証拠 |
| Async | 現状が最適 | singlethread、一frame/stateずつdrop、child/finally解放 |
| Startup | 現状が最適（今回優先順位） | 初期化4.05～4.34ms。cache等の利益未立証 |
| Intel | 非該当 | 凍結ローカル算術で判断、外部仕様を使っていない |

親の集計用PowerShellでcommaと算術の優先順位によりObject[]のop_Multiply例外が一度発生。読み取り専用集計だけを括弧/ForEachへ直して再集計。最終再読のJSON mtimeはConvertFrom-JsonがDateTimeへ変換していたため、ISO文字列との比較で不一致と誤判定した。UTC DateTime同士へ揃えて48件を再照合し、hash/bytes/mtimeすべて不変と確認。候補CLI/compile/旧Executeは再実行していない。git diff --check passed（既存DESIGN.mdのLF/CRLF warningのみ）。製品全build/testは実行していない。

次はKT normalizeの商/余りをu64で同値に計算できる範囲と拒否意味を先に固定し、局所比較＋全frame E2Eで実証する。現在CAPによりprefix mass total≤2*CAP+4=7650684、各mass*Q<2^55であり狭幅化候補はあるが、性能効果は未測定。一般normalizeの公開/拒否意味は変えない。

正式574.5624ms/CPU15%/observer確認待ち/既存terminal protocolは変更・起動していない。holdout/categories/4native/productAPI/一般8MiB対応も未検証。固定size gateだけは先行frameでpassed、総合達成ではない。
