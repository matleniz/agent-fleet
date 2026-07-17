#!/usr/bin/env python3
"""fleet_chat_parse — extract a compact, method-relevant signal from an agent
transcript. Importable as a module (parse_transcript(path) -> dict) and runnable
as a CLI (`fleet_chat_parse.py <transcript.jsonl>` prints the JSON).

This is the reader behind the fleet-wide conversation-feedback routine
(docs/04-routines.md): fleet-chats-scan.py inventories WHERE each pack recorded a
conversation; this turns ONE recorded conversation into the raw material a
routine reasons over — user prompts (including follow-up corrections), the
tool-use histogram, and tool errors — without shipping the whole transcript.

Coverage is claude-first: only Claude Code's JSONL format is parsed here (the
one format with prior groundwork). The scanner is pack-agnostic; other packs'
formats (gemini chats/, antigravity SQLite, ...) get their own parser when their
transcripts are wired in. detect_format() guards against feeding a non-claude
pointer in. Reads only; changes nothing.
"""
import json
import os
import sys

# Transcript line `type`s that are real conversational turns (vs bookkeeping:
# mode / file-history-* / permission-mode / ai-title / attachment / ...).
_TURN_TYPES = {"user", "assistant"}
# Wrapper text that is NOT a genuine user prompt but is stored as a user-role
# line: slash-command echoes, local-command stdout, and harness-injected events
# (background task notifications, system reminders). Excluded so the routine
# reasons over real human turns and their corrections, not machine chatter.
_WRAPPER_PREFIXES = ("<command-", "<local-command-", "<bash-", "Caveat:",
                     "<task-notification", "<system-reminder",
                     "[SYSTEM NOTIFICATION")
_PROMPT_MAX = 500      # truncate each captured user prompt
_ERROR_MAX = 300       # truncate each captured tool-error snippet
_MAX_ERRORS = 20       # cap error samples per transcript


def detect_format(path):
    """Best-effort: is this a Claude Code JSONL transcript? True if the first
    decodable line is a JSON object carrying a `type` key (claude's shape).
    Returns False for empty files, non-JSON, or non-claude pointers (e.g. an
    opencode pointer is a shell command string, a gemini pointer is a dir)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                return isinstance(obj, dict) and "type" in obj
    except (OSError, ValueError):
        return False
    return False


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
            val = block.get("text") if block.get("type") == "text" else block.get("content")
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
    """Read a Claude Code JSONL transcript into a compact signal dict. Never
    raises on a malformed line (skips it); returns {"error": ...} only if the
    file cannot be read or is not a claude transcript at all."""
    if not detect_format(path):
        return {"transcript": path, "error": "not a claude JSONL transcript"}

    session_id = cwd = git_branch = version = None
    started = ended = None
    counts = {"user_prompts": 0, "assistant_turns": 0,
              "thinking": 0, "tool_use": 0, "tool_errors": 0}
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
                        if isinstance(block, dict) and block.get("type") == "tool_result" \
                                and block.get("is_error"):
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
