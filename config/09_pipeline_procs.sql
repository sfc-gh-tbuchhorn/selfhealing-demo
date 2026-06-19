-- =============================================================
-- 09_pipeline_procs.sql
-- Three procedures that form the Snowflake-native pipeline:
--
--  GENERATE_AND_PREP()   — picks up oldest PENDING event,
--    generates code via Cortex AI, commits files to a Git
--    feature branch via GitHub API, fetches the repo, and
--    deploys SELFHEALING_TEST from that branch.
--    EXECUTE AS OWNER (needs EAI + CREATE DBT PROJECT).
--
--  COMMIT_TO_GITHUB()    — for event in TESTING state that passed,
--    opens a GitHub PR. Files are already committed by
--    GENERATE_AND_PREP so this is PR creation only.
--    EXECUTE AS OWNER (needs EAI + SCHEMA_CHANGE_EVENTS UPDATE).
--
--  HANDLE_TEST_FAILURE() — finalizer; if any event is stuck in
--    TESTING (dbt task failed), marks it FAILED. No stage
--    revert needed — the failed branch stays in GitHub for
--    debugging but no PR is opened.
--    EXECUTE AS OWNER.
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- -----------------------------------------------------------
-- GENERATE_AND_PREP
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.GENERATE_AND_PREP()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GITHUB_EAI)
SECRETS = ('github_token' = SELFHEALING_PROD.CONFIG.GITHUB_PAT)
EXECUTE AS OWNER
AS $$
import _snowflake, requests, base64, json

GITHUB_API   = 'https://api.github.com'
REPO         = 'your-username/selfhealing-demo'
BASE_BRANCH  = 'main'
GIT_REPO     = 'SELFHEALING_PROD.CONFIG.SELFHEALING_REPO'
# Default DEV-test dbt project. Overridden by SETTINGS.dbt_project at runtime.
# Must match the project RUN_DEV_TEST (14) executes — keep them aligned.
TEST_PROJECT = 'SELFHEALING_PROD.CONFIG.SELFHEALING'


def gh_headers(token):
    return {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }


def branch_sha(token, branch):
    r = requests.get(
        f'{GITHUB_API}/repos/{REPO}/git/refs/heads/{branch}',
        headers=gh_headers(token)
    )
    r.raise_for_status()
    return r.json()['object']['sha']


def create_branch(token, branch_name, sha):
    r = requests.post(
        f'{GITHUB_API}/repos/{REPO}/git/refs',
        headers=gh_headers(token),
        json={'ref': f'refs/heads/{branch_name}', 'sha': sha}
    )
    if r.status_code == 422:
        return  # branch already exists — reuse it
    r.raise_for_status()


def file_sha(token, path, branch):
    r = requests.get(
        f'{GITHUB_API}/repos/{REPO}/contents/{path}',
        headers=gh_headers(token),
        params={'ref': branch}
    )
    return r.json().get('sha') if r.status_code == 200 else None


def commit_file(token, path, content, branch, message, existing_sha=None):
    body = {
        'message': message,
        'content': base64.b64encode(content.encode()).decode(),
        'branch': branch,
    }
    if existing_sha:
        body['sha'] = existing_sha
    r = requests.put(
        f'{GITHUB_API}/repos/{REPO}/contents/{path}',
        headers=gh_headers(token),
        json=body
    )
    r.raise_for_status()


def run(session):
    global REPO, TEST_PROJECT
    _s = {r[0]: r[1] for r in session.sql('SELECT key, value FROM SELFHEALING_PROD.CONFIG.SETTINGS').collect()}
    REPO         = _s.get('github_repo', REPO)
    TEST_PROJECT = _s.get('dbt_project', TEST_PROJECT)

    token = _snowflake.get_generic_secret_string('github_token')

    # Find oldest event with pipeline_status = PENDING
    rows = session.sql("""
        SELECT event_id, change_type, table_name
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE pipeline_status = 'PENDING'
          AND status          = 'PENDING'
        ORDER BY detected_at ASC
        LIMIT 1
    """).collect()

    if not rows:
        return 'No pending events'

    event_id = rows[0]['EVENT_ID']

    # Generate code — returns full changes list including generated_sql
    gen_result_rows = session.sql(
        f"CALL SELFHEALING_PROD.CONFIG.GENERATE_ARTIFACT_CODE('{event_id}')"
    ).collect()
    gen_result = json.loads(gen_result_rows[0][0])
    generated_changes = gen_result.get('changes', [])

    # Refresh DEV clone
    session.sql(
        'CALL SELFHEALING_PROD.CONFIG.REFRESH_DEV_ENVIRONMENT()'
    ).collect()

    # Always branch from main — Git handles conflicts at review time
    branch_name = f"schema-change/{event_id[:8]}"

    # Create feature branch off base
    sha = branch_sha(token, base)
    create_branch(token, branch_name, sha)

    # Store branch_name immediately for idempotency
    session.sql(f"""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET branch_name = '{branch_name}'
        WHERE event_id  = '{event_id}'
    """).collect()

    # Commit each generated file to the feature branch
    change_type = gen_result.get('change_type', '')
    for change in generated_changes:
        path     = change['file_path']
        content  = change['generated_sql']
        msg      = f"schema({change_type.lower()}): update {path}"
        existing = file_sha(token, path, branch_name)
        commit_file(token, path, content, branch_name, msg, existing)

    # ── Open PR immediately (PR-first: PR is the guaranteed deliverable) ────
    table_name  = rows[0]['TABLE_NAME']
    column_name = gen_result.get('column_name', '')
    artifact_list = [
        f"- `{c['artifact_name']}` ({c['action']})"
        for c in generated_changes
    ]
    pr_title = f"[schema-change] {change_type} on {table_name}.{column_name}".rstrip('.')
    pr_body  = f"""## Schema Change: {change_type}

**Table:** `BRONZE.{table_name}`
**Column:** `{column_name or '(new table)'}`
**Event ID:** `{event_id}`
**Branch:** `{branch_name}`

## Impacted Artifacts
{chr(10).join(artifact_list)}

## CI Status
_dbt validation is running against a zero-copy clone of SELFHEALING_PROD._
_Results will be posted as a comment below._

> Auto-generated by Snowflake schema drift pipeline.
"""
    r = requests.post(
        f'{GITHUB_API}/repos/{REPO}/pulls',
        headers=gh_headers(token),
        json={'title': pr_title, 'head': branch_name, 'base': BASE_BRANCH, 'body': pr_body}
    )
    if r.status_code == 422:   # PR already exists
        existing_prs = requests.get(
            f'{GITHUB_API}/repos/{REPO}/pulls',
            headers=gh_headers(token),
            params={'head': f'sfc-gh-tbuchhorn:{branch_name}', 'state': 'open'}
        )
        pr_url = existing_prs.json()[0]['html_url'] if existing_prs.ok and existing_prs.json() else ''
    else:
        r.raise_for_status()
        pr_url = r.json()['html_url']

    # Fetch Git repo so Snowflake sees the new branch content
    session.sql(
        f'ALTER GIT REPOSITORY {GIT_REPO} FETCH'
    ).collect()

    # Deploy SELFHEALING_TEST from the feature branch.
    # Branch names with slashes need quoting: /branches/"schema-change/xxx"/
    # The dbt project lives in the repo's dbt/ subdirectory, so the path ends
    # in /dbt/ (dbt_project.yml must be at the FROM path root).
    session.sql(
        f'CREATE OR REPLACE DBT PROJECT {TEST_PROJECT} '
        f'FROM @{GIT_REPO}/branches/"{branch_name}"/dbt/'
    ).collect()

    # Store PR URL and mark ready for testing
    pr_url_esc = pr_url.replace("'", "''")
    session.sql(f"""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET pipeline_status = 'PR_OPEN',
            mr_url          = '{pr_url_esc}'
        WHERE event_id = '{event_id}'
    """).collect()

    return f'PR opened: {pr_url} — event {event_id} ready for dbt CI'
$$;


-- -----------------------------------------------------------
-- COMMIT_TO_GITHUB (repurposed: now posts dbt CI result as PR comment)
-- Called by COMMIT_AND_MR task after dbt test succeeds.
-- PR is already open from GENERATE_AND_PREP.
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.COMMIT_TO_GITHUB()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GITHUB_EAI)
SECRETS = ('github_token' = SELFHEALING_PROD.CONFIG.GITHUB_PAT)
EXECUTE AS OWNER
AS $$
import _snowflake, requests, re

GITHUB_API = 'https://api.github.com'
REPO       = 'your-username/selfhealing-demo'


def _headers(token):
    return {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }


def post_comment(token, pr_url, body):
    m = re.search(r'/pull/(\d+)', pr_url)
    if not m:
        return
    r = requests.post(
        f'{GITHUB_API}/repos/{REPO}/issues/{m.group(1)}/comments',
        headers=_headers(token),
        json={'body': body}
    )
    r.raise_for_status()


def run(session):
    global REPO
    REPO = ({r[0]: r[1] for r in session.sql('SELECT key, value FROM SELFHEALING_PROD.CONFIG.SETTINGS').collect()}).get('github_repo', REPO)

    token = _snowflake.get_generic_secret_string('github_token')

    # Find event in PR_OPEN state (dbt task just succeeded)
    rows = session.sql("""
        SELECT event_id, change_type, table_name, mr_url
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE pipeline_status = 'PR_OPEN'
        ORDER BY detected_at ASC
        LIMIT 1
    """).collect()

    if not rows:
        return 'No events in PR_OPEN state'

    event_id    = rows[0]['EVENT_ID']
    change_type = rows[0]['CHANGE_TYPE']
    table_name  = rows[0]['TABLE_NAME']
    pr_url      = rows[0]['MR_URL'] or ''

    comment = f"""## \u2705 dbt CI \u2014 All Tests Passed

`dbt run` completed successfully against `SELFHEALING_DEV` (zero-copy clone of PROD).

- All impacted models materialised with no errors
- Schema change validated end-to-end through BRONZE \u2192 SILVER \u2192 GOLD
- Safe to merge

_Validated by Snowflake schema drift pipeline \u2014 {change_type} on BRONZE.{table_name}_
"""
    if pr_url:
        post_comment(token, pr_url, comment)

    session.sql(f"""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET pipeline_status = 'CI_PASSED'
        WHERE event_id = '{event_id}'
    """).collect()

    return f'CI_PASSED comment posted to PR: {pr_url}'
$$;


-- -----------------------------------------------------------
-- HANDLE_TEST_FAILURE
-- Finalizer: posts dbt failure as a PR comment and marks
-- the event CI_FAILED. PR stays open for human review.
-- -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.HANDLE_TEST_FAILURE()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GITHUB_EAI)
SECRETS = ('github_token' = SELFHEALING_PROD.CONFIG.GITHUB_PAT)
EXECUTE AS OWNER
AS $$
import _snowflake, requests, re

GITHUB_API = 'https://api.github.com'
REPO       = 'your-username/selfhealing-demo'


def _headers(token):
    return {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }


def post_comment(token, pr_url, body):
    m = re.search(r'/pull/(\d+)', pr_url)
    if not m:
        return
    r = requests.post(
        f'{GITHUB_API}/repos/{REPO}/issues/{m.group(1)}/comments',
        headers=_headers(token),
        json={'body': body}
    )
    r.raise_for_status()


def run(session):
    global REPO
    REPO = ({r[0]: r[1] for r in session.sql('SELECT key, value FROM SELFHEALING_PROD.CONFIG.SETTINGS').collect()}).get('github_repo', REPO)

    token = _snowflake.get_generic_secret_string('github_token')

    # Reset events stuck in GENERATING so they retry
    session.sql("""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET pipeline_status = 'PENDING'
        WHERE pipeline_status = 'GENERATING'
    """).collect()

    # Any event in PR_OPEN after the DAG ran means dbt failed
    rows = session.sql("""
        SELECT event_id, change_type, table_name, mr_url
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE pipeline_status = 'PR_OPEN'
        ORDER BY detected_at ASC
        LIMIT 1
    """).collect()

    if not rows:
        return 'No failed events'

    event_id    = rows[0]['EVENT_ID']
    change_type = rows[0]['CHANGE_TYPE']
    table_name  = rows[0]['TABLE_NAME']
    pr_url      = rows[0]['MR_URL'] or ''

    comment = f"""## \u274c dbt CI \u2014 Tests Failed

`dbt run` failed against `SELFHEALING_DEV` (zero-copy clone of PROD).

This PR requires human review before merging. The feature branch is preserved for debugging.

Possible causes:
- Generated SQL references a column that does not exist in the source
- Jinja macro was corrupted during code generation
- Type incompatibility between BRONZE and a downstream model

_Check the dbt task logs in Snowflake for the specific model error._

_Flagged by Snowflake schema drift pipeline \u2014 {change_type} on BRONZE.{table_name}_
"""
    if pr_url:
        post_comment(token, pr_url, comment)

    session.sql(f"""
        UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        SET pipeline_status = 'CI_FAILED',
            status          = 'PENDING'
        WHERE event_id = '{event_id}'
    """).collect()

    return f'CI_FAILED comment posted to PR: {pr_url}'
$$;


-- ── Procedure usage grants ────────────────────────────────────
GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.GENERATE_AND_PREP()
  TO ROLE SELFHEALING_PIPELINE;
GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.COMMIT_TO_GITHUB()
  TO ROLE SELFHEALING_PIPELINE;
GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.HANDLE_TEST_FAILURE()
  TO ROLE SELFHEALING_PIPELINE;
