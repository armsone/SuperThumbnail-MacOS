#!/usr/bin/env python3
"""
MP4Assistant shared engine CLI: one bounded job per process, used by the Mac helper (encode-local) and by the NAS
coordinator (verify-candidate). It reuses worker.py's convert_and_verify / verify_output unchanged and adds only the
request, workspace, hashing, progress and cancellation plumbing. It never renames, deletes or commits an original.
Contract: team-cooperation/engine-api.md.

    python3 -I engine_cli.py encode-local     --request /abs/private/job.json [--tools-dir /abs/dir]
    python3 -I engine_cli.py verify-candidate --request /abs/private/job.json [--tools-dir /abs/dir]
"""

import hashlib
import importlib.util
import json
import os
import re
import signal
import stat
import sys
import threading
import time
import uuid
from typing import Any, Dict, List, Optional, Set, Tuple

SCHEMA = 1
OPERATIONS = ("encode-local", "verify-candidate")
EXIT_CODES = {"ok": 0, "failed": 1, "rejected": 2, "cancelled": 3, "error": 4}
MAX_REQUEST_BYTES = 64 * 1024
MAX_LINE_BYTES = 64 * 1024
MAX_MESSAGE_CHARS = 600
MAX_ROOT_CHARS = 512
MAX_REL_PARTS = 6
MAX_SIZE = 1 << 50
HASH_CHUNK = 1024 * 1024
PROGRESS_INTERVAL = 1.0
RESULT_FLUSH_TIMEOUT = 10.0  # the result line is given this long to reach a reader that is not draining stdout
TOOL_DIRS = {"darwin": ["/opt/homebrew/bin", "/usr/local/bin"], "linux": ["/usr/bin", "/usr/local/bin"]}
KEPT_ENV = ("TMPDIR", "LANG", "LC_ALL", "HOME")

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
REF_RE = re.compile(r"[A-Za-z0-9._:=-]{1,128}")
COMPONENT_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]{0,99}")


class Stop(Exception):
    """Ends the job with a result line: status in rejected / failed / cancelled / error, plus a machine-readable code."""

    def __init__(self, status: str, code: str, message: str) -> None:
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def bad_request(message: str) -> Stop:
    return Stop("rejected", "bad_request", message)


class Emitter:
    """The only writer of stdout. Progress lines are latest-wins and the result line is always written last; every
    blocking write happens in this thread, so a reader that stops draining can never stall the encode. A write error
    (reader closed) marks the stream broken and calls on_broken once."""

    def __init__(self, fd: int) -> None:
        self.fd = fd
        self.broken = fd < 0
        self.on_broken: Optional[Any] = None
        self._cv = threading.Condition()
        self._progress: Optional[bytes] = None
        self._result: Optional[bytes] = None
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    @staticmethod
    def encode(obj: Dict[str, Any]) -> bytes:
        line = json.dumps(obj, ensure_ascii=True, separators=(",", ":"), allow_nan=False).encode("ascii") + b"\n"
        if len(line) > MAX_LINE_BYTES:  # fields are bounded at the source; this is only a last guard
            line = json.dumps({"type": obj.get("type"), "schema": SCHEMA, "truncated": True}).encode("ascii") + b"\n"
        return line

    def progress(self, obj: Dict[str, Any]) -> None:
        line = self.encode(obj)
        with self._cv:
            if self._result is None and not self.broken:
                self._progress = line
                self._cv.notify()

    def result(self, obj: Dict[str, Any]) -> None:
        line = self.encode(obj)
        with self._cv:
            self._result, self._progress = line, None
            self._cv.notify()
        self._thread.join(RESULT_FLUSH_TIMEOUT)

    def _run(self) -> None:
        while True:
            with self._cv:
                while self._progress is None and self._result is None:
                    self._cv.wait()
                line, final = (self._progress, False) if self._progress is not None else (self._result, True)
                self._progress = None
            if self.broken:
                return
            try:
                view = memoryview(line)
                while view:
                    view = view[os.write(self.fd, view):]
            except OSError:
                self.broken = True
                if self.on_broken:
                    self.on_broken()
                return
            if final:
                return


class Run:
    """State of the one job of this process: identity echoed on every line, current phase, cancel reason."""

    def __init__(self, emitter: Emitter) -> None:
        self.emitter = emitter
        self.worker: Any = None
        self.operation: Optional[str] = None
        self.job_id: Optional[str] = None
        self.ref: Optional[str] = None
        self.root = ""
        self.extra: Dict[str, Any] = {}
        self.cancel_reason: Optional[str] = None
        self.ppid = os.getppid()
        self.t0 = time.monotonic()
        self.last_emit = 0.0
        self.seq = 0
        self.phase, self.label = "start", ""
        self.pct: Optional[float] = None
        self.pos_s: Optional[float] = None
        self.total_s: Optional[float] = None
        self.done_bytes: Optional[int] = None
        self.total_bytes: Optional[int] = None

    def cancel(self, reason: str) -> None:
        if self.cancel_reason is None:
            self.cancel_reason = reason
        if self.worker is not None:
            self.worker.stop_requested = True  # the worker's poll loops then stop and WAIT for the child process group

    def check(self) -> None:
        """Cancels when the parent is gone (a detached engine would keep encoding for nobody) or stdout was closed."""
        if self.cancel_reason is None:
            if os.getppid() != self.ppid:
                self.cancel("parent_exited")
            elif self.emitter.broken:
                self.cancel("stdout_closed")

    def raise_if_cancelled(self) -> None:
        self.check()
        if self.cancel_reason is not None:
            raise Stop("cancelled", "cancelled", "작업이 취소되었습니다. 원본은 변경되지 않았습니다.")

    def ident(self) -> Dict[str, Any]:
        ident: Dict[str, Any] = {"schema": SCHEMA, "operation": self.operation, "job_id": self.job_id}
        if self.ref is not None:
            ident["ref"] = self.ref
        return ident

    def scrub(self, text: Any) -> str:
        """User-facing text: no workspace path, valid UTF-8, bounded."""
        out = str(text)
        if self.root:
            out = out.replace(self.root, "<root>")
        return out.encode("utf-8", "replace").decode("utf-8")[:MAX_MESSAGE_CHARS]

    def poll(self) -> None:
        """worker.poll_hook: runs in every cancel poll of the worker (~0.3 s): cancel checks plus the ~1 s heartbeat."""
        self.check()
        self.emit(False)

    def report(self, phase: str, label: str, pos: Optional[float] = None, total: Optional[float] = None) -> None:
        """worker.convert_and_verify / verify_external_output report callback (media seconds)."""
        changed = (phase, label) != (self.phase, self.label)
        self.phase, self.label = phase, label
        self.done_bytes = self.total_bytes = None
        if pos is not None and total and total > 0:
            self.pct = round(min(max(pos / total, 0.0), 1.0) * 100, 1)
            self.pos_s, self.total_s = round(pos, 1), round(total, 1)
        else:
            self.pct = self.pos_s = self.total_s = None
        self.emit(changed)

    def fraction(self, phase: str, label: str, done: int, total: int) -> None:
        """Hashing progress in bytes."""
        changed = (phase, label) != (self.phase, self.label)
        self.phase, self.label = phase, label
        self.pos_s = self.total_s = None
        self.done_bytes, self.total_bytes = done, total
        self.pct = round(min(done / total, 1.0) * 100, 1) if total > 0 else None
        self.check()
        self.emit(changed)

    def emit(self, force: bool) -> None:
        now = time.monotonic()
        if not force and now - self.last_emit < PROGRESS_INTERVAL:
            return
        self.last_emit = now
        self.seq += 1
        self.emitter.progress({
            "type": "progress", **self.ident(), "seq": self.seq, "elapsed_s": round(now - self.t0, 1),
            "phase": self.phase, "phase_label": self.label[:200], "phase_pct": self.pct,
            "phase_pos_s": self.pos_s, "phase_total_s": self.total_s,
            "phase_done_bytes": self.done_bytes, "phase_total_bytes": self.total_bytes,
        })

    def finish(self, status: str, code: str, message: str) -> None:
        obj: Dict[str, Any] = {"type": "result", **self.ident(), "status": status, "code": code,
                               "message": self.scrub(message), "elapsed_s": round(time.monotonic() - self.t0, 1)}
        if status == "ok" or status == "failed":
            obj.update(self.extra)
        if status == "cancelled":
            obj["cancel_reason"] = self.cancel_reason or "signal"
        self.emitter.result(obj)


# ---------------------------------------------------------------- request ----------------------------------------------

def parse_argv(argv: List[str]) -> Tuple[str, str, Optional[str]]:
    """Exactly: <operation> --request PATH [--tools-dir DIR] (options in any order, each once). Nothing else."""
    if not argv or argv[0] not in OPERATIONS:
        raise bad_request("사용법: engine_cli.py <encode-local|verify-candidate> --request /abs/job.json [--tools-dir /abs/dir]")
    opts: Dict[str, str] = {}
    rest = argv[1:]
    if len(rest) % 2 or len(rest) > 4:
        raise bad_request("인자 형식이 올바르지 않습니다.")
    for flag, value in zip(rest[0::2], rest[1::2]):
        if flag not in ("--request", "--tools-dir") or flag in opts or not value.startswith("/") or len(value) > MAX_ROOT_CHARS:
            raise bad_request("허용되지 않거나 중복된 인자이거나 절대 경로가 아닙니다.")
        opts[flag] = value
    if "--request" not in opts:
        raise bad_request("--request 가 필요합니다.")
    return argv[0], opts["--request"], opts.get("--tools-dir")


def _unique_keys(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key] = value
    return out


def _reject_constant(name: str) -> Any:
    raise ValueError(f"invalid constant {name}")


def read_request(path: str) -> Any:
    """Private request file: regular, owned by this euid, mode 0600, <= 64 KiB, strict JSON (no duplicate keys)."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    except OSError as e:
        raise bad_request(f"요청 파일을 열 수 없습니다: {e.strerror}")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077 or st.st_size > MAX_REQUEST_BYTES:
            raise bad_request("요청 파일은 현재 사용자 소유 일반 파일, 모드 0600, 최대 64KiB 여야 합니다.")
        raw = b""
        while len(raw) <= MAX_REQUEST_BYTES:
            chunk = os.read(fd, MAX_REQUEST_BYTES + 1 - len(raw))
            if not chunk:
                break
            raw += chunk
    finally:
        os.close(fd)
    if len(raw) > MAX_REQUEST_BYTES:
        raise bad_request("요청 파일이 너무 큽니다.")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_keys, parse_constant=_reject_constant)
    except Exception:
        raise bad_request("요청 파일이 올바른 JSON(중복 키 없음)이 아닙니다.")


def check_keys(obj: Any, required: Set[str], optional: Set[str], what: str) -> Dict[str, Any]:
    if not isinstance(obj, dict):
        raise bad_request(f"{what}은(는) JSON 객체여야 합니다.")
    unknown, missing = set(obj) - required - optional, required - set(obj)
    if unknown or missing:
        raise bad_request(f"{what}의 필드가 올바르지 않습니다(알 수 없음: {sorted(unknown)[:5]}, 없음: {sorted(missing)[:5]}).")
    return obj


def as_int(value: Any, low: int, high: int, what: str) -> int:
    if type(value) is not int or not low <= value <= high:
        raise bad_request(f"{what} 값이 올바르지 않습니다.")
    return value


def as_sha(value: Any, what: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise bad_request(f"{what} 는 소문자 hex SHA-256 이어야 합니다.")
    return value


def as_rel(value: Any, what: str) -> str:
    if (not isinstance(value, str) or len(value) > 700 or not 1 <= len(value.split("/")) <= MAX_REL_PARTS
            or not all(COMPONENT_RE.fullmatch(p) for p in value.split("/"))):
        raise bad_request(f"{what} 는 작업공간 기준 안전한 상대 경로여야 합니다.")
    return value


def validate_request(run: Run, data: Any, op: str) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise bad_request("요청은 JSON 객체여야 합니다.")
    if isinstance(data.get("job_id"), str) and UUID_RE.fullmatch(data["job_id"]):
        run.job_id = data["job_id"]
    if isinstance(data.get("ref"), str) and REF_RE.fullmatch(data["ref"]):
        run.ref = data["ref"]
    second = "output" if op == "encode-local" else "candidate"
    check_keys(data, {"schema", "operation", "job_id", "root", "source", second},
               {"ref"} | ({"allow_clock_recovery"} if op == "encode-local" else set()), "요청")
    if data["schema"] != SCHEMA or type(data["schema"]) is not int or data["operation"] != op:
        raise bad_request("schema 또는 operation 이 올바르지 않습니다.")
    if "allow_clock_recovery" in data and data["allow_clock_recovery"] is not True:
        raise bad_request("allow_clock_recovery 는 true 일 때만 보낼 수 있습니다.")
    if run.job_id != data["job_id"] or ("ref" in data and run.ref != data["ref"]):
        raise bad_request("job_id 또는 ref 형식이 올바르지 않습니다.")
    root = data["root"]
    if (not isinstance(root, str) or not 1 < len(root) <= MAX_ROOT_CHARS or not root.startswith("/")
            or any(ord(c) < 32 or ord(c) == 127 for c in root) or os.path.normpath(root) != root):
        raise bad_request("root 는 정규화된 절대 경로여야 합니다.")

    src = check_keys(data["source"], {"path", "size", "sha256"}, {"ext", "mtime_ns", "inode", "dev"}, "source")
    as_rel(src["path"], "source.path")
    as_int(src["size"], 1, MAX_SIZE, "source.size")
    as_sha(src["sha256"], "source.sha256")
    for key in ("mtime_ns", "inode", "dev"):
        if key in src:
            as_int(src[key], 0, (1 << 63) - 1, f"source.{key}")
    if "ext" in src and src["ext"] not in run.worker.LEGACY_EXTENSIONS | {".mp4"}:
        raise bad_request("source.ext 는 지원하는 원본 확장자(소문자)여야 합니다.")

    if op == "encode-local":
        out = check_keys(data["output"], {"path"}, set(), "output")
        if not as_rel(out["path"], "output.path").endswith(".mp4") or out["path"] == src["path"]:
            raise bad_request("output.path 는 원본과 다른 .mp4 경로여야 합니다.")
    else:
        cand = check_keys(data["candidate"], {"path", "size", "sha256"}, set(), "candidate")
        if as_rel(cand["path"], "candidate.path") == src["path"]:
            raise bad_request("candidate.path 는 원본과 달라야 합니다.")
        as_int(cand["size"], 1, MAX_SIZE, "candidate.size")
        as_sha(cand["sha256"], "candidate.sha256")
    return data


# --------------------------------------------------------------- workspace ---------------------------------------------

def check_root(root: str) -> None:
    """The workspace: canonical (no symlink in the path), a real directory owned by this euid with mode exactly 0700."""
    try:
        if os.path.realpath(root) != root:
            raise Stop("rejected", "unsafe_workspace", "root 는 심볼릭 링크가 없는 정식 경로(realpath)여야 합니다.")
        st = os.lstat(root)
    except OSError as e:
        raise Stop("rejected", "unsafe_workspace", f"작업공간을 확인할 수 없습니다: {e.strerror}")
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise Stop("rejected", "unsafe_workspace", "작업공간은 현재 사용자 소유 디렉터리이며 모드가 0700 이어야 합니다.")


def join_rel(root: str, rel: str) -> str:
    """root + rel with every intermediate directory checked: real (no symlink), owned by this euid, not group/other writable."""
    parts = rel.split("/")
    cur = root
    for part in parts[:-1]:
        cur += "/" + part
        try:
            st = os.lstat(cur)
        except OSError as e:
            raise Stop("rejected", "unsafe_workspace", f"작업공간 하위 폴더를 확인할 수 없습니다: {e.strerror}")
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o022:
            raise Stop("rejected", "unsafe_workspace", "작업공간 하위 폴더가 안전한 디렉터리가 아닙니다.")
    return cur + "/" + parts[-1]


def snapshot(st: os.stat_result) -> Tuple[int, int, int, int, int]:
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


def stat_input(path: str, expect: Dict[str, Any], role: str, mismatch: str, single_link: bool) -> os.stat_result:
    """Regular file (no symlink, no extra hard link when single_link) owned by this euid with the exact expected size
    (and optional NAS snapshot binding)."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        raise Stop("rejected", "input_missing", f"{role} 파일이 작업공간에 없습니다.")
    except OSError as e:
        raise Stop("rejected", "unsafe_workspace", f"{role} 파일 상태를 확인할 수 없습니다: {e.strerror}")
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or (single_link and st.st_nlink != 1):
        raise Stop("rejected", "unsafe_workspace", f"{role} 파일이 일반 파일이 아니거나 소유자·링크 조건을 만족하지 않습니다.")
    if st.st_size != expect["size"]:
        raise Stop("failed", mismatch, f"{role} 파일 크기가 기대값과 다릅니다.")
    for key, attr in (("mtime_ns", "st_mtime_ns"), ("inode", "st_ino"), ("dev", "st_dev")):
        if key in expect and expect[key] != getattr(st, attr):
            raise Stop("failed", mismatch, f"{role} 파일의 스냅샷({key})이 기대값과 다릅니다.")
    return st


def hash_file(run: Run, path: str, st0: os.stat_result, phase: str, label: str, changed_code: str) -> str:
    """Streaming SHA-256 (1 MiB chunks, cancellable, progress in bytes). The open file must be the lstat'ed one and must
    not change while it is read."""
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        if snapshot(os.fstat(fd)) != snapshot(st0):
            raise Stop("failed", changed_code, "파일이 검사 도중 바뀌었습니다.")
        digest, done, total = hashlib.sha256(), 0, st0.st_size
        run.fraction(phase, label, 0, total)
        while True:
            run.raise_if_cancelled()
            chunk = os.read(fd, HASH_CHUNK)
            if not chunk:
                break
            digest.update(chunk)
            done += len(chunk)
            run.fraction(phase, label, min(done, total), total)
        if done != total or snapshot(os.fstat(fd)) != snapshot(st0):
            raise Stop("failed", changed_code, "파일이 해시 계산 도중 바뀌었습니다.")
        return digest.hexdigest()
    finally:
        os.close(fd)


# ------------------------------------------------------------------ tools ----------------------------------------------

def trusted_tool(path: str) -> Optional[str]:
    """realpath of an executable regular file owned by root or this euid and not group/other writable."""
    try:
        real = os.path.realpath(path)
        st = os.stat(real)
    except OSError:
        return None
    if (stat.S_ISREG(st.st_mode) and st.st_uid in (0, os.geteuid()) and not st.st_mode & 0o022
            and os.access(real, os.X_OK)):
        return real
    return None


def resolve_tools(tools_dir: Optional[str]) -> Tuple[str, str, str]:
    """(PATH folder, ffmpeg, ffprobe): fixed known folders, or the caller's --tools-dir; the first folder with both wins."""
    folders = [os.path.normpath(tools_dir)] if tools_dir else TOOL_DIRS.get(sys.platform, [])
    for folder in folders:
        ffmpeg, ffprobe = trusted_tool(folder + "/ffmpeg"), trusted_tool(folder + "/ffprobe")
        if ffmpeg and ffprobe:
            return folder, ffmpeg, ffprobe
    raise Stop("rejected", "tool_unavailable", "신뢰할 수 있는 ffmpeg/ffprobe 를 찾을 수 없습니다.")


def load_worker() -> Any:
    """worker.py (next to this file) is loaded by path - not through sys.path, which -I keeps free of this folder - as a
    library: ENGINE_MODE needs neither the NAS queue, shares nor request-UID environment."""
    sys.dont_write_bytecode = True
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "worker.py")
    spec = importlib.util.spec_from_file_location("worker", path)
    if spec is None or spec.loader is None:
        raise Stop("error", "internal_error", "worker.py 를 불러올 수 없습니다.")
    module = importlib.util.module_from_spec(spec)
    module.ENGINE_MODE = True  # type: ignore[attr-defined]
    sys.modules["worker"] = module
    spec.loader.exec_module(module)
    return module


# ------------------------------------------------------------------- jobs ----------------------------------------------

def expect_hash_binding(run: Run, path: str, spec: Dict[str, Any], role: str, mismatch: str, changed: str,
                        single_link: bool, phase: str) -> os.stat_result:
    """Size / optional snapshot / SHA-256 of an input must equal what the caller (the NAS) declared."""
    st = stat_input(path, spec, role, mismatch, single_link)
    if hash_file(run, path, st, phase, f"{role} 파일 SHA-256 확인 중", changed) != spec["sha256"]:
        raise Stop("failed", mismatch, f"{role} 파일의 SHA-256이 기대값과 다릅니다.")
    return st


def encode_local(run: Run, req: Dict[str, Any]) -> str:
    w = run.worker
    src_path, out_path = join_rel(run.root, req["source"]["path"]), join_rel(run.root, req["output"]["path"])
    out_dir = os.path.dirname(out_path)
    run.raise_if_cancelled()
    try:
        os.lstat(out_path)
        raise Stop("rejected", "output_exists", "출력 경로에 이미 파일이 있습니다(덮어쓰지 않음).")
    except FileNotFoundError:
        pass
    st_src = expect_hash_binding(run, src_path, req["source"], "원본", "source_mismatch", "source_changed", True, "hash_source")
    run.extra["source"] = {"size": st_src.st_size, "sha256": req["source"]["sha256"]}

    stem = os.path.basename(out_path)[:-len(".mp4")]
    temp_path = f"{out_dir}/.{stem}.{uuid.uuid4().hex[:8]}.tmp.mp4"
    w.current_target_dir = out_dir
    linked = False
    w.CLOCK_RECOVERY = req.get("allow_clock_recovery") is True  # opt-in of the local Mac app only; default off
    try:
        ok, msg = w.convert_and_verify(src_path, temp_path, {}, run.report)
        run.raise_if_cancelled()
        if not ok:
            raise Stop("failed", "encode_failed", msg)
        try:
            src_unchanged = snapshot(os.lstat(src_path)) == snapshot(st_src)
        except OSError:
            src_unchanged = False
        if not src_unchanged:
            raise Stop("failed", "source_changed", "변환 도중 원본(캐시) 파일이 바뀌어 결과를 버렸습니다.")

        w.fsync_file(temp_path)
        st_tmp = os.lstat(temp_path)
        if (not stat.S_ISREG(st_tmp.st_mode) or st_tmp.st_size == 0 or st_tmp.st_nlink != 1 or st_tmp.st_uid != os.geteuid()
                or (st_tmp.st_dev, st_tmp.st_ino) != w.temp_identities.get(os.path.normpath(temp_path))):
            raise Stop("failed", "encode_failed", "임시 결과 파일의 무결성 확인에 실패했습니다.")
        out_sha = hash_file(run, temp_path, st_tmp, "hash_output", "결과 파일 SHA-256 계산 중", "encode_failed")

        run.report("publish", "검증된 결과 파일 저장 중")
        run.raise_if_cancelled()
        try:
            os.link(temp_path, out_path)  # exclusive: fails if the name appeared meanwhile; the temp is dropped below
        except FileExistsError:
            raise Stop("rejected", "output_exists", "출력 경로에 이미 파일이 있습니다(덮어쓰지 않음).")
        linked = True
        w.fsync_file(out_path)
        w.fsync_dir(out_dir)
        st_out = os.lstat(out_path)
        if (st_out.st_dev, st_out.st_ino, st_out.st_size, st_out.st_mtime_ns) != snapshot(st_tmp)[:4]:
            raise Stop("failed", "encode_failed", "게시된 결과 파일이 검증한 임시 파일과 다릅니다.")
        linked = False
        run.extra["output"] = {"path": req["output"]["path"], "size": st_out.st_size, "sha256": out_sha}
        # Structured, machine-readable: true for EVERY output built on a repaired video clock, a re-encode recovering from source decoder messages or a normalised AVI header - the caller must keep the original.
        recovery = w.clock_recovery_result
        header = w.header_recovery_result  # malformed AVI header normalised in a read-only view: the original must be kept as well
        run.extra["retain_original"] = recovery is not None or header is not None
        if header is not None:
            run.extra["header_recovery"] = {"kind": "avi_avcc_header", "video_packets": header["video_packets"],
                                            "audio_packets": header["audio_packets"]}
        if recovery is not None and recovery["clock_clean"]:
            run.extra["decode_message_recovery"] = {"frames": recovery["frames"]}  # clean clock, only the source's decoder messages
        elif recovery is not None:
            run.extra["clock_recovery"] = {"frames": recovery["frames"], "ties": recovery["ties"],
                                           "terminal_derived": recovery["terminal_derived"]}
        return msg
    finally:
        if linked:  # published but not confirmed: take back only the link to the inode this process created
            try:
                if os.lstat(out_path).st_ino == os.lstat(temp_path).st_ino:
                    os.unlink(out_path)
            except OSError:
                pass
        w.safe_cleanup_temp_file(temp_path, out_dir)


def verify_candidate(run: Run, req: Dict[str, Any]) -> str:
    w = run.worker
    src_path, cand_path = join_rel(run.root, req["source"]["path"]), join_rel(run.root, req["candidate"]["path"])
    run.raise_if_cancelled()
    st_src = expect_hash_binding(run, src_path, req["source"], "원본", "source_mismatch", "source_changed", True, "hash_source")
    run.extra["source"] = {"size": st_src.st_size, "sha256": req["source"]["sha256"]}
    st_cand = expect_hash_binding(run, cand_path, req["candidate"], "후보", "candidate_mismatch", "candidate_changed", True,
                                  "hash_candidate")
    run.extra["candidate"] = {"size": st_cand.st_size, "sha256": req["candidate"]["sha256"]}

    ok, msg, info = w.verify_external_output(src_path, cand_path, run.report)
    run.raise_if_cancelled()
    try:
        if snapshot(os.lstat(src_path)) != snapshot(st_src):
            raise Stop("failed", "source_changed", "검증 도중 원본 파일이 바뀌었습니다.")
        if snapshot(os.lstat(cand_path)) != snapshot(st_cand):
            raise Stop("failed", "candidate_changed", "검증 도중 후보 파일이 바뀌었습니다.")
    except OSError as e:
        raise Stop("failed", "source_changed", f"검증 후 입력 파일 상태를 확인할 수 없습니다: {e.strerror}")
    if not ok:
        if info.get("reason"):
            run.extra["reason"] = info["reason"]
        raise Stop("failed", "verification_failed", msg)
    run.extra["candidate"]["duration_s"] = round(info["duration_s"], 3)
    run.extra["timeline"] = info["timeline"]
    return msg


def execute(run: Run, argv: List[str]) -> str:
    run.raise_if_cancelled()
    op, request_path, tools_dir = parse_argv(argv)
    run.operation = op
    if os.geteuid() == 0:
        raise Stop("rejected", "unsafe_workspace", "root 권한으로는 실행하지 않습니다.")
    run.worker = load_worker()
    if run.cancel_reason:
        run.worker.stop_requested = True
    req = validate_request(run, read_request(request_path), op)
    run.root = req["root"]
    check_root(run.root)

    folder, ffmpeg, ffprobe = resolve_tools(tools_dir)
    kept = {k: os.environ[k] for k in KEPT_ENV if k in os.environ}
    os.environ.clear()  # nothing inherited reaches ffmpeg/ffprobe (DYLD_*, LD_*, FFREPORT ...)
    os.environ.update(kept)
    os.environ["PATH"] = folder
    run.worker.FFMPEG, run.worker.FFPROBE = ffmpeg, ffprobe
    run.worker.poll_hook = run.poll
    return encode_local(run, req) if op == "encode-local" else verify_candidate(run, req)


def main() -> None:
    os.umask(0o077)
    try:
        out_fd = os.dup(1)
    except OSError:
        out_fd = -1
    try:
        os.dup2(2, 1)  # from now on fd 1 is stderr: print() and stray output can never corrupt the JSON stream
    except OSError:
        null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(null, 1)
        os.close(null)
    emitter = Emitter(out_fd)
    run = Run(emitter)
    emitter.on_broken = lambda: run.cancel("stdout_closed")

    def on_signal(signum: int, frame: Any) -> None:
        run.cancel("signal")  # only a flag: the poll loops stop and wait for the child group, then clean up

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)

    try:
        message = execute(run, sys.argv[1:])
        status, code = "ok", "ok"
    except Stop as e:
        status, code, message = e.status, e.code, e.message
    except Exception as e:
        sys.stderr.write(f"engine internal error: {type(e).__name__}: {e}\n")
        status, code, message = "error", "internal_error", f"예기치 않은 오류: {type(e).__name__}"
    if status != "cancelled" and run.cancel_reason and status != "ok":
        status, code, message = "cancelled", "cancelled", "작업이 취소되었습니다. 원본은 변경되지 않았습니다."
    run.finish(status, code, message)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass
    os._exit(EXIT_CODES[status])


if __name__ == "__main__":
    main()
