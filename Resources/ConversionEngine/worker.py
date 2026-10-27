#!/usr/bin/env python3
"""
MP4Assistant Companion Worker
Runs inside isolated container to process video conversion requests.
No Docker socket, no public ports, fail-closed UID security check.
"""

import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid
from fractions import Fraction
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

WORKER_VERSION = "0.4.0"
# True only when engine_cli.py pre-seeds it into this module's namespace before running it: the encode/verify code is then
# used as a one-job library (no queue, shares or request-UID environment). Never derived from the environment.
ENGINE_MODE = bool(globals().get("ENGINE_MODE", False))
FFMPEG = "ffmpeg"    # engine_cli.py replaces both with absolute trusted paths; the NAS queue worker keeps PATH lookup
FFPROBE = "ffprobe"
NAS_BASE = "/nas"  # every allowed share is bind-mounted individually as /nas/<share>
QUEUE_DIR = "/queue"
STATUS_FILE = os.path.join(QUEUE_DIR, "status.json")
STATE_FILE = os.path.join(QUEUE_DIR, "state.json")
LOCK_FILE = os.path.join(QUEUE_DIR, ".worker.lock")
RECOVERY_NAME = ".mp4-originals"  # retired 0.2.x archive folder: still never scanned or written
BACKUP_SUFFIX = "_원본"  # originals are only ever renamed STEM -> STEM_원본 (same folder, same extension), never deleted
DVD_NAV_NOTE = "DVD 탐색(메뉴·챕터 이동용 내비게이션) 데이터는 MP4에 담을 수 없어 포함되지 않았습니다. 해당 정보가 필요하면 보존된 _원본 파일을 사용하세요"
POLICY = "keep-original-suffix-v1"  # scan manifest and start request must both carry exactly this

UUID_REGEX = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
REQ_FILENAME_REGEX = re.compile(r"^(scan|start|stop)-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.req\.json$")

LEGACY_EXTENSIONS = {
    ".avi", ".mkv", ".wmv", ".vob", ".mpg", ".mpeg",
    ".asf", ".mov", ".flv", ".mts", ".m2ts", ".ts",
    ".3gp", ".webm", ".rm", ".rmvb", ".divx", ".m4v"
}

MAX_SCAN_FILES = 20000  # aggregate across ALL selected folders
MAX_FOLDERS = 30
MAX_PATH_LEN = 512
MAX_ERRORS_LISTED = 200
MANIFEST_SCHEMA = 3
MAX_MP4_PROBES = 20000  # existing MP4s probed per scan (same cap as MAX_SCAN_FILES)
PROBE_TIMEOUT = 60  # ffprobe of one file during conversion
SCAN_PROBE_TIMEOUT = 20  # ffprobe of one existing MP4 while scanning
MAX_PROBE_OUTPUT = 4 * 1024 * 1024
MAX_NAME_BYTES = 255
START_KEYS = {"action", "uuid", "scan_uuid", "batch_id", "policy", "mp4_check", "folders"}
RESERVED_SHARES = {"docker", "home"}  # service folder / DSM alias: never browsable by this engine
MAX_REQ_SIZE = 65536  # 64 KB limit for JSON request files
MAX_JSON_SIZE = 64 * 1024 * 1024  # 64 MB limit for scan/state JSON files
MAX_STATUS_DETAILS = 200
CLOCK_JUMP_SECONDS = 65.536  # 2^16 ms: the exact audio clock offset seen in damaged Matroska audio blocks
CLOCK_STEP_TOLERANCE = 0.005  # a packet may start this far from the previous packet's end and still be "continuous"
TIMELINE_TIMEOUT = 900  # ffprobe packet listing of one file (only run after a conversion already failed on timing)
MAX_TIMELINE_BYTES = 128 * 1024 * 1024
PTS_DTS_SLACK = 0.001  # a recovered presentation time may not precede its own decoding time by more than this
PROGRESS_INTERVAL = 1.0  # seconds between status writes while ffmpeg reports -progress
PROGRESS_LINE_MAX = 256  # a longer line on ffmpeg's -progress pipe is never valid and is dropped
PROGRESS_US_DIGITS = 15  # out_time_us with more digits (> ~31 years) is treated as garbage
STDERR_TAIL_BYTES = 8192

# Global worker runtime state
worker_lock_fd: Optional[int] = None
active_batch_id: Optional[str] = None
stop_requested: bool = False
current_process: Optional[subprocess.Popen] = None
current_temp_file: Optional[str] = None
current_target_dir: Optional[str] = None
timeline_failure = ""  # why the LAST probe_packet_timeline returned None: "incomplete" (cancelled, time/size limit, ffprobe error) or "unsupported" (packet without usable pts that +genpts cannot restore, no packets)
poll_hook: Optional[Callable[[], None]] = None  # engine mode: runs in every cancel poll (~0.3 s) instead of the queue stop check
commit_active: bool = False  # rename transaction in progress: SIGTERM must wait for it instead of exiting midway
shutdown_requested: bool = False
# Exact (dev, inode) of every temp file this worker created; only these may be unlinked.
temp_identities: Dict[str, Tuple[int, int]] = {}


def get_allowed_uid() -> int:
    env_val = os.environ.get("ALLOWED_REQUEST_UID")
    if not env_val or not env_val.strip():
        sys.stderr.write("FATAL: ALLOWED_REQUEST_UID environment variable is required; failing closed.\n")
        sys.exit(1)
    try:
        val = int(env_val.strip())
        if val <= 0:
            sys.stderr.write(f"FATAL: ALLOWED_REQUEST_UID must be positive non-root ({val}); failing closed.\n")
            sys.exit(1)
        return val
    except ValueError:
        sys.stderr.write(f"FATAL: ALLOWED_REQUEST_UID '{env_val}' is not a valid integer; failing closed.\n")
        sys.exit(1)


ALLOWED_REQUEST_UID = os.geteuid() if ENGINE_MODE else get_allowed_uid()


def load_shares() -> Dict[str, str]:
    """Static allow-list from ALLOWED_SHARES, e.g. {"video": "/nas/video"}. Fails closed on any malformed entry."""
    try:
        data = json.loads(os.environ.get("ALLOWED_SHARES", ""))
    except ValueError:
        data = None
    if not isinstance(data, dict) or not data:
        sys.stderr.write("FATAL: ALLOWED_SHARES must be a non-empty JSON object {share: /nas/share}; failing closed.\n")
        sys.exit(1)
    shares: Dict[str, str] = {}
    for name, path in data.items():
        if (not isinstance(name, str) or not isinstance(path, str) or not name or len(name) > 100
                or "/" in name or name[0] in ".@#" or any(ord(c) < 32 or ord(c) == 127 for c in name)
                or name.casefold() in RESERVED_SHARES or path != f"{NAS_BASE}/{name}"):
            sys.stderr.write(f"FATAL: invalid ALLOWED_SHARES entry {name!r}; failing closed.\n")
            sys.exit(1)
        shares[name] = path
    return shares


def find_connected_shares(shares: Dict[str, str]) -> List[str]:
    """A share is connected only if its /nas/<share> path is a real directory AND an actual mount point."""
    mounts = set()
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                fields = line.split(" ")
                if len(fields) > 4:
                    mounts.add(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), fields[4]))
    except OSError as e:
        sys.stderr.write(f"Cannot read mountinfo; no share will be treated as connected: {e}\n")
    connected = []
    for name, path in sorted(shares.items()):
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode) and path in mounts:
            connected.append(name)
    return connected


SHARES = {} if ENGINE_MODE else load_shares()
CONNECTED_SHARES = [] if ENGINE_MODE else find_connected_shares(SHARES)


def init_queue_dir() -> None:
    """Verifies queue directory ownership, removes symlinks, and sets mode 0700."""
    os.makedirs(QUEUE_DIR, exist_ok=True)
    try:
        st = os.lstat(QUEUE_DIR)
        if stat.S_ISLNK(st.st_mode):
            sys.stderr.write("FATAL: Queue directory is a symlink; failing closed.\n")
            sys.exit(1)
        if not stat.S_ISDIR(st.st_mode):
            sys.stderr.write("FATAL: Queue path is not a directory; failing closed.\n")
            sys.exit(1)
        if st.st_uid != ALLOWED_REQUEST_UID:
            sys.stderr.write(
                f"FATAL: Queue dir UID {st.st_uid} does not match verified UID {ALLOWED_REQUEST_UID}; failing closed.\n"
            )
            sys.exit(1)
        os.chmod(QUEUE_DIR, 0o700)
    except OSError as e:
        sys.stderr.write(f"FATAL: Error verifying queue directory: {e}\n")
        sys.exit(1)


def acquire_worker_lock() -> None:
    global worker_lock_fd
    try:
        open_flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        fd = os.open(LOCK_FILE, open_flags, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        worker_lock_fd = fd
    except (BlockingIOError, OSError) as e:
        sys.stderr.write(f"FATAL: Failed to acquire worker lock (another instance running?): {e}\n")
        sys.exit(1)


def atomic_write_json(filepath: str, data: Dict[str, Any]) -> None:
    """Atomic write using exclusive randomized temp, fsync file AND directory."""
    dirpath = os.path.dirname(filepath)
    rand_suffix = f".tmp.{os.getpid()}.{time.time_ns()}.{uuid.uuid4().hex[:8]}"
    temp_path = os.path.join(dirpath, rand_suffix)

    open_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(temp_path, open_flags, 0o600)
    try:
        payload = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        with os.fdopen(fd, "wb", closefd=False) as f:
            f.write(payload)
            f.flush()
        os.fsync(fd)
    finally:
        os.close(fd)

    # If destination exists as symlink, remove it before replace
    try:
        if os.path.islink(filepath):
            os.unlink(filepath)
    except OSError:
        pass

    os.replace(temp_path, filepath)

    # Fsync directory to commit metadata
    try:
        dir_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        dfd = os.open(dirpath, dir_flags)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def read_json_fd(fd: int, max_size: int = MAX_REQ_SIZE) -> Optional[Dict[str, Any]]:
    """Reads a bounded JSON object from fd. Does NOT close fd; the caller owns it."""
    try:
        with os.fdopen(fd, "rb", closefd=False) as f:
            raw = f.read(max_size + 1)
        if len(raw) > max_size:
            return None
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else None
    except Exception as e:
        sys.stderr.write(f"Error reading JSON from fd: {e}\n")
        return None


def read_json_file(filepath: str, max_size: int = MAX_REQ_SIZE) -> Optional[Dict[str, Any]]:
    """Opens with O_NOFOLLOW, checks regular file / UID / size on the SAME fd, always closes fd."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(filepath, flags)
    except OSError as e:
        sys.stderr.write(f"Cannot open {filepath} safely: {e}\n")
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != ALLOWED_REQUEST_UID or st.st_size > max_size:
            sys.stderr.write(f"Rejected {filepath}: not a regular file, wrong UID, or too large.\n")
            return None
        return read_json_fd(fd, max_size)
    except OSError:
        return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def update_status(
    state: str,
    stage: str,
    batch_id: Optional[str] = None,
    current_file: str = "",
    progress_pct: int = 0,
    total: int = 0,
    completed: int = 0,
    failed: int = 0,
    skipped: int = 0,
    cleanup_pending: int = 0,
    error: Optional[str] = None,
    details: Optional[List[Dict[str, Any]]] = None,
    current_folder: str = "",
    folder_index: int = 0,
    folder_total: int = 0,
    phase: str = "",
    phase_label: str = "",
    phase_pos_s: Optional[float] = None,
    phase_total_s: Optional[float] = None
) -> None:
    """progress_pct/total/completed/... are AGGREGATE file counts of the batch. phase* describe only the CURRENT file's
    current step: phase_pct is null (indeterminate) unless ffmpeg really reported a position inside a known duration."""
    phase_pct: Optional[float] = None
    if phase_pos_s is not None and phase_total_s and phase_total_s > 0:
        phase_pct = round(min(max(phase_pos_s / phase_total_s, 0.0), 1.0) * 100, 1)
    status_payload = {
        "worker_version": WORKER_VERSION,
        "shares": CONNECTED_SHARES,
        "state": state,
        "batch_id": batch_id,
        "stage": safe_text(stage, 600),
        "current_folder": safe_text(current_folder),
        "folder_index": folder_index,
        "folder_total": folder_total,
        "current_file": safe_text(current_file),
        "progress_pct": progress_pct,
        "total": total,
        "completed": completed,
        "failed": failed,
        "skipped": skipped,
        "cleanup_pending": cleanup_pending,
        "phase": phase,
        "phase_label": safe_text(phase_label, 200),
        "phase_pct": phase_pct,
        "phase_pos_s": round(phase_pos_s, 1) if phase_pct is not None else None,
        "phase_total_s": round(phase_total_s, 1) if phase_pct is not None else None,
        "error": safe_text(error, 600) if error else error,
        # Display-safe text only: never raw NAS container paths or undecodable bytes
        "details": [{**d, "file": safe_text(str(d.get("file", ""))), "message": safe_text(str(d.get("message", "")), 600)}
                    for d in (details or [])[-MAX_STATUS_DETAILS:]],
        "updated_at": int(time.time())
    }
    atomic_write_json(STATUS_FILE, status_payload)
    atomic_write_json(STATE_FILE, status_payload)


def safe_text(text: str, limit: int = 500) -> str:
    """Makes any string JSON/UTF-8 safe (undecodable filename bytes become '?') and shows share-relative paths."""
    return text.replace(NAS_BASE + "/", "/").encode("utf-8", "replace").decode("utf-8")[:limit]


def container_to_display(container_path: str) -> str:
    """/nas/video/a/b -> /video/a/b (the FileStation-style path shown in the UI and stored in manifests)."""
    return container_path[len(NAS_BASE):]


def display_to_container(display: str) -> Tuple[str, str]:
    """Explicit mapping of '/share/sub' to ('share', '/nas/share/sub'). Unknown shares are an error: no fallback."""
    if not isinstance(display, str) or not display.startswith("/") or len(display) > MAX_PATH_LEN:
        raise ValueError("폴더 경로 형식이 올바르지 않습니다.")
    if any(ord(c) < 32 or ord(c) == 127 for c in display):
        raise ValueError("폴더 경로에 사용할 수 없는 문자가 있습니다.")
    try:
        display.encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("폴더 경로를 UTF-8로 표현할 수 없습니다.")
    parts = display.split("/")[1:]
    if any(p in ("", ".", "..") for p in parts):
        raise ValueError(f"올바르지 않은 경로입니다: {display}")
    share = parts[0]
    if share not in CONNECTED_SHARES:
        raise ValueError(f"연결되지 않았거나 허용되지 않은 공유 폴더입니다: /{share}")
    return share, SHARES[share] + "".join("/" + p for p in parts[1:])


def share_root_for(path_str: str) -> str:
    """Returns /nas/<share> for any container path inside a connected share; raises otherwise."""
    parts = os.path.normpath(path_str).split("/")
    if len(parts) < 3 or parts[0] != "" or "/" + parts[1] != NAS_BASE or parts[2] not in CONNECTED_SHARES:
        raise ValueError(f"연결된 공유 폴더 범위를 벗어났습니다: {safe_text(path_str)}")
    return SHARES[parts[2]]


def validate_path_components_pre_realpath(path_str: str) -> None:
    """Validates each path component BEFORE realpath to prevent symlink traversal."""
    norm = os.path.normpath(path_str)
    root = share_root_for(norm)
    if norm != root and not norm.startswith(root + "/"):
        raise ValueError(f"경로가 {root} 경계를 벗어났습니다: {safe_text(path_str)}")

    # Walk from the share root down component by component
    accum = root
    for part in [p for p in norm[len(root):].split("/") if p]:
        accum += "/" + part
        try:
            st = os.lstat(accum)
            if stat.S_ISLNK(st.st_mode):
                raise ValueError(f"보안상 심볼릭 링크 경로는 허용되지 않습니다: {safe_text(accum)}")
        except FileNotFoundError:
            # Target path does not exist yet
            pass
        if part.startswith(".") or part.startswith("@") or part == "#recycle" or part == RECOVERY_NAME:
            raise ValueError(f"금지된 시스템 또는 특수 폴더 경로입니다: {safe_text(part)}")


def fsync_dir(dirpath: str) -> None:
    """Fsyncs a directory; raises on failure."""
    dfd = os.open(dirpath, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def revalidate_source_parent(cand_path: str, validated_target: str) -> None:
    """Re-checks (before publish/rename) that source path has no symlink components and still resolves inside the scanned folder."""
    validate_path_components_pre_realpath(cand_path)
    parent = os.path.dirname(cand_path)
    real_parent = os.path.realpath(parent)
    if real_parent != parent or (real_parent != validated_target and not real_parent.startswith(validated_target + os.sep)):
        raise RuntimeError("원본 폴더 경로가 변경되었거나 대상 폴더 범위를 벗어났습니다")


def resolve_folder(display: str) -> Tuple[str, str, os.stat_result]:
    """Strictly validates one selected folder (display path) inside a connected share without following symlinks.
    Returns (share, container_path, lstat)."""
    share, cpath = display_to_container(display)
    validate_path_components_pre_realpath(cpath)
    if os.path.realpath(cpath) != cpath:
        raise ValueError(f"심볼릭 링크를 통과하거나 경로가 변경되었습니다: {display}")
    st = os.lstat(cpath)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise ValueError(f"유효한 디렉토리가 아닙니다: {display}")
    return share, cpath, st


def folder_list_conflicts(folders: List[str]) -> Optional[str]:
    """Selected folders must be independent: no duplicate or ancestor/descendant pair (compared case-insensitively)."""
    keys = [tuple(p.casefold() for p in f.split("/")[1:]) for f in folders]
    for i, a in enumerate(keys):
        for j, b in enumerate(keys):
            if i != j and a[:len(b)] == b:
                return f"선택한 폴더가 중복되거나 서로 포함 관계입니다: {folders[i]} ⊂ {folders[j]}"
    return None


def name_key(name: str) -> str:
    """Collision key: Unicode-normalised (NFC) and case-folded, so case variants and NFC/NFD twins collide."""
    return unicodedata.normalize("NFC", name).casefold()


def is_backup_stem(stem: str) -> bool:
    """True for names that already carry the _원본 suffix: they are earlier backups and are never converted."""
    return name_key(stem).endswith(name_key(BACKUP_SUFFIX))


def index_names(names: List[str]) -> Dict[str, List[str]]:
    index: Dict[str, List[str]] = {}
    for n in names:
        index.setdefault(name_key(n), []).append(n)
    return index


def list_dir_index(directory: str) -> Optional[Dict[str, List[str]]]:
    """Fresh name index of one folder; None (callers fail closed) when it cannot be listed."""
    try:
        return index_names(os.listdir(directory))
    except OSError as e:
        sys.stderr.write(f"Listing error in {directory} during collision check: {e}\n")
        return None


def name_conflicts(index: Dict[str, List[str]], names: List[str], self_name: Optional[str] = None) -> List[str]:
    """Existing entries that collide with any of names (case-insensitively). Only the exact self_name is exempt."""
    found: List[str] = []
    for n in names:
        found += [e for e in index.get(name_key(n), []) if e != self_name]
    return found


def output_names(cand_name: str, is_mp4: bool) -> Tuple[str, str]:
    """(result name, backup name). A legacy file STEM.ext yields STEM.mp4; an MP4 keeps its own name."""
    stem, ext = os.path.splitext(cand_name)
    return (cand_name if is_mp4 else stem + ".mp4"), f"{stem}{BACKUP_SUFFIX}{ext}"


def candidate_kind_ok(kind: Any, name: str) -> bool:
    ext = os.path.splitext(name)[1].lower()
    return (kind == "legacy" and ext in LEGACY_EXTENSIONS) or (kind == "mp4" and ext == ".mp4")


def same_inode(a: os.stat_result, b: os.stat_result) -> bool:
    return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)


def same_snapshot(a: os.stat_result, b: os.stat_result) -> bool:
    return same_inode(a, b) and (a.st_size, a.st_mtime_ns) == (b.st_size, b.st_mtime_ns)


def require_snapshot(path: str, ref: os.stat_result, what: str) -> None:
    """Raises unless path is still the regular file (same inode, size, mtime) captured in ref."""
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or not same_snapshot(st, ref):
        raise RuntimeError(f"{what}이(가) 처리 도중 바뀌었습니다")


def fsync_file(path: str) -> None:
    """Fsyncs a regular file by path (no symlink following); raises on failure."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def original_name_state(path: str, ref: os.stat_result) -> str:
    """What is at the original name right now: intact (the scanned file), missing, replaced or unknown."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "unknown"
    if stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) and same_snapshot(st, ref):
        return "intact"
    return "replaced"


def terminate_current_process() -> None:
    """Kills the tracked ffmpeg/ffprobe process group and WAITS for it to exit."""
    proc = current_process
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except OSError:
        pass
    try:
        proc.wait(timeout=3.0)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.wait(timeout=10.0)
        except subprocess.TimeoutExpired:
            pass


def read_progress(fd: int, partial: bytearray) -> Optional[float]:
    """Drains ffmpeg's non-blocking -progress pipe (bounded per call) and returns the newest valid out_time in seconds.
    Partial lines are carried in `partial` (capped); N/A, negative, non-numeric and oversized values are ignored."""
    latest: Optional[float] = None
    for _ in range(4):
        try:
            chunk = os.read(fd, 65536)
        except OSError:  # includes BlockingIOError: nothing to read right now
            break
        if not chunk:
            break
        *lines, rest = (bytes(partial) + chunk).split(b"\n")
        # an over-long unterminated line is poisoned with '#' so its remainder is dropped when it ends
        partial[:] = rest if len(rest) <= PROGRESS_LINE_MAX else b"#"
        for line in lines:
            if line.startswith(b"out_time_us="):
                value = line[len(b"out_time_us="):].strip()
                if value.isdigit() and len(value) <= PROGRESS_US_DIGITS:
                    latest = int(value) / 1e6
    return latest


def run_cancellable_ffmpeg(cmd: List[str], total_s: float = 0.0,
                           on_position: Optional[Callable[[float], None]] = None) -> Tuple[int, str]:
    """Runs ffmpeg process cancellably using poll loop and process group kill.
    Captures stderr via TemporaryFile to prevent pipe deadlock and unbounded memory.
    With on_position and a known total_s, cmd must contain '-progress pipe:1': the pipe is drained without blocking in
    the same poll loop and on_position(seconds, never decreasing, at most total_s) is called about once per second."""
    global current_process, stop_requested

    stderr_f = tempfile.TemporaryFile()
    track = on_position is not None and total_s > 0
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if track else subprocess.DEVNULL,
            stderr=stderr_f,
            start_new_session=True
        )
        current_process = proc
        partial, position, last_sent = bytearray(), 0.0, time.monotonic()
        if track:
            os.set_blocking(proc.stdout.fileno(), False)

        while proc.poll() is None:
            time.sleep(0.3)
            check_incoming_stop()
            if stop_requested:
                terminate_current_process()
                return -1, "작업 중지 요청됨"
            if track:
                seen = read_progress(proc.stdout.fileno(), partial)
                if seen is not None and seen > position:
                    position = min(seen, total_s)
                    if time.monotonic() - last_sent >= PROGRESS_INTERVAL:
                        last_sent = time.monotonic()
                        try:
                            on_position(position)
                        except Exception as ex:  # a status write problem must not abort the conversion
                            sys.stderr.write(f"progress status update failed: {ex}\n")

        # Only the tail is read, so a chatty stderr can never be loaded whole
        stderr_f.seek(0, os.SEEK_END)
        stderr_f.seek(max(0, stderr_f.tell() - STDERR_TAIL_BYTES))
        err_tail = stderr_f.read().decode("utf-8", "replace")[-2000:]
        return proc.returncode, err_tail
    except Exception as ex:
        return -1, f"프로세스 실행 예외: {ex}"
    finally:
        terminate_current_process()
        current_process = None
        try:
            stderr_f.close()
        except Exception:
            pass
        try:
            if proc.stdout:
                proc.stdout.close()
        except Exception:
            pass


def create_temp_file(temp_path: str) -> os.stat_result:
    """Exclusively creates the temp inode and records its exact identity for later cleanup."""
    open_flags = os.O_CREAT | os.O_EXCL | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    t_fd = os.open(temp_path, open_flags, 0o600)
    try:
        st = os.fstat(t_fd)
    finally:
        os.close(t_fd)
    temp_identities[os.path.normpath(temp_path)] = (st.st_dev, st.st_ino)
    return st


def safe_cleanup_temp_file(temp_path: Optional[str], target_dir: str) -> None:
    """Unlinks ONLY the exact inode (dev, ino) this worker created; never a replacement file."""
    if not temp_path:
        return
    try:
        norm_temp = os.path.normpath(temp_path)
        norm_target = os.path.normpath(target_dir)
        if not norm_temp.startswith(norm_target + os.sep):
            sys.stderr.write(f"Refusing to delete temp file outside target_dir: {temp_path}\n")
            return
        ident = temp_identities.pop(norm_temp, None)
        if ident is None:
            return
        bname = os.path.basename(norm_temp)
        if not (bname.startswith(".") and bname.endswith(".tmp.mp4")):
            sys.stderr.write(f"Refusing to delete non-temp format file: {temp_path}\n")
            return
        st = os.lstat(norm_temp)
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            sys.stderr.write(f"Refusing to delete non-regular or symlink temp file: {temp_path}\n")
            return
        if (st.st_dev, st.st_ino) != ident or st.st_uid != ALLOWED_REQUEST_UID:
            sys.stderr.write(f"Refusing to delete replaced temp file (identity mismatch): {temp_path}\n")
            return
        os.unlink(norm_temp)
    except OSError:
        pass


def handle_scan(req_path: str, req_data: Dict[str, Any], req_uid: int) -> None:
    """Scans ALL selected folders of one request as one batch snapshot and writes one manifest."""
    global active_batch_id, stop_requested

    uuid_str = req_data.get("uuid")
    if not uuid_str or not UUID_REGEX.match(uuid_str):
        sys.stderr.write("Scan request has invalid UUID.\n")
        return

    scan_result_path = os.path.join(QUEUE_DIR, f"scan-{uuid_str}.json")
    raw_folders = req_data.get("folders")
    mp4_check = req_data.get("mp4_check")  # opt-in compatibility check of existing MP4s; bound into the manifest
    folders: List[str] = []
    roots: List[Dict[str, Any]] = []   # manifest roots: display folder + share + (dev, inode) identity
    roots_c: List[str] = []            # container paths of the roots (never written to the manifest)
    errors: List[str] = []
    notes: List[str] = []              # existing MP4s that were neither healthy nor convertible (not errors)
    error_count = 0
    note_count = 0
    candidates: List[Dict[str, Any]] = []
    per_root: List[Dict[str, Any]] = []
    seen_paths = set()
    scanned_dirs = 0
    skipped_mp4 = 0        # legacy file whose result MP4 already exists
    skipped_conflict = 0   # result/_원본 name already taken (never overwritten)
    mp4_checked = 0
    healthy_mp4 = 0
    unsupported_mp4 = 0
    unverified_mp4 = 0
    truncated = False
    cancelled = False

    def add_error(msg: str) -> None:
        nonlocal error_count
        error_count += 1
        if len(errors) < MAX_ERRORS_LISTED:
            errors.append(safe_text(msg))

    def add_note(msg: str) -> None:
        nonlocal note_count
        note_count += 1
        if len(notes) < MAX_ERRORS_LISTED:
            notes.append(safe_text(msg, 300))

    def write_manifest() -> None:
        atomic_write_json(scan_result_path, {
            "uuid": uuid_str,
            "schema": MANIFEST_SCHEMA,
            "owner_uid": req_uid,
            "created_at": int(time.time()),
            "worker_version": WORKER_VERSION,
            "policy": POLICY,
            "mp4_check": mp4_check is True,
            "folders": folders,
            "roots": roots,
            "limits": {"max_files": MAX_SCAN_FILES, "max_folders": MAX_FOLDERS},
            "complete": error_count == 0 and not truncated and not cancelled,
            "truncated": truncated,
            "cancelled": cancelled,
            "counts": {
                "scanned_dirs": scanned_dirs,
                "candidates": len(candidates),
                "skipped_mp4": skipped_mp4,
                "skipped_conflict": skipped_conflict,
                "mp4_checked": mp4_checked,
                "healthy_mp4": healthy_mp4,
                "unsupported_mp4": unsupported_mp4,
                "unverified_mp4": unverified_mp4,
                "errors": error_count,
                "per_root": per_root
            },
            "errors": errors,
            "notes": notes,
            "note_count": note_count,
            "candidates": candidates
        })

    # --- request validation: no fallback of unknown/legacy requests into any share ---
    if (not isinstance(raw_folders, list) or not 1 <= len(raw_folders) <= MAX_FOLDERS
            or not all(isinstance(f, str) for f in raw_folders)
            or not isinstance(mp4_check, bool) or req_data.get("policy") != POLICY):
        add_error(f"선택한 폴더 목록, MP4 호환 검사 옵션 또는 처리 정책 버전이 없거나 올바르지 않습니다(폴더 최대 {MAX_FOLDERS}개). "
                  "이전 버전 요청 형식은 지원되지 않으니 앱을 새로 고침하고 다시 검사하십시오.")
        write_manifest()
        return
    folders = list(raw_folders)

    conflict = folder_list_conflicts(folders)
    if conflict:
        add_error(conflict)
    for folder in folders:
        try:
            share, cpath, st_root = resolve_folder(folder)
            roots.append({"folder": folder, "share": share, "dev": st_root.st_dev, "ino": st_root.st_ino})
            roots_c.append(cpath)
        except Exception as e:
            add_error(f"{folder}: {e}")
    if error_count:
        roots, roots_c = [], []
        write_manifest()
        return

    active_batch_id = uuid_str
    stop_requested = False
    last_tick = 0.0

    def tick(folder_idx: int, cur_dir: str) -> None:
        """Throttled cancel check + aggregate scan status (current folder / directory)."""
        nonlocal last_tick, cancelled
        now = time.time()
        if now - last_tick < 1.0:
            return
        last_tick = now
        check_incoming_stop()
        if stop_requested:
            cancelled = True
            return
        update_status(
            state="scanning",
            stage=f"폴더 검사 중 ({folder_idx + 1}/{len(roots)}) - 대상 {len(candidates)}개 발견"
                  + (f", 기존 MP4 {mp4_checked}개 확인" if mp4_check else ""),
            batch_id=uuid_str,
            current_folder=folders[folder_idx],
            current_file=container_to_display(cur_dir),
            total=len(candidates),
            skipped=skipped_mp4,
            folder_index=folder_idx + 1,
            folder_total=len(roots)
        )

    def on_walk_error(err: OSError) -> None:
        add_error(f"폴더를 읽을 수 없어 일부 항목이 누락되었습니다 ({getattr(err, 'filename', '')}): {err}")

    try:
        check_incoming_stop()  # a cancel uploaded before the scan began
        cancelled = stop_requested
        for ri, root_c in enumerate(roots_c):
            if cancelled or truncated:
                break
            per_root.append({"folder": folders[ri], "candidates": 0, "skipped_mp4": 0, "healthy_mp4": 0})
            for root, dirs, files in os.walk(root_c, topdown=True, followlinks=False, onerror=on_walk_error):
                tick(ri, root)
                if cancelled:
                    break
                dir_index = index_names(list(dirs) + list(files))  # every name in this folder, for collision checks
                dirs[:] = [d for d in dirs
                           if not os.path.islink(os.path.join(root, d))
                           and not (d.startswith(".") or d.startswith("@") or d == "#recycle" or d == RECOVERY_NAME)]
                scanned_dirs += 1

                for f in files:
                    tick(ri, root)
                    if cancelled:
                        break
                    if f.startswith(".") or f.startswith("@"):
                        continue  # hidden/system names, including this worker's own temp files

                    name_stem, ext = os.path.splitext(f)
                    is_mp4 = ext.lower() == ".mp4"
                    if is_mp4 and not mp4_check:
                        continue
                    if not is_mp4 and ext.lower() not in LEGACY_EXTENSIONS:
                        continue
                    if is_backup_stem(name_stem):
                        continue  # an earlier backup (STEM_원본.ext): never converted again

                    file_path = os.path.join(root, f)
                    if os.path.islink(file_path):
                        continue

                    try:
                        st = os.lstat(file_path)
                        if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
                            continue
                        display = container_to_display(file_path)
                        try:
                            display.encode("utf-8")
                        except UnicodeEncodeError:
                            add_error(f"파일 이름을 UTF-8로 표현할 수 없어 제외됨: {display}")
                            continue
                        # Source ownership is not restricted (NAS ACLs may grant access); a file that will be converted
                        # needs read access and write access to its folder (to publish and rename). Existing MP4s are
                        # only held to that once they turn out to need conversion (read-only healthy ones are fine).
                        def access_ok() -> bool:
                            if os.access(file_path, os.R_OK) and os.access(root, os.W_OK | os.X_OK):
                                return True
                            add_error(f"읽기 또는 폴더 쓰기 권한이 없어 제외됨: {display}")
                            return False

                        if not is_mp4 and not access_ok():
                            continue

                        final_name, backup_name = output_names(f, is_mp4)
                        reason = ""
                        if is_mp4:
                            if mp4_checked >= MAX_MP4_PROBES:
                                truncated = True
                                add_error(f"MP4 호환 검사 한도({MAX_MP4_PROBES}개)에 도달하여 검사를 중단했습니다. 선택 폴더를 줄여 나누어 검사하십시오.")
                                break
                            mp4_checked += 1
                            verdict, why = classify_mp4(file_path)
                            if stop_requested:
                                cancelled = True
                                break
                            if verdict == "healthy":
                                healthy_mp4 += 1
                                per_root[ri]["healthy_mp4"] += 1
                                continue
                            if verdict != "convert":
                                if verdict == "unsupported":
                                    unsupported_mp4 += 1
                                else:
                                    unverified_mp4 += 1
                                add_note(f"{display}: {'변환 불가' if verdict == 'unsupported' else '확인 불가'} - {why}")
                                continue
                            reason = safe_text(why, 160)
                            if not access_ok():
                                continue
                            if name_conflicts(dir_index, [final_name, backup_name], f):
                                skipped_conflict += 1
                                continue
                        elif name_conflicts(dir_index, [final_name]):
                            skipped_mp4 += 1
                            per_root[ri]["skipped_mp4"] += 1
                            continue
                        elif name_conflicts(dir_index, [backup_name]):
                            skipped_conflict += 1
                            continue

                        if file_path in seen_paths:
                            continue
                        if len(candidates) >= MAX_SCAN_FILES:
                            truncated = True
                            add_error(f"전체 최대 검사 파일 제한({MAX_SCAN_FILES}개)에 도달하여 검사를 중단했습니다. 선택 폴더를 줄여 나누어 검사하십시오.")
                            break

                        seen_paths.add(file_path)
                        per_root[ri]["candidates"] += 1
                        cand_entry = {
                            "path": display,
                            "filename": f,
                            "kind": "mp4" if is_mp4 else "legacy",
                            "size": st.st_size,
                            "mtime_ns": st.st_mtime_ns,
                            "inode": st.st_ino,
                            "dev": st.st_dev,
                            "root": ri
                        }
                        if reason:
                            cand_entry["reason"] = reason
                        candidates.append(cand_entry)
                    except OSError as ex:
                        add_error(f"파일 상태 확인 실패 ({file_path}): {ex}")

                if truncated or cancelled:
                    break
    except Exception as ex:
        add_error(f"검사 중 예기치 않은 오류: {ex}")
    finally:
        active_batch_id = None
        stop_requested = False

    write_manifest()
    if cancelled:
        stage = "검사가 취소되었습니다. (원본 파일은 변경되지 않았습니다)"
    else:
        stage = (f"대기 중 (검사 완료: 변환 대상 {len(candidates)}개, 이미 MP4 존재 {skipped_mp4}개, 이름 충돌 {skipped_conflict}개"
                 + (f", 호환 MP4 {healthy_mp4}개 건너뜀, 변환 불가 {unsupported_mp4}개, 확인 불가 {unverified_mp4}개" if mp4_check else "")
                 + f", 오류 {error_count}건)")
    update_status(state="idle", stage=stage, batch_id=None)
    print(f"Scan {uuid_str} finished: {len(candidates)} candidates in {len(roots)} folders, "
          f"{skipped_mp4} skipped existing mp4, {skipped_conflict} name conflicts, {healthy_mp4} healthy mp4, "
          f"{error_count} errors, cancelled={cancelled}.")


def probe_file(filepath: str, timeout: int = PROBE_TIMEOUT) -> Optional[Dict[str, Any]]:
    """ffprobe as a tracked process: bounded by timeout and stopped promptly by a cancel request."""
    global current_process
    cmd = [
        FFPROBE, "-v", "error",
        "-show_entries", "format=format_name,duration:stream=index,codec_name,codec_tag_string,profile,level,codec_type,width,height,avg_frame_rate,r_frame_rate,time_base,sample_aspect_ratio,display_aspect_ratio,sample_rate,channels,color_space,color_transfer,color_primaries,pix_fmt,bits_per_raw_sample",
        "-of", "json",
        filepath
    ]
    out_f = tempfile.TemporaryFile()
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out_f, stderr=subprocess.DEVNULL, start_new_session=True)
        current_process = proc
        deadline = time.monotonic() + timeout
        while True:
            try:
                proc.wait(timeout=0.25)
                break
            except subprocess.TimeoutExpired:
                pass
            check_incoming_stop()
            if stop_requested or time.monotonic() > deadline:
                terminate_current_process()
                return None
        if proc.returncode != 0:
            return None
        out_f.seek(0)
        raw = out_f.read(MAX_PROBE_OUTPUT + 1)
        if len(raw) > MAX_PROBE_OUTPUT:
            return None
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else None
    except Exception as e:
        sys.stderr.write(f"ffprobe error on {filepath}: {e}\n")
        return None
    finally:
        terminate_current_process()
        current_process = None
        out_f.close()


def duration_tolerance(duration: float) -> float:
    return max(1.0, duration * 0.001)


def packet_float(value: Optional[str]) -> Optional[float]:
    try:
        val = float(value)
    except (ValueError, TypeError):
        return None
    return val if math.isfinite(val) else None


def dvd_nav_stream_indices(probe: Optional[Dict[str, Any]]) -> Set[int]:
    """Indices of DVD navigation streams (MPEG-PS format_name token exactly 'mpeg' + codec_type data + dvd_nav_packet)."""
    if not probe or not isinstance(probe.get("streams"), list):
        return set()
    fmt = probe.get("format")
    fmt_names = str(fmt.get("format_name", "") if isinstance(fmt, dict) else "").split(",")
    if "mpeg" not in fmt_names:
        return set()
    indices: Set[int] = set()
    for s in probe["streams"]:
        if isinstance(s, dict) and s.get("codec_type") == "data" and s.get("codec_name") == "dvd_nav_packet":
            idx = s.get("index")
            if isinstance(idx, int) and idx >= 0:
                indices.add(idx)
    return indices


def is_avi_source(probe: Optional[Dict[str, Any]]) -> bool:
    """True only when ffprobe format_name contains the exact token 'avi'."""
    if not probe or not isinstance(probe.get("format"), dict):
        return False
    return "avi" in str(probe["format"].get("format_name", "")).split(",")


def scan_packet_timeline(
    filepath: str, genpts: bool = False, ref: Optional[Dict[int, Dict[str, Any]]] = None,
    exclude_streams: Optional[Set[int]] = None
) -> Tuple[Optional[Dict[int, Dict[str, Any]]], Optional[Dict[int, Dict[str, Any]]], Dict[int, int]]:
    """One tracked ffprobe packet listing (genpts: with -fflags +genpts), stopped by a cancel request, a time limit or an
    output size limit. Audio packets are compared with the sample clock (previous start + duration): jumps counts
    +/-65.536 s steps that alternate and return to the clock, unknown counts every other deviation.
    Returns (streams, ids, missing). ids = per stream packet count, presence mask and digests of the listed pts/dts/duration text;
    with ref (the first listing) the pts digest covers only the packets that already had a pts there, and the stream ids,
    packet counts, those pts values, every dts and every duration must be identical to ref. missing = {stream: packets} for a first
    listing whose ONLY defect is a video packet with pts_time N/A/absent, a finite dts_time and a valid duration (streams
    is None then; the rest of the listing was still validated). Any other defect, or any missing pts in a genpts listing,
    gives (None, None, {}) with the reason left in timeline_failure.
    exclude_streams ignores precisely identified special streams (e.g. DVD navigation packets) that are not kept."""
    global current_process, timeline_failure
    timeline_failure = "incomplete"
    cmd = ([FFPROBE, "-v", "error"] + (["-fflags", "+genpts"] if genpts else [])
           + ["-show_entries", "packet=codec_type,stream_index,pts_time,dts_time,duration_time", "-of", "compact=p=0", filepath])
    out_f = tempfile.TemporaryFile()
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out_f, stderr=subprocess.DEVNULL, start_new_session=True)
        current_process = proc
        deadline = time.monotonic() + TIMELINE_TIMEOUT
        while True:
            try:
                proc.wait(timeout=0.25)
                break
            except subprocess.TimeoutExpired:
                pass
            check_incoming_stop()
            if stop_requested or time.monotonic() > deadline or os.fstat(out_f.fileno()).st_size > MAX_TIMELINE_BYTES:
                terminate_current_process()
                return None, None, {}
        if proc.returncode != 0 or os.fstat(out_f.fileno()).st_size > MAX_TIMELINE_BYTES:
            return None, None, {}
        timeline_failure = "unsupported"
        out_f.seek(0)
        streams: Dict[int, Dict[str, Any]] = {}
        ids: Dict[int, Dict[str, Any]] = {}
        missing: Dict[int, int] = {}
        for raw in out_f:
            fields = dict(kv.split("=", 1) for kv in raw.decode("utf-8", "replace").strip().split("|") if "=" in kv)
            try:
                idx = int(fields["stream_index"])
            except (KeyError, ValueError):
                return None, None, {}
            if idx < 0:
                return None, None, {}
            if exclude_streams and idx in exclude_streams:
                continue
            pts_text, dts_text, dur_text = fields.get("pts_time"), fields.get("dts_time"), fields.get("duration_time")
            pts, dts, dur = packet_float(pts_text), packet_float(dts_text), packet_float(dur_text)
            slot = ids.setdefault(idx, {"n": 0, "mask": bytearray(), "pts": hashlib.sha256(),
                                        "dts": hashlib.sha256(), "dur": hashlib.sha256()})
            pos = slot["n"]
            slot["n"] += 1
            slot["mask"].append(pts is not None)
            slot["dts"].update(f"{pos}:{dts_text}\n".encode())
            slot["dur"].update(f"{pos}:{dur_text}\n".encode())
            if ref is None:
                if pts is not None:
                    slot["pts"].update(f"{pos}:{pts_text}\n".encode())
            else:
                ref_slot = ref.get(idx)
                if ref_slot is None or pos >= len(ref_slot["mask"]):
                    return None, None, {}
                if ref_slot["mask"][pos]:
                    slot["pts"].update(f"{pos}:{pts_text}\n".encode())
            if pts is None:
                # Only the literal N/A (or an absent field) on a video packet with a finite dts and a valid duration can be
                # restored; garbage, nan/inf, audio and every other packet kind stay unsupported.
                if (genpts or pts_text not in (None, "N/A") or dts is None or fields.get("codec_type") != "video"
                        or not (dur_text in (None, "N/A") or (dur is not None and dur >= 0))):
                    return None, None, {}
                missing[idx] = missing.get(idx, 0) + 1
                continue
            s = streams.setdefault(idx, {"type": fields.get("codec_type"), "n": 0, "first": pts, "min_pts": pts,
                                         "dur_sum": 0.0, "dts_back": 0, "prev_dts": None, "prev_end": None,
                                         "shift": 0, "jumps": 0, "unknown": 0, "no_dur": 0, "pts_lt_dts": 0, "pts": []})
            s["n"] += 1
            s["min_pts"] = min(s["min_pts"], pts)
            if dts is not None:
                if s["prev_dts"] is not None and dts < s["prev_dts"]:
                    s["dts_back"] += 1
                s["prev_dts"] = dts
                if pts < dts - PTS_DTS_SLACK:
                    s["pts_lt_dts"] += 1
            if s["type"] == "video":
                s["pts"].append(pts)
            elif s["type"] == "audio":
                if dur is None or dur <= 0:
                    s["no_dur"] += 1
                    dur = 0.0
                if s["prev_end"] is not None:
                    off = pts - s["prev_end"]
                    if abs(off) <= CLOCK_STEP_TOLERANCE:
                        pass
                    elif abs(off - CLOCK_JUMP_SECONDS) <= CLOCK_STEP_TOLERANCE and s["shift"] == 0:
                        s["shift"], s["jumps"] = 1, s["jumps"] + 1
                    elif abs(off + CLOCK_JUMP_SECONDS) <= CLOCK_STEP_TOLERANCE and s["shift"] == 1:
                        s["shift"], s["jumps"] = 0, s["jumps"] + 1
                    else:
                        s["unknown"] += 1
                s["prev_end"] = pts + dur
                s["dur_sum"] += dur
        if ref is not None and (set(ids) != set(ref) or any(
                ids[i]["n"] != ref[i]["n"] or ids[i]["pts"].digest() != ref[i]["pts"].digest()
                or ids[i]["dts"].digest() != ref[i]["dts"].digest()
                or ids[i]["dur"].digest() != ref[i]["dur"].digest() for i in ids)):
            return None, None, {}
        if missing:
            return None, ids, missing
        if streams:
            timeline_failure = ""
        return streams or None, ids, {}
    except Exception as e:
        timeline_failure = "incomplete"
        sys.stderr.write(f"ffprobe packet timeline error on {filepath}: {e}\n")
        return None, None, {}
    finally:
        terminate_current_process()
        current_process = None
        out_f.close()


def probe_packet_timeline(
    filepath: str, exclude_streams: Optional[Set[int]] = None,
    allow_genpts: bool = False
) -> Optional[Dict[int, Dict[str, Any]]]:
    """Per-stream packet timing summary (see scan_packet_timeline); the single shared source timeline of the NAS
    verify-candidate check and the Mac/NAS encode diagnosis. None when the listing is incomplete or a packet has no usable
    pts (the reason is left in timeline_failure).
    A first listing whose only defect is video packets with pts_time N/A/absent and a finite dts_time gets exactly ONE
    retry of the SAME file with -fflags +genpts only when allow_genpts is true (opt-in for AVI sources). It is used only when
    it lists the same streams and packet counts, repeats every pts that was already present, every dts and every duration
    unchanged (so no other stream - the audio - can shift), gives every packet a pts, the restored pts are all distinct
    and none precedes its own dts. Such streams carry "pts_recovered": True.
    Nothing is substituted: a pts is never taken from the dts, and no other check is relaxed.
    Precisely identified DVD navigation data streams (MPEG-PS dvd_nav_packet) are excluded from the timeline."""
    global timeline_failure
    if exclude_streams is None and not filepath.lower().endswith(".mp4"):
        exclude_streams = dvd_nav_stream_indices(probe_file(filepath))
    streams, ids, missing = scan_packet_timeline(filepath, exclude_streams=exclude_streams)
    if streams is not None or not missing:
        return streams
    if not allow_genpts:
        return None
    if stop_requested:
        timeline_failure = "incomplete"
        return None
    streams, _, _ = scan_packet_timeline(filepath, genpts=True, ref=ids, exclude_streams=exclude_streams)
    if streams is None:
        return None  # the retry left its own reason: incomplete (limits, cancel) or unsupported
    for idx in missing:
        s = streams.get(idx)
        if (not s or s["type"] != "video" or s["n"] != ids[idx]["n"] or s["pts_lt_dts"]
                or len(set(s["pts"])) != len(s["pts"])):
            timeline_failure = "unsupported"
            return None
        s["pts_recovered"] = True
    return streams


def audio_clock_pattern(s: Dict[str, Any], src_duration: float) -> bool:
    """True only for the recognised damage: every audio packet continues the sample clock except paired +65.536 s /
    -65.536 s block offsets that return to the clock, and the sample-clock end agrees with the source duration."""
    return (s.get("type") == "audio" and s["jumps"] >= 2 and s["shift"] == 0 and s["unknown"] == 0 and s["no_dur"] == 0
            and abs(s["first"] + s["dur_sum"] - src_duration) <= duration_tolerance(src_duration))


def video_dts_damage(s: Optional[Dict[str, Any]]) -> bool:
    """True when decode-order timestamps run backwards while the presentation times are all distinct (so they can be kept)."""
    if not s or s.get("type") != "video" or not s["dts_back"]:
        return False
    pts = sorted(s["pts"])
    return all(b - a > 1e-6 for a, b in zip(pts, pts[1:]))


def plan_timing_repair(
    src_tl: Dict[int, Dict[str, Any]], src_duration: float,
    video_streams: List[Dict[str, Any]], audio_streams: List[Dict[str, Any]]
) -> Optional[Tuple[List[int], bool]]:
    """(audio positions whose timestamps are rebuilt from the sample clock, video must be re-encoded) for a source
    whose damage matches the recognised patterns; None when nothing is recognised or it cannot be repaired safely."""
    fix_audio: List[int] = []
    for i, sa in enumerate(audio_streams):
        s = src_tl.get(sa.get("index"))
        if s and audio_clock_pattern(s, src_duration):
            if aac_lc_problem(sa) is None:
                return None  # copied AAC cannot be re-timed without re-encoding it
            fix_audio.append(i)
    fix_video = any(video_dts_damage(src_tl.get(sv.get("index"))) for sv in video_streams)
    return (fix_audio, fix_video) if fix_audio or fix_video else None


def repaired_timeline_problem(
    src_tl: Dict[int, Dict[str, Any]], out_tl: Optional[Dict[int, Dict[str, Any]]], src_duration: float,
    video_streams: List[Dict[str, Any]], audio_streams: List[Dict[str, Any]],
    out_v: List[Dict[str, Any]], out_a: List[Dict[str, Any]], fix_audio: List[int]
) -> Optional[str]:
    """Checks the repaired file's own packet timeline (not just its container duration); None when it is sound."""
    if not out_tl:
        return "복구 결과의 패킷 시간축을 분석하지 못했습니다"
    for i in fix_audio:
        so, ss = out_tl.get(out_a[i].get("index")), src_tl[audio_streams[i]["index"]]
        if not so or so["jumps"] or so["unknown"] or so["no_dur"]:
            return "복구된 오디오의 시간축이 끊김 없이 이어지지 않습니다"
        if abs(so["dur_sum"] - ss["dur_sum"]) > 0.1 or abs(so["first"] + so["dur_sum"] - src_duration) > duration_tolerance(src_duration):
            return "복구된 오디오 길이가 원본 샘플 수 기준 길이와 다릅니다"
    for idx, sv in enumerate(video_streams):
        ss, so = src_tl.get(sv.get("index")), out_tl.get(out_v[idx].get("index"))
        if not ss or not so or so["n"] != ss["n"]:
            return "복구된 영상의 프레임 수가 원본과 다릅니다"
        a, b = sorted(ss["pts"]), sorted(so["pts"])
        if any(abs((y - b[0]) - (x - a[0])) > 0.005 for x, y in zip(a, b)):
            return "복구된 영상의 프레임 표시 시각이 원본과 다릅니다"
    if fix_audio and video_streams:
        src_off = src_tl[audio_streams[fix_audio[0]]["index"]]["first"] - src_tl[video_streams[0]["index"]]["min_pts"]
        out_off = out_tl[out_a[fix_audio[0]]["index"]]["first"] - out_tl[out_v[0]["index"]]["min_pts"]
        if abs(out_off - src_off) > 0.1:
            return f"복구 후 영상·음성 시작 오프셋이 원본과 다릅니다(원본 {src_off:.3f}s, 결과 {out_off:.3f}s)"
    return None


def probe_decoded_frame_timeline(
    filepath: str,
    expected_v_indices: List[int],
    expected_a_indices: List[int],
    allowed_other_indices: Optional[Set[int]] = None
) -> Optional[Dict[str, Any]]:
    """Per-stream decoded frame presentation timeline via tracked ffprobe: stopped by cancel, deadline or size limit.
    Validates each mapped video stream separately in decoded presentation order without sorting. Collects presentation
    timestamps and durations for all decoded video frames, and the trustworthy first audio timestamp for each mapped
    audio stream. Missing/untrustworthy timestamps, unexpected stream identities, non-increasing PTS or incomplete counts
    fail closed (returns None)."""
    global current_process
    cmd = [FFPROBE, "-v", "error", "-show_entries", "frame=media_type,stream_index,pts_time,duration_time",
           "-of", "compact=p=0", filepath]
    out_f = tempfile.TemporaryFile()
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out_f, stderr=subprocess.DEVNULL, start_new_session=True)
        current_process = proc
        deadline = time.monotonic() + TIMELINE_TIMEOUT
        while True:
            try:
                proc.wait(timeout=0.25)
                break
            except subprocess.TimeoutExpired:
                pass
            check_incoming_stop()
            if stop_requested or time.monotonic() > deadline or os.fstat(out_f.fileno()).st_size > MAX_TIMELINE_BYTES:
                terminate_current_process()
                return None
        if proc.returncode != 0 or os.fstat(out_f.fileno()).st_size > MAX_TIMELINE_BYTES:
            return None
        out_f.seek(0)

        v_set = set(expected_v_indices)
        a_set = set(expected_a_indices)
        other_set = set(allowed_other_indices or ())
        all_allowed = v_set | a_set | other_set

        video_pts: Dict[int, List[float]] = {idx: [] for idx in expected_v_indices}
        video_last_dur: Dict[int, float] = {}
        first_audio_pts: Dict[int, float] = {}
        seen_first_audio: Set[int] = set()

        for raw in out_f:
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            fields = dict(kv.split("=", 1) for kv in line.split("|") if "=" in kv)
            mtype = fields.get("media_type")
            s_idx_str = fields.get("stream_index")
            if s_idx_str is not None and s_idx_str != "":
                try:
                    s_idx = int(s_idx_str)
                except (ValueError, TypeError):
                    return None
            else:
                # Decoders/demuxers without per-frame stream_index (e.g. ASF/WMV)
                if mtype == "video" and len(expected_v_indices) == 1:
                    s_idx = expected_v_indices[0]
                elif mtype == "audio" and len(expected_a_indices) == 1:
                    s_idx = expected_a_indices[0]
                else:
                    # Missing/ambiguous stream identity fails closed
                    return None

            if s_idx not in all_allowed:
                return None

            if s_idx in v_set:
                if mtype != "video":
                    return None
                pts = packet_float(fields.get("pts_time"))
                if pts is None:
                    return None
                stream_pts = video_pts[s_idx]
                if stream_pts and pts <= stream_pts[-1]:
                    # Non-increasing per-stream PTS: fail closed, never sort
                    return None
                stream_pts.append(pts)
                dur = packet_float(fields.get("duration_time"))
                if dur is not None and dur > 0:
                    video_last_dur[s_idx] = dur
            elif s_idx in a_set:
                if mtype != "audio":
                    return None
                if s_idx not in seen_first_audio:
                    seen_first_audio.add(s_idx)
                    pts = packet_float(fields.get("pts_time"))
                    if pts is None:
                        # Trustworthy FIRST decoded audio reference required: no fallback to later frames
                        return None
                    first_audio_pts[s_idx] = pts
            elif s_idx in other_set:
                continue

        # Incomplete counts fail closed
        for v_idx in expected_v_indices:
            if not video_pts[v_idx] or v_idx not in video_last_dur:
                return None
        for a_idx in expected_a_indices:
            if a_idx not in first_audio_pts:
                return None

        return {
            "video_pts": video_pts,
            "video_last_dur": video_last_dur,
            "first_audio_pts": first_audio_pts,
        }
    except Exception as e:
        sys.stderr.write(f"ffprobe frame timeline error on {filepath}: {e}\n")
        return None
    finally:
        terminate_current_process()
        current_process = None
        out_f.close()


def verify_decoded_presentation_match(
    source_path: str,
    out_path: str,
    video_streams: List[Dict[str, Any]],
    out_v_streams: List[Dict[str, Any]],
    audio_streams: List[Dict[str, Any]],
    out_a_streams: List[Dict[str, Any]],
    allowed_other_src: Optional[Set[int]] = None,
    allowed_other_out: Optional[Set[int]] = None,
    probes: Optional[Tuple[Dict[str, Any], Dict[str, Any]]] = None,
) -> Optional[str]:
    """Strict bounded complete decoded presentation comparison between source and candidate across all mapped streams.
    Validates each mapped video stream separately in decoded presentation order without sorting, verifies start/end
    coverage using trustworthy decoded durations with explicitly justified quantization bounds, and checks relative
    A/V offsets for each mapped audio stream accounting for encoder priming."""
    src_v_indices = [int(s["index"]) for s in video_streams if s.get("index") is not None]
    out_v_indices = [int(s["index"]) for s in out_v_streams if s.get("index") is not None]
    src_a_indices = [int(s["index"]) for s in audio_streams if s.get("index") is not None]
    out_a_indices = [int(s["index"]) for s in out_a_streams if s.get("index") is not None]

    if len(src_v_indices) != len(video_streams) or len(out_v_indices) != len(out_v_streams):
        return "비디오 스트림 인덱스 정보가 올바르지 않습니다"
    if len(src_a_indices) != len(audio_streams) or len(out_a_indices) != len(out_a_streams):
        return "오디오 스트림 인덱스 정보가 올바르지 않습니다"
    if len(src_v_indices) != len(out_v_indices):
        return f"비디오 스트림 수 불일치 (원본: {len(src_v_indices)}, 결과: {len(out_v_indices)})"
    if len(src_a_indices) != len(out_a_indices):
        return f"오디오 스트림 수 불일치 (원본: {len(src_a_indices)}, 결과: {len(out_a_indices)})"

    if probes is not None:
        s_probe, o_probe = probes
    else:
        s_probe = probe_decoded_frame_timeline(source_path, src_v_indices, src_a_indices, allowed_other_src)
        if stop_requested:
            return "작업 중지 요청됨"
        if not s_probe:
            return "원본 디코딩 프레임 시간축 분석 실패 (시간 초과·출력 한도·ffprobe 오류 또는 타임스탬프 누락)"
        o_probe = probe_decoded_frame_timeline(out_path, out_v_indices, out_a_indices, allowed_other_out)
        if stop_requested:
            return "작업 중지 요청됨"
        if not o_probe:
            return "결과 파일 디코딩 프레임 시간축 분석 실패 (시간 초과·출력 한도·ffprobe 오류 또는 타임스탬프 누락)"

    # Validate each mapped video stream separately in decoded presentation order
    for idx, sv in enumerate(video_streams):
        ov = out_v_streams[idx]
        s_v_idx = src_v_indices[idx]
        o_v_idx = out_v_indices[idx]
        s_v = s_probe["video_pts"].get(s_v_idx, [])
        o_v = o_probe["video_pts"].get(o_v_idx, [])
        if len(s_v) != len(o_v):
            return f"비디오 스트림 #{idx} 프레임 수 불일치 (원본: {len(s_v)}, 결과: {len(o_v)})"
        if not s_v:
            return f"비디오 스트림 #{idx} 프레임이 없습니다"

        s_tb = parse_rational(sv.get("time_base"))
        o_tb = parse_rational(ov.get("time_base"))
        s_fps = video_fps(sv)
        o_fps = video_fps(ov)
        if s_tb is None or o_tb is None or s_fps is None or o_fps is None:
            return f"비디오 스트림 #{idx} 시간 기준(time_base) 또는 프레임레이트 정보가 유효하지 않아 양자화 허용 오차를 산출할 수 없습니다"

        s_precision = float(s_tb)
        o_precision = float(o_tb)
        half_period = float(Fraction(1, 2) / s_fps)
        # Justified per-frame PTS tolerance: half nominal frame period + source & output timebase precision
        max_pts_tol = half_period + s_precision + o_precision

        for i in range(len(s_v)):
            diff = abs(o_v[i] - s_v[i])
            if diff > max_pts_tol:
                return (f"비디오 스트림 #{idx} 프레임 #{i} 표시 시각 오차 초과 "
                        f"(원본: {s_v[i]:.4f}s, 결과: {o_v[i]:.4f}s, 오차: {diff:.4f}s > 허용치 {max_pts_tol:.4f}s)")

        # Start and PTS span coverage
        start_diff = abs(o_v[0] - s_v[0])
        if start_diff > max_pts_tol:
            return f"비디오 스트림 #{idx} 시작 표시 시각 오차 초과 (원본: {s_v[0]:.4f}s, 결과: {o_v[0]:.4f}s, 오차: {start_diff:.4f}s > {max_pts_tol:.4f}s)"

        s_pts_span = s_v[-1] - s_v[0]
        o_pts_span = o_v[-1] - o_v[0]
        pts_span_diff = abs(o_pts_span - s_pts_span)
        if pts_span_diff > max_pts_tol:
            return f"비디오 스트림 #{idx} PTS 구간 오차 초과 (원본: {s_pts_span:.4f}s, 결과: {o_pts_span:.4f}s, 오차: {pts_span_diff:.4f}s > {max_pts_tol:.4f}s)"

        # Decoded duration and end coverage: justified tail quantization
        s_last_dur = s_probe["video_last_dur"].get(s_v_idx)
        o_last_dur = o_probe["video_last_dur"].get(o_v_idx)
        if s_last_dur is None or s_last_dur <= 0 or not math.isfinite(s_last_dur):
            return f"비디오 스트림 #{idx} 원본 마지막 프레임 표시 기간 정보가 유효하지 않습니다"
        if o_last_dur is None or o_last_dur <= 0 or not math.isfinite(o_last_dur):
            return f"비디오 스트림 #{idx} 결과 마지막 프레임 표시 기간 정보가 유효하지 않습니다"

        frame_period = float(Fraction(1, 1) / s_fps)
        # Tail tolerance: PTS tolerance + at most 1 frame duration container muxing quantization + timebase precision
        max_tail_tol = max_pts_tol + frame_period + s_precision + o_precision

        s_end = s_v[-1] + s_last_dur
        o_end = o_v[-1] + o_last_dur
        tail_diff = abs(o_end - s_end)
        if tail_diff > max_tail_tol:
            return f"비디오 스트림 #{idx} 종료 표시 시점 오차 초과 (원본: {s_end:.4f}s, 결과: {o_end:.4f}s, 오차: {tail_diff:.4f}s > {max_tail_tol:.4f}s)"

        s_span = s_end - s_v[0]
        o_span = o_end - o_v[0]
        span_diff = abs(o_span - s_span)
        if span_diff > max_tail_tol:
            return f"비디오 스트림 #{idx} 전체 재생 구간 오차 초과 (원본: {s_span:.4f}s, 결과: {o_span:.4f}s, 오차: {span_diff:.4f}s > {max_tail_tol:.4f}s)"

    # Audio/Video relative offset check for every mapped audio stream
    if audio_streams:
        for a_idx, sa in enumerate(audio_streams):
            oa = out_a_streams[a_idx]
            s_a_id = src_a_indices[a_idx]
            o_a_id = out_a_indices[a_idx]
            s_a_first = s_probe["first_audio_pts"].get(s_a_id)
            o_a_first = o_probe["first_audio_pts"].get(o_a_id)
            if s_a_first is None or not math.isfinite(s_a_first):
                return f"오디오 스트림 #{a_idx} 원본 첫 번째 디코딩 타임스탬프를 확인할 수 없습니다"
            if o_a_first is None or not math.isfinite(o_a_first):
                return f"오디오 스트림 #{a_idx} 결과 첫 번째 디코딩 타임스탬프를 확인할 수 없습니다"

            v_map_idx = min(a_idx, len(video_streams) - 1)
            s_v_first = s_probe["video_pts"][src_v_indices[v_map_idx]][0]
            o_v_first = o_probe["video_pts"][out_v_indices[v_map_idx]][0]

            s_off = s_v_first - s_a_first
            o_off = o_v_first - o_a_first

            sr = sa.get("sample_rate")
            try:
                sr_val = float(sr) if sr else 0.0
            except (ValueError, TypeError):
                sr_val = 0.0
            if sr_val <= 0:
                return f"오디오 스트림 #{a_idx} 샘플레이트 정보가 유효하지 않습니다"

            # AAC re-encode introduces 1024 delay samples of encoder priming
            is_aac_reencode = (str(oa.get("codec_name")).lower() in ("aac", "mp4a")
                               and str(sa.get("codec_name")).lower() not in ("aac", "mp4a"))
            priming_sec = (1024.0 / sr_val) if is_aac_reencode else 0.0

            audio_precision = 1.0 / sr_val
            # Offset drift tolerance: video presentation quantization + audio sample precision
            s_v_fps = video_fps(video_streams[v_map_idx]) or Fraction(30, 1)
            s_v_tb = parse_rational(video_streams[v_map_idx].get("time_base")) or Fraction(1, 1000)
            o_v_tb = parse_rational(out_v_streams[v_map_idx].get("time_base")) or Fraction(1, 30000)
            v_pts_tol = float(Fraction(1, 2) / s_v_fps) + float(s_v_tb) + float(o_v_tb)
            max_offset_drift = v_pts_tol + audio_precision

            offset_drift = abs((o_off - s_off) - priming_sec)
            if offset_drift > max_offset_drift:
                return (f"오디오 스트림 #{a_idx} 영상·음성 시작 오프셋 오차 초과 "
                        f"(원본: {s_off:.4f}s, 결과: {o_off:.4f}s, 프라이밍 보정 차이: {offset_drift:.4f}s > 허용치 {max_offset_drift:.4f}s)")

    return None


def parse_rational(value: Any) -> Optional[Fraction]:
    """Parses ffprobe rationals like '30000/1001', '25', '16:9'. Returns None if invalid or non-positive."""
    try:
        text = str(value).strip().replace(":", "/")
        if "/" in text:
            num, den = text.split("/", 1)
            if int(den) == 0:
                return None
            frac = Fraction(int(num), int(den))
        else:
            frac = Fraction(text)
        return frac if frac > 0 else None
    except (ValueError, TypeError, ZeroDivisionError):
        return None


def parse_duration(fmt: Dict[str, Any]) -> Optional[float]:
    """Returns a finite positive duration in seconds, else None."""
    try:
        val = float(fmt.get("duration"))
    except (ValueError, TypeError):
        return None
    return val if math.isfinite(val) and val > 0 else None


def video_fps(stream: Dict[str, Any]) -> Optional[Fraction]:
    return parse_rational(stream.get("avg_frame_rate")) or parse_rational(stream.get("r_frame_rate"))


def video_display_aspect(stream: Dict[str, Any]) -> Optional[Fraction]:
    """Display aspect ratio from DAR if present, else width/height * SAR (SAR unknown => square)."""
    dar = parse_rational(stream.get("display_aspect_ratio"))
    if dar:
        return dar
    w, h = stream.get("width"), stream.get("height")
    if not isinstance(w, int) or not isinstance(h, int) or w <= 0 or h <= 0:
        return None
    sar = parse_rational(stream.get("sample_aspect_ratio")) or Fraction(1)
    return Fraction(w, h) * sar


def rel_close(a: Fraction, b: Fraction, tol: Fraction) -> bool:
    return abs(a - b) <= a * tol


# Only plain 8-bit 4:2:0 may be re-encoded with libx264; anything else (10/12/16-bit, p010, rgb48,
# 4:2:2/4:4:4, full-range yuvj ...) would be silently down-converted, so it is refused.
SAFE_REENCODE_PIX_FMTS = {"yuv420p"}

# Portability policy: every output video is H.264 (avc1) 8-bit yuv420p, profile Baseline/Main/High, level <= 4.1,
# every output audio is AAC-LC (mp4a). Anything else is re-encoded when that is safe, otherwise the file fails.
H264_ALLOWED_PROFILES = {"baseline", "constrained baseline", "main", "high"}
MAX_H264_LEVEL = 41                  # ffprobe reports level 4.1 as 41
LEVEL41_MAX_MBS = 8192               # max frame size in macroblocks at level 4.1
LEVEL41_MAX_MBPS = 245760            # max macroblocks per second at level 4.1
LEVEL31_MAX_MBS = 3600               # max frame size in macroblocks at level 3.1
LEVEL31_MAX_MBPS = 108000            # max macroblocks per second at level 3.1
MAX_LONG_SIDE, MAX_SHORT_SIDE = 1920, 1088
TEXT_SUBTITLE_CODECS = {"subrip", "srt", "text", "mov_text", "webvtt"}


def unsafe_to_reencode(s: Dict[str, Any]) -> bool:
    pix = str(s.get("pix_fmt", "")).lower()
    transfer = str(s.get("color_transfer", "")).lower()
    primaries = str(s.get("color_primaries", "")).lower()
    try:
        raw_bits = int(s.get("bits_per_raw_sample") or 8)
    except (ValueError, TypeError):
        return True
    return (
        pix not in SAFE_REENCODE_PIX_FMTS or raw_bits > 8 or
        transfer in ("smpte2084", "arib-std-b67") or
        primaries == "bt2020" or "hdr" in transfer
    )


def level41_problem(width: int, height: int, fps: Fraction) -> Optional[str]:
    """None if the frame size and rate fit H.264 level 4.1 (and 1080p); never scaled or retimed to fit."""
    if max(width, height) > MAX_LONG_SIDE or min(width, height) > MAX_SHORT_SIDE:
        return f"해상도 {width}x{height}이(가) 1080p 한도를 넘습니다"
    mbs = ((width + 15) // 16) * ((height + 15) // 16)
    if mbs > LEVEL41_MAX_MBS or mbs * fps > LEVEL41_MAX_MBPS:
        return f"해상도·프레임레이트({width}x{height}, {float(fps):.3f}fps)가 H.264 레벨 4.1 한도를 넘습니다"
    return None


def h264_target_level(width: int, height: int, fps: Fraction) -> str:
    """Level written for a re-encode: 3.1 when frame size and macroblock rate fit it (small SD sources), else 4.1.
    Callers have already rejected anything above level 4.1 via level41_problem; nothing is scaled or retimed."""
    mbs = ((width + 15) // 16) * ((height + 15) // 16)
    return "3.1" if mbs <= LEVEL31_MAX_MBS and mbs * fps <= LEVEL31_MAX_MBPS else "4.1"


def h264_policy_problem(s: Dict[str, Any], require_avc1: bool = False) -> Optional[str]:
    """None if the video stream already satisfies the portability policy, else the reason."""
    codec = str(s.get("codec_name", "")).lower()
    if codec != "h264":
        return f"영상 코덱이 H.264가 아닙니다({codec or '알 수 없음'})"
    if str(s.get("pix_fmt", "")).lower() != "yuv420p":
        return f"화소 형식이 yuv420p가 아닙니다({s.get('pix_fmt')})"
    try:
        bits = int(s.get("bits_per_raw_sample") or 8)
    except (ValueError, TypeError):
        return "비트 심도를 확인할 수 없습니다"
    if bits != 8:
        return f"8비트가 아닙니다({bits}비트)"
    if str(s.get("profile", "")).lower() not in H264_ALLOWED_PROFILES:
        return f"H.264 프로파일이 Baseline/Main/High가 아닙니다({s.get('profile')})"
    level = s.get("level")
    if type(level) is not int or not 1 <= level <= MAX_H264_LEVEL:
        return f"H.264 레벨이 4.1 이하가 아니거나 알 수 없습니다({level})"
    if require_avc1 and str(s.get("codec_tag_string", "")).lower() != "avc1":
        return f"코덱 태그가 avc1이 아닙니다({s.get('codec_tag_string')})"
    return None


def aac_lc_problem(s: Dict[str, Any], require_mp4a: bool = False) -> Optional[str]:
    codec = str(s.get("codec_name", "")).lower()
    if codec != "aac":
        return f"오디오 코덱이 AAC가 아닙니다({codec or '알 수 없음'})"
    if str(s.get("profile", "")).upper() != "LC":
        return f"AAC 프로파일이 LC가 아닙니다({s.get('profile')})"
    if require_mp4a and str(s.get("codec_tag_string", "")).lower() != "mp4a":
        return f"코덱 태그가 mp4a가 아닙니다({s.get('codec_tag_string')})"
    return None


def aac_bitrate(channels: int) -> str:
    """Stereo 192k; mono 128k; surround never gets a stereo-sized budget."""
    if channels <= 1:
        return "128k"
    if channels == 2:
        return "192k"
    return "384k" if channels <= 6 else "512k"


def plan_streams(
    video_streams: List[Dict[str, Any]],
    audio_streams: List[Dict[str, Any]],
    subtitle_streams: List[Dict[str, Any]],
    force_video_reencode: bool = False
) -> Tuple[List[str], List[str], bool]:
    """Chooses copy or re-encode per stream so the output meets the policy (force_video_reencode: no video copy). Returns (ffmpeg codec args,
    notes, copy_only). Raises ValueError with a user-facing reason when the policy cannot be met safely:
    nothing is scaled, retimed, colour-converted or otherwise silently coerced."""
    args: List[str] = []
    notes: List[str] = []
    copy_only = True

    for i, sv in enumerate(video_streams):
        width, height, fps = sv["width"], sv["height"], video_fps(sv)
        problem = level41_problem(width, height, fps)
        if problem:
            raise ValueError(f"영상 {i + 1}: {problem}. 크기·프레임레이트를 임의로 바꾸지 않으므로 변환하지 않고 원본을 유지합니다.")
        if not force_video_reencode and h264_policy_problem(sv) is None:
            args += [f"-c:v:{i}", "copy", f"-tag:v:{i}", "avc1"]
            continue
        if unsafe_to_reencode(sv):
            raise ValueError(f"영상 {i + 1}: HDR, 10비트 이상 또는 8비트 4:2:0(yuv420p)이 아닌 영상은 "
                             "색·화질을 바꾸지 않고는 호환 형식으로 만들 수 없어 건너뜁니다.")
        if width % 2 or height % 2:
            raise ValueError(f"영상 {i + 1}: 가로·세로가 짝수가 아니어서({width}x{height}) 크기 변경 없이 H.264로 인코딩할 수 없습니다.")
        level = h264_target_level(width, height, fps)
        args += [f"-c:v:{i}", "libx264", f"-crf:v:{i}", "18", f"-preset:v:{i}", "medium",
                 f"-pix_fmt:v:{i}", "yuv420p", f"-profile:v:{i}", "high", f"-level:v:{i}", level,
                 f"-tag:v:{i}", "avc1"]
        copy_only = False
        notes.append(f"영상 {i + 1}: {sv.get('codec_name')} → H.264 다시 인코딩(CRF 18, High@{level}, 해상도·프레임레이트·화면 비율 유지)")

    for i, sa in enumerate(audio_streams):
        if aac_lc_problem(sa) is None:
            args += [f"-c:a:{i}", "copy"]
            continue
        channels = sa.get("channels")
        if type(channels) is not int or channels < 1 or not sa.get("sample_rate"):
            raise ValueError(f"오디오 {i + 1}: 채널 수 또는 샘플레이트를 알 수 없어 AAC로 바꿀 수 없습니다.")
        args += [f"-c:a:{i}", "aac", f"-profile:a:{i}", "aac_low", f"-b:a:{i}", aac_bitrate(channels)]
        copy_only = False
        notes.append(f"오디오 {i + 1}: {sa.get('codec_name')} → AAC-LC {aac_bitrate(channels)}(채널 수·샘플레이트 유지)")

    for sub in subtitle_streams:
        sub_codec = str(sub.get("codec_name", "")).lower()
        if sub_codec in ("ass", "ssa"):
            raise ValueError("ASS/SSA 스타일 자막은 MP4 텍스트 규격으로 서식 보존이 불가능하여 건너뜁니다.")
        if sub_codec not in TEXT_SUBTITLE_CODECS:
            raise ValueError(f"자막 형식({sub_codec or '알 수 없음'})은 MP4 텍스트 자막으로 안전하게 바꿀 수 없어 건너뜁니다.")
    if subtitle_streams:
        args += ["-c:s", "mov_text"]
        notes.append("자막을 텍스트 자막으로 변환")

    return args, notes, copy_only


def output_policy_problem(out_streams: List[Dict[str, Any]]) -> Optional[str]:
    """Strict check of the FINISHED file: any legacy/non-policy codec is rejected even if ffmpeg can decode it."""
    for s in out_streams:
        ctype = s.get("codec_type")
        if ctype == "video":
            problem = h264_policy_problem(s, require_avc1=True)
        elif ctype == "audio":
            problem = aac_lc_problem(s, require_mp4a=True)
        elif ctype == "subtitle":
            problem = None if str(s.get("codec_name", "")).lower() == "mov_text" else f"자막 코덱이 mov_text가 아닙니다({s.get('codec_name')})"
        else:
            problem = None
        if problem:
            return f"스트림 #{s.get('index')}: {problem}"
    return None


def moov_before_mdat(path: str) -> bool:
    """True if the 'moov' box precedes 'mdat' at top level (what -movflags +faststart must produce)."""
    try:
        with open(path, "rb") as f:
            while True:
                head = f.read(8)
                if len(head) < 8:
                    return False
                size = int.from_bytes(head[:4], "big")
                kind = head[4:8]
                if kind == b"moov":
                    return True
                if kind == b"mdat":
                    return False
                if size == 1:
                    ext = f.read(8)
                    if len(ext) < 8:
                        return False
                    size, skip = int.from_bytes(ext, "big"), 16
                else:
                    skip = 8
                if size < skip:
                    return False
                f.seek(size - skip, os.SEEK_CUR)
    except OSError:
        return False


def sample_aspect(stream: Dict[str, Any]) -> Fraction:
    """Sample aspect ratio; unknown or 0:1 means square pixels. A non-1 SAR is preserved and compared as such."""
    return parse_rational(stream.get("sample_aspect_ratio")) or Fraction(1)


def video_metadata_ok(sv: Dict[str, Any]) -> bool:
    """Size, frame rate, aspect and time base must all be present and sane (fail closed otherwise)."""
    return (isinstance(sv.get("width"), int) and isinstance(sv.get("height"), int)
            and sv["width"] > 0 and sv["height"] > 0
            and video_fps(sv) is not None and video_display_aspect(sv) is not None
            and parse_rational(sv.get("time_base")) is not None)


def plan_from_probe(src_probe: Optional[Dict[str, Any]]) -> Tuple[float, List[Dict[str, Any]], List[Dict[str, Any]],
                                                                 List[Dict[str, Any]], List[str], List[str], bool]:
    """Source probe -> (duration, video, audio, subtitle streams, ffmpeg codec args, notes, copy_only).
    Raises ValueError with a user-facing reason when the source cannot be converted safely."""
    if not src_probe or not isinstance(src_probe.get("streams"), list):
        raise ValueError("원본 파일의 미디어 스트림 정보를 분석할 수 없습니다.")
    fmt = src_probe.get("format")
    src_duration = parse_duration(fmt if isinstance(fmt, dict) else {})
    if src_duration is None:
        raise ValueError("원본 파일의 재생 시간 정보가 유효하지 않아 변환을 건너뜁니다.")

    streams = [s for s in src_probe["streams"] if isinstance(s, dict)]
    video_streams = [s for s in streams if s.get("codec_type") == "video"]
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    subtitle_streams = [s for s in streams if s.get("codec_type") == "subtitle"]

    # Reject unsupported streams (attachments, data). The ONLY exception: DVD navigation packets (data / dvd_nav_packet)
    # inside an MPEG program stream (format_name token exactly "mpeg"); they are not carried into the MP4 (only v/a/s are mapped).
    mpeg_ps = "mpeg" in str(fmt.get("format_name", "") if isinstance(fmt, dict) else "").split(",")
    dvd_nav = [s for s in streams if mpeg_ps and s.get("codec_type") == "data" and s.get("codec_name") == "dvd_nav_packet"]
    if any(s.get("codec_type") in ("attachment", "data") and not any(s is n for n in dvd_nav) for s in streams):
        raise ValueError("첨부 파일 또는 특수 데이터 스트림이 포함되어 보존을 위해 변환을 건너뜁니다.")
    if not video_streams:
        raise ValueError("원본 파일에 비디오 스트림이 존재하지 않습니다.")
    if not all(video_metadata_ok(sv) for sv in video_streams):
        raise ValueError("원본 비디오의 해상도, 프레임레이트 또는 화면 비율 정보가 불완전하여 원본을 유지합니다.")

    codec_args, notes, copy_only = plan_streams(video_streams, audio_streams, subtitle_streams)
    if dvd_nav:
        notes.append(DVD_NAV_NOTE)
    return src_duration, video_streams, audio_streams, subtitle_streams, codec_args, notes, copy_only


def classify_mp4(path: str) -> Tuple[str, str]:
    """Metadata-only compatibility check of an EXISTING MP4 (nothing is decoded, so corruption is NOT detected):
    ('healthy', '')      H.264 avc1 8-bit yuv420p Baseline/Main/High <= 4.1 + every audio AAC-LC mp4a + faststart,
    ('convert', reason)  something differs from that policy and the file can be rebuilt safely,
    ('unsupported', why) differs but cannot be converted without changing it (HDR, 10-bit, data streams ...),
    ('unverified', why)  probe failed or key metadata is missing: never reported as healthy."""
    probe = probe_file(path, SCAN_PROBE_TIMEOUT)
    if not probe or not isinstance(probe.get("streams"), list):
        return "unverified", "ffprobe로 분석하지 못했거나 시간이 초과되었습니다"
    fmt = probe.get("format") if isinstance(probe.get("format"), dict) else {}
    streams = [s for s in probe["streams"] if isinstance(s, dict)]
    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    if not video or parse_duration(fmt) is None or not all(video_metadata_ok(s) for s in video):
        return "unverified", "영상 스트림, 재생 시간 또는 해상도·프레임레이트 정보를 확인할 수 없습니다"

    problem: Optional[str] = None
    if "mp4" not in str(fmt.get("format_name", "")).split(","):
        problem = "MP4 컨테이너가 아닙니다"
    for s in video:
        problem = problem or h264_policy_problem(s, require_avc1=True) or level41_problem(s["width"], s["height"], video_fps(s))
    for s in audio:
        problem = problem or aac_lc_problem(s, require_mp4a=True)
    if problem is None and not moov_before_mdat(path):
        problem = "faststart 구조가 아닙니다(moov가 파일 뒤쪽에 있음)"
    if problem is None:
        return "healthy", ""
    try:
        plan_from_probe(probe)
    except ValueError as e:
        return "unsupported", str(e)
    return "convert", problem


CHECKS_PASSED_TEXT = "파일 검사 통과(코덱 정책·스트림 구조·재생 시간·전체 디코딩). 실제 기기 재생은 확인되지 않았습니다"


def phase_announcer(
    report: Optional[Callable[[str, str, Optional[float], Optional[float]], None]]
) -> Callable[..., Optional[Callable[[float], None]]]:
    """begin(phase, label, total) announces a new step at once (nothing of the previous step carries over) and returns
    ffmpeg's position callback; without a report callback it does nothing."""
    def begin(phase: str, label: str, total: Optional[float] = None) -> Optional[Callable[[float], None]]:
        if report is None:
            return None
        report(phase, label, None, None)
        return lambda pos: report(phase, label, pos, total)
    return begin


def verify_output(
    out_path: str, src_duration: float, video_streams: List[Dict[str, Any]], audio_streams: List[Dict[str, Any]],
    subtitle_streams: List[Dict[str, Any]], tag: str, begin: Callable[..., Optional[Callable[[float], None]]],
    source_path: Optional[str] = None
) -> Tuple[Optional[str], bool, List[Dict[str, Any]], List[Dict[str, Any]], float]:
    """THE acceptance check of a finished MP4 against its source plan, shared by the NAS convert path and by the engine's
    verify-candidate: structure, strict codec policy, faststart, exact stream counts, size / frame rate / aspect /
    channels / sample rate fidelity and a clean full decode pass. The file is only read.
    Returns (problem or None, timing_symptom, output video streams, output audio streams, output duration): timing_symptom
    is set when the failure may be explained by damaged source timestamps (a timing-repair retry may then be diagnosed)."""
    def bad(reason: str, symptom: bool = False) -> Tuple[Optional[str], bool, List[Dict[str, Any]], List[Dict[str, Any]], float]:
        return reason, symptom, [], [], 0.0

    begin("verify", f"{tag} 구조·코덱 확인 중 (ffprobe 메타데이터)")
    out_probe = probe_file(out_path)
    if not out_probe or "streams" not in out_probe:
        return bad("생성된 파일의 미디어 분석에 실패했습니다.")

    if "mp4" not in str(out_probe.get("format", {}).get("format_name", "")).split(","):
        return bad("생성된 파일이 MP4 컨테이너가 아닙니다.")

    out_duration = parse_duration(out_probe.get("format", {}))
    if out_duration is None:
        return bad("생성된 파일의 재생 시간 정보가 유효하지 않습니다.")

    if abs(out_duration - src_duration) > duration_tolerance(src_duration):
        return bad(f"재생 시간 오차 초과 (원본: {src_duration:.1f}s, 생성: {out_duration:.1f}s)", True)

    out_v_streams = [s for s in out_probe["streams"] if s.get("codec_type") == "video"]
    out_a_streams = [s for s in out_probe["streams"] if s.get("codec_type") == "audio"]
    out_s_streams = [s for s in out_probe["streams"] if s.get("codec_type") == "subtitle"]

    if len(out_v_streams) != len(video_streams):
        return bad(f"비디오 스트림 수 불일치 (원본: {len(video_streams)}, 생성: {len(out_v_streams)})")

    if len(out_a_streams) != len(audio_streams):
        return bad(f"오디오 스트림 수 불일치 (원본: {len(audio_streams)}, 생성: {len(out_a_streams)})")

    if len(out_s_streams) != len(subtitle_streams):
        return bad(f"자막 스트림 수 불일치 (원본: {len(subtitle_streams)}, 생성: {len(out_s_streams)})")

    # Detailed codec policy: legacy video/audio (mpeg4, MP3, AC-3 ...) is rejected even though ffmpeg can decode it
    problem = output_policy_problem(out_probe["streams"])
    if problem:
        return bad(f"호환 정책 검증 실패(결과 파일 폐기, 원본 유지) - {problem}")

    if not moov_before_mdat(out_path):
        return bad("faststart 구조 검증 실패 (moov 정보가 파일 앞부분에 없습니다)")

    decoded_pres_verified = False
    decoded_pres_problem: Optional[str] = None
    sub_indices_src = set(int(s["index"]) for s in subtitle_streams if s.get("index") is not None)
    sub_indices_out = set(int(s["index"]) for s in out_s_streams if s.get("index") is not None)

    # Exact width, height, frame rate, display and sample aspect on each video stream
    for idx, sv in enumerate(video_streams):
        ov = out_v_streams[idx]
        if sv.get("width") != ov.get("width") or sv.get("height") != ov.get("height"):
            return bad(f"해상도 불일치 (원본: {sv.get('width')}x{sv.get('height')}, 생성: {ov.get('width')}x{ov.get('height')})")
        s_fps, o_fps = video_fps(sv), video_fps(ov)
        if o_fps is None or s_fps is None or not rel_close(s_fps, o_fps, Fraction(1, 2000)):
            if s_fps is not None and o_fps is not None and source_path:
                if not decoded_pres_verified:
                    begin("verify", f"{tag} 프레임레이트 정밀 검증 중 (디코딩 프레임 시간축 분석)")
                    decoded_pres_problem = verify_decoded_presentation_match(
                        source_path, out_path, video_streams, out_v_streams, audio_streams, out_a_streams,
                        allowed_other_src=sub_indices_src, allowed_other_out=sub_indices_out
                    )
                    decoded_pres_verified = True
                if decoded_pres_problem:
                    return bad(f"프레임레이트 검증 실패 (원본: {float(s_fps):.3f}, 생성: {float(o_fps):.3f}): {decoded_pres_problem}")
            else:
                s_fps_str = f"{float(s_fps):.3f}" if s_fps is not None else "알 수 없음"
                o_fps_str = f"{float(o_fps):.3f}" if o_fps is not None else "알 수 없음"
                return bad(f"프레임레이트 검증 실패 (원본: {s_fps_str}, 생성: {o_fps_str})")
        s_dar, o_dar = video_display_aspect(sv), video_display_aspect(ov)
        if o_dar is None or s_dar is None or not rel_close(s_dar, o_dar, Fraction(1, 500)):
            return bad("화면 비율 검증 실패 (원본과 생성 파일의 화면 비율이 다릅니다)")
        if not rel_close(sample_aspect(sv), sample_aspect(ov), Fraction(1, 500)):
            return bad("픽셀 비율(SAR) 검증 실패 (원본과 생성 파일의 픽셀 비율이 다릅니다)")
        if parse_rational(ov.get("time_base")) is None:
            return bad("생성된 비디오의 시간 기준 정보가 유효하지 않습니다.")

    # Channels and sample rate check on each audio stream (missing metadata fails closed)
    for idx, sa in enumerate(audio_streams):
        oa = out_a_streams[idx]
        if sa.get("channels") is None or sa.get("channels") != oa.get("channels"):
            return bad(f"오디오 채널 수 불일치 (원본: {sa.get('channels')}, 생성: {oa.get('channels')})")
        if not sa.get("sample_rate") or str(sa.get("sample_rate")) != str(oa.get("sample_rate")):
            return bad(f"오디오 샘플레이트 불일치 (원본: {sa.get('sample_rate')}, 생성: {oa.get('sample_rate')})")

    # Full decode pass with -xerror: decode errors and any error-level output (exit code 0 is not enough:
    # broken output timestamps are only reported on stderr). Cancellable, no arbitrary time cap
    decode_cmd = [
        FFMPEG, "-nostdin", "-v", "error", "-xerror", "-progress", "pipe:1", "-nostats",
        "-i", out_path,
        "-map", "0:v", "-map", "0:a?",
        "-f", "null", "-"
    ]
    rc, dec_err = run_cancellable_ffmpeg(decode_cmd, out_duration, begin(
        "decode", f"{tag} 전체 디코딩 검사 중", out_duration))
    if stop_requested:
        return bad("작업 중지 요청됨")
    if rc != 0:
        return bad(f"전체 디코딩 검사 실패: {dec_err[:200]}")
    if dec_err.strip():
        return bad(f"전체 디코딩 검사에서 오류 메시지가 출력되었습니다: {dec_err.strip()[-200:]}", True)
    return None, False, out_v_streams, out_a_streams, out_duration


def verify_external_output(
    source_path: str, out_path: str,
    report: Optional[Callable[[str, str, Optional[float], Optional[float]], None]] = None
) -> Tuple[bool, str, Dict[str, Any]]:
    """Acceptance check of an MP4 built by someone else (engine verify-candidate); out_path is only read. Nothing the
    builder says is used: the source plan, the strict verify_output and - when the SOURCE itself shows a recognised
    timestamp damage - the repaired-timeline check are all derived here. Returns (ok, message, info): on success info =
    {"duration_s", "timeline": "not_needed" | "verified"}; on failure info may carry {"reason"} for the timeline cases
    (timeline_incomplete / timeline_unsupported / timeline_damage_unrepairable / timeline_mismatch). An unanalysable source
    packet timeline is NEVER treated as "no damage": the candidate is refused."""
    begin = phase_announcer(report)
    begin("prepare", "원본 분석 중 (재생 시간·스트림 정보 확인)")
    src_probe = probe_file(source_path)
    try:
        src_duration, video_streams, audio_streams, subtitle_streams, _, _, _ = plan_from_probe(src_probe)
    except ValueError as e:
        return False, str(e), {}
    problem, _, out_v_streams, out_a_streams, out_duration = verify_output(
        out_path, src_duration, video_streams, audio_streams, subtitle_streams, "후보 파일", begin, source_path=source_path)
    if problem:
        return False, problem, {}

    begin("diagnose", "원본 타임스탬프 진단 중 (패킷 시간축 분석)")
    nav_indices = dvd_nav_stream_indices(src_probe)
    src_tl = probe_packet_timeline(source_path, exclude_streams=nav_indices, allow_genpts=is_avi_source(src_probe))
    if stop_requested:
        return False, "작업 중지 요청됨", {}
    if not src_tl:
        why = timeline_failure or "incomplete"
        return False, ("원본 패킷 시간축 분석을 완료하지 못해 후보를 검증할 수 없습니다: "
                       + ("분석이 불완전합니다(시간 초과·출력 한도·ffprobe 오류)" if why == "incomplete"
                          else "지원되지 않는 패킷 정보입니다(표시 시각이 없는 패킷 등)")), {"reason": f"timeline_{why}"}
    plan = plan_timing_repair(src_tl, src_duration, video_streams, audio_streams)
    ok_text = f"후보 MP4 검증 통과 / {CHECKS_PASSED_TEXT}"
    if nav_indices:
        ok_text += f" / {DVD_NAV_NOTE}"
    if any(s.get("pts_recovered") for s in src_tl.values()):
        ok_text += " / 원본 일부 패킷의 표시 시각(PTS) 누락을 -fflags +genpts 재분석으로 복원하고 원본 분석과 대조"
    if plan is None:
        damaged = (any(src_tl.get(sa.get("index")) and audio_clock_pattern(src_tl[sa["index"]], src_duration) for sa in audio_streams)
                   or any(video_dts_damage(src_tl.get(sv.get("index"))) for sv in video_streams))
        if damaged:  # a recognised damage that cannot be repaired safely is not "no damage"
            return False, "원본에 알려진 타임스탬프 손상이 있으나 안전하게 복구할 수 없는 형식이라 후보를 인정하지 않습니다", {
                "reason": "timeline_damage_unrepairable"}
        return True, ok_text, {"duration_s": out_duration, "timeline": "not_needed"}

    begin("timeline", "복구 결과 시간축 검증 중 (패킷 시간축 분석)")
    problem = repaired_timeline_problem(src_tl, probe_packet_timeline(out_path, exclude_streams=set()), src_duration,
                                        video_streams, audio_streams, out_v_streams, out_a_streams, plan[0])
    if stop_requested:
        return False, "작업 중지 요청됨", {}
    if problem:
        return False, f"타임라인 검증 실패: {problem}", {"reason": "timeline_mismatch"}
    return True, ok_text + " / 원본의 알려진 타임스탬프 손상에 대한 복구 시간축 검증 통과", {
        "duration_s": out_duration, "timeline": "verified"}


def convert_and_verify(
    source_path: str,
    temp_path: str,
    cand: Dict[str, Any],
    report: Optional[Callable[[str, str, Optional[float], Optional[float]], None]] = None
) -> Tuple[bool, str]:
    """Builds a portable MP4 (H.264 + AAC-LC): copies streams that already meet the policy, re-encodes the
    rest, and fails (keeping the original) when the policy cannot be met safely. Validates the result via
    a strict ffprobe policy check, fidelity metadata and a full decode pass.
    report(phase, label, position_s, total_s) tells the batch which step of THIS file is running (position/total only
    while ffmpeg reports real progress); it never influences the result."""
    global current_temp_file, current_target_dir

    begin = phase_announcer(report)

    def discard(reason: str) -> Tuple[bool, str]:
        safe_cleanup_temp_file(temp_path, current_target_dir or os.path.dirname(temp_path))
        return False, reason

    # 1+2. Probe the source and decide copy vs re-encode per stream BEFORE touching the disk; unsupported sources fail here
    begin("prepare", "원본 분석 중 (재생 시간·스트림 정보 확인)")
    src_probe = probe_file(source_path)
    try:
        src_duration, video_streams, audio_streams, subtitle_streams, codec_args, notes, copy_only = plan_from_probe(
            src_probe)
    except ValueError as e:
        return False, str(e)

    timing_symptom = False  # set when an attempt failed in a way a timestamp diagnostic may explain

    def attempt(args: List[str], repair: Optional[Tuple[Dict[int, Dict[str, Any]], List[int]]]) -> Tuple[bool, str]:
        """One build + full validation of the temp MP4. repair = (source packet timeline, audio positions rebuilt
        from the sample clock) marks the single timing-repair retry, which is also decoded with -xerror and has its
        own packet timeline verified."""
        nonlocal timing_symptom

        # Pre-create owned exclusive empty temp inode (identity tracked for cleanup)
        try:
            st_temp_init = create_temp_file(temp_path)
        except OSError as e:
            return False, f"임시 파일 독점 생성 실패: {e}"

        # 3. One ffmpeg run: all streams, metadata and chapters kept, no scaling and no frame-rate change
        cmd = (
            [FFMPEG, "-nostdin", "-y"] + (["-xerror"] if repair else []) + ["-progress", "pipe:1", "-nostats", "-i", source_path,
             "-map", "0:v", "-map", "0:a?", "-map", "0:s?",
             "-map_metadata", "0", "-map_chapters", "0"]
            + args
            + ["-fps_mode", "passthrough", "-movflags", "+faststart", temp_path]
        )
        print(f"Building compatible MP4 for {source_path} "
              f"({'timing repair' if repair else 'stream copy' if copy_only else 'partial re-encode'})")
        tag = "복구 결과" if repair else "결과 파일"
        rc, err = run_cancellable_ffmpeg(cmd, src_duration, begin(
            "repair" if repair else "convert",
            "타임스탬프 복구 재변환 중" if repair else
            "MP4 변환 중 (영상·음성 복사)" if copy_only else "MP4 변환 중 (일부 다시 인코딩)", src_duration))

        if stop_requested:
            return discard("작업 중지 요청됨")
        if rc != 0:
            return discard(f"변환 실패: {err[:200]}")

        # Verify temp inode identity has not been replaced
        try:
            st_temp_post = os.lstat(temp_path)
            if (st_temp_post.st_ino != st_temp_init.st_ino or
                    st_temp_post.st_dev != st_temp_init.st_dev or
                    st_temp_post.st_uid != ALLOWED_REQUEST_UID or
                    st_temp_post.st_size == 0):
                return discard("임시 파일 보안 무결성 검증 실패 (inode 또는 크기 불일치)")
        except OSError as e:
            return discard(f"임시 파일 상태 확인 실패: {e}")

        # 4. Validation of the generated MP4 (the same verifier that checks candidates built elsewhere)
        problem, symptom, out_v_streams, out_a_streams, _ = verify_output(
            temp_path, src_duration, video_streams, audio_streams, subtitle_streams, tag, begin, source_path=source_path)
        if problem:
            timing_symptom = timing_symptom or symptom
            return discard(problem)

        # Repaired output: its own packet timeline must show continuous audio of the sample-clock length
        if repair:
            begin("timeline", "복구 결과 시간축 검증 중 (패킷 시간축 분석)")
            problem = repaired_timeline_problem(repair[0], probe_packet_timeline(temp_path, exclude_streams=set()), src_duration,
                                                video_streams, audio_streams, out_v_streams, out_a_streams, repair[1])
            if stop_requested:
                return discard("작업 중지 요청됨")
            if problem:
                return discard(f"타임라인 검증 실패: {problem}")
        return True, ""

    checks = CHECKS_PASSED_TEXT
    ok, msg = attempt(codec_args, None)
    if ok:
        if copy_only:
            actions = ["영상·음성은 다시 인코딩하지 않고 복사"]
            if DVD_NAV_NOTE in notes:
                actions.append(DVD_NAV_NOTE)
            return True, "호환 MP4(H.264 + AAC) 생성: " + ", ".join(actions) + " / " + checks
        return True, ("호환 MP4(H.264 + AAC) 생성: " + ", ".join(notes)
                      + " / " + checks + ". 다시 인코딩한 부분은 원본과 완전히 동일하지 않습니다")
    if not timing_symptom or stop_requested:
        return False, msg

    # Duration mismatch or decode-time timestamp errors: confirm a recognised source timestamp damage before ONE retry
    begin("diagnose", "원본 타임스탬프 진단 중 (패킷 시간축 분석)")
    nav_indices = dvd_nav_stream_indices(src_probe)
    src_tl = probe_packet_timeline(source_path, exclude_streams=nav_indices, allow_genpts=is_avi_source(src_probe))
    if stop_requested:
        return False, "작업 중지 요청됨"
    plan = plan_timing_repair(src_tl, src_duration, video_streams, audio_streams) if src_tl else None
    if plan is None:
        return False, msg + " (원본 타임스탬프 진단: 복구 가능한 알려진 손상 패턴이 아니어서 원본을 유지합니다)"
    fix_audio, fix_video = plan
    try:
        args2, _, _ = plan_streams(video_streams, audio_streams, subtitle_streams, force_video_reencode=fix_video)
    except ValueError as e:
        return False, f"{msg} (타임스탬프 복구 불가: {e})"
    for i in fix_audio:
        args2 += [f"-filter:a:{i}", "asetpts=N/SR/TB+STARTPTS"]
    ok, msg2 = attempt(args2, (src_tl, fix_audio))
    if not ok:
        return False, f"{msg} / 타임스탬프 복구 재시도도 실패: {msg2}"
    repairs = [f"오디오 {i + 1}: 원본의 ±65.536초 시계 점프를 확인하여 샘플 수 기준으로 시간축 재구성(시작 오프셋·길이·속도 유지)"
               for i in fix_audio]
    if fix_video:
        repairs.append("영상: 디코딩 시각(DTS)이 어긋난 원본을 표시 시각 그대로 다시 인코딩")
    if DVD_NAV_NOTE in notes or nav_indices:
        repairs.append(DVD_NAV_NOTE)
    return True, ("호환 MP4(H.264 + AAC) 생성(타임스탬프 복구): " + ", ".join(repairs)
                  + " / " + checks + ". 다시 인코딩·재구성한 부분은 원본과 완전히 동일하지 않습니다")


def commit_conversion(
    is_mp4: bool, cand_path: str, final_path: str, backup_path: str, temp_path: str,
    st_src: os.stat_result, st_temp: os.stat_result, validated_target: str
) -> Tuple[str, str, bool]:
    """Publishes the fully validated and fsynced temp MP4 and keeps the original as STEM_원본.ext in the same
    folder. Every step is an exclusive create (hard link) or a removal that happens only after the original is
    durably linked under its backup name; nothing is ever overwritten or deleted otherwise.
      legacy source: result MP4 first, then backup link, then the old name is removed.
      MP4 source:    backup link first, old name removed, then the result is published under the freed name;
                     if that fails the old name is restored (again exclusive, no overwrite).
    Returns (outcome, message, keep_temp): 'done'; 'failed' (the original name still holds the original file);
    'partial' (it does not - the message states the actual state). A stop request is not honoured inside this
    short transaction (SIGTERM waits for it)."""
    global commit_active
    cand_dir = os.path.dirname(cand_path)
    cand_name, final_name, backup_name = (os.path.basename(p) for p in (cand_path, final_path, backup_path))
    phase = "준비"
    final_published = final_durable = backup_made = backup_durable = final_removed = restored = False
    restore_error = ""
    commit_active = True

    def finish_publish(stat_from: str) -> None:
        nonlocal final_durable
        try:
            shutil.copystat(stat_from, final_path)  # original's timestamps and mode; best effort
        except OSError:
            pass
        fsync_file(final_path)
        st = os.lstat(final_path)
        if (stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or not same_inode(st, st_temp)
                or st.st_size != st_temp.st_size):
            raise RuntimeError("게시된 MP4가 검증한 임시 파일과 다릅니다")
        fsync_dir(cand_dir)
        final_durable = True

    try:
        revalidate_source_parent(cand_path, validated_target)
        dir_index = list_dir_index(cand_dir)
        if dir_index is None or name_conflicts(dir_index, [final_name, backup_name], cand_name if is_mp4 else None):
            raise RuntimeError("같은 이름의 파일이 이미 있거나 폴더를 읽을 수 없습니다(덮어쓰지 않음)")
        require_snapshot(cand_path, st_src, "원본 파일")
        require_snapshot(temp_path, st_temp, "변환 결과 임시 파일")

        if not is_mp4:
            phase = "새 MP4 게시"
            os.link(temp_path, final_path)  # exclusive: fails if the name exists
            final_published = True
            finish_publish(cand_path)

        phase = "원본 보관 링크(_원본) 생성"
        require_snapshot(cand_path, st_src, "원본 파일")
        os.link(cand_path, backup_path)  # exclusive: fails if the backup name exists
        backup_made = True
        require_snapshot(backup_path, st_src, "보관된 원본(_원본)")
        fsync_file(backup_path)
        fsync_dir(cand_dir)
        backup_durable = True  # only now may the old name go

        phase = "원래 이름 제거"
        require_snapshot(cand_path, st_src, "원본 파일")
        require_snapshot(backup_path, st_src, "보관된 원본(_원본)")
        os.unlink(cand_path)
        fsync_dir(cand_dir)

        if is_mp4:
            phase = "새 MP4 게시"
            require_snapshot(temp_path, st_temp, "변환 결과 임시 파일")
            os.link(temp_path, final_path)  # exclusive: the freed name must still be free
            final_published = True
            finish_publish(backup_path)

        phase = "최종 확인"
        require_snapshot(backup_path, st_src, "보관된 원본(_원본)")
        if not same_inode(os.lstat(final_path), st_temp):
            raise RuntimeError("결과 MP4를 확인하지 못했습니다")
        if not is_mp4 and original_name_state(cand_path, st_src) != "missing":
            raise RuntimeError("원래 이름이 아직 남아 있습니다")
        return "done", f"원본은 같은 폴더에서 {backup_name}(으)로 이름이 바뀌어 보존됨 (삭제하지 않음)", False
    except Exception as e:
        err = f"{phase} 단계에서 오류: {e}"
        name_state = original_name_state(cand_path, st_src)
        if is_mp4 and name_state == "missing" and backup_durable and not final_published:
            try:  # the old name was freed but the result could not take it: put the original back, no overwrite
                os.link(backup_path, cand_path)
                fsync_dir(cand_dir)
                restored = True
            except Exception as re_err:
                restore_error = str(re_err)
            name_state = original_name_state(cand_path, st_src)
        if not is_mp4 and final_published and not final_durable and name_state == "intact":
            try:  # a result that could not be made durable is withdrawn again (only the exact inode we created)
                st_f = os.lstat(final_path)
                if same_inode(st_f, st_temp) and not stat.S_ISLNK(st_f.st_mode):
                    os.unlink(final_path)
                    final_removed = True
                    fsync_dir(cand_dir)
            except OSError:
                pass
        facts = [{
            "intact": "원래 이름에는 원본이 그대로 있습니다",
            "missing": f"원래 이름({cand_name}) 위치가 비어 있습니다",
            "replaced": ("원래 이름 위치에 새 MP4가 있습니다" if is_mp4 and final_published
                         else "원래 이름 위치에 원본이 아닌 다른 파일이 있습니다"),
            "unknown": "원래 이름의 상태를 확인하지 못했습니다",
        }[name_state]]
        if restored:
            facts.append("원래 이름을 복구했습니다")
        elif restore_error:
            facts.append(f"원래 이름 복구에 실패했습니다({restore_error})")
        if backup_durable:
            facts.append(f"원본 데이터는 {backup_name}에 보존되어 있습니다(삭제하지 않음)")
        elif backup_made:
            facts.append(f"{backup_name} 링크가 만들어졌으나 원본과 일치하거나 디스크에 저장됐는지 확인하지 못했습니다(직접 확인 필요, 삭제하지 않음)")
        if final_removed:
            facts.append("디스크 저장을 확인하지 못한 새 MP4는 다시 제거했습니다")
        elif final_published:
            facts.append(f"새 MP4({final_name})는 있으나 디스크 저장 확인은 {'완료' if final_durable else '실패'}했습니다")
        keep_temp = is_mp4 and name_state == "missing" and not final_published
        outcome = "failed" if name_state == "intact" else "partial"
        return outcome, err + " / " + "; ".join(facts), keep_temp
    finally:
        commit_active = False


def reject_start(reason: str) -> None:
    """Start refused before anything was touched: say so in the status the UI shows."""
    sys.stderr.write(f"Start rejected: {reason}\n")
    try:
        update_status(state="idle", stage="변환 시작이 거부되었습니다 (원본은 변경되지 않음): " + safe_text(reason, 300),
                      batch_id=None, error=safe_text(reason, 300))
    except Exception as e:
        sys.stderr.write(f"Cannot write rejection status: {e}\n")


def handle_start(req_path: str, req_data: Dict[str, Any], req_uid: int) -> None:
    global active_batch_id, stop_requested, current_temp_file, current_target_dir

    if active_batch_id is not None:
        sys.stderr.write("Start rejected: another batch is already running.\n")
        return

    scan_uuid = req_data.get("scan_uuid")
    batch_id = req_data.get("batch_id") or scan_uuid
    mp4_check = req_data.get("mp4_check")

    # Originals are never deleted or moved away any more: an old-style request (remove_originals) is refused, not honoured.
    if "remove_originals" in req_data:
        reject_start("이전 버전의 시작 요청입니다(원본 보관함 이동/삭제 옵션 remove_originals). 0.3.0은 원본을 이름만 바꿔 같은 폴더에 둡니다. 앱을 새로 고침하십시오.")
        return
    if set(req_data) - START_KEYS or req_data.get("policy") != POLICY or not isinstance(mp4_check, bool):
        reject_start("시작 요청의 형식 또는 처리 정책 버전이 이 워커와 맞지 않습니다. 앱을 새로 고침하고 다시 검사하십시오.")
        return
    if (not isinstance(scan_uuid, str) or not isinstance(batch_id, str)
            or not UUID_REGEX.match(scan_uuid) or not UUID_REGEX.match(batch_id)):
        reject_start("시작 요청의 작업 ID 형식이 올바르지 않습니다.")
        return

    scan_file = os.path.join(QUEUE_DIR, f"scan-{scan_uuid}.json")
    scan_data = read_json_file(scan_file, MAX_JSON_SIZE)
    if not scan_data:
        reject_start("검사 결과 파일을 읽을 수 없습니다. 다시 검사하십시오.")
        return

    if (scan_data.get("uuid") != scan_uuid or scan_data.get("owner_uid") != req_uid
            or req_uid != ALLOWED_REQUEST_UID):
        reject_start("검사 결과의 작업 ID 또는 요청자가 일치하지 않습니다.")
        return

    if (scan_data.get("schema") != MANIFEST_SCHEMA or scan_data.get("worker_version") != WORKER_VERSION
            or scan_data.get("policy") != POLICY):
        reject_start("이전 버전의 검사 결과이거나 처리 정책이 다릅니다. 다시 검사하십시오.")
        return

    if scan_data.get("mp4_check") is not mp4_check:
        reject_start("시작 요청의 MP4 호환 검사 옵션이 검사 때의 옵션과 다릅니다. 다시 검사하십시오.")
        return

    if scan_data.get("complete") is not True:
        reject_start("검사 결과가 불완전합니다(오류, 취소 또는 파일 수 초과). 다시 검사하십시오.")
        return

    # Exact target list: the start request, the manifest and the live filesystem must all agree.
    folders = req_data.get("folders")
    roots = scan_data.get("roots")
    if (not isinstance(folders, list) or not 1 <= len(folders) <= MAX_FOLDERS
            or not all(isinstance(f, str) for f in folders)
            or folders != scan_data.get("folders")
            or not isinstance(roots, list) or len(roots) != len(folders)):
        reject_start("시작 요청의 폴더 목록이 검사한 폴더 목록과 일치하지 않습니다. 다시 검사하십시오.")
        return
    conflict = folder_list_conflicts(folders)
    if conflict:
        reject_start(conflict)
        return
    roots_c: List[str] = []
    for folder, root in zip(folders, roots):
        try:
            share, cpath, st_root = resolve_folder(folder)
        except Exception as e:
            reject_start(f"{folder}: {e}")
            return
        if (not isinstance(root, dict) or root.get("folder") != folder or root.get("share") != share
                or root.get("dev") != st_root.st_dev or root.get("ino") != st_root.st_ino):
            reject_start(f"검사 이후 선택한 폴더가 바뀌었습니다: {folder}. 다시 검사하십시오.")
            return
        roots_c.append(cpath)

    candidates = scan_data.get("candidates")
    if not isinstance(candidates, list) or len(candidates) > MAX_SCAN_FILES:
        reject_start("검사 항목이 올바르지 않거나 너무 많습니다.")
        return
    total_files = len(candidates)
    active_batch_id = batch_id
    current_target_dir = None
    stop_requested = False

    update_status(
        state="running",
        stage="변환 작업 시작 준비",
        batch_id=batch_id,
        current_file="",
        progress_pct=0,
        total=total_files,
        completed=0,
        failed=0,
        skipped=0,
        cleanup_pending=0,
        error=None,
        details=[],
        folder_total=len(folders)
    )

    completed_count = 0
    failed_count = 0
    skipped_count = 0
    cleanup_pending_count = 0
    details: List[Dict[str, Any]] = []
    seen_cands = set()
    halt_reason: Optional[str] = None  # the first failure stops the whole batch; later files are left untouched

    for idx, cand in enumerate(candidates):
        check_incoming_stop()
        if stop_requested:
            break

        # Validate candidate metadata types, display-path/filename binding and kind/extension
        cand_disp = cand.get("path") if isinstance(cand, dict) else None
        cand_name = cand.get("filename") if isinstance(cand, dict) else None
        root_idx = cand.get("root") if isinstance(cand, dict) else None
        kind = cand.get("kind") if isinstance(cand, dict) else None
        shown = safe_text(str(cand_disp), 300)
        if (not isinstance(cand_disp, str) or not isinstance(cand_name, str)
                or type(root_idx) is not int or not 0 <= root_idx < len(roots_c)
                or os.path.normpath(cand_disp) != cand_disp
                or os.path.basename(cand_disp) != cand_name
                or not candidate_kind_ok(kind, cand_name)
                or (kind == "mp4" and not mp4_check)
                or not all(type(cand.get(k)) is int for k in ("size", "mtime_ns", "inode", "dev"))):
            skipped_count += 1
            details.append({"file": shown, "status": "skipped", "message": "스캔 항목 형식이 올바르지 않아 건너뜀"})
            continue
        is_mp4 = kind == "mp4"
        stem, ext = os.path.splitext(cand_name)
        if cand_name.startswith((".", "@")) or is_backup_stem(stem):
            skipped_count += 1
            details.append({"file": shown, "status": "skipped", "message": "이미 _원본 이름이거나 숨김·시스템 이름이라 건너뜀"})
            continue

        # Map display path -> container path; it must lie strictly inside its own selected root
        validated_target = roots_c[root_idx]
        try:
            share, cand_path = display_to_container(cand_disp)
            if not cand_path.startswith(validated_target + "/") or cand_path in seen_cands:
                raise ValueError("선택한 폴더 범위를 벗어났거나 중복된 항목입니다")
            seen_cands.add(cand_path)
        except ValueError as e:
            skipped_count += 1
            details.append({"file": shown, "status": "skipped", "message": f"경로 검증 실패: {e}"})
            continue
        current_target_dir = validated_target
        cand_dir = os.path.dirname(cand_path)

        pct = int((idx / max(total_files, 1)) * 100)
        update_status(
            state="running",
            stage=f"변환 처리 중 ({idx + 1}/{total_files})",
            batch_id=batch_id,
            current_file=shown,
            progress_pct=pct,
            total=total_files,
            completed=completed_count,
            failed=failed_count,
            skipped=skipped_count,
            cleanup_pending=cleanup_pending_count,
            details=details,
            current_folder=folders[root_idx],
            folder_index=root_idx + 1,
            folder_total=len(folders)
        )

        # 1. Validate candidate path within its share AND selected folder without symlinks
        try:
            validate_path_components_pre_realpath(cand_path)
            real_cand = os.path.realpath(cand_path)
            if not real_cand.startswith(validated_target + os.sep) and real_cand != validated_target:
                skipped_count += 1
                details.append({"file": shown, "status": "skipped", "message": "스캔된 대상 폴더 범위를 벗어남"})
                continue
        except Exception as e:
            skipped_count += 1
            details.append({"file": shown, "status": "skipped", "message": f"경로 보안 검증 실패: {e}"})
            continue

        # 2. Stable source check before encode
        try:
            st_pre = os.lstat(cand_path)
            if not stat.S_ISREG(st_pre.st_mode) or stat.S_ISLNK(st_pre.st_mode):
                skipped_count += 1
                details.append({"file": shown, "status": "skipped", "message": "정규 파일이 아니거나 심볼릭 링크임"})
                continue
            # Source ownership is not restricted (NAS ACLs); require read access and write access to its folder
            if not os.access(cand_path, os.R_OK) or not os.access(cand_dir, os.W_OK | os.X_OK):
                skipped_count += 1
                details.append({"file": shown, "status": "skipped", "message": "파일 읽기 또는 폴더 쓰기 권한이 없음"})
                continue
            if (st_pre.st_size != cand.get("size") or
                    st_pre.st_mtime_ns != cand.get("mtime_ns") or
                    st_pre.st_ino != cand.get("inode") or
                    st_pre.st_dev != cand.get("dev")):
                skipped_count += 1
                details.append({"file": shown, "status": "skipped", "message": "스캔 이후 원본 파일이 변경됨"})
                continue
        except OSError as e:
            failed_count += 1
            details.append({"file": shown, "status": "failed", "message": f"원본 파일 접근 불가: {e}"})
            halt_reason = f"{shown}: {details[-1]['message']}"
            break

        # 3. Names: result and backup must both be free (case-insensitively); an MP4 may only collide with itself
        final_name, backup_name = output_names(cand_name, is_mp4)
        final_path = os.path.join(cand_dir, final_name)
        backup_path = os.path.join(cand_dir, backup_name)
        temp_filename = f".{stem}.{uuid.uuid4().hex[:8]}.tmp.mp4"
        if any(len(n.encode("utf-8")) > MAX_NAME_BYTES for n in (backup_name, temp_filename)):
            skipped_count += 1
            details.append({"file": shown, "status": "skipped", "message": "파일 이름이 너무 길어 _원본 이름을 만들 수 없어 건너뜀"})
            continue
        dir_index = list_dir_index(cand_dir)
        if dir_index is None or name_conflicts(dir_index, [final_name, backup_name], cand_name if is_mp4 else None):
            skipped_count += 1
            details.append({"file": shown, "status": "skipped",
                            "message": "같은 이름의 MP4 또는 _원본 파일이 이미 있거나 폴더를 읽을 수 없어 건너뜀 (덮어쓰지 않음)"})
            continue

        # 4. Same-folder temporary MP4: the original is not touched until this one is fully validated
        temp_path = os.path.join(cand_dir, temp_filename)
        current_temp_file = temp_path

        def report_phase(phase: str, label: str, pos: Optional[float] = None, total: Optional[float] = None) -> None:
            """Current-file step for the UI: same batch context and aggregate counts as above, plus the phase fields."""
            update_status(
                state="running",
                stage=f"변환 처리 중 ({idx + 1}/{total_files})",
                batch_id=batch_id,
                current_file=shown,
                progress_pct=pct,
                total=total_files,
                completed=completed_count,
                failed=failed_count,
                skipped=skipped_count,
                cleanup_pending=cleanup_pending_count,
                details=details,
                current_folder=folders[root_idx],
                folder_index=root_idx + 1,
                folder_total=len(folders),
                phase=phase,
                phase_label=label,
                phase_pos_s=pos,
                phase_total_s=total
            )

        success, msg = convert_and_verify(cand_path, temp_path, cand, report_phase)

        if stop_requested:
            safe_cleanup_temp_file(temp_path, validated_target)
            current_temp_file = None
            break

        if not success:
            failed_count += 1
            details.append({"file": shown, "status": "failed", "message": msg})
            safe_cleanup_temp_file(temp_path, validated_target)
            current_temp_file = None
            halt_reason = f"{shown}: {details[-1]['message']}"
            break

        # 5. Source snapshot check after encode (the file is not finished until the commit below succeeds)
        report_phase("commit", "검사 통과 · 결과 저장 및 원본 보관(_원본) 처리 중")
        try:
            st_post = os.lstat(cand_path)
            if (st_post.st_size != st_pre.st_size or
                    st_post.st_mtime_ns != st_pre.st_mtime_ns or
                    st_post.st_ino != st_pre.st_ino or
                    st_post.st_dev != st_pre.st_dev):
                failed_count += 1
                details.append({"file": shown, "status": "failed", "message": "변환 도중 원본 파일이 변경되어 취소됨 (원본 이름은 그대로)"})
                safe_cleanup_temp_file(temp_path, validated_target)
                current_temp_file = None
                halt_reason = f"{shown}: {details[-1]['message']}"
                break
        except OSError as e:
            failed_count += 1
            details.append({"file": shown, "status": "failed", "message": f"변환 후 원본 상태 확인 실패: {e}"})
            safe_cleanup_temp_file(temp_path, validated_target)
            current_temp_file = None
            halt_reason = f"{shown}: {details[-1]['message']}"
            break

        # 6. The validated temp MP4 must be on disk before anything is renamed; fsync errors fail closed
        try:
            fsync_file(temp_path)
            st_temp = os.lstat(temp_path)
            if (not stat.S_ISREG(st_temp.st_mode) or stat.S_ISLNK(st_temp.st_mode) or st_temp.st_size == 0
                    or (st_temp.st_dev, st_temp.st_ino) != temp_identities.get(os.path.normpath(temp_path))
                    or st_temp.st_uid != ALLOWED_REQUEST_UID):
                raise RuntimeError("임시 파일이 바뀌었거나 비어 있습니다")
        except Exception as e:
            failed_count += 1
            details.append({"file": shown, "status": "failed", "message": f"변환 결과 임시 파일 저장 확인 실패 (원본 이름은 그대로): {e}"})
            safe_cleanup_temp_file(temp_path, validated_target)
            current_temp_file = None
            halt_reason = f"{shown}: {details[-1]['message']}"
            break

        # 7. Publish + keep the original as STEM_원본.ext (see commit_conversion); never deletes anything
        outcome, commit_msg, keep_temp = commit_conversion(
            is_mp4, cand_path, final_path, backup_path, temp_path, st_pre, st_temp, validated_target)
        if keep_temp:
            # Only copy of the converted data (original name vacated, restore impossible): deliberately kept
            temp_identities.pop(os.path.normpath(temp_path), None)
            commit_msg += f" / 변환 결과 임시 파일: {container_to_display(temp_path)}"
        else:
            safe_cleanup_temp_file(temp_path, validated_target)
        current_temp_file = None

        if outcome == "done":
            completed_count += 1
            details.append({"file": shown, "status": "completed", "message": f"{msg} / {commit_msg}"})
        elif outcome == "failed":
            failed_count += 1
            details.append({"file": shown, "status": "failed", "message": commit_msg})
            halt_reason = f"{shown}: {commit_msg}"
            break
        else:
            cleanup_pending_count += 1
            details.append({"file": shown, "status": "partial_rename", "message": commit_msg})
            halt_reason = f"{shown}: 원본 이름 변경이 일부만 진행됨 - {commit_msg}"
            break

    # Finalize status
    counts_text = f"완료 {completed_count}건, 건너뜀 {skipped_count}건, 실패 {failed_count}건, 확인 필요(이름 변경 일부만 진행) {cleanup_pending_count}건"
    if stop_requested:
        final_state = "stopped"
        final_stage = f"사용자에 의해 작업이 중지되었습니다. ({counts_text})"
    elif halt_reason:
        final_state = "halted"
        final_stage = (f"첫 실패에서 일괄 작업을 중단했습니다. 남은 {total_files - idx - 1}개는 처리하지 않았고 건드리지 않았습니다. "
                       f"마지막 파일의 실제 상태는 사유와 처리 내역을 확인하십시오. 사유: {halt_reason} ({counts_text})")
    elif failed_count > 0:
        final_state = "completed_with_errors"
        final_stage = f"일부 파일 변환 실패 ({counts_text})"
    elif cleanup_pending_count > 0 or skipped_count > 0:
        final_state = "completed_with_warnings"
        final_stage = f"완료되었으나 확인이 필요한 항목이 있습니다. ({counts_text})"
    else:
        final_state = "completed"
        final_stage = (f"모든 대상의 변환과 파일 검사가 끝났습니다. 원본은 삭제하지 않고 같은 폴더에서 이름 뒤에 {BACKUP_SUFFIX}을 붙여 "
                       f"두었습니다. 실제 재생은 직접 확인하십시오. ({counts_text})")

    processed_count = completed_count + skipped_count + failed_count + cleanup_pending_count
    final_pct = 100 if final_state == "completed" else int((processed_count / max(total_files, 1)) * 100)

    update_status(
        state=final_state,
        stage=final_stage,
        batch_id=batch_id,
        current_file="",
        progress_pct=final_pct,
        total=total_files,
        completed=completed_count,
        failed=failed_count,
        skipped=skipped_count,
        cleanup_pending=cleanup_pending_count,
        error=halt_reason,
        details=details,
        folder_total=len(folders)
    )

    active_batch_id = None
    current_target_dir = None
    stop_requested = False


def check_incoming_stop() -> None:
    global stop_requested, active_batch_id, current_process, current_temp_file, current_target_dir
    if poll_hook is not None:
        poll_hook()
        return
    if not active_batch_id:
        return

    try:
        for fname in os.listdir(QUEUE_DIR):
            m = REQ_FILENAME_REGEX.match(fname)
            if not m or m.group(1) != "stop":
                continue

            req_path = os.path.join(QUEUE_DIR, fname)
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
            try:
                fd = os.open(req_path, flags)
            except OSError:
                continue

            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != ALLOWED_REQUEST_UID or st.st_size > MAX_REQ_SIZE:
                    continue
                req_data = read_json_fd(fd)
            finally:
                try:
                    os.close(fd)
                except OSError:
                    pass

            if not req_data:
                continue

            if (req_data.get("action") == "stop" and req_data.get("uuid") == m.group(2)
                    and req_data.get("batch_id") == active_batch_id):
                print(f"Stop request confirmed for active batch {active_batch_id}")
                # Only flag the stop: the running poll loop kills and WAITS for ffmpeg, then the
                # batch loop removes the exact temp inode it created (never unlink while ffmpeg runs).
                stop_requested = True
                try:
                    os.unlink(req_path)
                except OSError:
                    pass
                break
    except OSError:
        pass


def handle_stop(req_path: str, req_data: Dict[str, Any], req_uid: int) -> None:
    global active_batch_id, stop_requested, current_process, current_temp_file, current_target_dir
    target_batch = req_data.get("batch_id")
    if target_batch and target_batch == active_batch_id:
        print(f"Executing stop for active batch {active_batch_id}")
        stop_requested = True
    else:
        print(f"Stop request ignored: target batch '{target_batch}' != active batch '{active_batch_id}'")


def process_queue() -> None:
    """Scans QUEUE_DIR for valid *.req.json files safely using O_NOFOLLOW and fstat."""
    try:
        entries = sorted(os.listdir(QUEUE_DIR))
    except OSError as e:
        sys.stderr.write(f"Cannot read queue directory {QUEUE_DIR}: {e}\n")
        return

    for fname in entries:
        if shutdown_requested:
            return
        m = REQ_FILENAME_REGEX.match(fname)
        if not m:
            continue

        action_prefix = m.group(1)
        req_uuid = m.group(2)
        req_path = os.path.join(QUEUE_DIR, fname)

        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        try:
            fd = os.open(req_path, flags)
        except OSError as e:
            sys.stderr.write(f"Cannot open {fname} safely (symlink or permission): {e}\n")
            continue

        req_data = None
        req_uid = 0
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                sys.stderr.write(f"Security: rejected non-regular file {fname}\n")
                continue
            if st.st_uid != ALLOWED_REQUEST_UID or st.st_uid <= 0:
                sys.stderr.write(
                    f"Security: {fname} owned by UID {st.st_uid}, expected {ALLOWED_REQUEST_UID}. Rejecting.\n"
                )
                continue
            if st.st_size > MAX_REQ_SIZE:
                sys.stderr.write(f"Security: {fname} size ({st.st_size}) exceeds limit ({MAX_REQ_SIZE}). Rejecting.\n")
                continue

            req_uid = st.st_uid
            req_data = read_json_fd(fd, MAX_REQ_SIZE)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass

        if not req_data:
            sys.stderr.write(f"Invalid JSON in {fname}, moving to error\n")
            try:
                os.replace(req_path, os.path.join(QUEUE_DIR, f"{fname}.error"))
            except OSError:
                pass
            continue

        # Strict ID and Action binding
        action = req_data.get("action")
        payload_uuid = req_data.get("uuid")
        if action != action_prefix or payload_uuid != req_uuid:
            sys.stderr.write(f"Security: filename/payload mismatch in {fname}. Rejecting.\n")
            try:
                os.replace(req_path, os.path.join(QUEUE_DIR, f"{fname}.rejected"))
            except OSError:
                pass
            continue

        print(f"Processing request action='{action}' uuid='{req_uuid}' from {fname}")

        if action == "scan":
            try:
                handle_scan(req_path, req_data, req_uid)
            finally:
                # Always consume the request so a failing scan can never loop forever
                try:
                    os.unlink(req_path)
                except OSError:
                    pass
        elif action == "start":
            try:
                os.unlink(req_path)
            except OSError:
                pass
            handle_start(req_path, req_data, req_uid)
        elif action == "stop":
            handle_stop(req_path, req_data, req_uid)
            try:
                os.unlink(req_path)
            except OSError:
                pass
        else:
            sys.stderr.write(f"Unknown action '{action}' in {fname}\n")
            try:
                os.replace(req_path, os.path.join(QUEUE_DIR, f"{fname}.unknown"))
            except OSError:
                pass


def on_sigterm(signum: int, frame: Any) -> None:
    global stop_requested, shutdown_requested, current_process, current_temp_file, current_target_dir
    print("SIGTERM received, shutting down gracefully...")
    stop_requested = True
    shutdown_requested = True
    if commit_active:
        # Never exit between "old name freed" and "result published": the short transaction finishes first,
        # then the batch loop stops and the main loop exits.
        return
    terminate_current_process()  # kill and wait BEFORE touching the temp file
    if current_temp_file:
        safe_cleanup_temp_file(current_temp_file, current_target_dir or os.path.dirname(current_temp_file))
        current_temp_file = None
    sys.exit(0)


def main() -> None:
    global active_batch_id, stop_requested, current_temp_file, current_target_dir
    if ENGINE_MODE:
        sys.exit("FATAL: worker.py was loaded as an engine library and cannot run the queue worker.")
    signal.signal(signal.SIGTERM, on_sigterm)
    signal.signal(signal.SIGINT, on_sigterm)

    print(f"MP4Assistant Companion Worker started.")
    print(f"Allowed Request UID: {ALLOWED_REQUEST_UID}")
    print(f"Configured shares: {sorted(SHARES)}; connected (mounted): {CONNECTED_SHARES}; Queue Dir: {QUEUE_DIR}")

    init_queue_dir()
    acquire_worker_lock()

    # Startup & Interruption Recovery check. The status file is ALWAYS rewritten here so the UI sees the
    # current worker_version / connected shares even if the previous state is carried over unchanged.
    saved_state = read_json_file(STATE_FILE, MAX_JSON_SIZE) if os.path.exists(STATE_FILE) else None
    if saved_state and saved_state.get("state") == "running":
        print("Detected previously running batch interrupted by restart. Marking as interrupted.")
        saved_state["state"] = "interrupted"
        saved_state["stage"] = "워커 재시작으로 인해 이전 작업이 중단되었습니다."
        saved_state["error"] = ("이전 작업이 워커 재시작으로 인해 중단되었습니다. 이름 변경 도중이었다면 해당 폴더에 "
                                f"{BACKUP_SUFFIX} 파일이 보존되어 있을 수 있으니 확인한 뒤, 새로 검사하여 다시 시작하십시오.")
    elif not saved_state or saved_state.get("state") == "scanning":
        saved_state = {"state": "idle", "stage": "대기 중 (새 검사 요청 대기)"}
    try:
        update_status(
            state=str(saved_state.get("state", "idle")),
            stage=str(saved_state.get("stage", "")),
            batch_id=saved_state.get("batch_id"),
            current_file="",
            progress_pct=int(saved_state.get("progress_pct", 0)),
            total=int(saved_state.get("total", 0)),
            completed=int(saved_state.get("completed", 0)),
            failed=int(saved_state.get("failed", 0)),
            skipped=int(saved_state.get("skipped", 0)),
            cleanup_pending=int(saved_state.get("cleanup_pending", 0)),
            error=saved_state.get("error"),
            details=saved_state.get("details") if isinstance(saved_state.get("details"), list) else []
        )
    except (ValueError, TypeError):
        update_status(state="idle", stage="대기 중 (새 검사 요청 대기)")

    # Main worker event loop
    while not shutdown_requested:
        try:
            process_queue()
        except Exception as e:
            sys.stderr.write(f"Unhandled error in main loop: {e}\n")
            if active_batch_id is not None:
                # Never stay stuck in "running": report the batch as interrupted and keep originals.
                terminate_current_process()
                if current_temp_file:
                    safe_cleanup_temp_file(current_temp_file, current_target_dir or os.path.dirname(current_temp_file))
                    current_temp_file = None
                try:
                    update_status(state="interrupted", stage="작업 중 예기치 않은 오류로 중단되었습니다.",
                                  batch_id=active_batch_id, error=str(e)[:200])
                except Exception:
                    pass
                active_batch_id = None
                current_target_dir = None
                stop_requested = False
        time.sleep(2)


if __name__ == "__main__":
    main()
