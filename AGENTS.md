# Libre Health Bridge task tracker references

Use these references for the existing **Libre Health Bridge Tasks** Notion database. The IDs locate resources; inspect the live schema before changing data. The database currently lives directly under **To Do List**. **Branch is rich text**, not a relation to a separate Branches database. Preserve the current organization and property types.

| Resource | ID |
| --- | --- |
| Parent page: To Do List | `3d85c974-d8df-80d8-8fd7-ecb7d5847e21` |
| Database: Libre Health Bridge Tasks | `628c4216-911d-492a-93fc-cf7fb61c8f23` |
| Tasks data source | `fd941e35-4d4b-427c-a9b4-c5e05068ea91` |
| Board — Status | `3f65c974-d8df-815c-88e9-000c145572f8` |
| Board — Severity | `3f65c974-d8df-8164-8454-000cccedec94` |
| Detailed view (table) | `4b7ada5a-31ec-4884-87a8-a58198e13bc2` |

[Open the task database](https://app.notion.com/p/628c4216911d492a93fccf7fb61c8f23).

## Existing views

- **Detailed view:** table over the task data source, currently without explicit sorting or grouping.
- **Board — Status:** grouped by Status, subgrouped by Severity, sorted by Hash ascending. Empty Status columns remain visible.
- **Board — Severity:** grouped by Severity, sorted by Hash ascending. Empty Severity columns are hidden.
- Both boards show Task name, Hash, Severity, Branch, Status, Blocked by, and Review axis. Quick filters are Branch, Severity, and Review axis.

Reuse these views. A new task does not require a new board, database, or standalone project page.
