# tatara.nvim

## Language and development

- Write repository guidance, documentation, commits and source comments in English. User-facing copy belongs in `SharedResources/Localizable.xcstrings`, with complete en, ko, ja, zh-Hans and zh-Hant entries.
- `Package.swift` and `Package.resolved` are authoritative. Use SwiftPM through mise; no generated Xcode project is needed. Run `swift Scripts/Tatara.swift localizations` after catalog edits; never edit generated tables directly.
- The Swift backend supports macOS 15+, Swift 6 strict concurrency and the pinned Xcode/SDK. Preserve `dev.PangMo5.tatara`, explicit Mach-O deployment/SDK fields, signing and the bundled `libswiftCompatibilitySpan.dylib` runtime.
- Write project automation in Swift. Use Swift Testing for backend tests and real Neovim for editor integration tests. Verify nonzero executed test counts and the installed Release runtime.

## Architecture

- Neovim owns the UI, windows, source cursor, search, jumplist, filetypes, syntax, LSP clients and diagnostics. Never launch a parallel language server, replace users' LSP handlers, change diagnostic configuration or install global navigation mappings.
- Prefer current official Neovim APIs. Nightly Neovim is the initial target. Use ordinary file-backed source buffers with their true managed-checkout paths so FileType, BufRead and LspAttach work normally.
- Keep the plugin extensible through public Lua functions, buffer-local configurable mappings, semantic highlight links, User events, `vim.ui.select`, `vim.ui.input` and `vim.notify`. Keep user windows, buffers, mappings and options intact outside the owned review session.
- `TataraCore` owns portable Sendable models, source coordinates and review invariants; `TataraKit` owns explicit Sendable client contracts; `TataraGitHub` implements the forge contract exclusively through `gh`; `TataraSystem` owns subprocesses, immutable worktrees and difftastic; `TataraPersistence` owns account-scoped SQLite caching; `TataraBridge` owns versioned editor RPC and review sessions; `TataraCLI` owns launch/serve/preparation entry points.
- The backend is a long-lived process per editor review session. Commands are executable/argument arrays, never shell strings. Stdout contains only framed protocol messages; diagnostics go to stderr.
- UI input and selection respond immediately. Cancel obsolete reads and validate repository, item, immutable revisions, file and request generation after every suspension. Keep parsing, I/O and indexing on workers, with no UI locks across them.
- Bound protocol frames, outstanding requests, drafts, previews, caches and worktrees. Give caches explicit identity, invalidation and eviction. Keep persistence atomic and scoped by forge, account, host and repository.

## Review and source ownership

- Every diff compares immutable merge-base/head content and preserves rename provenance. Never substitute a two-dot diff, edit the user's checkout or read its uncommitted contents as reviewed source.
- Local blobs require proven remote identity and exact commit identity, raw-byte preservation and disabled lazy fetch. Only absence/capability limits choose forge content; local/protocol failures remain visible.
- An isolated managed checkout belongs in the data directory. Validate HEAD and tracked source before reuse. Materializing review files must not start LSP or generate BSP metadata. Build-system preparation is an explicit user-owned hook, never forge-authored configuration.
- Source buffers are read-only during a review. Preserve pre-existing buffer options and local mappings on close. Do not overwrite modified buffers. Opening a file starts on its first changed source; explicit content-search and navigation coordinates take precedence.
- Inline anchors come from the forge patch and immutable source coordinates, never visual diff columns. Published annotations never create review anchors.
- Every remote write requires a concrete preview tied to account, item and reviewed revision. Consume its token once, refresh permissions and remote ownership, and never retry writes automatically. Preserve failures visibly and keep contextual validation with its input.
- Native diagnostics belong to Neovim. The plugin may display preparation status but must not confuse a server's background work with a query's completeness or infer readiness from a generic progress notification.
- Difftastic owns structural alignment and directional changed-token emphasis by default. Preserve complete source alignment through the backend; do not substitute Neovim's line diff unless explicitly configured. Use native, indexed folds and virtual filler without modifying source bytes or line numbers.
- Combined/unified projections are derived buffers with explicit per-row immutable source identities. Validate comments against original forge coordinates, and open the true source buffer for native LSP rather than attaching a server to a projection. Keep sticky paths consistent with their visible file headers.
- Preserve the original Tatara information hierarchy and review workflow. Adapt conflicts with Neovim's real buffers, ordinary splits, modes, navigation and user configuration explicitly; do not replace the product UI with generic text lists or nested selectors. `docs/NEOVIM_PARITY.md` is a capability inventory, not proof of experience parity. Acceptance requires same-scenario reference/current screen and interaction comparisons.
- Keep detailed selection/preview, query presets/pagination, visible content sections, contextual comment composition, review completion and thread actions in coherent workspaces. Capture ownership across picker callbacks; stable draft IDs and fresh permissions are required for mutations.

## Distribution

- This is a Neovim plugin with a Swift backend; `tatara` launches Neovim rather than a separate terminal renderer. Neovim and its user configuration remain explicit runtime dependencies.
- Do not publish releases, tags, Homebrew formulae or unverified installation paths while publication is paused. Update repository metadata only within the user's explicit authorization.
- Run formatting, catalog, notices and REUSE checks before publication. FFF's Cargo lockfile, native archive, source hashes and notices must stay synchronized; rebuild through `Scripts/FFF.swift`.
