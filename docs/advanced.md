# Configuration and troubleshooting

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| Enabled | true | Enable logging |
| StudioDelivery | true | Send during Studio tests; false makes Studio Output-only |
| WebhookUrl | empty | Full Discord webhook URL; preferred simple setup |
| MinLevel | INFO | DEBUG, INFO, WARN, ERROR |
| Console | true | Mirror short messages to server Output |
| FlushInterval | 5 seconds | Minimum spacing between successful requests |
| BatchSize | 6 | Events per Discord embed; clamped to 1–6 |
| MaxQueue | 200 | Reject new events once queue is full |
| MaxAttempts | 5 | Attempts per head batch before dropping it |
| CaptureServerErrors | true | Capture unhandled server script errors |
| CaptureWarnings | false | Capture server warnings |
| TrackPlayers / TrackCharacters | true | Lifecycle tracking; characters require player tracking |
| IncludePlayerNames | true | Include username in addition to user ID |

```lua
local stats = logger:GetStats()
print(stats.queued, stats.sent, stats.dropped, stats.failed, stats.suppressed, stats.deliveryEnabled)
```

## Reliability and boundaries

- Requests are serialized per server. Rate-limit responses honor `retry_after` in seconds and the rate-limit headers.
- Network failures and 5xx responses get bounded backoff. A timeout can occur after Discord accepted a message, so retries may create duplicates.
- HTTP 401/403/404 disables delivery for the logger's lifetime. Fix configuration and start a fresh server to reconnect.
- New events are rejected on overflow; failed batches are dropped after the retry budget. Counters are visible in `GetStats()` and outgoing embed footers.
- This is **best-effort, in-memory telemetry**, not a durable audit database. Crashes, shutdowns, and queue overflow can lose events. A shutdown drain attempts delivery for up to 8 seconds, but an in-flight HTTP request can exceed that budget and Roblox may terminate the server.
- Multiple Roblox servers using one webhook share Discord's limits. Use a controlled relay or dedicated logging backend when traffic grows. Per-server backoff cannot coordinate independent servers.
- Fields are deliberately truncated. Details accept up to six string keys; nested tables are omitted. Avoid large payloads, raw user text, and anything secret.
- Sensitive key names and webhook URLs are redacted, but redaction is not a guarantee that arbitrary free-text secrets will be detected.
- Discord mentions are disabled; captured errors and warnings are deduplicated within bounded ten-second windows.
- This implementation does not wrap `MarketplaceService.ProcessReceipt`; add a logging call only after your existing receipt handler confirms fulfillment.

## Tests

Included `SmokeTests` never makes network requests. From Studio's **server** Command Bar while testing:

```lua
require(game.ServerScriptService.Signal.SmokeTests)()
```

Eleven test groups cover successful delivery, redaction, level filtering, rate limiting, disabled delivery, retry exhaustion, queue bounds, concurrent enqueueing, timed return values, deduplication, Unicode payload bounds, and full-URL setup (requires HTTP enabled).

Core tests were executed with a Lua runtime and mocked Roblox services. The relay passed a JavaScript syntax check. **Live Roblox lifecycle hooks, Studio model import, secret access, and Discord delivery still require testing in your experience.** The generated banner is promotional artwork, not a screenshot of live logs.

