#!/bin/sh
# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
#
# Builds the zstdcat helper.
#
# The helper is a small console program that decompresses a zstd stream from
# standard input and extracts one member from the tar archive inside it. The
# Windows installer ships it because the tar.exe that comes with Windows is
# built on libarchive 3.3.2, which has no zstd support at all.
#
# Usage:
#   ./build.sh                 build for the host
#   ./build.sh x86_64-w64      cross compile for Windows x64
#
# The Windows build is fully static apart from the Universal C runtime, which
# is part of Windows 10 and later.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=${1:-host}
out="$here/build"

sources="zstdcat.c \
  lib/common/debug.c \
  lib/common/entropy_common.c \
  lib/common/error_private.c \
  lib/common/fse_decompress.c \
  lib/common/pool.c \
  lib/common/threading.c \
  lib/common/xxhash.c \
  lib/common/zstd_common.c \
  lib/decompress/huf_decompress.c \
  lib/decompress/zstd_ddict.c \
  lib/decompress/zstd_decompress_block.c \
  lib/decompress/zstd_decompress.c"

# The assembly fast path is not used, so the helper stays portable and does
# not need the assembler.
flags="-O2 -Wall -Wextra -DZSTD_DISABLE_ASM -I$here/lib"

mkdir -p "$out"

case "$target" in
  x86_64-w64)
    compiler=${MINGW_CC:-x86_64-w64-mingw32-gcc}
    "$compiler" $flags -static -o "$out/zstdcat.exe" $sources
    echo "built $out/zstdcat.exe"
    ;;
  *)
    cc=${CC:-cc}
    # shellcheck disable=SC2086
    "$cc" $flags -o "$out/zstdcat" $sources
    echo "built $out/zstdcat"
    ;;
esac
