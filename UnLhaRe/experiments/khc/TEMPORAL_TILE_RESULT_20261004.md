# 時間partition：無料情報screen改善、paidモデルは未検証

固定65536-run/14tileの無料Qscreen452387Bは旧static504637Bから52250B改善し、サイズ条件483599Bまで31212Bの余裕を得た。これは保存モデルを無料にしたin-sample情報診断で、実書庫や速度の達成ではない。180526 active rowsを保存する費用とモデル簡略化損失を払えるかが次の判定点。全GOALはactive/未達。

| 診断値 | 結果 |
| --- | ---: |
| empirical loss bits / token ceil B | 3594304.1487843213 / 449289 |
| Q32768 loss bits / token ceil B | 3594458.3338559293 / 449308 |
| side込み無料screen B | empirical452368 / Q452387 |
| active / pure rows / nonzero cells | 180526 / 78971 / 354913 |

## 実行不具合と修正

初回compile1/native1はstack overflow（exit -1073741571）で失敗し、stdout0。大きな14Summary inline配列をheap上の14件固定Vecへ変更し、stack reserveは変更しなかった。既存の24拒否/境界/全row oracle/実Front検証と固定入力経路を小さくせず、修正後の追加compile1/native1はexit0/diagnostic-passed。合計2compile/2native、同条件盲再試行ではない。正確なfault instructionは特定しておらず、同実行経路におけるallocation変更の有効性を確認した範囲。

親readonlyでtiles3site/probe2siteを逆置換し、初回コードSHAへ全文復元できることを検証。失敗report/EXEは保存して上書き・削除なし。旧失敗reportの当時before/after一致と、意図的に修正した現在sourceのlive一致は区別する。

## 実行経路の証拠

- 原grammarから更新前runをcallbackへ渡す2置換だけ、全文復元残差0。prefix1含むclass history10をtile境界でresetしない。
- 1read/BWT/集計walk、889227runs＝13full+37259tail、coded3825218/implicit122。原rawの全Meta（tokens/runs/escapes/history_checks/grammar/branches/classes/prefixes/final_history）を直接一致確認。旧2walkのevent Qloss再生を継承したとは呼ばない。
- Dense1個872448rows/13959192Bをreuse、14flush/12214272row検査。tile/component/node/wholeのcountとlossをnativeと親で再加算して一致。
- 先行E2E：synthetic境界131079events/65537runs・全row×child6979584比較、exact終端65536runs/3489792比較、named拒否24/回復、実Front tiny3cases/3BWT/3walk/2617344row算術。巨大event traceなし。post-finish拒否2はnamed24へ重複加算しない。
- 親readonly56 before/after/live組（source12+pins43+EXE1）/raw1全文一致、heap修正5site全文復元、追加compile/native0。原static基礎readonly39組は開始時と終了時に同コマンドで成功。

## 容量とidentity

bounded summary276016B、model保持推定18447904B<24MiB、fixed phase39405238B<48MiB、BWT推定141598926B<160MiB。実process peakWS55648256B/private51847168B<160MiB。stack予約増量・customallocator・新Cargo/PDB/ASM/frame/plain/rawtraceなし。

成功output EXE270848B＋report127263B＝398111B、失敗output305961B、計704072B。成功stdout26757B<64KiB、成功source12files/11edges/64920B。終了時free45457739776B（約42.3GiB）、共有ドライブ変動を今回約688KiB出力の効果と呼ばない。

| 証拠 | SHA256 |
| --- | --- |
| 成功report | E8A89FEE46CC6BB39697C416FD8150CB83B2406D9297A1C4397E6D9956C052A8 |
| 成功EXE | 91B8502A408C4F02F6439E27516DD41B1539658079C1DDA040D3E4CD57E0D3C8 |
| 成功runner | 767EBF40B6C4FE1B6165237497518028166C92E2E68B7D9E5727E27ABBDB01C8 |
| 失敗report | D2D7CF244C55738A1F466C5CAC60C5EC40DF4C3E2539D7AC322AC4D8695A6064 |
| 失敗EXE | FD0E3CD0C76CE7878B44ACF30CA7175B90C2C355FF4302F731682AB3211C820E |

確認入口 temporal-node-information/verify-artifacts.ps1。固定rustc1.98.1/edition2024/opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、Windows x64のみ。実frame/paidモデル/decoder/速度/quiet/holdout/API/native4/製品採用/Git/version/x86/外部/削除は未実施。次の問いをTEMPORAL_PAID_MODEL_QUESTIONへ保存した。
