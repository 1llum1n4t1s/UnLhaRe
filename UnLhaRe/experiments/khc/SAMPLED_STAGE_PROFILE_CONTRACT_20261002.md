# モデル段階の標本プロファイル: 実装前失敗計画

前turnはcompact lightのfull51項目が合格しPROGRESS。正式速度試行はpreflight CPU32%でterminal、codec CLI0。今回は別の診断EXEで、初期化・予測・更新・変換/entropy段階の内訳を確認して次の削減対象を決める。競争速度評価・同候補の正式再試行ではなく、control/native比較・中央値・採用判断を行わない。observer/15%等の固定ゲートは変更しない。

1. 観測コスト/標本偏り: Modelのlight/heavy predict/updateは全call件数を数え、span別固定saltとcall ordinalのSplitMix64で約1/1024だけInstantを読む。samplingは入力値・所要時間・学習状態に依存させない。初期化/BWT/inverse/entropy全体は1回を直接記録。count/samples/sum/min/maxと65個の固定log2 bucketだけ保存し、全callの生timestampを作らない。外れ値は削除せずsum/max/bucketへ含める。標本もobserverで変化したcode/cache/preemptionの影響を受けるので、速度改善率や正式CLI時間へ読み替えない。
2. scope重複: entropy全体にはModel処理とtimer overheadが含まれる。親子spanの時間を合算しない。sample sumは全Model時間ではなく標本だけ。call×標本平均による推定は次の研究優先順位の参考に限り、実測total/独立CPU時間とは扱わない。
3. cfgで学習が変わる: 凍結compact-light codec/scheduler、light、node-u32 heavyのコピーへcfg-only timerを追加し、module pathをコピーへ明示する。guardは値/履歴/重みを変更しない。原source/proof SHAと全置換対応を照合し、profile encodeの第1 stdout行/frameを現在full proofと実byte比較し、profile decodeのschedule/復元を比較する。1値でも差があればdiagnostic失敗。
4. 件数誤り: fixed scheduling.events合計7622618にlight predict/update、processed合計3223156にheavy predict/updateをbind。initは各1、encodeのBWT/entropyとdecodeのinverse/entropyは各1、他方向coarse span0。両方向でcountとsample数は同じ。4Model span各1000標本以上、samples≤calls、sum/min/max整合を要求。timerはRefCellをcall中保持せず、nested callやDropでborrow衝突させない。
5. integer/時間異常: count/集計はchecked算術、Durationはchecked u64変換。ns値はnonnegative。静的seed/flagsを記録し、異常/PDB/stdout/exit/CRC/復元/identity変更/子process120秒でfailed report。失敗を自動retryしない。
6. source/境界混同: source proof SHA9DB9E948B5D9F270FB5C58D003DC6BF6650C61121A7F499D361B407B8108D2BDの51/86/841と全current identities、固定input2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76とframe483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12を照合。診断を4条件7入力full/E2Eや四native証明へ拡張しない。
7. 容量と実行: build/khc-sampled-stage-profile-20261002をfresh一度、予算8MiB/空き5GiB+予算を前後guard。cfg off/onの小EXEをcompile、onで固定inputをencode/decode各1回。offは実行せずbuild可能性だけ確認。見込み4MiB未満（frame約0.48MB+restore2.81MB+2EXE+bounded JSON）。/DEBUG:NONE、Cargo/cache/ETL/raw/PDBなし。sourceはapply_patch、旧証拠は保持。他process/priority/affinity/powerを操作しない。
8. 未達事項: 正式サイズ/速度ゲート、warmup1+測定9等は不変で、terminal再試行や確認待ちの初期化分離は行わない。holdout/カテゴリ、同境界decode、四native、製品/API組込みと安全性を残す。必要な全証拠がない限りgoalはactive。

診断の呼出し元・型・source derivationとargv/実環境/識別値をbounded reportに保存し、用途を終えた今回の一時物だけ安全確認後に清掃する。編集担当は親のみ、製品/x86/version/Git/公開/共有cacheへ変更しない。
