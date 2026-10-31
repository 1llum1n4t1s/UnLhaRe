# 標本段階診断の結果（正式速度評価ではない）

固定corpusに対する診断EXEのencode/decodeを各1回実行し、7確認・5CLIが成功した。既存full proofの841識別レコード（重複パスを共有して検証）と、今回の453個の識別対象を照合した。圧縮frame 483496Bと復元2811006Bは、既存frame/元入力と逐次実byte比較で一致。既存の第1 stdout行・学習件数も一致した。

- 契約: `SAMPLED_STAGE_PROFILE_CONTRACT_20261002.md`、SHA256 `B9FEA87D801C2C3F05522862D84C7394347CDA38B72DB51960DF22DE76A8A25E`
- 検証器: `sampled-stage-profile/verify.ps1`、SHA256 `EE06A07CA0E7AC21512C2DE6B9AA923A3C761F05BE8227723C86F214C682BCA6`
- 証拠: `../../build/khc-sampled-stage-profile-20261002/report.json`、SHA256 `64037FC5F4525EE2A3094E5404EEAECB61AFDDDB8A6738D9767B4B3B533F21F7`
- UTC実行: 2026-10-01T21:09:38.8380439Z ～ 21:09:51.9517562Z

## 内訳と限界

以下は計測コードを含む診断EXEの観測値。BWT/entropy/initは各1回のspan壁時計、4つのModel行はcall×標本平均による推定であり、実測total/CPU時間/正式CLI中央値ではない。entropyの親spanはModel処理と観測器を含むため、行の時間を合算してはいけない。

| span | encode ms | decode ms | 記録方法 |
| --- | ---: | ---: | --- |
| BWT / inverse BWT | 125.684 | 84.114 | 各1回の観測 |
| entropy | 2885.420 | 3243.916 | 各1回の観測、子spanを含む |
| light init | 1.286 | 1.374 | 各1回の観測 |
| heavy init | 2.439 | 1.956 | 各1回の観測 |
| light predict | 516.899 | 555.646 | 7622618 calls / 7456 samplesの推定 |
| light update | 310.337 | 348.648 | 7622618 calls / 7521 samplesの推定 |
| heavy predict | 630.670 | 706.462 | 3223156 calls / 3232 samplesの推定 |
| heavy update | 833.856 | 948.940 | 3223156 calls / 3204 samplesの推定 |

両方向とも初期化の寄与は小さく、モデル予測・更新が次の削減候補。特にheavy updateが標本平均推定では最大。ただし解像度の制約がありlight updateの標本中央値は0nsのbucket、モデル4spanのmin/maxにも量子化・観測コスト・割込みが含まれる。約1/1024の標本と固定65bucketに外れ値も残したが、これだけで関数間の厳密な比率、速度改善率、正式ゲート合格を主張しない。

次は重み更新・比率計算と、lightを含めたイベント当たりの処理量削減を検討する。初期化だけの最適化では、現在の厳しい全CLI速度目標への大幅な前進は期待しにくい（本診断からの推論）。数学的等価変換なら既存数値oracle/状態遷移/完全codec経路で確認し、アルゴリズムを変更する場合はサイズ条件も改めて評価する。

## 容量・未達事項

追加生成物は5ファイル合計4016388B（約3.830MiB、報告JSONを含む）。予算8MiB。新しいCargo target/cache、PDB、生トレース、ETLは作っていない。cfg-off EXEはビルド確認のみで実行していない。復元ファイルとframeは再現可能な証拠として保持し、別実験へ無条件に複製しない。

固定CPU上限15%、サイズ483599B、全CLI encode中央値574.5624ms未満、warmup1+測定9、single-threadの条件は変更していない。既存terminal正式試行の自動再試行、control/native再実行、初期化分離の確認待ち手順の実行もしていない。正式性能・holdout/カテゴリ・同境界decode・四native・製品/API組込みと安全性の証明は未達で、7-Zip総合超えを達成したとは扱わない。
