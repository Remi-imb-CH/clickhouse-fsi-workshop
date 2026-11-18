-- =====================================================================
--  MODULE 2 · The card payment simulator (run it as is)
-- =====================================================================
--  We cannot share real payment data. So we SIMULATE it with
--  SQL functions (UDFs) that reproduce real-world behavior:
--    · consumers  : in-store payments peak at lunch and in the early evening,
--                   Saturday is the busiest day, Sunday the quietest
--    · online     : payments peak around 9pm, and go abroad more often
--    · business   : office hours on weekdays, very little at the weekend
--    · corporate  : few cards, large amounts
--    · October    : spending rises a little through the month
--  Target orders of magnitude: a consumer card makes ~3 payments a day and spends
--  ~3% of its daily limit (about 25 EUR per payment), a corporate card ~14 payments
--  and ~10% of its limit.
--  All amounts are settlement amounts in EUR, all local times are Europe/Paris
--  (the processing calendar of the fictional scheme).
--  Everything is deterministic: everyone gets exactly the same numbers.
-- =====================================================================


-- UDFs: one function = one reusable SQL expression
--  A SQL UDF is not external code: it is an expression that ClickHouse
--  copies into the query when it runs it. No call overhead, and
--  it benefits from vectorized execution like any native function.
--  All the simulator functions start with sim_.
CREATE OR REPLACE FUNCTION sim_card_id AS (n) ->
    toUInt64(4000000000000000 + n * 4093 + cityHash64(n) % 4093);

CREATE OR REPLACE FUNCTION sim_random AS (a, b, c) ->
    (cityHash64(a, b, c) % 1000000) / 1000000.;                -- deterministic "random" between 0 and 1

--  Each transaction has a SEED (a big number): every property of the transaction
--  (time, amount, merchant…) is derived from it with sim_u.
CREATE OR REPLACE FUNCTION sim_u AS (seed, tag) ->
    (cityHash64(seed, tag) % 1000000) / 1000000.;              -- between 0 and 1

CREATE OR REPLACE FUNCTION sim_z AS (seed, tag) ->             -- bell-shaped, centered on 0, spread ~1
    (sim_u(seed, concat(tag, '1')) + sim_u(seed, concat(tag, '2')) + sim_u(seed, concat(tag, '3')) - 1.5) * 2;

--  sim_day_count: how many payments a card makes on a given day.
--  = level of the segment × day of the week × trend of the month × noise.
CREATE OR REPLACE FUNCTION sim_day_count AS (id, segment, day) ->
    toUInt8(floor(
        multiIf(segment = 'CONSUMER', 2.6, segment = 'BUSINESS', 6., 14.)
        * multiIf(segment = 'CONSUMER', [1., 1., 1., 1., 1.1, 1.3, 0.7][toDayOfWeek(day)],    -- Saturday shopping, quiet Sunday
                  segment = 'BUSINESS', [1., 1., 1., 1., 1., 0.3, 0.2][toDayOfWeek(day)],     -- office days
                                        [1., 1., 1., 1., 1., 0.5, 0.4][toDayOfWeek(day)])
        * (1 + 0.004 * toDayOfMonth(day))                                                    -- spending rises through October
        * (0.3 + 1.4 * sim_random(id, day, 'n'))                                             -- noise
        + sim_random(id, day, 'round')));

--  The seeds of all the transactions of a card on a day
CREATE OR REPLACE FUNCTION sim_day_seeds AS (id, segment, day) ->
    arrayMap(i -> cityHash64(id, day, i), range(sim_day_count(id, segment, day)));

CREATE OR REPLACE FUNCTION sim_is_ecom AS (seed, ecom_share) ->
    sim_u(seed, 'channel') < ecom_share;

--  sim_txn_ts: the instant of a transaction (UTC), from an hour of the day in local time.
--  The hour (0 to 24) is turned into a share of the business day, then multiplied by the
--  real length of that day in seconds: 24 hours, except 25 on the day of the clock change.
CREATE OR REPLACE FUNCTION sim_txn_ts AS (seed, segment, is_ecom, day) ->
    toDateTime(toUInt32(toDateTime(day, 'Europe/Paris'))
        + toUInt32((toUInt32(toDateTime(day + 1, 'Europe/Paris')) - toUInt32(toDateTime(day, 'Europe/Paris'))) / 24
          * least(23.99, greatest(0.01,
            multiIf(
                is_ecom,                if(sim_u(seed, 'mode') < 0.6, 21 + 1.6 * sim_z(seed, 'h'),          -- online: mostly in the evening
                                                                      13 + 3.5 * sim_z(seed, 'h')),
                segment = 'CONSUMER',   multiIf(sim_u(seed, 'mode') < 0.30, 12.6 + 0.9 * sim_z(seed, 'h'),  -- lunch
                                                sim_u(seed, 'mode') < 0.75, 18.3 + 1.5 * sim_z(seed, 'h'),  -- early evening
                                                24 * sim_u(seed, 'flat')),                                  -- any time, night included
                segment = 'BUSINESS',   13.5 + 2.6 * sim_z(seed, 'h'),                                      -- office hours
                                        13 + 4 * sim_z(seed, 'h'))))), 'UTC');

--  sim_amount: the amount in CENTS = share of the daily limit × a skewed draw
--  (many small payments, a few large ones). Money is computed in whole cents,
--  never in floating point: sums stay exact to the cent.
CREATE OR REPLACE FUNCTION sim_amount AS (seed, segment, limit_eur) ->
    toUInt64(round(limit_eur * 100 * multiIf(segment = 'CONSUMER', 0.03 / 2.6, segment = 'BUSINESS', 0.06 / 6, 0.10 / 14)
                   * (0.15 + 2.55 * pow(sim_u(seed, 'amount'), 2))));

CREATE OR REPLACE FUNCTION sim_money AS (cents) ->                  -- 8420 → '84.20', the format of the files
    concat(toString(intDiv(cents, 100)), '.', leftPad(toString(cents % 100), 2, '0'));

--  sim_merchant: a merchant of the home country most of the time, anywhere otherwise
--  (6% of in-store payments and 35% of online payments are cross-border).
CREATE OR REPLACE FUNCTION sim_merchant AS (seed, is_ecom, first_merchant, n_merchants) ->
    toUInt32(1000000 + if(sim_u(seed, 'abroad') < if(is_ecom, 0.35, 0.06),
                          cityHash64(seed, 'm') % 50000,
                          first_merchant + cityHash64(seed, 'm') % n_merchants));

CREATE OR REPLACE FUNCTION sim_iso AS (ts) ->                       -- source format: 2026-10-25T02:30:00+01:00
    concat(substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 1, 22), ':',
           substring(formatDateTime(ts, '%Y-%m-%dT%H:%i:%S%z', 'Europe/Paris'), 23, 2));

--  sim_txn: one transaction as it appears in a clearing file: (ts, amount, merchantId, ref).
--  ~0.03% of amounts are empty (they will go to the rejects table in module 3).
CREATE OR REPLACE FUNCTION sim_txn AS (seed, segment, limit_eur, is_ecom, first_merchant, n_merchants, day) ->
    (sim_iso(sim_txn_ts(seed, segment, is_ecom, day)),
     if(sim_u(seed, 'ko') < 0.0003, '', sim_money(sim_amount(seed, segment, limit_eur))),
     toString(sim_merchant(seed, is_ecom, first_merchant, n_merchants)),
     toString(seed % 1000000000000000));


-- The simulator dictionary: the characteristics of each card in memory
--  To generate transactions, we need the segment, the limit and the online share
--  of each card. A dictionary loads this data into RAM once, then
--  dictGet reads it in constant time, without a join (details in module 4).
CREATE OR REPLACE DICTIONARY simulator.dict_card
(
    card_id          UInt64,
    segment          String,
    daily_limit_eur  UInt32,
    ecom_share       Float32,
    first_merchant   UInt32,              -- the range of merchants of the home country
    n_merchants      UInt32,
    old_end          Date,                -- last day of the old limit (1970-01-01 if never changed)
    old_limit        UInt32
)
PRIMARY KEY card_id
SOURCE(CLICKHOUSE(
    QUERY 'SELECT c.card_id, c.segment, c.daily_limit_eur, c.ecom_share, r.first_merchant, r.n_merchants, h.valid_to, h.daily_limit_eur
           FROM ref.card AS c
           INNER JOIN ref.city AS ci ON ci.city_code = c.city_code
           INNER JOIN (SELECT country_code, toUInt32(min(merchant_id) - 1000000) AS first_merchant, toUInt32(count()) AS n_merchants
                       FROM ref.merchant GROUP BY country_code) AS r ON r.country_code = ci.country_code
           LEFT JOIN (SELECT card_id, valid_to, daily_limit_eur FROM ref.card_limit_history WHERE valid_to < ''2099-01-01'') AS h ON h.card_id = c.card_id'
    USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED())
LIFETIME(0);


-- The 3 file generators, as PARAMETERIZED VIEWS
--  File no. k = day (k / 20) of October, batch (k % 20) of 5,000 cards.
--  Each batch belongs to an issuing bank (sim_issuer, module 1).
--  Usage: SELECT * FROM simulator.clearing_files(start = 0, n = 20)  → October 1
--
--  Trap avoided: in ClickHouse an alias is GLOBAL to the query. Writing
--  'POS' AS channel then 'ECOM' AS channel makes the 2nd alias
--  take the value of the 1st. So we build tuples WITHOUT aliases, then
--  convert them in one go (CAST) to a named type: the names become the
--  JSON keys.
--
--  A parameterized view is a saved query with parameters
--  ({start:UInt32}, {n:UInt32}). You call it like a table function.

--  CLEARING: every transaction of the day, card by card, channel by channel.
CREATE OR REPLACE VIEW simulator.clearing_files AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    -- arrival: the next day between 6am and 8am, except ~1% of late files (in the afternoon)
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC')
        + toIntervalSecond(if(sim_random(day, batch, 'late') < 0.01, 50400, 21600 + batch * 300 + cityHash64(day, batch) % 240)) AS arrival,
    -- ~0.3% of cards are missing from the file that day (records dropped upstream)
    arrayFilter(n -> sim_random(n, day, 'drop') >= 0.003, range(batch * 5000, batch * 5000 + 5000)) AS ns,
    arrayMap(n -> sim_card_id(n), ns)                                           AS ids,
    arrayMap(id -> dictGet('simulator.dict_card', ('segment', 'daily_limit_eur', 'ecom_share', 'first_merchant', 'n_merchants'), id), ids) AS attrs,
    arrayMap((id, a) -> sim_day_seeds(id, a.1, day), ids, attrs)                AS seeds
SELECT
    concat('SCHEME_CLEARING_DETAIL_', toString(100000 + number), '_', sim_issuer(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'CLEARING' AS flow_code,
    arrival    AS ingested_at,
    toJSONString(CAST((
        ('EMEA CARD SWITCH', 'ISSUER', sim_issuer(batch), 'CLR01', toString(100000 + number), 'DAILY', 'JSON'),
        arrayMap((id, a, sd) -> (
            toString(id),
            'CLEARED',
            (toString(day), toString(day + 1)),
            'EUR',
            arrayConcat(
                -- in-store payments: ~0.1% of transactions are missing from the file
                [('POS',
                  arrayMap(s -> sim_txn(s, a.1, a.2, 0, a.4, a.5, day),
                           arrayFilter(s -> NOT sim_is_ecom(s, a.3) AND sim_u(s, 'gap') >= 0.001, sd)))],
                -- online payments, only for cards that pay online
                if(a.3 > 0,
                   [('ECOM',
                     arrayMap(s -> sim_txn(s, a.1, a.2, 1, a.4, a.5, day),
                              arrayFilter(s -> sim_is_ecom(s, a.3) AND sim_u(s, 'gap') >= 0.001, sd)))],
                   []))
        ), ids, attrs, seeds)
    ), 'Tuple(header Tuple(sender String, receiverType String, receiverId String, flowCode String, fileId String, cycle String, format String),
              records Array(Tuple(cardId String, stage String, period Tuple(startDate String, endDate String), currency String,
                                  channels Array(Tuple(channel String,
                                                       txns Array(Tuple(ts String, amount String, merchantId String, ref String)))))))')) AS payload
FROM numbers({start:UInt32}, {n:UInt32})
SETTINGS max_block_size = 2;   -- 2 files per block: each file weighs ~2 MB of JSON, memory stays low whatever the number of files

--  SETTLEMENT: the daily totals per card, from the scheme's ledger.
--  They are complete even when the clearing detail has gaps.
CREATE OR REPLACE VIEW simulator.settlement_files AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(25200 + batch * 120) AS arrival,
    arrayMap(n -> sim_card_id(n), range(batch * 5000, batch * 5000 + 5000))     AS ids,
    arrayMap(id -> dictGet('simulator.dict_card', ('segment', 'daily_limit_eur', 'ecom_share'), id), ids) AS attrs,
    arrayMap((id, a) -> sim_day_seeds(id, a.1, day), ids, attrs)                AS seeds
SELECT
    concat('SCHEME_SETTLEMENT_DAY_', toString(200000 + number), '_', sim_issuer(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'SETTLEMENT' AS flow_code,
    arrival      AS ingested_at,
    toJSONString(CAST((
        ('EMEA CARD SWITCH', 'ISSUER', sim_issuer(batch), 'STL01', toString(200000 + number), 'DAILY', 'JSON'),
        arrayMap((id, a, sd) -> (
            toString(id),
            'CLEARED',
            (toString(day), toString(day + 1)),
            'EUR',
            arrayConcat(
                [('POS', [(toString(day),
                           toString(arrayCount(s -> NOT sim_is_ecom(s, a.3), sd)),
                           sim_money(arraySum(arrayMap(s -> sim_amount(s, a.1, a.2), arrayFilter(s -> NOT sim_is_ecom(s, a.3), sd)))))])],
                if(a.3 > 0,
                   [('ECOM', [(toString(day),
                               toString(arrayCount(s -> sim_is_ecom(s, a.3), sd)),
                               sim_money(arraySum(arrayMap(s -> sim_amount(s, a.1, a.2), arrayFilter(s -> sim_is_ecom(s, a.3), sd)))))])],
                   []))
        ), ids, attrs, seeds)
    ), 'Tuple(header Tuple(sender String, receiverType String, receiverId String, flowCode String, fileId String, cycle String, format String),
              records Array(Tuple(cardId String, stage String, period Tuple(startDate String, endDate String), currency String,
                                  channels Array(Tuple(channel String,
                                                       totals Array(Tuple(d String, count String, amount String)))))))')) AS payload
FROM numbers({start:UInt32}, {n:UInt32})
SETTINGS max_block_size = 2;   -- 2 files per block: each file weighs ~2 MB of JSON, memory stays low whatever the number of files

--  AUTH: the amount AUTHORIZED per card over the day, and the instant of the largest payment.
--  It is what gets compared with the daily limit (module 5).
CREATE OR REPLACE VIEW simulator.auth_files AS
WITH
    toDate('2026-10-01') + intDiv(number, 20)                                  AS day,
    number % 20                                                                 AS batch,
    toDateTime64(toDateTime(day + 1, 'Europe/Paris'), 3, 'UTC') + toIntervalSecond(27000 + batch * 120) AS arrival,
    arrayMap(n -> sim_card_id(n), range(batch * 5000, batch * 5000 + 5000))     AS ids,
    arrayMap(id -> dictGet('simulator.dict_card', ('segment', 'daily_limit_eur', 'ecom_share', 'old_end', 'old_limit'), id), ids) AS attrs,
    arrayMap((id, a) -> sim_day_seeds(id, a.1, day), ids, attrs)                AS seeds
SELECT
    concat('SCHEME_AUTH_DAY_', toString(300000 + number), '_', sim_issuer(batch), '_', formatDateTime(arrival, '%Y%m%d%H%i%S'), '.zip') AS file_name,
    'AUTH'  AS flow_code,
    arrival AS ingested_at,
    toJSONString(CAST((
        ('EMEA CARD SWITCH', 'ISSUER', sim_issuer(batch), 'AUT01', toString(300000 + number), 'DAILY', 'JSON'),
        arrayMap((id, a, sd) -> (
            toString(id),
            (toString(day), toString(day + 1)),
            'EUR',
            (
                -- the instant of the largest payment of the day
                sim_iso(sim_txn_ts(arraySort(s -> -sim_amount(s, a.1, a.2), sd)[1], a.1, sim_is_ecom(arraySort(s -> -sim_amount(s, a.1, a.2), sd)[1], a.3), day)),
                -- the daily limit IN FORCE that day: a.5 before the change, a.2 after
                sim_money(toUInt64(round(multiIf(
                    -- BUSINESS / CORPORATE: the limit is "soft", going over it is possible (and billed). ~3% of days,
                    -- ~25% before a limit increase (the customer asked for more because they kept going over)
                    if(day <= a.4, a.5, a.2) > 15000 AND sim_random(id, day, 'peak') < if(day <= a.4, 0.25, 0.03),
                        if(day <= a.4, a.5, a.2) * 100 * (1.02 + 0.25 * sim_random(id, day, 'size')),
                    if(day <= a.4, a.5, a.2) > 15000,
                        arraySum(arrayMap(s -> sim_amount(s, a.1, a.2), sd)) * 1.05,
                    -- CONSUMER: the authorization is declined at the limit, it is never exceeded
                    least(arraySum(arrayMap(s -> sim_amount(s, a.1, a.2), sd)) * 1.05,
                          if(day <= a.4, a.5, a.2) * 98.)))))
            )
        ), ids, attrs, seeds)
    ), 'Tuple(header Tuple(sender String, receiverType String, receiverId String, flowCode String, fileId String, cycle String, format String),
              records Array(Tuple(cardId String, period Tuple(startDate String, endDate String), currency String,
                                  authorized Tuple(peakTs String, amount String))))')) AS payload
FROM numbers({start:UInt32}, {n:UInt32})
SETTINGS max_block_size = 2;   -- 2 files per block: each file weighs ~2 MB of JSON, memory stays low whatever the number of files


-- Let's test: when do 20,000 consumer cards pay on a Thursday?
--  bar() draws a text bar proportional to the value: a chart
--  right in the result.
--  What to look for: in store, the lunch peak and the bigger early evening peak;
--  online, a single peak around 9pm.
SELECT
    toHour(ts, 'Europe/Paris')        AS hour,
    countIf(NOT is_ecom)              AS in_store,
    countIf(is_ecom)                  AS online,
    bar(in_store, 0, 6000, 30)        AS in_store_chart
FROM
(
    SELECT
        arrayJoin(sim_day_seeds(sim_card_id(number), 'CONSUMER', toDate('2026-10-15'))) AS seed,
        sim_is_ecom(seed, 0.3)                                                          AS is_ecom,
        sim_txn_ts(seed, 'CONSUMER', is_ecom, toDate('2026-10-15'))                     AS ts
    FROM numbers(20000)
)
GROUP BY hour
ORDER BY hour;

--  The amounts: many small payments, a few large ones (card with a 2,000 EUR daily limit)
SELECT
    round(quantile(0.5)(amount), 2)  AS median_eur,
    round(avg(amount), 2)            AS average_eur,
    round(quantile(0.99)(amount), 2) AS p99_eur,
    max(amount)                      AS max_eur
FROM (SELECT sim_amount(cityHash64(number), 'CONSUMER', 2000) / 100 AS amount FROM numbers(100000));

-- The day of the clock change (October 25) lasts 25 hours
--  The business day runs from midnight to midnight, Paris time: on October 25,
--  the night lasts one hour longer.
SELECT day, dateDiff('hour', toDateTime(day, 'Europe/Paris'), toDateTime(day + 1, 'Europe/Paris')) AS hours_in_the_day
FROM (SELECT toDate('2026-10-24') + number AS day FROM numbers(3));

--  One file, to see what it looks like (the first 700 characters)
SELECT file_name, ingested_at, substring(payload, 1, 700) AS json_start
FROM simulator.clearing_files(start = 0, n = 1);
