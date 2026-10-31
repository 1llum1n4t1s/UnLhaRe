# 比較器の小容量準備

2026-10-05。完成codec/APIの性能比較は未実施。この記録は比較器の入手と起動確認に限定する。

| 比較器 | ローカル確認 |
| --- | --- |
| 7-Zip | 既存build/khc-baseline-20260918/x64/7za.exeを再利用。`i` exit 0、26.03 x64 / 2026-09-03、LZMA2 encode/decode対応を確認 |
| Zstandard | 公式v1.5.7 win64配布からzstd.exeだけ抽出。`--version` exit 0、64bit v1.5.7を確認 |

[Zstandard公式リリース](https://github.com/facebook/zstd/releases/tag/v1.5.7)とGitHub connector `get_release_by_tag`でasset名・サイズ1747181B・更新2025-02-28T20:07:29Zを確認した。最初のshell API読取りはToolport検索前としてhookに拒否されたため、要求通りGitHub tool検索・release取得へ切り替えた。拒否操作をそのまま再実行していない。

`prepare-zstd.ps1`はZIPをRAM内で扱い、ZIP自体をディスクに保存しない。最初のダウンロードはZIP内にlicenseがないため、出力先作成前に失敗した。既存データを削除せず、GitHub connectorから[v1.5.7 LICENSE](https://github.com/facebook/zstd/blob/v1.5.7/LICENSE)（git blob 75800288cc243f164b9d130f125e2ffae28f8e39）を取得して保存し、1回の修正再実行で準備を完了した。取得総計はZIP 2回（どちらもRAMのみ）。製品への依存追加や配布はしていない。

出力はbuild/khc-bench-tools-20261005。zstd.exe 1601409B、LICENSE 1549B、preparation.json 3840B、合計1606798B。8MiB容量チェック成功。準備時には空き35GB超を観測し、最低5GiB＋8MiBを維持した。最終具体的空きは各記録のdisk欄に保存している。他作業のdrive容量変動を今回のファイル増分と扱わない。

- zstd.exe SHA256: `8076AAE03FEAC7C66B319579E82172EED168DEED2A3F25E5E2D3C60F55E84111`
- LICENSE SHA256: `7055266497633C9025B777C78EB7235AF13922117480ED5C674677ADC381C9D8`

リリースassetのpublisher digestは提供されなかった。これらはローカル識別用SHAであり、署名や提供者attestationを検証したとは述べない。

比較は1threadを明示し、圧縮率優先と時間/メモリ制約を合わせる条件を別にする。KHC 1MiB独立blockの比較ではZstd/LZMA2も同じ分割のraw codecで比較し、7zのsolid書庫との条件混同を避ける。完全復元のbyte照合・ヘッダを含む総費用・実時間・OS最大メモリ・コマンド・識別値を揃える。1回の診断時間を安定した中央値や性能優位として発表しない。条件はRESEARCH_SELECTION_20261005.mdと各native failure-first契約に従う。
