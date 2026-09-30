local Http = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ScriptContext = game:GetService("ScriptContext")
local LogService = game:GetService("LogService")
local Logger = {}
Logger.__index = Logger
local LEVEL = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40 }
local COLORS = { DEBUG = 9807270, INFO = 6730495, WARN = 16763979, ERROR = 16745861 }
local singleton

local function clean(value, limit)
    local text = tostring(value)
    if not utf8.len(text) then return "[invalid UTF-8]" end
    text = text:gsub("https://[^%s]+/api/webhooks/[^%s]+", "[redacted webhook]")
    text = text:gsub("https://[^%s]+/api/v%d+/webhooks/[^%s]+", "[redacted webhook]")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", " ")
    text = text:gsub("`", "'"):gsub("@", "＠")
    if #text > limit then
        text = text:sub(1, limit - 3)
        while not utf8.len(text) do text = text:sub(1, -2) end
        text = text .. "..."
    end
    return text
end

local function detailsText(details)
    if type(details) ~= "table" then return details and clean(details, 240) or "" end
    local keys, lines = {}, {}
    for key in pairs(details) do
        if type(key) == "string" then table.insert(keys, key) end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if #lines >= 6 then break end
        local lower = key:lower()
        local sensitive = lower:find("token", 1, true) or lower:find("secret", 1, true)
            or lower:find("password", 1, true) or lower:find("authorization", 1, true)
            or lower:find("webhook", 1, true) or lower:find("cookie", 1, true)
        local value = details[key]
        local rendered
        if sensitive then rendered = "[redacted]"
        elseif type(value) == "table" then rendered = "[table omitted]"
        elseif typeof(value) == "Instance" then rendered = value.ClassName
        else rendered = clean(value, 90) end
        table.insert(lines, clean(key, 30) .. "=" .. rendered)
    end
    return clean(table.concat(lines, " | "), 240)
end

local function header(response, name)
    for key, value in pairs(response.Headers or {}) do
        if key:lower() == name:lower() then return tonumber(value) end
    end
    return nil
end

function Logger.new(config, requestOverride)
    assert(RunService:IsServer(), "Signal belongs in ServerScriptService, never on a client")
    assert(LEVEL[config.MinLevel or "INFO"], "Invalid MinLevel")
    local self = setmetatable({}, Logger)
    self.Config = table.clone(config)
    self.Config.BatchSize = math.clamp(math.floor(config.BatchSize or 6), 1, 6)
    self.Config.MaxQueue = math.clamp(math.floor(config.MaxQueue or 200), 6, 2000)
    self.Config.FlushInterval = math.max(1, config.FlushInterval or 5)
    self.Config.MaxAttempts = math.clamp(math.floor(config.MaxAttempts or 5), 1, 10)
    self.Queue, self.Connections, self.PlayerConnections = {}, {}, {}
    self.Sent, self.Dropped, self.Failed, self.Suppressed = 0, 0, 0, 0
    self.Accepting, self.Running, self.InFlight = true, false, false
    self.NextAttempt, self.Attempts, self.RecentErrors = 0, 0, {}
    self.Request = requestOverride
    self.Deliver = config.Enabled ~= false and (not RunService:IsStudio() or config.StudioDelivery == true)
    if requestOverride then self.Deliver = true end
    return self
end

function Logger:_notice(message)
    warn("[Signal/internal] " .. message)
end

function Logger:Log(level, event, message, details)
    level = string.upper(level)
    assert(LEVEL[level], "Unknown log level")
    if not self.Accepting or self.Config.Enabled == false then return false end
    if LEVEL[level] < LEVEL[self.Config.MinLevel or "INFO"] then return false end
    local entry = {
        Level = level, Event = clean(event, 50), Message = clean(message or "", 150),
        Details = detailsText(details), Time = os.date("!%H:%M:%S"),
    }
    if self.Config.Console then
        local line = "[Signal] [" .. level .. "] " .. entry.Event .. " | " .. entry.Message
        if level == "WARN" or level == "ERROR" then warn(line) else print(line) end
    end
    if not self.Deliver then return true end
    if #self.Queue >= self.Config.MaxQueue then
        self.Dropped = self.Dropped + 1
        return false
    end
    table.insert(self.Queue, entry)
    return true
end

function Logger:Debug(event, message, details) return self:Log("DEBUG", event, message, details) end
function Logger:Info(event, message, details) return self:Log("INFO", event, message, details) end
function Logger:Warn(event, message, details) return self:Log("WARN", event, message, details) end
function Logger:Error(event, message, details) return self:Log("ERROR", event, message, details) end

function Logger:Timed(event, callback, ...)
    local start = os.clock()
    local results = table.pack(pcall(callback, ...))
    if results[1] then
        self:Debug(event, "Completed", { elapsedMs = math.floor((os.clock() - start) * 1000) })
        return true, table.unpack(results, 2, results.n)
    end
    self:Error(event, clean(results[2], 150), { elapsedMs = math.floor((os.clock() - start) * 1000) })
    return false, results[2]
end

function Logger:_payload(count)
    local lines, highest = {}, "INFO"
    for i = 1, count do
        local item = self.Queue[i]
        if LEVEL[item.Level] > LEVEL[highest] then highest = item.Level end
        local line = "`" .. item.Time .. " UTC` **" .. item.Level .. " · " .. item.Event .. "**\n" .. item.Message
        if item.Details ~= "" then line = line .. "\n`" .. item.Details .. "`" end
        table.insert(lines, line)
    end
    return {
        username = "Signal",
        allowed_mentions = { parse = {} },
        embeds = {{
            title = "Signal · Server events", color = COLORS[highest],
            description = table.concat(lines, "\n\n"),
            fields = {
                { name = "Place", value = tostring(game.PlaceId), inline = true },
                { name = "Server", value = clean(game.JobId ~= "" and game.JobId or "Studio", 80), inline = true },
            },
            footer = { text = "Queued: " .. #self.Queue .. " · Dropped: " .. self.Dropped .. " · Failed: " .. self.Failed },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    }
end

function Logger:_configureTransport()
    if self.Request then return true end
    if Http.HttpEnabled == false then
        self.Deliver = false
        self:_notice("Delivery disabled: enable Allow HTTP Requests in Experience Settings > Security, then restart the test.")
        return false
    end
    local setupHint = "check webhook configuration"
    local ok = pcall(function()
        if self.Config.Transport == "Relay" then
            setupHint = "check RelayUrl and your relay Secret/Local Secret"
            assert(type(self.Config.RelayUrl) == "string" and self.Config.RelayUrl:match("^https://"), "HTTPS required")
            self.Url = self.Config.RelayUrl
            self.Headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = Http:GetSecret(self.Config.RelaySecretName):AddPrefix("Bearer "),
            }
        elseif type(self.Config.WebhookUrl) == "string" and self.Config.WebhookUrl:match("%S") then
            setupHint = "paste a valid FULL Discord webhook URL into Config.WebhookUrl"
            local url = self.Config.WebhookUrl:match("^%s*(.-)%s*$")
            url = url:match("^[^?#]+") or ""
            url = url:gsub("^https://discordapp%.com/", "https://discord.com/")
            local base = url:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+$")
                or url:match("^https://discord%.com/api/v%d+/webhooks/%d+/[%w_%-]+$")
            assert(base, "Invalid webhook URL")
            self.Url = base .. "?wait=true"
            self.Headers = { ["Content-Type"] = "application/json" }
        else
            setupHint = "paste your full URL into Config.WebhookUrl, or configure WebhookId and Secret/Local Secret"
            assert(type(self.Config.WebhookId) == "string" and self.Config.WebhookId:match("^%d+$"), "Webhook ID required")
            self.Url = Http:GetSecret(self.Config.SecretName)
                :AddPrefix("https://discord.com/api/webhooks/" .. self.Config.WebhookId .. "/")
                :AddSuffix("?wait=true")
            self.Headers = { ["Content-Type"] = "application/json" }
        end
    end)
    if not ok then
        self.Deliver = false
        self:_notice("Delivery disabled: " .. setupHint .. ". Output still works.")
    end
    return ok
end

function Logger:Step()
    if not self.Deliver or self.InFlight or #self.Queue == 0 or os.clock() < self.NextAttempt then return false end
    local count = math.min(self.Config.BatchSize, #self.Queue)
    self.InFlight = true
    local ok, response = pcall(function()
        local payload = self:_payload(count)
        if self.Request then return self.Request(payload) end
        return Http:RequestAsync({ Url = self.Url, Method = "POST", Headers = self.Headers, Body = Http:JSONEncode(payload) })
    end)
    self.InFlight = false
    local code = ok and type(response) == "table" and tonumber(response.StatusCode) or 0
    self.NextAttempt = os.clock() + self.Config.FlushInterval
    if code >= 200 and code < 300 then
        for _ = 1, count do table.remove(self.Queue, 1) end
        self.Sent = self.Sent + count
        self.Attempts = 0
        if header(response, "x-ratelimit-remaining") == 0 then
            self.NextAttempt = os.clock() + math.max(self.Config.FlushInterval, header(response, "x-ratelimit-reset-after") or 1)
        end
        return true
    end
    self.Attempts = self.Attempts + 1
    if code == 401 or code == 403 or code == 404 then
        self.Failed = self.Failed + #self.Queue
        table.clear(self.Queue)
        self.Deliver = false
        self:_notice("Delivery stopped after HTTP " .. code .. ". Check webhook access; use your own relay if direct delivery is denied.")
        return false
    end
    local retryable = code == 0 or code == 429 or code >= 500
    local delay = math.min(60, 2 ^ self.Attempts)
    if code == 429 then
        local decodedOk, decoded = pcall(function() return Http:JSONDecode(response.Body or "") end)
        local retryAfter = decodedOk and type(decoded) == "table" and tonumber(decoded.retry_after) or nil
        delay = math.max(delay, retryAfter or 0, header(response, "retry-after") or 0)
    end
    self.NextAttempt = os.clock() + math.max(self.Config.FlushInterval, delay) + math.random()
    if not retryable or self.Attempts >= self.Config.MaxAttempts then
        for _ = 1, count do table.remove(self.Queue, 1) end
        self.Failed = self.Failed + count
        self.Attempts = 0
        self:_notice("Dropped a failed batch (HTTP " .. code .. "). See GetStats(); payloads are not printed.")
    end
    return false
end

function Logger:GetStats()
    return { queued = #self.Queue, sent = self.Sent, dropped = self.Dropped,
        failed = self.Failed, suppressed = self.Suppressed, deliveryEnabled = self.Deliver }
end

function Logger:_capture(level, event, message, details)
    local now = os.clock()
    if not self.ErrorWindow or now - self.ErrorWindow >= 10 then
        self.ErrorWindow, self.RecentErrors = now, {}
        self.ErrorCount = 0
    end
    local key = level .. clean(message, 150)
    if self.RecentErrors[key] or self.ErrorCount >= 20 then
        self.Suppressed = self.Suppressed + 1
        return
    end
    self.RecentErrors[key] = true
    self.ErrorCount = self.ErrorCount + 1
    self:Log(level, event, message, details)
end

function Logger:_playerDetails(player)
    local result = { userId = player.UserId }
    if self.Config.IncludePlayerNames then result.username = player.Name end
    return result
end

function Logger:_trackPlayer(player, existing)
    if self.PlayerConnections[player] then return end
    local record = { Links = {}, CharacterLinks = {}, Joined = os.clock() }
    self.PlayerConnections[player] = record
    self:Info(existing and "player.present" or "player.join", "Player connected", self:_playerDetails(player))
    local function characterAdded(character)
        if record.Character == character then return end
        record.Character = character
        for _, link in ipairs(record.CharacterLinks) do link:Disconnect() end
        table.clear(record.CharacterLinks)
        self:Info("character.spawn", "Character spawned", self:_playerDetails(player))
        task.spawn(function()
            local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
            if not humanoid or not humanoid:IsA("Humanoid") or self.PlayerConnections[player] ~= record
                or record.Character ~= character then return end
            table.insert(record.CharacterLinks, humanoid.Died:Connect(function()
                self:Info("character.death", "Character died", self:_playerDetails(player))
            end))
        end)
    end
    if self.Config.TrackCharacters then
        table.insert(record.Links, player.CharacterAdded:Connect(characterAdded))
        if player.Character then characterAdded(player.Character) end
    end
end

function Logger:Start()
    if self.Running then return self end
    if not self.Accepting then error("Cannot restart a stopped logger") end
    self.Running = true
    if self.Deliver then self:_configureTransport() end
    local function connect(signal, callback) table.insert(self.Connections, signal:Connect(callback)) end
    if self.Config.TrackPlayers then
        connect(Players.PlayerAdded, function(player) self:_trackPlayer(player, false) end)
        connect(Players.PlayerRemoving, function(player)
            local record = self.PlayerConnections[player]
            local data = self:_playerDetails(player)
            if record then
                data.sessionSeconds = math.floor(os.clock() - record.Joined)
                for _, link in ipairs(record.Links) do link:Disconnect() end
                for _, link in ipairs(record.CharacterLinks) do link:Disconnect() end
            end
            self.PlayerConnections[player] = nil
            self:Info("player.leave", "Player disconnected", data)
        end)
        for _, player in ipairs(Players:GetPlayers()) do self:_trackPlayer(player, true) end
    end
    if self.Config.CaptureServerErrors then
        connect(ScriptContext.Error, function(message, stack, source)
            if source and source:IsDescendantOf(script.Parent) then return end
            if tostring(message):find("[Signal", 1, true) then return end
            self:_capture("ERROR", "script.error", message, { source = source and source:GetFullName() or "unknown", stack = stack })
        end)
    end
    if self.Config.CaptureWarnings then
        connect(LogService.MessageOut, function(message, messageType)
            if messageType == Enum.MessageType.MessageWarning and not message:find("[Signal", 1, true) then
                self:_capture("WARN", "script.warning", message)
            end
        end)
    end
    self:Info("server.start", "Logger started", { placeVersion = game.PlaceVersion })
    task.spawn(function()
        while self.Running do
            task.wait(0.5)
            if self.Running then self:Step() end
        end
    end)
    return self
end

function Logger:Stop(timeout)
    if not self.Accepting then return end
    self:Info("server.stop", "Server shutting down")
    self.Accepting, self.Running = false, false
    for _, link in ipairs(self.Connections) do link:Disconnect() end
    for _, record in pairs(self.PlayerConnections) do
        for _, link in ipairs(record.Links) do link:Disconnect() end
        for _, link in ipairs(record.CharacterLinks) do link:Disconnect() end
    end
    table.clear(self.PlayerConnections)
    local deadline = os.clock() + math.clamp(timeout or 8, 0, 20)
    while self.Deliver and #self.Queue > 0 and os.clock() < deadline do
        self:Step()
        task.wait(0.1)
    end
end

function Logger.Get()
    if not singleton then
        singleton = Logger.new(require(script.Parent.Config)):Start()
        game:BindToClose(function() singleton:Stop(8) end)
    end
    return singleton
end
return Logger
