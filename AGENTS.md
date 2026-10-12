# Project tasks in Notion

When creating, editing, or publishing tasks for this project, use the existing **Libre Health Bridge Tasks** Notion database through `ntn`. Tasks are database rows with structured properties and a Markdown body; the table and boards are views of those same rows.

## Locate the tracker

| Resource                            | ID                                     |
| ----------------------------------- | -------------------------------------- |
| Parent page: To Do List             | `3d85c974-d8df-80d8-8fd7-ecb7d5847e21` |
| Database: Libre Health Bridge Tasks | `628c4216-911d-492a-93fc-cf7fb61c8f23` |
| Tasks data source                   | `fd941e35-4d4b-427c-a9b4-c5e05068ea91` |
| Board — Status                      | `3f65c974-d8df-815c-88e9-000c145572f8` |
| Board — Severity                    | `3f65c974-d8df-8164-8454-000cccedec94` |
| Detailed view (table)               | `4b7ada5a-31ec-4884-87a8-a58198e13bc2` |

[Open the task database](https://app.notion.com/p/628c4216911d492a93fccf7fb61c8f23).

These IDs are locators, not a substitute for inspecting the live schema. The database currently lives directly under **To Do List**. **Branch is rich text**, not a relation to a separate Branches database. Preserve the user's current organization and property types.

## Task properties

| Property    | Notion type  | How to populate it                                                                                                          |
| ----------- | ------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Task name   | title        | Short, action-oriented outcome; keep the hash and severity in their own properties.                                           |
| Hash        | rich_text    | Generate a unique 10-character lowercase hex value with `openssl rand -hex 5` for each new task.                              |
| Branch      | rich_text    | Exact target Git branch, such as `feature/recurrent-background-sync`. Confirm the target with the user when ambiguous.      |
| Severity    | select       | One existing option: `P0`, `P1`, `P2`, or `P3`.                                                                             |
| Status      | status       | `Not started`, `Blocked`, `In progress`, or `Done`.                                                                         |
| Review axis | select       | `Standards` or `Spec` for review-derived tickets; leave empty for unrelated work unless the user supplies a classification. |
| Labels      | multi_select | Include `ready-for-agent` on approved, sufficiently specified tickets.                                                      |
| Blocked by  | relation     | Actual prerequisite task rows in this data source.                                                                          |
| Blocks      | relation     | Reciprocal of Blocked by; let Notion maintain it.                                                                           |
| Assignee    | people       | Set only when responsibility is assigned; otherwise leave empty.                                                            |
| Due         | date         | Set only when a deadline is provided; otherwise leave empty.                                                                |

The database properties are authoritative for severity, branch, workflow status, and blockers. `ready-for-agent` is a triage label, not a workflow status or permission to skip dependencies. Keep these values out of duplicated body headers in new tickets.

### Severity and status

- **P0:** critical blocker requiring immediate action.
- **P1:** high-priority correctness or safety issue.
- **P2:** normal-priority correctness, acceptance, or verification gap.
- **P3:** low-priority improvement or maintainability work.

Assign severity from impact, not the review axis. Label smell-based recommendations as judgement calls; explain whether they are optional rather than presenting them as proven bugs.

New approved tickets start **Not started** if their prerequisites are complete, otherwise **Blocked**. Work the frontier: only start tasks whose blockers are all Done. Change to **In progress** when work begins and **Done** when acceptance criteria have evidence. Reevaluate dependent tasks after completing a blocker.

### Existing views

- **Default view:** table over the task data source, currently without explicit sorting or grouping.
- **Board — Status:** grouped by individual Status option, subgrouped by Severity, sorted by Hash ascending. Empty status columns remain visible.
- **Board — Severity:** grouped by Severity, sorted by Hash ascending. Empty severity columns are hidden.
- Both boards expose Task name, Hash, Severity, Branch, Status, Blocked by, and Review axis on cards, with quick filters for Branch, Severity, and Review axis.

Reuse these views. Publishing another row does not require a new board, database, or standalone project/ticket page.

## Future-task workflow

1. **Inspect live state.** Confirm authentication, retrieve the database and its data source schema, query existing tasks, and inspect relevant view configuration. Follow pagination until complete. Use `ntn --help` and endpoint help when needed. If access fails, report the failure and ask for access rather than creating a replacement tracker.
2. **Gather the contract.** Read the referenced issue/spec and any relevant glossary or ADRs. For background-sync work, read `docs/specs/recurrent-background-sync.md`; use its safety and bounded-verification requirements. Determine the target branch and record the actual source commit/baseline for review-derived work.
3. **Draft tracer bullets.** Each ticket delivers a narrow, independently verifiable outcome across the relevant layers, including regression/acceptance coverage. Keep it sized for one fresh agent context. State real prerequisites only; optional prefactoring is not automatically a blocker. Keep Standards and Spec findings distinguishable.
4. **Confirm the breakdown.** Present titles, severity, blockers, and delivered behavior. Obtain user approval for the breakdown before publishing; an already approved breakdown can proceed directly.
5. **Publish into the data source.** Check for equivalent existing tasks, generate a Hash with `openssl rand -hex 5`, confirm it is unique among existing task hashes (regenerate on collision), and create blockers before their dependents. Populate all applicable structured properties. Set native Blocked by relations using the created/existing page IDs. Preserve existing task IDs and content when updating or moving tasks.
6. **Read back and verify.** Query every created/updated row and retrieve its body. Confirm title, unique Hash, exact branch, severity, workflow status, triage label, complete acceptance criteria, and blocker IDs/reciprocal relationships. Retrieve the board views if their configuration changed. Finish only when the intended rows and relationships are observable; return links and counts.

Schema/view changes require user intent. Preserve all existing options when explicitly updating select/status option arrays: the API may replace the array rather than append it. Preserve unrelated tasks and parent issues.

## Ticket body

Use this structure; metadata belongs in properties, not repeated prose fields:

```markdown
## What to build

The end-to-end outcome from the user's perspective, with scope and safety constraints.

## Acceptance criteria

- [ ] Observable behavior that proves the outcome works.
- [ ] Regression/failure-path coverage using safe, deterministic fixtures.
- [ ] Required verification evidence or an explicit external acceptance check.

## Context

Why the work is needed. For a review finding, include the triggering condition,
quote the relevant requirement, and distinguish a confirmed defect from a heuristic.
Record the source branch/commit and comparison baseline where applicable.
```

Use stable domain vocabulary and decision-rich behavior descriptions. Keep incidental implementation paths and snippets out of ticket bodies. Put blocking edges in the native relation, not only a text list. Separate local automated verification from external StoreKit/device/release work; record actual results instead of assuming a pass.

## Publishing with `ntn`

Read the live schema and rows before writing:

```sh
ntn api v1/databases/628c4216-911d-492a-93fc-cf7fb61c8f23
ntn api v1/data_sources/fd941e35-4d4b-427c-a9b4-c5e05068ea91
ntn api v1/data_sources/fd941e35-4d4b-427c-a9b4-c5e05068ea91/query \
  -d '{"page_size":100,"sorts":[{"property":"Hash","direction":"ascending"}]}'
ntn api v1/views database_id==628c4216-911d-492a-93fc-cf7fb61c8f23
```

Retrieve each listed view with `ntn api v1/views/<view-id>`. For paginated results, repeat with `start_cursor` until `has_more` is false.

A convenient Markdown publication path is:

```sh
ntn pages create \
  --parent data-source:fd941e35-4d4b-427c-a9b4-c5e05068ea91 \
  --json < /tmp/task.md
ntn api v1/pages/<returned-page-id> -X PATCH -d @/tmp/task-properties.json
ntn pages get <returned-page-id>
```

Start `/tmp/task.md` with title frontmatter matching Task name. On create, `ntn pages` uses the title but ignores other frontmatter properties; populate properties with the API. A properties payload has this shape (substitute real approved values and task IDs):

```json
{
  "properties": {
    "Task name": {
      "title": [{ "text": { "content": "Approved task title" } }]
    },
    "Hash": {
      "rich_text": [{ "text": { "content": "<10-character-hex-hash>" } }]
    },
    "Branch": {
      "rich_text": [
        { "text": { "content": "feature/recurrent-background-sync" } }
      ]
    },
    "Severity": { "select": { "name": "P2" } },
    "Status": { "status": { "name": "Not started" } },
    "Review axis": { "select": { "name": "Spec" } },
    "Labels": { "multi_select": [{ "name": "ready-for-agent" }] },
    "Blocked by": { "relation": [] }
  }
}
```

For dependencies, use `{"relation":[{"id":"<blocking-task-page-id>"}]}` and set Status to Blocked while any prerequisite is unfinished. Generate each Hash with `openssl rand -hex 5`; verify it is unique across the data source and regenerate if it collides. If the property update fails after creation, retain the returned page ID and repair that row rather than publishing a duplicate. API requests can also create content and properties together when atomic publication is preferable.
