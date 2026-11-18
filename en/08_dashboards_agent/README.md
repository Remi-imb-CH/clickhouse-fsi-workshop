# Module 8 · Dashboards, API and ClickHouse Agents

Gold is ready: small tables, sorted by the filters, refreshed every 10 minutes. We expose them in three ways, all from the Cloud console:

| For whom | What | Where |
|---|---|---|
| The card operations team, the product manager | A 5-tile dashboard, filterable by issuing bank and by day | this README, part 1 |
| A bank's portal or mobile back end | An HTTPS API with no SQL on the client side | part 2 |
| Everyone | An agent that answers in English, builds dashboards and does data science | part 3 |

Duration: 1 h. Everything happens in the Cloud console, following the steps below: there is no SQL file to run in this module. Prerequisite: modules 00 to 07 have run on your service.

> The labels below are those of the ClickHouse Cloud console in autumn 2026. Dashboards and ClickHouse Agents are evolving quickly: a label may have moved, the principle stays the same.

The figures given as "expected" are results of the simulated data: they are the same on every service.

---

## 1. The "Card payments · Issuers" dashboard (20 min)

5 tiles, all filterable from the moment they are created:

| # | Tile | Type | Filters |
|---|---|---|---|
| 1 | Spend of the day, hour by hour, in store and online | Line | issuer, day |
| 2 | Monthly heatmap, day × hour | Heatmap | issuer |
| 3 | Spend per day | Stacked bar | issuer |
| 4 | Top 10 merchant categories | Horizontal bar | issuer |
| 5 | Over-limit alerts | Table | issuer |

The filters take human-readable values:
- **issuer**: part of the name, case does not matter. `Lumière`, `Rheingold`, `Thames`, `Meseta`, `Adriatica` or `Nordlys`.
- **day**: a date in October 2026 in YYYY-MM-DD format, for example `2026-10-15`.

Since all 5 tiles use the **same parameter names**, a single filter drives the whole dashboard.

### Step 1 · Create the dashboard
1. In the service sidebar, click **Dashboards**.
2. Click **+ New Dashboard**.
3. Name it `Card payments · Issuers`. The empty dashboard opens.

### Step 2 · Add a tile (repeat 5 times)
1. Top right, click **+ New visualization**. An empty tile appears and the **Edit element** panel opens on the right.
2. **General** tab, **Query** field: choose **New query**. The **Inline Editor** opens.
3. Paste the tile's query (cards below).
4. To the right of the editor, the **Query Parameters** panel shows the detected parameters. Enter the test values: `issuer` = `Lumière`, and for tile 1 `day` = `2026-10-15`.
5. Run with the ▷ button, check the result, then save with the **floppy disk** icon, under the tile's name.
6. **Visualization type**: choose the type given on the card.
7. **Data** tab: map the columns to the axes as given on the card.
8. Give the tile a title and close the panel (×). Resize the tile from its bottom right corner, move it with the handle at the top left.

### The 5 cards

#### Tile 1 · Spend of the day
Type **Line**. X axis: `local_hour`. Y series: `pos_keur`, `ecom_keur`.
```sql
SELECT
    toTimeZone(hour, 'Europe/Paris')                             AS local_hour,
    round(sumIf(spend_eur, channel = 'POS') / 1000, 1)           AS pos_keur,
    round(sumIf(spend_eur, channel = 'ECOM') / 1000, 1)          AS ecom_keur
FROM gold.issuer_curve
WHERE issuer_id IN (SELECT issuer_id FROM ref.issuer
                    WHERE positionCaseInsensitiveUTF8(name, {issuer:String}) > 0)
  AND hour >= toDateTime({day:Date}, 'Europe/Paris')
  AND hour <  toDateTime({day:Date} + 1, 'Europe/Paris')
GROUP BY local_hour
ORDER BY local_hour
```
What to look for: two in-store peaks, at lunch (about 715 k EUR between 12:00 and 13:00 for Lumière Banque on the 15th) and in the early evening, and the online curve that peaks around 9pm, when shops are closed.

#### Tile 2 · Monthly heatmap
Type **Heatmap**. X axis: `hour_of_day`. Y axis: `day`. Value: `spend_keur`.
```sql
SELECT
    toDate(hour, 'Europe/Paris')              AS day,
    toHour(hour, 'Europe/Paris')              AS hour_of_day,
    round(sum(spend_eur) / 1000, 1)           AS spend_keur
FROM gold.issuer_curve
WHERE issuer_id IN (SELECT issuer_id FROM ref.issuer
                    WHERE positionCaseInsensitiveUTF8(name, {issuer:String}) > 0)
GROUP BY day, hour_of_day
ORDER BY day, hour_of_day
```
What to look for: 31 rows × 24 columns. The lunch and evening bands every day, pale Sundays (half a weekday), and a month that gets slightly darker towards the end. This is the most telling tile of the dashboard.

#### Tile 3 · Spend per day
Type **Stacked bar**. X axis: `day`. Y series: `pos_keur`, `ecom_keur`.
```sql
SELECT
    day,
    round(pos_eur / 1000, 1)   AS pos_keur,
    round(ecom_eur / 1000, 1)  AS ecom_keur
FROM gold.issuer_day_summary
WHERE positionCaseInsensitiveUTF8(issuer, {issuer:String}) > 0
ORDER BY day
```
What to look for: the weekly rhythm (Sunday is about half a weekday, because business cards rest), and the trend that rises through October.

#### Tile 4 · Top 10 merchant categories
Type **Horizontal bar**. Category: `category`. Value: `spend_keur`.
```sql
SELECT
    dictGet('ref.dict_mcc', 'label', toUInt64(mcc))   AS category,
    round(sum(spend_eur) / 1000, 1)                   AS spend_keur
FROM gold.category_day_spend
WHERE issuer_id IN (SELECT issuer_id FROM ref.issuer
                    WHERE positionCaseInsensitiveUTF8(name, {issuer:String}) > 0)
GROUP BY mcc
ORDER BY spend_keur DESC
LIMIT 10
```
What to look for: restaurants, grocery stores and fast food on top. The label comes from a dictionary, with no JOIN.

#### Tile 5 · Over-limit alerts
Type **Table**. All columns.
```sql
SELECT
    day,
    city,
    segment,
    limit_eur,
    authorized_eur,
    over_limit_pct,
    peak_time
FROM gold.limit_alerts
WHERE issuer_id IN (SELECT issuer_id FROM ref.issuer
                    WHERE positionCaseInsensitiveUTF8(name, {issuer:String}) > 0)
ORDER BY day DESC, over_limit_pct DESC
```
What to look for: only BUSINESS and CORPORATE cards (a CONSUMER card is declined at its limit).

### Step 3 · Wire up the filters
1. Reopen each tile: **three dots** (⋮) top right, then **Edit**.
2. In the visualization settings, each query parameter (`issuer`, `day`) shows up with its **value source**. Choose **filter**.
3. Do this on all 5 tiles.
4. Click the **funnel** in the top bar: the **Global filters** panel opens, with an `issuer` field and a `day` field.

### Step 4 · Play with the dashboard
1. In **Global filters**, type `Lumière` and `2026-10-15`: the 5 tiles show Lumière Banque.
2. Replace with `Rheingold`, then `Nordlys`: the whole dashboard switches.
3. Change the date (`2026-10-25`, the day the clocks go back: 25 hours): only the curve in tile 1 changes.

---

## 2. The Query API endpoint for the bank's portal (15 min)

The portal only sends parameters (an issuer, two dates). The SQL stays in ClickHouse. We turn a saved query into an HTTPS address that can be called with an API key.

### Step 1 · Create the two API views
A **parameterized view** is a query stored in the database, with `{name:Type}` parameters. You call it like a table: `SELECT * FROM gold.api_issuer_curve(issuer_id = '488903', …)`. The portal will only ever see these parameters.

Prerequisite: modules 00 to 07 have run on **this same service** (the views read the gold tables).

In the SQL console, paste this block and run it all (Cmd+Enter):
```sql
-- The hourly spend curve of an issuer, between two dates
CREATE OR REPLACE VIEW gold.api_issuer_curve AS
SELECT
    toTimeZone(hour, 'Europe/Paris')   AS local_hour,
    channel,
    spend_eur,
    n_txns
FROM gold.issuer_curve
WHERE issuer_id = {issuer_id:String}
  AND hour >= toDateTime({start:Date}, 'Europe/Paris')
  AND hour <  toDateTime({finish:Date} + 1, 'Europe/Paris')
ORDER BY channel, hour;

-- The day-by-day summary of an issuer
CREATE OR REPLACE VIEW gold.api_issuer_summary AS
SELECT
    day,
    issuer,
    pos_eur,
    ecom_eur,
    round(100 * ecom_share, 2)   AS ecom_pct,
    cross_border_eur,
    n_txns
FROM gold.issuer_day_summary
WHERE issuer_id = {issuer_id:String}
  AND day BETWEEN {start:Date} AND {finish:Date}
ORDER BY day;

-- The module 7 role must be able to read the small reference tables used by the dashboard filters
GRANT SELECT ON ref.issuer TO role_lumiere;
GRANT dictGet ON ref.* TO role_lumiere;
```
If the console opens a **Query Variables** panel, leave it empty: the parameters are only used when calling the view.

Check:
```sql
SELECT name FROM system.tables WHERE database = 'gold' AND name LIKE 'api_%';
```
Expected: `api_issuer_curve` and `api_issuer_summary`.

If you later see `Unknown table function gold.api_issuer_curve (UNKNOWN_FUNCTION)`, the view does not exist on the service you are on: redo this step on that service.

### Step 2 · Get the values to pass
The identifier of each issuer:
```sql
SELECT issuer_id, name, country_code FROM ref.issuer ORDER BY issuer_id;
```
| issuer_id | name | country |
|---|---|---|
| 488903 | Lumière Banque | FR |
| 488904 | Rheingold Bank | DE |
| 488905 | Thames Union Bank | GB |
| 488906 | Banco Meseta | ES |
| 488907 | Banca Adriatica | IT |
| 488908 | Nordlys Bank | SE |

The available dates:
```sql
SELECT min(day) AS first_day, max(day) AS last_day FROM gold.issuer_day_summary;
```
Expected: from `2026-10-01` to `2026-10-31`.

### Step 3 · Write and test the endpoint query
1. New tab in the SQL console. Paste:
   ```sql
   SELECT *
   FROM gold.api_issuer_curve(
       issuer_id = {issuer_id:String},
       start     = {start:Date},
       finish    = {finish:Date})
   ```
2. The **Query Variables** panel opens on the right with three fields. Enter `488903`, `2026-10-15`, `2026-10-15`.
3. Run (Cmd+Enter). Expected: **46 rows** for October 15, one per hour and per channel.
4. Click **Save** and name the query `api_issuer_curve`.

### Step 4 · Create the API key
1. In the organization's left menu, open **API Keys**, then click **New API Key**.
2. Name: `issuer-portal`. Organization role: **Member**. Service access: **Query Endpoints** on your service. Pick an expiry date.
3. Optional: in **Allow access to this API Key**, restrict to the portal's IP addresses.
4. Click **Generate API Key**. The next screen shows the **Key ID** and the **Key secret**: copy them right away into a password vault. They will never be shown again.

### Step 5 · Create the endpoint
1. Reopen the saved query `api_issuer_curve`.
2. Click **Share**, then **API Endpoint**.
3. Choose the API key from step 4.
4. Choose the **database role** that will run the query: **Read only**, or the `role_lumiere` role from module 7 so that the endpoint only sees Lumière Banque.
5. **CORS**: the portal's domain (leave empty for a command-line test).
6. Confirm. The console shows the **call address**, in the form `https://queries.clickhouse.cloud/run/<identifier>`. Copy it.

### Step 6 · Call the endpoint
In a terminal, put the values in variables (never in a versioned file):
```bash
export KEY_ID='<Key ID from step 4>'
export KEY_SECRET='<Key secret from step 4>'
export ENDPOINT='https://queries.clickhouse.cloud/run/<identifier from step 5>'
```
GET call, parameters in the address:
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" \
  "$ENDPOINT?format=JSONEachRow&param_issuer_id=488903&param_start=2026-10-15&param_finish=2026-10-15"
```
POST call, parameters in the body:
```bash
curl -s --user "$KEY_ID:$KEY_SECRET" -X POST -H "Content-Type: application/json" \
  "$ENDPOINT?format=JSONEachRow" \
  -d '{"queryVariables": {"issuer_id": "488903", "start": "2026-10-15", "finish": "2026-10-15"}}'
```

What to expect:

| Call | Result |
|---|---|
| GET or POST, Lumière Banque (`488903`), October 15 | HTTP 200, **46 rows**: one per hour and per channel (no online payment between midnight and 2am) |
| GET, Lumière Banque, October 13 to 19 | HTTP 200, seven times as many rows |
| GET or POST, Rheingold Bank (`488904`), endpoint created with the `role_lumiere` role | HTTP 200, **0 rows**: the row policy hides everything that is not Lumière Banque |

Common pitfalls:
- **`401 Unauthorized`**: the key was not copied correctly. To test the key alone: `curl --user "$KEY_ID:$KEY_SECRET" https://api.clickhouse.cloud/v1/organizations` should return your organization.
- **No space or extra character in the address**: `param_issuer_id=488903`, not `param_issuer_id= 488903`. The `<…>` in the examples must be replaced entirely.
- `404`: the endpoint identifier is wrong. `400`: a parameter is malformed (date in YYYY-MM-DD format).

### Step 7 · See the calls on the server side
Each endpoint runs under a dedicated user named `queryEndpoint:<identifier>`:
```sql
SYSTEM FLUSH LOGS;
SELECT event_time, user, round(query_duration_ms) AS ms, read_rows
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish' AND user LIKE 'queryEndpoint:%' AND event_date = today()
ORDER BY event_time DESC
LIMIT 10;
```
What to look for: a few milliseconds and a few thousand rows read per call.

### Plan B · Test without an API key, over direct HTTPS
To check the query before you have a key, the service's HTTPS interface accepts the same parameters (`param_<name>`). This is a test: never put the `default` password in a portal.
```bash
curl --user "default:$CH_PASSWORD" \
  "https://$CH_HOST:8443/?param_issuer_id=488903&param_start=2026-10-15&param_finish=2026-10-15&default_format=JSONEachRow" \
  --data-binary "SELECT * FROM gold.api_issuer_curve(issuer_id = {issuer_id:String}, start = {start:Date}, finish = {finish:Date}) LIMIT 3"
```

---

## 3. ClickHouse Agents (35 min)

An agent does not guess the business: it reads the schema. So we document gold, create the agent with the right tools, ask it 2 questions to get a feel for it, then have it build dashboards and give it 3 data science exercises.

### Step 1 · Document gold for the agent
An agent starts by reading the tables, their columns and their **comments** (rule `agent-discovery-schema`). Without comments, it guesses that `hour` is in local time or that `488903` is a postal code. These commands only touch metadata: instant, no data rewritten.

In the SQL console, paste this block and run it all (Cmd+Enter):
```sql
ALTER TABLE gold.issuer_day_summary
    MODIFY COMMENT 'Daily summary per issuing bank (6 issuers). One row per issuer and per day of October 2026. Amounts in EUR.';
ALTER TABLE gold.issuer_day_summary
    COMMENT COLUMN issuer_id        'Issuer identifier (488903 = Lumière Banque, see ref.issuer)',
    COMMENT COLUMN day              'Business day, local time (Europe/Paris)',
    COMMENT COLUMN pos_eur          'In-store spend of the issuer''s cards that day, in EUR',
    COMMENT COLUMN ecom_eur         'Online spend of the issuer''s cards that day, in EUR',
    COMMENT COLUMN ecom_share       'ecom_eur / (pos_eur + ecom_eur), between 0 and 1',
    COMMENT COLUMN cross_border_eur 'Spend at merchants outside the issuer''s country, in EUR',
    COMMENT COLUMN n_txns           'Number of payments that day';

ALTER TABLE gold.issuer_curve
    MODIFY COMMENT 'Spend per issuer, channel and hour. hour = START of the hour, in UTC: convert with toTimeZone(hour, ''Europe/Paris''). Filter on issuer_id then hour (sorting key).';
ALTER TABLE gold.issuer_curve
    COMMENT COLUMN issuer_id 'Issuer identifier (488903 = Lumière Banque). Label: dictGet(''ref.dict_issuer'', ''name'', issuer_id)',
    COMMENT COLUMN channel   'POS = in store, ECOM = online',
    COMMENT COLUMN hour      'Start of the hour, UTC',
    COMMENT COLUMN spend_eur 'Total amount of the payments of the hour, in EUR',
    COMMENT COLUMN n_txns    'Number of payments of the hour';

ALTER TABLE gold.category_day_spend
    MODIFY COMMENT 'Spend per day, issuer, merchant category (MCC), merchant country, card segment and channel. Category label: dictGet(''ref.dict_mcc'', ''label'', toUInt64(mcc)). Country name: dictGet(''ref.dict_country'', ''name'', merchant_country).';
ALTER TABLE gold.category_day_spend
    COMMENT COLUMN mcc              'Merchant category code, ISO 18245 (5411 = grocery stores, 5812 = restaurants…)',
    COMMENT COLUMN merchant_country 'ISO country code of the merchant. Different from the issuer''s country = cross-border payment',
    COMMENT COLUMN segment          'CONSUMER, BUSINESS or CORPORATE card',
    COMMENT COLUMN spend_eur        'Spend of the day in EUR',
    COMMENT COLUMN n_cards          'Distinct cards of this row that day (do not add up across rows: a card can appear in several)';

ALTER TABLE gold.limit_alerts
    MODIFY COMMENT 'Cards whose authorized amount of the day exceeded their daily limit (AUTH flow). One row per card and per day over the limit. Only BUSINESS and CORPORATE cards can go over (a CONSUMER card is declined at the limit).';
ALTER TABLE gold.limit_alerts
    COMMENT COLUMN limit_eur       'Daily limit IN FORCE on that day, in EUR',
    COMMENT COLUMN authorized_eur  'Amount authorized over the day, in EUR',
    COMMENT COLUMN over_limit_pct  'Overrun as a % of the limit',
    COMMENT COLUMN peak_time       'Time of the largest payment of the day, Paris time';

ALTER TABLE gold.daily_sla_kpi
    MODIFY COMMENT 'Completeness of the CLEARING flow at 9am the next day (settlement cut-off). Target: data_by_9am_pct >= 99.';
ALTER TABLE gold.daily_sla_kpi
    COMMENT COLUMN txns_declared          'Transactions declared by the scheme''s ledger (SETTLEMENT flow)',
    COMMENT COLUMN data_by_9am_pct        'Transactions received before 9am / transactions declared, in %. This is the contractual KPI',
    COMMENT COLUMN complete_cards_9am_pct 'Share of active cards whose day is complete at 9am, in %';
```

Check:
```sql
SELECT name, comment FROM system.tables WHERE database = 'gold' AND comment != '' ORDER BY name;
```
Expected: 6 commented tables (`card_profile`, `category_day_spend`, `daily_sla_kpi`, `issuer_curve`, `issuer_day_summary`, `limit_alerts`). `card_profile` is commented as soon as it is created in module 05.

### Step 2 · Create and configure the agent
1. In the service sidebar, click **ClickHouse agents**, then **Launch ClickHouse agents**.
2. Click **+ Create New Agent** and fill in:

| Field | Value |
|---|---|
| Name | `Payments Assistant` |
| Description | `Answers business questions and builds dashboards on the October card payments (gold database).` |
| **Model** | a model from the list that can call tools and produce artifacts (the default one is fine) |
| Category | `General` |
| Instructions | **Inline** tab, paste the text below |
| **Tools** | **+ Add**, then add all three: **ClickHouse** (connected to your service: list tables, run SQL…), **Artifacts** (to build the dashboards), **Run Code** (calculations and charts in Python) |
| Skills | **All** |
| Conversation starters | add requests D1, D2 and D3 from step 5 below: they will show up as buttons when a conversation starts |

Without the **ClickHouse** tool, the agent cannot see your data. Without **Artifacts**, it answers in text but does not build a dashboard.

Instructions to paste (a single block):
```
You are the data assistant of the card operations team of a payment processor. You answer
business questions in English about the card payments of October 2026.
- Use ONLY the tables of the gold database and ref.issuer, through the ClickHouse tool.
  First read the comments of the tables and columns, and their sorting key.
- Always filter on the start of the sorting key and add a LIMIT.
- hour is in UTC and marks the START of an hour: convert with toTimeZone(hour, 'Europe/Paris').
- Labels are read with dictGet('ref.dict_issuer', 'name', issuer_id),
  dictGet('ref.dict_mcc', 'label', toUInt64(mcc)) and dictGet('ref.dict_country', 'name', merchant_country).
- All amounts are in EUR. Never show a card number in full: keep the last 4 digits.
- When asked for a dashboard, a page or a report: query ClickHouse first,
  then build an interactive artifact with the REAL values you got (never made-up
  data), titles in English, units (EUR, k EUR, %) and 2 or 3 sentences of analysis.
- Otherwise, give the key figures with their unit, then the SQL query you used.

Data science with the Run Code tool:
- You always run the Python code yourself in the Run Code tool. Never suggest a
  script to run, never use clickhouse_connect or any database connection.
- Method, always the same:
  1. one query with the ClickHouse tool that returns fewer than 100 rows (aggregate or
     sample in ClickHouse);
  2. copy the result as is into your Python code;
  3. run the code in Run Code and show the figures and a chart.
- Spend of an issuer: one row per day, with the 24 hours in an array:
  SELECT day, toDayOfWeek(day) AS weekday,
         arrayMap(x -> x.2, arraySort(groupArray((h, keur)))) AS spend_keur
  FROM (SELECT toDate(hour, 'Europe/Paris') AS day, toHour(hour, 'Europe/Paris') AS h,
               round(toFloat64(sum(spend_eur)) / 1000, 1) AS keur
        FROM gold.issuer_curve
        WHERE issuer_id = '<issuer_id, e.g. 488903>'
        GROUP BY day, h)
  GROUP BY day ORDER BY day
  (October 25 has 25 hours: two rows share the same local hour, keep the day as it comes.)
- Card profiles (30 per segment CONSUMER, BUSINESS, CORPORATE):
  SELECT segment, product, avg_ticket_eur, ecom_share, cross_border_share,
         arrayMap(x -> round(x, 2), weekday_shape) AS weekday,
         arrayMap(x -> round(x, 2), weekend_shape) AS weekend
  FROM gold.card_profile ORDER BY cityHash64(card_id) LIMIT 30 BY segment
  If gold.card_profile does not exist, say so in one sentence: it is created with the
  workshop file 05_gold/04_card_profiles.sql. Do not use silver instead.
- Forecast: HistGradientBoostingRegressor(max_iter=300, learning_rate=0.05, random_state=0)
  with the hour, the day of the week and the day of the month. Always compare its error (MAPE)
  with two naive methods aligned by hour: the previous day, and the same weekday of the previous week.
- Segmentation: KMeans(n_clusters=3, n_init=10, random_state=0) on the 48 shape values
  (weekday then weekend), then cross the clusters with the segment.
- Outliers: IsolationForest(random_state=0) on avg_ticket_eur, ecom_share, cross_border_share
  and n_txns, within one segment at a time. An outlier is a card to review, not a fraud.
- Always present the result in an artifact: the charts, a table of the key figures
  (errors, cluster sizes) and 3 to 5 sentences of analysis in English, without jargon.
```

### Step 3 · Open a conversation
1. Save the agent.
2. At the top of the page, choose `Payments Assistant` from the list, then click **Select**.
3. A conversation opens. The conversation starters appear as buttons.

### Step 4 · Ask 2 questions to get a feel for it
Two questions are enough to see how the agent works: it reads the comments, writes the SQL, filters on the sorting key. The interesting part comes next, with the dashboards and the data science.

Copy each question as is into the conversation and compare the answer with the expected result. The check query (expand it) gives the real figure.

**Q1** · "How much did the cards of Lumière Banque spend in October, and what share was spent online?"

Expected: about 220.7 million EUR, of which about 25% online.

<details><summary>Check query</summary>

```sql
SELECT round(sum(pos_eur + ecom_eur) / 1e6, 2)                     AS total_meur,
       round(100 * sum(ecom_eur) / sum(pos_eur + ecom_eur), 1)     AS ecom_pct
FROM gold.issuer_day_summary
WHERE issuer_id = '488903';
```
</details>

**Q2** · "At what time did the cards of Lumière Banque spend the most on October 15, and how much?"

Expected: between 12:00 and 13:00 Paris time, about 796 k EUR (in store and online together). The trap: hour is in UTC and marks the START of the hour.

<details><summary>Check query</summary>

```sql
SELECT toTimeZone(hour, 'Europe/Paris') AS local_hour, round(sum(spend_eur) / 1000, 1) AS spend_keur
FROM gold.issuer_curve
WHERE issuer_id = '488903'
  AND hour >= toDateTime('2026-10-15', 'Europe/Paris') AND hour < toDateTime('2026-10-16', 'Europe/Paris')
GROUP BY local_hour
ORDER BY spend_keur DESC
LIMIT 1;
```
</details>

### Step 5 · Have it build dashboards (the highlight)
With the **ClickHouse** and **Artifacts** tools, the agent no longer just answers: it queries gold, then builds an interactive page with charts and key figures, in a few tens of seconds.

For each request:
1. Paste it into the conversation (or click the conversation starter).
2. Watch the queries the agent runs: it should read the comments, then filter on `issuer_id`.
3. Compare the figures on the page with the check query.
4. Ask for a tweak in the same conversation: "add a filter by issuer", "switch the curve to stacked areas", "export to PDF".

Start with **D2** (the heatmap) then **D1** (the full dashboard): they are the most visual.

A good page: real data (never made up), units (EUR, %), titles in English, and a few lines of analysis under the charts.

**D1** · "Build an interactive dashboard for Lumière Banque for October 2026: the hourly spend of October 15 (in store and online), the spend day by day, the top 10 merchant categories, the 9am SLA and the over-limit alerts of the last day. Add 3 key figures at the top of the page."

<details><summary>Check query</summary>

```sql
SELECT round(sum(pos_eur + ecom_eur) / 1e6, 2) AS total_meur,
       round(100 * sum(ecom_eur) / sum(pos_eur + ecom_eur), 1) AS ecom_pct,
       round(100 * sum(cross_border_eur) / sum(pos_eur + ecom_eur), 1) AS cross_border_pct
FROM gold.issuer_day_summary
WHERE issuer_id = '488903';
```
</details>

**D2** · "Make a day × hour heatmap of the spend of Lumière Banque's cards in October, then explain in 3 sentences what it shows."

The analysis should mention the lunch and early evening peaks, the quiet Sundays, and the rise through the month.

<details><summary>Check query</summary>

```sql
SELECT toDate(hour, 'Europe/Paris') AS day, toHour(hour, 'Europe/Paris') AS h,
       round(sum(spend_eur) / 1000, 1) AS spend_keur
FROM gold.issuer_curve
WHERE issuer_id = '488903'
GROUP BY day, h
ORDER BY day, h;
```
</details>

**D3** · "Compare the 6 issuers on a single page: total spend, online share, cross-border share and number of over-limit alerts for the month. Highlight the most online one."

Expected: a ranked table and a chart. Nordlys Bank is the most online (25.7%), Rheingold Bank the least (22.1%); Lumière Banque is by far the largest.

<details><summary>Check query</summary>

```sql
SELECT s.issuer,
       round(sum(s.pos_eur + s.ecom_eur) / 1e6, 2)                           AS total_meur,
       round(100 * sum(s.ecom_eur) / sum(s.pos_eur + s.ecom_eur), 1)         AS ecom_pct,
       round(100 * sum(s.cross_border_eur) / sum(s.pos_eur + s.ecom_eur), 1) AS cross_border_pct,
       any(a.alerts)                                                         AS alerts
FROM gold.issuer_day_summary AS s
LEFT JOIN (SELECT toString(issuer_id) AS issuer_id, count() AS alerts FROM gold.limit_alerts GROUP BY issuer_id) AS a ON a.issuer_id = s.issuer_id
GROUP BY s.issuer
ORDER BY ecom_pct DESC;
```
</details>

**D4** · "Prepare the October 30 operations report for the team lead: the 9am SLA, the files that arrived late this month, the over-limit alerts of the day, and 3 recommendations. Lay it out as a printable page."

Expected: the 4 days below the 99% target (October 14, 16, 24 and 30) with their cause (one or two clearing files that arrived in the afternoon), the alerts of the 30th, and concrete recommendations (chase the late batches with the scheme, contact the companies that keep going over their limit).

<details><summary>Check query</summary>

```sql
SELECT day, data_by_9am_pct FROM gold.daily_sla_kpi WHERE data_by_9am_pct < 99 OR day = '2026-10-30' ORDER BY day;
```
</details>

**D5** · "Which cards regularly go over their daily limit? Show them on a chart (average overrun and number of days) and say which ones should get a higher limit."

A good answer: the agent shows the last 4 digits only, and points out that consumer cards never appear because they are declined at the limit.

<details><summary>Check query</summary>

```sql
SELECT concat('…', substring(toString(card_id), 13, 4)) AS card, any(city) AS city, any(segment) AS segment,
       count() AS days_over, round(avg(over_limit_pct), 1) AS avg_over_limit_pct, max(limit_eur) AS limit_eur
FROM gold.limit_alerts
GROUP BY card_id
HAVING days_over >= 3
ORDER BY days_over DESC, avg_over_limit_pct DESC
LIMIT 20;
```
</details>

**D6** · "Make a page for the head of retail at Rheingold Bank: 4 key figures for the month, the hourly spend of a typical weekday and of a typical Saturday, and where the cards are used abroad. Readable by a non-specialist."

<details><summary>Check query</summary>

```sql
SELECT dictGet('ref.dict_country', 'name', toString(merchant_country)) AS country,
       round(sum(spend_eur) / 1000, 1) AS spend_keur
FROM gold.category_day_spend
WHERE issuer_id = '488904' AND merchant_country != 'DE'
GROUP BY country
ORDER BY spend_keur DESC
LIMIT 10;
```
</details>

### Step 6 · Data science: forecast, segment and review with Run Code
The **Run Code** tool gives the agent real Python (pandas, scikit-learn) in a sandbox. The split of roles is the right data scientist reflex on ClickHouse:
- **ClickHouse prepares the data**: aggregates, card profiles, samples. It is fast and it cuts the volume;
- **Python trains the model** on only a few hundred or a few thousand rows.

First check that the **Run Code** tool is in the agent's tool list (step 2).

**6.1 · Check that the card profiles are in gold**
Examples 2 and 3 use the `gold.card_profile` table: each card is summarized by a few indicators and by its shape of the day, 24 values on weekdays and 24 at weekends. It is created in module 05 by `05_gold/04_card_profiles.sql`. Check in the SQL console:
```sql
SELECT segment, count() AS cards, round(avg(avg_ticket_eur), 2) AS avg_ticket_eur FROM gold.card_profile GROUP BY segment ORDER BY segment;
```
Expected: about 1,090 BUSINESS cards (average ticket ~357 EUR), 98,700 CONSUMER cards (~25 EUR) and 194 CORPORATE cards (~1,195 EUR).

If you see `Table gold.card_profile does not exist`, open `05_gold/04_card_profiles.sql`, paste it into the console and run it all (Cmd+Enter). Without this table, the agent will tell you it cannot do examples 2 and 3. That is the right behavior: it must not make up data.

**6.2 · The data science instructions**
Run Code runs Python in a sandbox that does not have your ClickHouse credentials. Without instructions, the agent writes a script with `clickhouse_connect` and asks you to run it yourself. So the method is given once and for all, in the "Data science with the Run Code tool" part of its instructions (step 2): a compact query with the ClickHouse tool, data pasted into the code, execution in Run Code, result in an artifact.

If you created the agent before adding that part, copy the full block from step 2 again, save, then open a **new** conversation.

**6.3 · The three requests**
One sentence is enough: the method is in the instructions.

| | Request to paste | What a good answer shows |
|---|---|---|
| **ML1 · Forecast** | "Forecast the hourly spend of Lumière Banque's cards for Saturday October 31 from October 1 to 30, and compare it with reality." | the model against two naive methods. The previous day (a Friday) is a poor guide for a Saturday; the previous Saturday is a good one; the model should do at least as well because it also follows the rise through the month |
| **ML2 · Segmentation** | "Group the cards into 3 clusters based on the shape of their day, cross these clusters with the CONSUMER, BUSINESS and CORPORATE segments, and show me each cluster." | 90 cards (30 per segment). The business cards stand out (office hours, almost nothing at the weekend); consumer cards show the lunch and evening peaks |
| **ML3 · Cards to review** | "Among the consumer cards, which ones have the most unusual profile? Explain why for the top 5." | a short list of cards with, for each, what makes it unusual: a very high online share, a very high cross-border share, an unusual number of payments. Last 4 digits only |

Each result is shown in an artifact: charts, a table of key figures and a few sentences of analysis.

Takeaway for ML1: the day of the week matters more than yesterday. Always compare a model with a naive method before trusting it.

Takeaway for ML2: the shape of the day depends on how a card is used, not on its limit.

Takeaway for ML3: an outlier is a question, not an answer. The data is simulated, with no fraud injected: the point is the method (features prepared in ClickHouse, model in Python), not the cards it finds.

**If the agent still does not run the code**: reply "run it yourself with Run Code, pasting the data into the code". Also check that the conversation was opened after the instructions were saved.

These results are clean because the data is simulated. On real data, holidays, paydays and individual behavior add noise. The method stays the same.

### Step 7 · In production: a dedicated role for the agent
During the workshop, the agent runs with your privileges. In production, give it a read-only role on gold, with limits on each query (rule `agent-query-safety`). To adapt, not run during the workshop:
```sql
CREATE SETTINGS PROFILE IF NOT EXISTS agent_profile SETTINGS
    readonly = 2, max_execution_time = 30, max_rows_to_read = 1000000000,
    max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS agent_role SETTINGS PROFILE 'agent_profile';
GRANT SELECT ON gold.* TO agent_role;
GRANT SELECT ON ref.* TO agent_role;
GRANT dictGet ON ref.* TO agent_role;
```
`readonly = 2` forbids any write, `max_rows_to_read` and `max_execution_time` cap the cost of a badly phrased question. In a bank, the agent reads gold only: no card-level table unless the use case requires it.
