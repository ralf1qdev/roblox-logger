-- Keep this ModuleScript inside ServerScriptService/Signal.
return {
    Enabled = true,
    StudioDelivery = false, -- Turn on only after adding a Studio Local Secret.
    MinLevel = "INFO", -- DEBUG, INFO, WARN, ERROR
    Console = true,
    Transport = "Discord", -- Discord or Relay
    WebhookId = "", -- Numeric ID from your webhook URL; NOT the token.
    SecretName = "SIGNAL_DISCORD_TOKEN", -- Store only the webhook token as this secret.
    RelayUrl = "", -- Optional HTTPS URL of YOUR relay, ending in /events.
    RelaySecretName = "SIGNAL_RELAY_KEY",
    FlushInterval = 5,
    MaxQueue = 200,
    BatchSize = 6,
    MaxAttempts = 5,
    CaptureServerErrors = true,
    CaptureWarnings = false,
    TrackPlayers = true,
    TrackCharacters = true,
    IncludePlayerNames = true,
}
