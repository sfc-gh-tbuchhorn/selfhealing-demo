USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.COMMIT_WORKFLOW_FILE()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GITHUB_EAI)
SECRETS = ('github_token' = SELFHEALING_PROD.CONFIG.GITHUB_PAT)
EXECUTE AS OWNER
AS $$
import _snowflake, requests, base64

GITHUB_API = 'https://api.github.com'
REPO       = 'sfc-gh-tbuchhorn/selfhealing_demo'
BRANCH     = 'main'
PATH       = '.github/workflows/sync_snowflake_on_merge.yml'

CONTENT = """name: Sync Snowflake on PR Merge

on:
  pull_request:
    types: [closed]
    branches: [main]

jobs:
  sync_snowflake:
    if: github.event.pull_request.merged == true
    runs-on: ubuntu-latest

    steps:
      - name: Install Snowflake connector
        run: pip install snowflake-connector-python

      - name: Call SYNC_FROM_MAIN
        env:
          SNOWFLAKE_ACCOUNT:   ${{ secrets.SNOWFLAKE_ACCOUNT }}
          SNOWFLAKE_USER:      ${{ secrets.SNOWFLAKE_USER }}
          SNOWFLAKE_PASSWORD:  ${{ secrets.SNOWFLAKE_PASSWORD }}
          SNOWFLAKE_WAREHOUSE: SELFHEALING_WH
          SNOWFLAKE_ROLE:      ACCOUNTADMIN
          PR_BRANCH:           ${{ github.event.pull_request.head.ref }}
        run: |
          python3 - <<'PYEOF'
          import os, snowflake.connector
          conn = snowflake.connector.connect(
              account   = os.environ['SNOWFLAKE_ACCOUNT'],
              user      = os.environ['SNOWFLAKE_USER'],
              password  = os.environ['SNOWFLAKE_PASSWORD'],
              warehouse = os.environ['SNOWFLAKE_WAREHOUSE'],
              role      = os.environ['SNOWFLAKE_ROLE'],
          )
          branch = os.environ['PR_BRANCH']
          cur    = conn.cursor()
          cur.execute("CALL SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN(%s)", (branch,))
          result = cur.fetchone()
          print(f"Snowflake: {result[0]}")
          cur.close()
          conn.close()
          PYEOF
"""

def headers(token):
    return {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }

def run(session):
    token = _snowflake.get_generic_secret_string('github_token')

    r = requests.get(
        f'{GITHUB_API}/repos/{REPO}/contents/{PATH}',
        headers=headers(token), params={'ref': BRANCH}
    )
    existing_sha = r.json().get('sha') if r.status_code == 200 else None

    body = {
        'message': 'chore: add Snowflake sync GitHub Action',
        'content': base64.b64encode(CONTENT.encode()).decode(),
        'branch': BRANCH,
    }
    if existing_sha:
        body['sha'] = existing_sha

    r = requests.put(
        f'{GITHUB_API}/repos/{REPO}/contents/{PATH}',
        headers=headers(token), json=body
    )
    r.raise_for_status()
    return f'Committed {PATH} to {BRANCH}'
$$;
