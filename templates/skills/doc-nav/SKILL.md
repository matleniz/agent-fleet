---
name: doc-nav
description: Answer any question about the system documented in this hub WITHOUT loading the whole hub. Read INDEX.md, pick the single relevant file, open only that one, grep the section. Trigger whenever you need a fact from the docs instead of opening files blindly or reading everything.
---

# doc-nav — token-cheap hub navigation

Goal: answer from the hub while loading as little as possible. This is the single
biggest token lever (see agent-fleet docs/06).

Procedure:

1. **Read `INDEX.md`.** It maps topic → file. Do not read anything else yet.
2. **Pick the ONE file** the index points to for this question.
3. **Open only that file.** If it is large, `grep '^#'` (or search headings) to
   jump to the section instead of reading top to bottom.
4. **Verify against code** if the fact is technical: the hub is distilled truth,
   but the code (`grep`/`ls` in the code repo) is ground truth. Flag any drift.

Do NOT:
- Read the whole hub, or several files "to be safe".
- Answer a technical fact from the hub alone if the code could have drifted.

If the index has no entry for the topic, that is a signal the hub is thin there
(see docs/05): answer from the code, and consider proposing an index entry via
`propose-doc-change` so the next lookup is cheap.
