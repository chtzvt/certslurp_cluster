#!/bin/bash

CLICKHOUSE="clickhouse-client"
TABLE="ct_certificates"
START_MONTH=202401   # Jan 2024
END_MONTH=$(date +"%Y%m" -d "last month")
CONCURRENCY=3
MAX_BLOCK=2048
MAX_INSERT_BLOCK=1024

months=()
ym=$START_MONTH

# Step 1: Build months array
while [[ $ym -le $END_MONTH ]]; do
  year=${ym:0:4}
  month=${ym:4:2}
  start_date="${year}-${month}-01"
  next_month=$(date -d "$start_date +1 month" +%Y%m)
  months+=("$start_date,$next_month")
  ym=$next_month
done

# For each month as before
for range in "${months[@]}"; do
  IFS=, read month_start month_end <<< "$range"
  day_start="$month_start"
  while [[ "$day_start" < "$month_end" ]]; do
    day_end=$(date -d "$day_start +1 day" +%Y-%m-%d)
    [[ "$day_end" > "$month_end" ]] && day_end="$month_end"
    while [ "$(jobs -r | wc -l)" -ge "$CONCURRENCY" ]; do sleep 5; done

    (
      echo "[$(date)] Processing $day_start to $day_end"
      $CLICKHOUSE --query="SET max_block_size = $MAX_BLOCK; SET max_insert_block_size = $MAX_INSERT_BLOCK; INSERT INTO $TABLE SELECT * FROM $TABLE WHERE nbf >= '$day_start' AND nbf < '$day_end';" \
        && echo "[$(date)] Finished $day_start to $day_end" \
        || echo "[$(date)] FAILED $day_start to $day_end"
    ) &

    day_start="$day_end"
  done
done

wait
echo "All days processed!"