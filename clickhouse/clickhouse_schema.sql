/*-----------------------------------------------------------------------
Certificate-to-Technology Analytics Schema  – 2025-07-01
-----------------------------------------------------------------------

End-to-end analytics pipeline for extracting, clustering, and analyzing certificate transparency logs to detect technology use by organization. 
Schema is designed for high-volume ingest, append-only safety, efficient surrogate keys, rapid fuzzy/org lookup, and scalable heuristics—leveraging ClickHouse 
refreshable materialized views for automatic periodic rollup, aliasing, and autocomplete.

________________________________________________________________________
DATA FLOW & ARCHITECTURE
________________________________________________________________________

CT logs → certslurp archives → ct_certificates
                        │
        ┌───────────────┴────────────────────────────────────────┐
        │   [mv_dns_flat] (per-SAN)                              │
        │   + PSL: org_id, root, etc                             │ 
dict_tech_patterns (HASHED dictionary) ←── tiny, versioned       │
        │                                                        ▼
        ▼                                           [pattern/token/regex match]
 [mv_ct_tech_signals] ─────────────────────────────────────→ tech_signals ←── external scan/API
        ▲                                                        ▲
        │                                                        │ merges & suppression
        │                                                        │
  [mv_org_tech]                                       (AggregatingMergeTree)
        │
        ▼
 org_tech_facts (read-only, deduped)


Org clustering, autocomplete & aliasing:

    mv_org_roots (periodic refresh)
    │
    ▼
    org_roots → org_root_sets (periodic refresh)
    │
    └─→ org_alias_map (periodic refresh)
    └─→ org_autocomplete_clustered (periodic refresh)

All organizational grouping uses org_id (UInt64; deterministic SipHash64 of normalized tokens) for speed and deduplication.

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

3. mv_org_cert  (MergeTree)
 - One row per (org_id, certificate)
 - Avoids arrayJoin at query time for exact org lookups.

5. org_roots  (AggregatingMergeTree)
 - Pre-deduped list of registrable domains for each org_id
 - Drives org_root_sets, which feeds alias clustering.
 - Refreshed automatically; do not manually insert.

6. org_root_sets  (periodically refreshed MergeTree)
 - Most recent root domain set per org_id (one row per org)
 - Refreshed automatically; do not manually insert.

7. org_alias_map  (periodically refreshed MergeTree)
 - All pairs of org_ids sharing ≥2 registrable roots
 - Used for alias/cluster detection and autocomplete grouping.

8. org_autocomplete_clustered  (periodically refreshed MergeTree)
 - Autocomplete table: cluster_id, aliases, display_name, cert_count
 - Used for fuzzy org lookup, UI, reporting.

9. tech_patterns/dict_tech_patterns/dict_regex_prefixes
 - Editable patterns and live-reload dictionaries for token/regex → tech mapping.

10. tech_signals  (ReplacingMergeTree)
 - All technology "signals" (from heuristics + external sources)
 - Evidence, source, confidence, is_negative fields
 - Very robust deduplication logic
 - Continuously refreshed by mv_ct_tech_signals

11. mv_ct_tech_signals
 - Insert tech_signals from token and regex matches in mv_dns_flat.
 - Refreshes on schedule

12. mv_org_tech / org_tech_facts (AggregatingMergeTree/view)
 - One row per (org_id, tech); highest-confidence, deduped
 - API and reporting table

13. etl_ingest_metrics
 - All ETL/ingest job runs (row count, duration, errors, partition, etc.)

14. mv_partition_stats, slow_queries
 - System-level metrics and performance diagnostics

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

==========================================================================
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
ORDER BY ts DESC
LIMIT 1

* Which orgs appear to run GitLab in DE + CH?
SELECT
    o.display_name,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
INNER JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE (f.tech = 'GitLab') AND (f.confidence >= 0.5) AND (f.org_id IN (
    SELECT org_id
    FROM dns_flat
    WHERE country IN ('DE', 'CH')
))
ORDER BY f.last_seen DESC
LIMIT 50;

* Growth of .bitbucket registrable domains in DE:
SELECT toStartOfMonth(nbf) AS month,
uniqExact(registrable) AS n
FROM dns_flat
WHERE country='DE' AND dn ILIKE '%bitbucket%'
GROUP BY month ORDER BY month;

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
    length(r.roots) AS roots_count
FROM org_roots AS r
LEFT JOIN org_autocomplete_clustered AS c
    ON r.org_id = c.cluster_id
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
      'sas','kg','kgaa','pte','plc','ltda','sl','pty','srl','at','for','se','sp','com','www',
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
SAMPLE BY li
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

/*-----------------------------------------------------------------------
  2.  Domain-flattened view  (one row per SAN)
-----------------------------------------------------------------------*/
DROP TABLE IF EXISTS dns_flat;
CREATE TABLE dns_flat
(
    dn           String,
    registrable  String,
    root         String,
    dn_tokens    Array(String),
    dn_tokens_full Array(String),

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
    INDEX idx_dn_token_array  dn_tokens      TYPE tokenbf_v1(2048,3,0) GRANULARITY 4,
    INDEX idx_dn_tokens_full dn_tokens_full TYPE tokenbf_v1(2048,3,0) GRANULARITY 4,

    -- index on country
    INDEX idx_country country TYPE set(0) GRANULARITY 1
)
ENGINE = ReplacingMergeTree(lts)
PARTITION BY toYYYYMM(lts)
ORDER BY (country, registrable, root, dn);

DROP VIEW IF EXISTS mv_dns_flat;
CREATE MATERIALIZED VIEW mv_dns_flat
TO dns_flat AS
SELECT
    lower(arrayJoin(arrayDistinct(dns)))               AS dn,
    cutToFirstSignificantSubdomain(dn)                 AS registrable,
    firstSignificantSubdomain(dn)                      AS root,
    splitByRegexp('[^\\p{L}\\p{N}]+', root)            AS dn_tokens,
    splitByRegexp('[^\\p{L}\\p{N}]+', dn)              AS dn_tokens_full,

    arrayJoin(org)                                     AS organization,
    arrayElement(ou,  1)                               AS ou,
    arrayElement(loc, 1)                               AS locality,
    arrayElement(prv, 1)                               AS province,
    arrayElement(co,  1)                               AS country,
    org_id(organization)                               AS org_id,

    nbf, sn, lts
FROM ct_certificates;

/*-----------------------------------------------------------------------
  3.  Org → certificate lookup view
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_cert
ENGINE = MergeTree
PARTITION BY toYYYYMM(lts)
ORDER BY (org_id, sn)
AS
SELECT
    org_id(org) AS org_id,
    sn,
    nbf,
    naf, 
    lts
FROM ct_certificates
ARRAY JOIN org
WHERE org != '';

/*-----------------------------------------------------------------------
  4.  Org → registrable-domain roll-up
-----------------------------------------------------------------------*/
/* 
   Accumulates all historical aggregates for each org_id (potentially multiple versions).

   This table is automatically maintained by mv_org_roots.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE TABLE IF NOT EXISTS org_roots
(
    org_id UInt64,
    roots Array(String),
    root_cnt UInt64,
    min_nbf DateTime64(0, 'UTC'),
    max_naf DateTime64(0, 'UTC'),
    min_lts DateTime64(6, 'UTC'),
    max_lts DateTime64(6, 'UTC')
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(min_lts)
ORDER BY (org_id);

DROP VIEW IF EXISTS mv_org_roots;
CREATE MATERIALIZED VIEW mv_org_roots
REFRESH EVERY 1 DAY OFFSET 1 HOUR RANDOMIZE FOR 1 HOUR
TO org_roots AS
SELECT
    org_id(organization) AS org_id,
    groupUniqArray(registrable) AS roots,
    countDistinct(registrable) AS root_cnt,
    min(nbf) AS min_nbf,
    max(nbf) AS max_naf,
    min(lts) AS min_lts,
    max(lts) AS max_lts
FROM dns_flat
GROUP BY org_id;

/*
   Stores only the latest, deduplicated snapshot of roots per org_id.

   This table is automatically maintained by org_root_sets_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE OR REPLACE TABLE org_root_sets
(
    org_id    UInt64,
    roots     Array(String),
    root_cnt  UInt64
)
ENGINE = MergeTree
ORDER BY org_id;

DROP VIEW IF EXISTS org_root_sets_mv;

CREATE MATERIALIZED VIEW org_root_sets_mv
REFRESH EVERY 1 DAY OFFSET 3 HOUR RANDOMIZE FOR 1 HOUR
TO org_root_sets AS
SELECT
    org_id,
    roots,
    length(roots) AS root_cnt
FROM (
    SELECT *,
        row_number() OVER (PARTITION BY org_id ORDER BY min_nbf DESC) AS rn
    FROM org_roots
)
WHERE rn = 1;

/*-----------------------------------------------------------------------
  5.  Organization SipHash signatures + autocomplete (fuzzy backbone)
-----------------------------------------------------------------------*/

/* This table is automatically maintained by org_alias_map_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE OR REPLACE TABLE org_alias_map
ENGINE = MergeTree
ORDER BY (alias_id, canonical_id) AS
SELECT
    a.org_id                                  AS alias_id,
    b.org_id                                  AS canonical_id,
    arrayIntersect(a.roots, b.roots)          AS shared,
    length(shared)                            AS inter_cnt,
    length(arrayUnion(a.roots, b.roots))      AS uni_cnt
FROM org_root_sets a
JOIN org_root_sets b ON a.org_id < b.org_id
WHERE length(arrayIntersect(a.roots, b.roots)) >= 2;

CREATE MATERIALIZED VIEW org_alias_map_mv
REFRESH EVERY 1 DAY OFFSET 5 HOUR RANDOMIZE FOR 1 HOUR
TO org_alias_map AS
SELECT
    a.org_id                                  AS alias_id,
    b.org_id                                  AS canonical_id,
    arrayIntersect(a.roots, b.roots)          AS shared,
    length(shared)                            AS inter_cnt,
    length(arrayUnion(a.roots, b.roots))      AS uni_cnt
FROM org_root_sets a
JOIN org_root_sets b ON a.org_id < b.org_id
WHERE length(shared) >= 2;

/* This table is automatically maintained by org_autocomplete_clustered_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE TABLE org_autocomplete_clustered
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
SETTINGS index_granularity = 8192, allow_experimental_reverse_key = 1;

CREATE MATERIALIZED VIEW org_autocomplete_clustered_mv
REFRESH EVERY 1 DAY OFFSET 7 HOUR RANDOMIZE FOR 1 HOUR
TO org_autocomplete_clustered AS
SELECT
    if(m.canonical_id != 0, m.canonical_id, c.org_id) AS cluster_id,
    groupArrayDistinct(c.organization) AS aliases,
    canonical_org_name(groupArrayDistinct(c.organization)) AS display_name,
    sum(c.count) AS cert_count
FROM (
    SELECT
        org_id(arrayJoin(org)) AS org_id,
        arrayJoin(org)         AS organization,
        count()                AS count
    FROM ct_certificates
    WHERE arrayJoin(org) != ''
    GROUP BY org_id, organization
) AS c
LEFT JOIN org_alias_map m ON c.org_id = m.alias_id
GROUP BY cluster_id
ORDER BY cert_count DESC;

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

    -- evidence_id: Uniquely identifies a normalized set of evidence for this detection.
    -- Computed as the SipHash64 of a string concatenation of all sorted evidence elements,
    -- where each element is type:value, array-sorted and joined with '\x1E' (ASCII record
    -- separator), e.g.: [('dns','foo.com'),('asn','123')] -> sipHash64('asn:123\x1Edns:foo.com')
    -- Ensures deduplication even if array order differs.
    evidence_id UInt64 MATERIALIZED
        sipHash64(arrayStringConcat(
            arrayMap(x -> concat(x.1, ':', x.2), arraySort(arrayDistinct(evidence))),
            '\x1E'
        )),

    -- Latest metadata
    ts           DateTime64(3, 'UTC'),
    confidence   Float32,
    source       LowCardinality(String), -- Conventional defaults: ct_heuristic, active_scan, proxycurl
    state        Enum8(
        'active' = 1,
        'suppressed' = 2,
        'pending_review' = 3,
        'expired' = 4
    ) DEFAULT 'active',
    is_negative  UInt8 DEFAULT 0,

    INDEX idx_org_id (org_id) TYPE set(0) GRANULARITY 1
)
ENGINE = ReplacingMergeTree(ts)
PARTITION BY toYYYYMM(ts)
ORDER BY (org_id, tech, evidence_id);

/* 6.3  CT-driven heuristic signals */
DROP VIEW IF EXISTS mv_ct_tech_signals;
CREATE MATERIALIZED VIEW mv_ct_tech_signals
REFRESH EVERY 1 DAY OFFSET 6 HOUR RANDOMIZE FOR 1 HOUR
TO tech_signals AS
-- pattern match (dict_tech_patterns)
SELECT
    now64()                       AS ts,
    df.org_id                     AS org_id,
    df.registrable                AS registrable,
    tp.tech                       AS tech,
    tp.weight                     AS confidence,
    'ct_heuristic'                AS source,
    arraySort(arrayDistinct([tuple('dns', df.dn)]))         AS evidence,
    0                             AS is_negative
FROM dns_flat AS df
CROSS JOIN (
    SELECT pattern, tech, weight
    FROM dict_tech_patterns
    WHERE is_regex = 0
) AS tp
WHERE arrayExists(
          tok -> arrayExists(
                     pat -> positionCaseInsensitive(tok, pat) > 0,
                     (SELECT groupArray(token) FROM tech_tokens)
                 ),
          df.dn_tokens_full
      )
  AND positionCaseInsensitive(df.dn, tp.pattern) > 0
UNION ALL
-- regex match (dict_regex_prefixes)
SELECT
    now64()                 AS ts,
    df.org_id               AS org_id,
    df.registrable          AS registrable,
    rp.tech                 AS tech,
    rp.weight               AS confidence,
    'ct_heuristic'          AS source,
    arraySort(arrayDistinct([tuple('dns', df.dn)]))   AS evidence,
    0                       AS is_negative
FROM dns_flat AS df
CROSS JOIN (
    SELECT regex_prefix, pattern, tech, weight
    FROM dict_regex_prefixes
) AS rp
WHERE (rp.regex_prefix = ''
       OR positionCaseInsensitive(df.dn, rp.regex_prefix) > 0)
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
ORDER BY (org_id, tech);


DROP VIEW IF EXISTS mv_org_tech;
CREATE MATERIALIZED VIEW mv_org_tech
REFRESH AFTER 4 HOUR RANDOMIZE FOR 1 HOUR
TO org_tech_facts AS
SELECT
    org_id,
    tech,
    IF(max(is_negative) = 1, 0, max(confidence)) AS confidence,
    max(ts) AS last_seen
FROM tech_signals
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
(1,'bitbucket',0,'Bitbucket', 1.0),
(2,'gitlab',   0,'GitLab',    1.0),
(3,'github',   0,'GitHub',    1.0),
(4,'vercel',   0,'Vercel',    1.0),
(5,'heroku',   0,'Heroku',    1.0),
(6,'splunk',   0,'Splunk',    1.0),
(7,'jenkins',  0,'Jenkins',   1.0),
(8,'jfrog',    0,'JFrog',     1.0);

INSERT INTO tech_patterns (id, pattern, is_regex, regex_prefix, tech, weight)
VALUES (9, '^([a-z0-9-]+\\.)+ghe\\.com$', 1, 'ghe.com', 'GitHub Enterprise Cloud (Data Residency)', 1.0);

SYSTEM RELOAD DICTIONARY dict_tech_patterns;