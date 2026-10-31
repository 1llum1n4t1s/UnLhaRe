# 現compiled Programのphase診断結果

2026-10-06 JST。前工程9E2E/83msnativeを引き継ぎ、現在のmodと一致する別namespace診断を実装・実行。製品source/API/wire/versionは変更しない。14child path・TLS・6境界時計を取り除くと現在のmodに正規化完全一致することをcompile前に検査。公開Release rlib SHA9D3BAEC4C907A80B043E7CE2DFDA2CC8AC0C483FE18DD82070E7DF7E085659BF、全child・compiler・設定・元corpus・保存書庫・EXEのpinを再確認、終了時不変。

実保存書庫466395B/全11frame465951B・元2810784Bを現public verify/listで確認した後、公開decompress_blockと計測namespaceを各warm1+9で復号。99有効行、元全11fileと全byte直接比較成功、phase合計<=total、method0/2/3のphaseは0、容量gate<=64MiB。raw/frameの新diskコピー0。

8MDL fileの各9中央値合計（各phase中央値和はtotal中央値と一致するとは限らない）:

- 診断MDL total42.9253ms、現公開MDL43.2198ms。
- wire0.0141ms、alphabet/Forest/CDF・Program reservation2.9049ms、grammar state/setup0.3506ms。
- token/runs27.8968ms、inverse11.7159ms、CRC/capacity0.0217ms。
- token/runs約65%、inverse約27%。旧pre-portの83%を転用しない。
- method3の公開3file合計15.5358ms（kennedy10.8365/ptt5 3.8925/sum0.8068ms）。内訳はこの診断では測っていない。

温まったblockの内部時間とnative全書庫83ms/cold startup/file IO/CRC時間を同一尺度にしない。public→診断の順が固定であり、namespace totalを性能改善の証拠とせず、優先箇所を選ぶ診断としてだけ用いる。grammar state/setupにはruntime Tree生成はなく、静的表のreadonly費はStatsへ計上済み。

report build/khc-program-profile-current-b-20261006/report.json SHA256 `322B95AFA779C7619051C7B59C87270183358FEB4DD3EFCE263E9FFEC8641E79`。
EXE1315840B SHA256 `487996E353645CB55CC8618DACE90F30F28F757B0B2D7C94A0BEC95E776B51BE`。compiler6.754秒/private255049728B/WS277504000B、helper1.298秒/private7069696B/WS11137024B。観測であり全瞬間peak保証でない。

初回current-aは「指定されたファイルが見つかりません」でcompile結果なし、report E4D42AAC016A38206E64156453E0A043017ACDB52FAF1F53AE49D1B9CFF8FDDCを保持。rustc --version/同ProcessStartInfo・CPU counterの読み取り確認は成功し、原因は未確定。例外type/stack/child出力を回収する派生runner bへ接続し、同じ期限/予算で実compileと実復号が成功した。初回を製品不具合と断定せず、成功へも置換しない。

Cargo6169422158B→同値、固定cap6175228536B、新target-dir/PDB/大規模cache0。8MiB専用root/free5GiBを維持、保存EXE/report約1.29MiB。原GOAL active/未達。

readonly分析担当lz_bulk_copy_contract（要求/役割実効gpt-6.1-sol/medium）は既存copy候補履歴のdoubling悪化2.92%/chunk copy小幅2.47%と製品scopeの相違を返した。親が履歴・契約を照合しコピー再試作を見送り、別のmethod2/3 binary thresholdを実装したが事前screen未達。../binary-threshold/RESULT_20261006.mdに証拠を保持。opopの6基本観点+Async/StartupはCURRENT_PHASE_PLANの親担当台帳を維持、Intel/Modernizerは今回外部仕様・依存変更判断なし。

次はtoken/run逐次区間数の削減可能性を、既存same-class compound7.08%coverage失格と区別して有限診断する。rank root(class0)とlength root(class3)は別historyを持ち、両rootのprefix上限はrun開始時に得られるので、両rootを先に処理できるか/モデルsupportを保つ共同区間の成立率・費用を読む。単なるroot productでは圧縮率の改善を仮定せず、quantize・再計算・table費用も隠さない。まだ実装/採用/性能証拠はない。元GOALのrate8980B不足/約2倍復号差/encode・真正未見・Zstd・4native等を残す。
