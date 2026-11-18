-- =====================================================================
--  SHORT TRACK · 4/5 · Analytics at scale: 186 million transactions
-- =====================================================================
--  125,000 cards × 1,488 payments (a full year) = 186,000,000 transactions,
--  generated and written by ONE statement, straight into silver.
--  Then we ask analytical questions of the whole table and note how long each one takes.
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


-- STEP 4 · Six analytical questions, each on all 186 million rows
--  For each one, note the duration and the rows read at the bottom of the console.

--  a) The year in one row
SELECT
    count()                              AS payments,
    round(sum(amount_eur) / 1e9, 2)      AS billion_eur,
    round(avg(amount_eur), 2)            AS avg_payment_eur,
    uniqExact(card_id)                   AS cards,
    uniqExact(merchant_id)               AS merchants
FROM silver.transaction_xl;

--  b) Month by month, in store and online
SELECT
    toStartOfMonth(ts)                                                      AS month,
    count()                                                                 AS payments,
    round(sum(amount_eur) / 1e6, 1)                                         AS million_eur,
    round(100 * sumIf(amount_eur, channel = 'ECOM') / sum(amount_eur), 1)   AS online_pct,
    uniqExact(card_id)                                                      AS active_cards
FROM silver.transaction_xl
GROUP BY month
ORDER BY month;

--  c) The shape of a week: 7 days × 24 hours
SELECT
    toDayOfWeek(ts, 0, 'Europe/Paris')   AS weekday,      -- 1 = Monday
    toHour(ts, 'Europe/Paris')           AS hour,
    count()                              AS payments,
    round(sum(amount_eur) / 1e6, 2)      AS million_eur
FROM silver.transaction_xl
GROUP BY weekday, hour
ORDER BY million_eur DESC
LIMIT 10;

--  d) The 10 merchants with the highest turnover, out of 50,000
SELECT
    dictGet('ref.dict_merchant', 'name', toUInt64(merchant_id))   AS merchant,
    count()                                                       AS payments,
    uniqExact(card_id)                                            AS cards,
    round(sum(amount_eur) / 1e6, 2)                               AS million_eur
FROM silver.transaction_xl
GROUP BY merchant_id
ORDER BY million_eur DESC
LIMIT 10;

--  e) How amounts are distributed: median, 95th and 99th percentile
SELECT
    channel,
    arrayMap(x -> round(x, 2), quantiles(0.5, 0.95, 0.99)(toFloat64(amount_eur))) AS p50_p95_p99_eur,
    max(amount_eur)                                                               AS max_eur
FROM silver.transaction_xl
GROUP BY channel;

--  f) Spend by merchant category: 2 dictionary lookups per row
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur
FROM silver.transaction_xl
GROUP BY category
ORDER BY billion_eur DESC
LIMIT 5;
-- What to look for: every query reads the 186 million rows and still answers in about a second
-- or less on the recommended service. No index helps here: this is columnar storage and
-- vectorized execution on all the cores.


-- STEP 5 · One card's statement: the primary key
--  The filter follows the start of the ORDER BY (channel, card_id): ClickHouse jumps
--  straight to the right granules.
SELECT toTimeZone(ts, 'Europe/Paris') AS local_time, amount_eur,
       dictGet('ref.dict_merchant', 'name', toUInt64(merchant_id)) AS merchant
FROM silver.transaction_xl
WHERE channel = 'POS' AND card_id = sim_card_id(648)
ORDER BY ts DESC
LIMIT 20;
-- What to look for: a few thousand rows read out of 186 million, a few milliseconds.


-- STEP 6 · The same full scan, spread over all the replicas
--  Question f) again, with one setting.
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


-- STEP 7 · The projection: the busiest hours of the year
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


-- CHECKPOINT 4/5
SELECT
    if((SELECT count() FROM silver.transaction_xl) = 186000000, 'OK', 'FAIL') AS xl_transactions
SETTINGS select_sequential_consistency = 1;
