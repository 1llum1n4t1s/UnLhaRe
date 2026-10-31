# 低負荷の確認後に分離するKT reciprocal正式比較

前回の試行はpreflight14%→19%でCLI実行前に停止し、性能rootも未生成だった。ユーザーがCPU負荷低下を報告し、2026-10-01 21:55:25〜31 JSTの新しい観測は1/6/4/0/9%、平均4%、関連cargo/rustc/7za/codec/audit処理なしだった。以前のpreflight失敗の自動retryではなく、この条件変化に基づく新しい単回の正式比較を行う。実行時のobserverが再確認するため、この低負荷観測を将来の保証にしない。

元`causal-bayes-q32-kt-reciprocal/compare.ps1` SHA `CE15DBEB417857C351A412ADF366C95511EEA00AFCCCA69FE228EDA2EF1C550C`は変更しない。同じディレクトリの`compare-quiet-host-2155.ps1`は元全文からwork directoryの固定文字列1か所だけを`build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/performance-quiet-host-2155`へ置換したcloneとする。LF/CRLF以外の全文対応とPowerShell parser成功を実行前に検査する。計測8helpers、loop/aggregation、97source pins、proof predicate/DFS、全current hold/after、candidate/control/native binary bindingは変更しない。

元[性能契約](Q32_KT_RECIPROCAL_PERFORMANCE_CONTRACT_20261001.md)の単一thread/fullCLI、native11件solid、warmup1＋測定9、circular3、120秒timeout、全child前後のquiet<=15%、size<=483599B、encode strict<574.5624msをすべて維持する。表初期化と追加524296Bはcandidate全process測定に含める。既存CPU設定・process優先度・affinity・同居処理へ介入しない。

失敗条件は以前と同じで、加えてclone全文の置換以外の差、既存root、再開前から走っている関連処理、新contractの実行中変更を拒否する。source/依存/proof不一致、CPU上限超過、timeout、frame/restore/native metadata不一致、9測定欠落は不採用とし自動再試行しない。新rootのterminal reportを保存し、旧試行と混ぜない。

正常に全比較が終わっても固定developmentの一候補評価にすぎない。同境界のdecode/peak memory、holdout/カテゴリ平均、Windows/macOS x64/ARM64 native、製品統合の総合条件は別途未達として保持する。新unit、Git、公開、依存/version変更、x86調査は行わない。
