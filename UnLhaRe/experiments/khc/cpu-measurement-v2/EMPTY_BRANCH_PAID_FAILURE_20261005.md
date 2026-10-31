# Paid全件のsuite超過と継続状態

2026-10-05。session52136は10:07:55にexit1で終端確認。失敗理由suite deadline、elapsed900665.819ms、CPUquiet待ち824596.226ms、186 native calls、44frame対一致、差0、88自己往復と10相互復号の完了記録、全live pin不変。部分fixture4を含むので7fixture比較完了とはしない。

reportはbuild/khc-cpu-measurement-v2-20261005-empty-paid/report.json、16464 B、SHA256 6C51CCA5CA1B7BA8119A2CD7F6E8A3C6895FA4A8CFAB084F2CBFB4C95157F5B7。改変せず保持する。fixture0..3は各warmup1＋9×両方式が完了。repeat圧縮中央値旧106.022→新109.169ms、all256旧117.789→新98.106msだがmin/maxは重なり、速度優位とは断定しない。実用fileの測定は未完了。

EMPTY_BRANCH_PARTITION_PLANで同じ条件のfixture範囲指定を実装し、runner ASTの解析エラー0を確認。静穏上限や全7入力/9測定を減らさず、未完了4..6を新しい専用runへ分離した。失敗record全体を成功へ変更しない。

継続実行はunified exec session82559、Attempt empty-paid-rest、HistoryMode paid、FirstFixture4/LastFixture6。新empty SHA D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79E、旧fill SHA 3F9E8ABA9500D0DF085A49DB071DBAF09DE3FE8FE4BB25C2C9263EB13FD2F63F。旧handle52136は再開しない。次は82559をpollして終端/保存reportを確認する。観測timeoutだけで重複起動しない。

出力build/khc-cpu-measurement-v2-20261005-empty-paid-restはnative開始前0 B/8MiB、free28402741248 B。新compileなし、raw/frame disk保存0、削除/Git/公開なし。Lowは未測定、候補の最終採否は保留。GOAL active、7-Zip総合優位未達。再度静穏待ち超過なら同じ測定を繰り返さず、DECODE_CANDIDATESの独立した実装工程を進める。
