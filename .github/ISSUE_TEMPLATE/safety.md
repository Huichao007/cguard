---
name: Something was deleted that should not have been
about: Report a target that removed the wrong file
title: '[SAFETY] '
labels: safety
---

<!--
This is the most important kind of issue. Please fill in the audit line.
-->

## Which target?

The `id` from the table output, for example `opencode-data` or `vscode-cache`.

## What disappeared?

Be specific: file names, folder names, roughly how much.

## The audit line

Open `%LOCALAPPDATA%\cguard\cguard.log` and paste the line whose timestamp
matches the run:

```
2026-11-10 13:13:58 mode=apply reclaimed=46.2 MB freeBefore=142.61 freeAfter=142.63
```

## Command you ran

```powershell
# paste the exact command, including flags
```

## Version

```
cguard version
```
