# Model統合検証のsource対応・schema修正

初回work `build/khc-q32-native32-model-20261001` は `CTS correspondence failure`、CLI実行0で終了した。source全文比較が、clone末尾に欠けた改行1文字を正しく拒否した。元balanced CTSは末尾LF2個、cloneは1個。sourceの正規化で検査を緩めず、cloneへ末尾LF1個を戻す。helper pathだけが差分になる条件を維持する。

実親proofのstatusは `verified`。新verifierが想定した `verified_numeric_not_timed` は別numeric helperのstatusであり、親schema照合を `verified` に直す。親proof SHAと直接使用するraw/expectedの全byte/current identities照合を維持する。

失敗root/reportは保存。修正後の別root `build/khc-q32-native32-model-20261001-correspondence-fix` で一度実行する。自動retry、既存root上書き、速度gate緩和はしない。旧helper・元CTS・CLI・frozen fixturesは変更しない。
