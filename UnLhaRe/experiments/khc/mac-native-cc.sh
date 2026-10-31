#!/bin/sh
# Xcodeの実コンパイラーへ直接渡し、専用領域外のxcrunキャッシュを経由しない。
exec /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang "$@"
