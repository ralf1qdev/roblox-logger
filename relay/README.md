# Optional Signal relay

Use this only if you need a controlled HTTPS endpoint between Roblox and Discord. It is a Node 22+ server using built-in modules, with no npm dependencies. Hosting is not included or deployed.

Set environment variables in your hosting provider's secret settings:

- `DISCORD_WEBHOOK_URL`: complete Discord webhook URL, without query parameters.
- `SIGNAL_RELAY_KEY`: a random secret of at least 32 characters (use a password manager).
- `PORT`: optional; defaults to 8080.

Start with `node server.mjs`. Put it behind a managed HTTPS endpoint. The public route must be `/events`; do not expose plain HTTP to Roblox.

Configure Roblox:

```lua
Transport = "Relay",
RelayUrl = "https://your-host.example/events",
RelaySecretName = "SIGNAL_RELAY_KEY",
```

Create a Roblox secret/Local Secret named `SIGNAL_RELAY_KEY` with the same key and your relay's exact domain. The Discord token stays only on your relay host; Roblox does not need the Discord secret in relay mode.

The relay authenticates each request, allows one upstream request at a time per process, limits payload size, forces mention suppression, and forwards rate-limit waits. It has no durable queue. Busy requests return 429 for Roblox to retry. Multiple relay instances do not share rate-limit state. Use a single instance for a small deployment; move to a shared queue before increasing traffic. A slow upstream request may complete after a caller times out, so duplicate messages are possible.

Configure your HTTPS reverse proxy/provider with a request-body timeout, a 32 KiB body limit, and platform request-rate limits. Keep the relay key in platform secret settings. Rotate it if exposed.

The relay was syntax-checked locally; no host or live Discord endpoint was contacted.
