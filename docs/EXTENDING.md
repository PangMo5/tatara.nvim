# Configuration and extension points

```lua
require('tatara').setup({
  backend = 'tatara', -- executable or argv array, no shell expansion
  language = 'en', -- en, ko, ja, zh-Hans, zh-Hant
  layout = { sidebar_width = 52, stacked_below = 134, files = 'tree' },
  theme = 'auto', -- original Tatara flavors, or 'inherit'
  reduce_motion = false,
  progress = { native = false }, -- opt into native Progress messages/cancellation
  initial_view = 'diff', -- or 'overview'
  diff = { engine = 'difftastic' }, -- explicitly opt into 'native' if preferred
  keymaps = { comment = 'c', review = 'R', close = 'q', files = 'gF',
    find_files = '/', grep = 'g/', comments = 'gc', combined = 'gC',
    drafts = 'gP', reviewed = '<Space>', pick = '<C-p>',
    refresh = 'r', open = '<CR>' },
  -- Default providers are resolved at invocation, preserving user overrides.
  select = vim.ui.select,
  notify = vim.notify,
  -- Optional asynchronous, user-owned setup before opening immutable source.
  prepare = function(context, done)
    -- context.workspace, source, head, merge_base and path identify the checkout.
    -- Invoke your configured build-system setup here, then done(nil) on success
    -- or done(error_message) on failure. Never infer commands from PR contents.
    done(nil)
  end,
})
```

Use `false` for an action's key to disable it. Mappings are installed only in owned review buffers and never overwrite existing buffer-local user mappings. `gd`, `gr`, `K`, window movement, search and diagnostics remain editor configuration.

Pane navigation defaults to native `Ctrl-w` commands. `Tab` is left free for native `Ctrl-i` jumplist movement in terminals that encode them identically; optional `next_pane` and `previous_pane` mappings default to `false`.

From Files or the PR summary, `Ctrl-f`/`Ctrl-b` page the content pane and `Ctrl-d`/`Ctrl-u` move half a page while retaining sidebar focus. These buffer-local mappings are configurable as `page_down`, `page_up`, `half_page_down`, and `half_page_up`; source buffers retain their native page commands.

Public Lua functions: `setup(opts)`, `start({cwd, repository, host, number, demo})`, `open(opts)`, `close()`, `get_context()`, `open_file(path, {line, column, side})`, `comment(opts)`, `review()`, `refresh()`, `find_files()`, `grep()`, `comments()` and `list()`. `start()` schedules opening after `VimEnter` callbacks; use it in startup commands so native session restoration completes first. `open()` immediately creates the review tab and returns its ID. Columns supplied to `open_file` are Neovim byte columns. Never mutate returned context snapshots to control internal state.

Review sections and utilities are public too: `overview()`, `diff_view()`, `combined()`, `discussion()`, `checks()`, `drafts()`, `filters()`, `post_comment()`, `mark_reviewed()`, `browser()`, `theme()`, `notifications()` and `help()`. `list({kind, query, page, quick})` supports detailed and quick selectors; `grep(mode, query)` can start a specific search directly. `get_context()` exposes the current `view`, immutable source coordinates, `reviewable`, and a copied `selection` snapshot while selecting. Its `windows` include `summary`, `files`, `left` and `right` when visible. The selector keeps separate list/preview splits and does not change review ownership on movement.

The workspace keeps Tatara's own semantic chrome and original Catppuccin flavors while source syntax, diagnostics, modes and clipboard remain native. `theme()` changes only owned Tatara groups, with an inherit option. Notification overrides remain supported; the default is Tatara's bounded toast/details component. CLI overrides include `--language`, `--theme`, `--files-view`, `--sidebar-width`, `--wrap` and motion/accessibility flags. Existing setup is merged rather than discarded. Global banner/status options are restored on leaving the review tab. Native user window resizing/closing is respected; explicit Files navigation restores hidden panels.

Main panes use native split separators and title bars. Rounded borders belong only to real floating windows and follow `winborder`. Default stacking below 134 columns leaves at least 40 columns per source side with the 52-column sidebar; configure `stacked_below` to choose another threshold. Native source windows reserve the default automatic sign column for structural annotations on both sides, preventing asynchronous gutter changes from shifting wrapped alignment; explicit `signcolumn` configurations are retained. Compact comment editors temporarily reduce the other source pane and restore its height on close. Resizing an active editor keeps it attached to its source, and native window close preserves its draft body.

Semantic chrome groups include `TataraHeader`, `TataraFocus`, `TataraBorder`, `TataraStatus`, `TataraStatusMuted`, `TataraEditor`, `TataraFloatBorder` and `TataraFloatTitle`. They are scoped through owned-window highlights and do not replace the editor's colorscheme.

An optional `picker(request, choose)` receives `{kind, items, query}`. `request.query(text, callback)` asynchronously returns FFF matches and returns a cancellation function. Call `choose(path)` on acceptance or `choose(nil)` on cancellation. Keep the original items and use the supplied UTF-16 ranges for highlights. Without this override, an already configured MiniPick receives asynchronous FFF matching while retaining its setup. Otherwise the standard UI input/select providers remain available.

Preparation receives canonical `workspace` / `base_workspace` paths, the original `source`, provider-qualified `repository`, PR `number`, `head`, `merge_base` and `path`. A user-owned `vim.system(argv, {cwd = context.workspace, text = true}, callback)` can run `tatara prepare-analysis --plan PLAN --source SOURCE --workspace WORKSPACE --repository REPOSITORY --revision REVISION`. Schedule `done(nil)` only after successful completion, pass a failure message otherwise, and return a function that kills the obsolete process. Prepare the base checkout with `merge_base` too when its server needs build settings. Plans belong outside the reviewed checkout; only configured ignored build inputs may be copied. This retains the standalone preparation utility without introducing a Tatara-owned LSP client or guessing an Xcode scheme.

Native LSP navigation to unchanged tracked files retains read-only source protection and does not create review anchors. SDK or other external locations remain normal editor navigation. The original buffer options are restored when the review closes.

User events: `TataraReady`, `TataraWorkspaceReady`, `TataraFileOpened`, `TataraDraftChanged`, `TataraReviewSubmitted`, `TataraRefreshed`, `TataraProgress`, `TataraClosed`. Events use `nvim_exec_autocmds` with `data`; callbacks may observe context without patching implementation internals.

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'TataraFileOpened',
  callback = function(event)
    -- Existing LspAttach and diagnostics settings still apply normally.
    vim.notify(event.data.path)
  end,
})
```

Small choices such as reactions honor `vim.ui.select`. Configured MiniPick supplies live FFF/content search and quick PR selection, with immutable previews; Alt-m changes content-search mode. Standard-provider alternatives use the detailed selector or a native location list. Review completion and filters are coherent workspaces rather than selector cascades. Editing buffers remain native; `:write` is the primary action and domain shortcuts are buffer-local/configurable.

Insert-mode completion keys are left intact, including `<C-s>` when configured by a completion provider. Use `:write` for saving/previewing; the optional `<C-s>` convenience mapping exists only in Normal mode.

`layout.preview_on_focus` defaults to `true`: Files cursor movement previews the selected immutable file or directory while keeping focus in the tree. Enter opens the ordinary source buffer. `diff.context_folds` defaults to `false`; enable it explicitly to collapse only context outside the forge hunks. Review windows clear inherited structural folds rather than hiding changed declarations. Section mappings default to `<LocalLeader>1` through `<LocalLeader>4`, avoiding Markdown's native `gO`; `g[` / `g]` cycle sections.

## Review state and optional workflows

Saved inline drafts, summary/event, file marks and hunk marks use an account-scoped SQLite store at `$XDG_DATA_HOME/tatara/state/reviews.sqlite` (default `~/.local/share`). Identity includes forge, host, account, repository, item kind/number, merge base and head. Mutations run as individual transactions against fresh persisted state; independent editor additions merge. Submission removes only unchanged drafts actually included in the concrete preview. Old heads are retained separately and cannot be used as current inline anchors. A saved revision is bounded to 128 inline comments, 8 MiB of bodies, 20,000 file/hunk marks and 10 MiB encoded state. Each account can retain 128 revisions; the saved-review workspace offers explicit, version-checked removal rather than evicting drafts. Demo state is isolated and temporary.

`:write` in an inline editor persists its draft before returning to source. `:write` in the review form persists the summary and event before requesting a remote-write preview. Unsaved composer text remains local to the editor session. Failed saves remain visible. A file-level comment has a separate direct-publication preview using GitHub's file subject; it is never assigned a fabricated line or silently mixed into a batched line review.

Optional configuration:

```lua
require('tatara').setup({
  files = { include = '', exclude = '', hide_reviewed = false },
  comment_types = {
    { id = 'issue', label = 'Issue', prefix = 'issue: ' },
    { id = 'nit', label = 'Nit', prefix = 'nit: ' },
  },
  keymaps = {
    next_hunk = ']h', previous_hunk = '[h',
    next_file = ']f', previous_file = '[f',
    reviewed_hunk = 'gH', hide_reviewed = '<LocalLeader>h',
    filter_files = '<LocalLeader>f', suggest = 'gs',
    file_comment = '<LocalLeader>C', typed_comment = '<LocalLeader>c',
    export_review = '<LocalLeader>e', saved_reviews = '<LocalLeader>s',
  },
})
```

Filters are Neovim regexes over repository-relative paths; empty patterns impose no constraint. They scope Files, directory/root projections and file/content picker results without changing forge review anchors. No ignore file or executable configuration is read from the reviewed checkout. Full PR metadata totals remain visible alongside the filtered file count. Native `/`, `n`/`N`, window commands, source cursor and the existing Files FFF picker retain their roles. `gs` is buffer-local and does not replace native `s`.

Public functions: `set_file_filter({include, exclude, hide_reviewed})`, `filter_files()`, `toggle_reviewed()`, `mark_hunk_reviewed()`, `suggest({start_line, end_line, visual})`, `file_comment(path)`, `typed_comment()`, `export_review(format, destination)` and `saved_reviews()`. Export formats are `markdown` and `json`; the optional destination `clipboard` uses the configured provider. Buffer exports are ordinary unnamed Markdown/JSON buffers with native `:write` and no publish action. `TataraReviewProgressChanged` and `TataraFileFilterChanged` expose state changes without replacing editor handlers. Comment categories are opt-in text templates, not a mandatory taxonomy.

This implementation independently adapts review workflows to Tatara and native Neovim. It does not embed another terminal renderer. Local working-copy reviews, alternate VCS/forges and commit-range review targets require separate source/provider contracts; these are not implied by the current PR workflow.
