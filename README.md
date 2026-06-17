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
| Snowflake account | Cortex LLM enabled; `llama3.1-70b` accessible |
| Openflow connector | Snowflake-native CDC; PostgreSQL connector configured |
| Snowflake dbt | `snow dbt deploy` available; `PLATFORM_REGISTRY.DBT` schema exists |
| GitHub account + PAT | `repo` scope; stored as `SELFHEALING_PROD.CONFIG.GITHUB_PAT` secret |
| Python 3.8+ | `snowflake-connector-python`, `requests`, `snow` CLI |

### Snowflake connections

| Name | Used by | Auth |
|---|---|---|
| `demo_au` | Snow CLI commands | Any |
| `demo_au_PAT` | `materialise_in_dev.py` (Python connector) | PAT or key-pair |

Update these in `config/materialise_in_dev.py` and Snow CLI config.

## Repo structure

```
selfhealing_demo/
├── config/                           # Snowflake setup scripts (run locally)
│   ├── 01_config_schema.sql          # CONFIG schema, SCHEMA_REGISTRY, SCHEMA_CHANGE_EVENTS
│   ├── 02_rbac.sql                   # SELFHEALING_AGENT role + grants
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
│   ├── 13_pipeline_tasks.sql         # Scheduled tasks (start automation)
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

## Running on a trial account

Snowflake trial accounts (including Business Critical) have two restrictions that affect this demo:

| Blocked feature | Used for | Workaround |
|---|---|---|
| **External network access** | Stored procs calling the GitHub REST API (open PR, post CI comments) | Skip `03_github_api_integration.sql` and `04_git_integration.sql`. Use `materialise_in_dev.py` locally — it calls GitHub directly from Python and handles the full PR-first flow without EAI |
| **Openflow** | Streaming Postgres CDC into BRONZE | Seed BRONZE manually (see below) |

Everything else works on a trial account: Cortex LLMs, Snowpark Python stored procs, Tasks, zero-copy clones, and Snowflake-native Git integration.

### Seeding BRONZE without Openflow

Create your BRONZE tables manually and load sample data:

```sql
CREATE TABLE SELFHEALING_PROD.BRONZE.ORDERS (
    id INT, customer_id INT, status VARCHAR, total_amount FLOAT,
    order_date DATE, _loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
CREATE TABLE SELFHEALING_PROD.BRONZE.CUSTOMERS (
    id INT, name VARCHAR, email VARCHAR, country VARCHAR,
    _loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
CREATE TABLE SELFHEALING_PROD.BRONZE.ORDER_ITEMS (
    id INT, order_id INT, product VARCHAR, quantity INT, unit_price FLOAT,
    _loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
```

Load sample rows, then proceed from **Step 5** (seed registry) in the setup guide.

### Running the pipeline on a trial account

Skip steps that require EAI. The pipeline runs like this instead:

```bash
# 1. Manually trigger a schema change event
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
  (table_schema, table_name, column_name, change_type, new_data_type)
VALUES ('BRONZE', 'ORDERS', 'discount_code', 'NEW_COLUMN', 'TEXT');"

# 2. Get the event ID and run code generation (no EAI needed)
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "SELECT event_id FROM SELFHEALING_PROD.CONFIG.PENDING_SCHEMA_CHANGES LIMIT 1;"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "CALL SELFHEALING_PROD.CONFIG.GENERATE_ARTIFACT_CODE('<event-id>');"

# 3. Run DEV validation, open PR, and post CI comment locally
GITHUB_PAT=<your-pat> python3 config/materialise_in_dev.py <event-id>
```

The full PR-first flow — PR opened immediately, CI result posted as a comment — still works end-to-end. The only difference is that step 3 runs from your laptop rather than being triggered automatically by the pipeline task.

---

## Setup guide

### Step 1 — Fork and configure

1. Fork this repository to your GitHub account — the pipeline will open PRs and post comments to **your fork**, not the original repo
2. Clone your fork:
   ```bash
   git clone https://github.com/<your-username>/selfhealing-demo.git
   cd selfhealing-demo
   ```
3. Set your environment variables — these are required before running any script:
   ```bash
   export SNOWFLAKE_CONNECTION_SQL=<your-snow-cli-connection>
   export SNOWFLAKE_CONNECTION_PY=<your-snow-cli-connection>
   export GITHUB_REPO=<your-username>/selfhealing-demo
   export GITHUB_PAT=<your-github-pat>
   export DBT_PROJECT=<your-dbt-project-fqn>   # e.g. PLATFORM_REGISTRY.DBT.SELFHEALING_TEST
   ```

### Step 2 — Provision Snowflake infrastructure

```bash
# 01 — Foundation: CONFIG schema, SCHEMA_REGISTRY, SCHEMA_CHANGE_EVENTS, SETTINGS
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/01_config_schema.sql

# Populate pipeline config from env vars
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
MERGE INTO SELFHEALING_PROD.CONFIG.SETTINGS t
USING (SELECT 'github_repo' AS key, '$GITHUB_REPO' AS value
       UNION ALL
       SELECT 'dbt_project', '$DBT_PROJECT') s
ON t.key = s.key
WHEN MATCHED THEN UPDATE SET t.value = s.value
WHEN NOT MATCHED THEN INSERT (key, value) VALUES (s.key, s.value);"

# 02 — RBAC: agent role + grants
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/02_rbac.sql

# 03 — GitHub API: network rule, EAI, PAT secret
# Store your PAT first:
snow sql -c $SNOWFLAKE_CONNECTION_SQL -q "
CREATE OR REPLACE SECRET SELFHEALING_PROD.CONFIG.GITHUB_PAT
  TYPE = GENERIC_STRING
  SECRET_STRING = '<your-pat>';"
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/03_github_api_integration.sql

# 04 — Snowflake native Git repo (links to your GitHub repo)
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/04_git_integration.sql

# 05–10 — Stored procedures
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/05_dev_environment.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/06_impact_analysis.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/07_code_generation.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/08_commit_workflow.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/09_pipeline_procs.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/10_poll_merged_prs.sql
```

### Step 3 — Configure Openflow

Set up the Openflow PostgreSQL CDC connector targeting your Postgres source:
- Destination database: your `PROD` database
- Destination schema: `BRONZE`
- Destination schema pattern: `BRONZE` (static)
- Object identifier resolution: `CASE_INSENSITIVE`

Once CDC is running and BRONZE tables exist with data, proceed.

### Step 4 — Deploy the dbt project

```bash
# Deploy dbt to Snowflake
snow dbt deploy SELFHEALING_PROD.CONFIG.SELFHEALING \
  --source ./dbt \
  --connection <connection>

# This also populates ARTIFACT_REGISTRY via the on-run-end hook
```

### Step 5 — Seed the schema registry baseline

```bash
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/11_seed_registry.sql
```

### Step 6 — Start the drift detector

```bash
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/12_drift_detector.sql
snow sql -c $SNOWFLAKE_CONNECTION_SQL -f config/13_pipeline_tasks.sql
```

## Pipeline status lifecycle

```
PENDING → GENERATING → PR_OPEN → CI_PASSED
                              ↘ CI_FAILED  (PR stays open, needs human review)
```

A detected schema change is **always guaranteed to produce a PR** (`PR_OPEN`). The `dbt run` CI test runs after the PR is open and posts its outcome as a comment. A human reviews the PR and the CI comment, then merges. On merge, `SYNC_FROM_MAIN` redeploys the production dbt project.

## Running the pipeline

### Manually trigger a schema change

Add a column to your Postgres source table (or directly to a BRONZE table to simulate), then wait up to 15 minutes for the drift detector, or insert a test event:

```sql
INSERT INTO SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
  (table_schema, table_name, column_name, change_type, new_data_type)
VALUES ('BRONZE', 'ORDERS', 'discount_code', 'NEW_COLUMN', 'TEXT');
```

### Process the event

```sql
-- Get the event ID
SELECT event_id FROM SELFHEALING_PROD.CONFIG.PENDING_SCHEMA_CHANGES LIMIT 1;

-- Run the pipeline for that event
CALL SELFHEALING_PROD.CONFIG.GENERATE_ARTIFACT_CODE('<event-id>');
```

### Validate in DEV and post CI results to the PR

```bash
GITHUB_PAT=<your-pat> python3 config/materialise_in_dev.py <event-id>
```

This script:
1. Opens the PR immediately after writing generated files to disk
2. Clones PROD to DEV, deploys the generated dbt models
3. Runs `dbt run --select source:bronze.<table>+` against the DEV clone
4. Posts a ✅ or ❌ comment to the PR with per-model results
5. Sets `pipeline_status` to `CI_PASSED` or `CI_FAILED`

The PR is opened regardless of whether dbt passes — it is the deliverable. The CI result informs the reviewer.

### What to look for

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

## Licence

MIT
