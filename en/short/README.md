# Short track · ClickHouse essentials in 90 minutes

The same story as the full workshop (one day of card payment clearing at an issuing bank), cut down to the
concepts that matter most. Everything is generated in SQL inside ClickHouse: nothing to download.

| Part | Concept | File | Hands-on |
|---|---|---|---|
| What is ClickHouse | column storage, the Cloud, where it is used | slides | |
| Setup | run two files as is | [`../01_fundamentals/01_setup_and_reference_data.sql`](../01_fundamentals/01_setup_and_reference_data.sql), then [`../02_bronze/01_simulator.sql`](../02_bronze/01_simulator.sql) | 3 min |
| **1** Storage | MergeTree, parts, compression, the sparse primary index | [`01_storage_and_primary_key.sql`](01_storage_and_primary_key.sql) | 12 min |
| **2** Ingestion | raw JSON in bronze, a materialized view, ReplacingMergeTree and FINAL | [`02_bronze_to_silver.sql`](02_bronze_to_silver.sql) | 15 min |
| **3** Serving | dictionaries, refreshable materialized views, a documented gold layer | [`03_dictionaries_and_gold.sql`](03_dictionaries_and_gold.sql) | 10 min |
| **4** Analytics at scale | six analytical questions of 186 million rows, then primary key, parallel replicas, projection | [`04_analytics_at_scale.sql`](04_analytics_at_scale.sql) | 10 min |
| **5** Live data | payments arriving every 10 seconds, a summary kept up to date on insert | [`05_live_feed.sql`](05_live_feed.sql) | 5 min |
| **6** Agent | create a ClickHouse agent, ask questions, have it build a live app | [`06_agent.md`](06_agent.md) | 20 min |

About 90 minutes with the slides. Short on time? Part 4 can be shown by the trainer: part 6 needs parts 1 to 3 and part 5.

## How to run it

1. Create a ClickHouse Cloud service and open its SQL console (see [the main README](../README.md#before-the-session-20-min-the-day-before)).
2. **Setup**: open each of the two setup files, paste it into a new tab and run the whole tab with **Cmd + Enter**.
   They create the databases, 1 million cards, 50,000 merchants and the simulator, in a few seconds.
3. **Parts 1 to 4**: paste each file into a new tab and go query by query with **Cmd + Shift + Enter**.
   **Part 5** is run as is (Cmd + Enter), then you replay its last queries. **Part 6** is a guide to follow in the console.
   The `What to look for` comments say what to check. Each file ends with a checkpoint: a row of `OK`.

Every file is idempotent: run it again if a step was missed.

## What you get at the end

- 1.9 million transactions unfolded from 140 JSON files by a materialized view, about 20 bytes each
- a gold table of a few thousand rows that answers the dashboard in milliseconds
- 186 million transactions: aggregations over the whole table in about a second, one card's statement in milliseconds
- a live feed of about 18,000 payments a minute, summarized at insert time
- an AI agent that answers questions in plain English and builds an interactive app on your data

## When you are done

Stop the live feed, otherwise the service never goes idle: `SYSTEM STOP VIEW simulator.live_feed;`
(or run [`../reset.sql`](../reset.sql), which drops everything).

## Going further

The full 5-hour workshop adds the three flows and their reconciliation, the 9am SLA, limit alerts,
the clock change, replay and atomic publish, row policies, a dashboard, an API and an AI agent:
start at [`../README.md`](../README.md). The short track uses the same table names, so reset first
([`../reset.sql`](../reset.sql)) or just carry on with module 03 of the full workshop after re-running module 02.
