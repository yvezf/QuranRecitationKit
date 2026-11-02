# Security/privacy hardening — November 2026

## Repository and history

One content/message history rewrite removed a private recording filename/detail and internal process references from every public branch and model/SDK tag. The repository had zero forks at the rewrite. Commit author/committer email fields were not changed by this operation. Reachable commits retain the repository account's public noreply identity; the API resolves authors to `yvezf`.

Release asset IDs, names, sizes and SHA-256 digests were compared before/after. All were unchanged:

| Tag | Assets |
|---|---:|
| model-v1 | 2 |
| model-v2 | 5 |
| v0.1.0 | 15 |
| v0.1.1 | 0 |
| v0.2.0 | 15 |
| v0.2.1 | 15 |
| v0.3.0 | 15 |

Release targets now match the rewritten tag commits. Release metadata was scrubbed and its internal commit references remapped where possible. Release and CI workflows were disabled for the atomic ref replacement and re-enabled afterward. A local ignored backup and before/after receipts were retained; no backup was pushed.

Rewriting refs does not delete GitHub's unreachable objects or cached views. A maintainer must request that purge from GitHub Support. No support message was sent automatically.

## Repository controls

- GitHub private vulnerability reporting, Dependabot alerts/security updates, secret scanning and secret-scanning push protection are enabled.
- Main requires the six platform/Swift checks and `supply-chain`; the policy applies to administrators, requires an up-to-date/linear history and blocks force pushes/deletion.
- Weekly Dependabot configuration covers Actions, all three Cargo workspaces, Node production dependencies, Python/export requirements and the .NET project.
- Every third-party workflow action is pinned to its reviewed full commit SHA with the original version/ref in a comment.

The required check names are the actual job names emitted by Cross-platform CI, not an invented workflow-name status. Settings responses and audit receipts were checked through the authenticated API; no credentials were printed or committed.

## Dependency and license gates

`tools/check_supply_chain.py` checks all three Cargo lockfiles with `cargo audit` and `cargo deny`, production npm dependencies, the complete resolved export Python graph and action pins. The same script runs as a required CI job; receipts are uploaded by CI without recordings or model files.

`deny.toml` permits the requested MIT, Apache-2.0, BSD-2/3, ISC, Unicode, Zlib and MPL-2.0 families. It explicitly spells out **Apache-2.0 WITH LLVM-exception** for PyO3's build-time target metadata: this is Apache-2.0 with additional redistribution permissions. No new license family or copyleft allowance is introduced. The unused Unicode legacy identifier and legitimate parallel dependency major versions can produce non-security warnings; vulnerabilities, unmaintained implementations, rejected licenses and unknown sources fail the gate. There are no advisory ignores.

Changes prompted by the checks:

- PyO3 moved from 0.23 to patched 0.29.3; the binding uses `Python::detach` and keeps its existing synchronization/API.
- The archived token-pasting implementation is replaced by the maintained `pastey` implementation through a one-re-export, unpublished compatibility facade. The tokenizer remains pinned to 0.22.2; its algorithm is not forked. The historical all-ayah token oracle and regression tests check parity.
- TLS uses the operating system's root store through rustls rather than shipping certificate data under a license outside the allowlist. TLS verification remains enabled.
- The unused ONNX ndarray feature was removed.
- The optional export toolchain now uses patched packages, including NeMo 3.0's minimal ASR/common extras and explicitly patched training-interface dependencies. The old extras' vulnerable Hydra/Lightning caps are not installed. The full resulting graph is still audited; dependencies are not omitted from the security report merely because they are transitive. The isolated environment successfully imports the actual exporter class after two version/hash-guarded compatibility adjustments: an annotation is widened for Lightning's optional bool, and an obsolete optional Neptune training logger is explicitly disabled for export. Override checks stay enabled. Neither patch changes model/checkpoint computations or ships in the SDK.

This package-level Rust SPDX check concerns code dependencies. It does not relabel the separately documented NVIDIA model or verbatim Tanzil data, whose attribution and CC BY terms remain in THIRD_PARTY_NOTICES.

## Cache boundary

`qrk_onnx::cache_directory()` is fallible. If platform user-data resolution fails on Unix, it atomically creates `$TMPDIR/QuranRecitationKit-<effective-uid>` with 0700 mode and checks `lstat` metadata. Existing non-directories, symlinks, another owner and group/other permission bits are refused. Other platforms fail closed if a private per-user data directory cannot be resolved.

Model, corpus-index, quotation-index and embedded-runtime operations propagate this error. The C cache query returns null plus `qrk_last_error`; Swift revalidates the native cache on each default download instead of trusting a cached path. Explicit host-selected paths remain trusted host configuration. Normal platform data paths and existing C ABI signatures are unchanged; Rust callers of the cache helper now handle its `Result`.

Unix tests cover 0700 creation/reuse, wrong-owner validation, shared permissions, pre-existing files and symlinks. The wrong-owner branch is exercised without requiring privileged ownership changes in CI.

## Limits and release state

This hardening is source work following the already published 0.3.0 assets. Existing SDK/model archive bytes and their Swift checksum pins remain unchanged; source fixes are not retroactively inside those binaries. No new version tag is created by this work.

The updated export environment is distinct from the historical environment that produced model-v2. A successful dependency audit or import is not a new model fidelity result. A newly exported candidate must still pass the manual model workflow and owned-audio gates; current model-v2 remains hash-pinned and unchanged.

The larger lecture benchmark is blocked by recording-license evidence, not reported as passing. See [the dataset revisions, method and unmeasured gate table](SPOT-EVAL-2026-11.md). No spot acceptance thresholds were tuned in this hardening change.
