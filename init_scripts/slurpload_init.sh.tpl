#!/bin/bash
set -euo pipefail

cat <<EOF > "/etc/slurpload.yaml"
database:
  host: "${postgres_internal_ip}"
  port: 5432
  username: "slurpload"
  password: "${slurpload_db_password}"
  database: "ctlogs"
  ssl_mode: "disable"
  max_conns: 16
  batch_size: 256
  cache_size: 1_000_000

server:
  listen_addr: "0.0.0.0:${slurpload_port}"

processing:
  inbox_dir: "/tmp/slurpload"

metrics:
  log_stat_every: 10_000
EOF

mkdir -p /tmp/slurpload
chown -R azureuser:azureuser /tmp/slurpload

cat <<EOF > "/etc/systemd/system/slurpload.service"
[Unit]
Description=Slurpload ETL Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/slurpload serve --config /etc/slurpload.yaml
Restart=always
RestartSec=5
User=azureuser
WorkingDirectory=/home/azureuser
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slurpload