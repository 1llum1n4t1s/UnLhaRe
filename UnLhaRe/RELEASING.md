# 近代化版のリリース

バージョンの正本はCargo.toml。GitHub Releaseは使わない。配布は Cloudflare R2（バケット `unlhare-updates`、`https://unlhare.kagayoi.com`）が唯一の入口で、mainのコミットに付けた軽量タグ `unlhare-v<version>` のpushが配信の起点になる（UnLha32Reと同じリポジトリにあるため、タグに `unlhare-` を付けて区別する）。旧版の `release/1.0.0` は変更しない。

1. mainでREADME・CHANGELOGを整え、`pwsh -NoProfile -File scripts/build.ps1 -Test` で検証する。依存関係はCargo.lockで固定し、不要な旧版Full試験を実行しない。
2. mainをpushしたあと、そのコミットに軽量タグ `unlhare-v<version>` を付け、`git push --no-follow-tags origin refs/tags/unlhare-v<version>` で1本だけpushする（`--tags` は使わない）。これだけで `Release UnLhaRe` workflow（`.github/workflows/release-unlhare.yml`）が自動で始まる。承認待ちはない。workflowは次の4ジョブで進む。
   - `resolve`: タグであること、`unlhare-v<version>`（`1.0.x`）の形、軽量タグがそのコミットを指すこと、mainの祖先であること、`UnLhaRe/Cargo.toml` の `[package] version` との一致を確かめて版を決める。どれかが合わなければ止まる。
   - `build`: `modern.yml` を同じrunの中で呼び出し、3ネイティブターゲット（Windows x64/ARM64、macOS ARM64）でfmt/clippy/test、Releaseビルド、C consumerを検証する。Secretsは渡さない。macOS ARM64はad-hoc署名のtar.gzで、Developer ID署名・公証ではない。
   - `sign`: build の成果物のうちWindows x64/ARM64 bundleのDLL・CLIを [Sigilune](https://github.com/1llum1n4t1s/Sigilune) で署名し（`../UnLha32Re/scripts/sign-release.ps1` と同じ処理）、署名状態Valid・署名者・タイムスタンプを確認してからZIPを作る。署名用Secrets（`SIGILUNE_EMAIL`・`SIGILUNE_TOTP_URI`）は署名stepだけへ渡す。`SHA256SUMS.txt`（3ファイル）と `release.json`（version・commit・files[name, sha256]）を作り、`unlhare-release-<version>` としてActionsの成果物に残す。
   - `publish`: 署名済み成果物を取得し、`scripts/Publish-R2.ps1` でR2へ配信する。`CLOUDFLARE_API_TOKEN` は配信stepだけへ渡す。
3. 配布名は `UnLhaRe-<version>-win-x64.zip`、`UnLhaRe-<version>-win-arm64.zip`、`UnLhaRe-<version>-macos-arm64.tar.gz`。R2の置き場は次のとおり。
   - `<version>/` 以下（版付き・不変、`Cache-Control: public, max-age=31536000, immutable`）: 上の3ファイル、`SHA256SUMS.txt`、`release.json`。
   - `latest.json`（固定名、`no-cache`）: `release.json` と同じ内容。最後に更新し、固定名だけCDNキャッシュを purge する。R2の `latest.json` がより新しい版なら更新しない（古い版の再配信で後退させない）。
4. 配信は「入力検査（ファイル集合・実ハッシュと `SHA256SUMS.txt`・`release.json` の照合・バケットとゾーンの権限）→ 版付きファイル → `SHA256SUMS.txt` → `release.json` → 公開URLから取り直して照合 → `latest.json` → purge」の順。同じ版が既にR2にあれば、内容が同一のときだけ成功し（unchanged）、別内容は上書きせず失敗する。
5. 一時的な失敗は、タグを動かさず同じタグで再実行する（コードの修正が要るときは、patchを上げた新しいタグで配信し直す）。`publish` だけが失敗したなら、失敗したジョブだけを再実行すれば、署名済みの同じバイト列（同じ成果物）をもう一度配れる（署名し直すとタイムスタンプでハッシュが変わるため、`sign` から再実行すると同じ版の別内容になりR2が拒否する）。署名からやり直す必要があるのにR2へ一部が置かれている場合は、原因を確認してから対応を決める。workflow全体からの再実行は `workflow_dispatch`（`gh workflow run release-unlhare.yml --ref unlhare-v<version>`）で行える。
6. リリースノートは `CHANGELOG.md` に書く（GitHub Releaseは作らない）。配信後にR2の `https://unlhare.kagayoi.com/<version>/` の内容を確認し、`SHA256SUMS.txt` のハッシュを記録する。

`Release UnLhaRe` が使うEnvironment `release` は、許可するrefをタグ `unlhare-v*` に限る。Secretsは `SIGILUNE_EMAIL`、`SIGILUNE_TOTP_URI`、`CLOUDFLARE_API_TOKEN`。

ローカルで署名する場合は、`sigilune setup` 済みの端末で `../UnLha32Re/scripts/sign-release.ps1 -Candidate <absolute-path>` を使う。署名後はビルドスクリプトでbundleを上書きしない。

## R2への配信スクリプト

`scripts/Publish-R2.ps1` の `-ValidateOnly` は、ネットワークに接続せず入力検査だけを行う（ファイル集合に厳密一致、全ファイルの実ハッシュを `SHA256SUMS.txt` と `release.json` に照合）。`scripts/R2Distribution.Common.ps1` と `scripts/R2Transfer.Core.cs` はSigilune・Edictoraと同じ転送実装の同梱コピーで、無改変のまま使う。片方だけを直さず、直すときは全リポジトリで同じ内容にそろえる。

### 旧方式（GitHub Release）で公開済みの版の取り込み

タグ・Release方式で公開した版は、`-Import` でR2へ移す。配布ファイルの中身は変えず、元のRelease添付ファイルを検証して配信する。元の `SHA256SUMS.txt` にmacOS Intelなど配布対象外の行が残っていても、配布する3ファイル（x64/ARM64 ZIPとmacOS ARM64 tar.gz）について照合して通し、配信する `SHA256SUMS.txt` は3ファイルだけの正規形で作り直す。`release.json` は元のタグが指していたコミットから生成する。

```powershell
$dir = Join-Path $env:TEMP 'unlhare-import-1.0.4'
gh release download unlhare-v1.0.4 --repo 1llum1n4t1s/UnLhaRe --dir $dir --pattern 'UnLhaRe-1.0.4-*' --pattern 'SHA256SUMS.txt'
pwsh -NoProfile -File scripts/Publish-R2.ps1 -Version 1.0.4 -DistDirectory $dir -Import -Commit 34349df36f7489437d4ebb4ad91f3a8e15e237dd -ValidateOnly
# 問題なければ、CLOUDFLARE_API_TOKEN を設定して -ValidateOnly を外して実行する。
```

## 過去の版とコミットの対応

タグ `unlhare-v<version>` は廃止した。タグ廃止後も追えるよう、各版のコミットを残す。1.0.4以降は、R2の `<version>/release.json` の `commit` が配信したコミットを示す。

| 版 | コミット |
| --- | --- |
| 1.0.0 | `3886241bfd8098a9afcbb9deef7a6f5022b4c620` |
| 1.0.1 | `4bea52f22985452f757020b1ce441ee70fee3b8e` |
| 1.0.2 | `cdf504e46bc6553032325ed56510a262efbd05c2` |
| 1.0.3 | `e44644e79e1fb8365a6b400e037dc837303650c8` |
| 1.0.4 | `34349df36f7489437d4ebb4ad91f3a8e15e237dd` |

## NuGetパッケージ

`Kagayoi.UnLhaRe` は同じ版をR2へ配信してから、`Publish UnLhaRe NuGet package` workflowを手動実行して公開する（自動では始まらない）。入力するversionは安定版の`1.0.x`で、Cargo.toml、R2の `<version>/`、NuGet packageを同じversionにそろえる。

workflowはR2の `https://unlhare.kagayoi.com/<version>/` から `release.json`、署名済みWindows x64/ARM64 ZIP、`SHA256SUMS.txt` を取得する（リダイレクトは追わない）。`release.json` のcommit（40桁hex）をfetchしてチェックアウトし、`SHA256SUMS.txt` と `release.json` のハッシュ、DLLのAuthenticode署名を検証する。native DLLを再ビルドせず、検証済みZIPから取り出した2ファイルを`runtimes/win-x64/native/`と`runtimes/win-arm64/native/`へ梱包する。package内のDLL、buildTransitive target、第三者告知とライセンス全文を検査してから、NuGet.org Trusted Publishingで公開する。このworkflowにはEnvironmentを付けない（Trusted PublishingのOIDC claimを変えないため）。

初回公開前にNuGet.orgでrepository `1llum1n4t1s/UnLhaRe`、workflow `publish-unlhare-nuget.yml`のTrusted Publishing policyを登録し、GitHub repository variable `NUGET_USER`へNuGet.org usernameを設定する。workflowの受付・実行結果と`dotnet nuget push`の送信結果を記録する。

ビルド中間物はbuild/、公開物と再開用記録はartifacts/配下へ置く。失敗時はバージョンを変更せず、同じブランチ・コミット・Actions runの状態を確認して未完了工程から再開する。CI待機時間はランナーの空き状況に依存し、ローカルの短時間検証と区別する。
