# Third-party notices

## UnLha64x

次のファイルは `sample/UnLha64x-main` の対応ファイルを出発点としており、
UnLhaRe 向けに大幅な変更と機能追加を行っています。

- `src/unlhare.cpp`（`msvc/UnLha64/unlha64.cpp` 由来）
- `src/lha_progress.c`（`msvc/UnLha64/lha_progress.c` 由来）
- `include/UNLHA64EX.H`（`Header/UNLHA64EX.H` 由来）

UnLha64x の README は、そのラッパー実装に LHa エンジンと同じ再配布条件を
適用すると説明しています。修正版または DLL を再配布する場合は、該当する
ソースとドキュメントを添付し、派生元の条件を遵守してください。これらの派生
ファイルはルートの MIT License だけで再許諾されるものではありません。

## LHa for UNIX with Autoconf

`sample/lha-master` と歴史的な `sample/lha211_s` は、UnLha64x の系譜・ベースに
当たる上流 LHa 実装です。`third_party/lha/src` は LHa for UNIX with Autoconf
系のコードに、UnLha64x で行われた Windows／DLL 対応と UnLhaRe の互換修正を
加えたものです。

上流の再配布条件は `third_party/lha/man/lha.man` に、README は
`third_party/lha/README.upstream.md` に保存しています。著作権表示を保持し、
ソースと文書を含めるなど、そこに記載された条件を遵守してください。改変版で
あるこのコードはルートの MIT License の対象外です。

## UNLHA32 compatible interface

`include/UNLHA32.H` は Micco 氏の UNLHA32.DLL 3.00 配布物に由来し、公開構造体
の配置、定数、関数宣言を維持するために収録しています。元の配布物に含まれる
文書と条件を確認してください。

UnLhaRe は元の `UNLHA32.DLL` バイナリをリンクまたは収録しません。一方で、
上記のとおり UnLha64x と LHa のコードから派生しているため、DLL 全体を独立した
クリーンルーム実装とは称しません。
