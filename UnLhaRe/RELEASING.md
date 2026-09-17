# 近代化版のリリース

バージョンの正本はCargo.toml。近代化版のタグは `unlhare-v<version>`、ブランチは `release/unlhare/<version>`。旧版の `v1.0.0` と `release/1.0.0` は変更しない。

1. mainでREADME・CHANGELOGを整え、`pwsh -NoProfile -File scripts/build.ps1 -Test` で検証する。依存関係はCargo.lockで固定し、不要な旧版Full試験を実行しない。
2. mainと同じコミットをreleaseブランチへ通常pushする。Modern Rust CIの4ネイティブターゲットでfmt/clippy/test、Releaseビルド、C consumerが成功したことを確認する。CIキャッシュを使い、同じSHAのジョブを重複起動しない。
3. Windows x64/ARM64 bundleのDLL・CLIを既存 `../UnLha32Re/scripts/sign-release.ps1 -Candidate <absolute-path>` で署名する。署名状態Validとタイムスタンプを確認してからZIPを作る。署名後はビルドスクリプトでbundleを上書きしない。
4. macOSのtar.gzは該当SHAのCI artifactから取得する。ad-hoc署名はDeveloper ID署名や公証の代用ではなく、その旨を公開説明に記載する。
5. 配布名は `UnLhaRe-<version>-win-x64.zip`、`UnLhaRe-<version>-win-arm64.zip`、`UnLhaRe-<version>-macos-x64.tar.gz`、`UnLhaRe-<version>-macos-arm64.tar.gz`。全4ファイルの `SHA256SUMS.txt` を作る。
6. 同じSHAの専用タグでGitHub Releaseを作成し、4パッケージとSHA256一覧を公開する。公開URLから再取得した全ファイルのハッシュが一致することを確認する。

ビルド中間物はbuild/、公開物と再開用記録はartifacts/配下へ置く。失敗時はバージョンを変更せず、同じタグ・SHA・CI runの状態を確認して未完了工程から再開する。CI待機時間はランナーの空き状況に依存し、ローカルの短時間検証と区別する。
