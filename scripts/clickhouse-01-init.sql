-- Author: Can Alhas
-- ClickHouse initialization script
-- This runs automatically when the container starts

CREATE DATABASE IF NOT EXISTS fraudbuster;

CREATE TABLE IF NOT EXISTS fraudbuster.events
(
    -- Core Event Identity
    event_id String,
    event_name LowCardinality(String),
    timestamp DateTime64(3, 'UTC'),
    date Date MATERIALIZED toDate(timestamp),
    
    -- Event Data (Three Types)
    event_parameters String CODEC(ZSTD(3)),
    event_variables String CODEC(ZSTD(3)),
    event_values String CODEC(ZSTD(3)),
    
    -- Processing Lifecycle Metrics
    event_found UInt8,
    event_lookup_time_ms UInt32,
    variables_computed_count UInt16,
    variables_computation_time_ms UInt32,
    values_computed_count UInt16,
    values_computation_time_ms UInt32,
    rules_found_count UInt16,
    rules_executed_count UInt16,
    rules_triggered_count UInt16,
    rule_execution_time_ms UInt32,
    buckets_found_count UInt16,
    buckets_executed_count UInt16,
    bucket_execution_time_ms UInt32,
    total_processing_time_ms UInt32,
    success UInt8,
    
    -- Execution Results
    rules_triggered String CODEC(ZSTD(3)),
    buckets_updated String CODEC(ZSTD(3)),
    computed_variables String CODEC(ZSTD(3)),
    computed_values String CODEC(ZSTD(3)),
    
    error Nullable(String),
    project_id Nullable(String),
    graph_fraud_score Nullable(UInt8),
    graph_signal_breakdown Nullable(String) CODEC(ZSTD(3)),
    
    actor_id String,
    
    amount Nullable(Decimal64(2)) MATERIALIZED 
        JSONExtractFloat(event_parameters, 'amount'),
    
    currency LowCardinality(Nullable(String)) MATERIALIZED 
        JSONExtractString(event_parameters, 'currency'),
    
    merchant_id Nullable(String) MATERIALIZED coalesce(
        JSONExtractString(event_parameters, 'merchantId'),
        JSONExtractString(event_parameters, 'merchant_id'),
        NULL
    ),
    
    hour UInt8 MATERIALIZED toHour(timestamp),
    day_of_week UInt8 MATERIALIZED toDayOfWeek(timestamp),
    
    -- Indexes
    INDEX idx_event_name event_name TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_actor_id actor_id TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_error error TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_name, date, timestamp)
TTL timestamp + INTERVAL 365 DAY
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS fraudbuster.model_features
(
    event_id String,
    event_name LowCardinality(String),
    actor_id String,
    event_timestamp DateTime64(3, 'UTC'),
    date Date MATERIALIZED toDate(event_timestamp),
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3),
    txn_amount_raw Nullable(String),
    txn_amount_normalized Nullable(String),
    currency_conversion_flag Nullable(String),
    txn_timestamp Nullable(String),
    txn_hour_of_day Nullable(String),
    txn_day_of_week Nullable(String),
    is_weekend Nullable(String),
    time_since_last_txn Nullable(String),
    geo_distance Nullable(String),
    country_code Nullable(String),
    is_international Nullable(String),
    merchant_category_code Nullable(String),
    merchant_id Nullable(String),
    is_online Nullable(String),
    device_type Nullable(String),
    ip_country Nullable(String),
    ip_location_mismatch Nullable(String),
    user_agent Nullable(String),
    cvv_match Nullable(String),
    three_ds_auth_result Nullable(String),
    txn_type Nullable(String),
    cust_txn_count_1h Nullable(String),
    cust_txn_count_24h Nullable(String),
    cust_txn_count_7d Nullable(String),
    cust_txn_count_30d Nullable(String),
    cust_txn_sum_1h Nullable(String),
    cust_txn_sum_24h Nullable(String),
    cust_txn_sum_7d Nullable(String),
    cust_txn_sum_30d Nullable(String),
    cust_txn_avg_7d Nullable(String),
    cust_txn_avg_30d Nullable(String),
    cust_txn_max_24h Nullable(String),
    cust_txn_max_7d Nullable(String),
    cust_unique_merchants_24h Nullable(String),
    cust_unique_merchants_7d Nullable(String),
    cust_declines_24h Nullable(String),
    cust_declines_7d Nullable(String),
    cust_velocity_ratio Nullable(String),
    cust_location_entropy Nullable(String),
    card_txn_count_1h Nullable(String),
    card_txn_count_24h Nullable(String),
    card_txn_count_7d Nullable(String),
    card_txn_sum_24h Nullable(String),
    card_txn_avg_30d Nullable(String),
    card_age_days Nullable(String),
    card_unique_devices_30d Nullable(String),
    card_fraud_history Nullable(String),
    INDEX idx_features_event_name event_name TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_features_actor_id actor_id TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_timestamp)
ORDER BY (event_name, actor_id, event_timestamp)
TTL event_timestamp + INTERVAL 365 DAY
SETTINGS index_granularity = 8192;

-- Migrations for existing deployments
ALTER TABLE fraudbuster.events ADD COLUMN IF NOT EXISTS graph_fraud_score Nullable(UInt8);
ALTER TABLE fraudbuster.events ADD COLUMN IF NOT EXISTS graph_signal_breakdown Nullable(String) CODEC(ZSTD(3));

-- Metrics-only actor×bucket projection for Bucket Reporting (UI-triggered sync)
CREATE TABLE IF NOT EXISTS fraudbuster.bucket_actor_state
(
    project_id String,
    bucket_id String,
    bucket_name LowCardinality(String),
    bucket_type LowCardinality(String),
    actor_id String,
    num_value Nullable(Float64),
    str_value Nullable(String),
    bool_value Nullable(UInt8),
    str_length Nullable(UInt64),
    item_count Nullable(UInt64),
    key_count Nullable(UInt64),
    total_count Nullable(UInt64),
    sum_value Nullable(Float64),
    avg_value Nullable(Float64),
    min_value Nullable(Float64),
    max_value Nullable(Float64),
    stddev_value Nullable(Float64),
    bin_count Nullable(UInt64),
    group_keys Array(String),
    updated_at DateTime64(3, 'UTC'),
    version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (project_id, bucket_id, actor_id)
TTL updated_at + INTERVAL 365 DAY
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS fraudbuster.bucket_state_watermark
(
    name String,
    last_ts Int64,
    updated_at DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY name;






















