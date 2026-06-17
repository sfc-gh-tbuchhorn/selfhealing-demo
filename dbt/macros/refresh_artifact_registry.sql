{% macro refresh_artifact_registry() %}
  {% if execute and var('db_name') == 'SELFHEALING_PROD' %}

    {# ── Collect all rows in Jinja first ───────────────────────────────────
       Building the full dataset before touching the table means:
       - If graph traversal fails, nothing is deleted
       - DELETE + INSERT execute as a single atomic SQL block
       - No partial state possible
    #}
    {% set rows = [] %}

    {% for node_id, node in graph.nodes.items() %}
      {% if node.resource_type == 'model' %}

        {% set model_fqn = node.database ~ '.'
                         ~ node.config.schema | upper ~ '.'
                         ~ node.name | upper %}

        {% for dep in node.depends_on.nodes %}

          {# source.selfhealing.bronze.order_items → BRONZE.ORDER_ITEMS #}
          {% if dep.startswith('source.') %}
            {% set parts        = dep.split('.') %}
            {% set source_table = parts[2] | upper ~ '.' ~ parts[3] | upper %}
            {% do rows.append({
                'artifact_name': node.config.schema | lower ~ '.' ~ node.name,
                'source_table':  source_table,
                'file_path':     node.original_file_path,
                'snowflake_fqn': model_fqn,
                'raw_code':      node.raw_code | replace("'", "''")
            }) %}

          {# model.selfhealing.order_items → SILVER.ORDER_ITEMS #}
          {% elif dep.startswith('model.') %}
            {% set dep_node = graph.nodes.get(dep) %}
            {% if dep_node %}
              {% set source_table = dep_node.config.schema | upper
                                  ~ '.' ~ dep_node.name | upper %}
              {% do rows.append({
                  'artifact_name': node.config.schema | lower ~ '.' ~ node.name,
                  'source_table':  source_table,
                  'file_path':     node.original_file_path,
                  'snowflake_fqn': model_fqn,
                  'raw_code':      node.raw_code | replace("'", "''")
              }) %}
            {% endif %}

          {% endif %}
        {% endfor %}
      {% endif %}
    {% endfor %}

    {# ── Guard: only touch the table if we have rows to write ─────────────
       If graph traversal somehow produced nothing, leave the existing
       registry intact rather than wiping it.
    #}
    {% if rows | length == 0 %}
      {{ log("refresh_artifact_registry: no rows collected — skipping update", info=True) }}

    {% else %}

      {# Single DELETE + single multi-row INSERT — atomic, no partial state #}
      BEGIN;

        DELETE FROM SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
        WHERE artifact_type = 'dbt_model';

        INSERT INTO SELFHEALING_PROD.CONFIG.ARTIFACT_REGISTRY
          (artifact_name, artifact_type, source_table, artifact_sql, file_path, snowflake_fqn)
        {% for row in rows %}
          SELECT
            '{{ row.artifact_name }}',
            'dbt_model',
            '{{ row.source_table }}',
            '{{ row.raw_code }}',
            '{{ row.file_path }}',
            '{{ row.snowflake_fqn }}'
          {% if not loop.last %} UNION ALL {% endif %}
        {% endfor %};

      COMMIT;

      {{ log("refresh_artifact_registry: wrote " ~ rows | length ~ " rows", info=True) }}

    {% endif %}

  {% endif %}
{% endmacro %}
