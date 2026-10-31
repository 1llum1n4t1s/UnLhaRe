# CTS/pool分離診断結果（2026-10-04）

数値を変更せず分離診断を完了。今回sampleした2子区間の時間和ではCTSが約68%、poolが約32%。次の局所調査はCTSを優先する。
この比率はpredict全体・payload全体・純粋なCPU時間の比率ではなく、7-Zip超えや正式性能の証明でもない。

| 同一sample集合の集約時間 | encode | decode |
| --- | ---: | ---: |
| CTS+pool親span | 18.3636 ms | 18.2844 ms |
| CTS子 | 9.9851 ms | 9.9821 ms |
| pool子 | 4.6418 ms | 4.5958 ms |
| 親から2子を引いた残差 | 3.7367 ms | 3.7065 ms |
| CTS / (CTS+pool子和) | 68.2653% | 68.4742% |

親spanはcontext/count取得後～pool完了後。観測のscope管理・clock/counter処理も影響する。親子を二重加算しない。
component×prefix8層ごと1始まりordinal%256==128、各方向14942枝をsample。固定総branches各3825340。
totals `[121,415562,13461,2296628,1,71469,7502,1020596]`、samples `[0,1623,53,8971,0,279,29,3987]`。
prefix1の2層はsample0で時間不明。周期・cold/rescale・clock分解能の偏りがあり、外挿・overhead補正は行わない。
保存timepairは3×completed scope、実時計のread attemptsは未追跡で、失敗時に時計をrollback可能とは主張しない。

## 実装と検証

- baseline codecは凍結copy、profile codecはmodel pathと旧pool配線のみの差分。modelはCTS/poolのclosure観測とadmit/finishだけ追加。数値原文へ復元したallowlist照合pass（CRLF・末尾改行だけ正規化）。Mathは旧Q32、exp-zero候補は使っていない。
- worker編集停止後、親がsample位相を以前のstageと同じ1始まりへ明確化。独立analystが変更後に配線・数値allowlist・counter拒否・全比較・runnerを再確認した。双方role既定 gpt-6.1-sol / medium。compile/CLIは親のみ。
- compile1回3088.1032ms（warning stderr563B）、契約CLI1回100.7624ms、profile CLI1回18270.9239ms、全exit0。CLI stderr0。計画済みの拒否診断は正常7ケース・期待Err17件、実時計0、拒否前後の全保存state保持pass。
- baseline encode1→profile encode1→profile decode1、input read1。全frame478750B×1、plain2811006B×1を直接比較。Proof全14field×2（CDF bits）とstats3組一致。peak candidate frames2/957500B、終了frame0、clone/frame/plain/input diskコピーなし。
- source graph13、197 identitiesをbefore/after/liveでSHA/bytes/UTCtick照合、不一致0。所有候補process0。
- baseline encode5613.2639ms、profile encode6341.8027ms、profile decode6175.2011ms。無観測/観測の呼出順、コード配置、追加処理が異なり、正式benchmarkや純粋なclock overhead比較には使わない。

## 容量と固定証拠

- 新source6file計87451B。生成物はEXE333312Bとreport70477B、合計403789B（約394KiB）。8MiB予算内。空き約69.70GiB。
- 前のexp-zero生成物と合わせても900264B（約879KiB）。これは今回の2rootだけの集計で、作業フォルダー全体の使用量ではない。削除は行っていない。
- report: `build/khc-quaternary-cts-predict-split-20261004/report.json` SHA256 `E1EF1915ECC9F3CE3A505B50D0FE3AF4986841B7ECFA20CB32E539FEDC9478EC`、70477B。
- EXE: 同root `predict-split-o2.exe` SHA256 `BA3F300FF95B1FE9A490BDE0148F1CE285D85F9A841DC59334661B9D2EFE8049`、333312B。
- source/入口: `quaternary-cts-predict-split/FAILURE_PLAN.md` / `verify.ps1`。既存出力先の再実行は拒否する。timeout・pipe/output overflowのfault注入による実際の終了・失敗報告は未実測。

次はCTS内の重複したmassの商/余りを再使用する案を、guard・tie-break・エラー順を維持できるか反証する。分布と実益はまだ未測定。固定総合goalは未達、採用条件は維持する。
