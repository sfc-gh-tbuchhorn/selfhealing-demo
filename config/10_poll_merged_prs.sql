USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

CREATE OR REPLACE PROCEDURE SELFHEALING_PROD.CONFIG.POLL_MERGED_PRS()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GITHUB_EAI)
SECRETS = ('github_token' = SELFHEALING_PROD.CONFIG.GITHUB_PAT)
EXECUTE AS OWNER
AS $$
import _snowflake, requests

GITHUB_API = 'https://api.github.com'
REPO       = 'your-username/selfhealing-demo'  # overridden from CONFIG.SETTINGS at runtime


def gh_headers(token):
    return {
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github.v3+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }


def get_pr_state(token, branch_name):
    """Return 'merged', 'closed' (rejected), or 'open' for the branch's PR."""
    owner = REPO.split('/')[0]
    r = requests.get(
        f'{GITHUB_API}/repos/{REPO}/pulls',
        headers=gh_headers(token),
        params={'head': f'{owner}:{branch_name}', 'state': 'all'}
    )
    prs = r.json() if r.ok else []
    for pr in prs:
        if pr.get('merged_at'):
            return 'merged'
        if pr.get('state') == 'closed':
            return 'closed'
    return 'open'


def run(session):
    global REPO
    REPO = ({r[0]: r[1] for r in session.sql('SELECT key, value FROM SELFHEALING_PROD.CONFIG.SETTINGS').collect()}).get('github_repo', REPO)

    token = _snowflake.get_generic_secret_string('github_token')

    rows = session.sql("""
        SELECT event_id, branch_name
        FROM SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
        WHERE pipeline_status IN ('PR_OPEN', 'CI_PASSED', 'CI_FAILED')
          AND branch_name IS NOT NULL
        ORDER BY detected_at ASC
    """).collect()

    if not rows:
        return 'No open PRs to check'

    synced  = []
    retried = []
    for row in rows:
        branch   = row['BRANCH_NAME']
        event_id = row['EVENT_ID']
        state    = get_pr_state(token, branch)

        if state == 'merged':
            # Use session.call() rather than session.sql('CALL ...').collect():
            # collecting a CALL result whose single column is the proc name
            # ('SYNC_FROM_MAIN') trips a Snowpark "existing quoted column
            # identifiers" error. session.call() invokes the proc cleanly.
            session.call('SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN', branch)
            synced.append(branch)

        elif state == 'closed':
            # PR was closed without merging (rejected by reviewer).
            # Reset to PENDING so GENERATE_AND_PREP retries with a fresh
            # branch and PR — prevents the event being stuck forever.
            session.sql(f"""
                UPDATE SELFHEALING_PROD.CONFIG.SCHEMA_CHANGE_EVENTS
                SET pipeline_status = 'PENDING',
                    branch_name     = NULL,
                    mr_url          = NULL
                WHERE event_id = '{event_id}'
            """).collect()
            retried.append(branch)

    parts = []
    if synced:  parts.append('Synced: '  + ', '.join(synced))
    if retried: parts.append('Retried: ' + ', '.join(retried))
    return ', '.join(parts) if parts else 'Checked ' + str(len(rows)) + ' open PR(s) — none merged yet'
$$;


-- Task: poll every 5 minutes (same cadence as PIPELINE_ROOT)
CREATE OR REPLACE TASK SELFHEALING_PROD.CONFIG.POLL_MERGED_PRS_TASK
    WAREHOUSE = SELFHEALING_WH
    SCHEDULE  = '5 MINUTE'
AS
    CALL SELFHEALING_PROD.CONFIG.POLL_MERGED_PRS();

ALTER TASK SELFHEALING_PROD.CONFIG.POLL_MERGED_PRS_TASK RESUME;

GRANT USAGE ON PROCEDURE SELFHEALING_PROD.CONFIG.POLL_MERGED_PRS()
  TO ROLE SELFHEALING_PIPELINE;
