# 測定開始前の固定と対応確認

2026-10-01 23:20 JST、正式候補の新比較入口を準備した。これは測定成功報告ではない。

- `causal-expert-scheduling/compare.ps1` SHA256 `785727BDEA01C90788707E352B215048D9934DA1848FFC5982BFBD4402EC69C2`、更新時刻2026-10-01T23:20:07.3778290+09:00。
- `performance-correspondence.json` SHA `25D301BD151A33DB7BBBFE6533155254F3D8CD0A631A921048AEE6E89039B1AC`。旧凍結scriptから18個の明示置換を順に適用し、改行正規化以外の全文が新scriptと一致。PowerShell parser正常、8個のmeasurement helper AST本文は旧scriptと完全一致。
- 支持source106 pins、新E2E83 identitiesの現在の長さ/SHAと保存後SHAを照合。新performance rootは不存在。
- 候補236544B SHA `0737E2FFD936ECD89EA2FD4F8907AC0CD6C0766072BCE56CBB65AABDA7C981EA`、旧control217088B SHA `7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0`、入力とnative7zaは契約で固定し、正式入口でも再照合する。

実行する絶対入口は `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\experiments\khc\causal-expert-scheduling\compare.ps1`、CWD `C:\Users\IMT\dev\UnLhaRe\UnLhaRe`。PowerShellは実在するbundled `C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe`。正式入口がOS/CPU/runtime/power scheme/各binary/source/inputの現在値と前後hashを記録する。

失敗時は同じ構成を再試行せず、terminal report/quiet観測/復元/残存を検査して結果を別文書へ残す。成功時も固定ゲートとpaired ratioを独立再計算し、総合goalと混同しない。
