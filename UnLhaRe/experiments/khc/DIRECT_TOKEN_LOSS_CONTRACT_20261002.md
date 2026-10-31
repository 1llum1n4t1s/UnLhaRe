# direct-tokenモデル損失の分解診断: 実行前契約

## 根拠・反証・目的

old575791byte、P256610222byte、Dirichlet590737byteで、全て固定483599byte gate未達。3候補の数値/full E2Eは成功、正式性能は未実行。既存source/proofを変更しない。今回の問いは、どのrank/length・観測量の層でモデルが損失を作るか、およびconstant prior64への変更と有限精度/正支持の違いを分離できるか。cold supportの改善が全書庫のサイズ差の全部を説明するとは仮定しない。prior64が旧directより予測損失を減らさなければ、単なる精度引上げだけで解決する仮説は棄却する。

## 集計定義（モデル選択前）

fixed all.group2811006byte SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76のみを1回read/BWTし、凍結grammarと同じrun/next-use rank/length token列を生成する。
実際の3つのimmutable ContextModel sourceをimportし、同一key/limit/tokenを同じ順でqueryしてupdateする。cfg model_audit count snapshotを用い、更新後state/rescaleは定期全count比較と終端全count比較で一致させる。rank/length context式、escape byte数、rank/length interval889227件ずつ、runs889227、escape742、alphabet257/primary1762795は固定fullのstatsへ照合する。これは新encoder/frame生成ではない。

モデルから取得したactual frequency/totalについて -log2(f/t) をf64で集計する。同時にactual root/local countsから独立の配列prefix sumを取り、
- old理論: (rootCount+4localCount)/(rootPrefix(limit)+4localPrefix(limit))
- continuous prior64: (64rootCount+DlocalCount)/(64rootPrefix(limit)+DlocalPrefix(limit))
を計算する。Dはglobal全total、local全total Tである。old式はactual旧intervalへ毎token整数照合する。P256/new actual intervalも独立通常u128 prefix CDFへ毎token比較する。counterfactual prior64は圧縮wire/CDFではなく理論予測分布、量子化されていない数値診断である。

P256/newは同じ理想prior64を異なる有限精度と正支持で近似している。各層で次を報告する:
old ideal bits、prior64 ideal bits、P256 actual-CDF ideal bits、Dirichlet actual-CDF ideal bits、
prior_strength_delta=prior64-old、
P256_precision_support_delta=P256-prior64、
Dirichlet_precision_support_delta=Dirichlet-prior64。
差の分解に整合性誤差がある場合は拒否する。一様支持と丸めをこの診断だけで個別分離したとは言わない。

rank/length別、query前のT別8bin（0/1..7/8..31/32..127/128..511/512..2047/2048..8191/8192..16383）、固定16cellsの件数とbitsだけを保存する。全合計・bin合計・token件数を照合する。escapeのideal8bit×742は全モデル共通として別欄。実frameのpayloadbitsとの差も報告するが、range整数割り/flush/丸めなどを含むのでentropy sumを実圧縮サイズや速度と同一視しない。f64は診断専用でwireには使わない。

## 実装前失敗・実行制約

入力/magic/stats/token/update順ずれ、prefix truncation・local/global total取違え、CDF整数不一致、counterfactual denominator0、NaN/infinite、bin境界/合計不一致、f64累積誤差で不当な勝利主張、余分な入力コピー/出力frame/rawtrace、root上書きやsource途中変更を失敗候補とする。入力・root・prior・dirichlet counts/oracle・compiler/runtime/importをreadlock/hash前後で固定。実allocation失敗注入や4native/performanceを主張しない。

親はdirect-token-loss/loss_probe.rs、verify-loss.ps1と結果文書を所有する。fresh build/khc-direct-token-loss-20261002、8MiB予算、1opt2/overflowyes EXE+小JSON、予想300KiB以下。child120s/stdoutstderr65536/report512KiB、debuginfo0 /DEBUG:NONE、Cargo/PDB/cache/rawtrace/frame/restoreなし。モデルcounts/table/BWTはメモリだけ、ディスクには16cell集計/件数/digest/identityを残す。ガードは事前事後確認でquotaではないため個数/JSON上限を先に評価。existing root上書き/同条件自動retryなし。

fullproofはold B2CBF04F6CAFA79DA72EB082A0C957DE468C9AC4945186D8DDABC1EB8AA91C4F、prior942C0FBF794C5A9A80479AD815A61E79F3A67EAB435FB848D40EFD18F68F944B、newDA54B607BC0076D380ACF43B292EBE2D6E8F26940640E0B35B387B7A21A7F4CDを保持・照合する。実行後必要な診断結果と次の反証可能な仮説を保存する。全goal、固定gate、CPU条件、正式境界は不変。Gitstage/commit/push/version/公開/外部書込み/x86/共有cacheは除外。

