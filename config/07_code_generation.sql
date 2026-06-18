-- =============================================================
-- 06_code_generation.sql
-- GENERATE_ARTIFACT_CODE — EXECUTE AS CALLER
--
-- Reads impacted artifacts from SELFHEALING_PROD (SELECT only),
-- calls Cortex AI to generate updated SQL, writes results to
-- SELFHEALING_DEV.CONFIG.GENERATED_CODE (INSERT only).
--
-- All prompt/SQL values are passed as Snowpark DataFrame column
-- values — never as SQL string literals — so Jinja macros like
-- {{ source('bronze', 'order_items') }} are never escaped or
-- mangled before reaching the LLM.
--
-- Generated changes are stored in
-- SCHEMA_CHANGE_EVENTS.generated_changes (VARIANT) instead of a
-- separate GENERATED_CODE table.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.GENERATE_ARTIFACT_CODE(
    event_id VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS $$
import json
import re
MODEL = 'llama3.1-70b'


def restore_config_block(original_sql, generated_sql):
    """
    Safety net: if the LLM stripped the {{ config(...) }} block,
    extract it from the original and prepend it to the generated SQL.
    """
    if generated_sql.strip().startswith('{{'):
        return generated_sql
    match = re.match(r'(\{\{.*?\}\})', original_sql.strip(), re.DOTALL)
    if match:
        return match.group(1) + '\n\n' + generated_sql.strip()
    return generated_sql


def restore_ref_calls(original_sql, generated_sql):
    """
    Safety net: if the LLM changed {{ ref('X') }} to {{ source('...', 'X') }},
    restore all ref() calls from the original. Operates on normalised lowercase
    model names so casing differences are handled.
    """
    ref_pattern    = re.compile(r"\{\{\s*ref\(\s*['\"](\w+)['\"]\s*\)\s*\}\}")
    source_pattern = re.compile(r"\{\{[^}]*source\([^)]*['\"](\w+)['\"]\s*\)\s*\}\}")

    original_refs = {m.group(1).lower(): m.group(0) for m in ref_pattern.finditer(original_sql)}
    if not original_refs:
        return generated_sql

    def replace_source_with_ref(m):
        table = m.group(1).lower()
        if table in original_refs:
            return original_refs[table]
        return m.group(0)

    return source_pattern.sub(replace_source_with_ref, generated_sql)


def cortex_complete(session, prompt):
    """
    Insert prompt into a real staging table (single-quote escaped for SQL),
    call CORTEX.COMPLETE reading from that row, then delete.
    Jinja macros survive because SQL unescapes '' back to ' on storage.
    Works inside nested stored procedures with no temp views or bind params.
    """
    import uuid
    job_id  = str(uuid.uuid4())
    escaped = prompt.replace("'", "''")
    try:
        session.sql(
            f"INSERT INTO SELFHEALING_PROD.CONFIG.PROMPT_STAGING (JOB_ID, PROMPT) "
            f"VALUES ('{job_id}', '{escaped}')"
        ).collect()
        result = session.sql(
            f"SELECT AI_COMPLETE('{MODEL}', PROMPT) AS RESPONSE "
            f"FROM SELFHEALING_PROD.CONFIG.PROMPT_STAGING WHERE JOB_ID = '{job_id}'"
        ).collect()[0]['RESPONSE']
        return result
    finally:
        session.sql(
            f"DELETE FROM SELFHEALING_PROD.CONFIG.PROMPT_STAGING WHERE JOB_ID = '{job_id}'"
        ).collect()


def store_generated_changes(session, event_id, changes):
    """
    Store artifact metadata in generated_changes (small, avoids JSON
    escaping issues), and write the full generated SQL to the
    GENERATED_CODE table via a Snowpark DataFrame (clean escaping).
    """
    metadata = [
        {'artifact_name': c['artifact_name'],
         'file_path':     c['file_path'],
         'action':        c['action']}
        for c in changes
    ]
    escaped = json.dumps(metadata).replace("'", "''")
    session.sql(
        f"""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET generated_changes = PARSE_JSON('{escaped}'),
            pipeline_status   = 'GENERATED'
        WHERE event_id = '{event_id}'
        """
    ).collect()

    # Clear any prior generated code for this event, then write full SQL
    session.sql(
        f"DELETE FROM SELFHEALING_PROD.CONFIG.GENERATED_CODE WHERE event_id = '{event_id}'"
    ).collect()
    for c in changes:
        if c.get('generated_sql'):
            session.sql(
                "INSERT INTO SELFHEALING_PROD.CONFIG.GENERATED_CODE "
                "(event_id, artifact_name, file_path, action, generated_sql) "
                "VALUES (?, ?, ?, ?, ?)",
                params=[event_id, c['artifact_name'], c['file_path'], c['action'], c['generated_sql']]
            ).collect()


def build_column_prompt(change_type, table_name, column_name,
                        old_type, new_type, artifact_sql, file_path):
    rules = {
        'NEW_COLUMN': (
            f"Add {column_name} ({new_type}) to the SELECT list "
            f"after the last existing source column."
        ),
        'COLUMN_DROP': (
            f"Remove {column_name} from the SELECT list and from any "
            f"GROUP BY, ORDER BY, or WHERE clauses that reference it."
        ),
        'TYPE_CHANGE': (
            f"Wrap {column_name} in CAST({column_name} AS {new_type}) "
            f"everywhere it appears in the SELECT list."
        ),
    }
    rule = rules.get(change_type, f"Update the model to reflect: {change_type} on {column_name}.")

    return f"""You are a dbt SQL developer. A schema change has occurred on a source table.

Schema change:
  Table:   BRONZE.{table_name}
  Change:  {change_type}
  Column:  {column_name}
  Old type: {old_type or 'N/A'}
  New type: {new_type or 'N/A'}

Current dbt model ({file_path}):
{artifact_sql}

Rules:
- The {{{{ config(...) }}}} block MUST be the first element of the model — never remove it, move it, or modify its arguments
- Preserve ALL {{{{ config() }}}}, {{{{ source() }}}}, {{{{ ref() }}}} calls exactly — do not change, add, or remove any of them
- Only modify the SELECT column list and GROUP BY / ORDER BY where necessary
- {rule}
- If this model is an aggregation (has GROUP BY or COUNT/SUM/AVG) and the new column is a raw attribute, do NOT add it unless it is already referenced in the FROM/JOIN
- If the change does not affect this model, return the model unchanged
- Return ONLY the updated SQL with no explanation, no markdown fences

Updated model:"""


def build_new_table_prompt(table_name, columns, primary_key):
    col_lines = '\n'.join(
        f"  - {c['name']}: {c['type']}" +
        (" (primary key)" if c['name'] == primary_key else "")
        for c in columns
    )
    col_select = '\n    '.join(c['name'] for c in columns)
    table_lower = table_name.lower()

    return f"""You are a dbt SQL developer. A new table has been created in the BRONZE layer.

New table: BRONZE.{table_name}
Columns:
{col_lines}

Generate a new dbt SILVER model following this exact pattern:
{{{{ config(database=var('db_name'), schema='SILVER') }}}}
SELECT
    {col_select}
FROM {{{{ source('bronze', '{table_lower}') }}}}
WHERE (_SNOWFLAKE_DELETED IS NULL OR _SNOWFLAKE_DELETED = FALSE)
QUALIFY ROW_NUMBER() OVER (PARTITION BY {primary_key} ORDER BY _SNOWFLAKE_UPDATED_AT DESC) = 1

Also provide the sources.yml line to add under the bronze source tables list.
Return two sections separated by exactly this line: ---SOURCES_YML---
Section 1: the complete dbt model SQL
Section 2: the sources.yml table entry (e.g. "      - name: {table_lower}")

Updated model:"""


def run(session, event_id):
    impact = session.sql(
        f"CALL SELFHEALING_PROD.CONFIG.GET_IMPACTED_ARTIFACTS('{event_id}')"
    ).collect()[0][0]

    if isinstance(impact, str):
        impact = json.loads(impact)

    event       = impact['event']
    change_type = event['change_type']
    table_name  = event['table_name']
    column_name = event.get('column_name', '')
    old_type    = event.get('old_type', '')
    new_type    = event.get('new_type', '')
    generated   = []
    changes     = []  # accumulates all generated artifacts for SCHEMA_CHANGE_EVENTS

    # Mark event as generating
    session.sql(f"""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET pipeline_status = 'GENERATING'
        WHERE event_id = '{event_id}'
    """).collect()

    # ── Branch 1: column-level changes ───────────────────────────
    if change_type in ('NEW_COLUMN', 'COLUMN_DROP', 'TYPE_CHANGE'):
        for artifact in impact.get('impacted', []):
            artifact_name = artifact['artifact_name']
            file_path     = artifact['file_path']

            rows = session.sql(f"""
                SELECT ARTIFACT_SQL
                FROM SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
                WHERE ARTIFACT_NAME = '{artifact_name}'
                LIMIT 1
            """).collect()
            artifact_sql = rows[0]['ARTIFACT_SQL'] if rows else ''

            prompt = build_column_prompt(
                change_type, table_name, column_name,
                old_type, new_type, artifact_sql, file_path
            )

            # Prompt passed as column value — no escaping
            result = cortex_complete(session, prompt)
            result = restore_config_block(artifact_sql, result)
            result = restore_ref_calls(artifact_sql, result)

            changes.append({
                'artifact_name': artifact_name,
                'file_path':     file_path,
                'action':        'UPDATE',
                'original_sql':  artifact_sql,
                'generated_sql': result,
            })

            generated.append({
                'artifact_name': artifact_name,
                'file_path':     file_path,
                'action':        'UPDATE'
            })

    # ── Branch 2: new table ───────────────────────────────────────
    elif change_type == 'NEW_TABLE':
        gen_block   = impact.get('generate', {})
        columns     = gen_block.get('columns', [])
        primary_key = gen_block.get('primary_key', columns[0]['name'] if columns else 'ID')
        silver_path = gen_block.get('silver_model_path', f"models/silver/{table_name.lower()}.sql")

        if not columns:
            return {'event_id': event_id,
                    'error': 'No columns found — BRONZE table may not exist yet'}

        prompt = build_new_table_prompt(table_name, columns, primary_key)
        result = cortex_complete(session, prompt)

        parts        = result.split('---SOURCES_YML---')
        model_sql    = parts[0].strip()
        sources_yaml = parts[1].strip() if len(parts) > 1 else ''

        changes.append({
            'artifact_name':        f"silver.{table_name.lower()}",
            'file_path':            silver_path,
            'action':               'CREATE',
            'original_sql':         '',
            'generated_sql':        model_sql,
            'sources_yml_addition': sources_yaml,
        })
        generated.append({'artifact_name': f"silver.{table_name.lower()}",
                           'file_path': silver_path, 'action': 'CREATE'})

    # ── Persist all generated changes atomically ──────────────────
    if changes:
        store_generated_changes(session, event_id, changes)

    return {
        'event_id':    event_id,
        'change_type': change_type,
        'generated':   generated,
        'changes':     changes,  # full list including generated_sql for stage writes
    }
$$;

-- -----------------------------------------------------------
-- GENERATE_NEXT_PENDING
-- Finds the oldest PENDING event and calls GENERATE_ARTIFACT_CODE.
-- Called by PIPELINE_ROOT task — avoids scripting blocks in
-- task body which are incompatible with snow sql -f execution.
-- Returns NULL if no pending events exist.
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.GENERATE_NEXT_PENDING()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS CALLER
AS $$
def run(session):
    row = session.sql("""
        SELECT event_id
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE pipeline_status = 'PENDING'
        ORDER BY detected_at
        LIMIT 1
    """).collect()
    if not row:
        return {'status': 'no_pending_events'}
    event_id = row[0][0]
    return session.call('SELFHEALING_PROD.CONFIG.GENERATE_ARTIFACT_CODE', event_id)
$$;
