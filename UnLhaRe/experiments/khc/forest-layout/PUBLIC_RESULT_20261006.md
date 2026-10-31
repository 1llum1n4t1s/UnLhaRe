# Forest 公開経路の検証（2026-10-06）

## 境界・仮統合

境界実行 `build/khc-forest-boundary-boundary-a-20261006/report.json` は completed / live pins true。独立のwire生成とCDF計算に対して6正常モデル、5234688 CDF、50拒否ケースが一致した。全852可変root、high/low、最後のgroup・最後のhistoryも検証済み。最大保持6989848B、追加parse transient4222622Bであり、全入力でメモリ削減になるとは主張しない。report SHA AA23B9C14308584869B2FD70E2A4BEE344946677F5A182A287F438CC83FFC9A8。

製品 packet.rs のForestだけを候補へ仮統合。SHA 058D43FA627009D47C7E9F589558673AF19F80C1757E6D7DD6569F29668CDCA1。旧packetの正確な実験対照は dense_packet.rs（SHA BA0BE650557F7F7224AA6632ECDD3BCB7023CF3DC4D69F0A293ADC33192EC618）へ固定した。codec.rs の参照先変更のみのため、以前のreportのcodec.rs SHAと現在のSHAは異なる。過去のreport/実行ファイルは書き換えず、古いcompile証拠を新しいsource pinにすり替えない。

直前の統合turnで、既存7targetの9E2Eを実行して全成功。Cargo生成は3＋4targetの直列 `cargo test --release --target x86_64-pc-windows-msvc --test ... --no-run`、生成後の試験は固定all.groupと専用rootを指定して実EXEを実行した。lib/CLI/hybridのclippy、対象fmtも成功。これはKHC経路の検証であり、bundle全体・.NET AOT・4OS native成功を意味しない。Cargo終了6163555929B、固定cap6175228536B、残11672607B。

## 公開API用実行ファイル

同じ examples/khc_compact_io.rs（SHA 7D55EF60641C01D9883106A182DA24B32518368F307A845A695798D73A50C656）を実際のCargo生成 libunlhare.rlib（SHA 94A19BFD6C0AFD23D7C0453760C51B596D9BFA2C7CBE983BBFA15F6111572AC4）にリンク。Rust1.98.1、opt3、codegen1、thinLTO、panic unwindでrelease設定に合わせた。paidは公開 BinaryAdaptive、decodeは公開 decompress_block。診断namespaceではない。

単体リンクにはtarget depsだけでなくhostのproc-macro depsとCargoが既に使っているWindows 0.52/0.53 native lib検索先が必要だった。初回はE0463、public-bはLINK1181で失敗。public-cはリンク成功したがthinLTOなしなので公平な本測定には使わない。public-dはlink中の一時ファイル消滅により容量走査が失敗して終了した。public-io.ps1の容量guardはfull scanをWin32 IO code2/3の場合のみ3回まで再試行し、他のエラーや上限超過は拒否を維持する。部分合計で継続しない。

public-eはcompleted / live pins true。EXE1041920B、PDB1257472B、report9909B、合計2309301B。EXE SHA 020ACFC3E9DFC5400EA99928B4ED33EAA619CA886D7D53DE67829FEDF48EED9D、report SHA 1A59EBD20ED029E9647B352318568CC8F23CCFDD76629F746087AADECF101D04。compiler壁時計4804.9558ms、観測private208556032B/WS257798144B。ビルド時間はcodec速度の証拠ではない。旧public baseline EXE SHA 330598C11A9464E3671155AEDE330F7862389A89CBF7C0A6187F71947618AC8Cは維持。

## 比較条件

compare-public.ps1は凍結 cpu-measurement-v2/run.ps1 から派生し、専用public-e実行ファイルの厳密な許可、元helper sourceとbuild reportのpin検証、出力先、来歴だけを変更した。build reportの全pinを現在の実体と再照合する。タイミング、CPU quiet15%/60秒、各child64MiB/60秒、suite900秒、warm1＋9交互、frame全一致、自己・交差復号、report256KiB、free5GiBは維持。全16入力を0–6/7–10/11–15の3分割で直列測定し、raw/frameはRAMのみ。各出力専用8MiB、実際は小さなJSONのみ。外側でdisk-budgetの前後確認も行う。

通常順でdecode改善を確認した場合だけ入力・pair逆順で再現する。採否と7-Zipの固定完了条件は別であり、未見・強い全archive比較が未達の間はGOALを完了しない。初期2分割ではframe一致・復元は成功したが速度改善はまだ明確でない。最後の分割と合算が終わるまで採用を決めない。

## 通常順・独立逆順の完了結果

通常順a/b/c、逆順c/b/aを独立に実行し、逆順の各partition内もdescending、pair順も反転。両順とも全16入力でwarm1＋9 pair。計1344 native calls、320同frame、640自己復号、64交差復号で全byte一致。全6reportはcompleted、live pins true、frame不同0、raw/frameディスク生成0。development11は以前から調整している集合であり未見とは扱わない。

| 範囲・順序 | 圧縮旧→新 ms（中央値合算） | 展開旧→新 ms（中央値合算） | frame総B旧＝新 |
| --- | ---: | ---: | ---: |
| 全16・通常 | 1498.7047→1451.1100 | 1247.2297→1228.7371 | 531979 |
| 全16・逆順 | 1509.3708→1450.9740 | 1205.5945→1197.5225 | 531979 |
| development11・通常 | 1200.0302→1154.0824 | 982.1756→962.8137 | 465951 |
| development11・逆順 | 1216.2719→1157.3731 | 940.4074→933.2687 | 465951 |

全16の圧縮短縮3.18%/3.87%、展開短縮1.48%/0.67%。development11の展開短縮1.97%/0.76%。小さな差であり、process起動・IO/pump込み、個別には悪化もある。独立namespaceの16.95%を公開経路の効果へ転用しない。旧EXEは凍結Cargo生成、新EXEは同release flagsの単体リンクなので、すべての時間差をForest単独の因果効果と断言しない。

development11の観測展開max privateは通常9748480→5332992B、逆順9740288→5328896B。観測展開max WSは13242368→8740864B / 13230080→8695808B。圧縮＋展開を合わせたmax privateは25505792→25522176B / 25509888→25526272Bで、全処理のpeakが半減したとは主張しない。短命processの真のprivate peakは見逃し得る。CDF全照合による保持表の削減、既存9E2E、両順での復元・小幅短縮を合わせ、形式不変の実装改善として採用する。新しい圧縮原理・7-Zip優位・未見優位ではない。

| report（build内） | B | SHA256 |
| --- | ---: | --- |
| khc-forest-public-compare-20261006-forest-old-a/report.json | 37871 | 3310FEBDC15B0C069040A571DB01E9BF9921C8BB74D3B52EFB3AC693153D1BA3 |
| khc-forest-public-compare-20261006-forest-old-b/report.json | 31205 | 2144B55AE2963796E59792F9A2DE2AEE0B12A8254BE795CB849669F47B70D3CC |
| khc-forest-public-compare-20261006-forest-old-c/report.json | 34048 | 440F511FE907CE9B3633A7529D0256E284514953F1E90E70C7375D0497C62118 |
| khc-forest-public-compare-reverse-20261006-forest-reverse-a/report.json | 38221 | 60F547EDE2F64B4437910165BD7B171E9F2701A636A1B3A22C25D6D176914958 |
| khc-forest-public-compare-reverse-20261006-forest-reverse-b/report.json | 31564 | 849076FF1553C68577F85DA5FAEB9A5B4AA7B138ED146F034FCC5DB6C3CE243B |
| khc-forest-public-compare-reverse-20261006-forest-reverse-c/report.json | 34402 | 182F601E7E47C1E8FB4E5788C08A58098A13CAE7119C2D18B8D48E4A2ACCC2CA |

両順report計207311B。各partitionのdisk-budget前後確認は8MiB内、終了時空き46163337216B。Cargo増加0。次は新public-eと固定7-Zipを同じ時点・公平設定で直接比較する。古い別時点の7-Zip時間を引いて優位と扱わない。さらに強い全archive・未見・Zstd/量子等の研究との照合が必要で、GOAL active。

## 不要リンク生成物の清掃

public-b/c/dのreportはSHA照合して保持。使わないlink object、PDB、thinLTOなしpublic-c EXE、失敗public-d EXEとrustc一時rlibを、専用scriptから共通Remove-CodexItem.ps1でrecycle→今回分のみpurge→元/$R/$I不在を検証した。合計8842286B、66top-level項目（内部を含め122生成file）を清掃。ledger `build/khc-forest-public-intermediates-cleanup-20261006.json` complete、既存ごみ箱不変。ごみ箱からは復元不能だが同source/commandから再生成可能。採用public-e EXE/report、旧baseline、corpus、共有cacheは触れない。初回preflightはUTC/local日時比較で失敗しhelper未呼出・台帳未生成。DateTimeOffset.UtcDateTimeで同じUTCとして比較する修正後、元の厳密な時間範囲・件数・byte条件を満たして実行した。
