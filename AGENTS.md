# リポジトリ作業規約

## 対象と参照先

- **対象が明示されていない作業依頼は `UnLhaRe/`（64bit版・Rust版）を対象とする。** 調査、レビュー、修正、最適化、依存更新、検証、リリースのいずれもこの既定値に従う。
- **`UnLha32Re/`（x86互換版）は、ユーザーがその版またはディレクトリを明示的に指定した場合だけ扱う。** 明示指定がなければ調査・編集・ビルド・テスト・リリースを行わず、全体監査、一括更新、サブエージェントへの委任にも含めない。ルートの共有文書・設定を変更するときも、依頼された `UnLhaRe/` の作業に必要な範囲に限定する。
- x86互換版は `UnLha32Re/`、Windows/macOS x64/ARM64向け新APIのRust版は `UnLhaRe/` で扱う。以下のx86 ABI・専用試験規約は互換版に適用する。新版は [新版作業規約](UnLhaRe/AGENTS.md) に従う。構造と設計上の境界は [DESIGN.md](DESIGN.md) を参照する。
- 明示指定された `UnLha32Re/` の互換性に関わる変更では [互換範囲と例外](UnLha32Re/README.md) と [比較資料](UnLha32Re/docs/reverse-engineering.md) を確認し、対応する `scripts/test-*.ps1` と `tests/compatibility_tests.cpp` のプローブを照合する。
- 利用者向けの版選択はルート README、各版の機能・制限・操作は各ディレクトリの README、互換版の詳細な検証手順は `UnLha32Re/docs/` に記載する。DESIGN.md は実装構造の正本として更新する。

## 既定のUnLhaReのビルドと検証

`UnLhaRe/` を作業ディレクトリとし、[新版作業規約](UnLhaRe/AGENTS.md) の手順を使用する。下記のx86互換版の手順は実行しない。

## UnLha32Reを明示指定した場合のビルドと検証

Windows、PowerShell、Visual Studio 2026 の C++ デスクトップ開発環境（MSVC v145、Windows SDK 10.0）を使用する。以下は `UnLha32Re/` を作業ディレクトリとして実行する。

```powershell
pwsh -NoProfile -File .\scripts\build.ps1
pwsh -NoProfile -File .\scripts\test.ps1
```

- **リリースの検証は `scripts/test.ps1 -Profile Release`（ビルドと短時間チェック）、署名済みZIPの準備は `scripts/release.ps1` を使う。** リリース処理のローカル予算は300秒。配布のたびに引数なしの `test.ps1` を実行しない。全比較は機能修正をまとめた時点や互換性調査で明示的に `-Profile Full` を選ぶ。手順と確認範囲は [リリース手順](UnLha32Re/docs/releasing.md) を参照する。
- 実装変更時は Release ビルドと関連する互換試験を実行し、統合確認には `test.ps1` を使用する。Debug は `build.ps1 -Configuration Debug` で指定する。ソリューションの `x86` は各プロジェクトの `Win32` に対応する。
- `test.ps1` の既定 `Full` は Release ビルドを実行してから統合試験へ進む。個別試験では先に `build.ps1` を実行する。Full の fixture は `sample/lha-master/tests/`、比較元 DLL は `sample/ulh3300_extracted/UNLHA32.DLL` に配置する。`sample/` は追跡対象外なので、試験前に必要なローカル資料の存在を確認し、不足時は未実行範囲を明示する。Release は正常な入力を自己生成する候補単独チェックで、原版や `sample/` を必要としない。
- 比較元がない場合の候補単独試験と、原版との一致確認を区別する。更新・移動ポリシーの追加ライブ比較には `test.ps1 -CompareUpdatePolicyOracle` を使用する。
- DLL を実行する診断は [検証用デスクトップ](UnLha32Re/docs/testing-desktop.md) に従い分離する。`-IsolatedChild` は内部呼び出し用とし、通常は標準の試験入口を使う。原版が停止し得るプローブは `DesktopRunner.exe --timeout-seconds` で時間を制限する。
- 標準入口は DWM 監視も実行する。互換試験が成功しても監視異常があれば統合成功とせず、`build/dwm-monitor/run-*/summary.json` を確認する。個別診断に監視を付ける手順と採取権限の扱いは、上記の検証用デスクトップ文書を参照する。
- 試験失敗時は保存された入力・出力から原因を確認し、一致条件と意図的な安全性例外を分けて検証する。文書だけの変更では参照パスと `git diff --check` を確認する。

## UnLha32Reを明示指定した場合に維持する制約

- ABI 変更を伴う箇所では `include/UNLHA32.H`、`include/UNLHA64EX.H`、`src/unlhare.def` と試験をまとめて確認し、x86、stdcall、公開構造体のパック、既存の名前・序数を維持する。
- 状態を扱う変更では単発の戻り値に加え、検索位置、エラー、コールバック、中断後・失敗後の連続呼び出しを確認する。互換上保持する状態と安全性例外は DESIGN.md とプロジェクト README に従う。
- 派生コードを変更・配布するときは [第三者告知](UnLha32Re/THIRD_PARTY_NOTICES.md) と対応する著作権表示を保持する。原版 DLL は挙動比較用として扱う。
- 生成物は `UnLha32Re/artifacts/`、中間生成物は `UnLha32Re/build/` に置き、ソースとは分離する。
