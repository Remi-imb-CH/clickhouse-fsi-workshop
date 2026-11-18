-- =====================================================================
--  SHORT TRACK · 3/5 · Dictionaries and a gold table for the dashboard
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


-- STEP 5 · A second gold table: the spend hour by hour, for the curves
CREATE OR REPLACE TABLE gold.issuer_curve
(
    issuer_id  LowCardinality(String),
    channel    LowCardinality(String),
    hour       DateTime('UTC'),
    spend_eur  Decimal(18, 2),
    n_txns     UInt32
)
ENGINE = MergeTree
ORDER BY (issuer_id, channel, hour);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_issuer_curve
REFRESH EVERY 10 MINUTE
TO gold.issuer_curve
AS
SELECT
    dictGet('ref.dict_card', 'issuer_id', card_id)  AS issuer_id,
    channel,
    toStartOfHour(ts)                               AS hour,
    sum(amount_eur)                                 AS spend_eur,
    count()                                         AS n_txns
FROM silver.transaction FINAL
GROUP BY issuer_id, channel, hour;

SYSTEM WAIT VIEW gold.rmv_issuer_curve;


-- STEP 6 · Document gold: the AI agent of part 5 reads these comments
--  An agent does not guess the business, it reads the schema. Without comments it would
--  not know that hour is in UTC or that 488903 is a bank. Only metadata changes: instant.
ALTER TABLE gold.category_day_spend
    MODIFY COMMENT 'Card spend per day, issuing bank, merchant category and channel, first week of October 2026. Amounts in EUR. Bank name: dictGet(''ref.dict_issuer'', ''name'', toString(issuer_id)). Category label: dictGet(''ref.dict_mcc'', ''label'', toUInt64(mcc)). Filter on issuer_id first (sorting key).';
ALTER TABLE gold.category_day_spend
    COMMENT COLUMN day       'Business day, local time (Europe/Paris)',
    COMMENT COLUMN issuer_id 'Issuing bank identifier (488903 = Lumière Banque, see ref.issuer)',
    COMMENT COLUMN mcc       'Merchant category code, ISO 18245 (5411 = grocery stores, 5812 = restaurants…)',
    COMMENT COLUMN channel   'POS = in store, ECOM = online',
    COMMENT COLUMN spend_eur 'Total amount of the payments, in EUR',
    COMMENT COLUMN n_txns    'Number of payments';

ALTER TABLE gold.issuer_curve
    MODIFY COMMENT 'Card spend per issuing bank, channel and hour. hour = START of the hour, in UTC: convert with toTimeZone(hour, ''Europe/Paris''). Filter on issuer_id first (sorting key).';
ALTER TABLE gold.issuer_curve
    COMMENT COLUMN issuer_id 'Issuing bank identifier (488903 = Lumière Banque). Name: dictGet(''ref.dict_issuer'', ''name'', toString(issuer_id))',
    COMMENT COLUMN channel   'POS = in store, ECOM = online',
    COMMENT COLUMN hour      'Start of the hour, UTC',
    COMMENT COLUMN spend_eur 'Total amount of the payments of the hour, in EUR',
    COMMENT COLUMN n_txns    'Number of payments of the hour';

SELECT name, comment FROM system.tables WHERE database = 'gold' AND comment != '' ORDER BY name;


-- CHECKPOINT 3/5
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_card') = 1000000, 'OK', 'FAIL') AS dictionaries,
    if((SELECT count() FROM gold.category_day_spend) > 1000, 'OK', 'FAIL')              AS gold,
    if((SELECT uniqExact(issuer_id) FROM gold.category_day_spend) = 6, 'OK', 'FAIL')    AS issuers,
    if((SELECT count() FROM gold.issuer_curve) > 1000, 'OK', 'FAIL')                    AS curve,
    if((SELECT count() FROM system.tables WHERE database = 'gold' AND comment != '') >= 2, 'OK', 'FAIL') AS documented
SETTINGS select_sequential_consistency = 1;
