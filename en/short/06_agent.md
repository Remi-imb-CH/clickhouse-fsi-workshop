# Short track · 6 · Ask your data: ClickHouse Agents

The last part of the session, and the one people remember. Gold is ready and documented (part 3):
we create an AI agent in the ClickHouse Cloud console, ask it a few questions, then have it **build an app**.

Duration: 20 minutes. Everything happens in the Cloud console. Prerequisite: parts 1 to 3 and part 5
(the live feed) have run on your service. Part 4 is not needed.

> The labels below are those of the ClickHouse Cloud console in autumn 2026. ClickHouse Agents evolves quickly:
> a label may have moved, the principle stays the same.

The agent reads three small tables, all documented with comments:

| Table | One row per | Use it for |
|---|---|---|
| `gold.live_minute` | minute, bank, channel, merchant category | **what is happening now**: new payments arrive every 10 seconds |
| `gold.category_day_spend` | day, bank, merchant category, channel | the week of October 1 to 7: totals, rankings, categories |
| `gold.issuer_curve` | bank, channel, hour | the week of October 1 to 7: curves and heatmaps |

---

## Step 1 · Create the agent (5 min)

1. In the left sidebar of your service, click **ClickHouse agents**, then **Launch ClickHouse agents**.
2. Click **+ Create New Agent**.
3. Fill in the form:

| Field | What to enter |
|---|---|
| **Name** | `Payments Assistant` |
| **Description** | `Answers questions and builds apps on card payments: live, and for the first week of October 2026.` |
| **Model** | keep the default, or pick one that can call tools and produce artifacts |
| **Category** | `General` |
| **Instructions** | open the **Inline** tab and paste the block below |
| **Tools** | click **+ Add** three times and add **ClickHouse** (connected to your service), **Artifacts** and **Run Code** |
| **Skills** | **All** |
| **Conversation starters** | paste questions Q1 and Q3 and app prompt A1 from this page: they become buttons |

4. Click **Save**.
5. At the top of the page, pick `Payments Assistant` in the list and click **Select**. A conversation opens.

Without the **ClickHouse** tool the agent cannot see your data. Without **Artifacts** it answers in text but cannot build an app.

Instructions to paste (one block):

```
You are the data assistant of the card operations team of a payment processor. You answer
in English about card payments.

Data
- Use ONLY gold.live_minute, gold.category_day_spend, gold.issuer_curve and ref.issuer,
  through the ClickHouse tool. Read the comments of the tables and columns first.
- gold.live_minute is LIVE: new payments arrive every 10 seconds. Use it for anything about
  "now", "live", "the last N minutes". Always aggregate it: sum(spend_eur), sum(n_txns),
  GROUP BY, with a filter such as minute >= now() - INTERVAL 15 MINUTE.
- gold.category_day_spend and gold.issuer_curve cover the week of October 1 to 7, 2026.
- Filter on issuer_id first, and always add a LIMIT.
- hour and minute are in UTC and mark the START of the period: convert with
  toTimeZone(x, 'Europe/Paris').
- Names: dictGet('ref.dict_issuer', 'name', toString(issuer_id)) for a bank,
  dictGet('ref.dict_mcc', 'label', toUInt64(mcc)) for a merchant category.
- channel is POS (in store) or ECOM (online). All amounts are in EUR.
- The data is simulated. The six banks are fictional.

Answers
- Give the key figures with their unit, then the SQL query you used and how long it took.
- Never invent a figure. If the data does not answer the question, say so.

Apps, dashboards and pages
- Query ClickHouse FIRST, with aggregated queries that return at most a few hundred rows.
- Then build ONE interactive artifact (a React app) that embeds the real results as data.
- Show the time of the data ("as of 14:32:10") at the top of the app.
- When I say "refresh", run the same queries again and update the same app with the new
  figures. Do not rebuild it from scratch.
- Use charts, key figures at the top, clear titles, units (EUR, k EUR, %).
- Use a sober style: white background, black text, one accent colour (yellow #FAFF69).
- When asked for a change, modify the existing app instead of starting again.
```

---

## Step 2 · Three questions to get a feel for it (5 min)

Paste each question as is. Watch what the agent does: it reads the comments, writes the SQL, filters on `issuer_id`.

**Q1** · "How many payments were made in the last 5 minutes, for how much, and which bank is ahead?"

Expected: about 18,000 payments a minute, so roughly 90,000 payments and 3 to 4 million EUR over 5 minutes,
with Lumière Banque far ahead (about 60% of the cards). The figures move: ask again a minute later.

<details><summary>Check query</summary>

```sql
SELECT dictGet('ref.dict_issuer', 'name', toString(issuer_id)) AS bank,
       sum(n_txns) AS payments, round(sum(spend_eur)) AS eur
FROM gold.live_minute
WHERE minute >= now() - INTERVAL 5 MINUTE
GROUP BY bank
ORDER BY eur DESC;
```
</details>

**Q2** · "Ask the same question again." Then: "How long did that query take, and how many rows did it read?"

What to look for: new figures a few seconds later, from a query that reads a few hundred rows.
The summary is maintained at insert time: the cost of the question does not grow with the number of payments.

**Q3** · "During the week of October 1 to 7, how much did the cards of Lumière Banque spend, and what share online?"

Expected: about **47.28 million EUR**, of which about **25%** online.

<details><summary>Check query</summary>

```sql
SELECT round(sum(spend_eur) / 1e6, 2) AS million_eur,
       round(100 * sumIf(spend_eur, channel = 'ECOM') / sum(spend_eur), 1) AS online_pct
FROM gold.category_day_spend
WHERE issuer_id = '488903';
```
</details>

More questions to try:

- "Which merchant categories took the most money in the last 10 minutes?"
- "Minute by minute, how many payments did Rheingold Bank process in the last quarter of an hour?"
- "At what time of day does online spending overtake in-store spending?" (week data: from **8pm** Paris time. The trap: hours are stored in UTC)
- "Rank the six banks by total spend for the week, with their online share." (Lumière Banque 47.28 M EUR; Nordlys Bank the most online at 26.5%, Rheingold Bank the least at 21.9%)
- "Which day of the week was the quietest, and by how much?" (Sunday October 4: 6.33 M EUR, about half a weekday)

---

## Step 3 · Have it build an app (10 min, the highlight)

With the **ClickHouse** and **Artifacts** tools, the agent queries gold, then writes a small interactive app
(a React component) that opens next to the conversation. The app embeds the figures the agent queried:
to refresh it, ask the agent to query again.

Paste one prompt, wait a few tens of seconds, then **iterate in the same conversation**.

### A1 · The live payments cockpit (start here)

```
Build an interactive app called "Live payments cockpit".

1. Query gold.live_minute for the last 15 minutes, for all six banks.
2. Build one React app with:
   - the time of the data at the top ("as of hh:mm:ss, Paris time");
   - a bank selector (the six banks, plus "All banks");
   - four key figures for the last 5 minutes: payments, spend in EUR, average payment,
     online share;
   - a line chart of the spend minute by minute over the last 15 minutes, in store and online;
   - a bar chart of the top 8 merchant categories over the last 15 minutes;
   - a small table: one row per bank, with payments and spend over the last 5 minutes.
3. Everything must react to the bank selector. Use only the real figures you queried.
```

Then type **`refresh`** a few times. The agent runs the same queries again and updates the app:
the curve moves one step to the right and the figures change.

What a good result shows: about 18,000 payments a minute in total, Lumière Banque far ahead, and queries
that come back in milliseconds every time.

How live is it? The data in ClickHouse is live to the second. The app embeds the result of the agent's last
queries, so it moves when you ask the agent to refresh. A production dashboard would query ClickHouse
directly, on a timer, with the same queries.

### A1b · The week in review

```
Add a second tab to the app, called "Week of October 1 to 7", built from gold.category_day_spend
and gold.issuer_curve: four key figures (total spend, payments, average payment, online share),
the spend hour by hour over the week in Paris time (in store and online), the spend per day stacked,
and the top 8 merchant categories. The bank selector must drive this tab too.
```

What a good result shows: for Lumière Banque, 47.28 M EUR and 25% online; a lunch peak and an early evening
peak in store; the online curve taking over around 8pm; Sunday at half a weekday.

### A2 · Day × hour heatmap

```
Build an app that shows a heatmap of card spend: one row per day of the week (October 1 to 7),
one column per hour of the day in Paris time, colour = spend in thousand EUR.
Add a switch "In store / Online / Both" and a bank selector.
Under the heatmap, explain in three sentences what the pattern shows.
```

### A3 · Compare two banks

```
Build an app to compare two banks side by side. Two selectors choose the banks.
Show for each: total spend, online share, average payment, and the top 5 merchant categories.
Add one chart with their two hourly curves overlaid, each as a % of its own maximum,
so that a small bank and a large bank can be compared.
Finish with a short text: what do these two banks do differently?
```

### A4 · A one-page report for the head of cards

```
Prepare a one-page weekly report for the head of cards at Lumière Banque, readable by a non-specialist
and ready to print: a title, four key figures, one chart of the spend per day, one chart of the top
merchant categories, the busiest hour of the week, and three recommendations.
```

### Follow-ups that work well

Ask for one change at a time, in the same conversation:

- "refresh"
- "Extend the live chart to the last 30 minutes."
- "Add a tab with a table of the figures and a button to copy them as CSV."
- "Highlight the Sunday in the daily chart and explain the drop."

### If something goes wrong

| What you see | What to do |
|---|---|
| The agent answers in text, no app opens | check that **Artifacts** is in the agent's tools, then ask: "build it as an interactive artifact" |
| The figures look invented or rounded oddly | ask: "show me the SQL you ran and the rows it returned", then compare with the check queries |
| The hours are shifted by one or two hours | remind it: "hour and minute are in UTC, convert with toTimeZone(x, 'Europe/Paris')" |
| The live figures are zero or do not move | check that the feed runs: step 4 of `05_live_feed.sql`. To restart it: `SYSTEM START VIEW simulator.live_feed;` |
| It tries to read silver, or scans too much | remind it: "use only the gold tables" |
| The app is empty or breaks | ask: "the app shows nothing, fix it and keep the same data" |

---

## When you are done

Stop the live feed, otherwise the service never goes idle:

```sql
SYSTEM STOP VIEW simulator.live_feed;
```

## In production

During the workshop the agent runs with your privileges. In production, give it a read-only role limited to gold,
with a cap on each query. To adapt, not to run during the workshop:

```sql
CREATE SETTINGS PROFILE IF NOT EXISTS agent_profile SETTINGS
    readonly = 2, max_execution_time = 30, max_rows_to_read = 1000000000,
    max_result_rows = 10000, result_overflow_mode = 'break';
CREATE ROLE IF NOT EXISTS agent_role SETTINGS PROFILE 'agent_profile';
GRANT SELECT ON gold.* TO agent_role;
GRANT SELECT ON ref.issuer TO agent_role;
GRANT dictGet ON ref.* TO agent_role;
```

The full workshop goes further: six gold tables, a secured API endpoint, and data science with the Run Code tool.
See [`../08_dashboards_agent/README.md`](../08_dashboards_agent/README.md).
