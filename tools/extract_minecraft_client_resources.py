#!/usr/bin/env python3
"""Import data-driven resources from the newest installed vanilla Java client."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys
import zipfile

from extract_minecraft_textures import (
    default_version_roots,
    discover_client_jars,
    unique_existing_directories,
)


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def sha1_bytes(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def safe_relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(f"unsafe resource path: {value!r}")
    if any(part in {"", "."} for part in path.parts):
        raise ValueError(f"invalid resource path: {value!r}")
    return path


def validate_payload(path: PurePosixPath, data: bytes) -> None:
    lower_name = path.name.lower()
    if lower_name.endswith(".json") or lower_name.endswith(".mcmeta"):
        json.loads(data.decode("utf-8"))
    elif lower_name.endswith(".png") and not data.startswith(PNG_SIGNATURE):
        raise ValueError("invalid PNG signature")


def atomic_write(target: Path, data: bytes) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(target)


def windows_path_key(path: Path) -> str:
    return str(path).replace("\\", "/").casefold()


def load_version_metadata(client_jar: Path) -> dict:
    metadata_path = client_jar.with_suffix(".json")
    return json.loads(metadata_path.read_text(encoding="utf-8"))


def find_asset_root(client_jar: Path, override: Path | None) -> Path | None:
    if override is not None:
        candidate = override.expanduser().resolve()
        return candidate if (candidate / "indexes").is_dir() and (candidate / "objects").is_dir() else None
    if len(client_jar.parents) >= 3:
        candidate = client_jar.parents[2] / "assets"
        if (candidate / "indexes").is_dir() and (candidate / "objects").is_dir():
            return candidate.resolve()
    return None


def asset_index_path(metadata: dict, asset_root: Path | None) -> Path | None:
    if asset_root is None:
        return None
    asset_index = metadata.get("assetIndex")
    if not isinstance(asset_index, dict):
        return None
    index_id = asset_index.get("id")
    if not isinstance(index_id, str) or not index_id:
        return None
    candidate = asset_root / "indexes" / f"{index_id}.json"
    return candidate if candidate.is_file() else None


def should_import_jar_entry(path: PurePosixPath) -> bool:
    parts = path.parts
    if len(parts) >= 3 and parts[:2] == ("assets", "minecraft"):
        # These were imported and exhaustively verified by the dedicated texture tool.
        return parts[2] not in {"textures", "atlases"}
    return len(parts) >= 3 and parts[:2] == ("data", "minecraft")


def should_import_index_entry(path: PurePosixPath) -> bool:
    # Sounds were imported and exhaustively verified by the dedicated sound tool.
    if len(path.parts) >= 2 and path.parts[:2] == ("minecraft", "sounds"):
        return False
    if str(path) == "minecraft/sounds.json":
        return False
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-jar", type=Path, help="specific verified vanilla client JAR")
    parser.add_argument(
        "--versions-root",
        action="append",
        type=Path,
        default=[],
        help="Minecraft versions directory used for automatic newest-client discovery",
    )
    parser.add_argument("--asset-root", type=Path, help="hashed Minecraft assets directory")
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="project root containing assets/ and data/ (default: current directory)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("docs/minecraft-client-resource-extraction-manifest.json"),
        help="audit manifest path",
    )
    parser.add_argument("--dry-run", action="store_true", help="validate without writing resources")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    jar_audit: list[dict] = []
    if args.client_jar is not None:
        client_jar = args.client_jar.expanduser().resolve()
        if not client_jar.is_file():
            print(f"Client JAR not found: {client_jar}", file=sys.stderr)
            return 2
        version_metadata = load_version_metadata(client_jar)
        version_id = str(version_metadata.get("id") or client_jar.stem)
    else:
        version_roots = unique_existing_directories(args.versions_root or default_version_roots())
        clients, jar_audit = discover_client_jars(version_roots)
        if not clients:
            print("No verified vanilla client JAR was found.", file=sys.stderr)
            return 2
        client = clients[0]
        client_jar = client.path
        version_id = client.version_id
        version_metadata = load_version_metadata(client_jar)

    project_root = args.project_root.expanduser().resolve()
    manifest_path = args.manifest.expanduser().resolve()
    asset_root = find_asset_root(client_jar, args.asset_root)
    index_path = asset_index_path(version_metadata, asset_root)
    selected: dict[str, dict] = {}
    failures: list[dict] = []
    asset_index_overrides: list[dict] = []
    category_counts: Counter[str] = Counter()

    try:
        archive = zipfile.ZipFile(client_jar)
    except (OSError, zipfile.BadZipFile) as exc:
        print(f"Unable to open client JAR: {exc}", file=sys.stderr)
        return 2
    with archive:
        for info in sorted(archive.infolist(), key=lambda item: item.filename):
            if info.is_dir():
                continue
            try:
                resource_path = safe_relative_path(info.filename)
            except ValueError as exc:
                failures.append({"source": str(client_jar), "entry": info.filename, "error": str(exc)})
                continue
            if not should_import_jar_entry(resource_path):
                continue
            try:
                data = archive.read(info)
                validate_payload(resource_path, data)
                target = project_root.joinpath(*resource_path.parts)
                if not args.dry_run:
                    atomic_write(target, data)
            except (OSError, KeyError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
                failures.append(
                    {
                        "source": str(client_jar),
                        "version": version_id,
                        "entry": info.filename,
                        "error": str(exc),
                    }
                )
                continue
            category = "/".join(resource_path.parts[:3])
            category_counts[category] += 1
            selected[windows_path_key(target)] = {
                "logical_path": str(resource_path),
                "source_type": "client_jar",
                "source": str(client_jar),
                "version": version_id,
                "target": str(target),
                "size": len(data),
                "sha1": sha1_bytes(data),
                "zip_crc32": f"{info.CRC:08x}",
            }

    index_id = None
    if index_path is not None and asset_root is not None:
        try:
            index_payload = json.loads(index_path.read_text(encoding="utf-8"))
            objects = index_payload.get("objects", {})
            if not isinstance(objects, dict):
                raise ValueError("asset index 'objects' value is not an object")
            index_id = index_path.stem
            for logical_name, metadata in sorted(objects.items()):
                try:
                    resource_path = safe_relative_path(logical_name)
                except ValueError as exc:
                    failures.append({"source": str(index_path), "entry": logical_name, "error": str(exc)})
                    continue
                if not should_import_index_entry(resource_path) or not isinstance(metadata, dict):
                    continue
                object_hash = metadata.get("hash")
                if not isinstance(object_hash, str) or len(object_hash) != 40:
                    failures.append(
                        {"source": str(index_path), "entry": logical_name, "error": "invalid object hash"}
                    )
                    continue
                source = asset_root / "objects" / object_hash[:2] / object_hash
                try:
                    data = source.read_bytes()
                    if sha1_bytes(data) != object_hash.lower():
                        raise ValueError("asset object SHA-1 mismatch")
                    validate_payload(resource_path, data)
                    target = project_root / "assets"
                    target = target.joinpath(*resource_path.parts)
                    if not args.dry_run:
                        atomic_write(target, data)
                except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
                    failures.append(
                        {"source": str(source), "entry": logical_name, "error": str(exc)}
                    )
                    continue
                parts = resource_path.parts
                category = "indexed/" + ("/".join(parts[:2]) if len(parts) >= 2 else parts[0])
                category_counts[category] += 1
                target_key = windows_path_key(target)
                previous = selected.get(target_key)
                if previous is not None:
                    asset_index_overrides.append(
                        {
                            "logical_path": "assets/" + str(resource_path),
                            "replaced_source_type": previous["source_type"],
                            "replaced_source": previous["source"],
                            "replaced_sha1": previous["sha1"],
                            "asset_index_sha1": object_hash.lower(),
                        }
                    )
                selected[target_key] = {
                    "logical_path": "assets/" + str(resource_path),
                    "source_type": "asset_index",
                    "source": str(source),
                    "asset_index": str(index_path),
                    "target": str(target),
                    "size": len(data),
                    "sha1": object_hash.lower(),
                }
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            failures.append({"source": str(index_path), "error": str(exc)})

    files = sorted(selected.values(), key=lambda item: item["logical_path"])
    manifest = {
        "generated_utc": datetime.now(tz=timezone.utc).isoformat(),
        "client_version": version_id,
        "client_jar": str(client_jar),
        "asset_root": str(asset_root) if asset_root else None,
        "asset_index": str(index_path) if index_path else None,
        "asset_index_id": index_id,
        "project_root": str(project_root),
        "dry_run": args.dry_run,
        "summary": {
            "files_imported": len(files),
            "total_bytes": sum(record["size"] for record in files),
            "client_jar_files": sum(record["source_type"] == "client_jar" for record in files),
            "asset_index_files": sum(record["source_type"] == "asset_index" for record in files),
            "asset_index_overrides": len(asset_index_overrides),
            "failures": len(failures),
        },
        "category_counts": dict(sorted(category_counts.items())),
        "client_jar_discovery_audit": jar_audit,
        "asset_index_overrides": asset_index_overrides,
        "failures": failures,
        "files": files,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Client version: {version_id}")
    print(f"Client JAR resources imported: {manifest['summary']['client_jar_files']}")
    print(f"Asset-index resources imported: {manifest['summary']['asset_index_files']}")
    print(f"Asset-index overrides applied: {len(asset_index_overrides)}")
    print(f"Total resources imported: {len(files)}")
    print(f"Total imported size: {manifest['summary']['total_bytes'] / (1024 * 1024):.2f} MiB")
    print(f"Failures: {len(failures)}")
    print(f"Manifest: {manifest_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
