# Dirichlet full CLI E2E 実行前失敗計画

- CDF・causal update・prefix・escapeのずれ: 固定7入力×opt2/3×overflow yes/noで28 encode/decodeの全byte比較、21 wire全byte比較、stats/実header/bounds照合。
- 共通モデル誤り: 候補model/codec encoderを参照せず、root1/local0の独立実配列countsから通常u128除算 C(k)=k+floor(32768*(64R+DL)/(D*(64+T)))を計算し、手組みmetadataとrange primitiveでempty/zeros255/256/257と23 malformedを構築。旧P256 tupleは使用しない。
- malformed受理: grammar/varint/active/primary/LF/CRC/packed fields/prefix/gap/trailing/terminalを意図stderrまで確認。no-clobberは既存全byte/hash保持、missing/args/operationとbalanced相互magic拒否、旧KHNPR001拒否。
- identity/import誤り: codec/cdf/math/数値report/契約/guard/compiler/runtime/旧EXE/旧frame/固定inputをpinしてRead lock、actual importsの固定集合所属と前後SHA確認。生成EXE/frameもRead lockして前後一致。
- 容量: fresh build/khc-direct-token-dirichlet-full-20261002、通常3MiB/最悪50MiB/上限64MiB。出力前reserve、child120秒・stdout/stderr各65536・report512KiB。4codec EXE+forge+7reference+reportのみ保持。入力/restore/condition/forgeは全byte比較後exactowned/nonreparse/child終了/stream閉鎖を確認して逐次削除しledger保存。
- サイズgate<=483599byte、直前610222/旧575791との実byte差。sizefalseでもcorrectness完遂、formal benchmark禁止。elapsedは診断だけ。
- allocation failure injection/他native/holdout/categories/正式性能/製品API統合は未検証。unique active invariantでnonmaximal adjacent分岐は到達不能、静的確認と実行済みcaseを区別。

親の数値成功report SHA確認・source freeze通知後に一度だけcompile/run。未知failureは最小証拠保持し、同条件retry/root上書きなし。Git/stage/commit/push/version/公開/x86/共有cache/追加委任なし。
