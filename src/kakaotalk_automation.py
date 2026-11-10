"""Native macOS Accessibility operations for KakaoTalk via CLI and MCP."""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import nullcontext
from importlib.resources import files
from pathlib import Path

from kakaotalk_ax import AXOperations, integer, ui_session, title, boolean
from kakaotalk_state import digest


# Keep the existing cache location across the project rename.
BINARY_ROOT = Path.home() / ".cache/kakaotalk-reader/native"


class NativeAX(AXOperations):
    def __init__(self, cache_root=BINARY_ROOT):
        self.cache_root = Path(cache_root)

    def build(self, kind="send"):
        if sys.platform != "darwin":
            raise ValueError("macOS is required for accessibility access")
        if kind not in ("send", "read", "control"):
            raise ValueError("Unknown native bridge kind")
        source = Path(str(files("kakaotalk_native").joinpath({
            "read": "ReadKakaoAX.swift", "send": "SendKakao.swift", "control": "ControlKakaoAX.swift"}[kind])))
        key = hashlib.sha256(source.read_bytes()).hexdigest()[:20]
        self.cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        binary = self.cache_root / (kind + "-kakao-" + key)
        if not binary.is_file():
            compiler = shutil.which("swiftc")
            if not compiler:
                raise ValueError("Swift compiler is required; install Apple command-line tools")
            descriptor, name = tempfile.mkstemp(prefix="." + kind + "-kakao-", dir=self.cache_root)
            os.close(descriptor)
            try:
                result = subprocess.run([compiler, "-O", str(source), "-o", name],
                                        capture_output=True, text=True, timeout=60)
                if result.returncode:
                    raise ValueError("Native accessibility bridge build failed")
                os.chmod(name, 0o700)
                os.replace(name, binary)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
        return binary

    def call(self, action, titles, text=None, **options):
        with ui_session() if action in ("send", "raise") else nullcontext():
            return self._call(action, titles, text, **options)

    def _call(self, action, titles, text=None, max_rows=None):
        request = {"action": action, "windowTitles": titles}
        if text is not None:
            request["text"] = text
        if max_rows is not None:
            request["maxRows"] = max_rows
        binary = self.build("read") if action in ("read", "windows") else self.build()
        result = subprocess.run([str(binary)], input=json.dumps(request, ensure_ascii=False),
                                capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError("Native accessibility process exited unexpectedly")
        value = json.loads(result.stdout)
        if not isinstance(value, dict) or "dispatchAttempted" not in value:
            raise RuntimeError("Invalid accessibility result")
        return value

    def windows(self):
        """List existing windows without opening, raising or reading their message bodies."""
        return self.call("windows", [])

    def _control(self, action, **arguments):
        with ui_session():
            return self._control_call(action, **arguments)

    def _control_call(self, action, **arguments):
        result = subprocess.run([str(self.build("control"))],
                                input=json.dumps({"action": action, **arguments}, ensure_ascii=False),
                                capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError("Native AX control process exited unexpectedly")
        value = json.loads(result.stdout)
        if not isinstance(value, dict) or value.get("source") != "macos_accessibility":
            raise RuntimeError("Invalid native AX control result")
        return value

    def read_messages(self, window_title, limit=50, offset=0, snapshot_id="", recent_only=False):
        """Read exposed AX rows, newest page first, preserving row order within a page.

        A snapshot ID is required for older pages so incoming messages cannot
        silently shift offsets. Reads preserve the current window state.

        recent_only reads just the newest `limit` exposed rows. It is much faster
        on rooms whose rows are expensive to traverse, but its snapshot covers
        only those rows, so it cannot be paged (offset must be 0).
        """
        if not isinstance(window_title, str) or not window_title.strip() or len(window_title.encode("utf-8")) > 4096:
            raise ValueError("An exact open window_title of 1..4096 UTF-8 bytes is required")
        integer(limit, "limit", 1, 500)
        integer(offset, "offset", 0, 1000)
        if not isinstance(snapshot_id, str) or snapshot_id and not re.fullmatch(r"[0-9a-f]{24}", snapshot_id):
            raise ValueError("snapshot_id must be the ID returned by an AX read")
        if offset and not snapshot_id:
            raise ValueError("snapshot_id is required for offset > 0; read the first page again")
        if not isinstance(recent_only, bool):
            raise ValueError("recent_only must be a boolean")
        if recent_only and (offset or snapshot_id):
            raise ValueError("recent_only reads cannot be paged; use offset 0 without snapshot_id")
        raw = self.call("read", [window_title], max_rows=limit) if recent_only else self.call("read", [window_title])
        if raw.get("status") != "ok":
            return raw
        snapshot = snapshot_digest(raw)
        if snapshot_id and snapshot_id != snapshot:
            return {"status": "snapshot_changed", "source": "macos_accessibility",
                    "reason": "AX rows changed; restart at offset 0", "items": [],
                    "databaseCalls": 0, "uiActions": 0, "snapshotId": snapshot}
        items = [ax_row(row) for row in raw["rows"]]
        end = max(0, len(items) - offset)
        start = max(0, end - limit)
        return {
            "status": "ok", "source": "macos_accessibility", "windowTitle": window_title,
            "items": items[start:end], "total": len(items), "limit": limit, "offset": offset,
            "hasMore": raw["rowStart"] > 0 if recent_only else start > 0,
            "nextOffset": None if recent_only else (offset + end - start if start > 0 else None),
            "snapshotId": snapshot, "textMessageCount": sum(item["kind"] == "text" for item in items),
            "unclassifiedRowCount": sum(item["kind"] == "unclassified" for item in items),
            "attachmentRowCount": sum(item["kind"] == "attachment" for item in items),
            "coverage": {"scope": "newest_exposed_ax_rows" if recent_only else "currently_exposed_ax_rows",
                         "historyComplete": False,
                         "consistency": "best_effort", "exposedRowCount": raw["exposedRowCount"],
                         "rowsTruncated": raw["rowsTruncated"], "rowStart": raw["rowStart"],
                         "rowLimit": 1000, "scrollPerformed": False,
                         "attributeReadMode": raw.get("attributeReadMode", "individual"),
                         "optionalAttributeFailures": raw.get("optionalAttributeFailures", {})},
            "databaseCalls": 0, "uiActions": 0, "elapsedMs": raw["elapsedMs"],
        }

    def read_attachment(self, window_title, row_index, snapshot_id, output_path=None, ocr=False):
        """Return one AX image row as a PNG crop; scrolls via AX and restores it.

        macOS 14.2+ and Screen Recording permission are required. The original file is
        not fetched. OCR is optional and kept separate from message text.
        """
        title(window_title)
        integer(row_index, "row_index", 0, 1_000_000)
        boolean(ocr, "ocr")
        if not isinstance(snapshot_id, str) or not re.fullmatch(r"[0-9a-f]{24}", snapshot_id):
            raise ValueError("A current read_messages snapshot_id is required")
        if output_path is not None and (not isinstance(output_path, str) or not Path(output_path).is_absolute()):
            raise ValueError("output_path must be an absolute path")
        if output_path and Path(output_path).exists():
            raise ValueError("output_path already exists")
        with ui_session():
            raw = self.call("read", [window_title])
            if raw.get("status") != "ok":
                return raw
            if snapshot_digest(raw) != snapshot_id:
                return {"status": "snapshot_changed", "reason": "Read the attachment row again", "databaseCalls": 0}
            selected = [row for row in raw["rows"] if row["rowIndex"] == row_index]
            if len(selected) != 1 or ax_row(selected[0])["kind"] != "attachment":
                return {"status": "blocked", "reason": "attachment_row_required", "databaseCalls": 0}
            request = {"action": "attachment", "windowTitles": [window_title], "rowIndex": row_index,
                       "expectedParts": selected[0]["parts"], "expectedCount": raw["exposedRowCount"],
                       "ocr": ocr}
            result = subprocess.run([str(self.build("read"))], input=json.dumps(request, ensure_ascii=False),
                                    capture_output=True, text=True, timeout=25)
            if result.returncode:
                raise RuntimeError("Native attachment reader failed")
            value = json.loads(result.stdout)
            encoded = value.pop("imageBase64", None)
            if value.get("status") == "ok":
                if not encoded:
                    raise RuntimeError("Attachment reader returned no image")
                image = base64.b64decode(encoded, validate=True)
                if output_path:
                    descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                else:
                    # A private temporary image can be viewed directly by the caller.
                    descriptor, output_path = tempfile.mkstemp(prefix="kax-attachment-", suffix=".png")
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(image)
                value["imagePath"] = str(Path(output_path))
            value["snapshotId"] = snapshot_id
            return value


def snapshot_digest(raw):
    return digest(json.dumps({k: raw[k] for k in (
        "windowTitle", "processId", "rows", "exposedRowCount", "rowStart", "rowsTruncated")},
        ensure_ascii=False, sort_keys=True))[:24]


def ax_row(row):
    """Keep unrecognized AX content; never fabricate sender or grouped timestamps."""
    parts = row["parts"]
    bodies = [part["AXValue"] for part in parts if part["role"] == "AXTextArea" and part.get("AXValue")]
    times = [(part, line.strip()) for part in parts if part["role"] == "AXStaticText"
             for line in part.get("AXValue", "").splitlines() if
             re.fullmatch(r"(?:(?:오전|오후|AM|PM)\s*)?\d{1,2}:\d{2}(?:\s*(?:AM|PM))?",
                          line.strip(), flags=re.IGNORECASE)]
    dates = [part["AXHelp"] for part, _ in times if
             re.fullmatch(r"\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?", part.get("AXHelp", ""))]
    attachments = [{"type": "image", "textSource": "accessibility_metadata",
                    "description": part.get("AXDescription") or None,
                    "title": part.get("AXTitle") or None}
                   for part in parts if part["role"] == "AXImage"] if not bodies else []
    links = [part.get("AXURL") or part.get("AXValue") or part.get("AXTitle")
             for part in parts if part["role"] == "AXLink"]
    return {"rowIndex": row["rowIndex"], "kind": "text" if bodies else "attachment" if attachments else "unclassified",
            "attachments": attachments, "links": [link for link in links if link],
            "text": "\n".join(bodies) if bodies else None, "sender": None,
            "timeText": times[0][1] if len(times) == 1 else None,
            "dateText": dates[0] if len(set(dates)) == 1 else None, "axParts": parts}


def main():
    parser = argparse.ArgumentParser(prog="kax", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("mcp", help="Serve the AX tools over MCP stdio")
    command = commands.add_parser("build")
    command.add_argument("--kind", choices=("send", "read", "control"), default="send")
    command = commands.add_parser("ax-call")
    command.add_argument("method", choices=("windows", "rooms", "search_rooms", "open_room", "close_room",
                        "read_messages", "read_attachment", "read_many", "load_more", "search_messages", "close_search",
                        "send_message", "send_result"))
    command.add_argument("--args-file", type=Path)
    commands.add_parser("ax-windows")
    commands.add_parser("status")
    command = commands.add_parser("ax-read")
    command.add_argument("--window-title", required=True)
    command.add_argument("--limit", type=int, default=50)
    command.add_argument("--offset", type=int, default=0)
    command.add_argument("--snapshot-id", default="")
    command.add_argument("--recent-only", action="store_true",
                         help="Read only the newest --limit rows (faster, not pageable)")
    args = parser.parse_args()
    if args.command == "mcp":
        from kakaotalk_mcp import main as serve
        serve()
        return 0
    sending_operation = None
    try:
        if args.command == "ax-call":
            request = json.loads(args.args_file.read_text()) if args.args_file else {}
            if not isinstance(request, dict):
                raise ValueError("AX arguments must be a JSON object")
            if args.method == "send_message":
                sending_operation = request.get("operation_id")
            value = getattr(NativeAX(), args.method)(**request)
        elif args.command in ("ax-windows", "status"):
            value = NativeAX().windows()
        elif args.command == "ax-read":
            value = NativeAX().read_messages(args.window_title, args.limit, args.offset, args.snapshot_id,
                                             recent_only=args.recent_only)
        elif args.command == "build":
            started = time.monotonic()
            NativeAX().build(args.kind)
            value = {"status": "built", "kind": args.kind, "elapsedMs": round((time.monotonic()-started)*1000, 1)}
        print(json.dumps(value, ensure_ascii=False, indent=2))
        return int(value["status"] not in ("ok", "built", "partial", "observed_in_ax"))
    except Exception as error:
        print(json.dumps({"status": "outcome_unknown" if sending_operation else "failed",
                          **({"operationId": sending_operation, "retrySafe": False} if sending_operation else {}),
                          "errorType": type(error).__name__,
                          "detail": str(error) if isinstance(error, ValueError) else (
                              "AX read failed" if args.command in ("ax-read", "ax-windows", "status") else
                              "Operation failed; inspect saved result before retrying")}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
