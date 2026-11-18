-- =====================================================================
--  MODULE 1 · Fundamentals: databases, MergeTree and reference data
-- =====================================================================
--  We create the 4 layers of the pipeline and the reference data:
--    ref     → countries, cities, merchant categories, merchants, issuing banks, cards
--    bronze  → raw JSON files, as received
--    silver  → typed, cleaned, deduplicated transactions
--    gold    → KPIs ready for the dashboards
--
--  A ClickHouse "database" is just a namespace: it costs nothing
--  and is used to organize tables and to grant rights per layer.
--
--  Nothing is downloaded: every table below is built by a SQL statement.
--  The banks, merchants and cards are fictional. Countries, cities and merchant
--  category codes (ISO 18245) are real; city populations are rounded and only
--  serve as weights for the simulation.
-- =====================================================================


-- STEP 1 · The databases (one per layer)
CREATE DATABASE IF NOT EXISTS ref;
CREATE DATABASE IF NOT EXISTS bronze;
CREATE DATABASE IF NOT EXISTS silver;
CREATE DATABASE IF NOT EXISTS gold;
CREATE DATABASE IF NOT EXISTS simulator;   -- the workshop's data generator


-- STEP 2 · A technical user for the dictionaries (module 4)
--  In the Cloud console, a dictionary that reads a local table
--  must declare a user and a password. We keep it limited:
--  local connection only, read-only on the reference data.
CREATE USER IF NOT EXISTS dict_reader IDENTIFIED BY 'Dict_Workshop_2026!' HOST LOCAL;
GRANT SELECT ON ref.* TO dict_reader;
GRANT SELECT ON simulator.* TO dict_reader;


-- STEP 3 · Our first MergeTree tables: countries and cities
--  MergeTree is the core ClickHouse engine. Two things to remember:
--    · ORDER BY sets the physical order of rows on disk AND the primary
--      index. It cannot be changed later: choose it from the most
--      frequent filters (rule schema-pk-plan-before-creation).
--    · each column is stored and compressed separately (columnar storage):
--      a query only reads the columns it uses.
CREATE OR REPLACE TABLE ref.country
(
    country_code  String,                   -- ISO 3166 alpha-2, e.g. FR
    name          String,
    region        LowCardinality(String),   -- 7 distinct values: stored once, then as numbers (rule: fewer than 10,000 values)
    currency      LowCardinality(String)    -- ISO 4217, e.g. EUR
)
ENGINE = MergeTree
ORDER BY country_code;

INSERT INTO ref.country VALUES
    ('FR', 'France',               'Western Europe',  'EUR'),
    ('DE', 'Germany',              'Western Europe',  'EUR'),
    ('NL', 'Netherlands',          'Western Europe',  'EUR'),
    ('BE', 'Belgium',              'Western Europe',  'EUR'),
    ('CH', 'Switzerland',          'Western Europe',  'CHF'),
    ('AT', 'Austria',              'Western Europe',  'EUR'),
    ('GB', 'United Kingdom',       'UK and Ireland',  'GBP'),
    ('IE', 'Ireland',              'UK and Ireland',  'EUR'),
    ('IT', 'Italy',                'Southern Europe', 'EUR'),
    ('ES', 'Spain',                'Southern Europe', 'EUR'),
    ('PT', 'Portugal',             'Southern Europe', 'EUR'),
    ('GR', 'Greece',               'Southern Europe', 'EUR'),
    ('SE', 'Sweden',               'Nordics',         'SEK'),
    ('NO', 'Norway',               'Nordics',         'NOK'),
    ('DK', 'Denmark',              'Nordics',         'DKK'),
    ('FI', 'Finland',              'Nordics',         'EUR'),
    ('PL', 'Poland',               'Central and Eastern Europe', 'PLN'),
    ('CZ', 'Czechia',              'Central and Eastern Europe', 'CZK'),
    ('RO', 'Romania',              'Central and Eastern Europe', 'RON'),
    ('HU', 'Hungary',              'Central and Eastern Europe', 'HUF'),
    ('TR', 'Türkiye',              'Middle East',     'TRY'),
    ('AE', 'United Arab Emirates', 'Middle East',     'AED'),
    ('SA', 'Saudi Arabia',         'Middle East',     'SAR'),
    ('IL', 'Israel',               'Middle East',     'ILS'),
    ('EG', 'Egypt',                'Africa',          'EGP'),
    ('ZA', 'South Africa',         'Africa',          'ZAR'),
    ('NG', 'Nigeria',              'Africa',          'NGN'),
    ('KE', 'Kenya',                'Africa',          'KES'),
    ('MA', 'Morocco',              'Africa',          'MAD');

--  The cities: the finest level of the geography. The population (rounded) is the
--  weight used to place cards and merchants: a big city gets more of them.
CREATE OR REPLACE TABLE ref.city
(
    city_code     String,                   -- country + 3 letters, e.g. FR-PAR
    name          String,
    country_code  LowCardinality(String),
    population    UInt32                    -- the smallest integer type that fits
)
ENGINE = MergeTree
ORDER BY city_code;

INSERT INTO ref.city VALUES
    ('FR-PAR', 'Paris', 'FR', 2100000),         ('FR-MRS', 'Marseille', 'FR', 870000),     ('FR-LYS', 'Lyon', 'FR', 520000),          ('FR-TLS', 'Toulouse', 'FR', 500000),
    ('DE-BER', 'Berlin', 'DE', 3700000),        ('DE-HAM', 'Hamburg', 'DE', 1900000),      ('DE-MUC', 'Munich', 'DE', 1500000),       ('DE-FRA', 'Frankfurt', 'DE', 770000),
    ('NL-AMS', 'Amsterdam', 'NL', 920000),      ('NL-RTM', 'Rotterdam', 'NL', 660000),     ('NL-HAG', 'The Hague', 'NL', 560000),     ('NL-UTC', 'Utrecht', 'NL', 370000),
    ('BE-BRU', 'Brussels', 'BE', 1240000),      ('BE-ANR', 'Antwerp', 'BE', 530000),       ('BE-GNE', 'Ghent', 'BE', 265000),         ('BE-LGG', 'Liège', 'BE', 195000),
    ('CH-ZRH', 'Zurich', 'CH', 440000),         ('CH-GVA', 'Geneva', 'CH', 205000),        ('CH-BSL', 'Basel', 'CH', 175000),         ('CH-LSN', 'Lausanne', 'CH', 140000),
    ('AT-VIE', 'Vienna', 'AT', 1980000),        ('AT-GRZ', 'Graz', 'AT', 300000),          ('AT-LNZ', 'Linz', 'AT', 210000),          ('AT-SZG', 'Salzburg', 'AT', 155000),
    ('GB-LON', 'London', 'GB', 8900000),        ('GB-BHM', 'Birmingham', 'GB', 1150000),   ('GB-MAN', 'Manchester', 'GB', 570000),    ('GB-EDI', 'Edinburgh', 'GB', 520000),
    ('IE-DUB', 'Dublin', 'IE', 590000),         ('IE-ORK', 'Cork', 'IE', 225000),          ('IE-LMK', 'Limerick', 'IE', 100000),      ('IE-GWY', 'Galway', 'IE', 85000),
    ('IT-ROM', 'Rome', 'IT', 2750000),          ('IT-MIL', 'Milan', 'IT', 1370000),        ('IT-NAP', 'Naples', 'IT', 910000),        ('IT-TRN', 'Turin', 'IT', 850000),
    ('ES-MAD', 'Madrid', 'ES', 3300000),        ('ES-BCN', 'Barcelona', 'ES', 1650000),    ('ES-VLC', 'Valencia', 'ES', 800000),      ('ES-SVQ', 'Seville', 'ES', 680000),
    ('PT-LIS', 'Lisbon', 'PT', 545000),         ('PT-OPO', 'Porto', 'PT', 230000),         ('PT-BGZ', 'Braga', 'PT', 195000),         ('PT-CBR', 'Coimbra', 'PT', 140000),
    ('GR-ATH', 'Athens', 'GR', 640000),         ('GR-SKG', 'Thessaloniki', 'GR', 320000),  ('GR-GPA', 'Patras', 'GR', 170000),        ('GR-HER', 'Heraklion', 'GR', 180000),
    ('SE-STO', 'Stockholm', 'SE', 980000),      ('SE-GOT', 'Gothenburg', 'SE', 600000),    ('SE-MMX', 'Malmö', 'SE', 360000),         ('SE-UPP', 'Uppsala', 'SE', 245000),
    ('NO-OSL', 'Oslo', 'NO', 710000),           ('NO-BGO', 'Bergen', 'NO', 290000),        ('NO-TRD', 'Trondheim', 'NO', 215000),     ('NO-SVG', 'Stavanger', 'NO', 150000),
    ('DK-CPH', 'Copenhagen', 'DK', 660000),     ('DK-AAR', 'Aarhus', 'DK', 290000),        ('DK-ODE', 'Odense', 'DK', 185000),        ('DK-AAL', 'Aalborg', 'DK', 120000),
    ('FI-HEL', 'Helsinki', 'FI', 670000),       ('FI-ESP', 'Espoo', 'FI', 310000),         ('FI-TMP', 'Tampere', 'FI', 255000),       ('FI-TKU', 'Turku', 'FI', 200000),
    ('PL-WAW', 'Warsaw', 'PL', 1860000),        ('PL-KRK', 'Kraków', 'PL', 800000),        ('PL-LCJ', 'Łódź', 'PL', 660000),          ('PL-WRO', 'Wrocław', 'PL', 670000),
    ('CZ-PRG', 'Prague', 'CZ', 1380000),        ('CZ-BRQ', 'Brno', 'CZ', 400000),          ('CZ-OSR', 'Ostrava', 'CZ', 280000),       ('CZ-PLZ', 'Plzeň', 'CZ', 180000),
    ('RO-BUH', 'Bucharest', 'RO', 1720000),     ('RO-CLJ', 'Cluj-Napoca', 'RO', 290000),   ('RO-TSR', 'Timișoara', 'RO', 250000),     ('RO-IAS', 'Iași', 'RO', 270000),
    ('HU-BUD', 'Budapest', 'HU', 1690000),      ('HU-DEB', 'Debrecen', 'HU', 200000),      ('HU-SZE', 'Szeged', 'HU', 160000),        ('HU-MCQ', 'Miskolc', 'HU', 145000),
    ('TR-IST', 'Istanbul', 'TR', 15700000),     ('TR-ANK', 'Ankara', 'TR', 5800000),       ('TR-IZM', 'Izmir', 'TR', 4400000),        ('TR-BUR', 'Bursa', 'TR', 3200000),
    ('AE-DXB', 'Dubai', 'AE', 3600000),         ('AE-AUH', 'Abu Dhabi', 'AE', 1500000),    ('AE-SHJ', 'Sharjah', 'AE', 1400000),      ('AE-AAN', 'Al Ain', 'AE', 770000),
    ('SA-RUH', 'Riyadh', 'SA', 7000000),        ('SA-JED', 'Jeddah', 'SA', 3700000),       ('SA-MKK', 'Mecca', 'SA', 2400000),        ('SA-DMM', 'Dammam', 'SA', 1500000),
    ('IL-TLV', 'Tel Aviv', 'IL', 470000),       ('IL-JRS', 'Jerusalem', 'IL', 980000),     ('IL-HFA', 'Haifa', 'IL', 290000),         ('IL-BEV', 'Beersheba', 'IL', 215000),
    ('EG-CAI', 'Cairo', 'EG', 10000000),        ('EG-ALY', 'Alexandria', 'EG', 5400000),   ('EG-GIZ', 'Giza', 'EG', 4400000),         ('EG-LXR', 'Luxor', 'EG', 420000),
    ('ZA-JNB', 'Johannesburg', 'ZA', 5600000),  ('ZA-CPT', 'Cape Town', 'ZA', 4700000),    ('ZA-DUR', 'Durban', 'ZA', 3700000),       ('ZA-PRY', 'Pretoria', 'ZA', 2500000),
    ('NG-LOS', 'Lagos', 'NG', 15000000),        ('NG-KAN', 'Kano', 'NG', 4100000),         ('NG-IBA', 'Ibadan', 'NG', 3600000),       ('NG-ABV', 'Abuja', 'NG', 3800000),
    ('KE-NBO', 'Nairobi', 'KE', 4400000),       ('KE-MBA', 'Mombasa', 'KE', 1200000),      ('KE-KIS', 'Kisumu', 'KE', 400000),        ('KE-NUU', 'Nakuru', 'KE', 570000),
    ('MA-CAS', 'Casablanca', 'MA', 3700000),    ('MA-RBA', 'Rabat', 'MA', 580000),         ('MA-RAK', 'Marrakesh', 'MA', 930000),     ('MA-FEZ', 'Fes', 'MA', 1150000);

SELECT count() AS n_cities, uniqExact(country_code) AS n_countries, sum(population) AS total_population FROM ref.city;
-- What to look for: 116 cities in 29 countries of Europe, the Middle East and Africa.


-- STEP 4 · Merchant category codes (MCC, ISO 18245)
--  Every card payment carries the 4-digit category of the merchant.
CREATE OR REPLACE TABLE ref.mcc
(
    mcc         UInt16,
    label       String,
    short_name  String,                    -- used to build merchant names
    category    LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY mcc;

INSERT INTO ref.mcc VALUES
    (5411, 'Grocery stores and supermarkets', 'Grocery',           'Everyday'),
    (5912, 'Drug stores and pharmacies',      'Pharmacy',          'Everyday'),
    (5812, 'Restaurants',                     'Restaurant',        'Food and drink'),
    (5814, 'Fast food',                       'Fast Food',         'Food and drink'),
    (5541, 'Service stations',                'Fuel',              'Mobility'),
    (4111, 'Local commuter transport',        'Transit',           'Mobility'),
    (4121, 'Taxis and ride hailing',          'Taxi',              'Mobility'),
    (5311, 'Department stores',               'Department Store',  'Retail'),
    (5651, 'Family clothing stores',          'Fashion',           'Retail'),
    (5732, 'Electronics stores',              'Electronics',       'Retail'),
    (5942, 'Book stores',                     'Books',             'Retail'),
    (5200, 'Home supply stores',              'Home and DIY',      'Retail'),
    (5999, 'Miscellaneous retail',            'Shop',              'Retail'),
    (4511, 'Airlines',                        'Airline',           'Travel'),
    (7011, 'Hotels and lodging',              'Hotel',             'Travel'),
    (7832, 'Cinemas',                         'Cinema',            'Leisure'),
    (4900, 'Utilities',                       'Utilities',         'Bills'),
    (7399, 'Business services',               'Business Services', 'Business'),
    (5045, 'Computers and software',          'IT Supplies',       'Business'),
    (6011, 'ATM cash withdrawal',             'ATM',               'Cash');


-- STEP 5 · The issuing banks that receive the files
--  Each file from the card scheme is addressed to one issuer (receiverId).
--  The six banks are fictional. Each one issues its cards in its home country.
CREATE OR REPLACE TABLE ref.issuer
(
    issuer_id     String,
    name          String,
    country_code  String
)
ENGINE = MergeTree
ORDER BY issuer_id;

INSERT INTO ref.issuer VALUES
    ('488903', 'Lumière Banque',    'FR'),
    ('488904', 'Rheingold Bank',    'DE'),
    ('488905', 'Thames Union Bank', 'GB'),
    ('488906', 'Banco Meseta',      'ES'),
    ('488907', 'Banca Adriatica',   'IT'),
    ('488908', 'Nordlys Bank',      'SE');

--  The 20 files of a day (batches of 5,000 cards) are split between the
--  6 banks, Lumière Banque taking the largest share (12 of 20). An issuer
--  receives ONLY its own cards: we take this into account in the draw.
--  CREATE FUNCTION creates a SQL function (UDF): a named expression,
--  reusable in every query. Here: batch number → issuer.
CREATE OR REPLACE FUNCTION sim_issuer AS (batch) ->
    ['488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903', '488903',
     '488903', '488903', '488904', '488904', '488905', '488905', '488906', '488906', '488907', '488908'][batch + 1];

SELECT sim_issuer(batch) AS issuer_id, count() AS batches, count() * 5000 AS cards
FROM (SELECT number AS batch FROM numbers(20))
GROUP BY issuer_id
ORDER BY issuer_id;


-- STEP 6 · 50,000 merchants, placed in proportion to the population
--  Each merchant is linked to a city. Trick: an ASOF JOIN on the cumulative population.
--    1. sort the cities and accumulate their population (window function);
--    2. each merchant gets a "ticket" between 0 and the total population;
--    3. ASOF JOIN finds the FIRST city whose cumulative value exceeds the ticket.
--  A populous city covers a large cumulative interval: it gets more merchants.
--  Here the tickets are evenly spaced: merchant numbers follow the order of the
--  cities, so the merchants of one country are numbered in one continuous range
--  (the simulator uses that range to pick a merchant "at home").
CREATE OR REPLACE TABLE ref.merchant
(
    merchant_id   UInt32,
    name          String,
    mcc           UInt16,
    city_code     LowCardinality(String),
    country_code  LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY merchant_id;

INSERT INTO ref.merchant
WITH
    cumulative AS
    (
        SELECT 1 AS k, city_code, name AS city, country_code,     -- k: ASOF JOIN needs one equality column
               sum(population) OVER (ORDER BY city_code ROWS UNBOUNDED PRECEDING) AS cumulative_pop
        FROM ref.city
    ),
    (SELECT sum(population) FROM ref.city) AS total_pop,
    draw AS
    (
        SELECT
            1                                                     AS k,
            number                                                AS n,
            toUInt64(intDiv(number * total_pop, 50000))           AS ticket,
            -- the category: everyday shops are the most common
            [5411, 5411, 5411, 5411, 5812, 5812, 5812, 5814, 5814, 5814, 5541, 5541, 4111, 4121, 5311,
             5651, 5651, 5732, 5912, 5912, 5942, 5200, 5999, 5999, 4511, 7011, 7011, 7832, 4900, 7399,
             5045, 6011][1 + cityHash64(number, 'mcc') % 32]      AS mcc,
            ['Blue', 'Golden', 'Royal', 'Little', 'Grand', 'Green', 'Silver', 'Urban', 'Sunny', 'Old Town',
             'Central', 'Northern'][1 + cityHash64(number, 'adj') % 12]  AS adjective,
            ['Harbor', 'Garden', 'Bridge', 'Market', 'Corner', 'Square', 'Station', 'Mill', 'Gate',
             'Park'][1 + cityHash64(number, 'noun') % 10]         AS noun
        FROM numbers(50000)
    )
SELECT
    toUInt32(1000000 + t.n)                                       AS merchant_id,
    concat(t.adjective, ' ', t.noun, ' ', m.short_name, ' ', c.city) AS name,
    t.mcc,
    c.city_code,
    c.country_code
FROM draw AS t
INNER JOIN ref.mcc AS m ON m.mcc = t.mcc
ASOF JOIN cumulative AS c ON t.k = c.k AND t.ticket < c.cumulative_pop;   -- the 1st city whose cumulative value exceeds the ticket

SELECT country_code, count() AS merchants, min(merchant_id) AS first_id, max(merchant_id) AS last_id
FROM ref.merchant
GROUP BY country_code
ORDER BY merchants DESC
LIMIT 10;
-- What to look for: 50,000 rows generated and joined well under a second, and one
-- continuous range of merchant numbers per country.

SELECT merchant_id, name, mcc, city_code FROM ref.merchant ORDER BY cityHash64(merchant_id) LIMIT 5;


-- STEP 7 · The card portfolio: 1 million generated cards
--  Each card has a home city, drawn at random in proportion to the population,
--  with the same ASOF JOIN, this time with a random ticket:
--    · the first 100,000 cards (the ones in the JSON files of module 2) are drawn
--      in the home country of their issuing bank;
--    · the other 900,000 across all 29 countries (the scale-up of module 6).
--  The portfolio is simulated: ~98.7% CONSUMER cards (daily limit up to 15,000 EUR),
--  ~1.1% BUSINESS cards, ~0.2% CORPORATE cards. Most consumer cards have a
--  daily limit of 1,000 or 2,000 EUR.
CREATE OR REPLACE TABLE ref.card
(
    card_id          UInt64,                  -- 16 digits fit in 8 bytes
    issuer_id        LowCardinality(String),  -- '000000' = another issuer (the 900,000 cards of module 6)
    city_code        LowCardinality(String),  -- home city of the cardholder
    segment          LowCardinality(String),  -- CONSUMER / BUSINESS / CORPORATE
    product          LowCardinality(String),  -- DEBIT / CREDIT / PREPAID / BUSINESS_DEBIT / BUSINESS_CREDIT / CORPORATE
    daily_limit_eur  UInt32,                  -- spending limit per day, in EUR
    ecom_share       Float32,                 -- share of the card's payments made online (0 = never)
    issued_date      Date
)
ENGINE = MergeTree
ORDER BY card_id
SETTINGS min_bytes_for_wide_part = 0;   -- one column = one file, to read compression column by column (step 9)

INSERT INTO ref.card
WITH
    zones AS
    (
        -- 'EMEA' = all countries, otherwise the home country of one of the 6 issuers
        SELECT 'EMEA' AS zone, city_code, population FROM ref.city
        UNION ALL
        SELECT toString(country_code), city_code, population FROM ref.city
        WHERE country_code IN (SELECT country_code FROM ref.issuer)
    ),
    cumulative AS
    (
        SELECT zone, city_code,
               sum(population) OVER (PARTITION BY zone ORDER BY city_code ROWS UNBOUNDED PRECEDING) AS cumulative_pop
        FROM zones
    ),
    zone_pop AS (SELECT zone, sum(population) AS pop FROM zones GROUP BY zone),
    draw AS
    (
        SELECT
            z.zone                                                    AS zone,
            n.number                                                  AS n,
            if(n.number < 100000, sim_issuer(intDiv(n.number, 5000)), '000000')   AS issuer_id,
            4000000000000000 + n.number * 4093 + cityHash64(n.number) % 4093      AS card_id,
            cityHash64(n.number, 'city') % z.pop                       AS ticket,
            cityHash64(n.number, 'segment') % 1000                     AS r_seg,
            cityHash64(n.number, 'detail')  % 1000                     AS r_det,
            cityHash64(n.number, 'ecom')    % 1000                     AS r_ecom
        FROM numbers(1000000) AS n
        LEFT JOIN ref.issuer AS i ON i.issuer_id = if(n.number < 100000, sim_issuer(intDiv(n.number, 5000)), '')
        INNER JOIN zone_pop AS z ON z.zone = if(n.number < 100000, i.country_code, 'EMEA')
    )
SELECT
    t.card_id,
    t.issuer_id,
    c.city_code,
    multiIf(t.r_seg < 987, 'CONSUMER', t.r_seg < 998, 'BUSINESS', 'CORPORATE')        AS segment,
    multiIf(segment = 'CONSUMER', ['DEBIT', 'DEBIT', 'DEBIT', 'CREDIT', 'CREDIT', 'PREPAID'][1 + t.r_det % 6],
            segment = 'BUSINESS', ['BUSINESS_DEBIT', 'BUSINESS_CREDIT'][1 + t.r_det % 2],
            'CORPORATE')                                                              AS product,
    toUInt32(multiIf(
            segment = 'CONSUMER', multiIf(t.r_det % 100 < 4, 300, t.r_det % 100 < 44, 1000, t.r_det % 100 < 77, 2000,
                                          t.r_det % 100 < 90, 3000, t.r_det % 100 < 95, 5000, t.r_det % 100 < 98, 7500,
                                          t.r_det % 100 < 99, 10000, 15000),              -- 40% at 1,000 EUR, 33% at 2,000 EUR
            segment = 'BUSINESS', 16000 + (t.r_det % 214) * 200,                         -- 16,000 to 58,600 EUR
            60000 + t.r_det * 200))                                                       AS daily_limit_eur,   -- 60,000 to 259,800 EUR
    multiIf(segment = 'CONSUMER'  AND t.r_ecom < 600, toFloat32([0.15, 0.3, 0.45, 0.6][1 + t.r_ecom % 4]),   -- 60% of consumers pay online
            segment = 'BUSINESS'  AND t.r_ecom < 500, toFloat32([0.2, 0.35, 0.5][1 + t.r_ecom % 3]),
            segment = 'CORPORATE' AND t.r_ecom < 800, toFloat32([0.3, 0.45, 0.6][1 + t.r_ecom % 3]),
            toFloat32(0))                                                              AS ecom_share,
    toDate('2019-01-01') + cityHash64(t.n, 'date') % 2800                             AS issued_date
FROM draw AS t
ASOF JOIN cumulative AS c ON t.zone = c.zone AND t.ticket < c.cumulative_pop;   -- the 1st city of the zone whose cumulative value exceeds the ticket

SELECT segment, product, count() AS n_cards, round(avg(daily_limit_eur)) AS avg_limit_eur, countIf(ecom_share > 0) AS n_online
FROM ref.card
GROUP BY segment, product
ORDER BY n_cards DESC;
-- What to look for: a million rows generated and joined in about a second.
-- countIf only counts the rows that match the condition: no need for CASE WHEN.

--  The 100,000 cards of the JSON files do live in the country of their issuer:
SELECT i.name AS issuer, ci.country_code, count() AS cards
FROM ref.card AS c
INNER JOIN ref.city   AS ci ON ci.city_code = c.city_code
INNER JOIN ref.issuer AS i  ON i.issuer_id = c.issuer_id
GROUP BY issuer, ci.country_code
ORDER BY cards DESC;
-- What to look for: 60,000 cards at Lumière Banque (FR), 10,000 each at Rheingold Bank (DE),
-- Thames Union Bank (GB) and Banco Meseta (ES), 5,000 each at Banca Adriatica (IT) and Nordlys Bank (SE).


-- STEP 8 · The daily limit history (for module 4)
--  ~3% of cards had their daily limit raised during October.
--  One row per validity period [valid_from, valid_to].
--  ARRAY JOIN "unfolds" an array: one row with a 2-element array
--  becomes 2 rows. It is the central tool for reading clearing JSON (module 3).
CREATE OR REPLACE TABLE ref.card_limit_history
(
    card_id          UInt64,
    valid_from       Date,
    valid_to         Date,
    daily_limit_eur  UInt32
)
ENGINE = MergeTree
ORDER BY (card_id, valid_from);

INSERT INTO ref.card_limit_history
SELECT card_id, valid_from, valid_to, daily_limit_eur
FROM
(
    SELECT
        card_id,
        daily_limit_eur,
        issued_date,
        cityHash64(card_id, 'chgt') % 100 < 3 AS changed,                 -- the cardholder asked for a higher limit
        toDate('2026-10-05') + cityHash64(card_id, 'j') % 20 AS change_date
    FROM ref.card
)
ARRAY JOIN
    if(changed, [issued_date, change_date], [issued_date])                                       AS valid_from,
    if(changed, [change_date - 1, toDate('2099-12-31')], [toDate('2099-12-31')])                 AS valid_to,
    if(changed, [toUInt32(intDiv(daily_limit_eur * 2, 3)), daily_limit_eur], [daily_limit_eur])  AS daily_limit_eur;

SELECT count() AS row_count, uniqExact(card_id) AS cards, countIf(valid_to < '2099-01-01') AS changes
FROM ref.card_limit_history;


-- STEP 9 · Under the hood: parts, compression, index
--  Each INSERT writes a "part": a small, immutable, already sorted set of files.
--  In the background, ClickHouse merges the parts together, hence the name
--  MergeTree. system.parts shows the actual state of the storage.
SELECT table, count() AS n_parts, sum(rows) AS row_count,
       formatReadableSize(sum(data_uncompressed_bytes)) AS raw,
       formatReadableSize(sum(data_compressed_bytes))   AS compressed,
       round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'ref' AND active
GROUP BY table
ORDER BY row_count DESC;

--  Compression column by column
--  Watch out: in Cloud, a part under 1 GB is "compact" (all the
--  columns in a single file) and its per-column sizes show as 0.
--  ref.card is created with min_bytes_for_wide_part = 0 so we can read them here.
--  What to look for: the LowCardinality columns (segment, product, issuer_id) compress
--  much better than the card number.
SELECT name, type,
       formatReadableSize(data_compressed_bytes)   AS compressed,
       formatReadableSize(data_uncompressed_bytes) AS raw,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'ref' AND table = 'card'
ORDER BY data_compressed_bytes DESC;

--  The sparse index: ClickHouse does not index every row, but one row out of
--  8192 (a "granule"). So the index fits in memory, even for billions
--  of rows. For a lookup, it finds the relevant granules and reads only those.
EXPLAIN indexes = 1
SELECT * FROM ref.card WHERE card_id = 4000000000006899;

--  Compare: filter on the key (fast) vs off the key (full scan)
SELECT * FROM ref.card WHERE card_id = 4000000000006899;     -- filter on the key: 1 granule read
SELECT count() FROM ref.card WHERE city_code = 'FR-LYS';      -- Lyon, off the key: the whole table is read
-- What to look for: "rows read" at the bottom of the console. 8,192 rows read for the first one,
-- 1,000,000 for the second. On 1 B rows, the gap would be the same in proportion.


-- CHECKPOINT MODULE 1
--  Every column must show OK. A FAIL: rerun the file (it is idempotent).
SELECT
    if((SELECT count() FROM ref.city) = 116, 'OK', 'FAIL')                 AS cities,
    if((SELECT count() FROM ref.merchant) = 50000, 'OK', 'FAIL')           AS merchants,
    if((SELECT count() FROM ref.card) = 1000000, 'OK', 'FAIL')             AS cards,
    if((SELECT count() FROM ref.card_limit_history) > 1000000, 'OK', 'FAIL') AS history,
    if((SELECT count() FROM ref.issuer) = 6, 'OK', 'FAIL')                 AS issuers,
    if((SELECT count() FROM ref.card AS c INNER JOIN ref.city AS ci ON ci.city_code = c.city_code
        INNER JOIN ref.issuer AS i ON i.issuer_id = c.issuer_id
        WHERE ci.country_code = i.country_code) = 100000, 'OK', 'FAIL')    AS cards_at_issuer
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whatever the replica
