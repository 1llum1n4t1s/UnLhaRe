# CTS depth 候補の一時停止記録

2026-10-03、ユーザーの「キリの良いところで一時停止」に従い、goal を paused に変更。実装担当へ保存・停止を通知した後に中断し、新規ビルド・計測を開始していない。

同日、ユーザーから「一時停止の依頼はしていないです。再開してください。」の明示依頼を受領。停止指示は撤回されたものとして、保存済み候補の実装・レビューを再開した。以下の識別値と未完成箇所は停止時点の記録であり、現在の実装完了・検証済みを表すものではない。

## 保存点

- 前段の sealed snapshot の検証済み結果は `QUATERNARY_CTS_SEALED_RESULT_20261003.md` に保持。約25%の短縮は同一バイナリ内の比較であり、7-Zip超えの達成を意味しない。
- 現段は `quaternary-cts-depth/` の7ファイルを保存済み。実装担当は Rust 6ファイルの rustfmt 構文確認成功を報告したが、型検査・実行・深さ別の性能は未検証。
- `verify-depth.ps1` は未保存で、runner の作成は未完了。source closure、compiled graph、容量予算の最終検証も未実施。
- 固定契約 `QUATERNARY_CTS_DEPTH_CONTRACT_20261003.md` の SHA256 は `3B2A9E1CA7DF9FDE77DFECCD36CA93D7E513392ECA648B8EC9627180574450F3`。
- 新出力先 `C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-quaternary-cts-depth-20261003` は存在せず、候補EXE・report・入力コピー・frame・復元コピーは未生成。
- 停止時のプロセス確認では rustc/cargo/候補probe/verify-depth の該当プロセスなし。PC全体のCPU負荷を測定したものではない。
- Cドライブ空き 92,543,184,896 B（約86.19 GiB）。既存証拠・共有キャッシュ・x86版は削除していない。

## 保存済みファイルの識別値

| ファイル | bytes | SHA256 |
| --- | ---: | --- |
| codec.rs | 21017 | 773493C397578A2E387FE0975F58CDDC03000CC71E9AC0AEE6453DA3ABCAFA4A |
| comparison.rs | 22392 | 9294DEFD524F57185CAEB20D3BF4BEA8C654C6879DB76A3273496C46A581AE71 |
| e2e.rs | 10345 | F3271691DE25F9B4C489B935A9772120018B33F22A8A29278860895017C24E31 |
| FAILURE_PLAN.md | 5966 | 753C7ABCE0B86BCBD78E1BCC0B0FBCAAB242F04068A54622A25AD59DA26B25F9 |
| integer_cts.rs | 10186 | E01F168CA9EEC738D9B0919BEF7574572219FDF180E2267A6F83267C8B26703D |
| model.rs | 11840 | AB4BBAC034472A6A83C1CCC39F29F37433A695FDA1FD5C89DBE6B63378575C12 |
| probe.rs | 6684 | 9DB04E95E25397EB014B443303BE58944C32D3E2419C6D6E12FB212FF688F3BF |

## 次回の再開地点

1. 保存点と契約を照合し、runner を完成する。旧 sealed 72件の証拠と旧KT64/basisの識別値を維持し、容量上限8MiB・保持物はEXEと小さなreportのみとする。
2. 親レビューを続ける。comparison.rs の後半、e2eの全差分、更新されたcodec/probe、runner全体は最終レビュー未完了。異深さの未改変tokenは拒否、visibleを現行予測へ完全に置換したtokenは従来fallbackで合法、という契約を維持する。
3. 実装所有権を回収して最終nonExecute検証。合格後にのみ親が1回compile/Executeし、5深さの復元・拒否理由・深さ8の旧frame bridge・サイズを確認する。単発sweepは正式な速度評価ではない。
4. 正式な7-Zip比較、CPU上限、holdout、4環境のネイティブ検証、製品への統合は未完了のまま。再開の明示依頼まで実装・計測しない。
