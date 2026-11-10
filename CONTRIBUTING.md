# Contributing

The most useful contribution to cguard is **a target entry**, because the tool
is only as good as its map of where disk space actually goes.

## Adding a target

Edit `config/targets.json` and add one object. Then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-cguard.ps1
```

The schema test will fail your PR if a target is missing `id`, `tier`, `group`,
`label` or `reclaim`, or uses an unknown tier or reclaim mode.

### Choosing a tier

| tier     | use when                                                | examples                                                     |
| -------- | ------------------------------------------------------- | ------------------------------------------------------------ |
| `safe`   | deleting costs a re-download or a cold start            | temp dirs, package caches, thumbnail cache, update payloads  |
| `apps`   | it is a runtime or model the agent re-fetches on launch | Codex runtimes, Playwright browsers, OEM repair snapshots    |
| `review` | it is the user's data or something that breaks tooling  | sessions, config, installed extensions, vhdx disks, pagefile |

**If in doubt, use `review`.** A target in `review` is measured and reported but
never deleted, which is a harmless outcome. A wrong `safe` entry deletes
someone's work.

### Choosing a reclaim mode

- `delete-contents` — empty the folders, keep the folder itself. Almost always
  what you want: several tools recreate their cache dir only on demand and
  break if the path is missing.
- `subdirs` — the folder holds both a live database and reclaimable children.
  List the children in `subdirs`. This is how `opencode.db` survives while
  `shell` and `tool-output` are emptied.
- `cmdlet` — the vendor ships an official cleaner; call it instead of deleting
  files underneath the vendor. `Delete-DeliveryOptimizationCache` is the only
  current example.
- `report-only` — never deletable.

### Required safety fields

Every cleanable target must set `minAgeDays`. Ask: _if an agent were running
right now, could it be writing to a file I am about to delete?_ If yes, that is
your minimum age.

Every target whose folder contains a live file must list it in `keep`. The
engine checks `keep` for every entry it removes, including nested ones.

## Rules the tests enforce

Do not weaken these to make a target work:

1. `clean` without `-Force` must not delete anything.
2. `keep` names must survive.
3. `minAgeDays` must be honoured (fresh files stay).
4. `report-only` must survive even `-Force -Deep`.
5. A malformed target file must be refused with a clear error, not silently
   obeyed.
6. `-Only` must narrow the run to exactly the named ids.
7. Paths outside the target list must never be touched.

## Code conventions

- PowerShell 5.1 compatible. No `??`, no ternary, no `-Parallel`.
- **ASCII only** in `.ps1` files. PS 5.1 parses BOM-less UTF-8 as ANSI and
  mangles anything else; this repo ships plain UTF-8 without BOM.
- Use the `Write-Cg*` helpers instead of bare `Write-Host`, so `-Json` and
  `-NoColor` keep working.
- New destructive behaviour belongs in `Remove-CgChildren` or a new reclaim
  mode with a test — not inline in `Invoke-CgClean`.

## Reporting a target that broke something

Open an issue with:

- the target `id`
- what disappeared that should not have
- the audit line from `%LOCALAPPDATA%\cguard\cguard.log`

That log line is the only durable record of what a run touched, which is why it
is written even in dry-run mode.
