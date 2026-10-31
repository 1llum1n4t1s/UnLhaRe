# 現candidateの段階別診断 — 実装前failure-first契約

前turnはexact-divの独立照合、別session改善6.12%/7.88%、最大batch、清掃を完了したprogress。研究基準はexact-div EXE SHA `8B5AE33E2507DE3B6DE649CF64901C6AEE239D0D091373617853D8080BE63D8B`、全frame483468B/SHA `B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A`。最新fullencode3481.2743ms、固定strict<574.5624msは未達。旧debugpairのCPU割合を現candidateへ移植しない。

今回はモデル/decoder/wire/係数/深さを変更せず、現codecを別directory `causal-bayes-stage/`へcopyし、encode内の3境界だけでInstantを読む。BWT、encode_payload、CRC/metadata/frame封入の各elapsed nanosecondsと全encode内部elapsedをStats/成功JSONに追加する。内部stageは開始/途中/終了の連続時間差で、sumとtotalが一致するよう単一時系列のduration差を使う。読み取り・公開・process起動/終了時間はstage範囲外で、CLI wall/CPUと区別する。decodeはstage値0とし元の処理を変えない。per-bit clock/counter/追加array/プロファイラーは使わない。

既存source/module/binary/proofを更新しない。BWT/CTS/exact_div/Bayes/range/packedは凍結sourceへ相対参照し、codec本体の許可diffはmodule配線とInstant/Stats/JSON追加だけ。Rust1.98.1/edition2024/opt3/panicabort/debuginfo未指定。同じ現在ISA/Windowsのみで、別instrumented binaryの数値は元EXEそのもののfunction CPU帰属や厳密割合ではない。

失敗条件を先に固定: frame/復元/11metadata/CRC/grammar/確率/更新順の変更、負例拒否の変化、既存出力上書き、非zero実exit/異常stdout/stderr、JSONのstage欠落/負値/total不整合/CLI wallより大きな内部時間、clock計測後の無意味な最適化消去、diagnostic/controlのframe不一致、source/binary/input/proofの変化、既存work上書き、同時codec/build/recording、samplingでthread生涯を断言すること。

まず元36 checks/61 CLIをdiagnostic/current exact-div referenceで実行する（JSON追加を許可するが元fieldsを保持）。その後のみwarmup1＋測定9、diagnostic/current controlの循環順で別processにて固定group encode。実argv/exit/stdout/stderr/wall/CPU/ピーク/全frame SHA/前後source+binary+input+proof SHAを保存。診断初回最終は双方でdirect decodeして原group SHAと一致を確認する。controlのframe全byte一致と時間分布でinstrumentationの影響を確認するが、diagnosticを高速化採用しない。各stageの中央値は合計してtotal中央値を作らず、各processのsum==totalとstage shareを記録する。

所有root `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-stage-20260930/`。失敗時は最小proofと必要現物を保持。独立read-only役にsource差分/実exit/frame/hash/stage sum/集計を照合してもらい、支配区間の実観測から次の単一案を選ぶ。BWTが支配的でないならSA-ISへ盲目的に進まない。結果を未来の7-Zip勝利へ読み替えない。最終proof/初回最終archive/restoresを保持し、不要中間は今回rootだけの安全条件付き清掃。過去policy拒否対象/UnLha32Re/cache/registry/Git/公開/version/deps/holdoutを操作しない。
