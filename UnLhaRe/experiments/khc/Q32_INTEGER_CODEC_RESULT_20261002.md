# Q32整数refinement: 完全frame同値・速度未測定

狭い整数seed/2段Newton/1up補正をheavy CTSへ組み込み、完全codecの有限E2Eは成功した。Q16精度変更ではなく、旧Q32の商を維持する演算実装の変更。固定group完全frameは483496B、SHA `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12` で旧schedulerと全byte一致し、上限483599Bを維持した。

根拠: `build/khc-causal-integer-refinement-20261002-comparison-repair/report.json` SHA `B7BE539DB0DA5786EAAA1BC7F4E43DC983A4495F21E6B2E80BADD999407D459D`、status `correctness_and_size_passed_not_timed`。32checks/53CLI/141held identitiesが成功し、終了後の現在値再照合でもSHA差0。owned tmp/reparse0。通常native238080B SHA `AD2D1D930F27FA73B70F1E096BBEDC35301244B0A2FA3130F689680430184A26`、overflow-checks付き239104B SHA `63D77A30EE1F6A1885E512D66EC5B31CB9517EA6A5F72529D65FC9E66F95D2C6`。

## 成功した範囲

- 旧heavy12置換、KT6置換、scheduler参照2置換、codec本文無変更の全文対応を入口で確認。コピーの末尾LF差も元へ合わせた。元のQ32/header/magic/confidence/grammar/BWT/range/primary/Bayesは変更しない。
- 空/単byte/全byte/反復/周期/固定seedrandom/固定groupの7入力で、通常/overflow-checksの新frameと保存済み旧native frameを逐次全byte比較。全encode stdout（schedule含む）が旧版と一致。両構成の復元と、旧decoder↔新frame・新decoder↔旧frameの双方向復元も全byte一致。
- 5破損magic/header_crc/payload_crc/truncated/trailingの拒否と出力なし、encode/decode既存出力保持、入力欠落拒否を実CLIで確認した。
- helper数値段階は各opt2/3で9,293,629件を直接u128除算oracleへ逐次比較。狭い版にはoverflow-checksを指定し、前段の全summary/非暗号学的rolling fingerprintも一致。正常domain certificate fallback0。独立BigInteger14queryも成功した。

## 実機machine codeの補足

既存split診断担当が、通常native codec EXEと固定llvm-objdumpのSHAを確認して読み取り調査した。0x140006c9f–0x140006d44の通常refinement/certificate経路は50命令、mulq4/imulq2、sbbq4/adcq1、条件jump2、DIV/CALL0。旧広いu128数値EXEの同役割経路は64命令、mulq6/imulq5だった。

Newtonのimulq→mulqは0x140006ca2/6ca9と6caf/6cb9、商推定mulqは6cc5、certificate productは6ce7。成功時6d42は6d6dへ進み、DIVを迂回する。不成立のみ6d52 divqまたは6d68 divlへ進む。別inline箇所0x14000c5a3–c63dにも同形がある。旧causal/native32では0x14000abaaのdivl %r12dが実在する。

これは構造からのsource対応推論でPDB行帰属ではない。静的命令数やDIV消失を速度改善と同一視しない。seed load、6乗算の依存列、可変shift、certificateコストが残る。以前の担当による補足であり、新独立著者レビューでもない。

## 入口修正・容量・再現

`Q32_INTEGER_CODEC_HARNESS_REPAIR_20261002.md` に最初の末尾LF差、StrictModeの空dir容量チェック、PowerShellのAsSpan呼出問題を記録した。基準を緩めず、計算を変えずに入口だけ修正し、新rootで実行した。失敗rootのreport SHA `AB515C5002B3B2C664FE157556A7C108F96A6EE9000A28CF0F93653A8EED580D` と候補を保持。初回の空rootは絶対path/祖先非reparse/内容0/使用processなしを確認して削除した。

共用guardのStrictMode修正後SHAは `F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7`。広い/narrow数値reportの旧guard identity1件ずつは歴史的記録で、現在一致を主張しない。math source/compiler/EXE/reportは元SHAを保持し、codec入口は修正版guardの現在SHAを保持して検証した。

数値2root＋失敗codec root＋成功codec rootの新生成物合計24,808,462B（約23.7MiB）。成功rootは約15.7MB。生numeric records・全逆assembly・ETL・新Cargo targetを作っていない。開始前/終了時256MiB予算に収まり、Cドライブの空きは約10.0GiBを維持した。

再現入口は `pwsh -NoProfile -File experiments/khc/causal-integer-refinement/verify.ps1`。既存rootを上書きしないので同rootでの再実行は拒否される。新しい明示rootを契約してから再現すること。全関連PowerShell構文解析エラー0、`git diff --check` 成功。数値helper/CLIのrustfmt確認は成功したが、凍結bodyからの全文対応を優先した旧codec/CTS clone全体の再formatはしていない。

## 次工程と未証明事項

通常nativeのfull CLI速度比較を行い、median strict<574.5624msと同session native7-Zip比を確認する必要がある。静穏上限15%、warmup1+9測定、3方式循環、native7za26.03の単thread LZMA2/64MiB、完全frame SHA/復元/固定inputを維持する。今回のcorrectness CLI所要時間から性能数値を作らない。

速度、host静穏下のformal測定、holdout/category、同境界decode、四nativeのfloat決定性、製品統合、安全性/APIの総合要件は未証明。数値helperの正常domain fallback0は単独CLIの観測で、全codecでの動的hit率を測った主張ではない。7-Zip超えのgoalはactive/未達のまま。
