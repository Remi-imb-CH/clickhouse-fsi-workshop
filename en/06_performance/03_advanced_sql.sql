-- =====================================================================
--  MODULE 6 · Advanced SQL on payment transactions
-- =====================================================================
--  Seven SQL tools that come up all the time with payment data, and a bonus.
--  They run on silver.transaction (the 100,000 cards of the JSON files).
-- =====================================================================


-- 1 · 3-hour moving average (window function)
--  OVER (ORDER BY hour ROWS BETWEEN 2 PRECEDING AND CURRENT ROW): for each
--  row, the average of the row and the 2 before it.
--  The window smooths the curve without grouping the rows.
SELECT
    hour,
    spend_eur,
    round(avg(spend_eur) OVER (ORDER BY hour ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) AS avg_3h
FROM
(
    SELECT toStartOfHour(toTimeZone(ts, 'Europe/Paris')) AS hour, toFloat64(sum(amount_eur)) AS spend_eur
    FROM silver.transaction FINAL
    WHERE day = '2026-10-15'
    GROUP BY hour
)
ORDER BY hour;


-- 2 · Make the GAPS visible: WITH FILL
--  Take the busiest merchant of October 15 and count its payments hour by hour.
--  ORDER BY … WITH FILL adds the missing rows of the series, from FROM to TO,
--  in steps of STEP (3600 s). The columns of the added rows get their
--  default value (0): the hours without any payment become visible.
WITH (
    SELECT merchant_id FROM silver.transaction
    WHERE day = '2026-10-15'
    GROUP BY merchant_id ORDER BY count() DESC, merchant_id LIMIT 1
) AS target
SELECT toTimeZone(hour, 'Europe/Paris') AS local_hour, payments, if(payments = 0, 'no payment', '') AS flag
FROM
(
    SELECT toStartOfHour(ts) AS hour, count() AS payments
    FROM silver.transaction FINAL
    WHERE merchant_id = target AND day = '2026-10-15'
    GROUP BY hour
    ORDER BY hour WITH FILL
        FROM toDateTime('2026-10-14 22:00:00', 'UTC')     -- midnight in Paris, in UTC
        TO   toDateTime('2026-10-15 22:00:00', 'UTC')
        STEP 3600
);
-- What to look for: 24 rows, including the hours where the terminal stayed silent.
-- The same pattern detects a terminal or an ATM that stopped sending.


-- 3 · The hour of each card's largest payment (argMax), in a single pass
--  argMax(ts, amount_eur) returns the ts of the row where amount_eur is highest:
--  no subquery or join needed to find "the time of the max".
SELECT segment, peak_hour, count() AS cards
FROM
(
    SELECT
        card_id,
        dictGet('ref.dict_card', 'segment', card_id)             AS segment,
        toHour(argMax(ts, amount_eur), 'Europe/Paris')           AS peak_hour
    FROM silver.transaction FINAL
    WHERE day = '2026-10-15'
    GROUP BY card_id
)
GROUP BY segment, peak_hour
ORDER BY segment, cards DESC
LIMIT 3 BY segment;   -- the 3 most frequent hours of each segment


-- 4 · Typical profile: weekday vs weekend, by local hour
--  sumIf(value, condition): a filtered sum. Two columns in a single scan.
--  uniqExactIf counts the days of each type, to get an average per day
--  (greatest(1, …) avoids a division by zero for the hours without any payment).
SELECT
    toHour(ts, 'Europe/Paris')                                                                AS hour,
    round(toFloat64(sumIf(amount_eur, toDayOfWeek(day) <= 5)) / greatest(1, uniqExactIf(day, toDayOfWeek(day) <= 5))) AS weekday_eur,
    round(toFloat64(sumIf(amount_eur, toDayOfWeek(day) >= 6)) / greatest(1, uniqExactIf(day, toDayOfWeek(day) >= 6))) AS weekend_eur,
    bar(weekday_eur, 0, 400000, 25)                                                           AS weekday_chart
FROM silver.transaction FINAL
WHERE dictGet('ref.dict_card', 'segment', card_id) = 'BUSINESS'
GROUP BY hour
ORDER BY hour;


-- 5 · Distribution by segment: quantiles of the amount
--  quantiles(0.5, 0.9, 0.99) computes several percentiles in one pass.
SELECT
    dictGet('ref.dict_card', 'segment', card_id)                               AS segment,
    count()                                                                    AS payments,
    arrayMap(x -> round(x, 2), quantiles(0.5, 0.9, 0.99)(toFloat64(amount_eur))) AS p50_p90_p99_eur,
    max(amount_eur)                                                            AS max_eur
FROM silver.transaction FINAL
GROUP BY segment
ORDER BY segment;


-- 6 · ASOF JOIN: the daily limit "at date", without a dictionary
--  For each day, ASOF JOIN takes the most recent history row whose
--  valid_from is on or before the day. Same result as the RANGE_HASHED
--  dictionary of module 4, written as a join.
SELECT
    p.card_id, p.day, p.authorized_eur, h.daily_limit_eur AS limit_at_date,
    p.authorized_eur > h.daily_limit_eur AS over_limit
FROM silver.daily_auth AS p FINAL
ASOF JOIN ref.card_limit_history AS h ON p.card_id = h.card_id AND p.day >= h.valid_from
WHERE p.card_id IN (SELECT card_id FROM ref.card_limit_history
                    WHERE valid_to BETWEEN '2026-10-10' AND '2026-10-20' AND daily_limit_eur > 15000 AND card_id < sim_card_id(100000)
                    ORDER BY card_id LIMIT 1)
ORDER BY p.card_id, p.day
LIMIT 31;


-- 7 · Channel mix: at what time does online overtake in-store?
--  sumIf separates POS and ECOM in the same query. We reuse the aliases
--  pos_eur and ecom_eur in the next calculation: ClickHouse allows it.
SELECT
    toHour(ts, 'Europe/Paris')                                    AS hour,
    round(sumIf(amount_eur, channel = 'POS'))                     AS pos_eur,
    round(sumIf(amount_eur, channel = 'ECOM'))                    AS ecom_eur,
    round(100 * ecom_eur / (pos_eur + ecom_eur), 1)               AS ecom_pct
FROM silver.transaction FINAL
WHERE day = '2026-10-15'
GROUP BY hour
ORDER BY hour;


-- BONUS · A velocity check, the classic fraud signal
--  For each payment, how many payments did the same card make in the previous 10 minutes?
--  RANGE BETWEEN 600 PRECEDING AND CURRENT ROW: a window in SECONDS, not in rows.
SELECT card_id, toTimeZone(ts, 'Europe/Paris') AS local_time, amount_eur, payments_in_10_min
FROM
(
    SELECT
        card_id, ts, amount_eur,
        count() OVER (PARTITION BY card_id ORDER BY toUInt32(ts) RANGE BETWEEN 600 PRECEDING AND CURRENT ROW) AS payments_in_10_min
    FROM silver.transaction FINAL
    WHERE day = '2026-10-15'
)
WHERE payments_in_10_min >= 3
ORDER BY payments_in_10_min DESC, card_id, ts
LIMIT 10;
-- What to look for: the cards that paid 3 times or more within 10 minutes, out of
-- ~280,000 payments that day. In production this runs in a materialized view or behind an API.
