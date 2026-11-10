# FFF search bridge

Tatara depends on the actual `fff-query-parser` crate from
[FFF](https://github.com/dmtrKovalenko/fff) and `neo_frizbee`, the same SIMD
matcher used by FFF. `Native/FFFBridge/Cargo.toml` pins FFF's Git revision;
`Cargo.lock` pins every Rust dependency and registry checksum.

The bridge searches the PR's immutable changed-path list. It does not start
FFF's filesystem walker, watcher, content index, or frecency database. Deleted
files remain searchable, and the local checkout cannot change the candidate set.
Filename weighting follows FFF's scoring policy. Short queries disable typos;
longer queries use FFF's bounded typo allowance. File paths, extensions, globs
and exclusions are supported; unavailable type/status qualifiers fail visibly.
All matches are returned, without pagination or a time budget.
Matching explicitly ignores case; case-aware scoring only affects ordering.
Highlight offsets include independently matched filenames even when the best
full-path alignment lands in an ancestor directory. Both use the same matcher.

`TataraFFF.xcframework` is a static arm64/x86_64 macOS library consumed directly
by SwiftPM. Ordinary Swift builds and the installed executable need no Rust
toolchain or dynamic bridge library. The checked-in binary keeps clean SwiftPM
builds independent of Cargo and network downloads. `upstream.json` records the
input and archive hashes. Preserve `LICENSE.txt` when redistributing.

To rebuild from source with the pinned mise toolchain:

```sh
mise exec -- rustup target add aarch64-apple-darwin x86_64-apple-darwin
mise exec -- swift Scripts/FFF.swift
mise exec -- swift Scripts/Tatara.swift notices
```

The Swift script builds both slices with `cargo --locked`, remaps machine paths,
packages the static archive, and regenerates provenance and dependency licenses.
