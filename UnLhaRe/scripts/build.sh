#!/usr/bin/env bash
set -euo pipefail

# macOS usage:
#   bash scripts/build.sh --test
#   bash scripts/build.sh --target x86_64-apple-darwin
# These are equivalent to cargo fmt/clippy/test followed by:
#   cargo build --locked --workspace --release --target <target>

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/.." && pwd)"

if command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
    cargo_bin="$HOME/.cargo/bin/cargo"
else
    echo 'cargo was not found on PATH or at $HOME/.cargo/bin/cargo.' >&2
    exit 1
fi

if command -v rustc >/dev/null 2>&1; then
    rustc_bin="$(command -v rustc)"
else
    rustc_bin="$(dirname "$cargo_bin")/rustc"
    [[ -x "$rustc_bin" ]] || { echo 'rustc was not found next to cargo.' >&2; exit 1; }
fi

target=''
run_tests=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -ge 2 ]] || { echo '--target requires a value.' >&2; exit 2; }
            target="$2"
            shift 2
            ;;
        --test)
            run_tests=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

host_target="$("$rustc_bin" -vV | sed -n 's/^host: //p')"
case "$host_target" in
    x86_64-apple-darwin|aarch64-apple-darwin|x86_64-pc-windows-msvc|aarch64-pc-windows-msvc) ;;
    *) echo "Unsupported host target: $host_target" >&2; exit 1 ;;
esac

target="${target:-$host_target}"
case "$target" in
    x86_64-apple-darwin|aarch64-apple-darwin|x86_64-pc-windows-msvc|aarch64-pc-windows-msvc) ;;
    *) echo "Unsupported target: $target" >&2; exit 2 ;;
esac

host_os="${host_target#*-}"
host_os="${host_os#*-}"
target_os="${target#*-}"
target_os="${target_os#*-}"
is_cross_os=false
if [[ "$host_os" != "$target_os" ]]; then
    is_cross_os=true
fi

export CARGO_TARGET_DIR="$repository_root/build/cargo"
cd -- "$repository_root"

if [[ "$run_tests" == true && "$target" == "$host_target" ]]; then
    "$cargo_bin" fmt --all -- --check
    "$cargo_bin" clippy --locked --workspace --all-targets --target "$target" -- -D warnings
    "$cargo_bin" test --locked --workspace --target "$target"
elif [[ "$run_tests" == true ]]; then
    echo "Tests run only on the native host target ($host_target); building $target without running tests." >&2
fi

if [[ "$is_cross_os" == true ]]; then
    echo "No native SDK is available for $target on this host; running cargo check only. Build and test this target in CI." >&2
    "$cargo_bin" check --locked --workspace --release --target "$target"
    exit 0
fi

"$cargo_bin" build --locked --workspace --release --target "$target"

release_directory="$CARGO_TARGET_DIR/$target/release"
bundle_directory="$repository_root/artifacts/$target"
temporary_bundle="$repository_root/artifacts/.$target-$$-$RANDOM"
trap 'rm -rf "$temporary_bundle"' EXIT
mkdir -p "$temporary_bundle/include"

required_files=(
    "$repository_root/include/unlhare.h"
    "$repository_root/README.md"
    "$repository_root/VALIDATION.md"
    "$repository_root/../LICENSE"
    "$repository_root/THIRD_PARTY_NOTICES.md"
    "$repository_root/THIRD_PARTY_LICENSES.txt"
    "$repository_root/Cargo.lock"
)
if [[ "$target" == *-pc-windows-msvc ]]; then
    required_files+=(
        "$release_directory/unlhare-cli.exe"
        "$release_directory/unlhare.dll"
        "$release_directory/unlhare.dll.lib"
    )
else
    required_files+=("$release_directory/unlhare-cli" "$release_directory/libunlhare.dylib")
fi

for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || { echo "Cannot create bundle because a required file is missing: $file" >&2; exit 1; }
done
[[ -d "$repository_root/licensing" ]] || {
    echo "Cannot create bundle because the licensing directory is missing: $repository_root/licensing" >&2
    exit 1
}

cp "$repository_root/include/unlhare.h" "$temporary_bundle/include/unlhare.h"
cp -R "$repository_root/licensing" "$temporary_bundle/licensing"
cp \
    "$repository_root/README.md" \
    "$repository_root/VALIDATION.md" \
    "$repository_root/../LICENSE" \
    "$repository_root/THIRD_PARTY_NOTICES.md" \
    "$repository_root/THIRD_PARTY_LICENSES.txt" \
    "$repository_root/Cargo.lock" \
    "$temporary_bundle/"
if [[ "$target" == *-pc-windows-msvc ]]; then
    cp \
        "$release_directory/unlhare-cli.exe" \
        "$release_directory/unlhare.dll" \
        "$release_directory/unlhare.dll.lib" \
        "$temporary_bundle/"
    for pdb in "$release_directory"/*.pdb; do
        [[ ! -f "$pdb" ]] || cp "$pdb" "$temporary_bundle/"
    done
else
    cp "$release_directory/unlhare-cli" "$release_directory/libunlhare.dylib" "$temporary_bundle/"
fi

rm -rf "$bundle_directory"
mv "$temporary_bundle" "$bundle_directory"
trap - EXIT
echo "Bundle: $bundle_directory"
