//! agentstation-hook — the ingress shim.
//!
//! Invoked by every agent's native hook mechanism. Budget: <=10ms p99, and a
//! <1ms fail-open path when the daemon is absent. Gemini CLI blocks its agent
//! loop until hooks return; Claude Code's PreToolUse/UserPromptSubmit gate the
//! turn. A slow shim is a slow agent.
//!
//! DESIGN NOTE (see docs/adr/0003-zero-dep-shim.md):
//! The shim does NOT parse the provider payload. It splices the raw bytes into
//! an envelope as a verbatim `raw` member and lets the daemon do the work. This
//! is why there are no dependencies in Cargo.toml: no serde, no tokio, no
//! Foundation. Parsing is the daemon's job and the daemon is not on the hot path.
//!
//! Usage:
//!   agentstation-hook --provider claude-code            # payload on stdin
//!   agentstation-hook --provider codex --payload-argv    # payload in argv[last]
//!   agentstation-hook --provider cursor --await-decision # read one reply frame

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::time::Duration;

const PROTOCOL_VERSION: u32 = 1;
const MAX_PAYLOAD_BYTES: usize = 256 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_millis(50);
const WRITE_TIMEOUT: Duration = Duration::from_millis(50);
/// Only used with --await-decision. Must stay below the provider's own hook
/// timeout or we turn a permission prompt into a hung agent.
const DECISION_TIMEOUT: Duration = Duration::from_millis(8_000);

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        // FAIL-OPEN. Every error path exits 0. Agent Station must never wedge
        // someone's coding session. Diagnostics go to stderr, which every
        // supported provider captures without treating it as hook output.
        Err(e) => {
            let _ = writeln!(io::stderr(), "agentstation-hook: {e}");
            ExitCode::SUCCESS
        }
    }
}

fn run() -> io::Result<ExitCode> {
    let args = Args::parse(env::args().skip(1).collect());

    let payload = if args.payload_argv {
        // Codex hands the JSON blob as an argv argument, not on stdin.
        args.trailing.unwrap_or_else(|| "{}".to_string()).into_bytes()
    } else {
        read_stdin_capped(MAX_PAYLOAD_BYTES)?
    };

    let truncated = payload.len() >= MAX_PAYLOAD_BYTES;
    let envelope = build_envelope(&args.provider, &payload, truncated);

    let sock = match socket_path() {
        Some(p) => p,
        None => return Ok(ExitCode::SUCCESS), // no HOME; nothing to do
    };

    // Fail-open fast path: if the socket file is absent the daemon is not
    // running. Do not attempt to connect, do not wait. This is the branch that
    // has to cost microseconds.
    if !std::path::Path::new(&sock).exists() {
        return Ok(ExitCode::SUCCESS);
    }

    let mut stream = match UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(_) => return Ok(ExitCode::SUCCESS),
    };
    stream.set_write_timeout(Some(WRITE_TIMEOUT))?;

    if stream.write_all(&envelope).is_err() {
        return Ok(ExitCode::SUCCESS);
    }
    let _ = stream.write_all(b"\n");
    let _ = stream.flush();

    if !args.await_decision {
        return Ok(ExitCode::SUCCESS);
    }

    // --- Decision channel (Class A providers only) -------------------------
    // The daemon may answer with a decision frame that we translate into the
    // provider's own hook protocol. We NEVER synthesise an approval: absent or
    // malformed reply means "defer to the provider's own prompt", exit 0.
    stream.set_read_timeout(Some(DECISION_TIMEOUT))?;
    let mut reply = String::new();
    if stream.read_to_string(&mut reply).is_err() || reply.trim().is_empty() {
        return Ok(ExitCode::SUCCESS);
    }

    match decision_of(&reply) {
        Some(Decision::Deny { reason }) => {
            // Claude Code convention: exit code 2 blocks, stderr is fed back to
            // the model. Provider-specific translation lives in the manifest;
            // the shim implements only the two universal shapes.
            let _ = writeln!(io::stderr(), "{reason}");
            Ok(ExitCode::from(2))
        }
        Some(Decision::Allow { stdout }) => {
            let _ = io::stdout().write_all(stdout.as_bytes());
            Ok(ExitCode::SUCCESS)
        }
        None => Ok(ExitCode::SUCCESS),
    }
}

// ---------------------------------------------------------------------------
// Envelope construction — byte splicing, no JSON parse of the payload.
// ---------------------------------------------------------------------------

fn build_envelope(provider: &str, payload: &[u8], truncated: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 768);
    out.extend_from_slice(b"{\"v\":");
    out.extend_from_slice(PROTOCOL_VERSION.to_string().as_bytes());
    out.extend_from_slice(b",\"provider\":");
    push_json_string(&mut out, provider);
    out.extend_from_slice(b",\"received_at_ms\":");
    out.extend_from_slice(unix_millis().to_string().as_bytes());
    out.extend_from_slice(b",\"truncated\":");
    out.extend_from_slice(if truncated { b"true" } else { b"false" });

    out.extend_from_slice(b",\"focus\":");
    push_focus(&mut out);

    // Verbatim splice. If the payload is not valid JSON that is the daemon's
    // problem to report, not ours to discover.
    out.extend_from_slice(b",\"raw\":");
    if payload.is_empty() {
        out.extend_from_slice(b"null");
    } else {
        out.extend_from_slice(payload);
    }
    out.push(b'}');
    out
}

/// Focus context. THE critical field — see ARCHITECTURE.md §8.
///
/// This can only be captured here, in a process that is a child of the agent,
/// which is a child of the terminal. By the time the turn completes nothing in
/// the payload identifies which of eleven iTerm panes owns the run. Captured on
/// every event; the daemon keeps the first non-empty set per session.
fn push_focus(out: &mut Vec<u8>) {
    const KEYS: &[(&str, &str)] = &[
        ("term_program", "TERM_PROGRAM"),
        ("iterm_session_id", "ITERM_SESSION_ID"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("wezterm_pane", "WEZTERM_PANE"),
        ("kitty_window_id", "KITTY_WINDOW_ID"),
        ("ghostty_resources", "GHOSTTY_RESOURCES_DIR"),
        ("tmux", "TMUX"),
        ("tmux_pane", "TMUX_PANE"),
        ("zellij_session", "ZELLIJ_SESSION_NAME"),
        ("vscode_pid", "VSCODE_PID"),
        ("vscode_cwd", "VSCODE_CWD"),
        ("vscode_git_ipc", "VSCODE_GIT_IPC_HANDLE"),
        ("ssh_tty", "SSH_TTY"),
    ];
    out.push(b'{');
    let mut first = true;
    for (json_key, env_key) in KEYS {
        if let Ok(v) = env::var(env_key) {
            if v.is_empty() {
                continue;
            }
            if !first {
                out.push(b',');
            }
            first = false;
            push_json_string(out, json_key);
            out.push(b':');
            push_json_string(out, &v);
        }
    }
    if !first {
        out.push(b',');
    }
    push_json_string(out, "host_pid");
    out.push(b':');
    out.extend_from_slice(parent_pid().to_string().as_bytes());
    out.push(b',');
    push_json_string(out, "cwd");
    out.push(b':');
    match env::current_dir() {
        Ok(p) => push_json_string(out, &p.to_string_lossy()),
        Err(_) => out.extend_from_slice(b"null"),
    }
    out.push(b'}');
}

fn push_json_string(out: &mut Vec<u8>, s: &str) {
    out.push(b'"');
    for c in s.chars() {
        match c {
            '"' => out.extend_from_slice(b"\\\""),
            '\\' => out.extend_from_slice(b"\\\\"),
            '\n' => out.extend_from_slice(b"\\n"),
            '\r' => out.extend_from_slice(b"\\r"),
            '\t' => out.extend_from_slice(b"\\t"),
            c if (c as u32) < 0x20 => {
                out.extend_from_slice(format!("\\u{:04x}", c as u32).as_bytes())
            }
            c => {
                let mut buf = [0u8; 4];
                out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes())
            }
        }
    }
    out.push(b'"');
}

// ---------------------------------------------------------------------------

enum Decision {
    Allow { stdout: String },
    Deny { reason: String },
}

/// Deliberately minimal reply parsing. The daemon is trusted (uid-checked peer,
/// 0600 socket) and the reply grammar is two shapes. Anything unrecognised
/// returns None and we fail open.
fn decision_of(reply: &str) -> Option<Decision> {
    let r = reply.trim();
    if r.contains("\"decision\":\"deny\"") {
        let reason = extract_str(r, "reason").unwrap_or_else(|| "Denied via Agent Station".into());
        return Some(Decision::Deny { reason });
    }
    if r.contains("\"decision\":\"allow\"") {
        let stdout = extract_str(r, "hook_stdout").unwrap_or_default();
        return Some(Decision::Allow { stdout });
    }
    None
}

fn extract_str(hay: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\":\"");
    let start = hay.find(&needle)? + needle.len();
    let rest = &hay[start..];
    let mut out = String::new();
    let mut escaped = false;
    for ch in rest.chars() {
        if escaped {
            out.push(match ch {
                'n' => '\n',
                't' => '\t',
                other => other,
            });
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else if ch == '"' {
            return Some(out);
        } else {
            out.push(ch);
        }
    }
    None
}

struct Args {
    provider: String,
    payload_argv: bool,
    await_decision: bool,
    trailing: Option<String>,
}

impl Args {
    fn parse(argv: Vec<String>) -> Args {
        let mut a = Args {
            provider: "unknown".into(),
            payload_argv: false,
            await_decision: false,
            trailing: None,
        };
        let mut i = 0;
        while i < argv.len() {
            match argv[i].as_str() {
                "--provider" => {
                    i += 1;
                    if i < argv.len() {
                        a.provider = argv[i].clone();
                    }
                }
                "--payload-argv" => a.payload_argv = true,
                "--await-decision" => a.await_decision = true,
                other => a.trailing = Some(other.to_string()),
            }
            i += 1;
        }
        a
    }
}

fn read_stdin_capped(cap: usize) -> io::Result<Vec<u8>> {
    let mut buf = Vec::with_capacity(8192);
    io::stdin().take(cap as u64).read_to_end(&mut buf)?;
    Ok(buf)
}

fn socket_path() -> Option<String> {
    let home = env::var("HOME").ok()?;
    Some(format!(
        "{home}/Library/Application Support/AgentStation/agentstation.sock"
    ))
}

fn parent_pid() -> u32 {
    // SAFETY: getppid() is always safe and cannot fail.
    unsafe { libc_getppid() as u32 }
}

extern "C" {
    #[link_name = "getppid"]
    fn libc_getppid() -> i32;
}

fn unix_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_splices_payload_verbatim() {
        let e = build_envelope("claude-code", br#"{"hook_event_name":"Stop"}"#, false);
        let s = String::from_utf8(e).unwrap();
        assert!(s.contains(r#""raw":{"hook_event_name":"Stop"}"#));
        assert!(s.contains(r#""provider":"claude-code""#));
    }

    #[test]
    fn empty_payload_becomes_null_not_broken_json() {
        let e = build_envelope("codex", b"", false);
        assert!(String::from_utf8(e).unwrap().contains(r#""raw":null"#));
    }

    #[test]
    fn provider_name_is_escaped() {
        let e = build_envelope("evil\"name", b"{}", false);
        assert!(String::from_utf8(e).unwrap().contains(r#""evil\"name""#));
    }

    #[test]
    fn unknown_reply_fails_open() {
        assert!(decision_of(r#"{"decision":"maybe"}"#).is_none());
        assert!(decision_of("").is_none());
        assert!(decision_of("garbage").is_none());
    }

    #[test]
    fn deny_carries_reason() {
        match decision_of(r#"{"decision":"deny","reason":"blocked by user"}"#) {
            Some(Decision::Deny { reason }) => assert_eq!(reason, "blocked by user"),
            _ => panic!("expected deny"),
        }
    }
}
