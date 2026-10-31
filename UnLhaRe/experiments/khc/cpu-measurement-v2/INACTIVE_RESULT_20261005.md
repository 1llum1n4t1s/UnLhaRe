# 非活動クラスのFit再利用：実測結果

2026-10-05 Windows x64。製品encodeの全値ゼロクラスのみ、block内で遅延構築したlow Fitを共有する。highのzero Fitは作らない。活動クラスの処理、選択tie、整数CDF、root順序、packet、CRC、decoder、形式versionは変更しない。cache＋活動Fitの同時生存容量を計上した。

## Before / After

同じprogress-driven runnerで7入力、各mode warmup1＋9測定。プロセス起動・binary I/O込みの時間であり、純codec CPU速度ではない。

| 入力 | Paid圧縮中央値 旧→新 ms | Low圧縮中央値 旧→新 ms |
| --- | --- | --- |
| empty | 60.472→61.713 | 56.803→60.550 |
| 1 byte | 61.935→62.001 | 46.852→59.780 |
| repeat4KiB | 323.864→164.168 | 229.218→133.354 |
| all256×8 | 321.691→141.773 | 228.430→136.106 |
| random64KiB | 491.269→387.117 | 370.397→319.091 |
| alice29 | 407.797→313.906 | 324.529→273.305 |
| kennedy | 757.344→765.501 | 662.824→658.719 |

repeat/all256/random/aliceでは圧縮min/max範囲も旧新で分離。kennedyおよびempty/1Bに確かな改善なし。復号は変更しておらず、測定変動を改善として主張しない。Paid最大WSは旧27652096→新27815936 B、最大観測privateは双方24838144 Bで、64MiB上限内。共有Fitぶん一部小入力のprivateは約127KiB増える。

Paid/Low合わせ588 native呼出し完走。140組ずつ自己往復と毎回の符号列全byte一致、14回ずつ相互復号、全pin前後一致を確認した。圧縮率は完全に同一。固定3blockは別E2Eで157149/237852/120312 Bの旧費用維持と完全復元を確認したが、旧新全frame比較の対象外である。

## 検証

- `cargo test --locked --offline --release --target x86_64-pc-windows-msvc --test khc_block_normal --test khc_block_adversarial --test khc_model_boundary -- --test-threads=1` 成功。固定入力は既存all.groupを環境変数UNLHARE_KHC_FIXED_INPUTで指定。30故障/30回復、9有限入力、oversize拒否、最大分割モデルを含む。
- `cargo clippy --locked --offline --release --target x86_64-pc-windows-msvc --lib --example khc_active_probe -- -D warnings` 成功。
- 変更Rust3filesのrustfmt checkと対象2sourceのgit diff check成功。全repo回帰・非Windows nativeは今回は未再実行。
- E2E再現成果物：build/khc-product-e2e-20261005/block-normal-43280/result.json、block-adverse-39112/result.json、model-boundary-27760/result.json。

## 再現・予算

新target khc_active_probeだけをbuild。旧khc_speed_probe EXEは再構築しない。

`run.ps1 -NewHelperExe <khc_active_probe.exe> -NewHelperSha256 254286AE96D9AB7654553B6B6613E0314C0D324C3A27B6A201CAC2BF16991B7F -BaselineHelperExe <khc_speed_probe.exe> -BaselineHelperSha256 CEA86D9E85532928368431CCD0B04F5457FB57FCE2201C6E8095F5B8C5D7A679 -HistoryMode paid -Attempt <未使用名>`。LowはHistoryMode lowで別の未使用Attemptを指定。

- Paid report 24426 B、SHA256 986CBD909025FBBEE5FB076B3AB0CD709A4A8B603CD31F4FC02121B2ED268147、build/khc-cpu-measurement-v2-20261005-active-paid/report.json。
- Low report 24395 B、SHA256 33352513C3FF4448FC611AD355C6E399D016561DB961369A33836CE3518BDE0C、build/khc-cpu-measurement-v2-20261005-active-low/report.json。
- 入力/圧縮物はRAMだけで保存0。今回report計48821 B。E2E専用先累計6320674 B、8MiB以内。
- 共有Cargo累計6109458782 B、元baselineから202665702 B追加、256MiB上限内（残り65769754 B）。空き約30GB。削除・依存追加・Git書込み・公開なし。

opopは失敗先行計画の採用分を実装・実証した。Performanceの効果は入力依存、Cleanerは同原因へ統合、Hardening/Testerは上限とbyte検証を維持。Modernizer/Normalizer/Async/Startup/Intelの独立変更は不要。前回のread-only analyst結果を親がcounts/bundle/paid_model/packetの実コードで再確認し、今回の編集・検証は親だけが担当した。

## 次の具体的な弱点

paid_model::build_nodeはcompact_frequency(quantize(counts))をleaf候補とし、splitとの比較だけを行う。非ゼロcountsでもuniform/pureを選ぶと「符号長＋metadata費用」が安い場合を、現在は候補として比較していない。root uniform費用0・通常uniform leaf3bit・pure leaf3＋dominant幅という既存wire内の選択肢を検討する。これはモデル費用選択の改良であり、新圧縮原理とは主張しない。

次の試作では現在方式を候補に残して理論目的を悪化させず、fullframe実サイズ（range丸めを含む）は実測で確認する。encoder出力が変わり得るため、今回の「旧新全byte一致」をその試作の合格条件へ流用しない。旧decoderで新frame復元、メタデータ込み圧縮率・時間/RAM、全正常/異常経路を検証する。事前固定の7-Zipゲートを維持し、未見評価へ進む前にdevelopment上で採否を決める。

GOALはactive。今回7-Zipとの新比較はしておらず、再現可能な7-Zip優位は引き続き未達。
