---
description: Pre-commit gate — secret scan, lint, and the full test suite
---

Run the full check before handing work back or committing.

```bash
make check      # = check-secrets + lint + test
```

Handle each part properly:

1. **`Scripts/check_secrets.sh` — this one is not negotiable.** This repository is
   **public**. A finding means a real problem:
   - an API key, token or private key → remove it, and tell the user to **revoke and
     rotate it at the provider**. Deleting the line is not enough if it was ever
     committed or pushed.
   - an absolute `/Users/<name>/…` path → replace it. Scripts derive their root from
     `${BASH_SOURCE[0]}`; Swift uses `Bundle`/`FileManager`.
   - Never silence a finding by adding the `check-secrets:allow` marker unless the
     match is provably harmless, and say out loud why when you do.
2. **`Scripts/lint.sh`** — swift-format, advisory by default. Run `make format` to
   fix findings; do not hand-edit formatting one line at a time. If the tool is not
   installed the script skips with a message; that is fine, not a failure.
3. **`Scripts/test.sh`** — builds every target and runs the tests. See `/test`.

Then report honestly: what passed, what failed, and what you did **not** verify
(for example anything behind `#if SPEECH_ANALYZER`, which is not compiled unless the
machine has the macOS 26 SDK).

Do not run `git commit` or `git push` unless the user explicitly asked.
