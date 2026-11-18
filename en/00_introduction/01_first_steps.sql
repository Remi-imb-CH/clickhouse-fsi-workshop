-- =====================================================================
--  MODULE 0 · First steps: from numbers() to a real clearing file
-- =====================================================================
--  Key idea: in ClickHouse, a SELECT can MAKE data.
--  We start from nothing and build, step by step, a daily settlement file
--  in the same format as the ones an issuing bank receives from its card scheme.
--
--  How to use it: put the cursor inside a query and press
--  Cmd + Shift + Enter to run it on its own. At the bottom, the
--  console shows the duration, the number of rows read and the volume read:
--  these are the three numbers to watch throughout the workshop.
-- =====================================================================


-- STEP 1 · numbers() is a "table function": it generates rows
--  A table function goes after FROM like a table, but it computes
--  its rows on the fly. numbers(10) returns the integers 0 to 9.
--  We use it to simulate millions of rows without storing anything.
SELECT number
FROM numbers(10);


-- STEP 2 · Apply functions to each row
--  cityHash64 always returns the same result for the same input: it is
--  a reproducible "random", identical for every participant.
--  randCanonical, on the other hand, changes on every run.
SELECT
    number,
    toDate('2026-10-01') + number              AS day,
    cityHash64(number) % 100                   AS deterministic_random,
    round(5 + 120 * randCanonical(), 2)        AS amount_eur
FROM numbers(10);


-- STEP 3 · A realistic 16-digit card identifier
--  A card number (here a token, never a real card number) fits in a UInt64
--  (8 bytes). toString turns it back into the 16-digit text used in the files.
SELECT toString(4000000000000000 + number * 4093 + cityHash64(number) % 4093) AS cardId
FROM numbers(5);


-- STEP 4 · A daily settlement total: a named tuple becomes a JSON object
--  tuple(value AS name, ...) builds a structure; toJSONString turns it
--  into a JSON object whose keys are the names. An array [...] becomes a
--  JSON list. The enable_named_columns_in_function_tuple setting keeps the names.
SELECT toJSONString(tuple(
    toString(4000000000000000 + 4093)                          AS cardId,
    'CLEARED'                                                  AS stage,
    tuple('2026-10-01' AS startDate, '2026-10-02' AS endDate) AS period,
    'EUR'                                                      AS currency,
    [tuple('POS' AS channel,
           [tuple('2026-10-01' AS d, '3' AS count, '84.20' AS amount)] AS totals)] AS channels
)) AS record_json
SETTINGS enable_named_columns_in_function_tuple = 1;


-- STEP 5 · A complete file: one header + 1000 card records
--  arrayMap(i -> ..., range(1000)) acts as a loop: it applies
--  the function to each element of the array 0..999 and returns the array
--  of results. A single result row = a whole file.
SELECT toJSONString(tuple(
    tuple('EMEA CARD SWITCH' AS sender, 'ISSUER' AS receiverType,
          '488903' AS receiverId, 'STL01' AS flowCode, 'DAILY' AS cycle,
          'JSON' AS format) AS header,
    arrayMap(i -> tuple(
        toString(4000000000000000 + i * 4093 + cityHash64(i) % 4093) AS cardId,
        'CLEARED' AS stage,
        tuple('2026-10-01' AS startDate, '2026-10-02' AS endDate) AS period,
        'EUR' AS currency,
        [tuple('POS' AS channel,
               [tuple('2026-10-01' AS d, toString(1 + cityHash64(i, 'n') % 5) AS count,
                      toString(round(5 + 120 * (cityHash64(i) % 1000) / 1000, 2)) AS amount)] AS totals)] AS channels
    ), range(1000)) AS records
)) AS daily_settlement_file
SETTINGS enable_named_columns_in_function_tuple = 1;
-- What to look for: paste the result into a JSON viewer. You get exactly
-- the structure of the source format: header, then records > channels > totals.


-- STEP 6 · The teaser: 1 MILLION JSON transactions. How long does it take?
--  Each row builds and serializes a small JSON object. ClickHouse
--  splits numbers() into blocks and processes them on all cores in parallel.
SELECT
    count()                                   AS n_transactions,
    formatReadableSize(sum(length(json)))     AS json_volume
FROM
(
    SELECT toJSONString(tuple(
        toString(4000000000000000 + number * 4093 + cityHash64(number) % 4093) AS cardId,
        'CLEARED' AS stage,
        toString(round(5 + 120 * (cityHash64(number) % 1000) / 1000, 2)) AS amount
    )) AS json
    FROM numbers(1000000)
)
SETTINGS enable_named_columns_in_function_tuple = 1;
-- What to look for: the duration at the bottom of the console. Replace 1000000 with 10000000:
-- the time is roughly multiplied by 10, the speed in rows/s stays stable.
