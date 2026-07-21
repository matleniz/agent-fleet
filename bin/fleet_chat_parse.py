#!/usr/bin/env python3
"""fleet_chat_parse — extract a compact, method-relevant signal from an agent
transcript. Importable as a module (parse_transcript(path) -> dict) and runnable
as a CLI (`fleet_chat_parse.py <transcript.jsonl>` prints the JSON).

This is the reader behind the fleet-wide conversation-feedback routine
(docs/04-routines.md): fleet-chats-scan.py inventories WHERE each pack recorded a
conversation; this turns ONE recorded conversation into the raw material a
routine reasons over — user prompts (including follow-up corrections), the
tool-use histogram, and tool errors — without shipping the whole transcript.

Coverage is claude + cursor: both Claude Code's and the Cursor CLI's JSONL
formats are parsed here. The scanner is pack-agnostic; the remaining packs'
formats (gemini chats/, antigravity SQLite, ...) get their own parser when their
transcripts are wired in. detect_format() tags the format (or returns None for a
non-transcript pointer, e.g. an opencode shell command) so parse_transcript can
dispatch. Reads only; changes nothing.
"""

import json
import os
import re
import sys

# Transcript line `type`s that are real conversational turns (vs bookkeeping:
# mode / file-history-* / permission-mode / ai-title / attachment / ...).
_TURN_TYPES = {"user", "assistant"}
# Wrapper text that is NOT a genuine user prompt but is stored as a user-role
# line: slash-command echoes, local-command stdout, and harness-injected events
# (background task notifications, system reminders). Excluded so the routine
# reasons over real human turns and their corrections, not machine chatter.
_WRAPPER_PREFIXES = (
    "<command-",
    "<local-command-",
    "<bash-",
    "Caveat:",
    "<task-notification",
    "<system-reminder",
    "[SYSTEM NOTIFICATION",
)
_PROMPT_MAX = 500  # truncate each captured user prompt
_ERROR_MAX = 300  # truncate each captured tool-error snippet
_MAX_ERRORS = 20  # cap error samples per transcript

# Cursor wraps each human turn as <timestamp>..</timestamp><user_query>..</user_query>,
# and in a headless (`-p`) run injects an auto-continue nudge as a user turn.
_USER_QUERY_RE = re.compile(r"<user_query>(.*?)</user_query>", re.DOTALL)
_CURSOR_NUDGE_PREFIXES = ("Briefly inform the user about the task result",)


def detect_format(path):
    """Best-effort transcript format tag from the first decodable line:
    "claude" (a JSON object carrying a top-level `type` key), "cursor" (a
    role-tagged {role, message} object with no top-level `type`), or None for an
    empty file, non-JSON, or a non-transcript pointer (an opencode pointer is a
    shell command string, a gemini pointer is a dir)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                if not isinstance(obj, dict):
                    return None
                if "type" in obj:
                    return "claude"
                if "role" in obj and "message" in obj:
                    return "cursor"
                return None
    except (OSError, ValueError):
        return None
    return None


def _text_blocks(content):
    """Yield the text of each text/tool_result block in a message content that
    is a list; a plain-string content yields itself."""
    if isinstance(content, str):
        yield content
        return
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") in ("text", "tool_result"):
            val = (
                block.get("text")
                if block.get("type") == "text"
                else block.get("content")
            )
            if isinstance(val, list):
                for sub in val:
                    if isinstance(sub, dict) and isinstance(sub.get("text"), str):
                        yield sub["text"]
            elif isinstance(val, str):
                yield val


def _is_real_user_prompt(obj):
    """A genuine human turn: type=user, string content, not meta/sidechain, not a
    command/stdout wrapper the CLI injects as a user line."""
    if obj.get("type") != "user" or obj.get("isMeta") or obj.get("isSidechain"):
        return False
    content = obj.get("message", {}).get("content")
    if not isinstance(content, str):
        return False
    stripped = content.lstrip()
    return bool(stripped) and not stripped.startswith(_WRAPPER_PREFIXES)


def parse_transcript(path):
    """Read one agent JSONL transcript into a compact signal dict, dispatching on
    the detected format. Never raises on a malformed line (skips it); returns
    {"error": ...} only if the file cannot be read or the format is unrecognized."""
    fmt = detect_format(path)
    if fmt == "claude":
        return _parse_claude(path)
    if fmt == "cursor":
        return _parse_cursor(path)
    return {"transcript": path, "error": "unrecognized transcript format"}


def _cursor_user_text(content):
    """The human prompt text of a cursor user turn: the <user_query> bodies with
    the <timestamp> envelope dropped. Falls back to the raw joined text when there
    is no <user_query> tag."""
    joined = "\n".join(_text_blocks(content)).strip()
    if not joined:
        return ""
    queries = _USER_QUERY_RE.findall(joined)
    text = "\n".join(q.strip() for q in queries) if queries else joined
    return text.strip()


def _parse_cursor(path):
    """Read a Cursor CLI JSONL transcript into the same compact signal dict as
    _parse_claude. Cursor turns are role-tagged ({role, message:{content:[...]}})
    with no top-level type, no per-turn ISO timestamp, and no tool_result blocks —
    so started/ended stay None (the scanner carries the file mtime) and tool_errors
    is always empty. session_id is the transcript's uuid filename, which keeps the
    stage-B dedup (feedback-notes/<session_id>.json) stable and unique per run."""
    session_id = os.path.splitext(os.path.basename(path))[0]
    counts = {
        "user_prompts": 0,
        "assistant_turns": 0,
        "thinking": 0,
        "tool_use": 0,
        "tool_errors": 0,
    }
    tools = {}
    user_prompts = []

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue

            role = obj.get("role")
            content = obj.get("message", {}).get("content")
            if role == "assistant" and isinstance(content, list):
                counts["assistant_turns"] += 1
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    bt = block.get("type")
                    if bt == "thinking":
                        counts["thinking"] += 1
                    elif bt == "tool_use":
                        counts["tool_use"] += 1
                        name = block.get("name", "?")
                        tools[name] = tools.get(name, 0) + 1
            elif role == "user":
                text = _cursor_user_text(content)
                if (
                    text
                    and not text.startswith(_WRAPPER_PREFIXES)
                    and not text.startswith(_CURSOR_NUDGE_PREFIXES)
                ):
                    counts["user_prompts"] += 1
                    user_prompts.append(text[:_PROMPT_MAX])

    return {
        "transcript": path,
        "session_id": session_id,
        "cwd": None,
        "git_branch": None,
        "version": None,
        "started": None,
        "ended": None,
        "counts": counts,
        "tools": dict(sorted(tools.items(), key=lambda kv: (-kv[1], kv[0]))),
        "user_prompts": user_prompts,
        "tool_errors": [],
    }


def _parse_claude(path):
    """Read a Claude Code JSONL transcript into a compact signal dict. Never
    raises on a malformed line (skips it)."""
    session_id = cwd = git_branch = version = None
    started = ended = None
    counts = {
        "user_prompts": 0,
        "assistant_turns": 0,
        "thinking": 0,
        "tool_use": 0,
        "tool_errors": 0,
    }
    tools = {}
    user_prompts = []
    tool_errors = []

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue

            session_id = session_id or obj.get("sessionId")
            cwd = cwd or obj.get("cwd")
            git_branch = git_branch or obj.get("gitBranch")
            version = version or obj.get("version")
            ts = obj.get("timestamp")
            if ts:
                started = ts if started is None or ts < started else started
                ended = ts if ended is None or ts > ended else ended

            t = obj.get("type")
            if t not in _TURN_TYPES:
                continue
            content = obj.get("message", {}).get("content")

            if t == "assistant" and isinstance(content, list):
                counts["assistant_turns"] += 1
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    bt = block.get("type")
                    if bt == "thinking":
                        counts["thinking"] += 1
                    elif bt == "tool_use":
                        counts["tool_use"] += 1
                        name = block.get("name", "?")
                        tools[name] = tools.get(name, 0) + 1
            elif t == "user":
                if _is_real_user_prompt(obj):
                    counts["user_prompts"] += 1
                    user_prompts.append(content.strip()[:_PROMPT_MAX])
                elif isinstance(content, list):
                    for block in content:
                        if (
                            isinstance(block, dict)
                            and block.get("type") == "tool_result"
                            and block.get("is_error")
                        ):
                            counts["tool_errors"] += 1
                            if len(tool_errors) < _MAX_ERRORS:
                                snippet = " ".join(_text_blocks([block])).strip()
                                tool_errors.append(snippet[:_ERROR_MAX])

    return {
        "transcript": path,
        "session_id": session_id,
        "cwd": cwd,
        "git_branch": git_branch,
        "version": version,
        "started": started,
        "ended": ended,
        "counts": counts,
        "tools": dict(sorted(tools.items(), key=lambda kv: (-kv[1], kv[0]))),
        "user_prompts": user_prompts,
        "tool_errors": tool_errors,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        sys.stderr.write("usage: fleet_chat_parse.py <transcript.jsonl>\n")
        sys.exit(2)
    path = args[0]
    if not os.path.isfile(path):
        sys.stderr.write("error: no such file: %s\n" % path)
        sys.exit(1)
    print(json.dumps(parse_transcript(path), indent=2))


if __name__ == "__main__":
    main()
