# CTS同一componentの計算省略候補: 実装前診断計画

直前の正式試行はCPU上限でterminal、source/history closureと候補warmupの証拠を取得しPROGRESS。今回は別のcounter診断EXEで、厳密な商計算を省ける機会が固定corpusに何件あるか先に確認する。正式性能・同候補の再試行ではない。observerの確認待ち変更を実施せず、既存terminal/固定条件を維持する。

仮説: KT確率pkとchild確率が同じなら、mixture=pk、観測側ceiling=pk、posterior=floor(weight*pk/pk)=weight。合法なpk>0・weight<Qで成立する。実際の既存計算結果を変えず、同一componentかつ実際のcached_ceiling==pkのlaneと4lane全体の件数を数える。多数なければshortcutを作らず、分岐/検算コストを増やさない。単なる同じ数値率から速度効果を推論しない。

1. 元入力と合法性: compact predictor/updateの全検査・商計算・学習状態は無変更。診断はprobability(pk)成功後にpk==childとceiling==pkを数える。等値pk/childなのにceilingが一致しないケースも数え、固定corpusで0を要求。maskの判断は実際のcurrent node weight/snapshot/cached ceilingを使い、古いsnapshotや初期値だけで省略可能と決めない。
2. 件数・漏れ: upper3/7/11/15ごと16maskのhistogramを固定64counterで記録。groups=12892624、各upper=3223156、全lane=51570496。diagnostic countersはchecked加算。encode/decodeの全histogramを一致させる。histのsumとmask popcountからequal lanes・all-equal groupsを独立に再集計する。
3. sourceの混同: basis full proof22C7D3364743D2FD962A330BCA5EC9BBE2DF4EC6E1603F8BB4ED655FE0D645BE（51/86/466）の全current identitiesを照合。codec/scheduler/heavyの3sourceを明示対応でcopyし、cfg-only counter・出力だけ追加。module pathを新counter moduleへbindし、KT/kernelは現reciprocal-codecのexact_ktを共有する。cfg off/onをbuildし、onで固定input encode/decode各1回。offは実行しない。
4. 正当性: 第1 stdout全行とframe483496B/CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12を基点fullのfixed nativeと比較。restore2811006Bを元inputと64KiB逐次比較し、CRC/学習/scheduleを不変にする。source/frame/restore/exit/argument/counter/identityの差はfailed、一度のrootを自動再試行しない。
5. 容量と清掃: fresh build/khc-equal-component-opportunity-20261002、8MiB。2小EXE/frame/restore/要約、ピーク4MiB未満見込み。PDB/cache/raw traceなし。restoreは実byte/hash比較と記録後にexact owned absolute path・祖先non-reparse・child終了/比較stream閉鎖・exclusive読込みを確認し、同一PowerShellのRemove-Item -LiteralPathで削除する。input・frame・EXE・reportは保持し、restoreは再現可能な一時物として記録。失敗時は最小出力を保持。
6. 実環境: compiler1.98.1/SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、cfg/argv/runtime/CWD/CPU/source hash・disk guard前後を保存。各child120秒、bounded stdout/stderr65536文字以下。壁時計は測らずcounterだけ。canonical arithmeticと整数certificateを省略しない本診断は新アルゴリズムのfull proofを代替しない。
7. 未達: サイズ/encode中央値574.5624ms未満・CPU15%・warmup1+9等の固定条件は不変。holdout/カテゴリ・同境界decode・四native・製品/API安全性は未達。多いと分かった場合だけ実装前の失敗条件/数値状態計画を別途作ってshortcutを実装する。正式reportのreciprocal_proofs key衝突は次derived comparerで分離し、測定済みcomparer/reportを編集しない。goal active。
