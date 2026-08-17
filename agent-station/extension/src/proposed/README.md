# Proposed-API code lives here and is excluded from the published build

`chatSessionsProvider` is a **proposed** VS Code API. Proposed APIs are
Insiders-only and cannot be used in published extensions; `vsce` hard-errors at
publish time if `package.json` declares `enabledApiProposals`. The "blessed"
escape hatch is an allowlist in VS Code's own `product.json`
(`extensionEnabledApiProposals`), which only Microsoft controls.

So: **nothing in this directory can ship to the Marketplace.**

- `tsconfig.json` excludes `src/proposed`
- `package.json` must never gain an `enabledApiProposals` key on the release build
- Build the bridge variant with `npm run build:insiders`, distribute as VSIX,
  and launch with `code-insiders --enable-proposed-api agentstation.agent-station`

This is the M0a spike surface. If `chatSessionsProvider` finalizes, promote this
code into `src/` and delete this note. If it stalls for two release cycles, cut
the bridge from the pitch and lead with focus routing instead.
