-- =====================================================================
--  MODULE 5 · Gold (3/4): the 9am SLA, over-limit alerts, reconciliation
-- =====================================================================


-- STEP 1 · KPI "99% of the transactions received by 9am"
--  The SETTLEMENT flow tells how many transactions each card made (the scheme's ledger).
--  The CLEARING flow brings the detail. Two readings of the same day:
--    · data_by_9am_pct: transactions received before 9am the next day / transactions declared
--      (this is the contractual target: 99%)
--    · complete_cards_9am_pct: cards whose day is COMPLETE at 9am, stricter
--      (a single missing transaction and the card does not count)
--  In production: REFRESH EVERY 1 DAY OFFSET 9 HOUR (every day at 9am).
--  The view joins the declared totals with gold.card_day_clearing (small): the computation is fast.
CREATE OR REPLACE TABLE gold.daily_sla_kpi
(
    day                      Date,
    active_cards             UInt32,
    txns_declared            UInt64,
    txns_received_9am        UInt64,
    data_by_9am_pct          Float64,
    complete_cards_9am       UInt32,
    complete_cards_9am_pct   Float64
)
ENGINE = MergeTree
ORDER BY day;

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_sla_kpi
REFRESH EVERY 1 DAY OFFSET 9 HOUR
TO gold.daily_sla_kpi
AS
WITH
    declared AS
    (
        SELECT day, card_id, sum(txn_count) AS expected
        FROM silver.daily_settlement FINAL
        GROUP BY day, card_id
        HAVING expected > 0                                   -- a card with no payment that day is not "active"
    ),
    received AS
    (
        SELECT day, card_id, uniqExactIfMerge(txns_before_9am) AS before_9am
        FROM gold.card_day_clearing
        GROUP BY day, card_id
    )
SELECT
    d.day                                                     AS day,
    count()                                                   AS active_cards,
    sum(d.expected)                                           AS txns_declared,
    sum(r.before_9am)                                         AS txns_received_9am,
    round(100 * txns_received_9am / txns_declared, 2)         AS data_by_9am_pct,
    countIf(r.before_9am >= d.expected)                       AS complete_cards_9am,
    round(100 * complete_cards_9am / active_cards, 2)         AS complete_cards_9am_pct
FROM declared AS d
LEFT JOIN received AS r ON r.day = d.day AND r.card_id = d.card_id   -- LEFT: a card with nothing received counts too
GROUP BY d.day;

SYSTEM REFRESH VIEW gold.rmv_sla_kpi;
SYSTEM WAIT VIEW gold.rmv_sla_kpi;

SELECT day, data_by_9am_pct, complete_cards_9am_pct,
       if(data_by_9am_pct >= 99, 'OK', 'below target') AS target_99
FROM gold.daily_sla_kpi
ORDER BY day;
-- What to look for: most days meet the target. The ones below: one or more files
--    arrived in the afternoon (one batch = 5,000 cards, i.e. 5% of the portfolio at once).

--  Which ones? The CLEARING files that arrived after 9am, Paris time
SELECT toDate(ingested_at, 'Europe/Paris') - 1 AS day, file_name, toTimeZone(ingested_at, 'Europe/Paris') AS arrival
FROM bronze.raw_flows
WHERE flow_code = 'CLEARING' AND toHour(ingested_at, 'Europe/Paris') >= 9
  AND file_name NOT LIKE '%RESEND%' AND file_name NOT LIKE '%ADJUSTMENT%'
ORDER BY ingested_at
LIMIT 10;


-- STEP 2 · Over-limit alerts
--  The reference limit is the one IN FORCE on the day of the payments:
--  dictGet on the "as of" dictionary from module 4, with the day as the 2nd key.
CREATE OR REPLACE TABLE gold.limit_alerts
(
    day             Date,
    card_id         UInt64,
    issuer_id       LowCardinality(String),
    city            String,
    segment         LowCardinality(String),
    limit_eur       UInt32,
    authorized_eur  Decimal(18, 2),
    over_limit_pct  Float64,
    peak_time       DateTime('Europe/Paris')
)
ENGINE = MergeTree
ORDER BY (day, card_id);

CREATE OR REPLACE MATERIALIZED VIEW gold.rmv_limit_alerts
REFRESH EVERY 10 MINUTE
TO gold.limit_alerts
AS
SELECT
    day,
    card_id,
    dictGet('ref.dict_card', 'issuer_id', card_id)                                       AS issuer_id,
    dictGet('ref.dict_city', 'name', dictGet('ref.dict_card', 'city_code', card_id))     AS city,
    dictGet('ref.dict_card', 'segment', card_id)                                         AS segment,
    dictGet('ref.dict_limit_asof', 'daily_limit_eur', card_id, day)                      AS limit_eur,
    authorized_eur,
    round(100 * (toFloat64(authorized_eur) / limit_eur - 1), 1)                          AS over_limit_pct,
    ts_peak                                                                              AS peak_time
FROM silver.daily_auth FINAL
WHERE authorized_eur > dictGet('ref.dict_limit_asof', 'daily_limit_eur', card_id, day);

SYSTEM REFRESH VIEW gold.rmv_limit_alerts;
SYSTEM WAIT VIEW gold.rmv_limit_alerts;

SELECT day, count() AS n_alerts, round(avg(over_limit_pct), 1) AS avg_over_limit_pct
FROM gold.limit_alerts
GROUP BY day
ORDER BY day;

--  By segment: on a CONSUMER card, the authorization is declined at the limit.
--  So the alerts only concern BUSINESS and CORPORATE cards (where the limit is "soft"
--  and going over it is billed).
SELECT segment, count() AS alerts, uniqExact(card_id) AS cards, round(avg(over_limit_pct), 1) AS avg_over_limit_pct
FROM gold.limit_alerts
GROUP BY segment;

--  Cards whose limit was raised in October: fewer alerts afterwards?
SELECT
    countIf(a.day <= h.valid_to)  AS alerts_before_change,
    countIf(a.day >  h.valid_to)  AS alerts_after_change,
    uniqExact(a.card_id)          AS cards
FROM gold.limit_alerts AS a
INNER JOIN (SELECT card_id, valid_to FROM ref.card_limit_history WHERE valid_to BETWEEN '2026-10-01' AND '2026-10-30') AS h
    ON h.card_id = a.card_id;
-- What to look for: the customer kept going over, had the limit raised, the alerts drop.
--    dict_limit_asof is what makes this correct: we compare with the limit OF THAT DAY.


-- STEP 3 · Reconciliation: settlement totals (the ledger) vs the clearing detail
--  A gap is a "break": we know WHICH card, WHICH day and HOW MUCH is missing.
--  The settlement totals come from the scheme's ledger, so they are complete even if the detail has gaps.
--  A plain view (CREATE VIEW) stores nothing: the query runs on every read.
CREATE OR REPLACE VIEW gold.v_reconciliation AS
SELECT
    s.day,
    s.card_id,
    s.declared_txns,
    s.declared_eur,
    c.cleared_txns,
    c.cleared_eur,
    s.declared_txns - c.cleared_txns  AS missing_txns,
    s.declared_eur - c.cleared_eur    AS break_eur
FROM
(
    SELECT day, card_id, sum(txn_count) AS declared_txns, sum(amount_eur) AS declared_eur
    FROM silver.daily_settlement FINAL
    GROUP BY day, card_id
    HAVING declared_txns > 0
) AS s
LEFT JOIN
(
    SELECT day, card_id, count() AS cleared_txns, sum(amount_eur) AS cleared_eur
    FROM silver.transaction FINAL
    GROUP BY day, card_id
) AS c ON c.day = s.day AND c.card_id = s.card_id;

SELECT
    multiIf(break_eur = 0, '1. matched to the cent', cleared_txns = 0, '4. no detail received',
            missing_txns = 1, '2. one transaction missing', '3. several transactions missing') AS status,
    count()                   AS card_days,
    round(100 * count() / sum(count()) OVER (), 2) AS pct,
    sum(break_eur)            AS total_break_eur
FROM gold.v_reconciliation
GROUP BY status
ORDER BY status;
-- What to look for: more than 99% of card-days match to the cent. The others are
-- located to the card and the day: a missing transaction, an unreadable amount (module 3 rejects),
-- or a card whose records were dropped from the file.

--  The largest breaks, ready for the operations team
SELECT day, card_id, declared_txns, cleared_txns, declared_eur, cleared_eur, break_eur
FROM gold.v_reconciliation
WHERE break_eur != 0
ORDER BY break_eur DESC
LIMIT 5;


-- CHECKPOINT MODULE 5
--  31 days of KPI, and at least one alert and one row in each gold table.
SELECT
    if((SELECT count() FROM gold.card_day_clearing) > 2000000, 'OK', 'FAIL')    AS clearing,
    if((SELECT count() FROM gold.category_day_spend) > 0, 'OK', 'FAIL')         AS spend,
    if((SELECT count() FROM gold.issuer_day_summary) > 0, 'OK', 'FAIL')         AS summary,
    if((SELECT count() FROM gold.daily_sla_kpi) = 31, 'OK', 'FAIL')             AS kpi_9am,
    if((SELECT count() FROM gold.limit_alerts) > 0, 'OK', 'FAIL')               AS alerts
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it
