-- =====================================================================
--  SHORT TRACK · 5/5 · Live data: payments arriving every 10 seconds
-- =====================================================================
--  Run this file AS IS (Cmd + Enter, the whole tab), then come back to the queries of step 4.
--
--  A feed inserts about 3,000 payments every 10 seconds, timestamped "now".
--  An incremental materialized view keeps a per-minute summary (an AggregatingMergeTree)
--  up to date on every insert.
--  The dashboard (the app your agent builds in part 6) reads that summary.
--
--     feed (every 10 s) ──► silver.transaction_live ──MV──► gold.live_minute ──► app
--
--  IMPORTANT: the feed keeps the service awake. Stop it at the end (last statement of this file).
-- =====================================================================


-- STEP 1 · The live table: one row per payment, already enriched
--  The bank, the category and the merchant country are looked up once, at insert time.
CREATE TABLE IF NOT EXISTS silver.transaction_live
(
    ts                DateTime('UTC') CODEC(Delta, ZSTD(1)),
    card_id           UInt64,
    issuer_id         LowCardinality(String),
    channel           LowCardinality(String),
    mcc               UInt16,
    merchant_country  LowCardinality(String),
    amount_eur        Decimal(12, 2)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (issuer_id, ts)
TTL ts + INTERVAL 7 DAY;          -- live data older than a week is purged


-- STEP 2 · The summary the dashboard reads, kept up to date on every INSERT
--  AggregatingMergeTree stores aggregation STATES, not final values:
--    · a sum merges by adding (SimpleAggregateFunction is enough);
--    · a number of distinct cards or a percentile cannot be added up: the table keeps
--      an intermediate state (AggregateFunction) that merges correctly.
--  The view writes states with the -State suffix, queries read them with -Merge.
--  A sum in an incremental view is right here because the feed never sends a payment twice.
CREATE TABLE IF NOT EXISTS gold.live_minute
(
    minute     DateTime('UTC'),
    issuer_id  LowCardinality(String),
    channel    LowCardinality(String),
    mcc        UInt16,
    spend_eur  SimpleAggregateFunction(sum, Decimal(38, 2)),
    n_txns     SimpleAggregateFunction(sum, UInt64),
    cards      AggregateFunction(uniq, UInt64),                 -- distinct cards: read with uniqMerge(cards)
    p95_eur    AggregateFunction(quantile(0.95), Float64)       -- 95th percentile: read with quantileMerge(0.95)(p95_eur)
)
ENGINE = AggregatingMergeTree
ORDER BY (issuer_id, minute, channel, mcc)
TTL minute + INTERVAL 7 DAY;

CREATE MATERIALIZED VIEW IF NOT EXISTS gold.mv_live_minute TO gold.live_minute AS
SELECT
    toStartOfMinute(ts)                           AS minute,
    issuer_id,
    channel,
    mcc,
    sum(amount_eur)                               AS spend_eur,
    count()                                       AS n_txns,
    uniqState(card_id)                            AS cards,
    quantileState(0.95)(toFloat64(amount_eur))    AS p95_eur
FROM silver.transaction_live
GROUP BY minute, issuer_id, channel, mcc;

ALTER TABLE gold.live_minute
    MODIFY COMMENT 'LIVE card spend per minute, issuing bank, channel and merchant category. New payments arrive every 10 seconds. minute = START of the minute, in UTC. This is an AggregatingMergeTree: ALWAYS aggregate with GROUP BY, using sum(spend_eur), sum(n_txns), uniqMerge(cards) and quantileMerge(0.95)(p95_eur). Filter on issuer_id and on minute >= now() - INTERVAL … to read the recent past.';
ALTER TABLE gold.live_minute
    COMMENT COLUMN minute    'Start of the minute, UTC. Compare with now()',
    COMMENT COLUMN issuer_id 'Issuing bank identifier (488903 = Lumière Banque). Name: dictGet(''ref.dict_issuer'', ''name'', toString(issuer_id))',
    COMMENT COLUMN channel   'POS = in store, ECOM = online',
    COMMENT COLUMN mcc       'Merchant category code. Label: dictGet(''ref.dict_mcc'', ''label'', toUInt64(mcc))',
    COMMENT COLUMN spend_eur 'Amount of the payments, in EUR. Read with sum(spend_eur)',
    COMMENT COLUMN n_txns    'Number of payments. Read with sum(n_txns)',
    COMMENT COLUMN cards     'Aggregation state: distinct cards that paid. Read with uniqMerge(cards). Never select it without -Merge',
    COMMENT COLUMN p95_eur   'Aggregation state: 95th percentile of the payment amount, in EUR. Read with quantileMerge(0.95)(p95_eur)';


-- STEP 3 · The feed: a refreshable materialized view in APPEND mode
--  Every 10 seconds it runs its query and APPENDS the result to the live table.
--  It plays the role of a stream (Kafka, ClickPipes) for the workshop: about 3,000 payments
--  per run, made by the cards of the six banks, with the simulator's amounts and merchants.
CREATE MATERIALIZED VIEW IF NOT EXISTS simulator.live_feed
REFRESH EVERY 10 SECOND APPEND
TO silver.transaction_live
AS
WITH
    cityHash64(now(), number)                                                    AS seed,
    sim_card_id(seed % 100000)                                                   AS id,
    dictGet('simulator.dict_card', ('segment', 'daily_limit_eur', 'ecom_share', 'first_merchant', 'n_merchants'), id) AS a,
    sim_is_ecom(seed, a.3)                                                       AS is_ecom,
    sim_merchant(seed, is_ecom, a.4, a.5)                                        AS merchant
SELECT
    now() - toIntervalSecond(number % 10)                                        AS ts,
    id                                                                           AS card_id,
    dictGet('ref.dict_card', 'issuer_id', id)                                    AS issuer_id,
    if(is_ecom, 'ECOM', 'POS')                                                   AS channel,
    dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant))                      AS mcc,
    dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant))             AS merchant_country,
    toDecimal64(sim_amount(seed, a.1, a.2), 2) / 100                             AS amount_eur
FROM numbers(2500 + cityHash64(now()) % 1000);

--  The first run starts as soon as the view is created: we wait for it to finish.
SYSTEM WAIT VIEW simulator.live_feed;


-- STEP 4 · Watch it live: run each of these queries several times
--  a) Is it flowing?
SELECT count() AS payments, min(ts) AS first_payment, max(ts) AS last_payment, toTimeZone(now(), 'UTC') AS now_utc
FROM silver.transaction_live;

--  b) The last 10 minutes, minute by minute (this is what a live chart reads)
SELECT
    toTimeZone(minute, 'Europe/Paris')                           AS local_minute,
    sum(n_txns)                                                  AS payments,
    round(sum(spend_eur))                                        AS eur,
    uniqMerge(cards)                                             AS distinct_cards,
    round(quantileMerge(0.95)(p95_eur), 2)                       AS p95_eur_amount,
    bar(toFloat64(eur), 0, 1500000, 25)                          AS chart
FROM gold.live_minute
WHERE minute >= now() - INTERVAL 10 MINUTE
GROUP BY local_minute
ORDER BY local_minute;

--  c) The last 5 minutes by bank
SELECT
    dictGet('ref.dict_issuer', 'name', toString(issuer_id))                 AS bank,
    sum(n_txns)                                                             AS payments,
    round(sum(spend_eur))                                                   AS eur,
    uniqMerge(cards)                                                        AS distinct_cards,
    round(100 * sumIf(spend_eur, channel = 'ECOM') / sum(spend_eur), 1)     AS online_pct
FROM gold.live_minute
WHERE minute >= now() - INTERVAL 5 MINUTE
GROUP BY bank
ORDER BY eur DESC;
-- What to look for: run b) and c) again every few seconds: the figures move, and each query
-- reads a few hundred rows in a few milliseconds, however many payments have arrived.
-- distinct_cards is exact across minutes and categories: the states were merged, not added.

--  d) The same distinct cards and percentile, computed from the detail: compare result and duration
SELECT
    count()                                               AS payments,
    uniq(card_id)                                         AS distinct_cards,
    round(quantile(0.95)(toFloat64(amount_eur)), 2)       AS p95_eur_amount
FROM silver.transaction_live
WHERE ts >= toStartOfMinute(now() - INTERVAL 5 MINUTE);

SELECT
    sum(n_txns)                                           AS payments,
    uniqMerge(cards)                                      AS distinct_cards,
    round(quantileMerge(0.95)(p95_eur), 2)                AS p95_eur_amount
FROM gold.live_minute
WHERE minute >= toStartOfMinute(now() - INTERVAL 5 MINUTE);
-- What to look for: the same payments and distinct cards, a percentile within a few cents
-- (percentiles are estimates), from far fewer rows. The gap in rows read grows with the volume.


-- CHECKPOINT 5/5
SELECT
    if((SELECT count() FROM silver.transaction_live) > 0, 'OK', 'FAIL')                                      AS live_table,
    if((SELECT sum(n_txns) FROM gold.live_minute) > 0, 'OK', 'FAIL')                                           AS summary,
    if((SELECT count() FROM system.view_refreshes WHERE view = 'live_feed') = 1, 'OK', 'FAIL')               AS feed
SETTINGS select_sequential_consistency = 1;


-- AT THE END OF THE SESSION · Stop the feed (do NOT run it now: select it and run it when you are done)
--  SYSTEM STOP VIEW simulator.live_feed;
--  To start it again: SYSTEM START VIEW simulator.live_feed;
