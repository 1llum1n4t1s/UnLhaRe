# CTS posteriorの逆数近似batch: 実装前失敗計画

直前のsampled-stage診断は7確認に成功しPROGRESS。heavy updateのcall×標本平均が大きかったが正式性能ではない。今回はcompact posteriorの4double除算を、4floatの逆数初期値とdoubleで2回のNewton補正、numeratorとの乗算へ置換する。元の整数certificate・1段上下補正・None時の既存exact fallbackは維持する。速度向上は仮説であり、数値同値だけでは採用しない。

1. domain/丸め: compact helperのd in 1..Q、n<Q*dの検査とunsigned u64→f64変換を変更しない。dをf32へ丸めて初期逆数を作るが、2回のr=r*(2-d*r)には元のdouble dを使う。FMA/fast-mathを新設しない。浮動推定への精度仮定を正しさの根拠にせず、q*d<=nかつn-q*d<dのchecked整数certificateを必須とする。
2. 拒否/overflow: q*d、上下補正、差は元のchecked演算と同じ。NaN/∞/domain外/bad quotientでNoneを返し、呼出し側の既存厳密経路に戻す。zero denominator、product overflow、power-of-two、legacy narrow/native経路の拒否順は変更しない。legacy divide4_avx2は凍結し、compact try_nonzero4だけ新しいestimate4_avx2を呼ぶ。
3. unsafe/CPU: AVX2利用可否は既存runtime guard、intrinsicsはAVX2対象関数内、storeuは4doubleのみ。新しいISA/affinity/priority/power設定を入れない。非x86またはforce scalarは元のscalar divideを維持し、今回はWindows x64のみ実行。
4. 数値反証: 既存compact auditを無変更で使い、独立u128除算oracleに逐次照合。opt2/3×scalar/AVX2の4条件それぞれ9293629 record、2323408 batch、small1114112/bucket7077888/upper38400/special729に要求値を固定。finite suiteでのcompact適用件数・全summary/fingerprintは旧数値proofと一致させる。tail1/2/3、混在lane/拒否、独立BigInteger14条件も同じCLIで検証。raw recordを保存しない。1値でも差またはcertificate fallback異常ならfailed、同じrootを自動再試行しない。
5. source境界: 元helper SHA978B932A7D0CFAA7C8090DB75C6928E7746798F91213CA7AE89231810A9C222Dとproof C8B6DAA9DEFA6C97D6DD062682AA87139B0CC6C5F6782B642EA977783FCE4935を固定。helper/監査/検証器の完全source対応を確認し、support/コンパイラ/全旧proof identitiesを前後照合。新実験以外のsource/proofは編集しない。
6. 容量: fresh build/khc-reciprocal-batch-20261002、8MiB予算、見込み1MiB未満。2個の小CLIとbounded JSONのみ、/DEBUG:NONE、Cargo/cache/PDB/生traceなし。disk-budget前後、子CLI120秒、runtime/compiler/argv/CWD/hashを報告。数値記録は逐次比較と要約に限定。
7. 未達: この数値CLIはfull codec、状態遷移、正式性能、四native、holdout/カテゴリ、製品/API安全性を証明しない。次にfull codecへ接続し既存圧縮frame/復元/summary/旧decoder相互運用を確認する。固定CPU15%・サイズ483599B・全CLI encode median574.5624ms未満、warmup1+9等は変更しない。同候補terminal正式再試行/確認待ちのobserver初期化分離も行わない。goalはactive。

設計資料はRust公式intrinsics (_mm_rcp_ps, _mm256_cvtpd_ps, _mm256_cvtps_pd)とIntel RCPPS仕様。逆数命令は近似値しか返さないため、integer certificateを省略しない。資料:

- https://doc.rust-lang.org/core/arch/x86_64/fn._mm_rcp_ps.html
- https://doc.rust-lang.org/core/arch/x86_64/fn._mm256_cvtpd_ps.html
- https://doc.rust-lang.org/core/arch/x86_64/fn._mm256_cvtps_pd.html
- https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2b-manual.pdf
