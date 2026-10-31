# Default root検証の集約：互換性と限定速度

2026-10-05 Windows x64。k2/3/4それぞれの最初のdefault rootだけlocal wire/CDF検証し、以後の同じdefaultを再利用する変更を採用。root_defaultのnosplit＋uniform不変条件、各packetのdefault/objective整合検査を維持。nondefaultは従来どおり全部検証する。decoder、CDF、選択、packet、CRC、形式versionは不変。cacheはblock内3boolだけ。

## 実測

同一runner、同一7fixture、各mode warmup1＋9。時間はprocess＋binary I/O込み。各mode294 native呼出し、70符号列対すべて全byte一致（変更0）、140自己往復、14相互復号が成功。全pin前後一致。

| 入力 | Paid圧縮中央値 旧→新 ms | Low圧縮中央値 旧→新 ms |
| --- | --- | --- |
| repeat4KiB | 149.767→103.500 | 136.430→103.485 |
| all256×8 | 136.174→108.325 | 140.042→108.266 |
| random64KiB | 396.543→383.553 | 348.895→321.153 |
| alice29 | 311.713→292.719 | 267.574→252.628 |
| kennedy | 786.733→768.107 | 678.023→645.626 |

repeat/all256は旧新min/max範囲も分離。alice/kennedy等は範囲が重なるため確かな速度優位とは言わない。圧縮率は完全に同じ。復号実装も変更せず、Low kennedy復号中央値295.340→311.989 msの変動を含め全raw sampleを保持している。最大RAMはいずれも64MiB ceiling内。

## 回帰

`cargo test --locked --offline --release --target x86_64-pc-windows-msvc --test khc_block_normal --test khc_block_adversarial --test khc_model_boundary -- --test-threads=1` 成功。固定all.groupをUNLHARE_KHC_FIXED_INPUTへ指定。30故障/30回復、有限入力/oversize、3block、最大分割モデルを確認。lib＋新example clippy -D warningsと変更2Rust rustfmt check成功。全repo/container/非Windows nativeは今回未再実行。

再現E2E成果物：build/khc-product-e2e-20261005/block-normal-28328/result.json、block-adverse-13356/result.json、model-boundary-33592/result.json。

## 保存・再現

新default probe SHA256 675F919E7C57EE074211CB7D6894248E2082C98D99F70AB5E007938DD2F978FD、旧leaf probe SHA256 A92088A87879B4328EA61179BCAD7BAB741D1BE2CB9DACE1598C523FBE2F234D。新targetだけをbuildし旧EXEは再構築していない。

`run.ps1 -NewHelperExe <khc_default_probe.exe> -NewHelperSha256 675F919E7C57EE074211CB7D6894248E2082C98D99F70AB5E007938DD2F978FD -BaselineHelperExe <khc_leaf_probe.exe> -BaselineHelperSha256 A92088A87879B4328EA61179BCAD7BAB741D1BE2CB9DACE1598C523FBE2F234D -Attempt <未使用名> -HistoryMode paid`。Lowはmode low・別Attempt。AllowDifferentFramesは付けない。

- Paid report：build/khc-cpu-measurement-v2-20261005-default-paid/report.json、25140 B、SHA256 DD6928626EACA627CA7E350219FCFAD012909054C12254FB96C2C9C3F72310FD。
- Low report：build/khc-cpu-measurement-v2-20261005-default-low/report.json、25132 B、SHA256 8719A904F3E89A5A03E0B13937FE30DDA359FFEAC210AAA1AE9877D6644537A4。
- report計50272 B、raw/frame disk保存0。E2E累計6329083 B/8MiB。
- 共有Cargo累計6114026509 B、元baselineから207233429 B追加/256MiB、残り61202027 B。空き約29.5GB。削除/Git/新依存/公開なし。

opop6基本観点はDEFAULT_PLANの採用分を親が完了した。Performanceは反復呼出しと実測、Hardening/Testerはdefault条件・byte互換・悪性入力回帰、Cleanerは同原因に統合。Modernizer/Normalizerは独立変更不要。Asyncは寿命維持、Startup/Intelは非該当。今回委任なし。

## 次の根拠と未達

paid_model::parse_packet_nodeはdefault rootでuniform(k)を1024回計算してdispatchへ代入する。kはそのloop内で不変。uniformを1回だけ計算し、対象slice.fillで複製する方式は整数CDFと検査を保ちながら呼出しを減らせる。decoderとencoderのForest parse双方に効く候補だが、まだ実装・実測していない。新candidateは今回のdefault EXEをbaselineとして保持し、全frame/CDF復元・悪性入力・最大splitの同条件検証を行う。

先の7-Zip直接比較はleaf版の結果（SEVEN_ZIP_RESULT_20261005）。この変更後の全11file対7-Zipは未再測定なので倍率を更新していない。GOALはactive、総合7-Zip優位は未達。次の改善も独立blockの局所高速化を完成条件へすり替えず、圧縮率・速度・メモリ・未見評価の事前ゲートを維持する。
