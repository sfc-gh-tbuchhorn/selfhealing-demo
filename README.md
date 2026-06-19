# Self-Healing dbt Pipeline with Openflow CDC and Snowflake Cortex

A Snowflake-native proof of concept that automatically detects source schema changes, identifies every dbt model in the downstream lineage graph, regenerates the affected SQL using a Cortex LLM, validates the changes by running `dbt run` against a zero-copy clone of production, and raises a pull request. All orchestration lives inside Snowflake — no external CI servers, no orchestration runtime.

Read the full technical walkthrough: [How Openflow and a Recursive SQL Query Power a Self-Healing dbt Pipeline](https://docs.google.com/document/d/1VqcSfSMoYwKId1meIOYoJ5UwDkS0-YF1nWXmyq4Uo50/edit)

## What this demonstrates

- **Openflow CDC-aware detection** — schema changes from Postgres arrive in BRONZE automatically; the drift detector uses Openflow's `__SNOWFLAKE_DELETED` column-rename pattern to detect dropped columns without any external catalog
- **Transitive lineage traversal** — a recursive CTE on `ARTIFACT_REGISTRY` (populated from `dbt ls`) finds every SILVER and GOLD model impacted by a BRONZE change, with full impact paths
- **Cortex-powered dbt refactoring** — `llama3.1-70b` regenerates the complete SQL for each impacted model; Jinja safety nets restore `{{ config(...) }}` blocks and `{{ ref() }}` calls the LLM might corrupt
- **`dbt run` as CI** — generated models are written to file, deployed to an isolated dbt project, and executed with `--select source:bronze.<table>+` against a zero-copy DEV clone; per-model pass/fail is captured
- **PR-first GitOps** — a detected change always opens a pull request immediately after code generation; `dbt run` validation runs after and posts its result as a comment; a human gates the merge

## Architecture

```
Postgres source
      │
      │  Openflow CDC  (native Snowflake connector)
      ▼
SELFHEALING_PROD.BRONZE.<table>
      │
      │  SCHEMA_DRIFT_DETECTOR (Task, 15 min)
      │  Compares INFORMATION_SCHEMA vs SCHEMA_REGISTRY
      │  Detects: NEW_COLUMN, COLUMN_DROP (__SNOWFLAKE_DELETED),
      │           TYPE_CHANGE, NEW_TABLE
      ▼
SCHEMA_CHANGE_EVENTS
      │
      │  GENERATE_ARTIFACT_CODE (Snowpark Python, Cortex llama3.1-70b)
      ▼
GET_IMPACTED_ARTIFACTS ── recursive CTE on ARTIFACT_REGISTRY
      │                   BRONZE → SILVER → GOLD transitive graph
      │
      │  Regenerated SQL committed to GitHub feature branch
      ▼
GENERATE_AND_PREP() opens PR immediately  ◄── guaranteed deliverable
      │
      │  materialise_in_dev.py
      │  1. REFRESH_DEV_ENVIRONMENT()  ← zero-copy clone of PROD
      │  2. snow dbt deploy SELFHEALING_TEST
      │  3. EXECUTE DBT PROJECT ... --select source:bronze.<table>+
      │  4. Parse per-model PASS/FAIL
      │  5. Post ✅/❌ result as PR comment
      ▼
pipeline_status: CI_PASSED or CI_FAILED
      │
      │  GitHub Action on merge → SYNC_FROM_MAIN
      ▼
Production dbt project redeployed from main
SCHEMA_REGISTRY advanced to new baseline
```

### dbt model graph

```
BRONZE.customers   BRONZE.orders    BRONZE.order_items
      │                 │                  │
      ▼                 ▼                  ▼
SILVER.customers  SILVER.orders   SILVER.order_items
                       │                  │
                       ▼                  ▼
               GOLD.orders_daily  GOLD.category_summary
```

When `BRONZE.ORDERS` changes, the recursive CTE returns `SILVER.ORDERS` (depth 1) and `GOLD.ORDERS_DAILY` (depth 2). Both are regenerated and tested.

## Prerequisites

| Requirement | Notes |
|---|---|
| Snowflake account | Cortex LLM enabled; `llama3.1-70b` accessible. Trial accounts need a payment method on file for Cortex (see [Trial vs full at a glance](#trial-vs-full-at-a-glance)) |
| GitHub account + PAT | `repo` scope |
| Python 3.8+ | `snowflake-connector-python`, `requests`, `snow` CLI |
| Openflow connector | **Full version only** — Snowflake-native PostgreSQL CDC. On trial, replaced by `trial_bronze_setup.sql` |
| `PLATFORM_REGISTRY.DBT` | **Full version only** — the dbt project registry. On trial, the dbt project lives in your own schema |

Connections and repo are configured entirely through environment variables (see [Setup — start here](#setup--start-here-both-paths)) — no file edits required.

## Repo structure

```
selfhealing_demo/
├── config/                           # Snowflake setup scripts (run locally)
│   ├── 01_config_schema.sql          # CONFIG schema, SCHEMA_REGISTRY, SCHEMA_CHANGE_EVENTS
│   ├── 02_rbac.sql                   # SELFHEALING_PIPELINE role + grants
│   ├── 03_github_api_integration.sql # Network rule, EAI, PAT secret for GitHub REST API
│   ├── 04_git_integration.sql        # Snowflake native Git repo (source of truth for dbt)
│   ├── 05_dev_environment.sql        # REFRESH_DEV_ENVIRONMENT — zero-copy clone PROD → DEV
│   ├── 06_impact_analysis.sql        # GET_IMPACTED_ARTIFACTS — recursive CTE lineage
│   ├── 07_code_generation.sql        # GENERATE_ARTIFACT_CODE — Cortex llama3.1-70b
│   ├── 08_commit_workflow.sql        # COMMIT_WORKFLOW_FILE — GitHub API commit helpers
│   ├── 09_pipeline_procs.sql         # GENERATE_AND_PREP · COMMIT_TO_GITHUB · HANDLE_TEST_FAILURE
│   ├── 10_poll_merged_prs.sql        # Detect merged PRs → SYNC_FROM_MAIN
│   ├── 11_seed_registry.sql          # Seed SCHEMA_REGISTRY from current BRONZE schema
│   ├── 12_drift_detector.sql         # SCHEMA_DRIFT_DETECTOR proc
│   ├── 13_pipeline_tasks.sql         # Core pipeline task (trial + full)
│   ├── 14_pipeline_tasks_full.sql    # Full task DAG (full version only)
│   ├── 15_run_as_pipeline.sql        # Harden: run tasks as least-privilege role
│   ├── trial_bronze_setup.sql        # Trial: BRONZE schema + sample data
│   ├── materialise_in_dev.py         # Run dbt in DEV, post ✅/❌ result as PR comment
│   └── refresh_artifact_registry.py  # Populate ARTIFACT_REGISTRY from dbt ls
│
├── dbt/                              # dbt project (deployed via snow dbt)
│   ├── dbt_project.yml
│   ├── profiles.yml
│   ├── models/
│   │   ├── sources.yml               # Declares BRONZE sources
│   │   ├── silver/
│   │   │   ├── customers.sql
│   │   │   ├── orders.sql
│   │   │   └── order_items.sql
│   │   └── gold/
│   │       ├── orders_daily.sql
│   │       └── category_summary.sql
│   └── macros/
│       ├── generate_schema_name.sql
│       └── refresh_artifact_registry.sql  # on-run-end hook → updates registry
│
├── dcm/                              # Snowflake DCM foundation
│   └── manifest.yml
│
├── load_retail_data.py               # Load sample Postgres data
└── load_order_items.py
```

## Setup — start here (both paths)

Complete this once, regardless of account type. Then follow **one** of the two self-contained paths below — they are **alternatives, not sequential steps**:

- **[Trial account setup](#trial-account-setup)** — no EAI, no Openflow; the GitHub work runs locally.
- **[Full account setup](#full-account-setup)** — Enterprise+ with EAI and Openflow; the whole pipeline runs inside Snowflake.

1. **Fork** this repository — the pipeline opens PRs and posts comments to **your fork**, not the original.
2. **Clone** your fork:
   ```bash
   git clone https://github.com/<your-username>/selfhealing-demo.git
   cd selfhealing-demo
   ```
3. **Set environment variables** (required before any script):
   ```bash
   export SNOWFLAKE_CONNECTION_SQL=<your-snow-cli-connection>
   export SNOWFLAKE_CONNECTION_PY=<your-snow-cli-connection>
   export GITHUB_REPO=<your-username>/selfhealing-demo
   export GITHUB_PAT=<your-github-pat>
   export DBT_PROJECT=SELFHEALING_PROD.CONFIG.SELFHEALING   # any unused FQN
   ```

### Trial vs full at a glance

| Capability | Trial | Full |
|---|---|---|
| Source → BRONZE | `trial_bronze_setup.sql` seeds sample data | Openflow PostgreSQL CDC streams live changes |
| GitHub REST calls (commit/PR/comment) | Run locally by `materialise_in_dev.py` | Run inside Snowflake via EAI |
| Merge → re-baseline | `RESOLVE_EVENT` run manually | `SYNC_FROM_MAIN` via polling task or GitHub Action |
| Scripts used | all **except** `03, 04, 08, 09, 10, 14` | all scripts |

> **Cortex needs a payment method on trial.** Snowflake Cortex LLM functions are blocked on trial accounts until you add a credit card (Admin → Billing → Add Credit Card). You keep your free credits, but the code-generation step fails without it.

---

## Trial account setup

> **Self-contained path.** Assumes you've completed [Setup — start here](#setup--start-here-both-paths). No EAI or Openflow — `trial_bronze_setup.sql` stands in for the CDC source and `materialise_in_dev.py` does the GitHub work locally. Skips scripts `03`, `04`, `08`, `09`, `10`, `14`.

Run in this order:

```bash
# Foundation
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/01_config_schema.sql

# RBAC
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/02_rbac.sql

# Core stored procedures
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/05_dev_environment.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/06_impact_analysis.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/07_code_generation.sql

# Seed BRONZE with sample data (replaces Openflow), then materialise SILVER/GOLD
# in PROD with an initial dbt run so the DEV clone mirrors production
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/trial_bronze_setup.sql
snow dbt deploy $DBT_PROJECT --source ./dbt --connection $SNOWFLAKE_CONNECTION_SQL
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
EXECUTE DBT PROJECT $DBT_PROJECT
  ARGS = 'run --vars \"{db_name: SELFHEALING_PROD}\" --target prod'"

# Seed registry, drift detector, core task, then harden
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/11_seed_registry.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/12_drift_detector.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/13_pipeline_tasks.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/15_run_as_pipeline.sql

# Resolution proc — advances SCHEMA_REGISTRY after you merge a PR
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/16_resolve_event.sql
```

Then simulate a change and watch it heal — see [Running the pipeline](#running-the-pipeline).

---

## Full account setup

> **Self-contained path.** Assumes you've completed [Setup — start here](#setup--start-here-both-paths). Enterprise+ account with EAI and Openflow. The entire pipeline runs inside Snowflake — no local `materialise_in_dev.py`, no manual resolution step.

**Merge detection.** When a PR is merged, `SYNC_FROM_MAIN` must run to redeploy PROD and re-baseline. Pick one:
- **Polling (default, no GitHub Actions needed):** `10_poll_merged_prs.sql` creates `POLL_MERGED_PRS_TASK`, which polls GitHub *from inside Snowflake* (via EAI) every 5 min and calls `SYNC_FROM_MAIN` on merged PRs. Works even where GitHub Actions can't reach Snowflake (e.g. VPN/network restrictions).
- **Push (optional):** the included `.github/workflows/sync_snowflake_on_merge.yml` calls `SYNC_FROM_MAIN` via the Snowflake SQL API on merge. Requires GitHub repo secrets `SNOWFLAKE_ACCOUNT` and `SNOWFLAKE_PAT`, and that GitHub's runners can reach your Snowflake account. If they can't, delete the workflow and rely on polling.

Run every script in order:

```bash
# Foundation + config
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/01_config_schema.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
MERGE INTO SELFHEALING_PROD.CONFIG.SETTINGS t
USING (SELECT 'github_repo' AS key, '$GITHUB_REPO' AS value
       UNION ALL SELECT 'dbt_project', '$DBT_PROJECT') s
ON t.key = s.key
WHEN MATCHED THEN UPDATE SET t.value = s.value
WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/02_rbac.sql

# GitHub API + native Git (require EAI)
# Both secrets are created inline so they pick up $GITHUB_PAT / $GITHUB_REPO
# from your shell (a `-f` file cannot read env vars; `-q` gets interpolation).
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
CREATE OR REPLACE SECRET SELFHEALING_PROD.CONFIG.GITHUB_PAT
  TYPE = GENERIC_STRING SECRET_STRING = '$GITHUB_PAT';"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
CREATE OR REPLACE SECRET SELFHEALING_PROD.CONFIG.GITHUB_GIT_CREDENTIALS
  TYPE = PASSWORD USERNAME = '${GITHUB_REPO%%/*}' PASSWORD = '$GITHUB_PAT';"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/03_github_api_integration.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/04_git_integration.sql

# Stored procedures
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/05_dev_environment.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/06_impact_analysis.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/07_code_generation.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/08_commit_workflow.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/09_pipeline_procs.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/10_poll_merged_prs.sql

# Configure Openflow CDC (destination DB = PROD, schema = BRONZE, static
# pattern, CASE_INSENSITIVE). Once BRONZE tables exist with data, continue.

# Deploy the dbt project from the Git repo and do an initial PROD run.
# This creates the DBT PROJECT object (required by RUN_DEV_TEST) and
# populates SILVER/GOLD in PROD so the DEV clone is realistic.
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
CREATE OR REPLACE DBT PROJECT $DBT_PROJECT
    FROM @SELFHEALING_PROD.CONFIG.SELFHEALING_REPO/branches/main/;"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
EXECUTE DBT PROJECT $DBT_PROJECT
    ARGS = 'run --vars \"{db_name: SELFHEALING_PROD}\" --target prod'"

snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/11_seed_registry.sql

# Drift detector + full task DAG, then harden
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/12_drift_detector.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/13_pipeline_tasks.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/14_pipeline_tasks_full.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/15_run_as_pipeline.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/16_resolve_event.sql
```

After this, schema changes flowing in through Openflow are detected, code-generated, validated in a DEV clone, and raised as PRs **entirely by Snowflake Tasks** — no local `materialise_in_dev.py` needed. `14_pipeline_tasks_full.sql` replaces the trial `PIPELINE_ROOT` (which only generates code) with the full DAG: `PIPELINE_ROOT` (`GENERATE_AND_PREP`) → `RUN_DEV_TEST` → `COMMIT_AND_MR`, plus `PIPELINE_FINALIZER`.

---

## Running the pipeline

Simulate a schema change and watch it heal. On a **full** account the drift detector and PR steps fire automatically; on **trial** you run them manually as shown.

```bash
# 1. Simulate Openflow adding a column to ORDERS
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
ALTER TABLE SELFHEALING_PROD.BRONZE.ORDERS ADD COLUMN discount_code VARCHAR;"

# 2. Run the drift detector — writes a NEW_COLUMN event
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
EXECUTE TASK SELFHEALING_PROD.CONFIG.SCHEMA_DRIFT_DETECTOR;"

# 3. Generate the fix (Cortex regenerates impacted dbt models)
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
CALL SELFHEALING_PROD.CONFIG.GENERATE_NEXT_PENDING();"

# 4. Grab the event_id and inspect the generated SQL
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
SELECT event_id FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
ORDER BY detected_at DESC LIMIT 1;"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
SELECT artifact_name, file_path, generated_sql
FROM SELFHEALING_PROD.CONFIG.GENERATED_CODE;"

# 5. Validate in a DEV clone, open the PR, and post the CI result as a comment
python3 config/materialise_in_dev.py <event-id>
```

`materialise_in_dev.py` opens the PR immediately (before tests — it's a guaranteed deliverable), zero-copy clones PROD→DEV, runs `dbt run --select source:bronze.<table>+` against the clone, then posts a ✅ or ❌ comment and sets `pipeline_status` to `CI_PASSED` / `CI_FAILED`.

### 6. Merge and re-baseline

Review the PR and CI comment, then **merge** it. On a full account a GitHub Action calls `SYNC_FROM_MAIN` to advance the baseline automatically. On **trial**, run the resolution step manually after merging — this advances `SCHEMA_REGISTRY` to include the change and marks the event `RESOLVED`, so the drift detector stops re-flagging it:

```bash
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
CALL SELFHEALING_PROD.CONFIG.RESOLVE_EVENT('<event-id>');"
```

> If you skip this on trial, the scheduled drift detector will keep re-detecting the same change on every run, because `SCHEMA_REGISTRY` still reflects the pre-change schema.

---

## Pipeline status lifecycle

```
PENDING → GENERATING → PR_OPEN → CI_PASSED → (merge) → RESOLVED
                              ↘ CI_FAILED  (PR stays open, needs human review)
```

A detected schema change is **always guaranteed to produce a PR** (`PR_OPEN`). The `dbt run` CI test runs after the PR is open and posts its outcome as a comment. A human reviews the PR and the CI comment, then merges. On merge, `SYNC_FROM_MAIN` redeploys the production dbt project.

## What to look for

| Event type | Expected model updates |
|---|---|
| `NEW_COLUMN` on ORDERS | `SILVER.orders` (add column + cast), `GOLD.orders_daily` (if used in aggregate) |
| `TYPE_CHANGE` | All models in the lineage graph that reference the column |
| `COLUMN_DROP` | Deprecation comment added; downstream models updated |
| `NEW_TABLE` | New SILVER model generated; `sources.yml` updated |

## How the lineage traversal works

`ARTIFACT_REGISTRY` is populated at dbt deploy time via an `on-run-end` macro (`macros/refresh_artifact_registry.sql`). Every `{{ source('bronze', 'table') }}` and `{{ ref('model') }}` relationship becomes a row with `source_table` → `snowflake_fqn`.

`GET_IMPACTED_ARTIFACTS` runs a recursive CTE on this registry:

```sql
WITH RECURSIVE impact AS (
    -- Seed: direct dependents of the changed BRONZE table
    SELECT artifact_name, file_path, snowflake_fqn, 1 AS depth,
           'BRONZE.orders → ' || snowflake_fqn AS impact_path
    FROM ARTIFACT_REGISTRY WHERE source_table = 'BRONZE.ORDERS'

    UNION ALL

    -- Recurse: dependents of dependents (SILVER → GOLD)
    SELECT a.artifact_name, a.file_path, a.snowflake_fqn,
           i.depth + 1,
           i.impact_path || ' → ' || a.snowflake_fqn
    FROM ARTIFACT_REGISTRY a
    JOIN impact i ON a.source_table = i.snowflake_fqn
)
SELECT * FROM impact ORDER BY depth, artifact_name
```

For `BRONZE.ORDERS` the result is:

```
depth 1: SILVER.orders          (impact_path: BRONZE.ORDERS → SILVER.ORDERS)
depth 2: GOLD.orders_daily      (impact_path: BRONZE.ORDERS → SILVER.ORDERS → GOLD.ORDERS_DAILY)
```

Both models are regenerated and tested. Nothing is missed.

## Jinja safety nets

Cortex LLMs occasionally corrupt dbt-specific Jinja. Two post-processors run after every generation:

- **`restore_config_block()`** — if the LLM stripped the `{{ config(...) }}` block, it is extracted from the original and prepended
- **`restore_ref_calls()`** — if the LLM changed `{{ ref('orders') }}` to `{{ source('bronze', 'orders') }}` in a Gold model, the original `{{ ref() }}` calls are restored

These are deterministic string operations. The LLM generates the SQL logic; the Jinja wiring is always restored from the known-good original.

## Extending this

### Adding new source tables

The `on-run-end` macro auto-populates `ARTIFACT_REGISTRY` when you run `dbt`. Add your new SILVER or GOLD model referencing an existing source and the registry updates on the next `dbt run`.

### Using a different LLM

In `config/07_code_generation.sql`:
```python
MODEL = 'llama3.1-70b'   # change to any Cortex-available model
```

### Live OpenMetadata integration

Replace the `SCHEMA_DRIFT_DETECTOR` task with a subscription to your OpenMetadata change feed. The event schema (`SCHEMA_CHANGE_EVENTS`) is compatible with either approach.

## Teardown

Remove everything created by the demo:

```bash
# 1. Drop all Snowflake objects (databases, warehouse, role, integrations)
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/teardown.sql

# 2. Remove the local clone
cd .. && rm -rf selfhealing-demo
```

3. On GitHub: close any open PRs and delete the `schema-change/*` branches on your fork — or simply delete the fork.

> **Re-running without a full teardown?** A passing run leaves the generated changes in your local dbt models (`materialise_in_dev.py` only reverts on failure). Before re-testing against a freshly seeded BRONZE, reset them so they don't reference columns that no longer exist:
> ```bash
> git restore dbt/models/
> ```

## Licence

MIT
