-- =====================================================================
--  MODULE 6 · Reading fast: primary index, projection, skip index,
--             parallel replicas, cache
-- =====================================================================
--  For each query, note in the console: duration, rows read, GB read.
--  Then compare with RESULTS.md.
--
--  The five levers, from the most important to the most specific:
--    1. read fewer rows thanks to the ORDER BY (primary index)
--    2. spread a big scan over all replicas (parallel replicas)
--    3. pre-aggregate (projection)
--    4. skip blocks on a column outside the key (skip index)
--    5. do not recompute what was just computed (query cache)
-- =====================================================================


-- QUERY 1 · The statement of ONE card over the year (the mobile banking app case)
--  The filter follows the start of the ORDER BY (channel, card_id): ClickHouse jumps
--  straight to the right granules (rule schema-pk-filter-on-orderby).
SELECT toTimeZone(ts, 'Europe/Paris') AS local_time, amount_eur,
       dictGet('ref.dict_merchant', 'name', toUInt64(merchant_id)) AS merchant
FROM silver.transaction_xl
WHERE channel = 'POS' AND card_id = sim_card_id(123456)   -- the first 2 columns of the ORDER BY
ORDER BY ts DESC
LIMIT 50;
-- What to look for: a few thousand rows read out of 1.5 billion. The first call on a replica
-- reads from object storage (cold read), the next ones from the replica's local disk cache.

--  EXPLAIN indexes = 1 shows what the index eliminated, without running the query.
EXPLAIN indexes = 1
SELECT amount_eur FROM silver.transaction_xl WHERE channel = 'POS' AND card_id = sim_card_id(123456);
-- What to look for: under "PrimaryKey", the "Granules" line. One or two granules of 8,192 rows
-- read out of ~180,000: that is why the query is instant.


-- QUERY 2 · Per home country: 1.5 billion rows, 4.5 billion dictGet calls
--  No index can help here: we want ALL the rows. It is a full
--  scan, and its speed depends on the number of cores working on it.
SELECT
    dictGet('ref.dict_city', 'country_code', dictGet('ref.dict_card', 'city_code', card_id)) AS home_country,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur,
    round(100 * sumIf(amount_eur, dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant_id)) != home_country) / sum(amount_eur), 1) AS cross_border_pct
FROM silver.transaction_xl
GROUP BY home_country
ORDER BY billion_eur DESC
LIMIT 10;
-- What to look for: the countries with the most cards come first, and about one euro
-- in seven is spent abroad.


-- OPTIMIZATION A · Spread the scan over the 3 replicas (parallel replicas)
--  By default, a query runs on the replica that receives it. With
--  enable_parallel_replicas = 1, the table is split into chunks and each
--  replica processes a share. This is storage/compute separation:
--  all replicas read the same data from object storage, so you just add
--  compute to go faster.
SELECT
    dictGet('ref.dict_city', 'country_code', dictGet('ref.dict_card', 'city_code', card_id)) AS home_country,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur,
    round(100 * sumIf(amount_eur, dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant_id)) != home_country) / sum(amount_eur), 1) AS cross_border_pct
FROM silver.transaction_xl
GROUP BY home_country
ORDER BY billion_eur DESC
LIMIT 10
SETTINGS enable_parallel_replicas = 1;
-- What to look for: same result, same number of rows read, duration divided by
-- roughly the number of replicas, without changing a line of SQL. The gain is largest
-- on queries that compute a lot per row (here the dictGet calls).


-- OPTIMIZATION B · The aggregation PROJECTION (declared when the table was created)
--  The optimizer decides on its own to read the projection when it answers
--  the question: the query does not change. To measure the difference, we first
--  turn it off with optimize_use_projections = 0.
--  The busiest hours of the year, WITHOUT the projection:
SELECT toStartOfHour(ts) AS hour_utc, round(sum(amount_eur) / 1e6, 2) AS million_eur, count() AS payments
FROM silver.transaction_xl
GROUP BY hour_utc
ORDER BY million_eur DESC
LIMIT 5
SETTINGS optimize_use_projections = 0;

--  … and WITH it (the default setting):
SELECT toStartOfHour(ts) AS hour_utc, round(sum(amount_eur) / 1e6, 2) AS million_eur, count() AS payments
FROM silver.transaction_xl
GROUP BY hour_utc
ORDER BY million_eur DESC
LIMIT 5;
-- What to look for: same result, a few tens of thousands of rows read instead of 1.5 billion.
-- The projection already holds one row per hour (and per part).

--  Bonus: the spend of the whole portfolio day by day benefits from the same projection,
--  because the day is computed from the hour, which is in the projection.
SELECT toDate(toStartOfHour(ts), 'Europe/Paris') AS day, round(sum(amount_eur) / 1e6, 1) AS million_eur
FROM silver.transaction_xl
GROUP BY day
ORDER BY day DESC
LIMIT 14;
-- What to look for: the weekly rhythm (Saturday on top, Sunday at the bottom), read in milliseconds.

--  On a table that is already loaded, you would add the projection like this:
--    ALTER TABLE silver.transaction_xl ADD PROJECTION p_hourly_spend (SELECT toStartOfHour(ts), sum(amount_eur), count() GROUP BY toStartOfHour(ts));
--    ALTER TABLE silver.transaction_xl MATERIALIZE PROJECTION p_hourly_spend SETTINGS mutations_sync = 1;
--  MATERIALIZE rewrites every existing part: to be scheduled outside peak hours.


-- OPTIMIZATION C · The minmax SKIP INDEX on the amount
--  "Which payments exceed 2,500 EUR?": only the corporate cards with the highest
--  limits reach that level. They are ~0.2% of the portfolio, and the rows are sorted
--  by card, so most granules have a max below 2,500 EUR and can be skipped.
--  WITHOUT the index (use_skip_indexes = 0):
SELECT count() AS payments_over_2500, uniqExact(card_id) AS cards
FROM silver.transaction_xl
WHERE amount_eur > 2500
SETTINGS use_skip_indexes = 0;

--  WITH the index:
SELECT count() AS payments_over_2500, uniqExact(card_id) AS cards
FROM silver.transaction_xl
WHERE amount_eur > 2500;

EXPLAIN indexes = 1
SELECT count() FROM silver.transaction_xl WHERE amount_eur > 2500;
-- What to look for: under "Skip", the number of granules kept, a small fraction of the table.
-- A skip index only helps if the values you look for are grouped in few
-- granules. On a column where all values are mixed together, it skips nothing.
--  On a table that is already loaded: ALTER TABLE … ADD INDEX, then MATERIALIZE INDEX.
--  Watch out: MATERIALIZE INDEX on 1.5 B rows takes well over 60 s
--  (the console gives up). That is why we declare the index in the CREATE TABLE.


-- OPTIMIZATION D · The query cache (dashboards refreshed in a loop)
--  A query's result is kept in memory for query_cache_ttl seconds.
--  The same query, with the same text and the same settings, is served from
--  the cache without reading anything again.
--  Watch out: dictGet is deemed "non-deterministic" (the dictionary can be
--  reloaded): without query_cache_nondeterministic_function_handling, ClickHouse
--  refuses to cache (error 704). Here the reference data changes at most every
--  hour, so a 5-min TTL is safe.
--  We clear the cache first, so the demo starts from scratch even if you rerun
--  the file (the cache survives tables being recreated, see below).
SYSTEM DROP QUERY CACHE;

SELECT
    dictGet('ref.dict_city', 'country_code', dictGet('ref.dict_card', 'city_code', card_id)) AS home_country,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur,
    round(100 * sumIf(amount_eur, dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant_id)) != home_country) / sum(amount_eur), 1) AS cross_border_pct
FROM silver.transaction_xl
GROUP BY home_country
ORDER BY billion_eur DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';

--  … run exactly the same query again:
SELECT
    dictGet('ref.dict_city', 'country_code', dictGet('ref.dict_card', 'city_code', card_id)) AS home_country,
    round(sum(amount_eur) / 1e9, 2) AS billion_eur,
    round(100 * sumIf(amount_eur, dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant_id)) != home_country) / sum(amount_eur), 1) AS cross_border_pct
FROM silver.transaction_xl
GROUP BY home_country
ORDER BY billion_eur DESC
LIMIT 10
SETTINGS use_query_cache = 1, query_cache_ttl = 300,
         query_cache_nondeterministic_function_handling = 'save';
-- What to look for: the 2nd run answers in about a millisecond and reads no rows.
-- Watch out: the cache belongs to each replica. If the console sends you to
-- another replica, the 1st call recomputes there: run it once more.
-- Watch out: the cache is NOT cleared when the table changes, only the TTL counts.
-- Keep it for tiles where a few minutes of delay are acceptable.


-- GOING FURTHER · PREWHERE is automatic
--  ClickHouse first reads the column of the most selective filter (card_id), then
--  only the other columns of the rows it kept. EXPLAIN shows it.
EXPLAIN actions = 1
SELECT sum(amount_eur) FROM silver.transaction_xl WHERE card_id = sim_card_id(42) AND amount_eur > 100;
