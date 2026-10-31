# CTS正規化演算のf64化 — 実装前failure-first契約

前段のdiagnostic9測定はBWT share中央値29.6793%、payload70.1505%、seal0.1702%。別instrumented binaryのstage wallであり凍結EXEのfunction CPU比率ではない。BWTだけを0にしても観測payload中央値2449.6404msが固定<574.5624msより大きい。従ってSA-ISを今回の主案にせず、payload内で毎bit17-level走査を行うCTSの整数正規化をf64へ変える一案を検証する。影響の帰属・速度・圧縮率は未証明であり、実測で採否を決める。

`causal-bayes-float-cts/`に元exact-div codecとCTSの隔離copyを作る。既存BWT/primary/grammar/Bayes/range/metadata/decoder制約、D16/7classes/全131071nodes/class、initial history0、initial weight1/2、count/global class observation、update順は維持。変更はCTS数値表現だけ。Q48の各floorを除き、KT=(zero+0.5)/(total+1)、予測=w*KT+(1-w)*child、alpha=1/(class_observations_after+1)、posterior=w*observedKT/observedMixture、nextWeight=alpha+(1-2alpha)*posterior とする。これは元Q48実装と全確率同値ではない別の有限精度方式で、全frame同値を合格条件へすり替えない。原理は既知CTSで、新発明や実数CTSの理論保証そのものとは呼ばない。

一次資料 [VenessらのCTS著者論文](https://arxiv.org/pdf/1111.3182) §3.1 のleaf→root switchingと正規化した重みの再帰を参照するが、class-global時刻/zero初期history/Q15/有限精度/独自BWT grammarは本研究の契約。論文のCalgary成績を本候補の圧縮率・速度へ転用しない。

1側のposterior分母に丸めた `1-zeroMixture` を使うと小確率でcancelするため、Predictionはzero/oneの両枝のmixtureを同じweighted sumで保持する。KT-oneは1-KT-zero、leaf-oneはそのKT-one。各nodeのq-one=w*KT-one+(1-w)*child-one、q-zero=w*KT-zero+(1-w)*child-zeroとし、観測後は保存した側を使う。重み×pkはqを構成した同じ積、加算項は非負。root-zeroのみ `(p*32768+0.5).floor().clamp(1,32767)` でQ15へ変換。fast-math/FMA intrinsic/逆数近似/係数調整/深さ探索/事後class選択は使用しない。

新研究magic `KHBAYF01` を使い、旧decoderへ互換性を装わない（header長36は同じ）。magic分離以外のcontainer/packed alphabet/size accountingを変更しない。製品wire/default/.NET/API/version/deps/UnLha32Reを変更しない。

## 先に失敗条件

- NaN/inf、KT/qが0以下/1以上、weight/posterior/alpha/retainedが[0,1]外、Q15範囲外、count/index/observation overflow、割当失敗、初期重み/history/update前後順の変更を拒否。有限精度の不正値を黙ってweight clampしない。
- decoderの予測とencoderの予測の非同期、opt3/opt2の出力非決定性、CRC修復意味攻撃/悪いmetadata/長さ/limits、既存出力上書き、失敗後公開、旧magicの誤受理を拒否。
- 圧縮率は新全frameで実測する。fixed size<=483599を超えた場合、全負例E2Eは完了しても時間計測・model/context/精度/深さsweepをせずsize no-go。
- size通過後のみfrozen exact-div/current candidate/native11file7zをwarmup1＋9の循環順で測定。strict<574.5624ms/固定2811006-byte group/単一thread設定/全container accountingを維持。全process argv/exit/time/peak/hash/proof/初回最終復元を保存。
- 元全36 checks/61 CLIをnew opt3/new opt2で実行し、2別process fullframe、11metadata/本文、自己/交差decodeを確認。旧decoderがnew magicを拒否し、新decoderがold magicを拒否する実CLI負例も行う。sourceの数式/有限値/正準Q15変換/互補branch/decoder同期と保存証拠を独立read-onlyで照合する。新unit testは追加しない。

独立数値照合は研究audit CLIから実Modelを呼ぶ。inputは最大4096個の(class,bit) 2byte records（class0..6/bit0..1）、outputは各更新前Q15-zeroのu16 LE列。emptyも正準入力。argc、非regular/長さ上限/奇数長/class/bit、read中上限超過、割当/算術異常、既存outputと書込失敗を失敗条件として先に固定する。JSONはoperation/observations、失敗時stderr+exit1/出力なし（I/O故障清掃万能保証はしない）。親は別実装のdecimal疎木・再帰predict/更新で同じ固定short/adversarial/interleaved recordsのQ15を独立比較し、初期1/2、1bitsの1/2→3/8→19/72を含む。opt3/opt2のaudit output同値、invalid input/no-clobberを実別processで検証する。数値CLIは圧縮性能の根拠にしない。

Rust1.98.1/edition2024/opt3 or opt2/panicabort/debuginfo未指定。浮動小数点の決定性は実検証したWindows x64/toolchain/opt範囲だけで、macOS/ARM64は未検証として保持。f64にしたこと自体を速度・portable互換・7-Zip勝利と呼ばない。必要な改善は依然約83%で、今回案だけで達成を約束しない。

所有root `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-float-cts-20260930/`。既存workは拒否。既存実装/source/proof/controlは凍結し、snapshotを改変しない。再現証拠を保持して今回新rootの不要中間archivesだけ安全条件付き清掃。過去policy拒否対象への再試行・回避、共有cache/registry/Git/外部公開/holdoutの操作なし。
