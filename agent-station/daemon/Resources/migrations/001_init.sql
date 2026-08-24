-- Agent Station store. SQLite, WAL. See ARCHITECTURE.md §11.
-- WAL mode is set on the connection (Store.swift's Configuration.prepareDatabase),
-- not here: `PRAGMA journal_mode = WAL` cannot run inside a transaction, and
-- GRDB's DatabaseMigrator wraps every registered migration in one.
PRAGMA foreign_keys = ON;

CREATE TABLE project (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  remote_url    TEXT,
  root_path     TEXT NOT NULL,
  ephemeral     INTEGER NOT NULL DEFAULT 0,
  pinned        INTEGER NOT NULL DEFAULT 0,
  last_seen_at  INTEGER NOT NULL
);

CREATE TABLE session (
  id          TEXT PRIMARY KEY,
  provider    TEXT NOT NULL,
  project_id  TEXT REFERENCES project(id) ON DELETE SET NULL,
  cwd         TEXT NOT NULL,
  surface     TEXT NOT NULL CHECK (surface IN ('terminal','ide','cloud','headless')),
  model       TEXT,
  started_at  INTEGER NOT NULL,
  ended_at    INTEGER,
  state       TEXT NOT NULL
);
CREATE INDEX ix_session_project ON session(project_id, started_at DESC);
CREATE INDEX ix_session_active  ON session(ended_at) WHERE ended_at IS NULL;

-- Separate table, not columns on session: focus context is captured once and is
-- write-once. Keeping it apart makes that invariant enforceable.
CREATE TABLE focus_context (
  session_id      TEXT PRIMARY KEY REFERENCES session(id) ON DELETE CASCADE,
  term_program    TEXT,
  term_session_id TEXT,
  tmux_pane       TEXT,
  host_pid        INTEGER,
  ide_window_id   TEXT,
  workspace_uri   TEXT,
  captured_at     INTEGER NOT NULL
);

CREATE TABLE event (
  id           INTEGER PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,
  provider_event TEXT,
  ts           INTEGER NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE INDEX ix_event_session_ts ON event(session_id, ts DESC);
CREATE INDEX ix_event_ts ON event(ts);   -- for the 30d retention sweep

CREATE TABLE approval (
  id           INTEGER PRIMARY KEY,
  session_id   TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  requested_at INTEGER NOT NULL,
  resolved_at  INTEGER,
  decision     TEXT CHECK (decision IN ('allow','deny','expired','answered_in_terminal')),
  decided_by   TEXT CHECK (decided_by IN ('user_island','user_terminal','expired')),
  risk         TEXT NOT NULL
);
-- NOTE: there is deliberately no 'auto' value for decided_by. Agent Station
-- never auto-approves — not on timeout, not by rule, not for "low risk".

CREATE TABLE usage_sample (
  id            INTEGER PRIMARY KEY,
  session_id    TEXT NOT NULL,
  project_id    TEXT,
  provider      TEXT NOT NULL,
  model         TEXT NOT NULL,
  ts            INTEGER NOT NULL,
  input_tokens  INTEGER NOT NULL DEFAULT 0,
  cache_write   INTEGER NOT NULL DEFAULT 0,
  cache_read    INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  billing_mode  TEXT NOT NULL CHECK (billing_mode IN ('subscription','api','credit','copilot_premium')),
  price_rev     TEXT NOT NULL   -- retroactively re-pricing history is a bug
);
CREATE INDEX ix_usage_project_ts ON usage_sample(project_id, ts);

CREATE TABLE window_state (
  provider    TEXT NOT NULL,
  window_kind TEXT NOT NULL,
  used        REAL NOT NULL,
  "limit"     REAL,
  confidence  TEXT NOT NULL CHECK (confidence IN ('authoritative','local_estimate','unknown')),
  resets_at   INTEGER,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (provider, window_kind)
);

-- Visible failure, not silent. Populated when a provider emits something no
-- manifest mapping matches -> surfaced by `station doctor`.
CREATE TABLE unmapped_event (
  provider       TEXT NOT NULL,
  provider_event TEXT NOT NULL,
  first_seen_at  INTEGER NOT NULL,
  last_seen_at   INTEGER NOT NULL,
  count          INTEGER NOT NULL DEFAULT 1,
  sample_json    TEXT,
  PRIMARY KEY (provider, provider_event)
);
