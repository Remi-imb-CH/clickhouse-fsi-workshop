-- =====================================================================
--  SHORT TRACK · 4/5 · Analytics at scale: 186 million transactions
-- =====================================================================
--  125,000 cards × 1,488 payments (a full year) = 186,000,000 transactions,
--  generated and written by ONE statement, straight into silver.
--  Then we ask analytical questions of the whole table and note how long each one takes,
--  and we measure four ways to go faster: primary key, parallel replicas, projection, query cache.
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


-- =====================================================================
--  GOING FASTER · four levers, each one measured before and after
-- =====================================================================
--  Each pair below is tagged with log_comment. STEP 9 reads the query log and puts the
--  durations and the rows read side by side: your own measurements, on your own service.


-- STEP 5 · Lever 1: the primary key
--  BEFORE: the payments taken by one merchant (Royal Park Airline Paris). merchant_id is not
--  in the ORDER BY: every row has to be read.
SELECT count() AS payments, round(sum(amount_eur), 2) AS eur
FROM silver.transaction_xl
WHERE merchant_id = 1014120
SETTINGS log_comment = 'faster|1 primary key|before';

--  AFTER: the payments made by one card. The filter follows the start of the
--  ORDER BY (channel, card_id): ClickHouse jumps straight to the right granules.
SELECT count() AS payments, round(sum(amount_eur), 2) AS eur
FROM silver.transaction_xl
WHERE channel = 'POS' AND card_id = sim_card_id(648)
SETTINGS log_comment = 'faster|1 primary key|after';
-- What to look for: a few thousand rows read instead of 186 million.
-- The ORDER BY of a table is chosen for the filters used most often.

--  The statement itself, as the banking app would show it:
SELECT toTimeZone(ts, 'Europe/Paris') AS local_time, amount_eur,
       dictGet('ref.dict_merchant', 'name', toUInt64(merchant_id)) AS merchant
FROM silver.transaction_xl
WHERE channel = 'POS' AND card_id = sim_card_id(648)
ORDER BY ts DESC
LIMIT 20;


-- STEP 6 · Lever 2: parallel replicas
--  Spend by merchant category (question f), on the replica that receives the query …
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur
FROM silver.transaction_xl
GROUP BY category
ORDER BY billion_eur DESC
LIMIT 5
SETTINGS log_comment = 'faster|2 parallel replicas|before';

--  … then spread over all the replicas of the service, with one setting.
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur
FROM silver.transaction_xl
GROUP BY category
ORDER BY billion_eur DESC
LIMIT 5
SETTINGS enable_parallel_replicas = 1, log_comment = 'faster|2 parallel replicas|after';
-- What to look for: same result, same rows read, a shorter duration with 3 replicas:
-- storage is shared, so adding compute is enough. With a single replica, nothing changes.


-- STEP 7 · Lever 3: the projection
--  The busiest hours of the year. BEFORE: the projection is turned off to compare.
SELECT toStartOfHour(ts) AS hour_utc, round(sum(amount_eur) / 1e6, 2) AS million_eur, count() AS payments
FROM silver.transaction_xl
GROUP BY hour_utc
ORDER BY million_eur DESC
LIMIT 5
SETTINGS optimize_use_projections = 0, log_comment = 'faster|3 projection|before';

--  AFTER (the default): same SQL, ClickHouse picks the projection on its own.
SELECT toStartOfHour(ts) AS hour_utc, round(sum(amount_eur) / 1e6, 2) AS million_eur, count() AS payments
FROM silver.transaction_xl
GROUP BY hour_utc
ORDER BY million_eur DESC
LIMIT 5
SETTINGS log_comment = 'faster|3 projection|after';
-- What to look for: same result, tens of thousands of rows read instead of 186 million.


-- STEP 8 · Lever 4: the query cache
--  A dashboard tile asks the same question again and again. With use_query_cache, the result
--  is kept in memory for query_cache_ttl seconds and served again without reading anything.
--  We clear the cache first, so the first run really computes.
SYSTEM DROP QUERY CACHE;

--  Month by month (question b). First run: computed, then stored.
SELECT
    toStartOfMonth(ts)                                                      AS month,
    count()                                                                 AS payments,
    round(sum(amount_eur) / 1e6, 1)                                         AS million_eur,
    round(100 * sumIf(amount_eur, channel = 'ECOM') / sum(amount_eur), 1)   AS online_pct,
    uniqExact(card_id)                                                      AS active_cards
FROM silver.transaction_xl
GROUP BY month
ORDER BY month
SETTINGS use_query_cache = 1, query_cache_ttl = 300, log_comment = 'faster|4 query cache|';

--  Exactly the same query again: served from the cache.
SELECT
    toStartOfMonth(ts)                                                      AS month,
    count()                                                                 AS payments,
    round(sum(amount_eur) / 1e6, 1)                                         AS million_eur,
    round(100 * sumIf(amount_eur, channel = 'ECOM') / sum(amount_eur), 1)   AS online_pct,
    uniqExact(card_id)                                                      AS active_cards
FROM silver.transaction_xl
GROUP BY month
ORDER BY month
SETTINGS use_query_cache = 1, query_cache_ttl = 300, log_comment = 'faster|4 query cache|';
-- What to look for: the second run reads no rows.
-- The cache belongs to each replica: if the console sends you to another replica, the query
-- is computed there once. Run it a third time.
-- The cache is not cleared when the table changes, only the TTL counts: keep it for tiles
-- where a few minutes of delay are acceptable. The live part (5/5) uses another approach.


-- STEP 9 · The scoreboard: before and after, from the query log
--  ClickHouse logs every query with its duration and the rows it read.
--  The log is written every few seconds: if a line is missing, wait 10 seconds and run again.
SELECT
    lever,
    argMaxIf(query_duration_ms, event_time, phase = 'before')                         AS before_ms,
    argMaxIf(query_duration_ms, event_time, phase = 'after')                          AS after_ms,
    formatReadableQuantity(argMaxIf(read_rows, event_time, phase = 'before'))         AS rows_read_before,
    formatReadableQuantity(argMaxIf(read_rows, event_time, phase = 'after'))          AS rows_read_after,
    round(before_ms / greatest(after_ms, 1), 1)                                       AS times_faster
FROM
(
    SELECT
        splitByChar('|', log_comment)[2]                                               AS lever,
        multiIf(splitByChar('|', log_comment)[3] != '', splitByChar('|', log_comment)[3],
                query_cache_usage = 'Read', 'after', 'before')                         AS phase,
        event_time, query_duration_ms, read_rows
    FROM clusterAllReplicas('default', system.query_log)
    WHERE type = 'QueryFinish' AND is_initial_query
      AND log_comment LIKE 'faster|%'
      AND event_time > now() - INTERVAL 1 HOUR
)
GROUP BY lever
ORDER BY lever;
-- What to look for: lever 1 and 3 read far fewer rows; lever 2 reads the same rows with more
-- compute; lever 4 reads none. Durations below 1 ms are counted as 1 ms in times_faster.


-- CHECKPOINT 4/5
SELECT
    if((SELECT count() FROM silver.transaction_xl) = 186000000, 'OK', 'FAIL') AS xl_transactions
SETTINGS select_sequential_consistency = 1;
