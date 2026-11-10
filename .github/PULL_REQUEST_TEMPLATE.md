# GitHub Actions: valid YAML but no runners needed for these checks.

Contributions welcome. Before opening a PR:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-cguard.ps1
```

CI runs the same suite on PowerShell 5.1 and 7, plus a parse check of every
script and a "clean must refuse to delete without -Force" check.

## Three rules that will get a PR rejected

1. **A `safe` target that holds real data.** When in doubt it is `review`.
2. **A cleanable target without `minAgeDays`.** An agent may be writing there
   right now.
3. **Weakening a test to make a target pass.** The tests encode the safety
   model; if a target needs an exception, the target is wrong.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full guide.
