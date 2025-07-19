#!/bin/bash

CLICKHOUSE="clickhouse-client"
TABLE="ct_certificates"
START_MONTH=202401   # Jan 2024
END_MONTH=$(date +"%Y%m" -d "last month")
CONCURRENCY=3
MAX_BLOCK=8192
MAX_INSERT_BLOCK=4096

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

for range in "${months[@]}"; do
  IFS=, read month_start month_end <<< "$range"

  # Step 2: For each month, break into weeks
  week_start="$month_start"
  while [[ "$week_start" < "$month_end" ]]; do
    # Calculate week_end (7 days ahead, but not after month_end)
    week_end=$(date -d "$week_start +7 days" +%Y-%m-%d)
    [[ "$week_end" > "$month_end" ]] && week_end="$month_end"

    while [ "$(jobs -r | wc -l)" -ge "$CONCURRENCY" ]; do sleep 5; done

    (
      echo "[$(date)] Processing $week_start to $week_end"
      $CLICKHOUSE --query="SET max_block_size = $MAX_BLOCK; SET max_insert_block_size = $MAX_INSERT_BLOCK; INSERT INTO $TABLE SELECT * FROM $TABLE WHERE nbf >= '$week_start' AND nbf < '$week_end';" \
        && echo "[$(date)] Finished $week_start to $week_end" \
        || echo "[$(date)] FAILED $week_start to $week_end"
    ) &

    week_start="$week_end"
  done
done

wait
echo "All weeks processed!"