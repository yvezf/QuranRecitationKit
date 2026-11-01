# Security

QuranRecitationKit processes microphone audio entirely on-device. It makes exactly one kind of network request: downloading the model file from this repository's GitHub Releases when you call `ModelPack.download()`, verified against a pinned SHA-256 before use. It stores nothing but that cached model (Application Support). It has no analytics, no telemetry, and no account.

If you find a vulnerability (for example a way to make the model loader accept an unverified file, or a crash from crafted audio), please open a private security advisory on GitHub ("Security" tab → "Report a vulnerability") rather than a public issue. You will get a reply within a week.

Supported versions: the latest minor release.
