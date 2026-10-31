# 逐次LZ＋order-2 literal expertの一案size screen

固定Canterbury serialized group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、archive<=483599B / single-thread encode strict<574.5624msを維持する。通常Lazy LZは過去の全group size screenで531353B（47754B超過）。既定Beamの整理では新しい出力同値の大幅削減根拠を得られなかったため、既定を変更せず独立研究cloneで新しいentropy modelを一案試す。既定LZ source SHA `43B334AEFD6E8585C2181E025F329CFDF3ED40F3B0DDBBC5789A94275E9EBC73`、frame wrapper SHA `3E37BD51E1CCD6CEC7BF5585F459BB3290803CB12E4F740763F30BB36777A8A3`。新unitなし。

前提の反証: 逐次LZのliteral符号化を改善し、Beamを使わず47754B以上の不足を埋められるか。現時点では仮説であり速度上限・size利得の保証はない。all-byte PPMや以前のorder-context codecとは異なり、LZ token/Rep grammarを保持してliteralイベントだけにexpertを追加する。既存macro/parser/table/transformのno-goを別名で再試行しない。

新expertは直前2byteだけから((previous2*257+previous1)&511)を選ぶ512contexts×256binary-prefixのu16確率。既存Rep予測literal expertとのu16混合重みを同じ131072prefixへ保持し、初期値はいずれも16384。Q=32768、p=round((w*p_old+(Q-w)*p_new)/Q)、範囲1..Q-1。実bitのposteriorはfloor(Q*w*observed_old/(w*observed_old+(Q-w)*observed_new))、次重みは256+floor((Q-512)*posterior/Q)。両expertの既存1/32更新を実bitの受理後に実行する。最大積2^45未満、分母正。追加storage524288BをModels要求容量へ計上する。global cache/学習済み外部model/多threadなし。

変更は`lz-literal-mix/{lz.rs,mod.rs,codec.rs,verify.ps1}`研究cloneのみ。元cloneのtest moduleは複製しない。Lazy LZ＋RangeのみをCLIへ公開し、Beam/RANS/deferred-updateは候補の対応範囲に含めない。通常cfgは元control、khc_literal_mix cfgは新expertと固有magic KLC2LAB\0。製品KHC/default/ABI/versionに混入させない。共有bt/profile/range等は元sourceを参照し、source/依存rlib/compiler/current hold/afterで束縛する。

実行前の失敗条件: source/correspondence/pins不一致、入力長SHA違い、controlの固定frame長531353B不再現、literal価格とencode/decode混合確率の不一致、追加要求容量漏れ、probability/weight bounds逸脱、非因果参照、繰返しframe不一致、復号/CRC不一致、破損や既存outputの公開、path ancestor reparse、64MiB cap/odd操作誤受理、120秒timeout、owned tmp/reparse残存。Input/source after差分は成功を禁止する。

新root `build/khc-lz-literal-mix-20261001` は既存拒否・自動retryなし。opt3 control/mix compile→代表空/短入力/全byte/反復/周期/seeded randomのencode/decode→固定groupの各2回frame一致/復号→代表破損/取消/no-clobber。size gate超過は、この一案をno-goとして閉じ、weight/context数/parseのparameter sweep・速度比較・holdoutをしない。size通過時だけ新しいquiet-host全CLI性能契約へ進む。今回のstageは時間を測定せず、速度・decode/peak memory・4native・製品・総合7-Zip超えを証明しない。

調査台帳(opop): Modernizer=現runtimeで可能な依存変更はこの性能問いに非該当、Normalizer/Cleaner=既存cache/遅延生成/width2の整理は既実装、Performance=新しい出力同値の重複削減は証拠不足、Hardening=元sourceのbounds/fallible allocation/errorを保持、Tester=CLI E2Eのみ、Async=逐次計算で非該当、Startup=新model初期化を将来の全CLIへ含め未測定、Intel=ローカル仮説のscreenに現在外部仕様は不要。analyst起動はthread limit reachedのため親が全観点を直接調査。basisのPATH cargo呼び出しは失敗、絶対path `C:/Users/IMT/.cargo/bin/cargo.exe +1.98.1 check --locked --offline --example khc_lab`はexit0/10.3888秒。source編集なしの同コマンド最終再確認とdiff checkを行う。新modelはユーザー許可済みアルゴリズム研究の設計forkであり、opopの既定挙動を保つ保守変更として採用したものではない。
