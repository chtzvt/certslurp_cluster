#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/clickhouse-init.log"
exec > >(tee -a "$LOGFILE") 2>&1

MOUNT_POINT="${mount_point}"
DEVICE="${data_device}"

echo "==> Cloud-init: Begin Clickhouse data disk setup"

# Install dependencies
apt-get update
apt-get install -y xfsprogs parted gnupg curl htop nload

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

# Install Clickhouse
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

# Download the ClickHouse GPG key and store it in the keyring
curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

# Get the system architecture
ARCH=$(dpkg --print-architecture)

# Add the ClickHouse repository to apt sources
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=$ARCH] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list

# Update apt package lists
sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y clickhouse-server clickhouse-client

# Configure Clickhouse data directories
mkdir -p "$MOUNT_POINT/data" "$MOUNT_POINT/tmp" "$MOUNT_POINT/user_files" "$MOUNT_POINT/access" "$MOUNT_POINT/ddl_queue"
chown -R clickhouse:clickhouse "$MOUNT_POINT"

cat >/etc/clickhouse-server/config.d/data_directories.xml <<EOF
<yandex>
    <path>$MOUNT_POINT/data/</path>
    <tmp_path>$MOUNT_POINT/tmp/</tmp_path>
    <user_files_path>$MOUNT_POINT/user_files/</user_files_path>
    <user_directories>
        <users_xml>
            <path>/etc/clickhouse-server/users.xml</path>
        </users_xml>
        <local_directory>
            <path>$MOUNT_POINT/access/</path>
        </local_directory>
    </user_directories>
    <distributed_ddl>
        <path>$MOUNT_POINT/ddl_queue/</path>
    </distributed_ddl>
</yandex>
EOF

# Configure clickhouse users
cat >/etc/clickhouse-server/users.d/init_users.xml <<EOF
<yandex>
  <users>
    <${admin_username}>
      <password>${admin_password}</password>
      <profile>default</profile>
      <networks>
        <ip>::/0</ip>
      </networks>
      <quota>default</quota>
    </${admin_username}>
    <${readonly_user_name}>
      <password>${readonly_user_password}</password>
      <profile>readonly</profile>
      <networks>
        <ip>::/0</ip>
      </networks>
      <quota>default</quota>
    </${readonly_user_name}>
  </users>
  <profiles>
    <readonly>
      <readonly>1</readonly>
      <allow_ddl>0</allow_ddl>
    </readonly>
  </profiles>
</yandex>
EOF

cat >/etc/clickhouse-server/users.d/disable_default.xml <<EOF
<yandex>
  <users>
    <default>
      <networks>
        <ip>127.0.0.1</ip>
      </networks>
      <access_management>0</access_management>
    </default>
  </users>
</yandex>
EOF

if [ ! -s /etc/clickhouse-server/users.xml ]; then
  echo "<yandex><users></users></yandex>" > /etc/clickhouse-server/users.xml
fi

chown -R clickhouse:clickhouse /etc/clickhouse-server/users.d /etc/clickhouse-server/config.d

systemctl restart clickhouse-server
sleep 2
clickhouse-client --user "${admin_username}" --password "${admin_password}" --query "SELECT 1"

echo "==> Cloud-init: Clickhouse installation and disk setup complete"