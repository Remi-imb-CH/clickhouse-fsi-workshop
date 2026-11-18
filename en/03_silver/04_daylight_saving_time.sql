-- =====================================================================
--  MODULE 3 · The daylight saving time trap (October 25, 2026)
-- =====================================================================
--  At 3am (summer time) the clocks go back to 2am (winter time): the business day
--  lasts 25 hours. Every local time between 02:00 and 02:59 exists TWICE.
--  That is why we store in UTC and display in local time.
-- =====================================================================


-- STEP 1 · Hours with payments, per business day (Paris time)
--  What to look for: 24 distinct hours on the 24th and 26th, 25 on the 25th.
SELECT
    day,
    uniqExact(toStartOfHour(ts)) AS hours_with_payments,
    count()                      AS transactions
FROM silver.transaction FINAL
WHERE day BETWEEN '2026-10-24' AND '2026-10-26'
GROUP BY day
ORDER BY day;


-- STEP 2 · The night of the 25th: same local time, two different instants
--  What to look for: 02:00 appears twice in local time, with a +0200 offset
--  (summer time) then +0100 (winter time). In UTC, no duplicate: that is why ts is stored in UTC.
SELECT
    toStartOfHour(ts)                                             AS hour_utc,
    formatDateTime(toStartOfHour(ts), '%H:%i', 'Europe/Paris')    AS local_hour,
    formatDateTime(toStartOfHour(ts), '%z', 'Europe/Paris')       AS utc_offset,
    count()                                                       AS transactions
FROM silver.transaction FINAL
WHERE ts >= '2026-10-24 22:00:00' AND ts < '2026-10-25 04:00:00'
GROUP BY hour_utc
ORDER BY hour_utc;


-- STEP 3 · A payment stamped "02:xx" that night: which hour is it?
--  The file gives the offset, so nothing is ambiguous once stored in UTC.
--  What to look for: two groups of payments share the same local hour, one hour apart in UTC.
SELECT
    formatDateTime(ts, '%z', 'Europe/Paris')   AS utc_offset,
    count()                                    AS payments_stamped_02h,
    min(ts)                                    AS first_utc,
    max(ts)                                    AS last_utc
FROM silver.transaction FINAL
WHERE formatDateTime(ts, '%Y-%m-%d %H', 'Europe/Paris') = '2026-10-25 02'
GROUP BY utc_offset
ORDER BY first_utc;


-- STEP 4 · The length of a business day is computed, not assumed
--  We measure the actual length of the local day. The settlement cut-off
--  and the SLA of module 5 use exactly this calculation.
SELECT
    day,
    dateDiff('hour', toDateTime(day, 'Europe/Paris'), toDateTime(day + 1, 'Europe/Paris')) AS hours_in_the_day
FROM (SELECT toDate('2026-10-23') + number AS day FROM numbers(5));
