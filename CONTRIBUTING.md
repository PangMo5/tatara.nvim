# Contributing to tatara.nvim

Use the pinned tools through mise. The Lua UI targets Neovim nightly and uses official editor APIs. The Swift backend builds with SwiftPM and remains independent of Neovim presentation.

```sh
mise exec -- swift Scripts/Tatara.swift resolve
mise exec -- swift Scripts/Tatara.swift localizations
mise exec -- swift Scripts/Tatara.swift format
mise exec -- swift Scripts/Tatara.swift test
mise exec -- swift Scripts/Tatara.swift build release
mise exec -- swift Scripts/Tatara.swift nvim-test
mise exec -- swift Scripts/Tatara.swift lint
```

Keep public text in English and UI copy in the five-language catalog. Add backend tests for source ownership, concurrency and write safety, and Neovim integration tests for buffer/window lifecycle and public APIs. Check native LSP attachment without replacing user configuration. Validate visible editor behavior using the Release backend; tests alone do not prove perceived responsiveness.

Publication remains paused until explicitly resumed. Preserve local modifications, credentials and users' worktrees. The plugin never owns a user's global LSP/diagnostic configuration.
