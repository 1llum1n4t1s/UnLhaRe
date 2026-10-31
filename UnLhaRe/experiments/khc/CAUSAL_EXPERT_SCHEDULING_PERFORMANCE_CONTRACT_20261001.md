# Causal scheduling: 正式 full CLI 比較契約

correctness/サイズ成功を速度の成功へ読み替えない。新しい構成はcausal-expert-schedulingの通常native EXE236544B、SHA256 `0737E2FFD936ECD89EA2FD4F8907AC0CD6C0766072BCE56CBB65AABDA7C981EA`。旧候補のCPU quiet失敗を再試行するものではなく、journal/light/replayを含む別アルゴリズムの初回正式測定。開始前と実行前後のtotal CPU上限15%を維持し、違反時は失敗のまま残し自動再試行しない。ユーザーの直前の低負荷観測を正式quiet checkの代わりにしない。

固定開発入力はKHSGRP0、2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。候補完全frame483496B SHA `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`を全encodeで要求。固定ゲートは完全frame<=483599B、single-thread full CLI encode中央値strict<574.5624msのまま。

凍結balanced KT control217088B SHA `7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0`は旧frame483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`。候補とcontrolは同じ入力だが新旧magic/予測が異なり、frame同一性は要求しない。旧reciprocal E2Eと数値/Model証拠は旧binaryへ結び、今回候補は新50checks/63CLI/83identitiesのproofへ別途結ぶ。前段の既存proof DFSとsupport pinsを維持し、新proofも同じDFSで追跡する。

測定harnessは凍結 `causal-bayes-q32-kt-reciprocal/compare.ps1` SHA `CE15DBEB417857C351A412ADF366C95511EEA00AFCCCA69FE228EDA2EF1C550C`を基にする。8個の関数、quiet observer、process launch/exit/stdio drain wall、child CPU、1ms要求のOS観測、timeout120秒、warm1+9、3方式循環順、集計式と固定閾値を保持。変更は候補/新root/方式label/新frameと新proof binding/source pins/事実に即したnotesに限定し、source対応表と関数AST全文比較で照合する。診断cfgは測らない。通常成功stdoutのscheduleカウンタも測定時間に含む。

native7za26.03 x64、1335296B SHA `EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0`。11ファイルをmanifestと本文hashで検証し、`-t7z -mx=9 -m0=LZMA2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mta=off -mtc=off`で同session実行。候補/controlはgroup1出力、nativeは11出力のためdecode時間は診断だけ、採用判定に混ぜない。初回/最終の復元hashとnative SLT、途中frameは直接復号済み初回frameとのSHA一致を要求する。

新rootは `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-causal-expert-scheduling-20261001\performance`、既存拒否/CreateNew。失敗条件を事前固定: quiet>15%、pin/length/ancestry差、source/input変更、CLI失敗/timeout、round不足、誤復元/native metadata差、frame差/非決定性、proof不備。safe root作成後は失敗reportも保持する。preflightで止まればroot/report未作成を確認して保存する。priority/affinity/power設定変更、他process停止、閾値変更はしない。

環境はWindows x64/Ryzen5 7640HS 6C12T、std-only rustc1.98.1 opt3 edition2024 panicabort。実際のOS/CPU/PowerShell/rustc/power schemeとhashはharnessで記録する。journal reservedはhard cap/OS peakの代用にしない。4native、holdout/category、同境界decode、製品統合、安全性/API要件を含む総合goalはこの単一開発測定で完了にしない。
