"""
refresh_artifact_registry.py
Runs dbt ls --output json, parses the dependency graph,
and upserts into SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY.

Run after every `snow dbt deploy`:
  python3 config/refresh_artifact_registry.py
"""

import subprocess, json, snowflake.connector, os

SQL_CONNECTION = "demo_au"        # snow CLI connection for dbt ls
PY_CONNECTION  = "demo_au_PAT"    # Python connector (password auth)
DB             = "SELFHEALING_PROD"
DBT_PROJECT    = "PLATFORM_REGISTRY.DBT.SELFHEALING"

# ── 1. Run dbt ls via snow sql --format json ──────────────────
print("Running dbt ls...")
cmd = [
    "snow", "sql", "-c", SQL_CONNECTION, "--format", "json", "-q",
    f"EXECUTE DBT PROJECT {DBT_PROJECT} "
    "ARGS = 'ls --resource-type model --output json --target prod'"
]
result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode != 0:
    print("ERROR running dbt ls:")
    print(result.stderr[:500])
    exit(1)

# snow --format json returns a list of row dicts; STDOUT is one field
rows_raw = json.loads(result.stdout)
stdout = rows_raw[0].get("STDOUT", "") if rows_raw else ""

# ── 2. Parse JSON lines from STDOUT ───────────────────────────
models = {}
for line in stdout.splitlines():
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        m = json.loads(line)
        uid = m['unique_id']
        models[uid] = {
            'name':       m['name'],
            'schema':     m['config']['schema'].upper(),
            'file_path':  m['original_file_path'],
            'depends_on': m['depends_on']['nodes']
        }
    except Exception:
        continue

print(f"Parsed {len(models)} models: {[m['name'] for m in models.values()]}")

# ── 3. Build FQN map for model→model dep resolution ──────────
fqn_map = {
    uid: f"{DB}.{m['schema']}.{m['name'].upper()}"
    for uid, m in models.items()
}

# ── 4. Build registry rows ────────────────────────────────────
registry_rows = []
for uid, m in models.items():
    artifact_fqn = fqn_map[uid]
    for dep in m['depends_on']:
        if dep.startswith('source.'):
            # source.selfhealing.bronze.order_items → BRONZE.ORDER_ITEMS
            parts = dep.split('.')
            source_table = f"{parts[2].upper()}.{parts[3].upper()}"
        elif dep.startswith('model.'):
            # model.selfhealing.order_items → look up from fqn_map
            dep_fqn = fqn_map.get(dep)
            if not dep_fqn:
                continue
            # SELFHEALING_PROD.SILVER.ORDER_ITEMS → SILVER.ORDER_ITEMS
            source_table = '.'.join(dep_fqn.split('.')[1:])
        else:
            continue

        registry_rows.append({
            'artifact_name': f"{m['schema'].lower()}.{m['name']}",
            'artifact_type': 'dbt_model',
            'source_table':  source_table,
            'artifact_sql':  '',
            'file_path':     m['file_path'],
            'snowflake_fqn': artifact_fqn
        })

print(f"Built {len(registry_rows)} registry rows")

# ── 5. Upsert into ARTIFACT_REGISTRY ─────────────────────────
conn = snowflake.connector.connect(connection_name=PY_CONNECTION)
cur  = conn.cursor()

cur.execute(f"DELETE FROM {DB}.CONFIG.ARTIFACT_REGISTRY WHERE artifact_type = 'dbt_model'")

for r in registry_rows:
    cur.execute(f"""
        INSERT INTO {DB}.CONFIG.ARTIFACT_REGISTRY
            (artifact_name, artifact_type, source_table, artifact_sql, file_path, snowflake_fqn)
        VALUES (%s, %s, %s, %s, %s, %s)
    """, (r['artifact_name'], r['artifact_type'], r['source_table'],
          r['artifact_sql'],  r['file_path'],     r['snowflake_fqn']))

conn.commit()
cur.close()
conn.close()

print("\nARTIFACT_REGISTRY refreshed:")
for r in sorted(registry_rows, key=lambda x: x['source_table']):
    print(f"  {r['source_table']:30} → {r['artifact_name']:30} ({r['file_path']})")
