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


def is_merged(token, branch_name):
    owner = REPO.split('/')[0]
    r = requests.get(
        f'{GITHUB_API}/repos/{REPO}/pulls',
        headers=gh_headers(token),
        params={'head': f'{owner}:{branch_name}', 'state': 'closed'}
    )
    prs = r.json() if r.ok else []
    return any(pr.get('merged_at') for pr in prs)


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

    synced = []
    for row in rows:
        branch = row['BRANCH_NAME']
        if is_merged(token, branch):
            session.sql(
                "CALL SELFHEALING_PROD.CONFIG.SYNC_FROM_MAIN('" + branch + "')"
            ).collect()
            synced.append(branch)

    if synced:
        return 'Synced: ' + ', '.join(synced)
    return 'Checked ' + str(len(rows)) + ' open PR(s) — none merged yet'
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
