# Compact posterior商のfull codec組込み: 実装前失敗計画

前goal turnはPROGRESS。新kernel数値proof C8B6DAA9DEFA6C97D6DD062682AA87139B0CC6C5F6782B642EA977783FCE4935 は32 checks / 87 CLI / 13 identities、9293629件×opt2/opt3×scalar/AVX2を独立u128商に逐次比較済み。今回は新別full候補へ組み込む。旧integer/Q15/SIMDのterminal正式比較は再実行しない。7-Zip超えは未達。

## 状態・拒否順

1. old integer heavyのKT大型分母/alpha/next_weightを維持し、KtTableにBackend autoを一度だけ保持。新try_nonzero4は16個のposteriorだけに使う。
2. leafを旧順で更新後、15..12、11..8、7..4、3..0の各4件をgroup変更前node/snapshotから準備する。正常kernelはOption<[u64;4]>だけを返す。生成済みPredictionの深さ別indexは一意で、同group内のnodeはまだ未更新。
3. 入力準備/確率/ceiling/積で拒否、またはkernel Noneなら、全groupを元のlane別posterior計算へ戻す。そこで旧leaf→root位置の元エラーを返す。先に別laneのエラーを返さず、count/weight/observations/historyの更新順を保持する。準備に副作用なし。捏造private Predictionの重複indexなどの内部破壊状態までの部分更新同値は契約外。
4. 4Result入力/戻り値配列を正常経路に残さない。codec wire/Bayes/light/schedulerの世代/poison/CRC/no-clobber/公開順は不変。商Q以上・対象外dも元経路へ戻し、正常確率を勝手にclampしない。

## 検証・失敗条件

- source/compiler/proof取り違え: Bayes-dominant codec0AD79D2C15CFFA96CDBED33421C20418C146BA223C872CFDCF5FD3F263ED0B64、schedulerC286EC6D84894A889B5BD2153E0817BDA4FD22A2A684B8E2554F47BB21475656、integer heavy00D546612907EAA420D4D292358D288349D00BB906B9A1B4AC9A4F4E7B2BF2AF、KT5C42A1076967540ED4EA32194D52B2A0A12A8D8190D80AC77C73A0EF632C6D3D、compact helper978B932A7D0CFAA7C8090DB75C6928E7746798F91213CA7AE89231810A9C222Dを固定。元4sourceからの全文明示置換、newsource/EXE/証拠の前後SHA/長さ。
- 未来学習/意味の変更: native(auto)/checked(auto)/scalar/checked-scalarの4条件×7入力で全文frame/stdout/restoreを旧proofと比較、旧decoderへの/旧frameからの双方向restore。固定frame483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12、上限483599Bを維持。scalar/AVX2の数値4matrixもbinding。
- 新kernel未使用: cfg khc_compact_countsだけの別診断EXEでfixed encode/decodeを追加実行。counterはtable.posterior4の実戻り値Some/Noneを一回だけ数える(重複計算しない)。table呼出し数は4×sum(scheduling.processed)を要求し、compact>0。frame/restore/元encode stdoutも照合し、encode/decode counts一致を要求。診断だけの追加stdoutを正規EXEへ混入しない。非参照native CLIだけが計数対象、無効private状態の入力準備失敗はcounter外と明記する。
- エラー/公開: native(auto)で5不正frame出力なし、encode/decode no-clobber、missing input拒否。例外をspeed成功と扱わない。private全拒否分岐/全poison遷移の実測は今回の通常E2Eと区別して未検証に残す。
- 容量: build/khc-causal-compact-simd-20261002、32MiB事前/事後guard。既存input/frameを再利用し、4正規EXE+診断EXE、必要なframe/restore/JSONだけ(約24MiB見込み)。/DEBUG:NONE、新Cargo target/cache/raw traceなし。fresh root一回、child120秒、上書き/自動再試行なし。
- 誤採用: 成功statusはcorrectness_and_size_passed_not_timed。新EXEの正式速度比較は別契約で一度だけ、固定CPU15%/483599B/encode median<574.5624ms/warmup1+9/順序/CLI境界は維持。四native、holdout/カテゴリ、同境界decode、製品組込み/安全性、総合7-Zip超えは別途必要。
