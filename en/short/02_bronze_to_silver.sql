-- =====================================================================
--  SHORT TRACK · 2/5 · From raw JSON files to typed transactions
-- =====================================================================
--  bronze (1 row = 1 JSON file)  ──materialized view──►  silver (1 row = 1 transaction)
--  A materialized view is an INSERT TRIGGER: every block inserted into bronze
--  is transformed and written to silver, on the fly.
-- =====================================================================


-- STEP 1 · Bronze: the raw files, as they arrive
CREATE OR REPLACE TABLE bronze.raw_flows
(
    file_name    String,
    flow_code    LowCardinality(String),        -- CLEARING / SETTLEMENT / AUTH
    ingested_at  DateTime64(3, 'UTC'),          -- arrival time of the file
    payload      String CODEC(ZSTD(3))          -- the raw JSON, compressed harder than the default
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ingested_at)              -- one partition per month: for the lifecycle, not for speed
ORDER BY (flow_code, ingested_at, file_name);


-- STEP 2 · Silver: one row per transaction
--  ReplacingMergeTree: for the same key, the row with the most recent version wins.
--  ORDER BY from lowest to highest cardinality: 2 channels, then the card, then time.
CREATE OR REPLACE TABLE silver.transaction
(
    card_id      UInt64,
    channel      LowCardinality(String),                        -- POS (in store) / ECOM (online)
    ts           DateTime('UTC')      CODEC(Delta, ZSTD(1)),    -- instant of the payment, stored in UTC
    txn_ref      UInt64,                                        -- the scheme's reference of the transaction
    amount_eur   Decimal(12, 2),                                -- Decimal: money is never a float
    merchant_id  UInt32,
    stage        LowCardinality(String),                        -- CLEARED / ADJUSTED
    version      DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),    -- file arrival: the most recent wins
    day          Date MATERIALIZED toDate(ts, 'Europe/Paris')   -- computed at insert: the business day
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(ts)
ORDER BY (channel, card_id, ts, txn_ref)
SETTINGS min_bytes_for_wide_part = 0;        -- one column = one file: we can read the compression per column


-- STEP 3 · The materialized view: bronze → silver
--  3 chained ARRAY JOINs unfold the JSON: file → cards → channels → transactions.
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_clearing TO silver.transaction AS
SELECT
    toUInt64(r.cardId)                        AS card_id,
    c.channel                                 AS channel,
    parseDateTimeBestEffort(t.ts, 'UTC')      AS ts,                -- "+02:00" in the file → UTC
    toUInt64(t.ref)                           AS txn_ref,
    toDecimal64(t.amount, 2)                  AS amount_eur,
    toUInt32(t.merchantId)                    AS merchant_id,
    r.stage                                   AS stage,
    ingested_at                               AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records',
    'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, txns Array(Tuple(ts String, amount String, merchantId String, ref String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.txns     AS t
WHERE flow_code = 'CLEARING'
  AND toDecimal64OrNull(t.amount, 2) IS NOT NULL;   -- an unreadable amount is skipped instead of failing the load


-- STEP 4 · One week of files arrives: 140 files, 100,000 cards × 7 days
--  simulator.clearing_files is a parameterized view: a saved query called like a function.
--  We insert ONLY into bronze.
INSERT INTO bronze.raw_flows
SELECT * FROM simulator.clearing_files(start = 0, n = 140);

--  One file, as received
SELECT file_name, ingested_at, substring(payload, 1, 500) AS json_start
FROM bronze.raw_flows
LIMIT 1;

--  … and silver filled up on its own
SELECT
    (SELECT count() FROM bronze.raw_flows)                                   AS files,
    (SELECT formatReadableSize(sum(length(payload))) FROM bronze.raw_flows)  AS json_received,
    (SELECT count() FROM silver.transaction)                                 AS transactions;
-- What to look for: 140 files, about 300 MiB of JSON, about 1.9 million transactions,
-- without any step between the two tables.

SELECT toTimeZone(ts, 'Europe/Paris') AS local_time, channel, amount_eur, merchant_id, stage
FROM silver.transaction
WHERE card_id = sim_card_id(648) AND day = '2026-10-03'
ORDER BY ts;


-- STEP 5 · What typed columns do to the size
SELECT
    table,
    formatReadableQuantity(sum(rows))                                AS row_count,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_compressed_bytes) / sum(rows), 1)                 AS bytes_per_row
FROM system.parts
WHERE database IN ('bronze', 'silver') AND active
GROUP BY table;
-- What to look for: megabytes per file in bronze, about 20 bytes per transaction in silver.

SELECT name, type, formatReadableSize(data_compressed_bytes) AS on_disk,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'silver' AND table = 'transaction'
ORDER BY data_compressed_bytes DESC;
-- What to look for: channel, stage and card_id (sorted, repeated) cost almost nothing;
-- the reference and the amount, random by nature, weigh the most.


-- STEP 6 · Real life: the scheme sends a file twice
INSERT INTO bronze.raw_flows
SELECT replaceOne(file_name, '_488903_', '_488903_RESEND_'), flow_code, ingested_at + INTERVAL 3 DAY, payload
FROM bronze.raw_flows
WHERE file_name LIKE 'SCHEME_CLEARING_DETAIL_100040_%';   -- batch 0 of October 3

--  On disk, the transactions are there twice…
SELECT count() AS rows_on_disk, uniqExact(txn_ref) AS distinct_transactions
FROM silver.transaction
WHERE card_id = sim_card_id(648) AND day = '2026-10-03';

--  … FINAL deduplicates at read time. The background merges will clean up later.
SELECT count() AS rows_with_final
FROM silver.transaction FINAL
WHERE card_id = sim_card_id(648) AND day = '2026-10-03';
-- What to look for: 10 rows on disk, 5 with FINAL. No UPDATE, no DELETE: in ClickHouse,
-- you correct data by inserting a newer version.


-- CHECKPOINT 2/5
SELECT
    if((SELECT count() FROM bronze.raw_flows) = 141, 'OK', 'FAIL')                 AS files,
    if((SELECT count() FROM silver.transaction FINAL) > 1800000, 'OK', 'FAIL')     AS transactions,
    if((SELECT count() FROM silver.transaction FINAL WHERE card_id = sim_card_id(648) AND day = '2026-10-03') = 5, 'OK', 'FAIL') AS deduplicated
SETTINGS select_sequential_consistency = 1;
