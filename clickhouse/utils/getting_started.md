Install the Clickhouse client:

```
brew install --no-quarantine clickhouse
```

Connect to Clickhouse:

`ctlro` is the read-only user that the app will use. 

CLI (Connection String)

```
clickhouse client clickhouse://ctlro:<password><ip>:9000/default
```

Web UI (In-browser)

```
http://<ip>:8123/play
```