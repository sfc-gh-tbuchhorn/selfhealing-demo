-- =============================================================
-- 08_github_integration.sql
-- Network rule, secret, and External Access Integration for
-- GitHub REST API calls from Python stored procedures.
--
-- Run once as ACCOUNTADMIN.
-- After running, populate the secret with your GitHub PAT:
--   ALTER SECRET SELFHEALING_PROD.CONFIG.GITHUB_PAT
--     SET SECRET_STRING = '<your_pat_here>';
-- =============================================================

USE DATABASE SELFHEALING_PROD;
USE WAREHOUSE SELFHEALING_WH;

-- -----------------------------------------------------------
-- Network rule: allow outbound HTTPS to GitHub API only
-- -----------------------------------------------------------
CREATE OR REPLACE NETWORK RULE SELFHEALING_PROD.CONFIG.GITHUB_API_RULE
    MODE            = EGRESS
    TYPE            = HOST_PORT
    VALUE_LIST      = ('api.github.com');

-- -----------------------------------------------------------
-- Secret: GitHub Personal Access Token (repo scope)
-- Populate after running:
--   ALTER SECRET SELFHEALING_PROD.CONFIG.GITHUB_PAT
--     SET SECRET_STRING = '<your_pat_here>';
-- -----------------------------------------------------------
CREATE SECRET IF NOT EXISTS SELFHEALING_PROD.CONFIG.GITHUB_PAT
    TYPE            = GENERIC_STRING
    SECRET_STRING   = 'REPLACE_WITH_PAT';

-- -----------------------------------------------------------
-- External Access Integration
-- -----------------------------------------------------------
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION GITHUB_EAI
    ALLOWED_NETWORK_RULES   = (SELFHEALING_PROD.CONFIG.GITHUB_API_RULE)
    ALLOWED_AUTHENTICATION_SECRETS = (SELFHEALING_PROD.CONFIG.GITHUB_PAT)
    ENABLED                 = TRUE;
