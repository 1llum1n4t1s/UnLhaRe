# 4lane商候補: 実装前の失敗計画

前goal turnはPROGRESS。通常/checked全codecの論理回数監査を完了し、77471768回のrefinement、うち22827543回はKT大型分母、残り約5464万回がposterior/alphaであると確認した。既存scalar浮動小数推定をheavy updateの16個の独立posteriorについて4laneへまとめる一つの候補を試す。正式性能試行はCPU16%でterminal、同候補再試行なし。

## 候補仕様

laneごとにd==0を積overflowより先に拒否し、a.checked_mul(b)を要求。power-of-two dはshift。1<=d<2^32かつn=a*b<2^32*dのみ浮動小数推定の対象とし、それ以外はnative商を保持する。未使用/不適格laneは0/1へ置換し、他laneへdiv0/NaN/Infを持ち込まない。

対象laneのunsigned nをf64へ変換し、4laneのf64除算を一度に実行。商はsigned32へ直接落とさず、約0〜2^32の推定を4scalar i64経由でu64へ変換する。推定が2^32に丸められる境界も保持し、checked整数積を一回DOWN/UP補正した後、q*d<=nかつn-q*d<dのcertificateで確定する。certificate不一致ならnative商。推定の精度に返却値の正確さを依存させない。

Backendはscalar/AVX2を明示選択でき、autoはCPU/OS feature検出を一度行う。x86/x64のAVX2対応時だけtarget_feature avx2関数へ入る。他platformや非対応CPUはscalarへ戻す。Rust公式のdiv/set/store intrinsicはAVXの4lane f64を扱うが、初回実装はAVX2を機能境界とする。四nativeの実行検証は未達として残す。

## 失敗条件と先行検証

1. unsigned n>i64::MAXの変換、signed32商域、q≈2^32、lane順を誤る。既存9293629recordのd/q境界・seed・全特殊値を同じ順に4件ずつ処理し、各laneを独立u128直接除算oracleへ実比較する。fingerprintだけで証明しない。
2. 不適格/zero-denominator/overflow laneが隣に影響。混在batchと1/2/3件tailを検証し、lane別Resultとエラー順を保存する。paddingをmatched件数へ加算しない。
3. backend間・最適化/overflow違い。opt2/opt3かつoverflow-checks=yesの外部CLIでscalar/AVX2を強制し、逐次比較と完全要約一致を要求する。AVX2未対応なら強制選択を明確に拒否し、実行済みとしない。少数のBigInteger商も外部から直接照合する。
4. unsafe条件/誤dispatch。SIMD unsafeはfeature証明済みの4double入出力のみ。未aligned storeの書込み先は4要素の固定配列。SSE/MXCSR/priority/affinity/powerは変更しない。普通のscalar実行にAVX専用命令を要求しない。
5. batch算術は正しくてもTree updateの意味を変える。posterior inputsは更新前snapshot、alpha/retainedは元の式、weightsは元のnodeから取得。16posteriorをまとめ、旧leaf→rootのcount/weight更新順は維持する。正常状態の未来学習も7入力の全文frame/stdoutと双方向restoreで確認し、拒否/poison状態を別途扱う。
6. full codecのcopy/source/helperの取り違え。元候補/source/contract/数値proof/compiler/新EXEを前後SHAで固定し、明示置換の全文対応を要求する。原source/proofは未編集。新unit testなし、E2Eに最小再現/argv/SHAを残す。
7. 容量増大。numeric root8MiB、後続full root32MiBを事前・事後guard。raw数値/trace/ETL/Cargo targetを作らず、recordを逐次比較しbounded要約/先頭witnessのみ保持。各child120秒、新root一度、既存attempt/出力上書きや自動再試行なし。
8. 整合だけで高速と主張。命令/論理回数と実速度は別。サイズ483599B・encode median<574.5624ms、warmup1+9/circular/host CPU15%/全CLI境界は変えない。正確さ合格後に新source/EXE/proofを固定して一回だけ正式比較する。holdout/カテゴリ/同境界decode/四native/製品安全性/総合7-Zip超えは別途未達。

参考の公式intrinsic定義: https://doc.rust-lang.org/core/arch/x86_64/fn._mm256_div_pd.html 、https://doc.rust-lang.org/core/arch/x86_64/fn._mm256_setr_pd.html 、https://doc.rust-lang.org/core/arch/x86_64/fn._mm256_storeu_pd.html 。閲覧の表示版はcacheにより1.89/1.98.1/1.99が混在したため、実行compiler1.98.1のcompile/runtime evidenceと区別する。
