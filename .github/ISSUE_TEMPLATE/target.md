---
name: A folder is eating my disk and cguard does not know it
about: Suggest a new target, or report one whose size looks wrong
title: '[TARGET] '
labels: targets
---

<!--
The most useful contribution: teach cguard about another place disk space goes.
-->

## The path

```
%LOCALAPPDATA%\SomeTool\cache
```

Use `%VARS%` rather than hardcoded `C:\Users\...` where possible.

## Which tool writes here?

Name and version, for example "Cursor 3.25.6" or "Docker Desktop 4.38".

## How big does it get, and how fast?

```
first scan : 1.2 GB
a week later: 6.8 GB
```

`cguard scan -Top 20 -Deep` output is ideal.

## Is it cache or data?

- [ ] Pure cache: deleting it only costs a re-download
- [ ] Runtime/model: the tool re-fetches it on next start
- [ ] Real data: sessions, settings, projects, a database

**If you are not sure, say so.** An uncertain target will be added as
`review`, which is measured but never deleted.

## Does the folder contain anything that must survive?

For example `state.vscdb`, `*.db`, `config.json`, `auth.json`. These go in the
target's `keep` list.

## Tiers and modes

Read the table in `CONTRIBUTING.md` first, then tell us which you think applies:

- tier: `safe` / `apps` / `review`
- reclaim: `delete-contents` / `subdirs` / `cmdlet` / `report-only`
