#!/usr/bin/env bash
set -Eeuo pipefail

# Print Usage Information.
usage() {
    cat <<'EOF'
Usage:
  log_compactor.sh --dir DIRECTORY --part SIZE --max SIZE [--dry-run]

Examples:
  log_compactor.sh --dir /var/logs/bt --part 8 --max 20
  log_compactor.sh --dir /var/logs/bt --part 8MiB --max 20MiB --dry-run

Size Rules:
  - A Bare Number Means MiB.
  - Supported Suffixes: B, KiB, MiB, GiB, KB, MB, GB, K, M, G.

Grouping Rules:
  - Every Directory Is Processed Independently.
  - app.log, app-001.log, app-002.log In The Same Directory Form One Group.
  - Files With The Same Name In Different Directories Never Mix.
EOF
}

ROOT_DIR=""
PART_SIZE=""
MAX_SIZE=""
DRY_RUN=0

# Parse Command-Line Arguments.
while (($# > 0)); do
    case "$1" in
        --dir)
            ROOT_DIR="${2:-}"
            shift 2
            ;;
        --part)
            PART_SIZE="${2:-}"
            shift 2
            ;;
        --max)
            MAX_SIZE="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown Argument: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Validate Required Arguments.
if [[ -z "$ROOT_DIR" || -z "$PART_SIZE" || -z "$MAX_SIZE" ]]; then
    usage >&2
    exit 2
fi

if [[ ! -d "$ROOT_DIR" ]]; then
    printf 'Directory Does Not Exist: %s\n' "$ROOT_DIR" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 Is Required.\n' >&2
    exit 1
fi

ROOT_DIR="$(realpath -- "$ROOT_DIR")"

# Run The Line-Safe Compaction Engine.
exec python3 - "$ROOT_DIR" "$PART_SIZE" "$MAX_SIZE" "$DRY_RUN" <<'PYTHON'
import collections
import fcntl
import hashlib
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path


ROOT_DIR = Path(sys.argv[1])
PART_BYTES_TEXT = sys.argv[2]
MAX_BYTES_TEXT = sys.argv[3]
DRY_RUN = sys.argv[4] == "1"
WRITE_CHUNK_SIZE = 1024 * 1024
ARCHIVE_PATTERN = re.compile(r"^(?P<base>.+)-(?P<number>\d{3,})\.log$")


def parse_size(value: str) -> int:
    """Convert A Human-Readable Size To Bytes."""
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([A-Za-z]*)\s*", value)
    if not match:
        raise ValueError(f"Invalid Size: {value}")

    number = float(match.group(1))
    suffix = match.group(2).upper()
    multipliers = {
        "": 1024**2,
        "B": 1,
        "K": 1024,
        "KB": 1000,
        "KIB": 1024,
        "M": 1024**2,
        "MB": 1000**2,
        "MIB": 1024**2,
        "G": 1024**3,
        "GB": 1000**3,
        "GIB": 1024**3,
    }
    if suffix not in multipliers:
        raise ValueError(f"Unsupported Size Suffix: {suffix}")

    result = int(number * multipliers[suffix])
    if result <= 0:
        raise ValueError("Size Must Be Greater Than Zero")
    return result


def human_size(size: int) -> str:
    """Format Bytes As A Compact Binary Size."""
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.2f} {unit}"
        value /= 1024
    return f"{size} B"


def iter_bounded_lines(path: Path, limit: int | None = None):
    """Yield Complete Or Final Partial Lines Without Reading Past A Snapshot."""
    with path.open("rb", buffering=0) as file_obj:
        remaining = limit
        while remaining is None or remaining > 0:
            line = file_obj.readline() if remaining is None else file_obj.readline(remaining)
            if not line:
                break
            if remaining is not None:
                remaining -= len(line)
            yield line


def collect_groups(directory: Path):
    """Collect Active Logs And Their Numbered Archives Inside One Directory."""
    files = [
        item
        for item in directory.iterdir()
        if item.is_file() and not item.is_symlink() and item.name.endswith(".log")
    ]
    names = {item.name for item in files}
    archives_by_active: dict[str, list[tuple[int, Path]]] = collections.defaultdict(list)

    for item in files:
        match = ARCHIVE_PATTERN.match(item.name)
        if not match:
            continue
        active_name = f"{match.group('base')}.log"
        if active_name in names:
            archives_by_active[active_name].append((int(match.group("number")), item))

    groups = []
    for item in sorted(files, key=lambda path: path.name):
        match = ARCHIVE_PATTERN.match(item.name)
        if match and f"{match.group('base')}.log" in names:
            continue
        archives = sorted(archives_by_active.get(item.name, []), key=lambda pair: pair[0])
        groups.append((item, [path for _, path in archives]))

    return groups


def load_retained_lines(files: list[Path], active: Path, active_size: int, max_bytes: int):
    """Keep The Newest Whole Lines Up To The Maximum Size."""
    retained: collections.deque[bytes] = collections.deque()
    retained_size = 0
    scanned_size = 0

    for path in files:
        limit = active_size if path == active else None
        for line in iter_bounded_lines(path, limit):
            scanned_size += len(line)
            retained.append(line)
            retained_size += len(line)

            while retained_size > max_bytes and len(retained) > 1:
                retained_size -= len(retained.popleft())

    return retained, retained_size, scanned_size


def split_lines(retained: collections.deque[bytes], retained_size: int, part_bytes: int):
    """Split Lines Into Archives While Reserving The Final Chunk For The Active Log."""
    chunks: list[bytes] = []
    current = bytearray()
    remaining = retained_size

    for line in retained:
        current.extend(line)
        remaining -= len(line)

        if len(current) >= part_bytes and remaining > 0:
            chunks.append(bytes(current))
            current.clear()

    chunks.append(bytes(current))
    return chunks


def apply_metadata(source: Path, target: Path):
    """Copy Basic Ownership And Permission Metadata."""
    source_stat = source.stat(follow_symlinks=False)
    os.chmod(target, stat.S_IMODE(source_stat.st_mode), follow_symlinks=False)
    try:
        os.chown(target, source_stat.st_uid, source_stat.st_gid, follow_symlinks=False)
    except PermissionError:
        pass
    try:
        shutil.copystat(source, target, follow_symlinks=False)
    except OSError:
        pass


def write_temp_file(directory: Path, base_name: str, content: bytes, metadata_source: Path) -> Path:
    """Write And Sync A Temporary Archive File."""
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{base_name}.compact.", dir=directory)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(descriptor, "wb", buffering=0) as file_obj:
            offset = 0
            while offset < len(content):
                count = file_obj.write(content[offset:])
                if count is None or count <= 0:
                    raise OSError("Could Not Write Temporary Archive")
                offset += count
            file_obj.flush()
            os.fsync(file_obj.fileno())
        apply_metadata(metadata_source, temp_path)
        return temp_path
    except Exception:
        try:
            temp_path.unlink(missing_ok=True)
        finally:
            raise


def rewrite_active_in_place(active: Path, content: bytes, expected_identity: tuple[int, int]):
    """Rewrite The Active Log While Preserving Its Path And Inode."""
    descriptor = os.open(active, os.O_RDWR)
    try:
        current_stat = os.fstat(descriptor)
        current_identity = (current_stat.st_dev, current_stat.st_ino)
        if current_identity != expected_identity:
            raise RuntimeError("Active Log Inode Changed During Processing")

        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.ftruncate(descriptor, len(content))

        end = len(content)
        while end > 0:
            start = max(0, end - WRITE_CHUNK_SIZE)
            block = content[start:end]
            written = 0
            while written < len(block):
                count = os.pwrite(descriptor, block[written:], start + written)
                if count <= 0:
                    raise OSError("Could Not Rewrite Active Log")
                written += count
            end = start

        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def process_group(active: Path, archives: list[Path], part_bytes: int, max_bytes: int):
    """Compact One Directory-Local Log Group."""
    lock_hash = hashlib.sha256(active.name.encode("utf-8")).hexdigest()[:16]
    lock_path = active.parent / f".log-compactor-{lock_hash}.lock"

    with lock_path.open("a+b") as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"SKIP  {active}: Group Is Already Locked")
            return

        active_stat = active.stat(follow_symlinks=False)
        active_identity = (active_stat.st_dev, active_stat.st_ino)
        active_size = active_stat.st_size
        source_files = archives + [active]

        # Retry A Few Times When The Active Log Is Growing Rapidly.
        for _ in range(3):
            retained, retained_size, scanned_size = load_retained_lines(
                source_files,
                active,
                active_size,
                max_bytes,
            )
            latest_stat = active.stat(follow_symlinks=False)
            latest_identity = (latest_stat.st_dev, latest_stat.st_ino)
            if latest_identity != active_identity:
                raise RuntimeError(f"Active Log Changed: {active}")
            if latest_stat.st_size == active_size:
                break
            active_size = latest_stat.st_size
        else:
            retained, retained_size, scanned_size = load_retained_lines(
                source_files,
                active,
                active_size,
                max_bytes,
            )

        chunks = split_lines(retained, retained_size, part_bytes)
        archive_chunks = chunks[:-1]
        active_chunk = chunks[-1]
        deleted_size = max(0, scanned_size - retained_size)

        planned_archives = [
            active.with_name(f"{active.stem}-{index:03d}.log")
            for index in range(1, len(archive_chunks) + 1)
        ]

        print(
            f"PLAN  {active.parent} :: {active.name} | "
            f"Input={human_size(scanned_size)} | "
            f"Keep={human_size(retained_size)} | "
            f"Delete={human_size(deleted_size)} | "
            f"Archives={len(archive_chunks)} | "
            f"Active={human_size(len(active_chunk))}"
        )

        if DRY_RUN:
            for path, content in zip(planned_archives, archive_chunks):
                print(f"      {path.name}: {human_size(len(content))}")
            print(f"      {active.name}: {human_size(len(active_chunk))}")
            return

        temp_archives: list[tuple[Path, Path]] = []
        try:
            for final_path, content in zip(planned_archives, archive_chunks):
                temp_path = write_temp_file(active.parent, active.stem, content, active)
                temp_archives.append((temp_path, final_path))

            # Publish New Archives Before Compacting The Active File.
            for temp_path, final_path in temp_archives:
                os.replace(temp_path, final_path)

            rewrite_active_in_place(active, active_chunk, active_identity)

            keep_names = {path.name for path in planned_archives}
            for old_archive in archives:
                if old_archive.name not in keep_names:
                    old_archive.unlink(missing_ok=True)

            directory_descriptor = os.open(active.parent, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)

            print(f"DONE  {active}")
        finally:
            for temp_path, _ in temp_archives:
                temp_path.unlink(missing_ok=True)


def main():
    """Process Every Directory Under The Requested Root."""
    try:
        part_bytes = parse_size(PART_BYTES_TEXT)
        max_bytes = parse_size(MAX_BYTES_TEXT)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    failures = 0
    for current_root, directory_names, _ in os.walk(ROOT_DIR, followlinks=False):
        directory_names[:] = [
            name
            for name in directory_names
            if not (Path(current_root) / name).is_symlink()
        ]
        directory = Path(current_root)
        try:
            groups = collect_groups(directory)
        except (OSError, PermissionError) as error:
            print(f"ERROR {directory}: {error}", file=sys.stderr)
            failures += 1
            continue

        for active, archives in groups:
            try:
                process_group(active, archives, part_bytes, max_bytes)
            except Exception as error:
                print(f"ERROR {active}: {error}", file=sys.stderr)
                failures += 1

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
PYTHON
