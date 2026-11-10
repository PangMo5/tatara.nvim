# Install tatara.nvim

Tatara builds a local macOS backend from the same source checkout as its Neovim plugin. Choose one way to load the plugin so each editor starts one copy of the runtime.

## Prerequisites

- Current Neovim nightly (0.13+) and macOS 15 or newer.
- Xcode 27.2 with Swift 6.4.2 and the macOS 27.2 SDK. Select Xcode with `xcode-select` or set `DEVELOPER_DIR` in the environment that launches Neovim or runs the build.
- `git`, GitHub CLI (`gh`), and Difftastic (`difft`) visible to Neovim. Run `gh auth login` for the host you review.

Check the tools before installation.

```sh
nvim --version
xcodebuild -version
swift --version
gh auth status
difft --version
```

SwiftPM uses the committed `Package.resolved` and FFF archive. Building Tatara from a checkout requires network access to resolve Swift dependencies on the first build. The Rust toolchain is used when rebuilding the FFF archive.

## vim.pack

Add Tatara to your Neovim configuration with current Neovim nightly that supports `:help vim.pack-manifest`.

```lua
vim.pack.add({ { src = 'https://github.com/PangMo5/tatara.nvim', version = 'main' } })
-- Optional settings
-- require('tatara').setup({ language = 'ko' })
```

The package manifest runs the backend build when `vim.pack` installs or updates Tatara. To update Tatara, run `:lua vim.pack.update({ 'tatara.nvim' })` and restart Neovim after the build finishes. Neovim records the selected revision in its pack lockfile. [Neovim package documentation](https://neovim.io/doc/user/pack.html)

## lazy.nvim

Add this spec to your Lazy configuration.

```lua
{ 'PangMo5/tatara.nvim', branch = 'main', cmd = 'Tatara', opts = {} }
```

Lazy runs the repository's `build.lua` on install and update. Restart Neovim after an update. To rerun the hook, use `:Lazy build tatara.nvim`. Put optional Tatara settings in `opts`. [Lazy build hooks](https://lazy.folke.io/developers#building)

## Other managers and manual loading

Point your manager at `https://github.com/PangMo5/tatara.nvim` on `main` and build from the directory it checks out. Repeat the build after updating the checkout.

```sh
swift Scripts/Tatara.swift build release
```

For a checkout you manage yourself, prepend it to `runtimepath` before startup plugin loading. This example also works after startup.

```lua
vim.opt.runtimepath:prepend(vim.fn.expand('~/src/tatara.nvim'))
vim.cmd.runtime('plugin/tatara.lua')
require('tatara').setup({})
```

The source runtime looks up the Release backend under `.artifacts/products/release-<architecture>/tatara`. If you supply a backend explicitly, point `setup({ backend = '/absolute/path/to/tatara' })` at a build compatible with the loaded runtime.

## Terminal launcher and native start package

```sh
git clone https://github.com/PangMo5/tatara.nvim.git
cd tatara.nvim
swift Scripts/Tatara.swift build release
swift Scripts/Tatara.swift install-local
```

Add `~/.local/share/tatara/local/bin` to PATH. The installer keeps the Swift compatibility library beside the executable and registers the runtime under `stdpath('data')/site/pack/tatara/start/tatara.nvim`. Run `:packadd tatara.nvim` to load it in a running editor or restart Neovim. To update, pull the source, rebuild, and rerun `install-local`.

If you switch from this installer to a plugin manager, locate the start package with `:echo stdpath('data')` and remove the `site/pack/tatara/start/tatara.nvim` symlink created by the installer. Keep the manager's checkout as the single runtime.

## Verify and integrate

Open `:Tatara demo` to exercise the backend with synthetic data, then open a real repository with `:Tatara` or `:Tatara 123`. Run `:checkhealth tatara` for the Neovim version, resolved backend, and command availability. If a build hook failed, fix the reported toolchain or SwiftPM error and run the build again from the plugin checkout.

Configure LSP, Tree-sitter, themes, completion, and diagnostics through your usual Neovim plugins. Tatara uses your editor's native buffers, semantic highlight links, and UI providers. An already configured MiniPick can supply live path and content search. Small selections honor your `vim.ui.select` provider. See [configuration and extension points](EXTENDING.md).
