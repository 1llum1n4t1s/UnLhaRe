# 同encoder・single-childの全corpus paired検証

2026-10-07 JST。旧normal-aは8/11入力終了後CPU quiet timeoutでincomplete（report SHA96D302BAA0035C68CC2110ABF68B4DA1C0C386749ACE340B95D793B0A0B940A2）、合否/aggregateはない。codec失格とは区別し、source/部分結果を保持する。

測定の再計画：8入力分の単独child起動がそれぞれquiet待機を要求して終盤で60sを超えたため、同じ11入力を同じ一つのchildで順次測る。各入力のraw/frames/models/voterは前入力の終了時にdrop、retainedは小さいJSONのみ。入力ごとの双方warm1/9交互pairs・同encode/decode入口・全費用・全frame/public/全復元byte照合は変えない。process間coldの比較ではなく、warm block比較である点を明記する。native cold archive/最終7zipとは分離する。

normalの全11median和でencode<=現baseline1.10倍/decode<=現baseline、frames456573/全予約457273Bを要求。通過時だけ同EXEでreverse9pairsを新rootで再測定、両順通過を必要条件にする。前KRS1の失格は覆さず、同codecに対する係数/閾値/反復数のsweepや合否条件の緩和をしない。部分結果をつなぎ合わせて全11結果にしない。

全11corpusのPin、整数proof/pruned/full-E2E screen成功とsource/依存commonhash/bytes/mtime一致を開始前に要求する。測定区間はbaseline試行/第一scan/4CDF/下界/必要な第二scan/ANS/metadata/CRC/wrapを含む。両経路のcaller上限3MiB+160とsuiteの小出力上限64KiBを課金、64MiB actual child監視。各入力終了時にモデルやrawを保持して学習条件を変えない。

元と同じChild起動前quietCPU15%/60s、child60s/suite300s、compiler512MiB/helper64MiB、専用output8MiB/report128KiB/free5GiB+8MiB、Cargo cap6175228536B/増分0。loopをまとめるだけでquiet条件を緩めない。raw/frame/trace/PDB/newtarget/download/削除0、source/report/EXE保持。通常のencode/decode呼出し費用の評価で、候補の処理を計測外へ動かさない。

失敗先行：args/11file数/extent/安全name、不足データ、各warm public baseline、新旧frame反復/復元、9正time/order、resource/output上限、normal prerequisite/source/exe identity、拒否後の有限検証。新unit testなし。metadata/CRC/modelはcodec有限E2Eで先に合格済み。親だけ新suite filesを編集、旧失敗sourceは変更しない。次はこのsuiteの実装・構文/有限照合、normal→reverse。未実行、GOAL active/未達。
