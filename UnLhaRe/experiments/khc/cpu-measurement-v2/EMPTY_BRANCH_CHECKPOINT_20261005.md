# 空頻度枝候補：実行中の引継ぎ

2026-10-05 10:01 JST現在。GOALはactive、7-Zip優位は未達。FILL_RESULTは完了した互換性検証であり、速度優位の証明ではない。

EMPTY_BRANCH_PLANに従いpaid_model.rsの空枝を変更。全子孫のcountゼロを検査した後、従来uniform/leafを使って非分割で終了する。非空枝、decoder、形式、revisionは不変。bundle::ingestは各rowを根から葉まで同時に加算し、tail/CAP/overflowを検査する。malformed内部Histを直接注入する検証は未実施。公開API経由の悪性wire検証は成功。

新empty EXE SHA256 D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79E。旧fill EXE SHA256 3F9E8ABA9500D0DF085A49DB071DBAF09DE3FE8FE4BB25C2C9263EB13FD2F63Fは保持し再buildしていない。新exampleのみbuild成功15.40秒。新候補の正式採用は旧版比較後に判断する。

既存3 E2E成功：固定3block156483/237176/119861 B、30故障/30回復、最大split。成果物build/khc-product-e2e-20261005/block-normal-44916/result.json、block-adverse-22244/result.json、model-boundary-388/result.json。lib＋empty example clippy -D warnings、変更2Rust rustfmt check成功。全repo/container/他OS nativeは未再実行。

Paid比較を09:52:54開始し、10:01:03の実プロセス照会で稼働を確認。unified exec session 52136、runner PID28140、親34548。未使用出力build/khc-cpu-measurement-v2-20261005-empty-paid、report未生成。quiet15%/child64MiB・60s/suite900sは不変、別作業の全体CPU22%観測。観測timeoutは終端ではない。次のターンは同じhandleをpollし、完了reportまたは失敗理由を読む。終端確認なしに再起動しない。

Paid完了後は同じbaseline/new SHAでHistoryMode low、別の未使用Attempt empty-lowを実行し、全frame一致/相互復号/時間範囲を保存する。両modeの効果が確認できなければ採用を見直す。旧7-Zip結果の倍率をこの候補の実測として使わない。

共有Cargo6118587153 B、元baselineから211794073 B追加/256MiB、残り56641383 B。native開始前free28753104896 B、report上限256KiB/専用dir8MiB、生raw/frameのdisk保存0。削除・Git・外部公開・新依存なし。
