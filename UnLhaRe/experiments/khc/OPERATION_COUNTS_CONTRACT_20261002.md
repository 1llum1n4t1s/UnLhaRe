# Q15/CTS演算回数監査: 実装前計画

正式性能比較はCPU16%でpreflight失敗した。新しい同候補の測定は再試行しない。次は時間と独立した論理演算の頻度を数え、6倍近い速度差を縮める候補の優先順位を決める。演算回数やinstrumented wall値を速度勝利へ読み替えない。

研究codecのコピーを凍結候補から明示置換で作り、cfg khc_operation_counts時だけthread-local固定長カウンタを付ける。親が唯一の編集担当、追加の独立レビューではなく既存codec調査担当の補足根拠を参照する。製品と元source/proof/ゲートは変更しない。新ユニットテストは作らない。

## 数える単位

- 1range bit=正常scheduler event。stageをlight/live-heavy/replay-heavy/reference、classを0〜6に分ける。scope guardで元stage/classを復元し、reference未使用を0として記録。
- 実際のBayes採用branch: equal/CTS優勢/primary優勢/旧posterior。予測を再呼出しせず、既存成功値から加算。
- lightはselected-depth0〜16、正常predictで実行した探索反復数（元の逆順loopからmin(16,17-selected)）、正常updateで完了した17nodeをまとめて計数する。
- heavyは正常predict/update、KT成功のmethod1/2/3、正常predictの16mixture、正常updateの17node。ratio wrapper試行33/updateと、KT内部fallbackを含めた実際のratio flagsを別に記録する。
- successful operationとattemptを混同しない。失敗CLIでは完走に関する等式を適用せず、既存refusal/no-outputのみ確認する。

## 失敗条件と検証

1. 計数がmodelの状態/予測/float評価順を変える。非instrumented候補の7入力/通常/checked完全frameと復元を直接比較。既存stdoutの1行目も完全一致を要求し、2行目の有限JSONだけを監査情報とする。
2. 診断だけで再predict/ratio/observeする。hookは既存Resultを読むのみで、source全文対応を要求する。TLS fixed stateは約十数KiB、raw event列は保存しない。
3. replayをlive/通常学習に二重計上。schedulerの各scopeを分け、classごとにlight calls=events、live heavy=active_events、replay=existing replayed、heavy合計=processedで照合する。reference cfgは通常未実行のため0を要求する。
4. node/ratio集計の誤り。heavy KT合計17×predict、mixture16×predict、nodes17×update、wrapper33×update。light histogram合計=events、nodes17×events。encode/decodeの全計数JSONとopt/checkedも一致させる。
5. overflow/TLS階層不整合。計数はchecked-addでoverflow flagを立て、model分岐や予測値へ返さない。phase/classは既存bounds通過後のみ設定し、完走時overflow=false/current phase restoredを要求する。
6. proof/exe/input取り違え。compiler/元full proof/原source/新source/EXEをSHA前後で保持。完全483496B/SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12と旧scheduleに一致することを要求する。
7. 破損/no-clobber/入力不足を成功扱い。既存32項目E2Eを引き継ぎ、expected exit/出力非公開も維持する。child120秒、再試行/上書きなし。
8. 容量増大。新root一つ32MiB予算、既存input/旧frame/proof再利用、EXE2個のみ、Cargo target/trace/raw数値/fixtureコピーなし。stdoutは固定サイズ要約。前後capacity guard。証拠未参照の新PDBだけは安全条件を確認後に片付けられる。

完走した論理頻度は改善箇所を選ぶ証拠であって、命令数/時間/cacheの原因確定ではない。正式静穏測定、holdout、四native、製品統合は別途未達のまま保持する。
