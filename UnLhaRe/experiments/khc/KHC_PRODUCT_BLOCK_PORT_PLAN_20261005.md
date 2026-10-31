# 製品用block moduleへの接続

2026-10-05。自己完結frameの実byte往復が成功したため、凍結実験へのpath依存を残さず製品へ接続する。既存LHA形式・公開API・dirty変更・package versionは維持する。

## 所有権

codec担当は新`src/khc/block/`以下だけを所有する。親は`src/khc/mod.rs` container、dirty lib/mainの接続、CLI E2E、runner/verifier、仕様・README/DESIGNを所有する。実験source/EXE/reportは変更禁止。codeを書き始める前にblock/FAILURE_PLAN.mdへport固有の失敗条件を保存する。新block source合計160KiB以内、閉じた製品codec350KiB以内。追加依存・cache・build・native・Git・削除・外部・version操作はcodec担当が行わない。

## 接続契約

`src/khc/block/mod.rs`は親containerから`pub(crate) mod block`として取り込む。内部のencode/decodeは現在の`Result<(Vec<u8>,Stats),String>`とMAX_INPUT/HEADER/MAGICを維持し、必要に応じてcrate側が公開Errorへ対応させる。codecだけならWindows APIを使わず、Windows/macOS x64/ARM64へ同じinteger decodeを提供する。OS memory診断は製品codecへ入れない。

実験frameの同じmagic/rev/40B header/alphabet u16LE/model packet/range/CRC/storedを維持する。コードの必要部分をapply_patchで独立moduleへ配置し、crate root参照は同じblock内のsuper参照へ統一する。既存依存を増やさず、markerの名前変更だけを新方式と主張しない。

SA-IS/frontend、grammar、Dense、Hist/量子化/LUT、paid木選択/codebook、全class packet、integer range、visited付きinverseを必要範囲で接続する。histogramの旧分析機能、旧形式/teacher/旧E2E/native memory/reference大規模codecは持ち込まない。原理上不要な旧legacy baseline処理を通常経路へ残さず、portした部分と除外した部分をSOURCE_MAP.mdへ明記する。既存sourceを参照して実装してよいが、srcからexperimentsへpath/importする形式は禁止。

低履歴順のみのablation入口をencoder内部に追加できる。defaultは今回と同じ低/高から実wire費用で選択。ablationのためにwire versionやdecoderを変えない。未知header・allocation前上限・integer CDF・visited cycle・CRC・strict stored benefit・一般errorを握り潰さない契約は不変。

## port後の検証

親がnative製品buildと実API/CLI E2Eを実行する。port自体の証拠は単なるhash一致でなく、同じ有限入力と固定3blockの直接byte往復・30故障拒否・真frame費用との照合とする。frame符号列を変える変更を入れた場合は理由と差分を記録する。cargo fmt/clippy/既存LHA回帰を、既存shared build/cargoと容量予算で実行する。今回のproduct接続はRust/CLIのみでC/.NET ABIは変更しない。
