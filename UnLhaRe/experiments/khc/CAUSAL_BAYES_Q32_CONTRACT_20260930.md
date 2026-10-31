# 固定Q32・保守的posterior CTS — 実装前契約

目的は支配payloadの整数除算をu64以内に収める固定精度候補の検証。研究基準SA-ISの全CLI中央値2543.9207msはstrict574.5624ms未満に届かない。Q48のwide積/除算を減らす仮説であり、演算型だけで高速化を証明したとはしない。LUT/float/signedの未測定候補は混ぜず、SA-IS基点に別のCTS数値仕様を接続する。Q48同値、実数CTSの理論保証、新発明、製品互換を主張しない。

## 仕様と先行反証

Q=2^32、D16/7classes、Node counts u32/weight u64、zero history/weight Q/2。KTはfloor((Q/2)*(2zero+1)/(total+1))。予測zeroはfloor((w*KT+(Q-w)*childZero)/Q)、leafはKT、rootを(zero+2^16)>>17でQ15丸めclamp1..32767。履歴/leaf→root更新/primary/Bayes/grammar/packed/range/CRCは維持する。

単純な旧posterior式をそのままQ32へ縮小する案は採用しない。BigIntegerでw=Q−7、pk=Q/2−4、child=3を計算するとweighted floor=2147483640、floor(w*pk/floorMixture)=4294967297>Qになる。これは有効な整数引数の反例で、特定のbit履歴での到達性は別問題。precision低下による重み越境を黙ったclampで隠さない。

新canonical更新は観測側の更新前pkとchildを使う。bit0は保存KT/childZero、bit1はQ−KT/Q−childZero。sum=w*pk+(Q-w)*child、ceiling=floor((sum+Q−1)/Q)、posterior=floor(w*pk/ceiling)。観測側の保守的な上側丸めを仕様として明示し、rangeのzero予測floorとは区別する。alpha=floor(Q/(class_after+1))、retained=Q−2alpha、nextWeight=alpha+floor(retained*posterior/Q)。これはQ48のposteriorモデルと厳密同値ではない。新研究magic `KHBAYQ32`、header36/packed alphabetは維持し、旧/new decoderが互いのmagicを拒否する。

## 支持範囲と失敗条件

grammarのrankは1+1+(9+8)=19 bits以下、lengthは1+(24+23)=48以下。run数<=8MiB+1=8388609、総bit/各class観測上限は67*8388609=562036803。不正指数/不正rank/lengthの停止前の呼出もこの上界に含むことを独立source照合で証明し、証明できなければ実装を止める。Tree updateは同上限を超えるclass observationを変更前に拒否する。このcapは既存8MiB codecを狭めるためではなく、全有効入力を含む算術支持範囲を明示するもの。

total<=562036803なのでKTの最小floorは3以上、最大はQ−3以下。KT numeratorは(Q/2)*(2zero+1)でu64以内、weighted sum<=Q*(Q−1)、ceil加算後<=Q^2−1=u64::MAX。ceiling>=w*pk/Qなのでposterior<=Q、alpha>=7、nextWeight<=Q−alpha<Q。全product/add/sub/div/count/indexをchecked/既存ガードで検査し、overflow/zero denominator/probability outside/observation capを拒否する。式/丸め/補数/更新順の誤り、誤ったQ48互換主張は候補無効。OOM/I/O故障注入の未実施は明記する。

## 所有・検証

所有は新 `causal-bayes-q32/{codec.rs,cts_model.rs,audit_cli.rs,verify.ps1,verify-numeric.ps1,compare.ps1,cleanup-*.ps1}`、専用 `build/khc-bwt-causal-bayes-q32-20260930/` と本契約/開発文書。codecは凍結SA-ISからlocal CTS、SA-IS BWT相対参照、新magicと未使用exact_div参照解除だけ変更。Bayesは元の凍結packed版。CTSの型/式以外のD16/7classes/木/履歴/update順は変えない。Rust1.98.1/edition2024/opt3・opt2/panicabort/debuginfo未指定、新unit/製品/API/version/deps/Git/外部公開/他process停止は禁止。

実audit CLIは最大4096(class,bit) recordsの更新前Q15列を返す。argc/regular/偶数長/容量+1/class/bit/no-clobberは作成前に拒否、create_new/write/syncと120秒制限を維持する。独立C# BigInteger疎木・再帰predict/update oracleでempty/既知列/一方連続/交互/全7classes/固定seed/最大batch、opt3/opt2・別process反復の全Q15を照合する。数値例の比例を速度へ転用しない。

全codecは既存38 checks/63 CLIのmagic相互拒否を含む検証を新仕様へ適用し、全入力復元/11metadata/本文/EOF、new opt2 cross/反復、CRC修復攻撃/上限/公開なし/no-clobberを確認。新frameのサイズとSHAを実測し、Q48のB4との同値や483468Bを期待値にしない。独立担当がmath/source/pins/raw/CRC/全expectedexitを照合する。fixed<=483599Bを超えた場合はsize no-go、別精度/モデルのsweepと時間計測を行わない。

correctness/数値/独立証拠とsize通過後だけ、候補対SA-IS control9AC.../native26.03のwarmup1+9/circular/39CLI、総container/全encode wall/child CPU/peak/初回最終復元を保存する。静穏observer読込前lock/preflight5/各子前後<=15%、fixedgroup2811006B/18B8...、native11件/options/1thread、strict574.5624ms未満を維持する。1session上限、host拒否は未判定、blind再試行/閾値緩和なし。holdout/カテゴリ/他OS/製品統合は未検証として区別し、総合目標は完了扱いしない。

全root/output/reportはCreateNew/全ancestor非reparse/既存root拒否、source/input/exe/proof readlockとbefore/after identityを保存。自己子だけfinally解放、用途終了した同backend重複だけreceipt付き清掃、初回最終/入力/oracle/proof/source/binaryは保持。共有cache/過去policy拒否/UnLha32Re/registry操作なし。
