#!/usr/bin/env python3
"""Reconstruct Minecraft Java sound assets from installed hashed object stores."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable


AUDIO_SUFFIXES = {".ogg", ".opus", ".wav", ".flac", ".mp3", ".m4a", ".aac"}
OGG_MAGIC = b"OggS"


@dataclass(frozen=True)
class Candidate:
    logical_path: str
    object_hash: str
    declared_size: int | None
    asset_root: Path
    index_path: Path
    index_mtime_ns: int

    @property
    def object_path(self) -> Path:
        return self.asset_root / "objects" / self.object_hash[:2] / self.object_hash


def default_asset_roots() -> list[Path]:
    home = Path.home()
    appdata = Path(os.environ.get("APPDATA", home / "AppData" / "Roaming"))
    candidates = [
        appdata / ".minecraft" / "assets",
        home / "curseforge" / "minecraft" / "Install" / "assets",
        appdata / "PrismLauncher" / "assets",
        appdata / "MultiMC" / "assets",
        appdata / "ModrinthApp" / "meta" / "assets",
    ]
    return unique_existing_asset_roots(candidates)


def unique_existing_asset_roots(paths: Iterable[Path]) -> list[Path]:
    roots: list[Path] = []
    seen: set[str] = set()
    for raw_path in paths:
        path = raw_path.expanduser().resolve()
        key = os.path.normcase(str(path))
        if key in seen:
            continue
        if (path / "indexes").is_dir() and (path / "objects").is_dir():
            roots.append(path)
            seen.add(key)
    return roots


def safe_logical_path(value: str) -> PurePosixPath:
    logical = PurePosixPath(value)
    if logical.is_absolute() or not logical.parts or ".." in logical.parts:
        raise ValueError(f"Unsafe asset path in index: {value!r}")
    if any(part in {"", "."} for part in logical.parts):
        raise ValueError(f"Invalid asset path in index: {value!r}")
    return logical


def is_audio_path(logical_path: str) -> bool:
    logical = safe_logical_path(logical_path)
    return logical.suffix.lower() in AUDIO_SUFFIXES and "sounds" in logical.parts


def read_candidates(asset_roots: list[Path]) -> tuple[dict[str, list[Candidate]], list[dict]]:
    candidates: dict[str, list[Candidate]] = {}
    index_records: list[dict] = []

    for asset_root in asset_roots:
        for index_path in sorted((asset_root / "indexes").glob("*.json")):
            try:
                payload = json.loads(index_path.read_text(encoding="utf-8"))
                objects = payload.get("objects", {})
                if not isinstance(objects, dict):
                    raise ValueError("top-level 'objects' value is not an object")
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
                index_records.append(
                    {"path": str(index_path), "status": "unreadable", "error": str(exc)}
                )
                continue

            matched = 0
            stat = index_path.stat()
            for logical_path, metadata in objects.items():
                if logical_path != "minecraft/sounds.json" and not is_audio_path(logical_path):
                    continue
                if not isinstance(metadata, dict):
                    continue
                object_hash = metadata.get("hash")
                if not isinstance(object_hash, str) or len(object_hash) != 40:
                    continue
                declared_size = metadata.get("size")
                if not isinstance(declared_size, int):
                    declared_size = None
                candidate = Candidate(
                    logical_path=logical_path,
                    object_hash=object_hash.lower(),
                    declared_size=declared_size,
                    asset_root=asset_root,
                    index_path=index_path,
                    index_mtime_ns=stat.st_mtime_ns,
                )
                candidates.setdefault(logical_path, []).append(candidate)
                matched += 1

            index_records.append(
                {
                    "path": str(index_path),
                    "status": "read",
                    "matching_entries": matched,
                    "modified_utc": datetime.fromtimestamp(
                        stat.st_mtime, tz=timezone.utc
                    ).isoformat(),
                }
            )

    for choices in candidates.values():
        choices.sort(key=lambda item: item.index_mtime_ns, reverse=True)
    return candidates, index_records


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_ogg(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(4) == OGG_MAGIC
    except OSError:
        return False


def select_candidate(choices: list[Candidate]) -> tuple[Candidate | None, list[str]]:
    errors: list[str] = []
    checked_hashes: set[tuple[str, str]] = set()
    for candidate in choices:
        identity = (str(candidate.asset_root), candidate.object_hash)
        if identity in checked_hashes:
            continue
        checked_hashes.add(identity)
        source = candidate.object_path
        if not source.is_file():
            errors.append(f"missing: {source}")
            continue
        if candidate.declared_size is not None and source.stat().st_size != candidate.declared_size:
            errors.append(f"size mismatch: {source}")
            continue
        actual_hash = sha1_file(source)
        if actual_hash.lower() != candidate.object_hash:
            errors.append(f"SHA-1 mismatch: {source}")
            continue
        return candidate, errors
    return None, errors


def target_path_for(logical_path: str, target_assets: Path) -> Path:
    logical = safe_logical_path(logical_path)
    if logical_path == "minecraft/sounds.json":
        relative = logical
    elif logical.suffix.lower() == ".ogg":
        relative = logical
    else:
        relative = logical.with_suffix(".ogg")
    return target_assets.joinpath(*relative.parts)


def copy_or_convert(source: Path, target: Path, ffmpeg: str | None) -> str:
    target.parent.mkdir(parents=True, exist_ok=True)

    if target.suffix.lower() == ".json":
        temporary = target.with_name(target.name + ".tmp")
        shutil.copyfile(source, temporary)
        temporary.replace(target)
        return "copied_metadata"

    if is_ogg(source):
        temporary = target.with_name(target.name + ".tmp")
        shutil.copyfile(source, temporary)
        temporary.replace(target)
        return "copied_ogg"

    if ffmpeg is None:
        raise RuntimeError(
            "source is not an Ogg stream and FFmpeg was not found; install FFmpeg or pass --ffmpeg"
        )

    with tempfile.NamedTemporaryFile(
        dir=target.parent, prefix=target.stem + "-", suffix=".ogg", delete=False
    ) as temporary_file:
        temporary = Path(temporary_file.name)
    try:
        subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
             "-c:a", "libvorbis", "-q:a", "6", str(temporary)],
            check=True,
        )
        if not is_ogg(temporary):
            raise RuntimeError("FFmpeg did not produce a valid Ogg stream")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return "converted_to_ogg"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--asset-root",
        action="append",
        type=Path,
        default=[],
        help="Minecraft assets directory containing indexes/ and objects/ (repeatable)",
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
        default=Path("docs/minecraft-sound-extraction-manifest.json"),
        help="audit manifest path",
    )
    parser.add_argument("--ffmpeg", help="path or command name for FFmpeg")
    parser.add_argument("--dry-run", action="store_true", help="index and verify without copying")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    requested_roots = args.asset_root or default_asset_roots()
    asset_roots = unique_existing_asset_roots(requested_roots)
    if not asset_roots:
        print("No Minecraft asset roots with indexes/ and objects/ were found.", file=sys.stderr)
        return 2

    target_assets = args.target_assets.resolve()
    manifest_path = args.manifest.resolve()
    ffmpeg = args.ffmpeg or shutil.which("ffmpeg")
    all_candidates, index_records = read_candidates(asset_roots)

    results: list[dict] = []
    failures = 0
    copied_ogg = 0
    converted = 0
    copied_metadata = 0
    destination_sound_files = 0
    path_collisions = 0
    claimed_targets: dict[str, str] = {}

    # Newer indexes claim a case-insensitive Windows destination first. Historical
    # indexes contain a few paths that differ only by capitalization, which cannot
    # coexist on NTFS even though both names are distinct on a case-sensitive FS.
    ordered_paths = sorted(
        all_candidates,
        key=lambda path: (-all_candidates[path][0].index_mtime_ns, path),
    )
    for logical_path in ordered_paths:
        choices = all_candidates[logical_path]
        hashes = list(dict.fromkeys(choice.object_hash for choice in choices))
        selected, selection_errors = select_candidate(choices)
        record = {
            "logical_path": logical_path,
            "candidate_hashes_newest_first": hashes,
            "had_version_conflict": len(hashes) > 1,
        }
        if selected is None:
            failures += 1
            record.update({"status": "failed", "errors": selection_errors})
            results.append(record)
            continue

        target = target_path_for(logical_path, target_assets)
        target_key = os.path.normcase(str(target))
        record.update(
            {
                "selected_hash": selected.object_hash,
                "selected_index": str(selected.index_path),
                "source_object": str(selected.object_path),
                "target": str(target),
            }
        )
        if selection_errors:
            record["fallback_reasons"] = selection_errors

        if target_key in claimed_targets:
            path_collisions += 1
            record.update(
                {
                    "status": "skipped_windows_path_collision",
                    "conflicts_with": claimed_targets[target_key],
                }
            )
            results.append(record)
            continue
        claimed_targets[target_key] = logical_path

        try:
            action = "verified_dry_run" if args.dry_run else copy_or_convert(
                selected.object_path, target, ffmpeg
            )
            record["status"] = action
            if logical_path != "minecraft/sounds.json":
                destination_sound_files += 1
            if action == "copied_ogg":
                copied_ogg += 1
            elif action == "converted_to_ogg":
                converted += 1
            elif action == "copied_metadata":
                copied_metadata += 1
        except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
            failures += 1
            record.update({"status": "failed", "errors": [str(exc)]})
        results.append(record)

    manifest = {
        "generated_utc": datetime.now(tz=timezone.utc).isoformat(),
        "asset_roots": [str(path) for path in asset_roots],
        "target_assets": str(target_assets),
        "ffmpeg": ffmpeg,
        "dry_run": args.dry_run,
        "summary": {
            "indexed_logical_sound_entries": sum(
                1 for path in all_candidates if path != "minecraft/sounds.json"
            ),
            "destination_sound_files": destination_sound_files,
            "copied_ogg_without_reencoding": copied_ogg,
            "converted_to_ogg": converted,
            "metadata_files_copied": copied_metadata,
            "windows_path_collisions_skipped": path_collisions,
            "version_conflicts": sum(
                1 for record in results if record["had_version_conflict"]
            ),
            "failures": failures,
        },
        "indexes": index_records,
        "files": results,
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Asset roots: {len(asset_roots)}")
    print(f"Indexes examined: {len(index_records)}")
    print(
        "Indexed logical sound entries: "
        f"{manifest['summary']['indexed_logical_sound_entries']}"
    )
    print(f"Destination sound files: {destination_sound_files}")
    print(f"Ogg files copied without re-encoding: {copied_ogg}")
    print(f"Files converted to Ogg: {converted}")
    print(f"Metadata files copied: {copied_metadata}")
    print(f"Windows path collisions skipped: {path_collisions}")
    print(f"Version conflicts resolved: {manifest['summary']['version_conflicts']}")
    print(f"Failures: {failures}")
    print(f"Manifest: {manifest_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
