Golden files. `<name>.json` is the verbatim provider payload; `<name>.expected.json`
is the canonical event(s) it must normalize to.

These are the regression net for the thing most likely to break: a provider
silently changing its hook schema. When that happens the mapping stops matching
and the event lands in `unmapped_event` — visible in `station doctor`, not a
mystery silence.

Capture real payloads, don't hand-write them. `station tail --raw` dumps them.
