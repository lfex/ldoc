# ldoc contributor instructions

Use lowercase `ldoc` in new user-facing prose and command output. Preserve the
canonical orphan `planning` worktree and its `projectNN-<slug>/` ownership.
Keep implementation changes on the assigned dedicated non-default source
branch; inspect and preserve owner checkouts, dirty work, and other worktree
ownership. Stage explicit full filenames only. Do not publish or create release
tags without the separate Operator gate.

## Commit attribution

Every future assistant-authored commit, on implementation or planning
branches, must include both of these trailers, separated from the message
body by a blank line:

```text
Co-authored-by: Codex <noreply@openai.com>
Co-authored-by: Billo AI <ai-engineering@billo.systems>
```
