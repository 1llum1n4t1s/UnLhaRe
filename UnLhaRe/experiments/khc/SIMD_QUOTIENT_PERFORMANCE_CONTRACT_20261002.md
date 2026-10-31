# 4lane posterior商: 正式比較の実装前契約

前goal turnはPROGRESS。数値9293629件×4条件、full47 checks / 83 CLI / 263 identitiesを確認した新候補を、一度だけ固定条件で正式比較する。旧integer/Q15候補のterminal試行は再実行しない。goal全体の達成は未証明。

## 固定条件

- KHSGRP0 all.group2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76、11件Canterbury development manifestを維持する。holdoutとは別。
- 新candidate247296B/SHA C54FADC9A17F584EBF6267A337107EB1149F0B3B954EA9F30B409A9AB3BFD948、complete frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12。旧balanced control217088B/SHA7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0、7za26.03 x64/SHAEDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0は不変。
- native7zaは -t7z -mx=9 -m0=LZMA2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mta=off -mtc=off。全frame483599B上限、encode median厳密<574.5624ms、single-thread設定を維持する。
- 三codec circular順、warmup1+measured9、CLI起動前〜終了/stdout/stderr drain後のwall、子CPU別、各process120秒。quiet preflight5×1秒、各CLI前後総CPU<=15%。priority/affinity/power/他processを変更しない。違反/失敗はその試行のterminalで、自動再試行しない。
- 初回/最終だけ直接復号とnative SLTを照合し、中間は復号済み初回と完全書庫SHA一致を要求する。native11file/候補1groupの異なるdecode境界を総合勝利や採用へ使わない。

## 失敗条件・証拠

1. candidateと旧proof取り違え: 旧Q15 ordinary bindingは旧binary絶対path/SHAへ残し、新候補はfull report09A9497FC34C580E7D18EFF3F0BCB988439FF40B6221BE77074C354B8D19BE7Eのnative-codec identityへ別途binding。47/83/263、frame bytes、4variant、tmp/PDB0、拒否8件を照合。
2. 数値proof混同: report FE390BBE820107F32570BFC6E416E5FA947743848131F8EB8513BFC4E02E1EDE、32/87/10、4matrix、各9293629 matched、2323408 batches、fingerprint e5c97b90b4768836、fallback0。CLIは引数なし/負のu64 queryだけexit2、それ以外0。旧Q15 numericの6/7/19も維持。
3. 計測定義変更: 旧Q15 comparer SHA3E5E745572D8F6AEEB5026E481AF329D8FD00ED000F85BA673F143EC8E81F232から明示置換で全文照合。8measurement/helper AST本文を不変とし、round/median/quiet/opts/timeoutとprocess採取は変えない。変更は新label/root/binary、追加proof/pin、容量見積り/上限、説明だけ。
4. source/pin/歴史proof不一致: 新旧全source/proof closureを現在ファイルへ再hash。wide/narrow numericのcapacity guard旧SHA379BFC1CCE693FCADD75AD6D8C375FEA2F10151EBA4B63D8462ADA91C2051BBF/1997B→StrictMode修正済みSHA F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7/2054Bだけ、従来の厳密owner/path/role例外2件を維持し、その他不一致を拒否する。
5. CPU静穏違反/CLI失敗/timeout/非決定性/復元不一致: failed report/attemptに保存し、warmupをmedianへ読替えず、勝利/採用としない。既存attempt/rootを上書きしない。
6. ディスク増大: 専用performance root96MiB、空き5GiB+予算を事前/事後確認。実decodeは30回でなく6回、約16.87MB。archiveは通常約14.51MB、snapshot2×input約5.62MB、thread/provenance/argv reportを加えて通常48MiB未満見込み。native archiveが入力並みに増えた場合の約29MB×他codec9.67MB、decode/snapshot/reportの余裕を含め96MiBを枠とする。既存full親は20.22MB、performanceと合わせ128MiB枠。EXE/compiler/Cargo target/raw trace/ETLは新設しない。guardは事前/事後チェックで、OSの書込み強制制限ではない。
7. 評価範囲の逸脱: development encodeの比較だけ。holdout/カテゴリ、同境界decode、四native決定性、製品API安全性・組込み、総合7-Zip超えは別途必要。全要求の現在証拠が揃うまでgoal completeにしない。

source/pin/proof identity、CPU/OS/runtime/script絶対path/更新UTC/CWD/power、実CLI argv、round別wall/CPU/memory/threads、前後保持SHA、最終容量/processを成果物へ残す。
