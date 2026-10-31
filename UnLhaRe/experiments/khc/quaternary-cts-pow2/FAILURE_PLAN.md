# 同値pow2 mixture: コード前失敗計画

契約SHA3D942A6A32F267B469E55999E83E84DD9EFCA1B46B3442A589899B8FCA9C0ED0全文確認。旧全source/proof/root immutable、新担当5fileのみ。一条件一回・親final review前compile/run禁止。parser/stdout rustfmt/nonExecute preflightのみ。新unit test追加なし、standalone RAM比較と先行E2Eのみ。

## 起こり得る失敗

- Q²=2^64をu64へ狭める、forced1 mass=Q²の桁落ち、mass>>32/low32剰余の誤り、Hamilton tie順/余剰件数/sum誤り: 正常4116件のmixed4/rawmass4を旧へ直接比較。fixed forced1とuniform境界fixtureも確認。
- prefix/weight/vectorの検査順とerror textの変更、非法入力の受理: 下記12具体入力の旧/fast Err理由を直接比較。
- stale/derived/rawmass改変snapshot/CAP検査の削除、class/history/node/leafweight更新誤り、部分commit: 旧types/helper再exportと同意味Cts接続。先行model16拒否・全state直接比較を凍結E2E経路で再実行（probe成功時のみ）。
- 一般normalize/KT/poolまで専用化を混ぜる、causal token/grammar/count/hash/CRC/range/quota/CLIを変える: codecは旧sourceからimport差分とcompare-mixture CLIだけ。旧frame474730Bの全byte/SHA比較と固定restore2811006Bの別comparisonを保存。
- probe構築/allocをtimer内へ混入、dead-code最適化、pass/round/順序変動、digestだけで同値を主張: 構築はtimer外、black_box、同4116case×16pass×5pairedround、偶数old→fast/奇数fast→old。5件elapsed_ns/median/digest/count保存。直接4116比較を省かない。
- fast>=oldでも正式採用/fullcandidate実行、局所probeを正式speed/CPUと同一視: probe passedかつfast median<old medianのときだけ次E2E/full3CLI。反証時はnot-adoptedと明記しframeを作らない。574.5624ms/CPU15%等は不変、full_benchmark_allowed=false。
- source/import/pins/環境/root/quota/timeout/streamcap/失敗証拠漏れ: 11source10rootedge、readlock/hash前後、旧proof26identity一回照合。fresh8MiB、peak5434775B、child120sec/UTF8各65536B。EXE_before/parsed/frame/header/二比較をvalidator前保存。失敗bounded partial/noRetry。
- restore/tiny削除で他作業を壊す: explicit絶対path用途台帳、ancestor/descendant links/所有EXEprocess0/exclusiveleaf/混在確認。同一PowerShell Remove-Item LiteralPath非再帰、EXE/frame/report保持。未知失敗後再起動/条件変更なし。

## 正常4116・固定LCG

prefix1..4×weight[0,1,Q/2,Q-1,Q]の20件。own/childは各prefixのunit massesを旧normalizeした合法uniform Hamilton vector。4096件はseed0x6d2b79f5、wrapping u32 state=state*1664525+1013904223。prefix=index%4+1、own/child各legal mass=(next_state&0xfffff)+1を旧normalize、weight=次stateのu64(0..Q-1)。全4116件構築時と全old/fast mixed/rawmassを逐次直接比較、RAMだけ。timed side calls=4116*16=65856/round、5round/side329280。

実行前coverage確認: 同一uniform vector同士では剰余0/left0なので、scalar3のtie group内でprefix3・weightQ/2・own=[1,1,Q-2,0]・child=[2,2,Q-4,0]を別の固定scalarとして旧/fast mixed/rawmass直接比較し、mixed=[2,1,Q-3,0]を要求する。child0/1のlow32剰余Q/2が同値、left1をchild0へ与える。scalar group数3・normal4116・invalid12・timed配列は変更しない。旧uniform3 fixtureも残す。この固定coverage補強は候補compile/run前だけで、旧proofは変更しない。

## 非法12: 具体入力→期待理由

U2=[Q/2,Q/2,0,0]、U4=[Q/4;4]。明記しないweight=Q/2。

| 名 | prefix / weight / own / child | 期待Err |
|---|---|---|
| weight_over | 4 / Q+1 / U4 / U4 | weight outside Q |
| prefix_zero | 0 / Q/2 / U4 / U4 | invalid prefix |
| prefix_five | 5 / Q/2 / U4 / U4 | invalid prefix |
| own_zero | 2 / Q/2 / [0,Q,0,0] / U2 | invalid categorical vector |
| own_over | 2 / Q/2 / [Q+1,1,0,0] / U2 | invalid categorical vector |
| own_outside | 1 / Q/2 / [Q,1,0,0] / [Q,0,0,0] | invalid categorical vector |
| own_sum | 2 / Q/2 / [1,1,0,0] / U2 | vector sum differs from Q |
| child_zero | 2 / Q/2 / U2 / [0,Q,0,0] | invalid categorical vector |
| child_over | 2 / Q/2 / U2 / [Q+1,1,0,0] | invalid categorical vector |
| child_outside | 1 / Q/2 / [Q,0,0,0] / [Q,1,0,0] | invalid categorical vector |
| child_sum | 2 / Q/2 / U2 / [1,1,0,0] | vector sum differs from Q |
| weight_precedence | 0 / Q+1 / [0;4] / [0;4] | weight outside Q |

## probe成功時だけの固定E2E

先行normal14/byte14/canonical14/malformed30、modelnamed14/assert16/CAPexact1、CRC32 fixture、LCG1831565813とCLI10を凍結importで維持。固定input encode/decode/canonical各一回、旧frame474730B/SHA9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFADへ全byte比較。payload474449/plainCRC433441561/payloadCRC3589341169/headerCRC1741345118、grammar58735a2b7383d755/base-pool9128444225deabce、枝2725772/1099568、class[889227,620240,1216305,889227,64372,145969]、CDF3788636.714502990±1e-4。二comparisonはnamed記録＋expected length引数で混同しない。

未検証: 正式codec median/CPU、holdout/4native/product、一般8MiB全入力、heap/write/sync fault injection、一般handle-safe抽出。採否/opop台帳/結果は親所有。Git/公開/外部書込/version/x86/sharedcache無し。
