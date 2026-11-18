-- =====================================================================
--  SHORT TRACK · 3/4 · Dictionaries and a gold table for the dashboard
-- =====================================================================
--  Silver holds the detail. A dashboard should read a small table that is
--  already aggregated and enriched: gold.
-- =====================================================================


-- STEP 1 · Dictionaries: reference data in memory
--  A dictionary = a key → values table loaded into RAM. dictGet() replaces a join
--  with a direct lookup. SOURCE says where to read, LAYOUT how to store, LIFETIME when to reload.
CREATE OR REPLACE DICTIONARY ref.dict_card
(
    card_id UInt64, issuer_id String, city_code String, segment String, product String, daily_limit_eur UInt32, ecom_share Float32
)
PRIMARY KEY card_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'card' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED_ARRAY())
LIFETIME(MIN 3600 MAX 7200);

CREATE OR REPLACE DICTIONARY ref.dict_merchant
(
    merchant_id UInt64, name String, mcc UInt16, city_code String, country_code String
)
PRIMARY KEY merchant_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'merchant' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED())
LIFETIME(MIN 3600 MAX 7200);

CREATE OR REPLACE DICTIONARY ref.dict_mcc (mcc UInt64, label String, short_name String, category String)
PRIMARY KEY mcc
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'mcc' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_issuer (issuer_id String, name String, country_code String)
PRIMARY KEY issuer_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'issuer' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);


-- STEP 2 · One card's day, fully described, without a JOIN
SELECT
    toTimeZone(ts, 'Europe/Paris')                                                              AS local_time,
    channel, amount_eur,
    dictGet('ref.dict_merchant', 'name', toUInt64(merchant_id))                                 AS merchant,
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    dictGet('ref.dict_issuer', 'name', dictGet('ref.dict_card', 'issuer_id', card_id))          AS issuer
FROM silver.transaction FINAL
WHERE card_id = sim_card_id(648) AND day = '2026-10-03'
ORDER BY ts;

--  The whole week by merchant category: 1.9 million rows, 2 lookups per row
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id)))) AS category,
    round(sum(amount_eur) / 1e6, 2) AS million_eur,
    count() AS payments
FROM silver.transaction FINAL
GROUP BY category
ORDER BY million_eur DESC
LIMIT 10;


-- STEP 3 · Gold: a refreshable materialized view
--  It recomputes its query on a schedule and atomically replaces the result.
--  It reads silver FINAL, so resent files are never counted twice.
--  The table is sorted the way the dashboard filters it: by issuer first.
CREATE OR REPLACE TABLE gold.category_day_spend
(
    day        Date,
    issuer_id  LowCardinality(String),
    mcc        UInt16,
    channel    LowCardinality(String),
    spend_eur  Decimal(18, 2),
    n_txns     UInt32
)
ENGINE = MergeTree
ORDER BY (issuer_id, mcc, channel, day);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_category_day_spend
REFRESH EVERY 10 MINUTE
TO gold.category_day_spend
AS
SELECT
    day,
    dictGet('ref.dict_card', 'issuer_id', card_id)              AS issuer_id,
    dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id))  AS mcc,
    channel,
    sum(amount_eur)                                             AS spend_eur,
    count()                                                     AS n_txns
FROM silver.transaction FINAL
GROUP BY day, issuer_id, mcc, channel;

--  The first refresh starts right away; we wait for it, then look at its status.
SYSTEM WAIT VIEW gold.rmv_category_day_spend;

SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duration_s, written_rows, next_refresh_time
FROM system.view_refreshes
WHERE database = 'gold';


-- STEP 4 · What the dashboard reads
--  1.9 million transactions became a few thousand rows.
SELECT
    dictGet('ref.dict_issuer', 'name', toString(issuer_id))                 AS issuer,
    round(sum(spend_eur) / 1e6, 2)                                          AS million_eur,
    round(100 * sumIf(spend_eur, channel = 'ECOM') / sum(spend_eur), 1)     AS online_pct,
    sum(n_txns)                                                             AS payments
FROM gold.category_day_spend
GROUP BY issuer
ORDER BY million_eur DESC;

--  Spend per day for one bank, in store and online
SELECT day,
       round(sumIf(spend_eur, channel = 'POS') / 1000)  AS in_store_keur,
       round(sumIf(spend_eur, channel = 'ECOM') / 1000) AS online_keur,
       bar(toFloat64(sum(spend_eur)), 0, 9000000, 30)   AS chart
FROM gold.category_day_spend
WHERE issuer_id = '488903'
GROUP BY day
ORDER BY day;
-- What to look for: a few milliseconds, a few thousand rows read. October 4 is a Sunday:
-- spending is cut in half.


-- CHECKPOINT 3/4
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_card') = 1000000, 'OK', 'FAIL') AS dictionaries,
    if((SELECT count() FROM gold.category_day_spend) > 1000, 'OK', 'FAIL')              AS gold,
    if((SELECT uniqExact(issuer_id) FROM gold.category_day_spend) = 6, 'OK', 'FAIL')    AS issuers
SETTINGS select_sequential_consistency = 1;
