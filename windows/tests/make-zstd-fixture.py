#!/usr/bin/env python3
# Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
"""Creates a small zstd compressed tar archive for the helper test.

The archive holds one member that the helper has to find, followed by another
one. The helper stops as soon as the wanted member is written, so the second
member is never reached. The test checks the extracted bytes and the exit
code.
"""
from __future__ import annotations

import hashlib
import io
import sys
import tarfile


def build() -> bytes:
    payload = bytes(range(256)) * 64
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        member = tarfile.TarInfo("test/member.bin")
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
        other = tarfile.TarInfo("test/other.bin")
        other_data = b"not wanted"
        other.size = len(other_data)
        archive.addfile(other, io.BytesIO(other_data))
    return buffer.getvalue()


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: make-zstd-fixture.py <output.tar.zst> <sha256-of-member>", file=sys.stderr)
        return 2

    import zstandard

    payload = bytes(range(256)) * 64
    digest = hashlib.sha256(payload).hexdigest()
    if digest != sys.argv[2]:
        print(f"unexpected member digest: {digest}", file=sys.stderr)
        return 1

    compressor = zstandard.ZstdCompressor()
    with open(sys.argv[1], "wb") as stream:
        stream.write(compressor.compress(build()))
    print(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
