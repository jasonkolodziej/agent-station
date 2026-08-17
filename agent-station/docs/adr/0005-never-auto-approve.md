# 0005 — Agent Station never auto-approves

## Decision
No auto-approval. Not on timeout, not by rule, not for "low risk" operations,
not with a user-set allowlist.

The `approval.decided_by` column has no `auto` value. This is enforced in the
schema so it can't drift in later as a "small" feature.

## Rationale
An app that can click Approve on `rm -rf` while you're at lunch is a liability.
And the moment it exists, every subsequent request is to make it smarter —
which is a request to make the liability larger.

When a prompt's deadline expires, the island dismisses it. The agent's own
terminal prompt remains authoritative and untouched.

## What would reverse this
Nothing short of a fundamentally different product with an explicit,
per-command, cryptographically-scoped delegation model. That is not v1, and
adding it incrementally to this design would be the wrong shape.
