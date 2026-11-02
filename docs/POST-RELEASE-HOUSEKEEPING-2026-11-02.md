# Post-release housekeeping — 2026-11-02

No history rewrite or force push is part of this work. Existing SDK/model tags and published asset bytes remain fixed. Main advances through ordinary reviewed/tested commits.

## Completed pull-request review

PR #14 updates only the CLI's base64 dependency and corresponding lock entry. All seven required checks passed before its normal merge (`571658a86a61097afb029c32fd5346c5a06aeda7`). The API used by the codec remains compatible and the transport/integration checks passed. A pre-1.0 version increment is not treated as automatically safe merely because it is labelled minor.

The other 24 proposals were closed with one-line reasons:

| PRs | Reason |
|---|---|
| #1 | Superseded by the validated datasets 5.1.0 pin already on main |
| #2, #3, #20, #23 | ONNX/Torch/ONNX Runtime export or inference changes need independent fidelity/compatibility validation |
| #5, #7, #12, #18, #22 | Major Action/runtime upgrades need dedicated workflow/release compatibility review |
| #6, #10 | Major Node native-binding updates fail required checks |
| #8, #15 | Tokenizer changes can change the runtime index and recognition decisions |
| #9 | Pre-1.0 PyO3 compatibility update kept separate; current patched binding remains validated |
| #11, #16, #24 | Export-environment proposals fail required checks; retain the validated environment |
| #13, #17, #19 | SHA-256 API updates fail required checks |
| #21 | Transport behavior requires a dedicated sidecar compatibility review |
| #25 | Capture/resampling behavior changes and failing checks need a device review |
| #26 | .NET major dependency/framework compatibility review required |

Obsolete CI runs for closed proposals were cancelled without disabling any workflow. The merged `codex/spot-mode` and `codex/security-hardening` remote branches were deleted; main already contains both histories. Closed dependency proposal branches were removed as part of the same cleanup.

## Weekly update policy

There is one configuration block for each of Actions, Cargo, npm, pip and NuGet. Cargo's three workspaces and pip's two directories share their ecosystem configuration. Each has one wildcard version-update group and an open version-PR limit of one, scheduled for Monday at 09:00 America/New_York. This bounds routine open version-update proposals to one per ecosystem instead of a proposal per dependency/directory.

Security updates have separate wildcard groups so urgent vulnerability fixes do not wait for the weekly version-update schedule. No auto-merge rule is introduced. A future group containing engine, runtime, tokenizer, transport, audio or model-export changes still needs the corresponding parity/compatibility/fidelity review; grouping is a review/noise policy, not evidence those updates are safe.

Configuration behavior follows [GitHub's Dependabot options reference](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference).

## Recognition scope

The source fixes and measured before/after results prepared for 0.3.1 are in [SPOT-RECALL-0.3.1.md](SPOT-RECALL-0.3.1.md). The existing larger benchmark requirement remains unmeasured. No published tag is moved and no new native release is claimed by this housekeeping change.
