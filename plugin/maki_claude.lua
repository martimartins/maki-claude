-- Claude subscription (Pro or Max) for maki, over the Claude Code OAuth flow.
-- The subscription token is accepted only when the system prompt opens with
-- the Claude Code identity line as its own block, which is the system prefix.

local SLUG = "claude"
local DISPLAY_NAME = "Claude subscription"
local IDENTITY = "You are Claude Code, Anthropic's official CLI for Claude."
local CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
local API_URL = "https://api.anthropic.com"
-- The provider origin: maki.net sends a browser user agent anywhere else, which
-- the token endpoint answers with a 429.
local TOKEN_URL = API_URL .. "/v1/oauth/token"
local MODELS_URL = API_URL .. "/v1/models?limit=1000"
local USAGE_URL = API_URL .. "/api/oauth/usage"
local API_VERSION = "2023-06-01"
local OAUTH_BETA = "oauth-2025-04-20"
local REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
local SCOPES =
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
local LONG_CONTEXT = 1000000
local LONG_CONTEXT_SUFFIX = "-1m"
local REFRESH_MARGIN_S = 300
local PKCE_WAIT_MS = 10000
local OS_WAIT_MS = 5000
-- Prints a random verifier, then its S256 challenge in standard base64.
local PKCE_SCRIPT =
  'v=$(openssl rand -hex 32) && echo "$v" && printf %s "$v" | openssl dgst -sha256 -binary | openssl base64 -A'
-- The same pair from the .NET classes that ship with Windows PowerShell.
local PKCE_POWERSHELL = [[
$ErrorActionPreference = 'Stop'
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$verifier = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
$digest = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
[Console]::WriteLine($verifier)
[Console]::WriteLine([Convert]::ToBase64String($digest))
]]
local PKCE_COMMANDS = {
  windows = { "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", PKCE_POWERSHELL },
  linux = { "sh", "-c", PKCE_SCRIPT },
  macos = { "sh", "-c", PKCE_SCRIPT },
}
local UNSUPPORTED_OS = "Claude login runs on Windows, Linux and macOS, not on %s"
local NOT_LOGGED_IN = "not logged in to Claude: run `maki auth login claude`"
-- maki replaces the message of a 401 with its own generic login hint.
local NEEDS_LOGIN = 403
local UNREACHABLE = 503
local RATE_LIMITED = 429
-- maki shows the message of a 402 and does not retry it, as with its own
-- billing errors.
local OUT_OF_USAGE = 402
local USED_UP = 100
local RESET_FORMAT = "%a %d %b %H:%M"
local SHORT_RESET_FORMAT = "%a %H:%M"
-- A limit with less than this percent left shows as a warning on the hint line.
local LOW_LEFT = 20
local SEPARATOR = " · "
-- A turn where the model spent less time than this gives no speed worth showing.
local MIN_MODEL_S = 1
-- Claude Code sends this when the install is enrolled in a server-side
-- experiment. Override with CLAUDE_ATIS, or set it to "off" to omit the header.
local ATIS_DEFAULT = "d5ce23808f17634f"

-- A deliberate failure reaches the user as its message alone, where a raised
-- error would read as a broken hook with a stack trace.
local function fail(status, message)
  return nil, maki.provider.http_error({ status = status, body = message })
end

local function request(url, opts)
  local res, err = maki.net.request(url, opts)
  if not res then
    return fail(UNREACHABLE, url .. " unreachable: " .. tostring(err))
  end
  if res.status < 200 or res.status >= 300 then
    return nil, maki.provider.http_error(res)
  end
  return maki.json.decode(res.body)
end

local function urlencode(value)
  return (value:gsub("[^%w%-_%.~]", function(c)
    return ("%%%02X"):format(c:byte())
  end))
end

-- The output of a command that exits 0, or why there is none.
local function run(command, timeout_ms)
  local job, err = maki.fn.jobstart(command, { scope = "plugin" })
  if not job then
    return nil, err
  end
  local result, wait_err = maki.fn.jobwait(job, timeout_ms)
  if not result then
    maki.fn.jobstop(job)
    return nil, wait_err
  end
  if result.exit_code ~= 0 then
    return nil, result.stderr:match("%S[^\r\n]*") or ("exit code " .. tostring(result.exit_code))
  end
  return result.stdout
end

-- "windows", "linux", "macos", or what uname calls any other system, in lower case.
local function detect_os()
  if maki.uv.os_getenv("OS") == "Windows_NT" then
    return "windows"
  end
  local output, err = run({ "uname", "-s" }, OS_WAIT_MS)
  local name = output and output:match("%S+")
  if not name then
    return nil, "cannot detect the operating system with uname: " .. tostring(err or "no output")
  end
  return name == "Darwin" and "macos" or name:lower()
end

-- The command that prints a PKCE pair on this system, or why login cannot run here.
local function pkce_command()
  local os_name, err = detect_os()
  if not os_name then
    return nil, err
  end
  local command = PKCE_COMMANDS[os_name]
  if not command then
    return nil, UNSUPPORTED_OS:format(os_name)
  end
  return command
end

local function pkce()
  local command, err = pkce_command()
  if not command then
    return nil, err
  end
  local output, run_err = run(command, PKCE_WAIT_MS)
  local verifier, challenge = (output or ""):match("^(%x+)\r?\n(%S+)")
  if not verifier then
    return nil, "cannot create a PKCE pair with " .. command[1] .. ": " .. tostring(run_err or "unexpected output")
  end
  return verifier, (challenge:gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

-- Posts to the token endpoint and stores what it grants.
local function grant(slug, body, previous)
  local data, err = request(TOKEN_URL, {
    method = "POST",
    headers = { ["content-type"] = "application/json", accept = "application/json" },
    body = maki.json.encode(body),
  })
  if not data then
    return nil, err
  end
  local refresh = type(data) == "table" and (data.refresh_token or (previous and previous.refresh))
  if not refresh or type(data.access_token) ~= "string" or type(data.expires_in) ~= "number" then
    return fail(UNREACHABLE, "token response is missing access_token, refresh_token or expires_in")
  end
  local creds = { access = data.access_token, refresh = refresh, expires = os.time() + math.floor(data.expires_in) }
  local ok, set_err = maki.provider.auth.set(slug, creds)
  if not ok then
    error("cannot store the Claude tokens: " .. tostring(set_err))
  end
  return creds
end

-- Accepts the `code#state` the callback page shows, or the redirect URL.
local function parse_code(input)
  local code = input:match("code=([^&#%s]+)") or input:match("^%s*([^#%s]+)")
  local state = input:match("state=([^&#%s]+)") or input:match("#(%S+)")
  return code, state
end

local function auth_headers(access)
  local headers = { authorization = "Bearer " .. access }
  local atis = maki.uv.os_getenv("CLAUDE_ATIS") or ATIS_DEFAULT
  if atis ~= "" and atis ~= "off" then
    headers["x-cc-atis"] = atis
  end
  return headers
end

local function auth(ctx, purpose)
  local creds = maki.provider.auth.get(ctx.slug)
  if not creds then
    -- Where login cannot run, say why instead of sending the user to it.
    local command, err = pkce_command()
    return fail(NEEDS_LOGIN, command and NOT_LOGGED_IN or err)
  end
  if purpose == "refresh" or (purpose == "resolve" and creds.expires <= os.time() + REFRESH_MARGIN_S) then
    local err
    creds, err =
      grant(ctx.slug, { grant_type = "refresh_token", client_id = CLIENT_ID, refresh_token = creds.refresh }, creds)
    if not creds then
      return nil, err
    end
  end
  return { headers = auth_headers(creds.access) }
end

-- The models the subscription serves. Like Claude Code, a model with a 1M
-- window is offered only with it, under the `-1m` id that makes maki ask for
-- the long context.
local function list_models(ctx)
  local headers = { ["anthropic-version"] = API_VERSION }
  for name, value in pairs(ctx.headers) do
    headers[name] = value
  end
  local data, err = request(MODELS_URL, { headers = headers })
  if not data then
    return nil, err
  end
  local rows = {}
  for _, model in ipairs(data.data or {}) do
    local window = model.max_input_tokens or 0
    local long = window >= LONG_CONTEXT
    local capabilities = model.capabilities or {}
    table.insert(rows, {
      id = long and (model.id .. LONG_CONTEXT_SUFFIX) or model.id,
      context_window = long and LONG_CONTEXT or (window > 0 and window or nil),
      max_output_tokens = model.max_tokens,
      supports_thinking = (capabilities.thinking or {}).supported,
      supports_vision = (capabilities.image_input or {}).supported,
    })
  end
  return rows
end

-- Unix time of an RFC 3339 stamp, to the nearest minute: the reset Anthropic
-- reports drifts by fractions of a second. Luau reads an os.time table as UTC.
local function parse_time(stamp)
  local year, month, day, hour, min, sec = stamp:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  local time = year
    and os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(min),
      sec = tonumber(sec),
    })
  if not time then
    return nil
  end
  local sign, offset_hour, offset_min = stamp:match("([+-])(%d%d):?(%d%d)$")
  local offset = sign and (tonumber(offset_hour) * 3600 + tonumber(offset_min) * 60) or 0
  local utc = (sign == "-" and time + offset or time - offset) + 30
  return utc - utc % 60
end

-- Whether a limit on {model}, such as "Fable", covers the focused session's
-- model. Without a UI the session is unknown, so the limit counts.
local function covers_focused(model)
  local focused = maki.model.get()
  if type(focused) ~= "table" or focused.provider ~= SLUG or type(focused.id) ~= "string" then
    return true
  end
  local id = focused.id:lower():gsub("%W", "")
  return id:find((model:lower():gsub("%W", "")), 1, true) ~= nil
end

-- What /api/oauth/usage reports for the account the {headers} log in as.
local function get_usage(headers)
  local merged = { ["anthropic-version"] = API_VERSION, ["anthropic-beta"] = OAUTH_BETA }
  for name, value in pairs(headers) do
    merged[name] = value
  end
  local usage = request(USAGE_URL, { headers = merged })
  return type(usage) == "table" and usage or nil
end

-- The plan limits in a usage answer, each with its period ("5-hour", "weekly"),
-- the model it is scoped to, if any, and its reset as Unix time.
local function plan_limits(usage)
  local limits = {}
  for _, limit in ipairs(type(usage.limits) == "table" and usage.limits or {}) do
    local scope = type(limit.scope) == "table" and limit.scope.model
    if type(limit.percent) == "number" then
      table.insert(limits, {
        kind = limit.kind,
        period = limit.kind == "session" and "5-hour" or (type(limit.group) == "string" and limit.group or "plan"),
        model = type(scope) == "table" and type(scope.display_name) == "string" and scope.display_name or nil,
        percent = limit.percent,
        reset = type(limit.resets_at) == "string" and parse_time(limit.resets_at) or nil,
      })
    end
  end
  return limits
end

-- What a 429 means when a plan limit that covers the request is used up.
-- Without one it is a passing rate limit, which maki retries.
local function usage_message(usage)
  local used_up, every_model, weekly = {}, false, nil
  for _, limit in ipairs(plan_limits(usage)) do
    if limit.percent >= USED_UP and (not limit.model or covers_focused(limit.model)) then
      table.insert(
        used_up,
        ("the %s%s limit is used up%s"):format(
          limit.period,
          limit.model and (" " .. limit.model) or "",
          limit.reset and (" until " .. os.date(RESET_FORMAT, limit.reset)) or ""
        )
      )
      every_model = every_model or not limit.model
    elseif limit.kind == "weekly_all" then
      weekly = limit.percent
    end
  end
  if #used_up == 0 then
    return nil
  end
  local parts = { "Claude usage limit reached: " .. table.concat(used_up, " and ") .. "." }
  if weekly and not every_model then
    table.insert(
      parts,
      ("The weekly limit for all models is at %d%%, so other models still work: pick one with /model."):format(weekly)
    )
  end
  local extra = usage.extra_usage
  if type(extra) == "table" and extra.is_enabled == false then
    local reason = type(extra.disabled_reason) == "string" and (": " .. extra.disabled_reason:gsub("_", " ")) or ""
    table.insert(parts, "Extra usage is off" .. reason .. ".")
  end
  return table.concat(parts, " ")
end

-- The usage left on each plan limit, as spans for the hint line.
local function usage_spans(usage)
  local spans = {}
  for _, limit in ipairs(plan_limits(usage)) do
    local left = math.max(0, math.floor(100 - limit.percent + 0.5))
    local text = ("%s %d%% left"):format(limit.model or limit.period, left)
    if limit.percent >= USED_UP then
      local reset = limit.reset and (" until " .. os.date(SHORT_RESET_FORMAT, limit.reset)) or ""
      table.insert(spans, { text .. reset, "error" })
    else
      table.insert(spans, { text, left < LOW_LEFT and "warning" or "dim" })
    end
  end
  return spans
end

-- What the hint line shows: the last turn's speed and the usage left.
local readout = { usage = {} }

local function render_readout()
  local spans = {}
  if readout.speed then
    table.insert(spans, { ("%d tok/s"):format(math.floor(readout.speed + 0.5)), "accent" })
  end
  for _, span in ipairs(readout.usage) do
    if #spans > 0 then
      table.insert(spans, { SEPARATOR, "dim" })
    end
    table.insert(spans, span)
  end
  maki.ui.set_status_hint(#spans > 0 and spans or nil)
end

-- Uses the stored token as it is. Refreshing it is the auth hook's job, and two
-- refreshes would race for the one refresh token.
local function refresh_usage()
  maki.async.spawn(function()
    if not maki.session.live() then
      return
    end
    local creds = maki.provider.auth.get(SLUG)
    if not creds then
      readout.usage = {}
    elseif creds.expires > os.time() then
      local usage = get_usage(auth_headers(creds.access))
      readout.usage = usage and usage_spans(usage) or readout.usage
    end
    render_readout()
  end)
end

-- A used-up plan limit does not pass before it resets, so its 429 becomes a 402
-- that says which limit and when. Every other error stays as it is.
local function map_error(ctx, status)
  if status ~= RATE_LIMITED then
    return nil
  end
  local usage = get_usage(ctx.headers)
  if not usage then
    return nil
  end
  readout.usage = usage_spans(usage)
  render_readout()
  local message = usage_message(usage)
  return message and { status = OUT_OF_USAGE, message = message } or nil
end

-- Each session's running turn: when it started, and how long tool calls and
-- permission prompts held it, with overlaps counted once.
local turns = {}

local function hold(session, on)
  local turn = turns[session]
  if not turn then
    return
  end
  if on then
    if turn.holds == 0 then
      turn.since = os.clock()
    end
    turn.holds = turn.holds + 1
  elseif turn.holds > 0 then
    turn.holds = turn.holds - 1
    if turn.holds == 0 then
      turn.held = turn.held + os.clock() - turn.since
    end
  end
end

-- Output tokens over the time the model spent on the turn. In Luau, os.clock is
-- a monotonic wall clock, not processor time.
local function turn_speed(turn, usage)
  local now = os.clock()
  local held = turn.held + (turn.holds > 0 and now - turn.since or 0)
  local seconds = now - turn.start - held
  local output = type(usage) == "table" and usage.output_tokens
  if type(output) == "number" and output > 0 and seconds >= MIN_MODEL_S then
    return output / seconds
  end
  return nil
end

local function login(ctx)
  local verifier, challenge = pkce()
  if not verifier then
    ctx.print(challenge)
    return
  end
  -- The authorize page accepts the verifier as state, which is what pi sends.
  local query = {
    "code=true",
    "client_id=" .. CLIENT_ID,
    "response_type=code",
    "redirect_uri=" .. urlencode(REDIRECT_URI),
    "scope=" .. urlencode(SCOPES),
    "code_challenge=" .. challenge,
    "code_challenge_method=S256",
    "state=" .. verifier,
  }
  local url = AUTHORIZE_URL .. "?" .. table.concat(query, "&")
  ctx.print("Log in to Claude in your browser:\n\n  " .. url .. "\n")
  ctx.open_url(url)
  local code, state = parse_code(ctx.prompt({ label = "Paste the code shown after you approve: " }) or "")
  if not code then
    ctx.print("No code entered, nothing was stored.")
    return
  end
  if state and state ~= verifier then
    ctx.print("OAuth state mismatch, start the login again.")
    return
  end
  local creds, err = grant(ctx.slug, {
    grant_type = "authorization_code",
    client_id = CLIENT_ID,
    code = code,
    state = verifier,
    redirect_uri = REDIRECT_URI,
    code_verifier = verifier,
  })
  if not creds then
    return nil, err
  end
  ctx.print("Logged in. Pick a model with /model.")
end

local function logout(ctx)
  maki.provider.auth.clear(ctx.slug)
  ctx.print("Claude tokens removed")
end

maki.provider.register({
  slug = SLUG,
  display_name = DISPLAY_NAME,
  codec = "anthropic",
  base_url = API_URL,
  system_prefix = IDENTITY,
  auth = auth,
  list_models = list_models,
  map_error = map_error,
  login = login,
  logout = logout,
})

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    turns[ev.data.session_id] = { start = os.clock(), held = 0, holds = 0, waiting = false }
  end,
})

maki.api.create_autocmd("ToolStart", {
  callback = function(ev)
    hold(ev.data.session_id, true)
  end,
})

maki.api.create_autocmd("ToolDone", {
  callback = function(ev)
    hold(ev.data.session_id, false)
  end,
})

maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(ev)
    local turn = turns[ev.data.session_id]
    local waiting = ev.data.status == "needs_input"
    if turn and turn.waiting ~= waiting then
      turn.waiting = waiting
      hold(ev.data.session_id, waiting)
    end
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(ev)
    local turn = turns[ev.data.session_id]
    turns[ev.data.session_id] = nil
    readout.speed = turn and turn_speed(turn, ev.data.usage) or readout.speed
    render_readout()
    refresh_usage()
  end,
})

maki.api.create_autocmd("SessionFocusChanged", { once = true, callback = refresh_usage })
