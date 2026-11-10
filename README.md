<div align="center">

# cguard

**Keep the Windows C: drive from filling up while AI coding agents run.**

AI agents accumulate output, caches, runtimes and browser binaries faster than
anyone thinks to look. cguard measures every place they hide, reclaims the ones
that are safe, and moves the growth off the system drive for good.

`Windows 10/11` · `PowerShell 5.1+` · `no dependencies` · `MIT`

```
C: 257.4 GB total / 30.1 GB free  ->  142.6 GB free
```

</div>

---

## The problem

A modern agentic toolchain quietly writes to `C:` all day long:

| Where                                           | Grows because                                        |
| ----------------------------------------------- | ---------------------------------------------------- |
| `%LOCALAPPDATA%\Temp`                           | every tool call, screenshot and unzip                |
| `~/.local/share/opencode`                       | shell output and tool output for **every** session   |
| `~/.cache/codex-runtimes`                       | each Codex runtime download                          |
| `~/.cache/puppeteer`, `ms-playwright`           | a fresh Chromium per automation tool                 |
| `%APPDATA%\Code`, `Cursor`, `WorkBuddy`         | renderer caches, VSIX installers, rotated logs       |
| `%LOCALAPPDATA%\npm-cache`, `pnpm`, `uv`, `pip` | every package you ever installed                     |
| `C:\ProgramData\Dell\SARemediation\...`         | Dell SupportAssist keeps a **full pre-repair image** |
| Volume Shadow Copies                            | System Restore points, silently 10-60 GB             |

Nothing in that list is your data. Together it is enough to take a 30 GB free
drive to zero while you are asleep, and every one of these tools is designed to
re-download whatever it needs.

## What cguard does about it

Four verbs, deliberately few.

| Command    | What it does                                                                      | Deletes anything?  |
| ---------- | --------------------------------------------------------------------------------- | ------------------ |
| `scan`     | measures every known bloat location, prints a table                               | never              |
| `clean`    | dry run by default; `-Force` reclaims                                             | only with `-Force` |
| `doctor`   | explains _why_ C: is full: top folders, shadow copies, hibernation, OEM snapshots | never              |
| `relocate` | moves package/browser caches to another drive via env vars, so regrowth stops     | never              |
| `watch`    | registers a scheduled task that cleans only when C: gets low                      | only on low space  |

The design rule is blunt: **a target is deleted only if deleting it costs
nothing but a re-download.** Anything else is reported, never touched.

## Quick start

```powershell
git clone https://github.com/Huichao007/cguard.git
cd cguard

.\cguard.ps1 scan              # where did my disk go
.\cguard.ps1 clean             # what would be reclaimed (nothing is deleted)
.\cguard.ps1 clean -Force      # do it
.\cguard.ps1 doctor            # why is it full, and what is safe to fix
```

Run it elevated for the machine-wide targets:

```powershell
.\cguard.ps1 clean -Force -Admin      # one UAC prompt, cleans everything
```

## Commands

### `scan`

```
TARGET                   TIER          SIZE    FILES  WHAT IT IS
------------------------------------------------------------------------------
browser-automation       apps       2.45 GB     2464  Headless browser binaries
vscode-cache             safe       1.07 GB      684  VS Code cache (not extensions)
codex-runtimes           apps      244.7 MB      658  Codex runtime cache
crash-dumps              safe      190.8 MB       10  Crash dumps
opencode-data            apps       31.3 MB      268  OpenCode agent data
```

Three tiers, because "safe to delete" is not one thing:

- **safe** — pure cache or temp. Deleting costs a re-download or a cold start.
- **apps** — agent runtimes and model files. Safe, but the agent re-fetches them on next launch.
- **review** — _your_ data: sessions, settings, installed extensions, container disks. **Never deleted.** Listed only with `-Deep`.

```powershell
.\cguard.ps1 scan -Json                # machine-readable, for dashboards
.\cguard.ps1 scan -Deep -Top 20         # include the review tier
```

### `clean`

```powershell
.\cguard.ps1 clean                              # dry run
.\cguard.ps1 clean -Force                       # safe + apps tiers
.\cguard.ps1 clean -Force -Only opencode-data   # just one target
.\cguard.ps1 clean -Force -Admin                # include admin-only targets
.\cguard.ps1 clean -Auto                        # only if C: is actually low
.\cguard.ps1 clean -Force -ReportPath report.md # write a markdown report
```

Every run appends one line to `%LOCALAPPDATA%\cguard\cguard.log`:

```
2026-11-10 13:13:58 mode=apply reclaimed=46.2 MB freeBefore=142.61 freeAfter=142.63
```

### `doctor`

Answers "why is my disk full" instead of guessing:

- biggest folders under `C:\`, with a time budget so it never hangs
- the 8 largest folders inside your user profile
- volume shadow copy storage (needs Administrator)
- `hiberfil.sys` / `pagefile.sys` and whether hibernation can be turned off
- OEM repair snapshots (Dell SupportAssist and friends)
- which caches are still pointed at `C:`

### `relocate`

Cleaning is a mop. This is the tap.

```powershell
.\cguard.ps1 relocate -ToDrive D            # dry run: shows what would be set
.\cguard.ps1 relocate -ToDrive D -Force     # writes the user env vars
```

Sets `NPM_CONFIG_CACHE`, `PNPM_HOME`, `YARN_CACHE_FOLDER`, `UV_CACHE_DIR`,
`PIP_CACHE_DIR`, `BUN_INSTALL_CACHE_DIR`, `PUPPETEER_CACHE_DIR`,
`PLAYWRIGHT_BROWSERS_PATH` and optionally `TMP`/`TEMP` to a folder on another
drive. Existing values are preserved unless you pass `-Force`, so a machine
that is already configured sanely will not be disturbed.

### `watch`

```powershell
.\cguard.ps1 watch                       # show the task it would create
.\cguard.ps1 watch -Install              # every 6 hours
.\cguard.ps1 watch -Install -EveryHours 12
.\cguard.ps1 watch -Status               # installed? what did it reclaim?
.\cguard.ps1 watch -Uninstall
```

The task runs `clean -Auto`, which **does nothing unless free space is below
the threshold** (20 GB by default, `config\policy.json`). A healthy machine is
never touched, so the task cannot surprise you by deleting a cache mid-build.

## Safety model

This tool deletes files, so the rules are explicit:

1. **Dry run is the default.** `clean` without `-Force` only prints numbers.
2. **Never outside the target list.** Paths come from `config\targets.json`; a
   target that is not declared cannot be deleted, ever.
3. **`keep` wins.** Any name in a target's `keep` array survives, including
   inside a folder that is otherwise emptied — that is how `opencode.db`
   outlives `clean -Force` on `opencode-data`.
4. **`minAgeDays` is respected.** A cache written in the last N days is left
   alone, so the file an agent is actively using is not yanked away.
5. **Locked files are skipped, not forced.** In-use files are counted and
   reported; nothing is killed to make a delete succeed.
6. **`review` is never written.** The tier exists to be measured, not cleaned.
7. **`-Auto` has a floor.** The scheduled task refuses to run while there is
   plenty of space.

`tests\test-cguard.ps1` asserts every one of those rules against a throwaway
sandbox — 29 checks, no real cache touched:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-cguard.ps1
```

## Adding your own target

`config\targets.json` is the whole knowledge base. One entry:

```json
{
  "id": "my-agent-cache",
  "tier": "safe",
  "group": "ai-agents",
  "label": "My agent cache",
  "description": "Downloaded model shards.",
  "paths": ["%LOCALAPPDATA%\\MyAgent\\cache"],
  "minAgeDays": 14,
  "keep": ["config.json"],
  "reclaim": "delete-contents"
}
```

`reclaim` modes:

| mode              | behaviour                                                             |
| ----------------- | --------------------------------------------------------------------- |
| `delete-contents` | empty the listed paths, keep the folders themselves                   |
| `subdirs`         | only empty the named children (for folders that hold a live database) |
| `cmdlet`          | run an official cmdlet instead of deleting by hand                    |
| `report-only`     | measure and report; never delete                                      |

Point the engine at a different file with `-TargetsFile mine.json`.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (ships with Windows) — no modules, no `Install-Module`, no elevation to scan
- Administrator only for `%WINDIR%\Temp`, Windows Update cache, `$WinREAgent`, shadow copies and Dell snapshots

## What it will not do

- It will not touch your documents, projects, git repos, photos or downloads.
- It will not delete VS Code / Cursor extensions, browser profiles, cookies or logins.
- It will not shrink a Docker/WSL `ext4.vhdx` — that needs `wsl --manage <distro> --set-sparse true`, and cguard only reports the size.
- It will not install anything, phone home, or send telemetry.

## Results

On the machine this tool was written for, C: free space went from under
**30 GB** to **142.6 GB** free.

The biggest win, and the one nobody thinks to look for, came with hard numbers
from the run log:

| Action                                                 | Reclaimed               | Evidence                                                       |
| ------------------------------------------------------ | ----------------------- | -------------------------------------------------------------- |
| Dell SupportAssist repair snapshots                    | **48.5 GB in one pass** | free space 96.67 GB -> 145.21 GB, 316 snapshot folders removed |
| Ongoing: agent caches, browser binaries, editor caches | **3-4 GB on demand**    | `cguard scan` on this machine                                  |

`SARemediation\SystemRepair\Snapshots` is a full pre-repair disk image that
SupportAssist keeps after a driver or BIOS repair. It is invisible in Explorer,
it never expires on its own, and it can be tens of gigs. `cguard doctor` looks
for it by name; `clean -Force -Admin` removes it.

Two other findings on the same machine, both reported by `doctor` rather than
assumed:

- Volume shadow copy storage was holding tens of GB of System Restore points.
  `vssadmin resize shadowstorage /for=C: /on=C: /maxsize=8GB` caps it.
- Explorer thumbnails, Windows Update downloads and `$WinREAgent` staging added
  single-digit GB between them.

`cguard` does not claim credit for space it did not free: run `scan` before and
`clean -Force` after, and the audit log records both numbers.

## License

MIT. Use it, fork it, ship it in your own toolchain.
