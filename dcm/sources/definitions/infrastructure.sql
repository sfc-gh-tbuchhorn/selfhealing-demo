-- Single platform database
DEFINE DATABASE {{db_name}};

-- Medallion schemas
DEFINE SCHEMA {{db_name}}.BRONZE;
DEFINE SCHEMA {{db_name}}.SILVER;
DEFINE SCHEMA {{db_name}}.GOLD;

-- Warehouse
DEFINE WAREHOUSE {{name_prefix}}_WH{{db_suffix}}
    WAREHOUSE_SIZE = '{{wh_size}}'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Data platform warehouse ({{env}})';
