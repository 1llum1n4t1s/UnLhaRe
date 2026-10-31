# Compact posterior full候補の正式比較: 実装前契約

前goal turnは数値kernel実装/検証でPROGRESS。今回full候補48 checks / 86 CLI / 269 identities、四条件7入力のframe/stdout/restore一致と、実kernel12892624 group使用を確認した。旧integer/Q15/一般SIMD候補のterminal試行は再実行せず、この別source/EXEへ固定した比較を一度だけ実行する。総合7-Zip超えは未証明。

## 固定条件・容量

- Input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76と11件Canterbury development manifestを維持。holdoutとは別。
- 新normal243712B/SHA362282160B038EF495927DE2F855E8EF651D4611101BA8D8D0F842AA8D61DDB9、固定complete frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12。旧balanced control/7za26.03 x64は従来SHA/optsを固定する。
- 上限483599B、encode median厳密<574.5624ms、warmup1+measured9、3codec circular順、single-thread設定、process120秒、CLI起動前〜終了/stdout/stderr drain後wall/子CPU別、quiet preflight5×1秒と各CLI前後総CPU<=15%を不変とする。priority/affinity/power/他processを変えない。
- 初回/最終の6decodeとnative SLT、中間archiveは直接復号済み初回SHAとの完全一致。native11file/候補1groupの異なるdecode境界は総合勝利/採用に使わない。
- performance root96MiB、full親は既存23.75MBを加え128MiB枠。normal見込み48MiB未満、native archiveが入力程度へ増大した場合の余裕を含む。EXE/Cargo target/cache/raw traceを新設しない。guardは事前/事後であり、OS強制quotaではない。既存root/attemptを上書きしない。

## 失敗条件・binding

1. 古いproofへの誤binding: 元一般SIMD comparer SHA D31CF484DB4078D733DB70CD7DF9271241B079366144C1C54BCCF078ED280165を全文明示対応で派生し、8helper AST不変を要求。旧SIMD ordinary bindingは旧絶対path/SHA C54FADC9A17F584EBF6267A337107EB1149F0B3B954EA9F30B409A9AB3BFD948/247296Bへ残し、新ordinaryはfull proof A98CA8C5B4ABA79F03D91171909755887DEC528AE50325F191EEA3BF63DC43CDのnative-codecへ別binding。
2. Compact/fullの未使用・matrix混同: 新full48/86/269、4variant、frame483496、tmp/PDB0、期待拒否8件を照合。bounded diagnostic heavy_events3223156、Some12892624/None0、encode/decode完全一致、Option40/plain32/legacy96を照合。診断EXEを正式計測しない。
3. 数値proof混同: C8B6DAA9DEFA6C97D6DD062682AA87139B0CC6C5F6782B642EA977783FCE4935の32/87/13、4matrix、各9293629 matched /2323408 batches /compact8398832、fingerprint f02dbdcb00adbe1d、legacy certificate fallback0。compact内のNone原因/補正回数まで0だったと推論しない。旧numeric/SIMD/Q15 proofも維持する。
4. source/歴史閉包の不一致: current support pinに加え全history proof closureを現在ファイルへ再hashし、既存wide/narrow numericの厳密owner/path/role/旧SHA379BFC1CCE693FCADD75AD6D8C375FEA2F10151EBA4B63D8462ADA91C2051BBF/1997B→修正済みSHA F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7/2054B例外2件だけを維持する。
5. CPU違反/timeout/CLI failure/非決定性/復元不一致/容量超過: その試行をterminalとし、自動再試行せずfailed report/attemptを残す。warmupをmedianへ読替えない。source/pin照合と、preflightより後のhistory closure実行状況を区別する。
6. 評価範囲逸脱: 仮に合格してもWindows x64 development encodeの比較のみ。holdout/カテゴリ、同境界decode、四native決定性、製品組込み/API安全性、総合7-Zip超えは別の証拠が必要。全要求が未証明ならgoalをcompleteにしない。

全source/proof/compiler/runtime/script/CWD/power/argv、round別wall/CPU/memory/threads、前後SHA、最終容量/processを記録する。計測helpers/round/order/gateは旧comparerから変更しない。
