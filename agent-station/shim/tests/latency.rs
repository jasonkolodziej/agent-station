//! Latency guard. This test is the contract, not a nicety: if it fails, agents
//! get slower for every user on every hook event.
//!
//! Run: cargo test --release --test latency

use std::process::{Command, Stdio};
use std::time::Instant;

const BIN: &str = env!("CARGO_BIN_EXE_agentstation-hook");
const FAIL_OPEN_BUDGET_US: u128 = 5_000; // 5ms wall, generous for process spawn
const ITERATIONS: usize = 200;

#[test]
fn fail_open_path_is_fast_when_daemon_absent() {
    // Point HOME at a dir with no socket -> exercises the fast-exit branch.
    let tmp = std::env::temp_dir().join("agentstation-latency-test");
    std::fs::create_dir_all(&tmp).unwrap();

    let mut samples = Vec::with_capacity(ITERATIONS);
    for _ in 0..ITERATIONS {
        let t = Instant::now();
        let out = Command::new(BIN)
            .args(["--provider", "test"])
            .env("HOME", &tmp)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect("spawn");
        samples.push(t.elapsed().as_micros());
        assert!(out.success(), "shim must always exit 0 on the fail-open path");
    }

    samples.sort_unstable();
    let p99 = samples[(ITERATIONS as f64 * 0.99) as usize];
    assert!(
        p99 < FAIL_OPEN_BUDGET_US,
        "fail-open p99 {p99}us exceeds {FAIL_OPEN_BUDGET_US}us budget"
    );
}
