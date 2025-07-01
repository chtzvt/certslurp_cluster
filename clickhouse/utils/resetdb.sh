ADMIN_USER_NAME=""
ADMIN_USER_PW=""

clickhouse-client --query="SELECT concat('DROP DATABASE IF EXISTS ', name, ' SYNC;') FROM system.databases WHERE name NOT IN ('system')" |   clickhouse-client --multiquery
echo "CREATE DATABASE default;" | clickhouse-client --user $ADMIN_USER_NAME --password $ADMIN_USER_PW
clickhouse-client --user $ADMIN_USER_NAME --password $ADMIN_USER_PW < schema.sql