-- =====================================================================
--  MODULE 4 · Dictionaries: reference data in memory
-- =====================================================================
--  A dictionary = a key → values table loaded into RAM.
--  dictGet() replaces a join: an O(1) lookup per row.
--  Why is it better than a repeated JOIN? A JOIN rebuilds a hash table
--  on EVERY query. The dictionary builds it once, keeps it in memory
--  and reloads it according to LIFETIME (rule query-join-use-dictionaries).
--  It does not use the query's memory, which protects large scans.
-- =====================================================================


-- STEP 1 · The merchant dictionary (numeric key: HASHED, the fastest)
--  SOURCE says where to read the data, LAYOUT how to store it in memory,
--  LIFETIME when to reload it. In Cloud, the CLICKHOUSE source must declare
--  a user: we use dict_reader, which is read-only (module 1).
CREATE OR REPLACE DICTIONARY ref.dict_merchant
(
    merchant_id   UInt64,
    name          String,
    mcc           UInt16,
    city_code     String,
    country_code  String
)
PRIMARY KEY merchant_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'merchant' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED())
LIFETIME(MIN 3600 MAX 7200);          -- reloaded every 1 to 2 hours


-- STEP 2 · The card dictionary (many attributes: HASHED_ARRAY)
CREATE OR REPLACE DICTIONARY ref.dict_card
(
    card_id          UInt64,
    issuer_id        String,
    city_code        String,
    segment          String,
    product          String,
    daily_limit_eur  UInt32,
    ecom_share       Float32
)
PRIMARY KEY card_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'card' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED_ARRAY())                -- a HASHED variant, leaner when there are many attributes
LIFETIME(MIN 3600 MAX 7200);


-- STEP 3 · The daily limit "as of" a date (RANGE_HASHED)
--  For a key AND a date, it finds the row that was valid at that moment.
--  Exactly what we need to compare an authorized amount with the limit
--  on the day of the payment, not with the current limit.
CREATE OR REPLACE DICTIONARY ref.dict_limit_asof
(
    card_id          UInt64,
    valid_from       Date,
    valid_to         Date,
    daily_limit_eur  UInt32
)
PRIMARY KEY card_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'card_limit_history' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(RANGE_HASHED())
RANGE(MIN valid_from MAX valid_to)
LIFETIME(MIN 3600 MAX 7200);


-- STEP 4 · Text keys: cities, countries, issuers, categories (COMPLEX_KEY_HASHED)
CREATE OR REPLACE DICTIONARY ref.dict_city (city_code String, name String, country_code String, population UInt32)
PRIMARY KEY city_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'city' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_country (country_code String, name String, region String, currency String)
PRIMARY KEY country_code
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'country' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_issuer (issuer_id String, name String, country_code String)
PRIMARY KEY issuer_id
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'issuer' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(COMPLEX_KEY_HASHED()) LIFETIME(86400);

CREATE OR REPLACE DICTIONARY ref.dict_mcc (mcc UInt64, label String, short_name String, category String)
PRIMARY KEY mcc
SOURCE(CLICKHOUSE(DB 'ref' TABLE 'mcc' USER 'dict_reader' PASSWORD 'Dict_Workshop_2026!'))
LAYOUT(HASHED()) LIFETIME(86400);


-- STEP 5 · Usage: one card, its full profile, in one row
--  The dictGets chain together: card → city → country. No JOIN.
SELECT
    sim_card_id(648)                                                                   AS card_id,
    dictGet('ref.dict_card', 'segment', card_id)                                      AS segment,
    dictGet('ref.dict_card', 'daily_limit_eur', card_id)                              AS limit_current,
    dictGet('ref.dict_issuer', 'name', dictGet('ref.dict_card', 'issuer_id', card_id)) AS issuer,
    dictGet('ref.dict_card', 'city_code', card_id)                                    AS city_code,
    dictGet('ref.dict_city', 'name', city_code)                                       AS city,
    dictGet('ref.dict_country', 'name', dictGet('ref.dict_city', 'country_code', city_code)) AS country;

--  … and one transaction, fully described, still without a JOIN
SELECT
    toTimeZone(ts, 'Europe/Paris')                                                     AS local_time,
    channel, amount_eur,
    dictGet('ref.dict_merchant', 'name', merchant_id)                                  AS merchant,
    dictGet('ref.dict_mcc', 'label', dictGet('ref.dict_merchant', 'mcc', merchant_id)) AS category,
    dictGet('ref.dict_merchant', 'country_code', merchant_id)                          AS merchant_country
FROM silver.transaction FINAL
WHERE card_id = sim_card_id(648) AND day = '2026-10-15'
ORDER BY ts;


-- STEP 6 · A limit that changes over time
--  Take a card whose limit changed on October 15
SELECT card_id, valid_from, valid_to, daily_limit_eur
FROM ref.card_limit_history
WHERE card_id IN (SELECT card_id FROM ref.card_limit_history WHERE valid_to = '2026-10-14' ORDER BY card_id LIMIT 1)
ORDER BY valid_from;

SELECT
    day,
    dictGet('ref.dict_limit_asof', 'daily_limit_eur', p.card_id, day) AS limit_at_date
FROM (SELECT card_id FROM ref.card_limit_history WHERE valid_to = '2026-10-14' ORDER BY card_id LIMIT 1) AS p
CROSS JOIN (SELECT toDate('2026-10-12') + number AS day FROM numbers(5)) AS j;
-- What to look for: on the 15th, the new limit applies. Essential for the
-- over-limit alerts in module 5.


-- STEP 7 · Dictionary vs JOIN: same result, compare the timings
--  Spend of the month by merchant category.
SELECT
    dictGet('ref.dict_mcc', 'label', dictGet('ref.dict_merchant', 'mcc', merchant_id)) AS category,
    round(sum(amount_eur) / 1e6, 2) AS million_eur
FROM silver.transaction
GROUP BY category
ORDER BY million_eur DESC
LIMIT 10;

SELECT
    c.label AS category,
    round(sum(t.amount_eur) / 1e6, 2) AS million_eur
FROM silver.transaction AS t
INNER JOIN ref.merchant AS m ON m.merchant_id = t.merchant_id
INNER JOIN ref.mcc      AS c ON c.mcc = m.mcc
GROUP BY category
ORDER BY million_eur DESC
LIMIT 10;
-- What to look for: same result (grocery stores first). Compare duration and
-- memory at the bottom of the console: the JOIN must first load ref.merchant and ref.mcc into memory,
-- the dictionary does not. On this small table the timings are close; the gap grows with the
-- size of the reference table (try it with the cards: 1 million rows).


-- STEP 8 · Quality: are there cards or merchants missing from the reference data?
--  dictHas returns 0 if the key is absent: a quality check in one line.
SELECT
    countIf(NOT dictHas('ref.dict_card', card_id))                   AS unknown_card_rows,
    countIf(NOT dictHas('ref.dict_merchant', toUInt64(merchant_id))) AS unknown_merchant_rows
FROM silver.transaction;


-- STEP 9 · What it costs in memory
--  What to look for: tens of MB for 1 million cards, a few MB for 50,000 merchants. The "as of"
--  dictionary is bigger because it stores intervals per key.
SELECT name, status, type, element_count, formatReadableSize(bytes_allocated) AS memory, loading_duration
FROM system.dictionaries
WHERE database = 'ref';


-- GOING FURTHER · Fuzzy matching of a typed name against the reference data
--  ngramDistance measures how similar two texts are (0 = identical):
--  it finds "Cluj-Napoca" despite the typos.
SELECT name, city_code, round(ngramDistanceCaseInsensitiveUTF8(replaceAll(name, '-', ' '), 'Kluj Napoka'), 3) AS distance
FROM ref.city
ORDER BY distance ASC
LIMIT 3;

--  The same on 50,000 merchant names, as they would appear on a card statement
SELECT name, merchant_id, round(ngramDistanceCaseInsensitiveUTF8(name, 'GOLDN BRIDGE GROCRY LYON'), 3) AS distance
FROM ref.merchant
ORDER BY distance ASC
LIMIT 3;


-- CHECKPOINT
SELECT
    if((SELECT element_count FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_card') = 1000000, 'OK', 'FAIL') AS dict_card,
    if((SELECT status FROM system.dictionaries WHERE database = 'ref' AND name = 'dict_limit_asof') = 'LOADED', 'OK', 'FAIL') AS dict_asof,
    if(dictGet('ref.dict_city', 'name', 'RO-CLJ') = 'Cluj-Napoca', 'OK', 'FAIL') AS dict_city,
    if(dictGet('ref.dict_merchant', 'country_code', toUInt64(1000000)) != '', 'OK', 'FAIL') AS dict_merchant
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it
