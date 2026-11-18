-- =====================================================================
--  SHORT TRACK · 4/4 · Scale: 186 million transactions, and how to read them fast
-- =====================================================================
--  125,000 cards × 1,488 payments (a full year) = 186,000,000 transactions,
--  generated and written by ONE statement, straight into silver.
--  The full workshop (module 06) goes up to 1.5 billion with the same code.
-- =====================================================================


-- STEP 1 · The table, with a PROJECTION declared up front
--  A projection is a pre-aggregated copy that ClickHouse keeps up to date on every INSERT
--  and picks on its own when it answers the question.
CREATE OR REPLACE TABLE silver.transaction_xl
(
    card_id      UInt64,
    channel      LowCardinality(String),
    ts           DateTime('UTC') CODEC(Delta, ZSTD(1)),
    amount_eur   Decimal(12, 2)  CODEC(ZSTD(1)),
    merchant_id  UInt32          CODEC(ZSTD(1)),
    PROJECTION p_hourly_spend (SELECT toStartOfHour(ts), sum(amount_eur), count() GROUP BY toStartOfHour(ts))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (channel, card_id, ts);   -- lowest to highest cardinality: 2 values, then the card, then time


-- STEP 2 · The generator, a parameterized view
--  numbers_mt produces blocks of numbers on all the cores at once; each number becomes a transaction.
CREATE OR REPLACE VIEW simulator.xl_txns AS
WITH
    sim_card_id(intDiv(number, 1488))                                                             AS id,
    toDate('2025-11-01') + intDiv((number % 1488) * 365, 1488)                                    AS d,
    cityHash64(id, number % 1488, 'xl')                                                           AS seed,
    dictGet('simulator.dict_card', ('segment', 'daily_limit_eur', 'ecom_share', 'first_merchant', 'n_merchants'), id) AS a,
    sim_is_ecom(seed, a.3)                                                                        AS is_ecom
SELECT
    id                                                      AS card_id,
    if(is_ecom, 'ECOM', 'POS')                              AS channel,
    sim_txn_ts(seed, a.1, is_ecom, d)                       AS ts,
    toDecimal64(toUInt64(sim_amount(seed, a.1, a.2) * [1., 1., 1., 1., 1.1, 1.3, 0.7][toDayOfWeek(d)]), 2) / 100 AS amount_eur,
    sim_merchant(seed, is_ecom, a.4, a.5)                   AS merchant_id
FROM numbers_mt({start:UInt64} * 1488, {n:UInt64} * 1488);


-- STEP 3 · 186 million transactions in one INSERT
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 0, n = 125000) SETTINGS max_insert_threads = 8;
-- What to look for: the duration and the rows per second at the bottom of the console.
-- Every transaction is computed, sorted, compressed, then written to object storage.
-- On a small service, if the console gives up after 60 s, the INSERT still finishes on the server:
-- wait a little and run the next query.

SELECT
    formatReadableQuantity(sum(rows))                                AS transactions,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_compressed_bytes) / sum(rows), 1)                 AS bytes_per_transaction
FROM system.parts
WHERE database = 'silver' AND table = 'transaction_xl' AND active
SETTINGS select_sequential_consistency = 1;


-- STEP 4 · Lever 1: the primary key. One card's statement over a year
--  The filter follows the start of the ORDER BY (channel, card_id): ClickHouse jumps
--  straight to the right granules.
SELECT toTimeZone(ts, 'Europe/Paris') AS local_time, amount_eur,
       dictGet('ref.dict_merchant', 'name', toUInt64(merchant_id)) AS merchant
FROM silver.transaction_xl
WHERE channel = 'POS' AND card_id = sim_card_id(648)
ORDER BY ts DESC
LIMIT 20;
-- What to look for: a few thousand rows read out of 186 million.

EXPLAIN indexes = 1
SELECT amount_eur FROM silver.transaction_xl WHERE channel = 'POS' AND card_id = sim_card_id(648);


-- STEP 5 · A full scan: no index can help, every row is needed
--  186 million rows, 2 dictionary lookups per row. Its speed depends on the cores at work.
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur
FROM silver.transaction_xl
GROUP BY category
ORDER BY billion_eur DESC
LIMIT 5;

--  Lever 2: spread the same scan over all the replicas of the service
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur
FROM silver.transaction_xl
GROUP BY category
ORDER BY billion_eur DESC
LIMIT 5
SETTINGS enable_parallel_replicas = 1;
-- What to look for: same result, same rows read, a shorter duration with 3 replicas:
-- storage is shared, so adding compute is enough.


-- STEP 6 · Lever 3: the projection. The busiest hours of the year
--  WITHOUT the projection (we turn it off to compare):
SELECT toStartOfHour(ts) AS hour_utc, round(sum(amount_eur) / 1e6, 2) AS million_eur, count() AS payments
FROM silver.transaction_xl
GROUP BY hour_utc
ORDER BY million_eur DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;

--  WITH it (the default): same SQL
SELECT toStartOfHour(ts) AS hour_utc, round(sum(amount_eur) / 1e6, 2) AS million_eur, count() AS payments
FROM silver.transaction_xl
GROUP BY hour_utc
ORDER BY million_eur DESC
LIMIT 5;
-- What to look for: same result, tens of thousands of rows read instead of 186 million.


-- CHECKPOINT 4/4
SELECT
    if((SELECT count() FROM silver.transaction_xl) = 186000000, 'OK', 'FAIL') AS xl_transactions
SETTINGS select_sequential_consistency = 1;
