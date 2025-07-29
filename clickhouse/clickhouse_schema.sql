/*-----------------------------------------------------------------------
Certificate-to-Technology Analytics Schema  – 2025-07-01
-----------------------------------------------------------------------

End-to-end analytics pipeline for extracting, clustering, and analyzing certificate transparency logs to detect technology use by organization. 
Schema is designed for high-volume ingest, append-only safety, efficient surrogate keys, rapid fuzzy/org lookup, and scalable heuristics—leveraging ClickHouse 
refreshable materialized views for automatic periodic rollup, aliasing, and autocomplete.

________________________________________________________________________
DATA FLOW & ARCHITECTURE
________________________________________________________________________

CT logs -> certslurp archives -> ct_certificates
                        │
        ┌───────────────┴────────────────────────────────────────┐
        │   [mv_dns_flat] (per-SAN)                              │
        │   + PSL: org_id, root, etc                             │ 
dict_tech_patterns (HASHED dictionary) ←── tiny, versioned       │
        │                                                        ▼
        ▼                                           [pattern/token/regex match]
 [mv_ct_tech_signals] ─────────────────────────────────────-> tech_signals ←── external scan/API
        ▲                                                        ▲
        │                                                        │ merges & suppression
        │                                                        │
  [mv_org_tech]                                       (AggregatingMergeTree)
        │
        ▼
 org_tech_facts (read-only, deduped)


Org clustering, autocomplete & aliasing:

org_root_sets (periodic refresh, de-noised ownership)
│
├─→ org_alias_map (periodic refresh, alias cluster detection)
└─→ org_autocomplete_clustered (periodic refresh, fuzzy search clusters)

All organizational grouping uses org_id (UInt64; deterministic SipHash64 of normalized organization tokens) for high-speed lookup and lossless deduplication.
De-noising (ownership filtering) is applied in org_root_sets_mv; all downstream clustering depends on these filters to exclude infrastructure, super-issuers, and SaaS/hosting providers.

Key tunable params:
 - Diversity threshold (registrable_count > 1000)
 - Domain depth filter (min_depth; usually <=2)
 - Explicit denylist/canonical owner overrides

________________________________________________________________________
TABLE & VIEW GLOSSARY
________________________________________________________________________

1. ct_certificates  (MergeTree, raw ingest)
 - One row per certificate scraped by certslurp
 - Partitioned by toYYYYMM(lts) (append-only; lts = log timestamp)
 - All multi-value fields (org, dns, etc) are arrays.
 - Indexes:  Bloom on Array(String) dns; token Bloom on issuer

2. mv_dns_flat  (ReplacingMergeTree)
 - One row per SAN domain
 - Derived columns: dn (SAN), org_id, registrable (PSL), root, token arrays
 - Purpose: fast domain & country filters; feeds heuristics.

3. org_root_sets  (periodically refreshed MergeTree)
 - Snapshot of de-noised “true” org_id <-> registrable relationships (one row per (org_id, registrable)).
 - Result of applying infra/denylist and org diversity (super-issuer) filters, and min domain depth logic.
 - Columns flag canonical ownership and allow/disallow aliasing/merging.
 - Refreshed automatically by org_root_sets_mv; do not manually insert or update.
Tunable parameters: org_diversity_signal threshold, denylist, canonical overrides.

4. org_alias_map  (periodically refreshed MergeTree)
 - All pairs of org_ids sharing >=N registrable roots (default: N=5), where both are allowed to be aliased.
 - Used for alias cluster detection and autocomplete grouping.
 - Excludes infra orgs, super-issuers, and noisy relationships by using org_root_sets as its source.
 - Fast graph view of plausible org merges for UI, search, and clustering.

5. org_autocomplete_clustered  (periodically refreshed MergeTree)
 - Autocomplete index and search clusters for organizations.
 - Each row represents an alias cluster (cluster_id), with display name, list of aliases, and cert count.
 - Used for fuzzy org lookup, search UI, and reporting.
 - Automatically deduplicated and grouped via alias mapping; updated on schedule.

6. tech_patterns/dict_tech_patterns/dict_regex_prefixes
 - Editable patterns and live-reload dictionaries for token/regex -> tech mapping.

7. tech_signals  (ReplacingMergeTree)
 - All technology "signals" (from heuristics + external sources)
 - Evidence, source, confidence, is_negative fields
 - Very robust deduplication logic
 - Continuously refreshed by mv_ct_tech_signals

8. mv_ct_tech_signals
 - Insert tech_signals from token and regex matches in mv_dns_flat.
 - Refreshes on schedule

9. mv_org_tech / org_tech_facts (AggregatingMergeTree/view)
 - One row per (org_id, tech); highest-confidence, deduped
 - API and reporting table

10. etl_ingest_metrics
 - All ETL/ingest job runs (row count, duration, errors, partition, etc.)

11. mv_partition_stats, slow_queries
 - System-level metrics and performance diagnostics

12. org_locations
 - 1 row per country/province/locality/org ID
 - Simplifies organization lookup by geographical location
 - Note that all fields are lowercased
________________________________________________________________________
CLUSTERING & QUERYING ORGANIZATIONS
________________________________________________________________________

Each organization name is normalized into an org_id (UInt64) using org_id().

Multiple `org_id`s that represent aliases (e.g., variants, subsidiaries, or naming differences) are grouped into clusters.

Clusters are identified by a unique cluster_id, which is either:
- The canonical_id from org_alias_map if aliases exist, or
- The original org_id if no cluster exists.

The org_alias_map table maintains mappings between alias org_ids and their canonical cluster_id.
Clustering updates automatically on scheduled materialized view refreshes.

The materialized view org_autocomplete_clustered resolves and exposes clusters, providing:
- cluster_id — the unified cluster key
- display_name — best canonical org name
- aliases — array of known name variants
- cert_count — total certs across cluster

** Querying by cluster_id ensures unified, deduplicated results across all aliases. **

Workflow to resolve user input:
1. Normalize user input to org_id via org_id().
2. Lookup corresponding cluster_id in org_alias_map.
3. If no cluster exists, use org_id as cluster_id.
4. Use cluster_id for all queries against clustered views/tables.

This abstraction removes the need for manual alias expansion or fan-out in queries.

________________________________________________________________________
De-noising Organization "Ownership" in CT Domain Data
________________________________________________________________________

Problem:
- Not every organization listed on a certificate is the true owner
  of a domain. Infra providers, SaaS vendors, CDNs, and super-issuers
  (e.g., CAs, hosting platforms) create significant noise in org→domain
  mappings extracted from CT logs.

Approach:

We combine two complementary heuristics to infer "true" organizational
ownership of registrable domains, and to reduce false positives:

1. Org Diversity Filter ("Super-Issuer" Suppression)
  - Track how many distinct registrables each org_id appears on.
  - Orgs with abnormally high diversity (e.g., >1000 registrables)
    are flagged as "infra" and downranked or excluded as owners.
  - The diversity threshold is tunable in org_diversity_signal.

2. Domain Depth Heuristic ("Proximity to the Root")
  - For each (org_id, registrable) pair, record the minimum depth of
    domain names associated with that org on certificates.
  - Orgs with only deep subdomain coverage (e.g., analytics.example.com)
    but never for the registrable itself (example.com) are likely not
    true owners—these are downranked or filtered out.
  - The maximum allowed depth is tunable (usually 2 or 3).

Implementation:
  - For each (org_id, registrable), retain only those where the org
    is not "infra" (fails org diversity or explicit denylist), or is the
    canonical owner via manual override.
  - Only merge/alias orgs if they clear these de-noising filters.

Tunable parameters:
  - org_diversity_signal.registrable_count threshold (default: 1000)
  - max domain depth (set in downstream consumers or clustering logic)
  - org_alias_denylist contents
  - canonical override table

TL;DR Heuristic:
  - True owner: Org certifies apex/1st-level domains, and appears for
    relatively few registrables overall.
  - Infra: Org appears on many registrables, and typically only deep
    subdomains.

Example owner score:
  owner_score = log(cert_count + 1) / (min_depth + 1) / log(registrable_diversity + 2)

This logic is implemented in org_root_sets_mv and related tables.
For best results, periodically review threshold settings and sample
output to ensure continued signal quality.

________________________________________________________________________
TYPICAL QUERY PATTERNS
________________________________________________________________________

* What techs does Org X run?
SELECT * FROM org_tech_facts
WHERE org_id = org_id('JPMorgan Chase') AND confidence >= 0.5;

* Specific source signals that led to a given tech detection at an org:
SELECT
    tech,
    confidence,
    source,
    ts,
    evidence
FROM tech_signals
WHERE org_id = org_id('JPMorgan Chase')
  AND tech = 'GitHub'
  AND confidence >= 0.5
ORDER BY ts DESC
LIMIT 50;

* All tech signals + evidence for a given organization:
SELECT
    tech,
    confidence,
    source,
    ts,
    evidence
FROM tech_signals
WHERE org_id = org_id('JPMorgan Chase')
  AND confidence >= 0.5
ORDER BY tech, ts DESC
LIMIT 200;

As a single array:

SELECT
    t.tech,
    groupArray((t.ts, t.evidence, t.source)) AS all_evidence,
    max(t.confidence) as max_confidence
FROM tech_signals AS t
WHERE t.org_id = org_id('JPMorgan Chase')
  AND t.confidence >= 0.5
GROUP BY t.tech
ORDER BY t.tech

* Correlated with certificates:

SELECT
    t.tech,
    t.confidence,
    t.source,
    t.ts,
    t.evidence,
    d.dn,
    d.organization,
    d.sn,
    d.lts,
    d.nbf
FROM tech_signals AS t
LEFT JOIN dns_flat AS d ON (d.dn = ((arrayFilter(x -> ((x.1) = 'dns'), t.evidence)[1]).2)) AND (d.org_id = t.org_id)
WHERE (t.org_id = org_id('JPMorgan Chase')) AND (t.confidence >= 0.5)
ORDER BY t.ts DESC
LIMIT 100

* Fetch the most recent cert for a particular detection:

SELECT *
FROM dns_flat
WHERE dn = 'githubcopilot-prod-106135.jpmchase.com'
  AND org_id = org_id('JPMorgan Chase')
ORDER BY lts DESC
LIMIT 1

* Which orgs appear to run GitLab in DACH?
SELECT
    o.display_name,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
INNER JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE (f.tech = 'GitLab') AND (f.confidence >= 0.5) AND (f.org_id IN (
    SELECT org_id
    FROM org_locations
    WHERE country IN ('de', 'ch', 'at')
))
ORDER BY f.last_seen DESC
LIMIT 100;


* Rollup of technology detections per (organization cluster, tech), with display names and de-duplicated org clustering.
For every technology (t.tech) detected:
- Count how many signals exist, grouped by canonical org cluster (ac.cluster_id, ac.display_name)
- Only include orgs that pass the allow_aliasing filter from org_root_sets (so, not infra/noisy orgs)
- Results are ordered by number of detections (most detected tech/org pairs first)

SELECT
    ac.cluster_id,
    ac.display_name,
    t.tech,
    count() AS detection_count
FROM tech_signals AS t
JOIN org_root_sets AS r
  ON t.registrable = r.registrable
 AND t.org_id = r.org_id
 AND r.allow_aliasing = 1
JOIN org_autocomplete_clustered AS ac
  ON r.org_id = ac.cluster_id
GROUP BY ac.cluster_id, ac.display_name, t.tech
ORDER BY detection_count DESC

* Growth of .bitbucket registrable domains in DE:
WITH
orgs_in_de AS (
    SELECT DISTINCT org_id
    FROM org_locations
    WHERE country = 'de'
),
first_seen AS (
    SELECT
        toStartOfMonth(min(lts)) AS month,
        dn
    FROM dns_flat
    WHERE org_id IN (SELECT org_id FROM orgs_in_de)
      AND NOT wildcard
      AND depth >= 3
      AND dn ILIKE '%bitbucket%'
    GROUP BY dn
),
last_seen AS (
    SELECT
        toStartOfMonth(max(lts)) AS month,
        dn
    FROM dns_flat
    WHERE org_id IN (SELECT org_id FROM orgs_in_de)
      AND NOT wildcard
      AND depth >= 3
      AND dn ILIKE '%bitbucket%'
    GROUP BY dn
)
SELECT
    months.month,
    countDistinct(first_seen.dn) AS new_dns,
    countDistinct(last_seen.dn) AS disappeared_dns,
    sum(new_dns) OVER (ORDER BY month ASC) AS cumulative,
    sum(new_dns) OVER (ORDER BY month ASC) - sum(disappeared_dns) OVER (ORDER BY month ASC) AS population,
    runningDifference(cast(sum(new_dns) OVER (ORDER BY month ASC), 'Int64')) AS net_growth,
    runningDifference(cast(sum(disappeared_dns) OVER (ORDER BY month ASC), 'Int64')) AS net_attrition
FROM (
    SELECT month FROM first_seen
    UNION
    SELECT month FROM last_seen
) AS months
LEFT JOIN first_seen ON months.month = first_seen.month
LEFT JOIN last_seen ON months.month = last_seen.month
GROUP BY months.month
ORDER BY months.month ASC;

* Recent ETL job runs and durations:
SELECT * FROM etl_ingest_metrics
ORDER BY ts DESC
LIMIT 25;

* Average ingest duration for a table/job:
SELECT job_name, table_name, avg(duration_ms) AS avg_ms
FROM etl_ingest_metrics
WHERE ts > now() - INTERVAL 7 DAY
GROUP BY job_name, table_name;

* Error summary for last 24h:
SELECT ts, job_name, error
FROM etl_ingest_metrics
WHERE error != ''
ORDER BY ts DESC;

* Per-table partition sizes (latest):
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY table, partition DESC;

* Largest partitions by bytes:
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY bytes DESC
LIMIT 10;

* Investigate active merges/mutations/TTL:
SELECT table, partition_id, progress, is_mutation, elapsed
FROM system.merges
WHERE active = 1;

* Check ongoing TTL moves:
SELECT * FROM system.ttl_moves WHERE table = 'ct_certificates';

* Show long-running queries:
SELECT * FROM slow_queries
WHERE query_duration_ms > 10000
ORDER BY event_time DESC
LIMIT 10;

* Show current org alias clusters:
SELECT * FROM org_autocomplete_clustered
WHERE length(aliases) > 1
ORDER BY cert_count DESC;

* List organizations ordered by number of distinct roots:
SELECT
    c.display_name,
    r.org_id,
    count() AS roots_count
FROM org_root_sets AS r
LEFT JOIN org_autocomplete_clustered AS c
    ON r.org_id = c.cluster_id
GROUP BY r.org_id, c.display_name
ORDER BY roots_count DESC
LIMIT 10;

* Fuzzy search for orgs containing "acme" (case-insensitive, matches aliases or display_name)
SELECT
    display_name,
    cert_count
FROM org_autocomplete_clustered
WHERE display_name ILIKE '%acme%'
   OR arrayExists(x -> positionCaseInsensitive(x, 'acme') > 0, aliases)
ORDER BY cert_count DESC
LIMIT 10;

* Find orgs running "GitLab" with confidence at least 0.5, showing sample alias
SELECT
    o.display_name,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE f.tech = 'GitLab' AND f.confidence >= 0.5
ORDER BY f.confidence DESC, f.last_seen DESC
LIMIT 25;

* All tech detected for orgs matching 'acme'
SELECT
    f.tech,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE arrayExists(x -> positionCaseInsensitive(x, 'acme') > 0, o.aliases)
ORDER BY f.confidence DESC, f.tech

* Tech detected for a particular SAN (e.g., "example.com")
SELECT
    t.tech,
    t.confidence,
    t.last_seen
FROM org_tech_facts t
JOIN dns_flat d ON t.org_id = d.org_id
WHERE d.dn = 'example.com'
ORDER BY t.confidence DESC, t.tech

* Given a user-typed org name, get cluster and all known aliases
SELECT
    cluster_id,
    display_name,
    aliases
FROM org_autocomplete_clustered
WHERE arrayExists(x -> positionCaseInsensitive(x, 'AT&T') > 0, aliases)
   OR display_name ILIKE '%AT&T%';

* Autocomplete by organization name

-- Position-independent 
SELECT
    cluster_id AS org_id,
    display_name
FROM org_autocomplete_clustered
WHERE display_name ILIKE '%ven%'
   OR arrayExists(x -> positionCaseInsensitive(x, 'ven') > 0, aliases)
ORDER BY cert_count DESC, display_name ASC
LIMIT 10;

-- Only at start of search 
SELECT
    cluster_id AS org_id,
    display_name
FROM org_autocomplete_clustered
WHERE display_name ILIKE 'Ven%'
   OR arrayExists(x -> positionCaseInsensitive(x, 'ven') = 1, aliases)
ORDER BY cert_count DESC, display_name ASC
LIMIT 10;

________________________________________________________________________
MANAGING DETECTIONS
________________________________________________________________________

== Adding a new detection

Insert your detection rule/pattern: 

-- regex rule (matching subdomains of ghe.com):
INSERT INTO tech_patterns (id, pattern, is_regex, regex_prefix, tech, weight)
VALUES (10, '^([a-z0-9-]+\\.)+ghe\\.com$', 1, 'ghe.com', 'GitHub Enterprise Cloud (Data Residency)', 1.0);

Reload the dictionaries:

SYSTEM RELOAD DICTIONARY dict_tech_patterns;
SYSTEM RELOAD DICTIONARY dict_regex_prefixes;

(Optional) Refresh mv_ct_tech_signals (if you want to apply the new detections to existing data immediately, otherwise it'll refresh automatically on schedule):

SYSTEM REFRESH VIEW mv_ct_tech_signals;

(Optional) Check for your detections:

SELECT
    ts,
    org_id,
    registrable,
    evidence
FROM tech_signals
WHERE tech = 'GitHub Enterprise Cloud (Data Residency)'
  AND source = 'ct_heuristic'
  AND ts >= now() - INTERVAL 1 HOUR
ORDER BY ts DESC
LIMIT 100;

________________________________________________________________________
PERFORMANCE CONSIDERATIONS
________________________________________________________________________

+ Append-only ingest path – partitions by lts; no in-flight duplicates.
+ Surrogate org_id (UInt64) – all joins/group-bys via hash key.
+ Large "wide" parts – minimizes background merges and write amplification.
+ Bloom / tokenbf / ngrambf – efficient substring filters on org/dn/issuer.
+ PSL helpers – registrable, root fields use built-in PSL.
+ AggregatingMergeTree rollups – constant size w.r.t. distinct-key.
+ FLAT/HASHED dictionaries – sub-ms lookups for heuristics and API.
+ Signal scalability – tech_signals is append-only, disk grows ~=~ evidence volume.

________________________________________________________________________
EXTENSION HOOKS
________________________________________________________________________

* Add new heuristic pattern:
INSERT INTO tech_patterns …;
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

* Add new signal source:
INSERT INTO tech_signals FORMAT JSONEachRow …;

* Suppress a false positive:
INSERT INTO tech_signals VALUES
('2025-07-01 12:00:00', org_id('acme co'), 'acme.com',
'WordPress', 0, 'active_scan', [('note','manual suppression')], 1);

* Bump or rollback a detection pattern:
UPDATE tech_patterns SET weight = 0.4, version = version+1
WHERE pattern = 'bitbucket';
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

* TTL to cold storage:
ALTER TABLE ct_certificates
MODIFY TTL lts + INTERVAL 24 MONTH TO VOLUME 'blob';
   ALTER TABLE tech_signals
     MODIFY TTL ts + INTERVAL 18 MONTH TO VOLUME 'blob';

* Manual/forced view refresh:
SYSTEM REFRESH VIEW org_root_sets_mv;

* Check view refresh status:
SELECT * FROM system.view_refreshes WHERE view_name LIKE '%org%';

* Debug/override:
Force a refresh and inspect downstream tables after any batch.
________________________________________________________________________
OPERATIONAL METRICS & OBSERVABILITY
________________________________________________________________________

==== etl_ingest_metrics ====

Tracks every ETL/ingest run for audit, debugging, and monitoring pipeline health.
Records when, what, and how much data was loaded, plus run time and errors.

Typical Insert (after ETL job):

INSERT INTO etl_ingest_metrics
  (job_name, table_name, rows_loaded, rows_inserted, duration_ms, partition, source, error)
VALUES
  ('certslurp', 'ct_certificates', 1048576, 1048576, 12500, '202506', 'S3', '');

Common Queries

Recent job runs and durations:
SELECT * FROM etl_ingest_metrics
ORDER BY ts DESC
LIMIT 25;

Average ingest duration for a table/job:
SELECT job_name, table_name, avg(duration_ms) AS avg_ms
FROM etl_ingest_metrics
WHERE ts > now() - INTERVAL 7 DAY
GROUP BY job_name, table_name;

Error summary:
SELECT ts, job_name, error
FROM etl_ingest_metrics
WHERE error != ''
ORDER BY ts DESC;

==== mv_partition_stats ====

Live summary of active rows and bytes for each table/partition.
Monitor storage, spot partitions that are too large, empty, or not merging as expected.

Example Queries

Per-table partition sizes (latest):
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY table, partition DESC;

Largest partitions:
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY bytes DESC
LIMIT 10;

==== system tables ====

Monitor merges, mutations, TTL progress:
system.merges, system.ttl_moves, system.view_refreshes, etc.

Monitor merges, mutations, TTL progress:
SELECT table, partition_id, progress, is_mutation, elapsed
FROM system.merges
WHERE active = 1;

Check ongoing TTL moves:
SELECT * FROM system.ttl_moves WHERE table = 'ct_certificates';

==== slow_queries ====

Use for long-running query analysis and troubleshooting.

SELECT *
FROM slow_queries
WHERE query_duration_ms > 10000
ORDER BY event_time DESC
LIMIT 10;

==== Table and Column Sizes / Compression Stats ==== 

SELECT
    name,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.columns
WHERE table = 'ct_certificates'
GROUP BY name
ORDER BY sum(data_compressed_bytes) DESC

SELECT
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed_size,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.columns
WHERE table = 'ct_certificates'

SELECT
    partition,
    sum(rows) AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE (`table` = 'ct_certificates') AND active
GROUP BY partition
ORDER BY partition ASC
________________________________________________________________________
SCHEMA MAINTENANCE / WRITING
________________________________________________________________________

* Do NOT manually write to org_root_sets, org_alias_map, or org_autocomplete_clustered; these are maintained by periodic refreshable MVs.
* Use SYSTEM REFRESH VIEW  to trigger immediate refresh if required.
* All TTLs and refresh intervals are defined in DDL and can be tuned via ALTER TABLE.

-----------------------------------------------------------------------*/

/*-----------------------------------------------------------------------
  0.  Helper UDFs
-----------------------------------------------------------------------*/
DROP FUNCTION IF EXISTS norm_token_key;
DROP FUNCTION IF EXISTS org_id;
DROP FUNCTION IF EXISTS canonical_org_name;


/* norm_token_key
Deterministically normalizes an organization (or entity) name string into a concise, fuzzy-matchable token key.

Purpose:
- Enables fuzzy and loose deduplication, grouping, and searching of organization names.
- Serves as the foundational normalization function for clustering or entity resolution workflows.

Normalization Process:
1. Converts the input string to lowercase using UTF-8 safe lowercasing.
2. Splits the string into chunks on spaces
3. Checks the current chunk. 
  3a. If it looks like an acronym (e.g. M.I.T.), it'll strip all . characters at once
  3b. Otherwise, it'll strip any non-. letter/number, then split on . (e.g. "salesforce.com" -> "salesforce","com", "l'oreal"->"loreal")
4. Filters out common organizational stopwords (e.g., inc, ltd, llc, corp, company, etc.) and tokens of length <= 1.
5. Deduplicates tokens and sorts them alphabetically.
6. Joins tokens back into a single space-separated string.
7. If the resulting normalized key is empty, falls back to a simpler partial normalization (norm_token_key_partial) which removes all punctuation and filters basic stopwords.
8. If still empty, returns the original input string.

Example Usage:
SELECT norm_token_key('AT&T Services, Inc.')  -- Returns: 'att services'
SELECT norm_token_key('Queen’s University of Belfast')  -- Returns: 'belfast queens university'
SELECT norm_token_key('F5, Inc.')  -- Returns: 'f5'

Note:
- This function is designed to balance aggressive normalization with the need to preserve meaningful tokens.
- Hyphenated names like "T-Mobile" normalize to "tmobile" by removing the hyphen.
- Stopword filtering is customizable via the underlying stopword list in norm_token_key_filter_stopwords.

If you update these functions, you will need to rebuild everything that depends on/stores an org_id.

Can be tested with:

SELECT
    org_name,
    norm_token_key_full(org_name) AS full,
    norm_token_key_partial(org_name) AS fallback
FROM
(
  SELECT arrayJoin(['F5, Inc.', 'AT&T Services, Inc.', 'E.C.L. LIMITED', 'S.I.C.E.S. S.R.L.', 
    'Salesforce Inc', 'Salesforce.com, Inc', 'A Company Srl', 'O\'Reilly Media, Inc.', 'J.P. Morgan Chase & Co.', 
    'Alphabet, Inc.', 'Google LLC', 'M.I.T.', 'L\'Oréal S.A.', 'Bayerische Motoren Werke AG', '123 Industries', 
    'Acme Corp.', 'N/A Corp', 'Example LLC - Division 5', 'Foo & Bar Co.', 'ACME, Co.', 'Nippon Steel & Sumitomo Metal Corporation', 
    'Telefonaktiebolaget LM Ericsson', 'Renault S.A.S.', 'KPMG LLP', 'R&D Solutions Inc.', 'D&B Corporation', 
    'T-Mobile US, Inc.', 'Schrödinger GmbH', 'NVIDIA Corporation', 'H&M Hennes & Mauritz AB', 'LVMH Moët Hennessy Louis Vuitton', 
    'Tata Consultancy Services Limited', 'Zoë & Co.', 'Company XYZ, Ltd.', '3M Company', '7-Eleven, Inc.', 'Smith, Johnson & Associates', 
    'G.E. Healthcare', 'The Walt Disney Company', 'Coca-Cola Co.', 'Deloitte LLP', 'Ernst & Young LLP', 'PwC (PricewaterhouseCoopers)', 
    'BASF SE', 'Müller GmbH & Co. KG', 'Renée\'s Café & Bakery, LLC']) 
  AS org_name
)

Stopword list can be tuned with results from:

SELECT
    token,
    count() AS n
FROM
(
    SELECT arrayJoin(splitByChar(' ', norm_token_key(display_name))) AS token
    FROM org_autocomplete_clustered
)
GROUP BY token
ORDER BY n DESC
LIMIT 50;
*/
CREATE OR REPLACE FUNCTION norm_token_key_filter_stopwords AS
  (tokens, min_len) -> arrayFilter(
    x -> length(x) > min_len AND NOT x IN (
      'inc','incorporated','llc','co','company','corp','corporation','ltd','limited','sa','gmbh',
      'the','and','&','-','of','pvt','llp','bv','spa','as','oy','aps','ab','sarl','nv','ag','sl',
      'sas','kg','kgaa','pte','plc','ltda','sl','pty','srl','at','for','se','sp','com','www','nv','amba',
      'gesellschaft','societe','société','empresa','firma','compania','compañía','compania','associés','vereniging',
      'de','del'
    ),
    tokens
  );

CREATE OR REPLACE FUNCTION norm_token_key_full AS s ->
arrayStringConcat(
    arraySort(
        arrayDistinct(
            norm_token_key_filter_stopwords(
                arrayFlatten(
                    arrayMap(
                        chunk ->
                            if(
                                match(chunk, '^(\\p{L}\.){2,}$'),
                                -- it’s a dot-acronym: remove all dots at once
                                [ replaceRegexpAll(chunk, '\\.', '') ],
                                -- otherwise: strip any non-dot letter/number, then split on dot
                                splitByRegexp('[^\\p{L}\\p{N}]+', replaceRegexpAll(chunk, '[^\p{L}\p{N}.]', ''))
                            ),
                        -- first, split the entire string on spaces
                        splitByChar(' ', lowerUTF8(s))
                    )
                ),
                1
            )
        )
    ),
    ' '
);


CREATE OR REPLACE FUNCTION norm_token_key_partial AS
  (s) -> arrayStringConcat(
    arraySort(
     arrayDistinct(
      norm_token_key_filter_stopwords(
        splitByChar(
          ' ',
          replaceRegexpAll(lowerUTF8(s), '[^\\p{L}\\p{N}\\s]+', '')
        ),
        0
      )
     )
    ),
    ' '
  );

CREATE OR REPLACE FUNCTION norm_token_key AS
  (s) ->
    if(length(norm_token_key_full(s)) > 0, norm_token_key_full(s),
       if(length(norm_token_key_partial(s)) > 0, norm_token_key_partial(s), s));

/* org_id

Returns a deterministic 64-bit hash of an organization name for fast joins and clustering.
Provides a stable, normalized org key for joins, groupings, and identity resolution across tables.

How it works:
* Calls norm_token_key on the input string.
* Applies sipHash64 to produce a UInt64 ID.

Example:

SELECT org_id('AT&T Inc.')  -- Returns: 4058091255216720182  (example value)

*/
CREATE OR REPLACE FUNCTION org_id AS
  (s) -> sipHash64(norm_token_key(s));


/* canonical_org_name 

Select the best canonical display name from a set of possible organization name variants. Ideal for normalizing org names in certificate analytics, 
entity resolution, autocomplete, or any use-case with many noisy string variants.

* Underlying normalization is done with norm_token_key.
* Designed to work well for company and organization names from certificate fields, directory listings, customer data, etc.
* Can be adapted with different scoring rules for domain or internationalization needs.

== Usage

Typically used over a grouped array of org names, e.g.:

SELECT
    cluster_id AS org_id,
    arraySlice(aliases, 1, 5) AS org_examples,
    display_name AS canonical
FROM org_autocomplete_clustered
ORDER BY length(aliases) DESC
LIMIT 100;

Examples:

SELECT canonical_org_name(['PepsiCo Inc', 'Pepsico, Inc', 'PEPSICO, INC', 'Pepsico Inc'])
-- Returns 'Pepsico, Inc'

SELECT canonical_org_name([
    'NEC CORPORATION',
    'NEC Corporation'
])
-- Returns 'NEC Corporation'

SELECT canonical_org_name([
    'AMERICAN INTERNATIONAL GROUP INC.',
    'American International Group, Inc.'
])
-- Returns 'American International Group, Inc.'

== How it Works

Given an array of org name variants, canonical_org_name:

1. Normalizes each name (using norm_token_key) to group together truly-similar names.
2. Counts the frequency of each variant.
3. Scores each variant based on:
	* Preferred casing: Favors Title Case (e.g., Pepsico, Inc) over ALLCAPS or all lowercase.
	* Penalizes ALLCAPS: (e.g., PEPSICO, INC).
	* Frequency: Higher frequency is better.
	* Similarity to the first variant: Jaccard string similarity to the normalized form of the first name in the list.
	* Length: Slightly prefers longer names (to avoid over-aggressive abbreviation).
4. Returns the original-cased string with the highest score.

Scoring Algorithm (Heuristic)

A score is computed for each name variant as follows:
* +1000 points if the string is in Title Case (initcapUTF8).
* −500 points if the string is ALL CAPS (upperUTF8).
* +100 * frequency in the input array.
* +100 * Jaccard similarity to the normalized form of the first variant.
* +0.01 * string length (slight tie-breaker).

The variant with the highest total score is returned.
*/
CREATE OR REPLACE FUNCTION canonical_org_name AS names ->
    arrayFirst(
        x -> x.2 != '',
        arraySort(
            x -> (
                -1 * (
                    (initcapUTF8(x.2) = x.2 ? 1000 : 0) - (upperUTF8(x.2) = x.2 ? 500 : 0)
                    + x.3 * 100
                    + stringJaccardIndex(x.1, x.4) * 100
                    + length(x.2) * 0.01
                ),
                x.2
            ),
            arrayMap(
                n -> (
                    norm_token_key(n),
                    n,
                    countEqual(names, n),
                    norm_token_key(names[1])
                ),
                arrayDistinct(names)
            )
        )
    ).2
;


/*
  PSL-aware effective TLD + 1
*/
CREATE OR REPLACE FUNCTION psl_registrable AS (dn) ->
    cutToFirstSignificantSubdomainCustom(dn, 'public_suffix_list');

/*
  The PSL *suffix* of the given domain (eTLD)
*/
CREATE OR REPLACE FUNCTION psl_suffix AS (dn) ->
    arrayStringConcat(
        arrayPopFront(
            arrayFilter(x -> length(x) > 0, splitByChar('.', cutToFirstSignificantSubdomainCustom(dn, 'public_suffix_list')))
        ),
        '.'
    );

-- The ICANN TLD of a given domain
CREATE OR REPLACE FUNCTION psl_tld AS (dn) -> 
    topLevelDomain(dn);

/*-----------------------------------------------------------------------
  1.  Raw certificate landing table
-----------------------------------------------------------------------*/
CREATE TABLE IF NOT EXISTS ct_certificates
(
    /* core identity */
    cn  String,
    sub String,
    iss String,
    sn  String,

    /* multi-value RDN / SAN fields */
    em   Array(String),
    ou   Array(String),
    org  Array(String),
    loc  Array(String),
    prv  Array(String),
    co   Array(String),
    st   Array(String),
    pc   Array(String),
    dns  Array(String),
    ips  Array(String),
    uris Array(String),

    /* validity window */
    nbf DateTime64(0, 'UTC'),
    naf DateTime64(0, 'UTC'),

    /* CT-log position */
    log String,
    li  UInt64,
    lts DateTime64(6, 'UTC')
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(lts)          -- append-only
ORDER BY (log, li)
SETTINGS
    index_granularity       = 8192,
    min_bytes_for_wide_part = 134217728;

/* codecs & LowCardinality */
ALTER TABLE ct_certificates
    -- switch to LC + LZ4HC for the log name
    MODIFY COLUMN log LowCardinality(String) CODEC(LZ4HC),

    -- core certificate strings -> ZSTD level-3
    MODIFY COLUMN cn   String         CODEC(ZSTD(3)),
    MODIFY COLUMN sub  String         CODEC(ZSTD(3)),
    MODIFY COLUMN iss  String         CODEC(ZSTD(3)),
    MODIFY COLUMN sn  String         CODEC(ZSTD(3)),

    -- multi-value arrays -> keep existing type, add codec
    MODIFY COLUMN dns  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN em   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN org  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN ou   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN loc  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN prv  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN co   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN st   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN pc   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN uris Array(String)  CODEC(ZSTD(3));

/* secondary indexes */
ALTER TABLE ct_certificates
    ADD INDEX IF NOT EXISTS idx_dns_bloom  dns TYPE bloom_filter(0.02) GRANULARITY 2,
    ADD INDEX IF NOT EXISTS idx_cn     cn TYPE tokenbf_v1(2048,3,0)      GRANULARITY 4,
    ADD INDEX IF NOT EXISTS idx_sub    sub TYPE tokenbf_v1(2048,3,0)      GRANULARITY 4;

/*
  registrable_canonical_override

  Table of manual overrides mapping registrable domains to their *canonical*
  organizational owner. Used to fix cases where the default org_id logic
  is insufficient (e.g. mergers, legal parent/child relationships, etc).

  - registrable:  Domain name (e.g., 'example.com').
  - org_id:       Canonical owner org_id for this registrable.
  - owner_name:   Display name for reference.

  Notes:
    - Use only for true overrides—avoid overuse.
    - Always keep entries deduplicated and current.
*/
CREATE OR REPLACE TABLE registrable_canonical_override
(
    registrable String,
    org_id      UInt64,
    owner_name  String,

    INDEX idx_org_id (org_id) TYPE set(0) GRANULARITY 1,
    INDEX idx_owner_name_tokenbf (owner_name) TYPE tokenbf_v1(2048,3,0) GRANULARITY 4
)
ENGINE = ReplacingMergeTree()
ORDER BY registrable
SETTINGS index_granularity = 8192;

DROP DICTIONARY IF EXISTS dict_registrable_canonical_override;
CREATE DICTIONARY dict_registrable_canonical_override
(
    registrable String,
    org_id      UInt64,
    owner_name  String,
)
PRIMARY KEY registrable
SOURCE(CLICKHOUSE(TABLE 'registrable_canonical_override'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

/*-----------------------------------------------------------------------
  2.  Domain-flattened view  (one row per SAN)
-----------------------------------------------------------------------*/

DROP TABLE IF EXISTS dns_flat;
CREATE TABLE dns_flat
(
    dn           String,
    registrable  String,
    root         String,
    tld          String,
    depth        UInt8,
    wildcard     Bool,
    dn_tokens_full Array(String),
    dns_hash UInt64 MATERIALIZED sipHash64(dn),

    organization String,
    ou           String,
    locality     String,
    province     String,
    country      String,
    org_id       UInt64,
    nbf          DateTime64(0, 'UTC'),
    sn           String,
    lts          DateTime64(6, 'UTC'),

    /* token Bloom on scalar domains */
    INDEX idx_dn_token_scalar dn TYPE tokenbf_v1(2048,3,0) GRANULARITY 4, 
    INDEX idx_tld  tld           TYPE tokenbf_v1(2048,3,0) GRANULARITY 4,
    INDEX idx_dn_tokens_full dn_tokens_full TYPE tokenbf_v1(2048,3,0) GRANULARITY 4,

    -- index on country
    INDEX idx_country country TYPE set(0) GRANULARITY 1
)
ENGINE = ReplacingMergeTree(lts)
PARTITION BY toYYYYMM(lts)
ORDER BY (country, registrable, root, dn)
SETTINGS index_granularity = 8192,
         min_bytes_for_wide_part = 134217728;


DROP VIEW IF EXISTS mv_dns_flat;
CREATE MATERIALIZED VIEW mv_dns_flat
TO dns_flat AS
WITH
    lowerUTF8(arrayJoin(arrayDistinct(dns))) AS dn,
    psl_registrable(dn) AS registrable,
    psl_suffix(registrable) AS root,
    psl_tld(registrable) AS tld,
    length(splitByChar('.', dn)) - length(splitByChar('.', registrable)) AS depth,
    startsWith(dn, '*.') AS wildcard,
    arrayFilter(x -> length(x) > 0, splitByChar('.', dn)) AS dn_tokens_full
SELECT
    dn,
    registrable,
    root,
    tld,
    depth,
    wildcard,
    dn_tokens_full,

    -- hierarchical override lookup
    COALESCE(
        NULLIF(dictGetOrDefault('dict_registrable_canonical_override', 'owner_name', registrable, ''), ''),
        NULLIF(dictGetOrDefault('dict_registrable_canonical_override', 'owner_name', root, ''), ''),
        arrayJoin(if(length(org) > 0, org, ['']))
    ) AS organization,

    if(length(ou) > 0, ou[1], '')        AS ou,
    if(length(loc) > 0, loc[1], '')      AS locality,
    if(length(prv) > 0, prv[1], '')      AS province,
    if(length(co) > 0, co[1], '')        AS country,

    org_id(organization)                 AS org_id,
    nbf, sn, lts
FROM ct_certificates;

/*-----------------------------------------------------------------------
  3.  Org -> certificate and org -> country lookup views
-----------------------------------------------------------------------*/

/* ----------------------------------------------------------------------
   org_locations: Flattened mapping of each certificate observation
   to a specific (org_id, country, province, locality, tld) tuple.
   Enables detailed, row-level lookups and granular filtering of org
   activity by any combination of geographic or TLD attributes.

   - Each row: one (org, country, province, locality, tld) combination.
   - Fast filtering on country/tld via token bloom filter indexes.
   - Useful for answering "which orgs exist in this region/TLD?".
------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE org_locations
(
    org_id   UInt64,
    country  LowCardinality(String),
    province String,
    locality String,
    tld      LowCardinality(String),

    INDEX idx_org_id (org_id) TYPE set(0) GRANULARITY 1,
    INDEX idx_tld (tld) TYPE set(0) GRANULARITY 1
)
ENGINE = ReplacingMergeTree()
ORDER BY (country, province, locality, tld, org_id);

/* ----------------------------------------------------------------------
   mv_org_locations: Materialized view to populate org_locations,
   lowercasing and normalizing all geo/TLD fields, omitting blanks.
   Refreshes on a schedule to keep lookup data up to date.
------------------------------------------------------------------------ */
DROP VIEW IF EXISTS mv_org_locations;
CREATE MATERIALIZED VIEW mv_org_locations
REFRESH EVERY 1 DAY OFFSET 4 HOUR RANDOMIZE FOR 1 HOUR
APPEND TO org_locations AS
SELECT
    multiIf(
        canonical_org_name != '', org_id(canonical_org_name),
        am.cluster_id IS NOT NULL, am.cluster_id,
        org_id(df.organization)
    ) AS org_id,
    lowerUTF8(df.country)   AS country,
    lowerUTF8(df.province)  AS province,
    lowerUTF8(df.locality)  AS locality,
    lowerUTF8(df.tld)       AS tld
FROM (
    SELECT *,
        COALESCE(
            NULLIF(dictGetOrDefault('dict_registrable_canonical_override', 'owner_name', registrable, ''), ''),
            NULLIF(organization, ''),
            ''
        ) AS canonical_org_name
    FROM dns_flat
) AS df
LEFT JOIN org_alias_map_expanded AS am
    ON lowerUTF8(df.organization) = lowerUTF8(am.alias)
WHERE organization != ''
GROUP BY
    org_id, country, province, locality, tld;

/* ----------------------------------------------------------------------
   org_location_agg: Aggregated view of all locations and TLDs
   observed for a given org_id. Collapses many org_locations rows
   into a single row per org_id, with arrays for countries, provinces,
   localities, and TLDs. Indexed with token bloom filters for
   fast "array contains" queries on any location dimension.

   - Each row: one org_id, arrays for all observed values.
   - Great for "show me orgs in tld X or country Y" queries.
   - Enables ultra-fast multi-value filters.
------------------------------------------------------------------------ */
CREATE OR REPLACE TABLE org_location_agg
(
    org_id    UInt64,
    countries Array(String),
    provinces Array(String),
    localities Array(String),
    tlds      Array(String),

    INDEX idx_countries_bf  countries   TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_tlds_bf       tlds        TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_provinces_bf  provinces   TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_localities_bf localities  TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,

    PRIMARY KEY org_id
)
ENGINE = MergeTree
ORDER BY org_id;


/* ----------------------------------------------------------------------
   mv_org_location_agg: Materialized view that generates
   org_location_agg, deduplicating and normalizing arrays,
   and omitting empty values for all geo/TLD dimensions.
   Keeps the aggregated locations in sync with source data.
------------------------------------------------------------------------ */
DROP VIEW IF EXISTS mv_org_location_agg;
CREATE MATERIALIZED VIEW mv_org_location_agg
REFRESH EVERY 1 DAY DEPENDS ON mv_org_locations
TO org_location_agg AS
SELECT
    org_id,
    arrayFilter(x -> x != '', groupArrayDistinct(lowerUTF8(country)))   AS countries,
    arrayFilter(x -> x != '', groupArrayDistinct(lowerUTF8(province)))  AS provinces,
    arrayFilter(x -> x != '', groupArrayDistinct(lowerUTF8(locality)))  AS localities,
    arrayFilter(x -> x != '', groupArrayDistinct(lowerUTF8(tld)))       AS tlds
FROM org_locations
WHERE country != ''
GROUP BY org_id;


CREATE TABLE iso_countries
(
    name String,
    alpha_2 FixedString(2),
    alpha_3 FixedString(3),
    country_code String,
    iso_3166_2 String,
    region String,
    sub_region String,
    intermediate_region String,
    region_code String,
    sub_region_code String,
    intermediate_region_code String
)
ENGINE = MergeTree
ORDER BY (alpha_2);

INSERT INTO iso_countries
SELECT
    name,
    `alpha-2` AS alpha_2,
    `alpha-3` AS alpha_3,
    `country-code` AS country_code,
    `iso_3166-2` AS iso_3166_2,
    region,
    `sub-region` AS sub_region,
    `intermediate-region` AS intermediate_region,
    `region-code` AS region_code,
    `sub-region-code` AS sub_region_code,
    `intermediate-region-code` AS intermediate_region_code
FROM url('https://raw.githubusercontent.com/packfiles/ISO-3166/refs/heads/master/all/all.json', 'JSONEachRow');

/*-----------------------------------------------------------------------
  4.  Org -> registrable-domain roll-up
-----------------------------------------------------------------------*/
/*
   This table is automatically maintained by org_diversity_signal_mv.
   Do not manually write to this table, it will refresh on a schedule.

Threshold tuning queries:

-- Drill down into orgs associated with a single registrable:
SELECT
    org_id,
    min(depth) AS min_depth,
    count() AS n,
    any(organization) AS org_name
FROM dns_flat
WHERE registrable = 'nba.com'
GROUP BY org_id
ORDER BY
    min_depth ASC,
    n DESC
LIMIT 10

-- Overall spread and a few key stats:
SELECT
    quantile(0.5)(registrable_count) AS median,
    quantile(0.9)(registrable_count) AS p90,
    quantile(0.95)(registrable_count) AS p95,
    quantile(0.99)(registrable_count) AS p99,
    max(registrable_count) AS max_count,
    count() AS orgs_total
FROM org_diversity_signal;

-- Orgs with the highest registrable diversity:
SELECT
    org_id,
    org_name,
    registrable_count
FROM org_diversity_signal
ORDER BY registrable_count DESC
LIMIT 50;

-- Bucketed:
SELECT
    intDiv(registrable_count, 10) * 10 AS bucket,
    count() AS orgs_in_bucket
FROM org_diversity_signal
GROUP BY bucket
ORDER BY bucket;

-- Check who is just above and just below a candidate threshold:
SELECT org_id, org_name, registrable_count
FROM org_diversity_signal
WHERE registrable_count BETWEEN 900 AND 21473440
ORDER BY registrable_count DESC;
*/
CREATE OR REPLACE TABLE org_diversity_signal (
    org_id             UInt64,
    registrable_count  UInt64,
    min_depth          UInt8,
    org_name           String
)
ENGINE = MergeTree
ORDER BY org_id;

DROP VIEW IF EXISTS org_diversity_signal_mv;
CREATE MATERIALIZED VIEW org_diversity_signal_mv
REFRESH EVERY 1 DAY OFFSET 2 HOUR RANDOMIZE FOR 1 HOUR
TO org_diversity_signal AS
SELECT
    org_id,
    countDistinct(registrable) AS registrable_count,
    min(depth) AS min_depth,
    any(organization) AS org_name
FROM dns_flat
WHERE organization != ''
GROUP BY org_id
ORDER BY registrable_count DESC;

/*
  org_alias_denylist

  Table of organization IDs (org_id) that are explicitly *disallowed* from
  being considered as canonical or alias owners of registrables.
  Used to block infra, CDN, proxy, and other "unmergeable" orgs from
  being aggregated or aliased.

  - org_id:   Unique organization signature (UInt64 hash, never null).
  - org_name: Display name for reference.

  Notes:
    - Only a small, highly curated set of orgs should be in this table.
    - Maintain via explicit governance—mistakes can break canonical logic.
    - Write changes atomically if possible.
*/
CREATE OR REPLACE TABLE org_alias_denylist
(
    org_id      UInt64,
    org_name    String,

    INDEX idx_org_id (org_id) TYPE set(0) GRANULARITY 1,
    INDEX idx_org_name_tokenbf (org_name) TYPE tokenbf_v1(2048,3,0) GRANULARITY 4
)
ENGINE = ReplacingMergeTree()
ORDER BY org_id
SETTINGS index_granularity = 8192;

/*
  dict_org_alias_denylist

  Dictionary view of org_alias_denylist, for ultra-fast lookup from SQL.
  Used to check in queries and materialized views if an org is "denylisted".

  - PRIMARY KEY: org_id
  - Source:      org_alias_denylist table

  Tunable:
    - LIFETIME: How often the dictionary refreshes (300–3600 seconds).
                Lower = fresher updates, higher = less overhead.
*/
DROP DICTIONARY IF EXISTS dict_org_alias_denylist;
CREATE DICTIONARY dict_org_alias_denylist
(
    org_id   UInt64,
    org_name String
)
PRIMARY KEY org_id
SOURCE(CLICKHOUSE(TABLE 'org_alias_denylist'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);


/*
  org_root_sets

  This table is automatically maintained by org_root_sets_mv.
  Do not manually write to this table, it will refresh on a schedule.

  Roll-up table that links each org_id to its associated registrables,
  with computed signals for canonical ownership, infra status, and
  aliasing policy. This is the definitive record for whether an org
  can be considered the "owner" or "alias" for a domain.

  - org_id:             Unique organization signature (UInt64 hash).
  - registrable:        Registrable domain (e.g., 'example.com').
  - is_canonical_owner: True if org is canonical owner of the registrable.
  - is_infra_org:       True if org is infra (denylist/diversity).
  - allow_aliasing:     True if org can participate in alias/cluster logic.
  - min_nbf, min_lts, max_lts: Date boundaries for the relationship.

  Maintained by: org_root_sets_mv materialized view.

  Important:
    - Do not manually write to this table.
    - The business logic (diversity threshold, denylist, overrides)
      is tunable in the underlying views/dictionaries.
    - Tune diversity threshold and denylist as needed for your use case.
*/
CREATE OR REPLACE TABLE org_root_sets (
    org_id      UInt64,
    organization String,
    registrable String,
    is_canonical_owner Bool,
    is_infra_org Bool,
    allow_aliasing Bool,
    min_depth UInt8,
    min_nbf     DateTime64(0, 'UTC'),
    min_lts     DateTime64(6, 'UTC'),
    max_lts     DateTime64(6, 'UTC'),

    INDEX idx_org_registrable (org_id, registrable) TYPE set(0) GRANULARITY 1
)
ENGINE = MergeTree
ORDER BY (org_id, registrable);

/*
  org_root_sets_mv

  Materialized view that automatically maintains and refreshes the
  org_root_sets table, rolling up all observed (org_id, registrable)
  relationships from dns_flat and computing canonical ownership,
  infra/denylist status, and aliasing eligibility.

  Key logic:
    - Canonical ownership is determined either by explicit override or
      by the org_id's relationship to the registrable.
    - If organization is empty, but there’s a canonical override for that registrable, use the override value. Otherwise, 
    skip rows where the org is empty and there’s no override.
    - Infra orgs are those appearing in the denylist *or* surpassing the
      org diversity threshold (via org_diversity_signal).
    - Aliasing is permitted only for non-infra orgs or the canonical owner.

  Inputs:
    - dns_flat: Source of organization->registrable relationships.
    - org_diversity_signal: Diversity threshold for "infra" detection.
    - org_alias_denylist: Explicit blocklist for infra orgs.
    - registrable_canonical_override: Manual owner overrides.

  Important tunables:
    - Adjust org diversity threshold in org_diversity_signal as needed.
    - Maintain org_alias_denylist and canonical overrides with care.
*/
DROP VIEW IF EXISTS org_root_sets_mv;
CREATE MATERIALIZED VIEW org_root_sets_mv
REFRESH EVERY 1 DAY OFFSET 3 HOUR RANDOMIZE FOR 1 HOUR
TO org_root_sets AS
WITH
    COALESCE(
      NULLIF(dictGetOrDefault('dict_registrable_canonical_override', 'owner_name', d.registrable, ''), ''),
      NULLIF(d.organization, ''),
      ''
    ) AS organization,
    org_id(organization) AS org_id
SELECT
    organization,
    org_id,
    d.registrable AS registrable,
    min(d.nbf) AS min_nbf,
    min(d.lts) AS min_lts,
    max(d.lts) AS max_lts,
    min(d.depth) AS min_depth,
    -- Is this org the canonical owner of this registrable?
    dictGetOrDefault('dict_registrable_canonical_override', 'org_id', d.registrable, 0) = org_id AS is_canonical_owner,
    -- Is it an infra org? (in denylist or hits org diversity threshold)
    dictHas('dict_org_alias_denylist', org_id) 
      OR (max(ds.org_id) != 0) AS is_infra_org,
    -- Allow aliasing if NOT infra, or if canonical owner
    (NOT is_infra_org OR is_canonical_owner) AS allow_aliasing
FROM dns_flat AS d
LEFT JOIN org_diversity_signal AS ds
  ON (org_id(d.organization) = ds.org_id)
  AND (ds.registrable_count > 10000) -- Tunable diversity threshold
WHERE organization != ''
GROUP BY
    org_id,
    d.registrable,
    organization
HAVING organization != '';


/*-----------------------------------------------------------------------
  5.  Organization SipHash signatures + autocomplete (fuzzy backbone)
-----------------------------------------------------------------------*/

/*----------------------------------------------------------------------------
 org_alias_map: Organization Alias Cluster Mapping

 This table is automatically maintained by org_alias_map_mv.
 Do not manually write to this table, it will refresh on a schedule. 
------------------------------------------------------------------------------

 This materialized view constructs a mapping between pairs of organization IDs
 (org_id) that appear to represent aliases—i.e., different names used for the 
 same real-world organization—based on shared registrable domains observed in 
 certificate transparency logs.

 For every pair of org_ids that share registrables (i.e., both have appeared as
 certificate subjects for the same apex domain), a row is emitted if the pair
 meets the following heuristics:

   - Both orgs are eligible for aliasing (allow_aliasing = 1).
   - They share a minimum required number of registrables (inter_cnt >= N).
   - Both orgs have sufficient domain proximity (min_depth thresholds).

 The resulting table is used for:
   - Clustering orgs for autocomplete, search, and analytics.
   - Deduplicating org-centric analytics and reducing noisy splits.

------------------------------------------------------------------------------
 HEURISTIC: inter_cnt (shared registrables threshold)

 The `inter_cnt` column measures how many distinct registrable domains the
 org_id pair has in common (i.e., how many roots both have certificates for).
 This serves as a strong, practical signal that two org_ids represent
 different variants/aliases for the same entity.

 *Rationale:*
   - It's common for companies to appear under multiple org names due to M&A,
     subsidiaries, spelling/locale differences, or data entry variation.
   - But accidental collisions (i.e., two unrelated orgs both touching the same
     domain) are rare, especially as the count increases.

 *Tuning Guidance:*
   - A higher `inter_cnt` threshold (e.g., >= 5) yields higher-precision
     clusters (less risk of over-aggregation), but lower recall (some true
     aliases are missed if they only overlap on a few domains).
   - Lowering the threshold (e.g., to 3) increases recall, at the risk of
     pulling together unrelated orgs with coincidental overlap (e.g., 
     resellers, resold SaaS, CDNs).

   - Tune `inter_cnt` by examining the distribution (see example query below).
     A good rule of thumb: set the threshold just high enough to avoid most
     accidental aliasing, but low enough to catch real-world org variants.
     For most corp/brand CT datasets, 3–5 is a reasonable starting point.

     -- Example: Distribution of inter_cnt (shared registrable roots)
     SELECT inter_cnt, count(*) FROM org_alias_map GROUP BY inter_cnt ORDER BY inter_cnt DESC

   - Consider complementing this with domain depth and infra/super-issuer
     filtering to avoid clustering infrastructure providers.
*/
CREATE OR REPLACE TABLE org_alias_map
(
    alias_id     UInt64,
    canonical_id UInt64,
    shared       Array(String),
    inter_cnt    UInt64,
    uni_cnt      UInt64,

    INDEX idx_alias_id (alias_id) TYPE set(0) GRANULARITY 1,
    INDEX idx_canonical_id (canonical_id) TYPE set(0) GRANULARITY 1
)
ENGINE = MergeTree
ORDER BY (alias_id, canonical_id);

-- p_by_alias_id:
-- Projection to accelerate lookups of all canonical_id clusters for a given alias_id.
-- Optimizes queries that retrieve all clusters or shared registrables associated with a particular alias_id.
ALTER TABLE org_alias_map
ADD PROJECTION IF NOT EXISTS p_by_alias_id
(
    SELECT canonical_id, shared, inter_cnt, uni_cnt
    GROUP BY canonical_id, alias_id, shared, inter_cnt, uni_cnt
);

-- p_root_counts:
-- Projection to efficiently compute the number of alias entries per alias_id (cluster size).
-- Optimizes "top-N largest clusters" and fast alias_id cardinality queries.
ALTER TABLE org_alias_map
ADD PROJECTION IF NOT EXISTS p_root_counts
(
    SELECT alias_id, count() AS alias_count
    GROUP BY alias_id
);

DROP VIEW IF EXISTS org_alias_map_mv;
CREATE MATERIALIZED VIEW org_alias_map_mv
REFRESH EVERY 1 DAY DEPENDS ON org_root_sets_mv
TO org_alias_map AS
SELECT
    a.org_id AS alias_id,
    b.org_id AS canonical_id,
    groupArrayDistinct(a.registrable) AS shared,
    uniqExact(a.registrable) AS inter_cnt,
    uniqExact(arrayConcat([a.registrable], [b.registrable])) AS uni_cnt
FROM org_root_sets a
JOIN org_root_sets b
    ON a.registrable = b.registrable
    AND a.org_id < b.org_id
WHERE a.allow_aliasing = 1
  AND b.allow_aliasing = 1
GROUP BY alias_id, canonical_id
HAVING min(a.min_depth) <= 1 AND min(b.min_depth) <= 1 AND inter_cnt >= 4 AND (inter_cnt / uni_cnt) >= 0.5;


/* This table is automatically maintained by org_autocomplete_clustered_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE OR REPLACE TABLE org_autocomplete_clustered
(
    cluster_id   UInt64,
    display_name String,
    cert_count   UInt64,
    aliases      Array(String),

    INDEX idx_display_name_tokenbf (display_name) TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_display_name_ngram   (display_name) TYPE ngrambf_v1(3, 2048, 3, 0) GRANULARITY 4,
    INDEX idx_aliases_tokenbf      (aliases)      TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_aliases_ngram        (aliases)      TYPE ngrambf_v1(3, 2048, 3, 0) GRANULARITY 4,
)
ENGINE = MergeTree
ORDER BY (cert_count DESC, display_name)
SETTINGS 
    index_granularity = 8192, 
    allow_experimental_reverse_key = 1;


/* org_autocomplete_clustered_mv

This materialized view builds the autocomplete/search index for 
organization names, clustering related aliases and grouping certificate
ownership under canonical display names.

- Surfaces the most "authoritative" display name for an organization cluster
(as determined by certificate count, name depth, and canonical flags).
- Emits all known aliases for autocomplete, grouped by the best canonical name.
- Enables robust organization search/autocomplete in user-facing UIs.
- Uses cluster_id as a synthetic key (hash of canonical name).

How it works:
1. name_signals:  
    - Ingests org names and org_id from org_root_sets.
    - Gathers metrics: certificate count, depth in the org tree, canonical owner, infra org flag.

2. scored_names:  
    - Calculates an authority_score for each org string in a cluster:
        authority_score = cert_count * 1
                        - min_depth * 5
                        + 200 (if canonical owner)
                        - 100 (if infra org)
    - Note that infra orgs are NOT excluded, but are penalized. This allows
    names like "Cloudflare, Inc." or "Microsoft Corporation" to remain
    searchable/autocompletable, but less likely to become the main cluster
    display name unless they are truly the canonical entity.

3. cluster_map & clustered_orgs:
    - Maps aliases to canonical org_ids for deduplication and alias expansion.
    - Groups all org names/aliases and their authority scores for a given cluster.

4. cluster_with_top:
    - Sorts aliases by descending authority score.
    - cluster_id = hash of display_name, used as key.

5. Final SELECT:
    - Emits:
        - display_name: best canonical name for the cluster (highest-scoring)
        - cluster_id: stable hash of display_name.
        - cert_count: sum of all certificates for the cluster.
        - aliases: unique set of all alias org names in the cluster (for autocomplete).
    - Orders clusters by descending cert_count.

Notes:
    - "Infra" orgs (e.g. Cloudflare, Microsoft, Akamai) are included, but
    generally will not dominate clusters unless they are true root owners.
    - If a name appears in multiple clusters (e.g. due to acquisition or
    poor root set resolution), it may appear in multiple alias lists.


If clustering is too broad, use the following query to debug:

SELECT
    am.alias_id,
    am.canonical_id,
    am.inter_cnt,
    am.shared
FROM org_autocomplete_clustered AS ac
JOIN org_alias_map AS am
    ON ac.cluster_id = am.canonical_id OR ac.cluster_id = am.alias_id
WHERE ac.cluster_id = <cluster ID>
ORDER BY am.inter_cnt DESC

*/
DROP VIEW IF EXISTS org_autocomplete_clustered_mv;
CREATE MATERIALIZED VIEW org_autocomplete_clustered_mv
REFRESH EVERY 1 DAY OFFSET 7 HOUR RANDOMIZE FOR 1 HOUR
TO org_autocomplete_clustered AS
WITH
    name_signals AS (
        SELECT
            organization,
            org_id(organization)           AS org_id,
            count()                        AS cert_count,
            min(min_depth)                 AS min_depth,
            maxIf(is_canonical_owner, 1) = 1  AS is_canon,
            maxIf(is_infra_org,      1) = 1  AS is_infra
        FROM org_root_sets
        GROUP BY org_id, organization
    ),
    scored_names AS (
        SELECT
            org_id,
            organization,
            cert_count,
            min_depth,
            is_canon,
            is_infra,
            (cert_count)            * 1.0
          - (min_depth)            * 5.0
          + (is_canon ? 200 : 0)
          - (is_infra ? 100 : 0)
            AS authority_score
        FROM name_signals
    ),
    cluster_map AS (
        SELECT alias_id AS org_id, canonical_id FROM org_alias_map
        UNION ALL
        SELECT canonical_id AS org_id, canonical_id FROM org_alias_map
    ),
    clustered_orgs AS (
        SELECT
            if(isNull(cm.canonical_id) OR cm.canonical_id = 0, sn.org_id, cm.canonical_id) AS cluster_id,
            groupArray((sn.organization, sn.authority_score)) AS orgs,
            sum(sn.cert_count) AS cert_count
        FROM scored_names sn
        LEFT JOIN cluster_map cm ON sn.org_id = cm.org_id
        GROUP BY cluster_id
    ),
    cluster_with_top AS (
        SELECT
            cluster_id,
            arraySort(x -> -x.2, orgs) AS top_orgs,
            orgs,
            cert_count
        FROM clustered_orgs
    )
SELECT
    canonical_org_name(arraySlice(arrayMap(x -> (x.1), top_orgs), 1, 1)) AS display_name,
    org_id(display_name) AS cluster_id,
    sum(cert_count) AS cert_count,
    arrayDistinct(flatten(groupArray(arrayDistinct(arrayMap(x -> (x.1), orgs))))) AS aliases
FROM cluster_with_top
GROUP BY display_name
ORDER BY cert_count DESC;

/*---------------------------------------------------------------------------
  org_alias_map_expanded

  Purpose:
    - Provides a complete, fast-mapping "resolver" table for mapping any known
      organization alias (string) or its alias_id (sipHash64) to its canonical 
      cluster (cluster_id), and the cluster's display_name.

  Usage:
    - Use to canonicalize organization references from any input string or alias.
    - Can JOIN on `alias` (string) or `alias_id` (UInt64) to efficiently resolve 
      to the cluster_id and canonical display name used throughout the system.
    - This table is refreshed automatically from org_autocomplete_clustered.
  
  Difference from org_alias_map:
    - org_alias_map is a pairwise mapping of alias_id <-> canonical_id based on 
      shared registrables (roots). It is optimized for graph-style queries 
      (e.g., find all org_ids in a cluster, compute cluster sizes, etc).
    - org_alias_map_expanded is a *flat* mapping: for every alias string 
      observed in a cluster, it maps directly to that cluster's canonical_id 
      and display_name. It is ideal for typeahead/autocomplete, UI lookup, 
      and anywhere fast canonicalization is required.

  Example query:
    -- Given an org name, get its canonical cluster id and display name:
    SELECT cluster_id, display_name
    FROM org_alias_map_expanded
    WHERE alias = 'Fujitsu America Inc'
-----------------------------------------------------------------------------*/

CREATE OR REPLACE TABLE org_alias_map_expanded
(
    alias       String,
    alias_id    UInt64,
    cluster_id  UInt64,
    display_name String,

    INDEX idx_alias_id (alias_id) TYPE set(0) GRANULARITY 1
)
ENGINE = MergeTree
ORDER BY (alias, cluster_id);

DROP VIEW IF EXISTS org_alias_map_expanded_mv;
CREATE MATERIALIZED VIEW org_alias_map_expanded_mv
REFRESH EVERY 1 DAY DEPENDS ON org_autocomplete_clustered_mv
TO org_alias_map_expanded AS
SELECT
    arrayJoin(aliases) AS alias,
    org_id(alias) AS alias_id,
    cluster_id,
    display_name
FROM org_autocomplete_clustered;

/*-----------------------------------------------------------------------
  6.  Technology-matching components
-----------------------------------------------------------------------*/

/* 6.1  Pattern dictionary (tiny, hand-editable) */
CREATE TABLE tech_patterns
(
    id            UInt32,
    pattern       String,
    is_regex      UInt8  DEFAULT 0,
    regex_prefix  String DEFAULT '',
    tech          String,
    weight        Float32 DEFAULT 1.0,
    updated_at    DateTime DEFAULT now(),
    version       UInt32  DEFAULT 1
)
ENGINE = MergeTree
PRIMARY KEY id
ORDER BY id; 

DROP DICTIONARY IF EXISTS dict_tech_patterns;

CREATE DICTIONARY dict_tech_patterns
(
    id       UInt32,
    pattern  String,
    is_regex UInt8,
    regex_prefix String,
    tech     String,
    weight   Float32
)
PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'tech_patterns'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

DROP DICTIONARY IF EXISTS dict_regex_prefixes;
CREATE DICTIONARY dict_regex_prefixes
(
    regex_prefix String,
    pattern      String,
    tech         String,
    weight       Float32
)
PRIMARY KEY regex_prefix, pattern
SOURCE(
    CLICKHOUSE(
        QUERY '
            SELECT regex_prefix, pattern, tech, weight
            FROM tech_patterns
            WHERE is_regex = 1
        '
    )
)
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 3600);

CREATE MATERIALIZED VIEW tech_tokens
ENGINE = TinyLog
AS
SELECT id,
       arrayJoin(
           arrayFilter(x -> x != '',
                       splitByNonAlpha(lower(pattern)))
       ) AS token
FROM tech_patterns
WHERE is_regex = 0;

/* 6.2  Raw signal sink (external scanners + CT heuristics) */
DROP TABLE IF EXISTS tech_signals;
CREATE TABLE IF NOT EXISTS tech_signals
(
    -- Detection identity columns
    org_id UInt64 DEFAULT 0,
    registrable  String,
    tech         LowCardinality(String),
    evidence     Array(Tuple(type String, value String)),

    -- Latest metadata
    ts           DateTime64(3, 'UTC'),
    confidence   Float32,
    source       LowCardinality(String), -- Conventional defaults: ct_heuristic, active_scan

    dns String MATERIALIZED (arrayFirst(x -> x.1 = 'dns', evidence).2),
    dns_hash UInt64 MATERIALIZED (if(length(dns) > 0, sipHash64(dns), 0)),

    -- evidence_id: Uniquely identifies a normalized set of evidence for this detection.
    -- Computed as the SipHash64 of a string concatenation of all sorted evidence elements,
    -- where each element is type:value, array-sorted and joined with '\x1E' (ASCII record
    -- separator), e.g.: [('dns','foo.com'),('asn','123')] -> sipHash64('asn:123\x1Edns:foo.com')
    -- Ensures deduplication even if array order differs.
    evidence_id UInt64 MATERIALIZED
        sipHash64(concat(arrayStringConcat(
            arrayMap(x -> concat(x.1, ':', x.2), arraySort(arrayDistinct(evidence))),
            '\x1E'
        ), source)),

    state        Enum8(
        'active' = 1,
        'suppressed' = 2,
        'pending_review' = 3,
        'expired' = 4
    ) DEFAULT 'active',
    is_negative  UInt8 DEFAULT 0,

    INDEX idx_org_id (org_id) TYPE set(0) GRANULARITY 1,
    INDEX idx_dns (dns) TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4
)
ENGINE = ReplacingMergeTree(ts)
PARTITION BY toYYYYMM(ts)
ORDER BY (tech, evidence_id, dns_hash)
SETTINGS 
    index_granularity = 8192,
    min_bytes_for_wide_part = 134217728,
    deduplicate_merge_projection_mode = 'drop';

ALTER TABLE tech_signals
ADD PROJECTION IF NOT EXISTS p_by_org_tech_tld_country
(
    SELECT
        org_id,
        tech,
        confidence,
        ts,
        dns_hash
    ORDER BY (org_id, tech, dns_hash)
);

/* 6.3  CT-driven heuristic signals */
DROP VIEW IF EXISTS mv_ct_tech_signals;
CREATE MATERIALIZED VIEW mv_ct_tech_signals
REFRESH EVERY 1 DAY OFFSET 6 HOUR RANDOMIZE FOR 1 HOUR
APPEND TO tech_signals AS
SELECT
    df.lts AS ts,
    CASE
        WHEN canonical_org_name != '' THEN org_id(canonical_org_name)
        WHEN am.cluster_id IS NOT NULL THEN am.cluster_id
        ELSE org_id(df.organization)
    END AS org_id,
    df.registrable,
    tp.tech,
    tp.weight AS confidence,
    'ct_heuristic' AS source,
    arraySort(arrayDistinct([tuple('dns', df.dn)])) AS evidence,
    0 AS is_negative
FROM (
    SELECT
        *,
        COALESCE(
            NULLIF(dictGetOrDefault('dict_registrable_canonical_override', 'owner_name', registrable, ''), ''),
            NULLIF(organization, ''),
            ''
        ) AS canonical_org_name
    FROM dns_flat
) AS df
CROSS JOIN (
    SELECT pattern, tech, weight
    FROM dict_tech_patterns
    WHERE is_regex = 0
) AS tp
LEFT JOIN org_alias_map_expanded AS am
    ON lowerUTF8(df.organization) = lowerUTF8(am.alias)
WHERE
    arrayExists(
        tok -> arrayExists(
            pat -> positionCaseInsensitive(tok, pat) > 0,
            (SELECT groupArray(token) FROM tech_tokens)
        ),
        df.dn_tokens_full
    )
    AND positionCaseInsensitive(df.dn, tp.pattern) > 0
    AND df.wildcard = false
    AND df.depth > 0
UNION ALL
-- Regex match (dict_regex_prefixes)
SELECT
    df.lts AS ts,
    CASE
        WHEN canonical_org_name != '' THEN org_id(canonical_org_name)
        WHEN am.cluster_id IS NOT NULL THEN am.cluster_id
        ELSE org_id(df.organization)
    END AS org_id,
    df.registrable,
    rp.tech,
    rp.weight AS confidence,
    'ct_heuristic' AS source,
    arraySort(arrayDistinct([tuple('dns', df.dn)])) AS evidence,
    0 AS is_negative
FROM (
    SELECT
        *,
        COALESCE(
            NULLIF(dictGetOrDefault('dict_registrable_canonical_override', 'owner_name', registrable, ''), ''),
            NULLIF(organization, ''),
            ''
        ) AS canonical_org_name
    FROM dns_flat
) AS df
CROSS JOIN (
    SELECT regex_prefix, pattern, tech, weight
    FROM dict_regex_prefixes
) AS rp
LEFT JOIN org_alias_map_expanded AS am
    ON lowerUTF8(df.organization) = lowerUTF8(am.alias)
WHERE
    (rp.regex_prefix = '' OR positionCaseInsensitive(df.dn, rp.regex_prefix) > 0)
    AND df.wildcard = false
    AND df.depth > 0
    AND match(df.dn, rp.pattern);

/* 6.4  Aggregated truth table  (org × tech) */
DROP TABLE IF EXISTS org_tech_facts;
CREATE TABLE org_tech_facts
(
    org_id UInt64,
    tech String,
    confidence Float32,
    last_seen DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(last_seen)
PARTITION BY toYYYYMM(last_seen)
ORDER BY (org_id, last_seen, tech);


DROP VIEW IF EXISTS mv_org_tech;
CREATE MATERIALIZED VIEW mv_org_tech
REFRESH EVERY 8 HOUR RANDOMIZE FOR 1 HOUR DEPENDS ON mv_ct_tech_signals
TO org_tech_facts AS
SELECT
    org_id,
    tech,
    IF(max(is_negative) = 1, 0, max(confidence)) AS confidence,
    max(ts) AS last_seen
FROM tech_signals FINAL 
GROUP BY org_id, tech;

/*-----------------------------------------------------------------------
  7. Observability
-----------------------------------------------------------------------*/

CREATE TABLE IF NOT EXISTS etl_ingest_metrics
(
    ts          DateTime64(3, 'UTC') DEFAULT now64(),
    job_name    LowCardinality(String),   -- e.g. "certslurp", "active_scan"
    table_name  LowCardinality(String),   -- e.g. "ct_certificates"
    rows_loaded UInt64,
    rows_inserted UInt64,
    duration_ms UInt32,
    partition   String,                   -- e.g. "202506" for June 2025
    source      LowCardinality(String),   -- e.g. "S3", "API", etc
    error       String DEFAULT ''         -- error message if any, else ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (job_name, table_name, ts);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_partition_stats
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (table, partition)
AS
SELECT
    now64() AS ts,
    table,
    partition,
    sum(rows) AS rows,
    sum(bytes_on_disk) AS bytes
FROM system.parts
WHERE active = 1
GROUP BY table, partition;

CREATE TABLE IF NOT EXISTS slow_queries
(
    event_time DateTime,
    query_duration_ms UInt32,
    query_text String,
    user String,
    database String,
    read_rows UInt64,
    read_bytes UInt64
)
ENGINE = MergeTree
ORDER BY event_time;

/*-----------------------------------------------------------------------
  8. Seeds
-----------------------------------------------------------------------*/
INSERT INTO tech_patterns (id, pattern, is_regex, tech, weight) VALUES
(1,'bitbucket',0,'Bitbucket', 0.5),
(2,'gitlab',   0,'GitLab',    0.5),
(3,'github',   0,'GitHub',    0.5),
(4,'vercel',   0,'Vercel',    0.5),
(5,'heroku',   0,'Heroku',    0.5),
(6,'splunk',   0,'Splunk',    0.5),
(7,'jenkins',  0,'Jenkins',   0.5),
(8,'jfrog',    0,'JFrog',     0.5);
(9,'sharepoint',    0,'SharePoint',     0.5);

INSERT INTO tech_patterns (id, pattern, is_regex, regex_prefix, tech, weight)
VALUES (9, '^([a-z0-9-]+\\.)+ghe\\.com$', 1, 'ghe.com', 'GitHub Enterprise Cloud (Data Residency)', 1.0);

SYSTEM RELOAD DICTIONARY dict_tech_patterns;

-- Seed org_alias_denylist
WITH orgs AS (
    SELECT arrayJoin([
        'Microsoft Corporation',
        'Cloudflare Inc',
        'Edgio, Inc.',
        'Edgecast Inc.',
        'Incapsula Inc',
        'Criteo Technology SAS',
        'CRITEO SA',
        'CDNETWORKS CO., LTD.',
        'Shopify Inc.',
        'Salesforce.com, Inc.',
        'Salesforce, Inc.',
        'Adobe Systems Co., Ltd.',
        'Adobe Systems Incorporated',
        'HCA - Information Technology & Services, Inc.',
        'Firebase, Inc.',
        'Verizon Digital Media Services Inc.',
        'Kyndryl, Inc.',
        'TIBCO Software Inc',
        'Atanar Technologies',
        'MarkMonitor, Inc.',
        'Dynamic Network Services, Inc.',
        'Dynamic Network Services Limited',
        'Fastly, Inc',
        'Distil Inc',
        'DISTIL NETWORKS, INC.',
        'Shared Services Canada',
        'Acquia Inc',
        'Khoros, LLC',
        'Jive Software Inc.',
        'Tyler Technologies, Inc.',
        'Tyler Technologies',
        'Akamai Technologies, Inc.'
    ]) AS org_name
)
INSERT INTO org_alias_denylist
SELECT
    org_id(org_name) AS org_id,
    org_name
FROM orgs;

SYSTEM RELOAD DICTIONARY dict_org_alias_denylist;

-- Seed registrable_canonical_override
WITH
    arrayJoin([
        ('nba.com',       'NBA Media Ventures, LLC'),
        ('trutv.com',     'Warner Bros. Discovery, Inc.'),
        ('github.com',    'GitHub, Inc.'),
        ('ghe.com',    'GitHub, Inc.'),
        ('linkedin.com',  'LinkedIn Corporation'),
        ('splunkcloud.com',          'Splunk Inc.'),
        ('splunkcloudgc.com',        'Splunk Inc.'),
        ('vercel-storage.com',       'Vercel Inc.'),
        ('vercel.app',               'Vercel Inc.'),
        ('workers.dev',              'Cloudflare, Inc.'),
        ('pages.dev',                'Cloudflare, Inc.'),
        ('herokuapp.com',            'Heroku'),
        ('herokuspace.com',          'Heroku'),
        ('herokusnitest.com',        'Heroku'),
        ('plesk.page',               'WebPros International GmbH'),
        ('platformsh.site',          'Platform.sh Ltd'),
        ('catalyst-sandbox-vercel.store', 'BigCommerce Inc.'),
        ('innfinite.co.uk',          'Innfinite Web Solutions Ltd'),
        ('moonscale.net',            'Ici la Lune'),
        ('cprapid.com',              'cPanel LLC'),
        ('bookfocal.com',            'Focal Inc.'),
        ('vagabundo.co',             'Vagabundo'),
        ('konimbo.co.il',            'Konimbo'),
        ('it-dept.ca',               'Shared Services Canada'),
        ('dell.com',                 'Dell Technologies Inc.'),
        ('dellfaas.com',             'Dell Technologies Inc.'),
        ('att-idns.net',             'AT&T Services, Inc.'),
        ('att-mail.com',             'AT&T Services, Inc.'),
        ('att.net',                  'AT&T Services, Inc.'),
        ('atttest.com',              'AT&T Services, Inc.'),
        ('attws.com',                'AT&T Services, Inc.'),
        ('cingular.net',             'AT&T Services, Inc.'),
        ('sbc.com',                  'AT&T Services, Inc.'),
        ('att.com',                  'AT&T Services, Inc.'),
        ('criticalmissionsolutions.com', 'Jacobs Solutions Inc.'),
        ('jacobs.com',                   'Jacobs Solutions Inc.'),
        ('keywcorp.com',                 'Jacobs Solutions Inc.'),
        ('streetlightdata.com',          'Jacobs Solutions Inc.')
    ]) AS pair
INSERT INTO registrable_canonical_override
SELECT
    pair.1 AS registrable,
    org_id(pair.2) AS org_id,
    pair.2 AS owner_name;