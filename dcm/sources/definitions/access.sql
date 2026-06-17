-- Roles
DEFINE ROLE {{name_prefix}}_READER{{db_suffix}}
    COMMENT = 'Read access to GOLD schema ({{env}})';

DEFINE ROLE {{name_prefix}}_ANALYST{{db_suffix}}
    COMMENT = 'Read access to SILVER and GOLD schemas ({{env}})';

DEFINE ROLE {{name_prefix}}_ADMIN{{db_suffix}}
    COMMENT = 'Full access to all schemas in {{db_name}} ({{env}})';

-- Warehouse usage
GRANT USAGE ON WAREHOUSE {{name_prefix}}_WH{{db_suffix}} TO ROLE {{name_prefix}}_READER{{db_suffix}};
GRANT USAGE ON WAREHOUSE {{name_prefix}}_WH{{db_suffix}} TO ROLE {{name_prefix}}_ANALYST{{db_suffix}};
GRANT ALL   ON WAREHOUSE {{name_prefix}}_WH{{db_suffix}} TO ROLE {{name_prefix}}_ADMIN{{db_suffix}};

-- Database usage
GRANT USAGE ON DATABASE {{db_name}} TO ROLE {{name_prefix}}_READER{{db_suffix}};
GRANT USAGE ON DATABASE {{db_name}} TO ROLE {{name_prefix}}_ANALYST{{db_suffix}};
GRANT ALL   ON DATABASE {{db_name}} TO ROLE {{name_prefix}}_ADMIN{{db_suffix}};

-- Reader: GOLD schema only
GRANT USAGE  ON SCHEMA {{db_name}}.GOLD                    TO ROLE {{name_prefix}}_READER{{db_suffix}};
GRANT SELECT ON ALL TABLES IN SCHEMA {{db_name}}.GOLD      TO ROLE {{name_prefix}}_READER{{db_suffix}};
GRANT SELECT ON FUTURE TABLES IN SCHEMA {{db_name}}.GOLD   TO ROLE {{name_prefix}}_READER{{db_suffix}};

-- Analyst: SILVER + GOLD schemas
GRANT USAGE  ON SCHEMA {{db_name}}.SILVER                  TO ROLE {{name_prefix}}_ANALYST{{db_suffix}};
GRANT SELECT ON ALL TABLES IN SCHEMA {{db_name}}.SILVER    TO ROLE {{name_prefix}}_ANALYST{{db_suffix}};
GRANT SELECT ON FUTURE TABLES IN SCHEMA {{db_name}}.SILVER TO ROLE {{name_prefix}}_ANALYST{{db_suffix}};
GRANT ROLE {{name_prefix}}_READER{{db_suffix}} TO ROLE {{name_prefix}}_ANALYST{{db_suffix}};

-- Admin: all schemas
GRANT ALL ON SCHEMA {{db_name}}.BRONZE TO ROLE {{name_prefix}}_ADMIN{{db_suffix}};
GRANT ALL ON SCHEMA {{db_name}}.SILVER TO ROLE {{name_prefix}}_ADMIN{{db_suffix}};
GRANT ALL ON SCHEMA {{db_name}}.GOLD   TO ROLE {{name_prefix}}_ADMIN{{db_suffix}};
GRANT ROLE {{name_prefix}}_ANALYST{{db_suffix}} TO ROLE {{name_prefix}}_ADMIN{{db_suffix}};
