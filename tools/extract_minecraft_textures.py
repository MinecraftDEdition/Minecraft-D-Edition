#!/usr/bin/env python3
"""Extract namespaced Minecraft Java textures from installed client JARs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
import struct
import sys
import zipfile
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


@dataclass(frozen=True)
class ClientJar:
    path: Path
    version_id: str
    release_time: str
    release_timestamp: float
    jar_sha1: str
    expected_sha1: str | None


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha1_bytes(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def parse_release_timestamp(value: str, fallback: float) -> float:
    if not value:
        return fallback
    normalized = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.timestamp()
    except ValueError:
        try:
            parsed = datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
            return parsed.replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            return fallback


def default_version_roots() -> list[Path]:
    home = Path.home()
    appdata = Path(os.environ.get("APPDATA", home / "AppData" / "Roaming"))
    return unique_existing_directories(
        [
            appdata / ".minecraft" / "versions",
            home / "curseforge" / "minecraft" / "Install" / "versions",
        ]
    )


def unique_existing_directories(paths: list[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for raw_path in paths:
        path = raw_path.expanduser().resolve()
        key = os.path.normcase(str(path))
        if key not in seen and path.is_dir():
            seen.add(key)
            result.append(path)
    return result


def client_hash_from_metadata(metadata: dict) -> str | None:
    downloads = metadata.get("downloads")
    if not isinstance(downloads, dict):
        return None
    client = downloads.get("client")
    if not isinstance(client, dict):
        return None
    value = client.get("sha1")
    if isinstance(value, str) and len(value) == 40:
        return value.lower()
    return None


def discover_client_jars(version_roots: list[Path]) -> tuple[list[ClientJar], list[dict]]:
    discovered: list[ClientJar] = []
    audit: list[dict] = []
    seen_jar_hashes: set[str] = set()

    for root in version_roots:
        for jar_path in sorted(root.glob("*/*.jar")):
            if jar_path.stem != jar_path.parent.name:
                continue
            metadata_path = jar_path.with_suffix(".json")
            try:
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                audit.append(
                    {"jar": str(jar_path), "status": "skipped_no_valid_metadata", "error": str(exc)}
                )
                continue

            version_id = str(metadata.get("id") or jar_path.stem)
            inherits_from = metadata.get("inheritsFrom")
            if isinstance(inherits_from, str) and inherits_from:
                audit.append(
                    {
                        "jar": str(jar_path),
                        "version": version_id,
                        "status": "skipped_mod_loader_wrapper",
                        "inherits_from": inherits_from,
                    }
                )
                continue

            try:
                actual_sha1 = sha1_file(jar_path)
            except OSError as exc:
                audit.append({"jar": str(jar_path), "status": "unreadable", "error": str(exc)})
                continue
            expected_sha1 = client_hash_from_metadata(metadata)
            if expected_sha1 is not None and actual_sha1 != expected_sha1:
                audit.append(
                    {
                        "jar": str(jar_path),
                        "version": version_id,
                        "status": "skipped_client_hash_mismatch",
                        "expected_sha1": expected_sha1,
                        "actual_sha1": actual_sha1,
                    }
                )
                continue
            if actual_sha1 in seen_jar_hashes:
                audit.append(
                    {
                        "jar": str(jar_path),
                        "version": version_id,
                        "status": "skipped_duplicate_client_jar",
                        "sha1": actual_sha1,
                    }
                )
                continue

            release_time = str(metadata.get("releaseTime") or metadata.get("time") or "")
            client = ClientJar(
                path=jar_path.resolve(),
                version_id=version_id,
                release_time=release_time,
                release_timestamp=parse_release_timestamp(release_time, jar_path.stat().st_mtime),
                jar_sha1=actual_sha1,
                expected_sha1=expected_sha1,
            )
            try:
                with zipfile.ZipFile(jar_path) as archive:
                    has_textures = any(
                        name.startswith("assets/minecraft/textures/")
                        and name.lower().endswith(".png")
                        for name in archive.namelist()
                    )
            except (OSError, zipfile.BadZipFile) as exc:
                audit.append(
                    {
                        "jar": str(jar_path),
                        "version": version_id,
                        "status": "skipped_invalid_zip",
                        "error": str(exc),
                    }
                )
                continue
            if not has_textures:
                audit.append(
                    {"jar": str(jar_path), "version": version_id, "status": "skipped_no_namespaced_textures"}
                )
                continue

            seen_jar_hashes.add(actual_sha1)
            discovered.append(client)
            audit.append(
                {
                    "jar": str(jar_path),
                    "version": version_id,
                    "release_time": release_time,
                    "status": "selected_client_jar",
                    "sha1": actual_sha1,
                    "verified_against_version_metadata": expected_sha1 is not None,
                }
            )

    discovered.sort(key=lambda item: (item.release_timestamp, item.version_id), reverse=True)
    return discovered, audit


def safe_archive_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(f"unsafe archive path: {value!r}")
    if any(part in {"", "."} for part in path.parts):
        raise ValueError(f"invalid archive path: {value!r}")
    return path


def resource_kind(path: PurePosixPath, namespaces: set[str], include_atlases: bool) -> str | None:
    parts = path.parts
    if len(parts) < 4 or parts[0] != "assets" or parts[1] not in namespaces:
        return None
    if parts[2] == "textures":
        lower_name = path.name.lower()
        if lower_name.endswith(".png"):
            return "texture_png"
        if lower_name.endswith(".png.mcmeta"):
            return "texture_metadata"
    if include_atlases and parts[2] == "atlases" and path.suffix.lower() == ".json":
        return "atlas_definition"
    return None


def validate_png(data: bytes) -> tuple[int, int]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("invalid PNG signature")
    offset = len(PNG_SIGNATURE)
    width = height = 0
    saw_ihdr = False
    saw_iend = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("truncated PNG chunk header")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_start = offset + 8
        chunk_end = chunk_start + length
        crc_end = chunk_end + 4
        if crc_end > len(data):
            raise ValueError("truncated PNG chunk")
        expected_crc = struct.unpack(">I", data[chunk_end:crc_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(data[chunk_start:chunk_end], actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise ValueError(f"PNG CRC mismatch in {chunk_type.decode('ascii', errors='replace')}")
        if chunk_type == b"IHDR":
            if saw_ihdr or length != 13:
                raise ValueError("invalid PNG IHDR")
            width, height = struct.unpack(">II", data[chunk_start : chunk_start + 8])
            if width <= 0 or height <= 0:
                raise ValueError("invalid PNG dimensions")
            saw_ihdr = True
        if chunk_type == b"IEND":
            if length != 0:
                raise ValueError("invalid PNG IEND")
            saw_iend = True
            offset = crc_end
            break
        offset = crc_end
    if not saw_ihdr or not saw_iend:
        raise ValueError("PNG is missing IHDR or IEND")
    return width, height


def validate_json(data: bytes) -> None:
    payload = json.loads(data.decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("metadata root must be a JSON object")


def atomic_write(target: Path, data: bytes) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(target)


def windows_path_key(path: Path) -> str:
    return str(path).replace("\\", "/").casefold()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--versions-root",
        action="append",
        type=Path,
        default=[],
        help="Minecraft versions directory (repeatable)",
    )
    parser.add_argument(
        "--target-assets",
        type=Path,
        default=Path("assets"),
        help="destination assets directory (default: ./assets)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("docs/minecraft-texture-extraction-manifest.json"),
        help="audit manifest path",
    )
    parser.add_argument(
        "--namespace",
        action="append",
        default=[],
        help="asset namespace to import (repeatable; default: minecraft)",
    )
    parser.add_argument(
        "--latest-only",
        action="store_true",
        help="extract only the newest installed vanilla client instead of the union",
    )
    parser.add_argument(
        "--no-atlases",
        action="store_true",
        help="do not import assets/<namespace>/atlases JSON definitions",
    )
    parser.add_argument("--dry-run", action="store_true", help="validate without writing assets")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    version_roots = unique_existing_directories(args.versions_root or default_version_roots())
    if not version_roots:
        print("No Minecraft versions directories were found.", file=sys.stderr)
        return 2

    client_jars, jar_audit = discover_client_jars(version_roots)
    if not client_jars:
        print("No verified vanilla client JARs with namespaced textures were found.", file=sys.stderr)
        return 2
    if args.latest_only:
        client_jars = client_jars[:1]

    target_assets = args.target_assets.resolve()
    manifest_path = args.manifest.resolve()
    namespaces = set(args.namespace or ["minecraft"])
    selected: dict[str, dict] = {}
    failures: list[dict] = []
    case_collisions: list[dict] = []
    duplicate_occurrences = 0
    changed_superseded_variants = 0

    for client in client_jars:
        try:
            archive = zipfile.ZipFile(client.path)
        except (OSError, zipfile.BadZipFile) as exc:
            failures.append({"jar": str(client.path), "error": str(exc)})
            continue
        with archive:
            for info in sorted(archive.infolist(), key=lambda item: item.filename):
                if info.is_dir():
                    continue
                try:
                    archive_path = safe_archive_path(info.filename)
                except ValueError as exc:
                    failures.append(
                        {"jar": str(client.path), "entry": info.filename, "error": str(exc)}
                    )
                    continue
                kind = resource_kind(archive_path, namespaces, not args.no_atlases)
                if kind is None:
                    continue

                relative = PurePosixPath(*archive_path.parts[1:])
                target = target_assets.joinpath(*relative.parts)
                target_key = windows_path_key(target)
                existing = selected.get(target_key)
                if existing is not None:
                    duplicate_occurrences += 1
                    if existing["logical_path"] != str(relative):
                        case_collisions.append(
                            {
                                "skipped_logical_path": str(relative),
                                "selected_logical_path": existing["logical_path"],
                                "skipped_version": client.version_id,
                            }
                        )
                    if existing["zip_crc32"] != f"{info.CRC:08x}" or existing["size"] != info.file_size:
                        changed_superseded_variants += 1
                        existing.setdefault("superseded_versions", []).append(client.version_id)
                    else:
                        existing.setdefault("also_present_in_versions", []).append(client.version_id)
                    continue

                try:
                    data = archive.read(info)
                    dimensions = None
                    if kind == "texture_png":
                        dimensions = validate_png(data)
                    else:
                        validate_json(data)
                    if not args.dry_run:
                        atomic_write(target, data)
                except (OSError, KeyError, RuntimeError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
                    failures.append(
                        {
                            "jar": str(client.path),
                            "version": client.version_id,
                            "entry": info.filename,
                            "error": str(exc),
                        }
                    )
                    continue

                record = {
                    "logical_path": str(relative),
                    "kind": kind,
                    "selected_version": client.version_id,
                    "selected_jar": str(client.path),
                    "target": str(target),
                    "size": len(data),
                    "sha1": sha1_bytes(data),
                    "zip_crc32": f"{info.CRC:08x}",
                }
                if dimensions is not None:
                    record["width"] = dimensions[0]
                    record["height"] = dimensions[1]
                selected[target_key] = record

    files = sorted(selected.values(), key=lambda item: item["logical_path"])
    png_count = sum(record["kind"] == "texture_png" for record in files)
    metadata_count = sum(record["kind"] == "texture_metadata" for record in files)
    atlas_count = sum(record["kind"] == "atlas_definition" for record in files)
    total_bytes = sum(record["size"] for record in files)
    manifest = {
        "generated_utc": datetime.now(tz=timezone.utc).isoformat(),
        "version_roots": [str(path) for path in version_roots],
        "target_assets": str(target_assets),
        "namespaces": sorted(namespaces),
        "latest_only": args.latest_only,
        "dry_run": args.dry_run,
        "summary": {
            "client_jars_used": len(client_jars),
            "texture_png_files": png_count,
            "texture_metadata_files": metadata_count,
            "atlas_definition_files": atlas_count,
            "total_files": len(files),
            "total_bytes": total_bytes,
            "duplicate_occurrences_skipped": duplicate_occurrences,
            "changed_older_variants_superseded": changed_superseded_variants,
            "windows_case_collisions_skipped": len(case_collisions),
            "failures": len(failures),
        },
        "client_jar_audit": jar_audit,
        "windows_case_collisions": case_collisions,
        "failures": failures,
        "files": files,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Verified vanilla client JARs used: {len(client_jars)}")
    print(f"Texture PNG files: {png_count}")
    print(f"Texture animation metadata files: {metadata_count}")
    print(f"Atlas definition files: {atlas_count}")
    print(f"Total imported files: {len(files)}")
    print(f"Total imported size: {total_bytes / (1024 * 1024):.2f} MiB")
    print(f"Changed older variants superseded: {changed_superseded_variants}")
    print(f"Windows case collisions skipped: {len(case_collisions)}")
    print(f"Failures: {len(failures)}")
    print(f"Manifest: {manifest_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
