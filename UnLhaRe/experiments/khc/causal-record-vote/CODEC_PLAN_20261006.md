# 因果record bit codecの実装開始点

2026-10-06。census RESULTを根拠に1構成へ進む。固定prefix selectorの範囲やstride定数を再調整しない。凍結voter.rsのpair stateを、そのままbyte完成後にencoder/decoder両方で更新する。新private magic `KRC1BLK\0`、revision1。原GOAL/採否条件を変えない。

- 基本bodyは record-bit/codec.rs の4096×u16確率、初期16384、ceil/32・clamp、MSB-first range。新voter上界266372Bを追加RAMとして確保前/後・peakへ課金する。外部学習/保存表なし、file名条件/将来byteアクセスなし。
- 各byteを処理する前にvoter.best()からstrideを取る。幅変更時も因果性を保つため、byte冒頭のleft4bitは **現在strideでrow開始なら0、そうでなければ復元済み直前byteの下位4bit**から作る。前row/前々row窓は同じ現在strideで取り、各bit後にleft/tableだけ更新する。8bit完了後にvoter.observe(byte)する。前の幅でresetされたleftを幅変更後も持ち越さない。
- 新headerは同じ40B layout。method1では保存stride@20=0、context id1、selector id2（因果voter）。method0/2はstride/id0。method2の内側はKHC1のみ、未知id/非0保存stride/旧KRB1 magicを拒否する。wire/raw CRC、長さ・1MiB・正準range終端を保持。
- encodeでは現BinaryAdaptive、因果record、raw storedを新headerを含め選ぶ。両試行・voter・包み直しを全encode計時へ含める。output capでrecordを早期放棄しても、その処理費用を隠さない。
- 独立pixel/windowと確率参照は旧成功を参照するだけでなく新harnessにも接続。voterのfrozen state一致/byte前の選択、encoder/decoderのcoded-frame終端best/票数/変更数一致、空/境界/白prefix後変化/任意byte/oversize、3wire method、必須拒否/曖昧変異・余剰/回復を実frame E2Eで確認する。新unit testなし。
- 同11developmentの実frame合計＋container444B＋統合予約256B<=457415Bのsize-first。未達なら速度/係数/距離範囲/bitcontext sweep/製品移植なし。通過時だけ事前の公平なpaired gateを追加で固定して通常/逆順速度へ進む。census89.74%を圧縮改善89.74%へ読み替えない。

parentだけ編集。基礎sourceは現mod B050BBF7...、rlib9D3BAEC4...、凍結record-bitの成功c source/causal voter source。旧候補source/report/EXEを編集・削除しない。専用root8MiB/report128KiB、free5GiB+8MiB、codec64MiB/compile512MiB/child60秒/suite300秒/quietCPU15%60秒、Cargo固定capを維持。現製品API/wire/version/他版/Git/外部write変更なし。
