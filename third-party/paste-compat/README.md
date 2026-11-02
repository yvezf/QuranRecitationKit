# Maintained token-pasting backend

The pinned tokenizer uses `paste::paste!` internally. The upstream `paste` package is archived (RUSTSEC-2024-0436); its implementation is not used by this workspace.

This local, unpublished compatibility package contains one macro re-export from [pastey 0.2.3](https://crates.io/crates/pastey), the maintained successor recommended by that advisory. Its package name preserves the tokenizer's import path, while the implementation comes entirely from the separately audited registry package `pastey`. All three Cargo workspaces apply the same path patch. This is an implementation replacement, not an advisory ignore or a version-only relabeling of the old implementation.

The facade is MIT licensed; `pastey` retains its own upstream license. Corpus/tokenizer parity and the normal SDK tests exercise the tokenizer through this replacement. No tokenization, normalization, model, or acceptance code is forked here.
