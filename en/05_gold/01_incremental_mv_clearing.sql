-- =====================================================================
--  MODULE 5 · Gold (1/4): clearing tracking, in real time
-- =====================================================================
--  bronze ──MV──► silver ──MV──► gold      (CASCADING MVs)
--  For each card and each day, we count the transactions received, and those
--  received BEFORE 9am the next day (the settlement cut-off).
--  Aggregation at insert time: AggregatingMergeTree.
--  Gold receives ready-made aggregates: the KPI is read from a small table
--  instead of recounting millions of transactions (rule query-mv-incremental).
-- =====================================================================


-- STEP 1 · An aggregate table: it stores STATES, not values
--  A state is an "in-progress" calculation (for example the set of references seen).
--  Two states merge without losing anything: that is what the merges do.
--  SimpleAggregateFunction is enough for min and max, which merge trivially.
CREATE OR REPLACE TABLE gold.card_day_clearing
(
    day              Date,
    card_id          UInt64,
    txns_received    AggregateFunction(uniqExact, UInt64),
    txns_before_9am  AggregateFunction(uniqExactIf, UInt64, UInt8),
    first_arrival    SimpleAggregateFunction(min, DateTime64(3, 'UTC')),
    last_arrival     SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(day)
ORDER BY (day, card_id);


-- STEP 2 · The MV attached to silver (triggered by the bronze → silver MV)
--  uniqExact is IDEMPOTENT: a resent file is not counted twice.
--  The -State suffix produces the state instead of the final result.
CREATE OR REPLACE MATERIALIZED VIEW gold.mv_clearing TO gold.card_day_clearing AS
SELECT
    day,
    card_id,
    uniqExactState(txn_ref)                                                                             AS txns_received,
    uniqExactIfState(txn_ref, toUInt8(version < toDateTime(day + 1, 'Europe/Paris') + INTERVAL 9 HOUR)) AS txns_before_9am,
    min(version)                                                                                        AS first_arrival,
    max(version)                                                                                        AS last_arrival
FROM silver.transaction
GROUP BY day, card_id;


-- STEP 3 · Backfill from silver (the MV only sees the future, remember)
INSERT INTO gold.card_day_clearing
SELECT
    day, card_id,
    uniqExactState(txn_ref),
    uniqExactIfState(txn_ref, toUInt8(version < toDateTime(day + 1, 'Europe/Paris') + INTERVAL 9 HOUR)),
    min(version), max(version)
FROM silver.transaction
GROUP BY day, card_id;


-- STEP 4 · Reading states: the -Merge suffix
--  uniqExactMerge merges the states from all parts and returns the final count.
--  Always with a GROUP BY: several rows can exist for the same card-day.
SELECT
    day,
    uniqExactMerge(txns_received)       AS transactions,
    uniqExactIfMerge(txns_before_9am)   AS before_9am,
    min(first_arrival)                  AS first_arrival
FROM gold.card_day_clearing
WHERE card_id = sim_card_id(648)
GROUP BY day
ORDER BY day
LIMIT 10;


-- STEP 5 · The duplicate experiment: is a SUM in an MV safe?
--  We create an MV that sums the spend per day, then resend a file.
CREATE OR REPLACE TABLE gold.naive_spend
(
    day        Date,
    spend_eur  SimpleAggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE OR REPLACE MATERIALIZED VIEW gold.mv_naive_spend TO gold.naive_spend AS
SELECT day, sum(toFloat64(amount_eur)) AS spend_eur
FROM silver.transaction
GROUP BY day;

INSERT INTO gold.naive_spend
SELECT day, sum(toFloat64(amount_eur)) FROM silver.transaction FINAL GROUP BY day;

--  We resend a file that was already received (batch 3 of October 20)
INSERT INTO bronze.raw_flows
SELECT replaceOne(file_name, '_488903_', '_488903_RESEND_'), flow_code, ingested_at + INTERVAL 1 DAY, payload
FROM bronze.raw_flows
WHERE file_name LIKE 'SCHEME_CLEARING_DETAIL_100383_488903_2%';

SELECT
    (SELECT round(sum(spend_eur)) FROM gold.naive_spend WHERE day = '2026-10-20')                                    AS sum_by_mv,
    (SELECT round(sum(amount_eur)) FROM silver.transaction FINAL WHERE day = '2026-10-20')                           AS actual_sum,
    (SELECT sum(n) FROM (SELECT uniqExactMerge(txns_received) AS n FROM gold.card_day_clearing WHERE day = '2026-10-20' GROUP BY card_id)) AS txns_mv_uniq,
    (SELECT count() FROM silver.transaction FINAL WHERE day = '2026-10-20')                                          AS actual_txns;
-- What to look for: the sum is off by about 5% (the resent file is counted
--    twice: one batch out of 20), uniqExact stays correct.
--    Rule: sum in an incremental MV only if the source never has duplicates.
--    Otherwise: a REFRESHABLE materialized view on silver FINAL (next file).
--    In payments, a double-counted file is a reconciliation break: it must never reach a report.

--  We drop the experiment: it is no longer needed.
DROP VIEW gold.mv_naive_spend;
DROP TABLE gold.naive_spend;
