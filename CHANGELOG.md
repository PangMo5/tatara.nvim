# Changelog

## Unreleased

- Rebuild the Lua UI around the original Tatara workspace and reviewer flow, with explicit Neovim adaptations instead of claiming command-level feature presence as UI parity.
- Restore visible content sections, paired combined diffs, inline conversation cards, anchored native editors, integrated review completion and query/preset/label workspaces.
- Keep real split navigation and user sizing/visibility, native Markdown/editing/LSP, cancellable list previews and live MiniPick search; restore global editor options outside review tabs.

- Convert the review workspace to a native Neovim plugin with a persistent Swift backend.
- Restore difftastic structural alignment, directional changed tokens, combined root and narrow unified views with exact source coordinates.
- Use normal immutable file buffers, native windows, motions, search and jumplists, including read-only LSP navigation to unchanged source.
- Restore detailed PR/issue selection, metadata, checks/discussion, forge filters, presets, pagination and reviewed markers.
- Add live FFF matching through configured MiniPick, stable editable draft IDs, single comments alongside pending reviews, and fresh permission-gated published thread actions.
- Inherit user LSP activation, diagnostics, mappings and UI providers without a parallel client.
- Preserve GitHub patch anchors, revision/account ownership and concrete single-use write previews.
- Expose public Lua functions, configurable buffer mappings, User events and optional setup hooks.
- Keep local source installation available; releases and publication remain paused.
