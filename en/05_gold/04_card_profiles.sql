-- =====================================================================
--  MODULE 5 · Gold (4/4): the spending profile of each card
-- =====================================================================
--  A "features" table for data science (module 8, agent + Run Code).
--  Each card is summarized by a few indicators and by its shape of the day:
--  24 values for weekdays and 24 for weekends, each one the share of the
--  card's payments made during that hour. 8 M transactions become 100,000 rows.
--
--  Good practice: prepare the data in ClickHouse (fast, as close as possible
--  to the data), and send only the small result to the Python model.
-- =====================================================================


-- STEP 1 · The table: one row per card, the shapes in arrays
--  Array(Float32): 24 values in a single column, read in one block.
--  ORDER BY (segment, product, card_id): we often sample by segment.
CREATE OR REPLACE TABLE gold.card_profile
(
    card_id             UInt64,
    segment             LowCardinality(String),
    product             LowCardinality(String),
    daily_limit_eur     UInt32,
    n_txns              UInt32,
    spend_eur           Float64,
    avg_ticket_eur      Float64,
    ecom_share          Float32,
    cross_border_share  Float32,
    weekday_shape       Array(Float32),
    weekend_shape       Array(Float32)
)
ENGINE = MergeTree
ORDER BY (segment, product, card_id);


-- STEP 2 · The computation, in one query
--  The subquery prepares, for each transaction, its local hour and its day type.
--  groupArrayIf gathers the hours of a day type into an array,
--  arrayCount counts how many of them fall in hour h, for h from 0 to 23,
--  and the division turns the counts into shares.
INSERT INTO gold.card_profile
SELECT
    card_id,
    dictGet('ref.dict_card', 'segment', card_id),
    dictGet('ref.dict_card', 'product', card_id),
    dictGet('ref.dict_card', 'daily_limit_eur', card_id),
    count(),
    round(sum(amount), 2),
    round(avg(amount), 2),
    round(countIf(channel = 'ECOM') / count(), 3),
    round(countIf(merchant_country != home_country) / count(), 3),
    arrayMap(h -> toFloat32(round(arrayCount(x -> x = h, groupArrayIf(hour, NOT weekend)) / greatest(1, countIf(NOT weekend)), 3)), range(24)),
    arrayMap(h -> toFloat32(round(arrayCount(x -> x = h, groupArrayIf(hour, weekend)) / greatest(1, countIf(weekend)), 3)), range(24))
FROM
(
    SELECT card_id, channel,
           toFloat64(amount_eur)                                                                        AS amount,
           toHour(ts, 'Europe/Paris')                                                                   AS hour,
           toDayOfWeek(ts, 0, 'Europe/Paris') >= 6                                                      AS weekend,
           dictGet('ref.dict_merchant', 'country_code', toUInt64(merchant_id))                          AS merchant_country,
           dictGet('ref.dict_city', 'country_code', dictGet('ref.dict_card', 'city_code', card_id))     AS home_country
    FROM silver.transaction FINAL
)
GROUP BY card_id;


-- STEP 3 · Comments for the agent (module 8)
ALTER TABLE gold.card_profile
    MODIFY COMMENT 'Spending profile of each card in October 2026, for data science. One row per card with at least one payment.';
ALTER TABLE gold.card_profile
    COMMENT COLUMN segment            'CONSUMER (daily limit up to 15,000 EUR), BUSINESS, CORPORATE',
    COMMENT COLUMN product            'DEBIT, CREDIT, PREPAID, BUSINESS_DEBIT, BUSINESS_CREDIT, CORPORATE',
    COMMENT COLUMN n_txns             'Number of payments of the card over the month',
    COMMENT COLUMN spend_eur          'Total spend of the card over the month, in EUR',
    COMMENT COLUMN avg_ticket_eur     'Average amount of a payment, in EUR',
    COMMENT COLUMN ecom_share         'Share of the payments made online (0 to 1)',
    COMMENT COLUMN cross_border_share 'Share of the payments made at a merchant outside the home country of the card (0 to 1)',
    COMMENT COLUMN weekday_shape      '24 values, from 0h to 23h (Paris time): share of the weekday payments made during each hour',
    COMMENT COLUMN weekend_shape      '24 values, from 0h to 23h (Paris time): share of the weekend payments made during each hour';


-- STEP 4 · The average shapes by segment
--  avgForEach averages arrays position by position: one average shape per segment.
SELECT segment, count() AS cards, round(avg(avg_ticket_eur), 2) AS avg_ticket_eur,
       arrayMap(x -> round(x, 2), avgForEach(weekday_shape)) AS weekday_shape
FROM gold.card_profile
GROUP BY segment;
-- What to look for: the lunch and early evening peaks of consumers, the office hours
-- of business cards, and average tickets that differ by two orders of magnitude.

--  The sample the agent will use: 30 cards per segment, in one query
SELECT segment, product, count() AS cards
FROM (SELECT segment, product FROM gold.card_profile ORDER BY cityHash64(card_id) LIMIT 30 BY segment)
GROUP BY segment, product
ORDER BY segment, product;
-- What to look for: LIMIT 30 BY segment keeps 30 rows per segment value.


-- CHECKPOINT MODULE 5 (4/4)
--  One row per card of the JSON files that paid at least once (nearly all of the 100,000),
--  with 24 values per shape.
SELECT
    if((SELECT count() FROM gold.card_profile) >= 99000, 'OK', 'FAIL') AS profiles,
    if((SELECT min(length(weekday_shape)) FROM gold.card_profile) = 24, 'OK', 'FAIL') AS length_24
SETTINGS select_sequential_consistency = 1;
