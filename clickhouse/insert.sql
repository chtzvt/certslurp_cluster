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
);