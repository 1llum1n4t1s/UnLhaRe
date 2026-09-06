# リポジトリ作業規約

## 対象と参照先

- 実装・ソリューション・試験は `UnLha32Re/` 配下で扱う。構造と設計上の境界は [DESIGN.md](DESIGN.md) を参照する。
- 互換性に関わる変更では [互換範囲と例外](UnLha32Re/README.md) と [比較資料](UnLha32Re/docs/reverse-engineering.md) を確認し、対応する `scripts/test-*.ps1` と `tests/compatibility_tests.cpp` のプローブを照合する。
- 利用者向けの案内はルート README、詳細な検証手順は `UnLha32Re/docs/` に記載する。DESIGN.md は実装構造の正本として更新する。

## ビルドと検証

Windows、PowerShell、Visual Studio 2026 の C++ デスクトップ開発環境（MSVC v145、Windows SDK 10.0）を使用する。以下は `UnLha32Re/` を作業ディレクトリとして実行する。

```powershell
pwsh -NoProfile -File .\scripts\build.ps1
pwsh -NoProfile -File .\scripts\test.ps1
```

- 実装変更時は Release ビルドと関連する互換試験を実行し、統合確認には `test.ps1` を使用する。Debug は `build.ps1 -Configuration Debug` で指定する。ソリューションの `x86` は各プロジェクトの `Win32` に対応する。
- 統合試験は Release をビルドしてから実行する。fixture は `sample/lha-master/tests/`、比較元 DLL は `sample/ulh3300_extracted/UNLHA32.DLL` に配置する。`sample/` は追跡対象外なので、試験前に必要なローカル資料の存在を確認し、不足時は未実行範囲を明示する。
- 比較元がない場合の候補単独試験と、原版との一致確認を区別する。更新・移動ポリシーの追加ライブ比較には `test.ps1 -CompareUpdatePolicyOracle` を使用する。
- DLL を実行する診断は [検証用デスクトップ](UnLha32Re/docs/testing-desktop.md) に従い分離する。`-IsolatedChild` は内部呼び出し用とし、通常は標準の試験入口を使う。原版が停止し得るプローブは `DesktopRunner.exe --timeout-seconds` で時間を制限する。
- 試験失敗時は保存された入力・出力から原因を確認し、一致条件と意図的な安全性例外を分けて検証する。文書だけの変更では参照パスと `git diff --check` を確認する。

## 維持する制約

- ABI 変更を伴う箇所では `include/UNLHA32.H`、`include/UNLHA64EX.H`、`src/unlhare.def` と試験をまとめて確認し、x86、stdcall、公開構造体のパック、既存の名前・序数を維持する。
- 状態を扱う変更では単発の戻り値に加え、検索位置、エラー、コールバック、中断後・失敗後の連続呼び出しを確認する。互換上保持する状態と安全性例外は DESIGN.md とプロジェクト README に従う。
- 派生コードを変更・配布するときは [第三者告知](UnLha32Re/THIRD_PARTY_NOTICES.md) と対応する著作権表示を保持する。原版 DLL は挙動比較用として扱う。
- 生成物は `UnLha32Re/artifacts/`、中間生成物は `UnLha32Re/build/` に置き、ソースとは分離する。
