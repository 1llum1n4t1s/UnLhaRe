# 近代化版のリリース

バージョンの正本はCargo.toml。近代化版のタグは `unlhare-v<version>`、ブランチは `release/unlhare/<version>`。旧版の `v1.0.0` と `release/1.0.0` は変更しない。

1. mainでREADME・CHANGELOGを整え、`pwsh -NoProfile -File scripts/build.ps1 -Test` で検証する。依存関係はCargo.lockで固定し、不要な旧版Full試験を実行しない。
2. mainと同じコミットをreleaseブランチへ通常pushする。Modern Rust CIの4ネイティブターゲットでfmt/clippy/test、Releaseビルド、C consumerが成功したことを確認する。CIキャッシュを使い、同じSHAのジョブを重複起動しない。
3. Windows x64/ARM64 bundleのDLL・CLIを既存 `../UnLha32Re/scripts/sign-release.ps1 -Candidate <absolute-path>` で署名する。署名状態Validとタイムスタンプを確認してからZIPを作る。署名後はビルドスクリプトでbundleを上書きしない。
4. macOSのtar.gzは該当SHAのCI artifactから取得する。ad-hoc署名はDeveloper ID署名や公証の代用ではなく、その旨を公開説明に記載する。
5. 配布名は `UnLhaRe-<version>-win-x64.zip`、`UnLhaRe-<version>-win-arm64.zip`、`UnLhaRe-<version>-macos-x64.tar.gz`、`UnLhaRe-<version>-macos-arm64.tar.gz`。全4ファイルの `SHA256SUMS.txt` を作る。
6. 同じSHAの専用タグでGitHub Releaseを作成し、4パッケージとSHA256一覧を公開する。公開URLから再取得した全ファイルのハッシュが一致することを確認する。

## NuGetパッケージ

`Kagayoi.UnLhaRe` は同じ版のGitHub Releaseを公開してから、`Publish UnLhaRe NuGet package` workflowを手動実行して公開する。入力するversionは安定版の`1.0.x`で、Cargo.toml、`unlhare-v<version>`タグ、GitHub Release、NuGet packageを同じversionにそろえる。

workflowはGitHub Releaseの`SHA256SUMS.txt`と署名済みWindows x64/ARM64 ZIPを取得し、ハッシュとDLLのAuthenticode署名を検証する。native DLLを再ビルドせず、検証済みZIPから取り出した2ファイルを`runtimes/win-x64/native/`と`runtimes/win-arm64/native/`へ梱包する。package内のDLL、buildTransitive target、第三者告知とライセンス全文を検査してから、NuGet.org Trusted Publishingで公開する。

初回公開前にNuGet.orgでrepository `1llum1n4t1s/UnLhaRe`、workflow `publish-unlhare-nuget.yml`のTrusted Publishing policyを登録し、GitHub repository variable `NUGET_USER`へNuGet.org usernameを設定する。公開後は正規feedで`Kagayoi.UnLhaRe`の完全一致versionを確認してから、`vava.config.json`のconsumer updateでLhamielの`UnLhaReVersion`と追跡済みlock fileを更新する。Lhamiel自体のversionとreleaseはこの同期では変更しない。

ビルド中間物はbuild/、公開物と再開用記録はartifacts/配下へ置く。失敗時はバージョンを変更せず、同じタグ・SHA・CI runの状態を確認して未完了工程から再開する。CI待機時間はランナーの空き状況に依存し、ローカルの短時間検証と区別する。
