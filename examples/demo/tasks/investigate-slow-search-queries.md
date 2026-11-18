---
id: investigate-slow-search-queries
title: Investigate slow search queries
status: needs-attention
attention: Needs a decision on which index to add
jira: SRCH-77
cursor_agent: c4e1f8a2-5b6d-4e3f-a1b2-7d8e9f0a1b33
workspace: ~/code/search
created: 2026-11-18T13:00:00Z
updated: 2026-11-18T16:20:00Z
---

p95 for `/search` went from 180 ms to 900 ms after the catalog import.

## Findings

1. The planner picks a sequential scan on `products` for prefix queries.
2. A trigram index fixes prefix and substring queries, but adds about 2 GB.
3. A plain b-tree on `lower(name)` fixes prefix queries only, at about 300 MB.

**Waiting on you:** which index do you want?
