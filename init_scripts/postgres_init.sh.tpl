#!/bin/bash
set -euo pipefail

MOUNT_POINT="${mount_point}"
DEVICE="${data_device}"
PG_VERSION="${pg_version}"
PG_DATA="${pg_data_dir}"

echo "==> Cloud-init: Begin postgresql data disk setup"

# Install dependencies
apt-get update
apt-get install -y xfsprogs parted gnupg curl

for i in {1..30}; do
    if [ -b "$DEVICE" ]; then break; fi
    echo "Waiting for $DEVICE to appear..."
    sleep 1
done
if [ ! -b "$DEVICE" ]; then
    echo "ERROR: Device $DEVICE not found after waiting"
    exit 1
fi

# Format and mount disk if not already mounted
if ! grep -qs "$MOUNT_POINT" /proc/mounts; then
    echo "==> Partitioning and formatting data disk"
    parted -s $DEVICE mklabel gpt
    parted -s -a optimal $DEVICE mkpart primary xfs 0% 100%
    sleep 2
    PARTITION="$DEVICE-part1"
    if [ ! -b "$PARTITION" ]; then
    echo "ERROR: Partition $PARTITION not found after partitioning $DEVICE"
    exit 1
    fi
    mkfs.xfs -f "$PARTITION"
    mkdir -p "$MOUNT_POINT"
    echo "$PARTITION $MOUNT_POINT xfs defaults,nofail,noatime,nodiratime 0 2" >> /etc/fstab
    mount "$MOUNT_POINT"
fi

# Install PostgreSQL
if ! command -v psql >/dev/null; then
    echo "==> Installing PostgreSQL"
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
    apt-get update
    apt-get install -y postgresql-$PG_VERSION
fi

systemctl stop postgresql

# Move/initialize PGDATA on the data disk
if [ ! -d "$PG_DATA" ]; then
    echo "==> Initializing PostgreSQL data directory"
    mkdir -p "$PG_DATA"
    chown postgres:postgres "$PG_DATA"
    sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D "$PG_DATA"
fi

PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"

# Only append new tunings if not already present (idempotent)
grep -q "CERTSLURP TUNING" "$PG_CONF" || cat <<EOF >> "$PG_CONF"

# CERTSLURP TUNING - ADDED BY CLOUD-INIT

listen_addresses = '*'

# WAL & Checkpoints
wal_level = logical
max_wal_size = 8GB
min_wal_size = 2GB
wal_compression = on
checkpoint_timeout = 30min
checkpoint_completion_target = 0.9
max_wal_senders = 5
wal_keep_size = 2GB

# Autovacuum tuning
# Aggressive, best for post-bulk load
#autovacuum = on
#autovacuum_max_workers = 5
#autovacuum_naptime = 10s
#autovacuum_vacuum_scale_factor = 0.02
#autovacuum_analyze_scale_factor = 0.01
#autovacuum_vacuum_cost_limit = 2000
#autovacuum_vacuum_cost_delay = 5ms

# Best for during bulk load
autovacuum_vacuum_scale_factor = 0.5   
autovacuum_analyze_scale_factor = 0.10 
autovacuum_naptime = 30s  
autovacuum_max_workers = 2  
autovacuum_vacuum_cost_limit = 1000  
autovacuum_vacuum_cost_delay = 25ms

# Memory for caching/bulk loading
shared_buffers = 20GB
work_mem = 128MB
maintenance_work_mem = 4GB
effective_cache_size = 48GB

# Background writer
bgwriter_delay = 10ms
bgwriter_lru_maxpages = 1000
bgwriter_lru_multiplier = 4.0

# Other
max_connections = 500
log_min_duration_statement = 1000  # Log slow queries (ms)
EOF

# Point PostgreSQL at the new data directory (override data_directory)
if ! grep -q "^data_directory = '$PG_DATA'" "$PG_CONF"; then
    sed -i "s|^#*data_directory =.*|data_directory = '$PG_DATA'|" "$PG_CONF"
fi

# Allow access from anywhere (or restrict as needed)
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
if ! grep -q "^host all all 0.0.0.0/0 md5" "$PG_HBA"; then
    echo "host all all 0.0.0.0/0 md5" >> "$PG_HBA"
fi

# Set proper permissions
chown -R postgres:postgres "$PG_DATA"

systemctl daemon-reload
systemctl enable postgresql
systemctl restart postgresql

sleep 2 

sudo -u postgres psql <<EOF
DO
\$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'slurpload') THEN
      CREATE ROLE slurpload WITH LOGIN PASSWORD '${slurpload_db_password}' NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;
   END IF;
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${db_user_name}') THEN
      CREATE ROLE ${db_user_name} WITH LOGIN PASSWORD '${db_user_password}' NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;
   END IF;
END
\$\$;
EOF

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'ctlogs'" | grep -q 1; then
  sudo -u postgres createdb -O slurpload ctlogs
fi

sudo -u postgres psql <<EOF
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE ctlogs FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ctlogs TO slurpload;
GRANT CONNECT ON DATABASE ctlogs TO ${db_user_name};
GRANT USAGE ON SCHEMA public TO ${db_user_name};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${db_user_name};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${db_user_name};
EOF

PGPASSWORD=${slurpload_db_password} psql -h localhost -U slurpload -d ctlogs -c '\conninfo'
PGPASSWORD=${db_user_password} psql -h localhost -U ${db_user_name} -d ctlogs -c '\conninfo'

PGPASSWORD=${slurpload_db_password} psql -h localhost -U slurpload -d ctlogs -c 'ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${db_user_name};'

echo "==> Cloud-init: PostgreSQL installation and disk setup complete"