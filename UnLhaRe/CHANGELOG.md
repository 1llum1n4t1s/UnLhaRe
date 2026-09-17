# Changelog

## 1.0.1 - 2026-09-17

- ABI 1を維持してAPI level 2を追加。明示した入力一覧の圧縮、選択展開、上限指定、同期進捗通知とキャンセルに対応。
- Windows x64/ARM64 DLLとNative AOT対応C#ラッパーを含むNuGet `Kagayoi.UnLhaRe` を追加。
- ハードリンクが利用できないファイルシステムでも、検査済みデータを既存ファイルを置換せず展開。
- Lhamielがパッケージの版とlockfileを固定し、UnLhaReの公開後に参照更新・検証できる手順を追加。
- LH5/LH6/LH7の単一ファイル圧縮計算中はキャンセルを遅延して受け付ける制限を明記。

## 1.0.0 - 2026-09-17

- Windows・macOSのx64/ARM64向けに、64bit専用のLHAライブラリとCLIを初公開。
- Rust APIとUTF-8 C ABIを提供。旧UNLHA32の32bit ABIとは独立し、既存32bitアプリには互換版UnLha32Reを使用。
- 書庫一覧、本文サイズ・CRC検査、展開、新規圧縮（LH0/LH5/LH6/LH7）に対応。
- 日本語・絵文字の書庫名と階層、独立した並列呼び出し、既存出力を上書きしない操作を提供。
- Windowsは署名付きZIP、macOSは実行権限を保持するtar.gz、SHA-256一覧を配布。
