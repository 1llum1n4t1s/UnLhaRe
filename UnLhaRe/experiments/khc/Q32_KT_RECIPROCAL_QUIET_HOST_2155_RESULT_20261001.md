# 新しいquiet-host比較の結果: warmup中の負荷超過で不採用

2026-10-01 21:55の低負荷観測とユーザーの報告を受け、[新契約](Q32_KT_RECIPROCAL_QUIET_HOST_2155_CONTRACT_20261001.md)に従って別rootで単回の比較を開始した。preflight5点は0/0/0/9/0%で成功したが、candidateのwarmup復号後にCPU27%を観測し、15%上限超過で停止した。9回の本測定は0回。中央値、改善率、採用判断、7-Zip比は算出しない。自動retryやCPU設定・同居processへの介入はしていない。

## 実行と原本の保持

元comparator SHA `CE15DBEB417857C351A412ADF366C95511EEA00AFCCCA69FE228EDA2EF1C550C`を保持。新`compare-quiet-host-2155.ps1` SHA `4C23FDEC7B4EEB17CBA123F7C502B1D88DE1FD55AE6641177A6E65CBC17D1B03`はwork-directory文字列1か所と改行表現以外、全文が元と一致することを実行前に確認した。parser成功、関連processなし。新contract SHA `4499AC03C7919240ADA9AFC1728E7DE6EA9168415BF4BB858753F59D5C7DDC1C`はwrapperのread-only lock下で保持し、終了後も一致した。

開始前にlauncherの誤った固定pwshパスと、`Get-Command`の2件を単一文字列として扱った誤りがそれぞれ発生した。どちらもcomparator/preflight/CLIを開始せずworkも未生成だった。実在するbundled pwsh `C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe`（7.6.5）へ修正して初めてcomparatorを起動した。候補・測定式・CPU guardの変更ではない。

実行開始22:01:40 JST、終了22:02:55 JST、shell exit1。root `build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/performance-quiet-host-2155` のreport SHA `1F95232A30606A2F7B8555A90B2DE7B3BC52FADF5641B07912358CFFE9FBE493`、status `failed`、error `Host CPU busy; no ordinary performance adoption allowed.`。

## 到達した検証と未到達部分

- 97source pinsと前提proof検査に進み、proof evidence2033filesを含むprovenance2227recordsを現在readlockへ束縛した。終了時before/after差0。22:05の再確認でも全2227recordsの現存長さ/hashが一致した。
- CLI3回はnative version、candidate warmup encode、candidate warmup decode。exit0/timeout0。warmup encodeのwall2978.4183ms、decode2763.7935msは失敗試行のraw診断であり、正式性能や他試行とのpaired比として採用しない。
- frame483469B SHA `7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C`。復号後CPU guardのthrowが本体の復号照合より先に発生したため、終了後に別途restore2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`を確認した。この追加確認で失敗reportを成功へ変更しない。
- host負荷観測11件のうち失敗1件、`q32-kt-reciprocal-group/decode/0-after`、2026-10-01T13:02:35.4536249Z、27%。control/native圧縮、9測定、native一覧/復号の同session比較、paired集計には未到達。

owned root9915086B、tmp/reparse0、関連processなしを22:05に確認。report、入力、warmup書庫、復号結果を再開/失敗解析の最小証拠として保持する。共有cache、旧試行、x86は削除/変更しない。

固定size条件だけを維持していても、strict encode574.5624ms、holdout/カテゴリ、同境界decode/peak memory、4native、製品統合は未達。総合7-Zip超えは未証明。全体goalはactiveのまま。次工程は同条件の再測定を重ねず、既存LZ/BWT/CTSのno-goを参照して、必要な計算量を減らす別の設計仮説を反証可能な形へ絞る。
