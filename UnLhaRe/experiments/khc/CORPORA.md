# 研究用の固定コーパス

配布元が圧縮評価向けに公開しているデータを、ローカル研究だけに利用する。包括的な再配布ライセンスは確認していないため、アーカイブや内容をソース管理・配布bundleへ入れない。原本のハッシュと分類だけを[manifest](CORPUS_MANIFEST.json)へ記録する。実行形式も入力byte列として扱い、実行しない。

| 集合 | 役割 | 件数 / 合計bytes | 一次資料 |
| --- | --- | --- | --- |
| Canterbury標準 | 開発・改善量の比較 | 11 / 2810784 | [公式説明](https://corpus.canterbury.ac.nz/descriptions/) |
| Silesia | 初回はholdout、2026-10-11現在は観測済みの調整用集合 | 12 / 211938580 | [著者配布ページ](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia) |

Canterburyの全11入力を省略せず使用する。Silesiaは当初のsource固定後に全量測定したが、その後のMozilla/x-ray診断と設計変更へ利用しているため、今後の方式に対する未見性はない。manifestの`holdout-not-yet-measured`は初回登録時の凍結ラベルであり、現在の未使用を示さない。元の集合・SHA参照は書き換えない。2026-10-11のDelta16 revision 5全量screenは完全復元を確認したが、総サイズが同じ制限の7-Zipを上回り不合格だった。詳細は[開発記録](DEVELOPMENT.md)を参照する。

今後の総合合格には、次の候補sourceを固定した後に別の未見集合を事前固定して評価する。Silesiaだけで日本語・JSON・ARM64・現代の既圧縮データまで網羅できるとは扱わない。追加評価と、保存形式・API・資源制約の検証が残る。

取得には`fetch-corpora.ps1`を使用した。URL・取得日時・archive SHA-256・全member SHA-256をmanifestへ保存し、展開前に各ファイル名と元サイズを公式一覧へ照合する。初回取得時のSHA-256は同一性の固定用であり、配布者署名の代わりではない。

```powershell
# UnLhaRe/を作業ディレクトリとして、未作成の保存先へ取得する。
./experiments/khc/fetch-corpora.ps1

$inputs = @(Get-ChildItem ./build/khc-corpus/canterbury-development -File | Sort-Object Name | ForEach-Object FullName)
./experiments/khc/compare.ps1 `
  -LabPath ./build/cargo/release/examples/khc_lab.exe `
  -SevenZipPath ./build/khc-baseline-20260918/x64/7za.exe `
  -InputFiles $inputs -WorkDirectory ./build/khc-development-new `
  -Algorithms @('standard','lz','context','auto') -DictionaryMiB 64 -Repeats 5
```

`build/khc-corpus/`は継続研究の入力として保持する。SHA-256を照合し、ダウンロードを重複実行しない。初回比較の7-Zipは公式26.03 x64、SHA-256は[初回測定](BASELINE.md)の値。2026-10-11の全量screenでは、その時点の公式安定版26.04 x64を使用し、実行ファイル・全引数・新規書庫のSHAを別の結果へ記録した。1回反復の開発試験はサイズ・可逆性の判定に使うが、速度優位や最終合格の判定に使わない。
