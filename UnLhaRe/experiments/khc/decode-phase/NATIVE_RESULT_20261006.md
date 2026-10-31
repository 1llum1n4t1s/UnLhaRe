# 実全書庫の復号差と現Forestでのphase実測

2026-10-06 JST。前のGOAL質問応答はno progress、本工程は新native測定とcurrent-source診断・E2E・清掃を実行したprogress。GOAL active/未達、元の固定ゲート、真正未見、独自性、4環境、形式統合、Zstd/量子研究の要件を保持。製品source/形式/公開API/versionの変更0。

## 実行環境・再現
Windows x64、AMD Ryzen5 7640HS（6core/12logical）、fixed rustc1.98.1/opt3/codegen1/thinLTO/unwind。
cwd C:/Users/IMT/dev/UnLhaRe/UnLhaRe、開始UTC2026-10-05T18:56:18.3146454Z（JST10月6日）。
固定11entry/raw2810784B、実KHC466395B/7z481490B、前native-cの全byte/mtime復元記録SHA18E70562A567D520B57C4CD7FDC11F5B67C502C218933E6E5B2419DFBCB83D3Aからsource/tool/archive pinを再照合して再使用。
7za26.03、実solid+/blocks1/LZMA2:3m/mx9/md4m要求/mfb273/mmt1。property3145728Bが全入力を覆う。KHCはentry独立block。設定を弱めず率条件5%に対して3.135%削減で未達。

実行:
- decode-phase/native_compare.ps1 -Attempt paired-a（session52477 exit0）
- 同 -Attempt paired-reverse-a -Reordered（session53771 exit0）
- decode-phase/native_profile.ps1 -LibrarySha256 94A19BFD6C0AFD23D7C0453760C51B596D9BFA2C7CBE983BBFA15F6111572AC4 -Attempt profile-a（session36837 exit0）

各nativeはCLI khc-test対7za t -mmt1 -bd -bso0 -bsp0、warm1+9paired、逆順は同じ書庫/EXEを再pinしてpair内順序を反転。全child exit0・終了pins unchanged true。archive/復元物コピー0、output files0。これは全復号+CRC検証で、extract書込み速度ではない。OS process start/exit差をprocess wall、外側起動待機をharness wallとして保存。Guard/終了後hash確認はこのwallに含めない。全sampleを保存し、都合のよい外れ値を除いていない。

| 順序 | KHC wall median/min/max ms | 7-Zip wall median/min/max ms | KHC/7Zip中央値比 |
| --- | --- | --- | ---: |
| KHC→7Zip | 149.4961 / 145.7539 / 166.5476 | 39.0672 / 38.0544 / 42.1207 | 3.8266 |
| 7Zip→KHC | 149.2002 / 143.1831 / 179.2227 | 39.7909 / 37.9662 / 41.8100 | 3.7496 |

KHC CPU medianは両回140.625ms、7Zip15.625/31.25ms。OS tick粒度が粗いためこの差から細かい倍率は主張しない。
最大観測private KHC4980736/5009408B、7Zip5517312/5525504B。WS KHC8818688/8814592B、7Zip9732096/10727424B。全sampleで採取あり、64MiB内。privateはsample/PeakPagedによる観測、WSはOS peakであり、真の全時点最大の独立保証ではない。CPU quiet15%/60秒、suite300秒/child60秒、work8MiB/report128KiB/free5GiBを維持。

## 現ソースのphase
旧diagnostic EXEは10月5日05:38UTC生成でcompact Forest採用前。流用せず、同profile_block.rsの13pathが現在の子moduleへ接続されるよう再compile。13path/TLS/6境界時計だけを取り除くと現mod.rsに正規化完全一致することをbuilderで検査した。
CLI生成16:35UTC、rlib16:34:35、現packet16:34:23UTC。現在のcli/source連続性と既存E2Eは確認、今回CLI全buildを再実行した証拠ではない。

実保存KHCの11frameをpublic archive verify/listで検証してからboundedに取り出し、各frameを公開rlibと計測namespaceでwarm1+9復号。全byteを元corpusと直接比較、99有効行、元11file/2810784B一致、非MDLの6phaseは0、各phase合計<=total。自作frame取出しは製品parserの代用品ではない。全frame465951B＋container overhead444B＝466395B。
8MDLの554504run/2023324branch、残3frameはmethod3（kennedy/ptt5/sum）。Forest容量は10264〜75800B。

各入力の9中央値を合算:
- 公開decompress_block全11frame:102.8420ms、計測namespace全11frame:104.9474ms。
- 計測namespaceの8MDL:89.3864ms。
- token/run:74.3259ms（MDLtotalの83.151%、全11frame計測合計の70.82%）。
- alphabet/Forest:2.7987ms（MDLの3.13%）、inverse:11.4695ms（12.83%）。
各phase中央値の和はtotal中央値と必ずしも一致しない。時計はinner branchではなく6固定境界だけ。温まったframe/API内時間と新process/native wallの差を、純codecの速度差や起動だけの費用と断定しない。

結果はモデル初期化より逐次token/runが優先対象という根拠。古い7.08%Forest/80.71%tokenという比率を最新へ転記しない。CDF検査削減/slot融合/active移動/LFvisited省略の過去棄却を再試行しない。次の独立候補と失敗先行契約はMDL_ENTROPY_PLAN_20261006.md（多値単一state rANS、別研究magic、12MiB上限journal、全費用/安全性/両順比較）。まだ候補コード/性能/製品統合は未実施、rANS自体を新圧縮原理と称さない。

compile6438.1635ms/private255598592B/WS281919488B、run2267.2089ms/private7028736B/WS11001856B。EXE1163264B SHA6FDC294D80C05E608B7DCE217D44DCB3CAF55BC8873AC7E2153A1F5AA9127076、public rlibは上記94A19…。
runner native_compare SHA3D0B485A6AA30E2496585E5E1D8526202CC2717396105D5EFC8C65C80364E3C3、
native_profile.ps1 SHA4D01CBF587AB8BDACBA20FA0B07EE1E88869F29EB80EBAC4B2078F72252F9A4C、
native_profile.rs SHA9BF1A4769F1601CFAC3FA74CAC0BAECD3725F0038AA03F063335A93252DD9D17。
全ソース/compilation/EXE/input pinは各reportに保存。製品mod/model/paid/packetの現SHAは前回から変わらない。

## 保存結果
| build配下report | B | SHA256 |
| --- | ---: | --- |
| khc-native-decode-paired-a-20261006/report.json | 36952 | E96663F8137201F6FC7F2E909B9083BE1A31C277B77BE69C68160A86EBFE0BBF |
| khc-native-decode-paired-reverse-a-20261006/report.json | 36956 | 4DB3001BF7D8D3AD3D852A3DB2307F3698FAA1156BF318852D5C688994497AEC |
| khc-native-profile-profile-a-20261006/report.json | 38021 | D15CFC0E052B2B29603F8E674091C4E15CA4EAB0FF3678746B822B8342C130A8 |

## E2Eと容量
前後同じ7target/9E2E、fixed all.group SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、--test-threads=1。baseline7.1700025秒/終了6.5952316秒で9件全成功。UNLHARE_KHC_E2E_ROOTは新build/khc-native-decode-public-e2e-20261006、両回終了4199234B。56×3/CLI/空/複数block、最大split/悪性model、30故障と回復、CRC前未公開/no-clobber/limits/cancel/source置換を確認。既存実行ファイルを再使用した確認で、full fmt/clippy/release/4OSの新検証ではない。新unitなし。
hardcoded shared hybrid7237226B/product6449512B、各8MiB内。新4出力root合計5474427B（約5.22MiB、E2E4.2MBを含む）。Cargo6163555929Bで増加0、固定cap6175228536B/残11672607Bを変更しない。最終空き47797792768B、関連process0。

今回の用途終了PDB1396736Bだけ共通CodexCleanup moduleで清掃。対象SHA/mtime/reparse/exclusive read/停止/EXEとreport保存を確認し、recycle成功→捕捉した$R/$Iのみpurge成功→source/recycle/metadata不在、module ledger state completeを実測。
summary build/khc-native-profile-cleanup-20261006.json SHA5AE39C42A10DF2B37B4A8CE68FB2406EDDDDCEA007394A3636D2B9EB22252AE8、
module ledger C:/Users/IMT/.codex/artifacts/recycle-cleanup/cleanup-df2a4dbd75c645c3b1db9c23d04d4c5b.jsonを保持。完全消去済みでPDBは再compileから再生成可能、旧EXE/report/archive/input/shared cacheの削除0。

opopの各観点はNATIVE_PLAN台帳に対応する。Normalizer/Performance/Tester/Hardening/Async/Startupは測定基盤と証拠を採用、Modernizerは更新非該当、CleanerはPDBだけ完了、Intel未解決照会なし。採否gateを変更せず、証拠不足の製品micro候補は追加しなかった。
本結果は総合優位を**否定する現状証拠**であり、改善済みとは言わない。未達のまま方式改善へ継続する。

