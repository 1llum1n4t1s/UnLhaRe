# SIMD helperの命令・配置調査: 実装前契約

前のfull正確さ検証は成功したが、新SIMD候補の正式速度比較は2026-10-01T18:14:08Zのpreflight総CPU20%でterminal。圧縮/展開CLI0件、性能root/reportなし。同候補を再試行せず、現在凍結helperの静的codegenを調査する。

失敗計画:

1. 別source/compile flagsの命令を実codecの命令やCPUサイクルと混同する。helper SHA9A135D48AD9C80B02B5BF916301EBBA0F95ED3EA578B6E0B0563A4E6E38645C7、rustc1.98.1 SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BCを固定し、独立probe(lib/emit=asm)だけの結果と明記する。ABI/layout/immediateやcall/storeの存在は命令証拠で、実行回数・CPUコスト・速度差の証明ではない。
2. optimizerがkernelを削除する。公開no_mangle wrapperからBatchEngine::ratio4を呼び、assemblyを識別する。使用helperとprobeを前後hashで照合。AVX命令の場所と動的backend分岐を区別し、scalarにAVXを要求すると推論しない。
3. 巨大dump/cache作成。build/khc-simd-layout-20261002は2MiB予算。単体rustc --crate-type=lib --emit=asmのみ、EXE/PDB/Cargo target/traceを作らない。生成前後guard、child120秒、fresh root一回。sourceはapply_patchで保存する。
4. 推測で採用。Ratio/4Ratio/CTS Resultなどのコンパイル時sizeをexport定数getterの即値から読む。stack/コピー/callの存在が多くても、局所化/compact array案は仮説に留める。新仕様を実装するなら数値/full E2Eと別性能契約が必要であり、今回の調査だけで7-Zip超えや高速化を主張しない。

scopeは研究helper/probeのみ。製品API、既存source/proof、CPU静穏ゲート、priority/affinity/powerは変えない。
