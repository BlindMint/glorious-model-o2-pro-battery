--!nonstrict
-- Bar widget for Glorious Model O 2 PRO charge.
-- Polls glorious-battery.py over HID. Does not change mouse settings.

local intervalSeconds = noctalia.getConfig("interval_seconds")
local showLabel = noctalia.getConfig("show_label")
local hideWhenMissing = noctalia.getConfig("hide_when_missing")
local warningThreshold = noctalia.getConfig("warning_threshold")
local scriptPath = noctalia.getConfig("script_path")

local inflight = false
local lastPayload = nil

local function resolveScript()
  local configured = noctalia.expandPath(scriptPath)
  if configured ~= "" then
    if not string.find(configured, "^/") then
      configured = noctalia.pluginDir() .. "/" .. configured
    end
    if noctalia.fileExists(configured) then
      return configured
    end
  end
  local bundled = noctalia.pluginDir() .. "/glorious-battery.py"
  if noctalia.fileExists(bundled) then
    return bundled
  end
  -- Dev checkout: script sits next to noctalia-plugin/
  local besidePlugin = noctalia.pluginDir() .. "/../glorious-battery.py"
  if noctalia.fileExists(besidePlugin) then
    return besidePlugin
  end
  return configured
end

local function glyphFor(payload)
  local state = payload.state
  local percent = payload.percent or 0
  if state == "missing" then
    return "battery-off"
  elseif state == "permission" or state == "error" then
    return "battery-exclamation"
  elseif state == "asleep" or state == "waking" then
    return "battery"
  elseif state == "charging" then
    return "battery-charging"
  elseif state == "full" then
    return "plug-filled"
  elseif percent >= 85 then
    return "battery-4"
  elseif percent >= 55 then
    return "battery-3"
  elseif percent >= 30 then
    return "battery-2"
  elseif percent >= 10 then
    return "battery-1"
  end
  return "battery"
end

local function colorFor(payload)
  local state = payload.state
  local percent = payload.percent
  if state == "permission" or state == "error" then
    return "error"
  elseif state == "missing" or state == "asleep" then
    return "on_surface_variant"
  elseif state == "charging" then
    return "primary"
  elseif state == "full" then
    return "primary"
  elseif state == "discharging" and warningThreshold > 0 and percent ~= nil and percent <= warningThreshold then
    return "error"
  end
  return "on_surface"
end

local function textFor(payload)
  if not showLabel then
    return ""
  end
  if payload.percent == nil then
    if payload.state == "missing" then
      return ""
    end
    return "?"
  end
  return `{payload.percent}%`
end

local function stateLabel(state)
  if state == "charging" then
    return "Charging"
  elseif state == "full" then
    return "Full / plugged in"
  elseif state == "discharging" then
    return "Discharging"
  elseif state == "asleep" then
    return "Asleep"
  elseif state == "waking" then
    return "Waking"
  end
  return state or "?"
end

local function tooltipFor(payload)
  if not payload.ok then
    return payload.error or "Mouse battery unavailable"
  end
  local connection = payload.connection
  if payload.plugged then
    connection = "wired"
  end
  return {
    { "Mouse", payload.name or "Glorious Model O 2 PRO" },
    { "Charge", `{payload.percent}%` },
    { "State", stateLabel(payload.state) },
    { "Connection", connection },
    { "USB", `{payload.vid}:{payload.pid}` },
  }
end

local function render(payload)
  lastPayload = payload
  local missing = payload.state == "missing"
  if hideWhenMissing and missing then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setGlyph(glyphFor(payload))
  barWidget.setText(textFor(payload))
  local color = colorFor(payload)
  barWidget.setColor(color)
  barWidget.setGlyphColor(color)
  barWidget.setTooltip(tooltipFor(payload))
end

local function applyStdout(stdout)
  local decoded, err = noctalia.json.decode(stdout)
  if decoded == nil then
    render({
      ok = false,
      state = "error",
      error = err or "could not parse battery JSON",
    })
    return
  end
  render(decoded)
end

local function poll()
  if inflight then
    return
  end
  local script = resolveScript()
  if script == "" or not noctalia.fileExists(script) then
    render({
      ok = false,
      state = "error",
      error = "battery reader script not found",
    })
    return
  end
  inflight = true
  noctalia.runAsync(`/usr/bin/python3 "{script}" --json`, function(result)
    inflight = false
    if result.timedOut then
      render({ ok = false, state = "error", error = "battery query timed out" })
      return
    end
    local stdout = noctalia.string.trim(result.stdout)
    if stdout ~= "" then
      applyStdout(stdout)
      return
    end
    if result.exitCode ~= 0 then
      render({
        ok = false,
        state = "error",
        error = noctalia.string.trim(result.stderr) ~= "" and noctalia.string.trim(result.stderr)
          or `battery query failed ({result.exitCode})`,
      })
      return
    end
    render({ ok = false, state = "error", error = "empty battery reply" })
  end)
end

function update()
  local seconds = intervalSeconds
  if typeof(seconds) ~= "number" or seconds < 5 then
    seconds = 60
  end
  noctalia.setUpdateInterval(seconds * 1000)
  poll()
end
