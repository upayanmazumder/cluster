# Changelog

Forensic timeline of everything that happens to the `vps` cluster — git-tracked changes **and**
break-glass `kubectl` operations. This is the single source of truth for "what happened, when,
why, and how it was verified"; `git log` alone only covers changes that went through git, and says
nothing about break-glass `kubectl` actions or *why*.

**Split by month** (`YYYY-MM.md`) so no single file grows unbounded. Newest month is current;
older months are immutable history. Within a file, newest entries first.

| Month | File |
|---|---|
| 2026-10 | [2026-10.md](2026-10.md) |
| 2026-09 | [2026-09.md](2026-09.md) |
| 2026-08 | [2026-08.md](2026-08.md) |

**Never edit or delete a past entry.** If something was wrong, append a correction entry that
says so — the record must stay append-only for forensic integrity.

See `.claude/skills/changelog/SKILL.md` for the exact entry format and when a new entry is
required (short answer: every git-tracked cluster change *and* every break-glass `kubectl`
mutation, no exceptions).

## Starting a new month

When the current month's file doesn't exist yet: create `changelog/YYYY-MM.md` with a one-line
`# Changelog — YYYY-MM` header, add a row to the table above (newest month on top), commit both
in the same change that starts logging that month.
