-- =====================================================================
--  MODULE 5 · Gold (2/4): consolidated KPIs, refreshed on a schedule
-- =====================================================================
--  A REFRESHABLE materialized view recomputes its query on a schedule
--  and atomically replaces the result. It reads silver FINAL, so
--  duplicates and adjustments are always taken into account.
--
--     silver FINAL ──(every 10 min)──► gold.category_day_spend
--                                              │ DEPENDS ON
--                                              ▼
--                                    gold.issuer_day_summary
--
--  Incremental or refreshable MV?
--    · incremental: real time, but only sees the INSERTs (the sum trap)
--    · refreshable: recomputes everything, correct with FINAL and joins,
--      at the cost of a small delay (rule query-mv-refreshable).
-- =====================================================================


-- STEP 1 · Spend by issuer, merchant category and merchant country, by day
--  The target table is sorted the way the dashboard filters it: by issuer, then category.
CREATE OR REPLACE TABLE gold.category_day_spend
(
    day               Date,
    issuer_id         LowCardinality(String),
    mcc               UInt16,
    merchant_country  LowCardinality(String),
    segment           LowCardinality(String),
    channel           LowCardinality(String),
    spend_eur         Decimal(18, 2),
    n_txns            UInt32,
    n_cards           UInt32,
    max_amount_eur    Decimal(12, 2)
)
ENGINE = MergeTree
ORDER BY (issuer_id, mcc, channel, day);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_category_day_spend
REFRESH EVERY 10 MINUTE
TO gold.category_day_spend
AS
SELECT
    day,
    dictGet('ref.dict_card', 'issuer_id', card_id)                            AS issuer_id,
    dictGet('ref.dict_merchant', 'mcc', toUInt64(merchant_id))                AS mcc,
    dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant_id))       AS merchant_country,
    dictGet('ref.dict_card', 'segment', card_id)                              AS segment,
    channel,
    sum(amount_eur)                                                           AS spend_eur,
    count()                                                                   AS n_txns,
    uniqExact(card_id)                                                        AS n_cards,
    max(amount_eur)                                                           AS max_amount_eur
FROM silver.transaction FINAL
GROUP BY day, issuer_id, mcc, merchant_country, segment, channel;

--  The first refresh starts right away. Follow it in
--  system.view_refreshes (status, duration, rows written, next run):
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, read_rows, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

--  We wait for this 1st computation to finish before attaching other views to the table.
--  Watch out: without this wait, on a service with several replicas, step 3
--  fails with "has been changed by another replica".
SYSTEM WAIT VIEW gold.rmv_category_day_spend;


-- STEP 2 · The hourly spend curve of each issuer (for the dashboard)
--  8 million silver transactions become about 9,000 rows: one curve per issuer and per channel.
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


-- STEP 3 · A view that DEPENDS on another one: the summary per issuer
--  DEPENDS ON: it waits until the spend by category has been refreshed.
CREATE OR REPLACE TABLE gold.issuer_day_summary
(
    issuer_id         String,
    issuer            String,
    day               Date,
    pos_eur           Decimal(18, 2),
    ecom_eur          Decimal(18, 2),
    ecom_share        Float64,         -- online spend / total spend
    cross_border_eur  Decimal(18, 2),  -- spent at merchants outside the issuer's country
    n_txns            UInt32
)
ENGINE = MergeTree
ORDER BY (issuer_id, day);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_issuer_summary
REFRESH EVERY 10 MINUTE
DEPENDS ON gold.rmv_category_day_spend
TO gold.issuer_day_summary
AS
SELECT
    i.issuer_id                                                   AS issuer_id,
    i.name                                                        AS issuer,
    e.day                                                         AS day,
    sumIf(e.spend_eur, e.channel = 'POS')                         AS pos_eur,
    sumIf(e.spend_eur, e.channel = 'ECOM')                        AS ecom_eur,
    round(toFloat64(ecom_eur) / toFloat64(pos_eur + ecom_eur), 4) AS ecom_share,
    sumIf(e.spend_eur, e.merchant_country != i.country_code)      AS cross_border_eur,
    sum(e.n_txns)                                                 AS n_txns
FROM gold.category_day_spend AS e
INNER JOIN ref.issuer AS i ON i.issuer_id = e.issuer_id
GROUP BY issuer_id, issuer, day;


-- STEP 4 · Forcing a refresh (instead of waiting 10 min)
--  SYSTEM REFRESH starts the computation, SYSTEM WAIT waits until it is done.
--  The result replaces the old one in one go: a dashboard never sees a partial state.
SYSTEM REFRESH VIEW gold.rmv_category_day_spend;
SYSTEM WAIT VIEW gold.rmv_category_day_spend;
SYSTEM REFRESH VIEW gold.rmv_issuer_summary;
SYSTEM WAIT VIEW gold.rmv_issuer_summary;
SYSTEM REFRESH VIEW gold.rmv_issuer_curve;
SYSTEM WAIT VIEW gold.rmv_issuer_curve;

SELECT view, status, last_success_time, round(last_success_duration_ms / 1000, 2) AS duration_s, written_rows
FROM system.view_refreshes
WHERE database = 'gold';

SELECT issuer, round(sum(pos_eur) / 1e6, 2) AS pos_meur, round(sum(ecom_eur) / 1e6, 2) AS ecom_meur,
       round(100 * sum(ecom_eur) / sum(pos_eur + ecom_eur), 1) AS ecom_pct,
       round(100 * sum(cross_border_eur) / sum(pos_eur + ecom_eur), 1) AS cross_border_pct,
       sum(n_txns) AS n_txns
FROM gold.issuer_day_summary
GROUP BY issuer
ORDER BY pos_meur DESC;
-- What to look for: 6 issuers, Lumière Banque first (12 batches out of 20).
--    About one euro in five is spent online, and cross-border spend is a few
--    percent in store and far more online.
