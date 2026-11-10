# Tatara workspace on Neovim

The product reference is the original Tatara review workspace, not a collection of Neovim commands. The Lua frontend is being rebuilt around that distinction. Existing GitHub/source/write contracts remain in the Swift backend.

## Keep the review experience

- The workspace keeps a current-PR summary above a tall Files tree, with the review content beside it. Below the configurable default of 134 columns, the sidebar and content each occupy about half the height. The default sidebar is the original 52 columns.
- Overview, Diff, Discussion and Checks remain visible, directly selectable sections. Files retain status, nonzero change counts, published-comment counts, diagnostic badges and reviewed markers.
- The root shows paired structural source in a wide workspace and unified source in a narrow workspace. Difftastic alignment and exact path/side/line ownership survive both presentations. Comments remain beside their source as conversation cards rather than an end-of-line abbreviation.
- Structural scroll synchronization uses native viewport APIs and difftastic coordinates to correct native scrollbind across virtual filler. It does not remap scrolling keys and honors a user's `noscrollbind`. Sticky filenames use the same semantic path color as their source headers.
- PR selection shows compact detailed entries with a separate, cancellable preview. Moving the preview does not switch the reviewed item; Enter accepts it and Escape restores the previous workspace. Quick selection uses configured MiniPick when available.
- `c` opens an editing buffer near the source anchor, spanning the content group. Source selection remains visible; the editor opens above when space below is insufficient. Writing adds a local draft directly; `<LocalLeader>p` / `:Tatara post_comment` previews a single published comment, including while a review is pending.
- `R` opens review completion directly: summary, visible Comment/Approve/Request changes selection, and a pending-comment window. Event changes preserve text. Pending comments can be edited, removed or opened in source. Preview and Back retain the editing buffer and event.
- Filters expose the query, presets and labels together. Writing the query applies it; Enter selects a preset or toggles a quoted label; deleting/saving a preset remains a local operation.
- Published readers offer freshly permitted actions directly (`r`, `e`, `d`, `a`, `s`, `y`, `o`), with a concrete preview before each mutation. There is no action-menu cascade.
- Backend errors use a bounded notification component with a details reader. Loading uses the original forge artwork only while work is active; reduced-motion presentation remains still. Backend activity uses the statusline by default, avoiding duplicate completion toasts over the editor. Optional native progress messages start after 150 ms of sustained work. User LSP progress remains independent.

## Adapt to Neovim fundamentals

- Main panes and review/filter children are ordinary windows. Standard `Ctrl-w` navigation, splits and native viewport operations remain usable. The plugin does not draw a separate terminal emulator over Neovim.
- Review URI buffers are transient. Native `SessionLoadPost` removes only empty, unmodified URI placeholders that have no live backend; real buffers, modified work and nonempty URI content remain intact. Session managers can observe normal User events; automated user-configuration checks stop autosaving in their test process.
- Ordinary panes use connected native separators with plain title bars. They do not imitate rounded floating frames through statuscolumns or window bars. Real popups follow `winborder`, stay attached across resize, and use a consistent border/body surface. A global statusline exposes the active pane's actions without stale child-window overrides. Compact composition keeps the selected source visible and restores the other pane's height afterward.
- Editors are real `acwrite` Markdown buffers. Insert/Normal mode, motions, undo, registers, `q` macro recording, completion and `:write` are native. Domain actions use buffer-local mappings; Insert-mode completion keys are not reassigned to posting. Escape in Normal mode returns to source; `q` closes read-only readers and previews.
- Individual source views use canonical immutable file paths and normal buffers. User FileType/LspAttach configuration, language servers, diagnostics and mappings remain in charge. Navigation to unchanged source stays read-only without inventing review anchors.
- Combined projections represent multiple files and cannot be sent to a language server as one document. Enter reveals the exact real file; configured definition/reference/hover keys reveal it and delegate to the user's source mapping.
- The banner/section strip uses the native tabline, and context/actions use a native global statusline. This deliberately replaces the standalone two-row footer instead of covering real source rows with an overlay. Global options are restored outside the owned review tab.
- Read-only prose uses native Markdown/Tree-sitter presentation. Source is never interpreted as Markdown. Colors are owned semantic groups, with the original Catppuccin flavors and an inherit option; the rest of the editor is not recolored by choosing a Tatara flavor.
- FFF and content search use the user's MiniPick layout/mappings where configured. Without that provider, content results use a native location list with immutable result acceptance. LSP/BSP setup remains an explicit user-owned hook, never a second client or guessed project setup.

## Acceptance evidence

Use the preserved standalone executable and the new frontend at the same terminal size for workspace, inline-comment and review-completion captures. The source and derived-row text must agree for both source sides. Keyboard checks must cover direct save/post, preview/back, event/text retention, pending edits/removal, list/preview ownership, query/label interaction, resize and restoration of user work/options.

`tests/nvim/workbench.lua` exercises those transitions through public APIs and actual window/buffer actions. `Scripts/NvimSmoke` captures the standalone reference and the current workspace and verifies real Release PTY keyboard behavior. Passing backend tests, or exposing an operation through a menu, is not visual/interaction acceptance and must not be reported as complete equivalence.

Screen-row comparisons cover visible, unfolded source outside modal overlays. The user's fold policy can collapse inactive source and remains intact. Composer checks separately require a visible source anchor, retained Insert mode/focus, and the correct active action hints after resize. Insert completion keys remain user-owned; save through `:write`.

`mise exec -- swift Scripts/Tatara.swift nvim-ui-audit` exercises the review flows at 176×48, 160×24, 120×40, 100×32, 80×32 and 64×24. Captures include actual terminal PNG/text, native window geometry, title evaluation, active statusline ownership, and screen-row agreement with difftastic alignment. It covers comment/review/preview/filter/selection flows, border preferences, theme inheritance and live resize. Set `TATARA_UI_AUDIT_USER_CONFIG=1` to opt into additional runs with the real user configuration, `TATARA_UI_AUDIT_OUTPUT` to choose an artifact directory, or `TATARA_UI_AUDIT_PROFILES` to rerun a failing comma-separated subset. Visually inspect the PNGs; assertions do not establish visual quality.

`TATARA_SCREENSHOT_STYLE` selects an installed-font/color/line-height JSON profile for actual terminal-cell captures. User-configuration checks stop Persisted autosaving through its public API after startup, preserving session restoration coverage without writing test layouts to the user's session files.
