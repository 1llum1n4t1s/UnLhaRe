# 近代化版のリリース

バージョンの正本はCargo.toml。近代化版のタグは `unlhare-v<version>`、ブランチは `release/unlhare/<version>`。旧版の `v1.0.0` と `release/1.0.0` は変更しない。

1. mainでREADME・CHANGELOGを整え、`pwsh -NoProfile -File scripts/build.ps1 -Test` で検証する。依存関係はCargo.lockで固定し、不要な旧版Full試験を実行しない。
2. mainと同じコミットをreleaseブランチへ通常pushする。Modern Rust CIの3ネイティブターゲット（Windows x64/ARM64、macOS ARM64）でfmt/clippy/test、Releaseビルド、C consumerが成功したことを確認する。CIキャッシュを使い、同じSHAのジョブを重複起動しない。
3. mainから `Release UnLhaRe` workflow（`.github/workflows/release-unlhare.yml`）を手動実行する（`gh workflow run release-unlhare.yml --ref main -f version=<version> -f create_draft_release=true`）。workflowは承認待ちなしで動き、再ビルドせず、releaseブランチHEADで成功したModern RustのWindows x64/ARM64 bundleのDLL・CLIを [Sigilune](https://github.com/1llum1n4t1s/Sigilune) で署名し（`../UnLha32Re/scripts/sign-release.ps1` と同じ処理）、署名状態Valid・署名者・タイムスタンプを確認してからZIPを作る。署名用Secrets（`SIGILUNE_EMAIL`・`SIGILUNE_TOTP_URI`）は署名stepだけへ渡す。
4. macOS ARM64のtar.gzは同じCI runのartifactをそのまま使う。ad-hoc署名はDeveloper ID署名や公証の代用ではなく、その旨を公開説明に記載する（下書きの既定文に含む）。
5. 配布名は `UnLhaRe-<version>-win-x64.zip`、`UnLhaRe-<version>-win-arm64.zip`、`UnLhaRe-<version>-macos-arm64.tar.gz`。workflowが全3ファイルの `SHA256SUMS.txt` を作り、Actionsの成果物にも残す。
6. `create_draft_release=true` のとき、workflowが同じSHAを対象に `unlhare-v<version>` のGitHub Releaseを下書きで作成し、3パッケージとSHA256一覧を添付する。既存のタグ・Releaseは上書きしない。リリースノートを整えて本人が公開し、公開物のハッシュを記録する。

ローカルで署名する場合は、`sigilune setup` 済みの端末で `../UnLha32Re/scripts/sign-release.ps1 -Candidate <absolute-path>` を使う。署名後はビルドスクリプトでbundleを上書きしない。

## NuGetパッケージ

`Kagayoi.UnLhaRe` は同じ版のGitHub Releaseを公開してから、`Publish UnLhaRe NuGet package` workflowを手動実行して公開する。入力するversionは安定版の`1.0.x`で、Cargo.toml、`unlhare-v<version>`タグ、GitHub Release、NuGet packageを同じversionにそろえる。

workflowはGitHub Releaseの`SHA256SUMS.txt`と署名済みWindows x64/ARM64 ZIPを取得し、ハッシュとDLLのAuthenticode署名を検証する。native DLLを再ビルドせず、検証済みZIPから取り出した2ファイルを`runtimes/win-x64/native/`と`runtimes/win-arm64/native/`へ梱包する。package内のDLL、buildTransitive target、第三者告知とライセンス全文を検査してから、NuGet.org Trusted Publishingで公開する。

初回公開前にNuGet.orgでrepository `1llum1n4t1s/UnLhaRe`、workflow `publish-unlhare-nuget.yml`のTrusted Publishing policyを登録し、GitHub repository variable `NUGET_USER`へNuGet.org usernameを設定する。workflowの受付・実行結果と`dotnet nuget push`の送信結果を記録する。

ビルド中間物はbuild/、公開物と再開用記録はartifacts/配下へ置く。失敗時はバージョンを変更せず、同じタグ・SHA・CI runの状態を確認して未完了工程から再開する。CI待機時間はランナーの空き状況に依存し、ローカルの短時間検証と区別する。
