-- Author: Can Alhas
-- ClickHouse materialized views for fraud analytics dashboards.
--
-- NOT auto-created by the Rust engine (fraudbuster_be only creates the base
-- `events` / `model_features` tables on startup — see
-- src/persistence/clickhouse.rs::initialize_schema_static). These views are
-- optional: the UI's timeseries endpoint falls back to querying the raw
-- `events` table if `events_hourly_stats` is missing, so the dashboard still
-- works without this script — just slower on large (7d/30d) windows.
--
-- Run once, after clickhouse-init.sql (setup-clickhouse.sh does this
-- automatically). Safe to re-run: every view uses IF NOT EXISTS.

-- ============================================
-- 1. HOURLY EVENT STATISTICS
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS fraudbuster.events_hourly_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(hour_start)
ORDER BY (event_name, hour_start)
POPULATE
AS SELECT
    event_name,
    toStartOfHour(timestamp)     AS hour_start,
    toDate(timestamp)            AS date,
    count()                      AS event_count,
    countIf(success = 1)         AS success_count,
    countIf(rules_triggered_count > 0) AS fraud_count,
    sum(toFloat64(amount))       AS total_amount,
    sumIf(toFloat64(amount), rules_triggered_count > 0) AS fraud_amount,
    avg(total_processing_time_ms) AS avg_processing_time,
    avg(rule_execution_time_ms)  AS avg_rule_time,
    avg(bucket_execution_time_ms) AS avg_bucket_time,
    quantile(0.50)(total_processing_time_ms) AS p50_processing_time,
    quantile(0.95)(total_processing_time_ms) AS p95_processing_time,
    quantile(0.99)(total_processing_time_ms) AS p99_processing_time,
    uniq(actor_id)               AS unique_actors,
    uniq(merchant_id)            AS unique_merchants
FROM fraudbuster.events
GROUP BY event_name, hour_start, date;

-- ============================================
-- 2. ACTOR DAILY SUMMARY
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS fraudbuster.actor_daily_summary
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (actor_id, date)
POPULATE
AS SELECT
    actor_id,
    toDate(timestamp)            AS date,
    count()                      AS event_count,
    countIf(rules_triggered_count > 0) AS fraud_count,
    sum(toFloat64(amount))       AS total_amount,
    sumIf(toFloat64(amount), rules_triggered_count > 0) AS fraud_amount,
    avg(toFloat64(amount))       AS avg_transaction_amount,
    uniq(merchant_id)            AS unique_merchants,
    uniq(event_name)             AS unique_event_types,
    min(timestamp)               AS first_event_time,
    max(timestamp)               AS last_event_time
FROM fraudbuster.events
WHERE actor_id != ''
GROUP BY actor_id, date;

-- ============================================
-- 3. MERCHANT FRAUD STATISTICS (DAILY)
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS fraudbuster.merchant_fraud_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, merchant_id_str)
POPULATE
AS SELECT
    assumeNotNull(merchant_id)   AS merchant_id_str,
    toDate(timestamp)            AS date,
    count()                      AS total_transactions,
    countIf(rules_triggered_count > 0) AS fraud_transactions,
    countIf(success = 1)         AS successful_transactions,
    sum(toFloat64(amount))       AS total_amount,
    sumIf(toFloat64(amount), rules_triggered_count > 0) AS fraud_amount,
    uniq(actor_id)               AS unique_actors,
    avg(total_processing_time_ms) AS avg_processing_time
FROM fraudbuster.events
WHERE merchant_id IS NOT NULL
GROUP BY merchant_id_str, date;

-- ============================================
-- 4. RULE EFFECTIVENESS (DAILY)
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS fraudbuster.rule_effectiveness
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, event_name)
POPULATE
AS SELECT
    event_name,
    toDate(timestamp)            AS date,
    count()                      AS total_events,
    sum(rules_triggered_count)   AS total_rule_triggers,
    sum(rules_executed_count)    AS total_rules_executed,
    avg(rule_execution_time_ms)  AS avg_rule_execution_time,
    uniq(actor_id)               AS unique_actors_flagged
FROM fraudbuster.events
WHERE rules_triggered_count > 0
GROUP BY event_name, date;

-- ============================================
-- 5. EVENT PERFORMANCE (DAILY + HOUR)
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS fraudbuster.event_performance
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, hour, event_name)
POPULATE
AS SELECT
    event_name,
    toDate(timestamp)            AS date,
    toHour(timestamp)            AS hour,
    count()                      AS event_count,
    avg(total_processing_time_ms) AS avg_processing_time,
    quantile(0.95)(total_processing_time_ms) AS p95_processing_time,
    quantile(0.99)(total_processing_time_ms) AS p99_processing_time,
    avg(variables_computation_time_ms) AS avg_variable_time,
    avg(values_computation_time_ms)    AS avg_values_time,
    avg(rule_execution_time_ms)        AS avg_rule_time,
    avg(bucket_execution_time_ms)      AS avg_bucket_time,
    countIf(success = 0)               AS error_count
FROM fraudbuster.events
GROUP BY event_name, date, hour;

-- ============================================
-- 6. REAL-TIME FRAUD MONITORING (5-MIN WINDOWS)
-- ============================================
CREATE MATERIALIZED VIEW IF NOT EXISTS fraudbuster.fraud_realtime_5min
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(window_start)
ORDER BY (window_start, event_name)
TTL window_start + INTERVAL 7 DAY
POPULATE
AS SELECT
    event_name,
    toStartOfFiveMinutes(timestamp) AS window_start,
    count()                          AS event_count,
    countIf(rules_triggered_count > 0) AS fraud_count,
    sum(toFloat64(amount))           AS total_amount,
    uniq(actor_id)                   AS unique_actors
FROM fraudbuster.events
GROUP BY event_name, window_start;
