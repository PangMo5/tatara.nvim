# Standalone functionality in Neovim

The capability inventory below is not evidence of UI/UX parity. The initial Lua implementation exposed many operations through plain buffers and nested selectors, but did not preserve Tatara's workspace or review flow. Its earlier completion claim was incorrect.

The standalone Tatara UI is the reference for information hierarchy, selection/preview, source presentation, inline conversation, review completion and feedback. Neovim provides real buffers, ordinary splits, editing modes, navigation, configurable mappings, LSP/diagnostics and extension APIs. An interaction that conflicts with those fundamentals should be adapted explicitly rather than imitating an independent terminal editor inside Neovim.

Acceptance requires side-by-side, same-scenario terminal captures and keyboard verification of the workspace, selection/preview, inline comment, review completion, thread reader and narrow layout. Backend tests and the presence of a command are insufficient. The following table describes available mechanisms, not completed interaction acceptance.

| Standalone capability | Neovim implementation |
| --- | --- |
| Difftastic structural alignment and directional token emphasis | Default structural renderer: immutable ordinary source buffers, difftastic alignment, semantic extmarks, native folds and virtual filler; explicit native-engine alternative |
| Root combined diff | `/` root / `:Tatara combined`; ordered, cancellable preparation with four concurrent reads |
| Narrow unified diff | Both removed/added source rows, immutable per-row coordinates, Enter to the real source buffer |
| Sticky filename and focused source row | Content winbar, suppressed duplicate path at the visible file header; native cursorline on the active source side |
| PR summary and metadata | Dedicated summary above Files; typed state, CI/reviews, branches, totals, assignees, reviewers, labels and milestone; complete overview |
| Overview / Diff / Discussion / Checks | Commands and `g[` / `g]`; native Markdown buffers and published-thread readers |
| Detailed PR/issue selection and quick switching | Full-window selector with loaded metadata, native `/` and `n`/`N`; Ctrl-p quick provider; `L` pagination; `I` kind switch |
| Forge queries, labels and named presets | `f` / `:Tatara filters`, built-ins, quoted label toggles, local SQLite save/delete |
| Files tree and flat list | Configurable `layout.files`; folding, parent navigation and root selection |
| File status, change totals, comments, reviewed markers | Files rows preserve forge status, nonzero counts, published-comment count, diagnostics and revision-scoped Space toggle |
| FFF file picker | Existing MiniPick setup with cancellable FFF matching, exact UTF-16 highlights and immutable preview; configurable picker contract / standard UI providers |
| Plain / regex / fuzzy content search | `g/`, immutable content search with exact side/line/column and native Search highlights |
| Source cursor, words, search, folds, wrapping, horizontal scrolling and paging | Native source buffers and motions; `gw` wrap toggle; normal editor viewport behavior |
| Jump back/forward and window movement | Native jumplist, Ctrl-o / Ctrl-i and window commands; optional buffer-local Tab / Shift-Tab |
| Single-line and range review comments | `c`, visual `c` and Ex ranges; forge-patch validation; derived display rows never become source coordinates |
| Single comment without starting a review | Post comment remains available with or without pending review drafts; separate concrete preview |
| Durable review state, hunk marks and export | Exact-revision/account SQLite state, file/hunk progress, saved revisions, Markdown/JSON ordinary-buffer export and clipboard output |
| Suggestions and file-level comments | Immutable new-side suggestion templates; separate previewed file-subject publication without fake source coordinates |
| File include/exclude scope | Native regex filters shared by tree, combined projections and file/content search; optional reviewed-file hiding |
| Pending comment editing, removal and navigation | `gP` / `:Tatara drafts`; stable draft IDs; retained across PR switches at the same head |
| Comment / Approve / Request changes | `R`; full summary and inline-comment preview, once-only confirmation, fresh ownership/account checks |
| Published conversations | Reader before actions; replies, edits, deletion, all eight reaction types, thread resolution/reopening, copy and permalink |
| Issues | Detailed selection, overview, discussion, permitted comment actions and previewed issue comments |
| Refresh and browser opening | `r` and `o`; refresh preserves an exact source location at the same head and invalidates stale previews |
| Notifications and progress | User `vim.notify`, native progress events and `:messages`; no periodic Tatara redraw while idle |
| LSP, diagnostics, BSP preparation | User-configured official Neovim LSP/diagnostic facilities on canonical checkout paths, including read-only navigation to unchanged source; explicit cancellable preparation hook and retained `prepare-analysis` utility; no parallel client |
| Theme, localization and accessibility | User editor colorscheme/cursor/clipboard/prose facilities, semantic highlight links, five localized UI catalogs and native colorscheme selection |
| Current-PWD entry point | `tatara`, `tatara --number N`, `tatara --list`, `tatara --issues`; native start-package registration for `:Tatara` |

Combined/unified projections are derived review buffers. Their rows can be searched and commented directly, and Enter opens the exact ordinary source buffer for the user's LSP. A projection is never presented to a server as if it were a real source file. Native Markdown rendering follows the user's installed prose tools.

Renderer-specific ASCII/color/motion controls and the old TOML UI file are superseded by editor configuration. Four Catppuccin flavors can be selected through the installed Neovim colorscheme; Tatara does not install or replace the user's theme, language server or notification plugin.

## Verification

`swift Scripts/Tatara.swift test` verifies backend source ownership, structural alignment, fresh comment permissions, reaction payloads, stable draft editing/removal/retention, pagination, issues, filters and once-only writes. `nvim-test` verifies native LSP/diagnostics and review capabilities through real Neovim. `nvim-smoke` verifies actual Release PTY keyboard, source/window movement, composition, preview, resize and launcher behavior. GitHub mutations are not exercised against a real PR by these checks.
