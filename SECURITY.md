# Security

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/yvezf/QuranRecitationKit/security/advisories/new), which is enabled for this repository. Include the affected version, platform, minimal reproduction and impact. Keep sensitive reports, recordings and credentials out of public issues. There is no guaranteed response deadline.

## Threat model

- An untokened localhost helper trusts local processes, including processes belonging to other local users; use `--token` on shared machines. It binds only to 127.0.0.1 and limits sessions/messages. It is not a remote service or a sandbox against a compromised host.
- Model bytes and embedded runtime bytes are size/SHA-256 verified before use. Cached corpus indexes are checked against the canonical source. The Unix temporary fallback is private (0700), per effective UID, and refuses symlinks, another owner, or group/other access.
- The SDK makes no outbound requests except an explicit HTTPS model download. Recognition and audio stay local. Explicitly starting the sidecar opens a loopback listener; loading the SDK never starts capture or a listener.

Only trusted host code should supply native handles, callbacks, corpus/model/runtime paths or an `ORT_DYLIB_PATH` override. C callers own buffer lifetime, must not free an in-use handle and borrow callback strings only during the call. Capture requires OS permission. Hosts must surface overruns, transport failures and inconclusive results; recognition confidence is not an authentication credential or pronunciation verdict.

## Supported versions

| Version | Security support |
|---|---|
| `main` | Current fixes and security checks |
| 0.3.x | Reports accepted; fixes are prepared on `main` for the next reviewed release |
| 0.2.x and older | No separate backport branch; upgrade to the maintained line |

The new cache and dependency hardening on `main` is not retroactively present in the existing 0.3.0 binary assets. Those published bytes remain immutable. See the release notes and verification reports for the exact source/archive revisions. Changing a source tag's documentation does not change a downloaded native archive.

The optional model-export environment is build tooling, not part of the shipped SDK or runtime. Its complete Python dependency graph is audited separately. Updating that environment does not promote or replace a model: a new candidate must pass the export fidelity/recognition gates before publication. Existing model hashes and model assets remain fixed.
