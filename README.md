![Signal — Roblox Logger](assets/banner.png)

# Signal

**Server-side Luau logging for Roblox, delivered to Discord.**

Player lifecycle events, structured debugging, bounded queues, and readable Discord embeds. Designed for experiences you own or develop. Includes an importable Roblox model, editable Luau source, tests, and an optional self-hosted relay.

## What it logs

| Event | How it is captured |
| --- | --- |
| Server startup and shutdown | Automatic; shutdown delivery is best effort |
| Player joins and leaves | Automatic; includes user ID, optional username, and observed session duration |
| Character spawns and deaths | Automatic for standard Humanoid characters |
| Unhandled server script errors | `ScriptContext.Error`, with bounded duplicate suppression |
| Server warnings | Optional `LogService.MessageOut` capture; disabled by default |
| Debug/info/warn/error messages | Your explicit logging calls |
| Timed operations | `logger:Timed(...)` around your function |
| Trades, purchases, moderation, rounds, inventory changes | Add explicit calls at the point your server confirms the action |

This does **not** intercept every script or RemoteEvent, capture chat, inspect private messages, collect passwords, or automatically capture client-only errors. There is no client logger endpoint. Do not treat client-reported events as verified server actions.

## 1. Install in Roblox Studio

1. Extract the downloaded ZIP.
2. In Studio, use **Insert from File** to insert `Signal.rbxmx` into **ServerScriptService**. If Studio inserts it elsewhere, move the complete `Signal` folder into ServerScriptService.
3. The folder contains **Config** (ModuleScript), **Logger** (ModuleScript), **Bootstrap** (Script), and **SmokeTests** (ModuleScript).
4. Do not put it in ReplicatedStorage, StarterPlayerScripts, or Workspace. Keep one Signal folder per server.
5. First run with the defaults: Studio is Output-only, so you can check events without sending anything to Discord.

Manual alternative: create the same objects inside a ServerScriptService folder named `Signal`; paste the corresponding `src` files and `tests/SmokeTests.luau` into their Source. Rojo users can use `default.project.json`.

## 2. Connect Discord

Use a normal Discord text channel for this version. Forum/thread-specific webhook parameters are not configured.

1. In your Discord server, create a webhook for the logging channel through the channel's **Integrations → Webhooks** settings. You need permission to manage webhooks.
2. Its URL has this structure: `https://discord.com/api/webhooks/WEBHOOK_ID/WEBHOOK_TOKEN`.
3. In `Config`, set **WebhookId** to the numeric `WEBHOOK_ID`, as a quoted string. Do not paste the complete URL into the code.
4. In Roblox Creator Dashboard, select the experience, open **Secrets**, and create a secret named **SIGNAL_DISCORD_TOKEN**. The value is **only WEBHOOK_TOKEN**, and the domain is **discord.com**.
5. Enable **Allow HTTP Requests** in your experience's Security settings.
6. For local Studio testing, also create the same token under Studio's **Experience Settings → Security → Local Secrets**. Published secrets are not automatically available in local playtests.
7. Set `StudioDelivery = true` when you want a Studio test to send Discord messages. For published servers, delivery is enabled automatically when `Enabled = true`.
8. Play the experience and wait several seconds. A `server.start` event and player events should arrive in an embed.

The code never needs your Discord bot token. Never put a webhook token in GitHub, a LocalScript, screenshots, or chat. Regenerate it if it is exposed. Log only details you intend to share with members who can view the Discord channel.

If HTTP 403 prevents direct delivery, the logger stops sending and continues in Output-only mode. Check the webhook first, then see `relay/README.md` to deploy **your own** authenticated relay. No shared/public proxy is bundled or required. This package does not claim that direct Roblox-to-Discord requests work in every network environment.

## 3. Log your own gameplay

From another **server Script**:

```lua
local Logger = require(game.ServerScriptService.Signal.Logger)
local logger = Logger.Get()

logger:Info("round.start", "Round started", { round = 12, map = "Harbor" })
logger:Warn("inventory.reject", "Invalid item rejected", { userId = player.UserId, itemId = "sword_01" })
logger:Error("save.failed", "Data save failed", { userId = player.UserId, attempt = 3 })
```

The `player` examples belong inside an existing function/event where you have a player variable. Call them after your server validates the action. Never attach a client RemoteEvent directly to unrestricted logging.

For a protected operation:

```lua
local ok, result = logger:Timed("inventory.load", function()
    -- Your own yielding operation is allowed here.
    return { coins = 100 }
end)
if not ok then
    -- Handle failure; Timed returns false and the error instead of rethrowing.
end
```

Timing success is DEBUG level; set `MinLevel = "DEBUG"` to include it. Failures are ERROR level.

## Configuration

| Setting | Default | Purpose |
| --- | --- | --- |
| Enabled | true | Enable logging |
| StudioDelivery | false | Explicitly opt Studio into webhook sending |
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

Ten test groups cover successful delivery, redaction, level filtering, rate limiting, disabled delivery, retry exhaustion, queue bounds, concurrent enqueueing, timed return values, deduplication, and Unicode payload bounds.

Core tests were executed with a Lua runtime and mocked Roblox services. The relay passed a JavaScript syntax check. **Live Roblox lifecycle hooks, Studio model import, secret access, and Discord delivery still require testing in your experience.** The generated banner is promotional artwork, not a screenshot of live logs.

## Project files

- `Signal.rbxmx` — importable folder with all Roblox scripts.
- `src/` — editable Luau modules and startup script.
- `tests/` — offline Studio tests.
- `relay/` — optional Node relay and setup notes.
- `assets/banner.png` — generated README banner.

Suggested repository name: **signal-roblox**

Suggested description: **Server-side Luau logging for Roblox with lifecycle events, structured debugging, and Discord webhook delivery.**

No software license has been selected. Add one before offering reuse under specific open-source terms.

## API references

- [Roblox HTTP requests](https://create.roblox.com/docs/cloud-services/http-service)
- [Roblox secrets and Local Secrets](https://create.roblox.com/docs/cloud-services/secrets)
- [Discord webhook execution](https://docs.discord.com/developers/resources/webhook#execute-webhook)
- [Discord rate limits](https://docs.discord.com/developers/topics/rate-limits)
