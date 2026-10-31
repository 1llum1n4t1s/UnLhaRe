# KT exact reciprocal tableの数値CLI条件

親が新 `kt-reciprocal-table/{exact_kt.rs,audit_cli.rs,verify.ps1}` を所有する。source対応を保持した実分布診断後に、本契約とexact proofを保存してから実装する。tableは65537*u64=524296B、Model所有にできるVecでglobal/static cacheなし。通常native32 helperは凍結参照、大分母はそのratioへfallback。no-correction証明のdomain外でtableを使わない。

失敗条件:

- zero+one checked overflowよりcap/equal/table計算が先、error分類が旧KTと異なる。分母1や>65536をlookupへ入れる、reciprocalの丸め違い、商がBigInteger floorと異なる、table bytes/sizeが異なる、source/compiler/直接oracle証拠のcurrent hold/after不一致。
- LEu32 zero/oneの8B input、LEu64 probability/error-code/method/reciprocalの32B outputが違う。methodはerror0/equal1/table2/fallback3、errorはcounts overflow1/cap2。その他unexpected helper errorはCLI失敗。empty、最大524288records、不完全record、cap+1、invalid-count error priority、existing-output sentinel、path refusalを正しく扱わない。120秒期限超過、stderr/exit/Stats異常、所有tmp残存。
- 全d=2..65536にzero=0,total,floor(total/2),floor(total/3),floor(2*total/3)を含む327675records、旧KT65536records、境界/overflow/cap/equalの追加recordsが独立oracleと不一致。通常/forcedportable各opt2/3の全raw又は同mode反復が異なる。forcedportableは大分母だけ旧fallbackを使いtableの精度/利用は変えない。他OS native検証とは称さない。

新root `build/khc-kt-reciprocal-numeric-20261001` にsource/current identities、raw input/BigInteger expected/全output、compile/CLI log、ownership/inventoryを保持。CLIは全入力を評価した後に自身がCreateNewで獲得したtmpだけをhardlink no-replace公開し、所有tmpだけを削除する。既存root拒否・自動retryなし。

この段階はhelperのみ。Model/full codec/速度/peak memory/4native/製品/holdout/総合7-Zip超えは未判定。新unit/Gitstagecommitpush/CPU設定/他process停止/外部write/threshold緩和なし。
