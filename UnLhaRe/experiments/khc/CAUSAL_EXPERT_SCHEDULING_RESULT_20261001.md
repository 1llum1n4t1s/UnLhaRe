# Causal expert scheduling: correctness とサイズ

通常構成の CLI E2E は成功。固定開発 group の完全 frame は483496Bで、固定上限483599Bを103B下回る。凍結balanced KT frame483469Bより27B大きい。速度はこの段階では未測定、総合7-Zip超えは未証明。

証拠は `build/khc-causal-expert-scheduling-20261001/report.json`、SHA256 `370534F32A979FE2768CD60C29DFBD8342CD7B358C15C4D510945B8F8DD35E7A`。50 checks、63 CLI、83 identities、すべて成功し、終了後の長さ/hashを再照合した。通常native EXE236544B SHA `0737E2FFD936ECD89EA2FD4F8907AC0CD6C0766072BCE56CBB65AABDA7C981EA`、固定frame SHA `CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12`。

空/単byte/全256byte/反復/周期/seeded random/固定groupをnative、forced portable、連続heavy参照cfgで圧縮・復号。frame全byteと復元hash、通常cfgのschedule件数を照合し、固定group反復も一致。小journal64recordの診断cfgではforced replayと多数の切替を実行し、独自magicの往復と通常magicとの交差拒否を確認した。旧新magic交差拒否、代表5破損、出力no-clobber、入力欠落も確認。通常input上限超過fixtureはこのstageでは再実行していない。

| 件数 | 固定group合計 |
| --- | ---: |
| 全観測event | 7622618 |
| heavy処理（replayを含む） | 3223156 |
| replay | 434286 |
| active観測event | 2788870 |
| pending未処理 | 4399462 |

heavy処理は全eventの42.2841%。これは整数操作件数であり、57.7159%の時間短縮を意味しない。light/Bayes/journal/再開コストを含めたfull CLIで別途測る。class2には一時的な誤活性化があり、そのreplayも集計に含む。logical journal reserved/peak4980736records、record arrays19922944B、最大8388608records。全process peak memoryまたはhard memory capの証明ではない。

参照cfgではactive予測2788870件のheavy Q15とheavy Bayes Q15が、全過去eventを連続学習した参照と一致した。有限実行での比較であって、544B Prediction全体や全内部状態、独立数値oracleの証明ではない。f64の4環境native決定性、製品のparent-handle公開安全性、cancel、metadata、holdout、同境界decode、総合性能は未確認。

再現: `pwsh -NoProfile -File experiments/khc/causal-expert-scheduling/verify.ps1`。入口は既存rootを拒否するので、保存済み証拠を上書きしない。生成rootの絶対パスは `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-causal-expert-scheduling-20261001`。保存量22305245B、owned tmp/reparseとも0、用途を終えた巨大一時入力はこのstageでは作っていない。ソース/CLI/入力/出力/ログは再現証拠として保持。
