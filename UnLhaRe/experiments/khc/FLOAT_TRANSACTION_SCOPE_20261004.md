# 排他的branch transactionの候補範囲

読み取り専用analystによる4file調査。2026-10-04。sourceはlookup-float-cts/{model.rs,float_cts.rs,float_pool.rs,codec.rs}。実装・計測・採用ではない。

通常経路にSnapshot.cloneはなく、返却はmove。名目サイズだけから実コピーや速度短縮を断定しない。codec.rs:144からのpredict→coder→edge→observeではModelを介在更新しないが、model.rs:81以降とfloat_cts.rs:48以降は再利用可能snapshotのstale防御を適用する。

## FT1: fresh transaction

1 branchを排他的&mut Model transactionで囲み、狭いreadonly予測をcoder callbackへ渡してchildを受け取る。介在Model mutation、snapshot改変・再利用を型とscopeで禁止したときだけ、serial/4rows/5weights/CTS history/path/observations/6nodes再照合と検証済みpの再vectorを削減する候補。予測・CDF・学習の数学順序は維持する。速度は未測定。

成功順はcoder→edge→pool gradient→counts準備→serial確認→audit準備→CTS全node準備→CTS commit→Model非fallible assignment。Modelは全fallible処理完了まで変更しない。coder自身のrollbackはこの候補の保証範囲外。

必須検査は入力/count/weight/vector/CDF、child/slot、gradient/posteriorの有限性・範囲、serial/audit overflow、class/raw更新CAP。predictはCAPちょうどを許しobserveは拒否するため更新CAPを省略しない。checked standalone経路のstale防御も削除しない。

## FT2: FT1成立後の保持情報縮小

fresh中間状態のCTS raw/weights/history/observations、pool pの保持は省ける可能性がある。kernel/features/q/CDFとpending commit状態は必要。p計算・検証・CDF生成を消す候補ではない。コンパイラがmoveを既に除去している反証があるため、名目bytesだけで採用しない。

## 後続の検証と判断

新モデル自身のstage profileで対象段の比重を先に確認する。採用する場合は新source rootと先行failure planを用意し、全frame/plain/Proof14/entropy bits比較、既存拒否の全state直接比較、CAP境界に加えcallback Err/不正child/edge失敗後のtransaction state非mutationを実行経路で確認する。既存26拒否だけを新transaction検証の代用にしない。

要求担当はanalyst（役割定義sol/medium）、新規独立文脈。実行時model IDの別経路観測はなし。最適化はまだ未採用、GOAL active。
