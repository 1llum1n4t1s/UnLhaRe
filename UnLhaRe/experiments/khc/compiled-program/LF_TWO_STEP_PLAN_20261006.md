# LF二歩表の同wire逆変換候補

2026-10-06。現Program8MDL inverse11.7159ms/27%、token27.8968ms/65%、native83ms対7Zip41ms/5%率不足8980B。root productは3.94%coverage失格、前2joint16CDF学習もgross2827B/追加model49920Bで失格。これらの基準を緩めず別のinverse候補へ移る。

独立readonly analyst lf_two_step_feasibility（要求/役割実効gpt-6.1-sol/medium）は指定packed-inverse/permutation-inverse/lf-cycle RESULT、DEVELOPMENT内にexact二歩方式の既採否を発見しなかった。旧read-only packed24は0.65%悪化、1歩visited除去も逆順0.36%悪化で復旧済み。既存負例を再調整せず、pointer依存鎖を減らす別機構を試作する。

仕様候補: 元LF u32表をcounts/starts/occurrenceで構築し、別Vec<u64>へ2歩nextと2文字を一度だけprecompute。low32はnext2 23bit＋byte(row)8bit＋visited31、high32はnext1 23bit＋byte(next1)8bit＋midIsPrimary31。元表はprecompute後drop、packed child/wire/model/encoder/公開APIは不変。

cycle条件: LFはsymbolごとの連続rangeを重複なく埋める全域置換。pair先頭 `step>0 && row==primary` とpair middle `midIsPrimary` はLF cycle inconsistentで拒否。first byteはstep0のsentinel dummyだけ省略、secondはplain[n−2−step]。odd tailはfirstだけ出力してhigh32.next1で1歩、n1は空出力。n歩後row==primaryを必須にする。sampled visitedは補助でありmiddle判定を省かない。終端だけではn6/cycle3の反例を受理する。

失敗先行:

- 任意置換の短cycle/primary/parity/byte255/middle flag/odd tail、範囲外、alphabet/sentinel、raw CRC/extent拒否の差は棄却。
- original capacity＋2×jump capacityをscratch_capacity_wordsへ報告し、同時保持最大12nBを隠さない。modのbefore_program予約は旧4MiBから12*(MAX_INPUT+1)=12582924Bへ候補だけ変更。割当失敗が増える可能性を無視して完全な資源同値と称さない。
- originalをplain割当前にdrop。追加random読み込みは概数n→1.5n、scratch4n→12n。walkだけの速度やbig-O同じことを採用理由とせず、table初期化/作成を含むinverse全体を測る。

有限検証: 全置換n1..8×全primaryを独立visited oracleと二歩walkerで照合し、受拒否・失敗step・成功byte一致。実last列n1..8/symbols0,1,256（sentinel位置含む）を現packed inverseと照合。n1/n2/n3、最大1048577、超過、不正symbol/primary/alphabet、n6/cycle3反例を明示。実保存11frame/現公開APIと自己・cross復元、既存異常decoder/回復、最大全可変Forestで64MiB gateと増分を検証。新unitは追加しない。

採否固定: inverse全体25%以上、全11frame復号5%以上の短縮を各file中央値合計・対応pair合計中央値の両方で要求、各file10%以上悪化なし。warm1+9通常/同じEXE独立逆順の両方。初回失格なら逆順/第三測定/sweepなし。encoder/frame不変は別に確認し、成立後のみ仮統合・公開9E2E・native強solid再測定へ進む。元GOALrate/encode/decode/真正未見/総費用等は保持。

生成source/EXE/reportの専用8MiB/free5GiB、raw/last/frame disk0、compiler512MiB/codec64MiB、child60秒/suite300秒/quiet15%60秒、Cargo6169422158B/cap6175228536B/書込0を維持。親のみ編集。まだコード/有限実行/速度採用の証拠はなく、readonlyの成立条件を実行成功へ格上げしない。
