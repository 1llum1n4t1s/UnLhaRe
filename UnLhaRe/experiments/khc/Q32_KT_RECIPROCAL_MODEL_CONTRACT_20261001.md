# KT reciprocalの実Model統合条件（次工程）

前提numeric proof SHA `9E6CE54D564C602CBAD6ACADFDF67D9AB0D2444B7C4791AC5383CDEAB63BBF93`、36checks/42CLI/54identities/tmp0/reparse0、helper SHA `D102D534397EA91055DCF0716B05EB48F1CFB0642F1B45FA27A388C894CCFE25`。この時点でModel/codecには未接続、速度未判定。

親が新 `causal-bayes-q32-kt-reciprocal/{cts_model.rs,audit_cli.rs,verify-model.ps1}` を所有する。凍結native32 CTS `27775D82F1A94E013C83A2D42C8A004D7EF507ED09302EB1BB0704DCC798B0A0` からcloneし、exact_kt module参照を追加。Node::ktを検査済みhelperへ委譲し、そのerror文字列をResult<String>へ変換する。posterior/next_weightのgeneric exact_div moduleと計算は保持する。

KtTableはModel所有の1個、Model::newで構築し、Model::predict → Tree::predict → Node::ktへborrowする。Nodeごと/bitごとにtableを作らず、global/shared/process cacheも使わない。Node16B/Prediction544Bを保持し、Model所有メモリ+524296Bと構築時間は今後の全CLI/peak memoryに含める。

audit CLIはModel cfgに限定してfrozen11267records/7histories/7classes/17levels×5fieldsを使用。元旧opt2・3反復raw/独立BigInteger expected・通常/forcedportable opt2・3の新rawを全byte照合する。table storage bytesは実Modelから診断取得して検査する。古いbalanced-KT cfg入口を残す場合はtableをbatchで1回だけ作り、recordごとの新規tableを禁止する。unsupported入口を暗黙に遅くしない。

失敗条件を先に固定する: source/契約/compiler/直接使用するproof・input/expected/rawの長さSHA/hold/after欠落、許可したtable委譲・borrow・構築・監査storage取得以外のsource差分、error順/wire/layout不一致、未実行の推定件数を成功条件に使うこと、120秒期限超過、class7/bit2/odd/cap+1誤受理、既存output置換、所有tmp残存、通常codecへのnumeric audit混入。過去のclone書式をfmt cleanと主張せず、新helperはfmtを確認する。

Model historyの小batchではd>65536 fallbackのreal履歴到達はない。helper legacy fixtureは大分母fallbackを含むが、実codecの固定groupで別途確認する。共有tableの受渡しが成立しただけで速度又は全codecの成功とはしない。

新root `build/khc-q32-kt-reciprocal-model-20261001` を使用。独立oracle再利用であり新作者監査ではない。新unit/Git/外部write/製品/x86/CPU設定/閾値緩和なし。既存root拒否・自動retryなし。固定size/速度gate、holdout/4native/製品/総合7-Zip超えの未達を保持する。

実装前のaccessor補足: 凍結helperの`audit_bytes`はnumeric専用cfgのため、Model cfgから直接使えない。元helperを変更せず、新Modelディレクトリに`exact_kt.rs`をcloneする。変更は`audit_bytes`直前のcfgを`any(khc_kt_reciprocal_audit, khc_mixture_reuse_audit)`へ広げる1か所のみ。module参照はこのlocal cloneへ向ける。verifierは元helperとの全source correspondence、cloneの長さSHA/hold/after、fmtを検査する。numeric専用`audit`は通常Model/codecへ混入させず、KT計算・配列初期化・fallbackは凍結helperと完全一致させる。
