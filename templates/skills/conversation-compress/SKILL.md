---
name: conversation-compress
description: Stage B of the conversation-feedback routine (docs/04). The cheap, frequent, LOCAL pass. Reads the fleet's recorded conversations and compresses each new transcript into a small grounded "session note" (user corrections, recurring tool errors, one candidate lesson) under $FLEET_HOME/feedback-notes/. Extractive only — it summarizes what the deterministic parser already flagged, it never judges whether a lesson is worth filing (that is stage C). Report-only, writes only note files. Trigger on the compress schedule, or when asked to refresh the feedback notes.
---

# Conversation-compress routine (stage B, cheap + frequent + LOCAL)

You turn raw local transcripts into a small, shippable, private-data-free payload
so the heavier distill pass (stage C, the `conversation-feedback` skill) can reason
over notes instead of re-reading every transcript — and can even run elsewhere,
because these notes carry no transcript paths and no private content beyond the
grounded lesson.

You run **local** because transcripts are local and private (docs/04 cloud-vs-local).
You use a **cheap model** (the routine passes `FEEDBACK_MODEL_COMPRESS`). You are
**extractive**: you compress the signal the parser already extracted. You do not
decide what becomes a queue issue — that judgment is stage C's, on the notes you
leave behind.

## 1. Read the input

```
fleet chats --scan --all --parse --history --since <ISO>  --json
```

`--history` is essential here: without it the scan returns only the latest pointer
per LIVE worktree, so a fleet that creates and deletes workers (the normal case)
would expose almost none of its real history. `--history` emits one entry per
transcript file across the window, **including finished workers whose worktree was
deleted** — that is where most of the fleet's learning lives. `--since <ISO>` bounds
the window (use the most recent note's date, or the last week); correctness still
rests on the note-dedup in step 2, this is a token lever.

Each Claude Code transcript carries a `parsed` block: `counts`, a `tools`
histogram, the real `user_prompts` (machine chatter stripped), and `tool_errors`.
Entries without a `parsed` key (other packs, or a pointer that is not a readable
file) are **inventory only** — skip them, do not guess their content. Coverage is
claude-first; note the un-analyzed packs so stage C knows the gap.

## 2. Write one note per NEW transcript

The note store is `$FLEET_HOME/feedback-notes/` (`$FLEET_HOME` defaults to
`~/.config/fleet`). Resolve it with `fleet feedback config` if unsure. One file per
transcript, named by its `session_id`:

```
$FLEET_HOME/feedback-notes/<session_id>.json
```

**Dedup is the file's existence.** If `<session_id>.json` already exists, skip that
transcript — it is already compressed. This is the whole incrementality mechanism;
there is no ledger at this stage.

Each note:

```json
{
  "session_id": "<from parsed.session_id>",
  "project": "<project name from the scan>",
  "role": "worker | coordinator",
  "worktree": "<name or null>",
  "pack": "claude",
  "ended": "<parsed.ended>",
  "transcript": "<parsed.transcript, the LOCAL path>",
  "corrections": ["<a user follow-up that corrected the agent, quoted short>", "..."],
  "recurring_errors": ["<tool>: <short error>", "..."],
  "candidate_lesson": "<one line: what durable instruction would have avoided this>",
  "confidence": "low | med | high"
}
```

Grounding rules:

- **Corrections** come from consecutive `user_prompts`: a short second prompt right
  after the agent acted ("no, in French", "don't edit the hub") is the user fixing
  a default. Capture the *correction*, not the first ask.
- **recurring_errors** come from `tool_errors` — same command/denied write failing.
- **candidate_lesson** is one grounded sentence, or `""` if nothing rises above
  noise. Do not invent. A quiet session gets an empty lesson and empty lists; still
  write the note so it is not re-read next run.
- The `transcript` path stays in the LOCAL note for traceability. Stage C strips it
  before any payload leaves the machine.

## Rules (report-only, mechanical)

- Read the scan; write note files under `$FLEET_HOME/feedback-notes/`. Nothing else.
- Never edit code or a hub doc, never file a queue issue, never `git push`, never
  touch prod. Filing and judgment are stage C.
- Never invent a lesson you cannot ground in the parsed signal.
- Do not copy whole transcripts into a note; summarize and keep the path.
- End by telling the user: notes written (count), transcripts skipped as already
  compressed, and packs left un-analyzed (no parser yet).
