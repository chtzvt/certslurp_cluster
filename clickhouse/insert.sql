SYSTEM STOP VIEWS;

INSERT INTO ct_certificates
SELECT
    -- raw fields
    cn,
    sub,
    iss,
    sn,
    em,
    ou,
    org,
    loc,
    prv,
    co,
    st,
    pc,
    dns,
    ips,
    uris,

    -- parse ISO8601 into DateTime64(0,'UTC')
    parseDateTime64BestEffort(nbf, 0, 'UTC') AS nbf,
    parseDateTime64BestEffort(naf, 0, 'UTC') AS naf,

    log,
    li,

    -- convert epoch-ms to DateTime64(6,'UTC')
    toDateTime64(lts/1000, 6, 'UTC')       AS lts

FROM azureBlobStorage(
     'https://STORAGE_ACCOUNT.blob.core.windows.net',  -- storage endpoint
     'CONTAINER_NAME',                                 -- container name
     'PATH/GLOB*',                                     -- file glob
     'ACCOUNT_NAME',                                   -- account name
     'ACCOUNT_KEY',                                    -- account key
     'JSONEachRow',                                    -- format
     'zstd',                                           -- compression
     'cn String,sub String,iss String,sn String,em Array(String),ou Array(String),org Array(String),loc Array(String),prv Array(String),co Array(String),st Array(String),pc Array(String),dns Array(String),ips Array(String),uris Array(String),nbf String,naf String,log String,li UInt64,lts UInt64'
)

-- Only records from 2024-01-01 onwards
WHERE lts >= toDateTime64('2024-01-01 00:00:00', 6, 'UTC')

SETTINGS
    -- Reference: https://clickhouse.com/docs/integrations/s3/performance

    -- Maximum number of rows per in-memory block processed during the insert.
    -- Lower values reduce per-block memory, but increase the number of parts and merge pressure.
    max_block_size = 4096,

    -- Maximum number of rows per block written by the INSERT.
    -- Similar to max_block_size; lowering helps prevent OOM, but increases part count.
    max_insert_block_size = 4096,

    -- Limits the number of partitions that can be present in a single insert block.
    -- Lowering can help avoid out-of-memory conditions when inserting across many partitions.
    max_partitions_per_insert_block = 128,

    -- Disable asynchronous insert mode.
    -- Ensures INSERT blocks until data is written, improving safety for large/bulk loads.
    async_insert = 0,

    -- Wait for data to be fully inserted before returning control to the client.
    -- Reduces risk of data loss or confusion during bulk ingest.
    wait_for_async_insert = 1,

    -- Enables parallel parsing of input data (e.g., JSONL/CSV) across threads.
    -- Boosts performance on wide files and multi-core machines.
    input_format_parallel_parsing = 1,

    -- Disable row-based threshold for minimum insert block size;
    -- all control is via min_insert_block_size_bytes below (prevents block splitting by row count).
    min_insert_block_size_rows = 0,

    -- Number of threads used to process and insert data in parallel.
    -- Rule of thumb: about half your available CPUs to balance inserts and merges.
    max_insert_threads = 16,

    -- Minimum block size in bytes for each in-memory insert block (uncompressed).
    -- Set to 1/3rd of (RAM allocated for insert) divided by insert threads.
    -- Larger values = fewer, bigger parts (less merge pressure), but higher peak memory.
    min_insert_block_size_bytes = 941048693, -- 941 MiB / 512 * 1024 * 1024

    -- Number of threads used for downloading data from Azure Blob Storage in parallel.
    -- Higher values help saturate bandwidth and speed up ingest from large blobs.
    max_download_threads = 16,

    -- Size (bytes) of each download buffer for object storage reads.
    -- Larger buffers (e.g., 50 MiB) improve throughput for big files; can lower for small files.
    max_download_buffer_size = 52_428_800,  -- 50 MiB

    -- Disable insert de-duplication logic (faster bulk inserts).
    -- Safe if you know your data is unique or you are loading in a controlled, idempotent way.
    insert_deduplicate = 0,

    -- Disable part merging during the insert (defers merges to background).
    -- Maximizes ingest speed at the cost of more small parts temporarily; run optimize later.
    optimize_on_insert = 0,

    -- Parse input formats like JSONL/CSV in parallel.
    input_format_parallel_parsing = 1;
;

OPTIMIZE TABLE ct_certificates FINAL;

SYSTEM START VIEWS;

SYSTEM REFRESH VIEW org_locations;
SYSTEM REFRESH VIEW org_diversity_signal;