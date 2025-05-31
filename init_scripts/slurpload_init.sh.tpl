#!/bin/bash
set -euo pipefail

cat <<EOF > "/etc/slurpload.json"
{
    "host": "${postgres_internal_ip}",
    "port": 5432,
    "user": "slurpload",
    "password": "${slurpload_db_password}",
    "dbname": "ctlogs",
    "sslmode": "disable"
}
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
ExecStart=/usr/bin/slurpload serve --http 0.0.0.0:${slurpload_port} --inbox /tmp/slurpload --config /etc/slurpload.json
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