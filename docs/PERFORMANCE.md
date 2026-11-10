# Editor responsiveness

Use the Release backend and real Neovim PTY, with other builds/profilers idle:

```sh
mise exec -- swift Scripts/Tatara.swift build release
mise exec -- swift Scripts/Tatara.swift nvim-smoke
```

The PTY check opens a warm immutable two-file synthetic PR, sends 48 actual
native source h/l keys, and waits for synchronized terminal output with the
matching cursor position. It also moves between native windows, composes a
local inline draft, inspects the exact write preview, resizes from 176x48 to
80x32 and exits cleanly. No GitHub writes occur.

The local parity check recorded p95 0.311 ms and maximum 0.449 ms for these
48 warm cursor samples. These figures include terminal output/emulator handling;
they exclude initial checkout generation, real GitHub latency, SourceKit/BSP
preparation and display-compositor paint. They are not a general project-indexing
benchmark. Raw frames, screenshots and latency.json are in `.artifacts/neovim-pty`.

The extended PTY opens the combined root through the actual Files keys, verifies
the native source pane before timing, and validates Neovim's own 80x32 geometry
before inspecting both source sides in the narrow unified view. SwiftTerm's
pixel geometry is initialized so its negotiated in-band resize reports are
emitted. This matters because [Neovim's terminal implementation](https://github.com/neovim/neovim/blob/master/src/nvim/tui/tui.c)
uses those reports instead of SIGWINCH while that mode is enabled. Merely
resizing the emulator is insufficient evidence of editor layout behavior.

`swift Scripts/Tatara.swift nvim-test` separately validates ordinary immutable
file buffers, native LSP auto-attachment and diagnostics from a configured test
server, user mapping/options preservation, preparation-hook reuse, native
Ctrl-o/Ctrl-i jumps, narrow layout, composer retention, local drafts and explicit
write previews.

The parity integration additionally verifies source-text/coordinate agreement
for every projected row, direct single comments alongside pending reviews,
draft editing/removal, reactions, checks/discussion, filters, pagination and
issue comments. Native navigation to unchanged source remains read-only and
cannot acquire review anchors. A separate local check exercises the user's
configured MiniPick with live FFF matching, exact highlight ranges and native
source acceptance.
