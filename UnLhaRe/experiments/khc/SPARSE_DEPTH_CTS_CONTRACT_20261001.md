# 幾何深度CTSの一構成を先に反証する

17深度CTSのうち、過去bitのcontext深度0/1/2/4/8/16だけを混合する新研究形式を一構成として実装する。連続深度を間引いて重いposteriorを減らすアルゴリズム変更であり、旧予測/旧frame互換の最適化ではない。深度集合は短context0/1/2を残し以後2倍というclass共通規則、観測class番号でroutingしない。失敗時に深度集合やconfidenceをsweepしない。

heavy1eventのKTは17→6、posterior/mixtureは16→5。Q32のKT、mixture floor、posterior側ceiling、switch alphaの式、観測cap、leaf→root更新順は凍結CTSから保持する。ただし階層自体が変わるため同じ各式でも確率列は変わり得る。light、Bayes、過去gain64bits hysteresis、journal上限8388608records、因果的replayと通常successカウンタは直前schedulerを保持する。構成式数を時間短縮率に読み替えない。

historyは過去16bitsを保持する。各深度のcontext keyは元CTSの根から最新bit優先で辿ったsuffixと同じ。compact offset0/1/3/7/23/279、nodes65815を使用し、history.reverse_bits()から当該深度を切り出す。元tree BFS indexとは異なるが同じsuffixを同じnodeへ写す必要がある。7class Node16B arrays7371280B＋KT表524296B。allocator/他models/journal/BWTを含むprocess peak/hard capではない。

失敗を事前列挙: depth/offset/range差、history bit順逆転、context衝突、未来/currentbit参照、更新重複/欠落、算術/観測cap逸脱、元式の変更、scheduler/source/correspondence/pin差、continuous参照とreplay予測不一致、通常/portable/frame/復元/schedule差、小journalforced未実行、代表破損の公開、旧新magic混同/no-clobber破壊、source/input変更、120秒timeout、tmp/reparse残存、完全frameの固定size超過。

元CTSからの全文置換対応を記録し、全65536historiesについてselected depthのsuffix keyが元1bit-step pathと同じことをnative CLI E2E診断入口で確認する。binary丸ごとのroundtrip、native/forcedportable/continuous参照、小journal診断、反復、代表破損/既存出力拒否は直前の有限E2Eを保持する。新unitを書かない。context mapping診断は有限全16bit historyの証明だが、全内部状態の独立数値oracleではない。

新magic通常 `KHBSPR01`、小journal `KHBSPT01`。新root `build/khc-sparse-depth-cts-20261001`、CreateNew、既存拒否、std-only rustc1.98.1/edition2024/opt3/panicabort。入力2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`、完全frame<=483599Bを先に判定。失敗は速度/holdout/設定sweepを行わず保存する。通過時の正式速度は別契約でquiet15%、singlethread full CLI strict<574.5624msを保持する。

この一構成は未実装/未検証として開始する。4native f64決定性、製品path/publication、cancel/metadata、holdout/category、同境界decode/資源と総合7-Zip超えを省略して完成にしない。直前のCPU17%失敗を再試行する計測ではない。
