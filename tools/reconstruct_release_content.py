#!/usr/bin/env python3
"""Reconstruct shared game content from the public differential release."""

from __future__ import annotations

import argparse
import hashlib
import io
import pathlib
import urllib.parse
import urllib.request
import zipfile


def download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "MDE-macOS-builder/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def fields(text: str) -> list[list[str]]:
    return [line.split("\t") for line in text.replace("\r\n", "\n").splitlines()
            if line and not line.startswith("#")]


def safe_relative(value: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"unsafe release path: {value}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default="MinecraftDEdition/Minecraft-D-Edition")
    parser.add_argument("--tag", default="Test")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    base = f"https://github.com/{args.repository}/releases/download/{urllib.parse.quote(args.tag)}/"
    pointer = fields(download(base + "mde-update-pointer-v1.txt").decode("utf-8-sig"))
    pointer_values = {row[0]: row[1] for row in pointer[1:] if len(row) == 2}
    manifest_name = safe_relative(pointer_values["manifest"]).as_posix()
    manifest_bytes = download(base + urllib.parse.quote(manifest_name))
    if len(manifest_bytes) != int(pointer_values["size"]):
        raise ValueError("release manifest size mismatch")
    if hashlib.sha256(manifest_bytes).hexdigest() != pointer_values["sha256"].lower():
        raise ValueError("release manifest SHA-256 mismatch")

    manifest = fields(manifest_bytes.decode("utf-8-sig"))
    chunks: dict[str, tuple[int, str]] = {}
    files: dict[str, tuple[int, str, str]] = {}
    for row in manifest[1:]:
        if row[0] == "chunk" and len(row) == 4:
            chunks[row[1]] = (int(row[2]), row[3].lower())
        elif row[0] == "file" and len(row) == 5:
            path = safe_relative(row[1]).as_posix()
            if path.startswith("assets/") or path.startswith("data/minecraft/") or path == "data/eos.client.json":
                files[path] = (int(row[2]), row[3].lower(), row[4])

    args.output.mkdir(parents=True, exist_ok=True)
    needed_chunks = sorted({record[2] for record in files.values()})
    for chunk_name in needed_chunks:
        expected_size, expected_sha = chunks[chunk_name]
        payload = download(base + urllib.parse.quote(chunk_name))
        if len(payload) != expected_size or hashlib.sha256(payload).hexdigest() != expected_sha:
            raise ValueError(f"release shard verification failed: {chunk_name}")
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            members = {safe_relative(name).as_posix(): name for name in archive.namelist() if not name.endswith("/")}
            for path, (size, sha, owner_chunk) in files.items():
                if owner_chunk != chunk_name:
                    continue
                member = members.get(path)
                if member is None:
                    raise ValueError(f"{chunk_name} is missing {path}")
                content = archive.read(member)
                if len(content) != size or hashlib.sha256(content).hexdigest() != sha:
                    raise ValueError(f"file verification failed: {path}")
                destination = args.output.joinpath(*safe_relative(path).parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(content)

    print(f"Reconstructed {len(files)} shared files in {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

