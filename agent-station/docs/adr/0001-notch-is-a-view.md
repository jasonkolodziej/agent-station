# 0001 — The notch is a view, not the app

## Context
macOS ships no Dynamic Island API. Every app in this category (NotchNook,
Alcove, Boring Notch, DynamicLake, Notchy) implements the same technique: a
borderless transparent `NSPanel` at `CGShieldingWindowLevel`, drawing a shape
with concave Bézier ears that fuse with the physical cutout.

## Decision
State lives in an always-on `LaunchAgent` daemon. The notch panel, menu bar,
VS Code extension, and CLI are all clients over a Unix domain socket.

## Consequences
- The panel can crash, be occluded, or be lost on display reconfiguration
  without losing session state.
- Hooks fire from processes we don't control at times the UI may not be running;
  the daemon is the only always-on receiver.
- Cost: two processes to install, sign, notarize, and keep version-compatible.
- The panel must not steal focus (`.nonactivatingPanel`,
  `becomesKeyOnlyIfNeeded = true`). A notch UI that grabs focus mid-typing gets
  uninstalled the same day.

## What would reverse this
Apple shipping a real activity API for macOS. Then the daemon stays but the
panel becomes a system surface and arbitration moves out of our hands.
