# Bayes Q15等値短絡の適用頻度 — 診断前契約

目的は固定Q32の全Stream::bitにおけるprimary_zero==cts.zero()の発生率を測り、exp2省略候補の実装価値を判断すること。数学上は正規化有限weightと通常binary64丸めで等値Q15は変わらないが、ここではshortcutsを実装せず、元のBayes計算/更新を全て実行する。loss差dominance/LUT/精度/grammar/CRC/形式を変更しない。発生率は速度改善率ではない。

所有は新bayes-equality-eligibility/{codec.rs,verify.ps1}を親一人、新build/khc-bayes-equality-eligibility-20261001/、本契約/開発記録。凍結Q32 codecからモジュール相対参照と診断文言を変え、成功cts予測の後にclassごとのtotal/equal AtomicU64をRelaxedで加算、正常CLIの末尾だけJSONで14countsを出す。元encode/decode/outputの数値経路は全文同一。atomic overheadがある別診断EXEなので通常性能を計測/採用しない。

先に失敗条件: source/input/exe/proof変化、祖先reparse、既存root/output上書き、invalid class/count/Q15JSON、frame483469B/SHA7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C不一致、復元2811006B/SHA18B8不一致、encode/decodeの全class counts不一致、equal>total、total0、子timeout/非zero/予期しないstderr。固定8MiB境界の数学的観測上限562036803を超えないことも照合する。数値pathの変更や計数から速度達成を推定した場合は無効。

Rust1.98.1/edition2024/opt3/panicabort/debuginfo未指定、source/support/compilerを読込み前readlock。新root/CreateNew/no-reparse、所有子だけfinally解放/120s、2 actual診断CLI encode→decode、新frameを元full proofに照合し、元入力と復元を全byte比較する。reportとsource/binary/input/generatedframe/restoreはbeforeafter SHA固定、生成物と14countsを保持する。新unit/製品/API/version/deps/Git/公開/他process停止/priority/affinity/power/cache/UnLha32Re/registry操作なし。

ここは正確性と頻度の診断であり、host busyでも通常性能へ転用しない。親のsource許可差分/実raw/count検査後、別の読み取り担当が同じ証拠を独立照合する。低頻度なら等値shortcutの新候補・新比較は作らず、効果上限が小さい案として記録する。全目標は総合7-Zip超過のまま、局所診断の成功を完了へ読み替えない。
