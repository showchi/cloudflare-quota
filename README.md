# Cloudflare Quota

English | [中文](README.zh-CN.md)

Unofficial macOS menu-bar app. It is not affiliated with Cloudflare, Inc. It shows today's Workers and Pages Functions usage for several Cloudflare free accounts and marks the account that still has the most quota left below the switch line. It does not switch traffic. Callers read the local status file and choose the address for that account themselves.

The free plan includes 100,000 requests per day. Workers and Pages Functions share that quota, and it resets at midnight UTC. Static Pages do not count. The app adds the sampled Workers and Pages Functions GraphQL Analytics datasets. Those numbers are not the billed count. Compare the datasets with the account dashboard before treating them as the same traffic; matching script names alone does not prove that the calls overlap. By default, an account is no longer suggested once its displayed usage reaches 75%.

## Create a token

Create one API token for each Cloudflare login:

1. Open My Profile → API Tokens → Create Token → Create Custom Token.
2. Add only **Account → Account Analytics → Read**.
3. Limit the token to that one account.
4. Copy the token. The Account ID is in the Workers & Pages sidebar. Leave it blank if the token can see only one account; the app fills it in.

Do not paste an API token into an issue, pull request, or log. Tokens stay on this Mac.

## Run

Requires macOS 15 and Swift 6. If `xcode-select -p` points at the Command Line Tools, point `DEVELOPER_DIR` at a full Xcode installation:

```bash
export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app/Contents/Developer | head -1)"
```

```bash
swift test
swift run QuotaBar
```

Packaging needs Python 3 and Pillow. Use a virtual environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r scripts/requirements.txt
scripts/package-dmg.sh
```

The script writes `dist/CloudflareQuota.dmg`. Open it and drag the app on the left to Applications on the right. The app is signed ad hoc and is not notarized. Only proceed if you trust the download source and are certain the app has not been tampered with. If macOS blocks the first launch, first try opening the app from Applications, then go to System Settings → Privacy & Security → Open Anyway and confirm Open. See [Apple's instructions](https://support.apple.com/en-us/102445).

The menu bar shows the percentage of the fullest account. It shows `!` when an account refresh or status publication fails. Refresh starts at launch and repeats on the configured interval, without opening the menu. Manage Accounts opens the main window, where accounts can be added, edited, or deleted. The window also switches Chinese or English, light, dark, or system appearance, and can hide the menu-bar icon. The version and build are at the bottom. The app has no Dock icon while it is running. After hiding the menu-bar icon, open the app from Applications once to return to the main window.

Tokens are stored in `~/Library/Application Support/CloudflareQuota/tokens.json` with mode `0600`. Account names and limits are in `accounts.json` in the same directory. That file contains no tokens.

The status file is:

`~/.cloudflare-quota/status.json`

`suggestedAccountID` is the local ID of the account to use. The file contains no tokens.

If configuration loading or transaction recovery fails, the app publishes a status with no suggestion and an empty account list. Any failed status publication, including one after a delete, a disable, or a refresh that finds an account unusable, tries to remove the old status file. If that removal fails, the app shows an explicit warning. A publication error stays visible in the menu panel and the management window and is not replaced by a later operation error. A failed publication does not roll back an account change that was already saved, and it does not replace the original configuration with defaults.

Status publication retries on its own. The delay starts at 1 second and grows to at most 60 seconds. Each attempt uses the latest configuration, usage, and UTC day, and it does not call Cloudflare again. A successful publication cancels the retry.

Callers should treat a missing, unreadable, or stale status file as unavailable. At minimum, check that `generatedAt` belongs to the current UTC day and that the current time is before `resetsAt`. Also set a maximum age; do not keep the previous suggestion indefinitely. `generatedAt` is when the status was written. For usage freshness, also check `accounts[].usage.fetchedAt`.

When a query reaches its row limit, the app splits the day into non-overlapping windows and totals a result only when every window is complete. One refresh makes at most 31 queries per account. If a one-second window is still full, the query budget is exhausted, or any window fails, the app reports the failure and stops suggesting that account. It does not present a partial total as complete usage. The follow-up queries reuse the existing time filters. They do not use a cursor and do not deduplicate by script name.

To trace panel clicks, run `QUOTA_DEBUG_EVENTS=1 swift run QuotaBar` and filter Console for `QuotaPanel`. The log is off by default. When enabled, it records the event source, type, time, window number, pointer location, and panel visibility. It does not record account names or tokens. Check the first click opening the panel, the next click closing it, scrolling and buttons inside the panel, a click outside closing it, and an automatic refresh while the panel is open. The log shows event routing and callback order. It does not replace checking the native interface.

Editing an account temporarily writes `.accounts.json.pending` in the configuration directory. It uses mode `0600`, like the token file, and contains the configuration and credentials needed for recovery. A completed save deletes it. After an interrupted save, the next launch restores the previous state or finishes the committed state. If recovery fails, loading and writing stop, and the record remains so it can be retried after file access is fixed. This covers one app instance interrupted while running. It does not cover concurrent writers or a power loss.

## License

[MIT](LICENSE)
