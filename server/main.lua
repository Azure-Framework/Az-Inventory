print(('[Az-Inventory] server loaded (%s)'):format(GetCurrentResourceName()))
-- server.lua (fixed + deterministic inventory:useItem + shop find fallback + shop:buyItem)
-- Inventory + shop robbery handler (server-side authoritative)
-- PER-LOCATION shop state support (fixes closing all locations when one is robbed)


-- Basic DB lib sanity check (this script expects MySQL.Sync.* from oxmysql/mysql-async)
CreateThread(function()
  Wait(0)
  if not MySQL or not MySQL.Sync then
    print('^1[Az-Inventory]^7 MySQL library not found. Ensure oxmysql (or mysql-async) is installed and loaded.')
  end
end)

local MAX_WEIGHT = 120.0
local PlayerInv   = {}  -- src → { [item]=count }
local PlayerW     = {}  -- src → weight
local Drops       = {}
local nextDropId  = 1
local ActiveCharID = {} -- src → charID
local LastDropAt = {}
local LastPickupAt = {}
local NOTIFY_EVERYTHING = true

-- Load Config (try global, then require)
Config = Config or (pcall(function() return require("config") end) and require("config") or nil) or Config or {}
Config.RobCooldown = tonumber(Config.RobCooldown or Config.robberyCooldown) or 600
Config.PersistStates = Config.PersistStates == true
Config.StateFile = Config.StateFile or "shop_states.json"
Config.RequiredWeaponItems = Config.RequiredWeaponItems or {}
Config.RequiredCops = tonumber(Config.RequiredCops or 0) or 0
Config.MaxRobDistance = tonumber(Config.MaxRobDistance or 4.0) or 4.0
Config.AntiSpam = Config.AntiSpam or { PerPlayerAttemptCooldown = 5 }
local DEBUG = Config.Debug or true

-- shopState now: shopState[ shopName ] = { closed = { [locIndex] = ts, ... } }
local shopState = {} -- populated from memory or file if persistence enabled

-- attemptRob anti-spam timestamps
local LastRobAttempt = {} -- src -> unix seconds


-- NORMALIZE SHOPS (server-side)
local function normalizeVectorLike(v)
  if not v then return nil end
  -- If it's already a table with x,y,z -> return normalized numbers
  if type(v) == "table" then
    if v.x ~= nil and v.y ~= nil and v.z ~= nil then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
    if v[1] ~= nil and v[2] ~= nil and v[3] ~= nil then
      return { x = tonumber(v[1]), y = tonumber(v[2]), z = tonumber(v[3]), w = tonumber(v[4]) or 0.0 }
    end
    return nil
  end

  -- userdata/vector3 vector4: try reading fields in pcall
  if type(v) == "userdata" then
    local ok, _ = pcall(function() return v.x end)
    if ok then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
  end

  -- string fallback: parse only after first '(' to avoid the '3' in "vector3("
  local s = tostring(v)
  local startAt = s:find("%(")
  if startAt then s = s:sub(startAt + 1) end
  local nums = {}
  for num in s:gmatch("([%-]?%d+%.?%d*)") do
    nums[#nums+1] = tonumber(num)
  end
  if #nums >= 3 then
    return { x = nums[1], y = nums[2], z = nums[3], w = nums[4] or 0.0 }
  end
  return nil
end

local function normalizeShopsTable()
  if not Shops or type(Shops) ~= "table" then return end
  for i, shop in ipairs(Shops) do
    -- normalize coords (single)
    if shop.coords then
      local n = normalizeVectorLike(shop.coords)
      if n then shop.coords = n end
    end

    -- normalize ped.coords if vector4
    if shop.ped and shop.ped.coords then
      local n = normalizeVectorLike(shop.ped.coords)
      if n then shop.ped.coords = { x = n.x, y = n.y, z = n.z, w = n.w } end
    end

    -- normalize each entry of locations -> table {x,y,z,w}
    if shop.locations and type(shop.locations) == "table" and #shop.locations > 0 then
      local out = {}
      for j, loc in ipairs(shop.locations) do
        local n = normalizeVectorLike(loc)
        if n then
          out[#out+1] = n
        else
          -- keep original if we can't parse (but log)
          print(("[SHOP] normalizeShopsTable: could not parse locations[%d] for shop '%s'"):format(j, tostring(shop.name)))
        end
      end
      shop.locations = out
    end

    -- Ensure radius numeric
    if shop.radius then shop.radius = tonumber(shop.radius) or shop.radius end
  end
  -- optional: print a short confirmation
  if DEBUG then print(("[SHOP] normalizeShopsTable: normalized %d shops on server"):format(#Shops)) end
end


normalizeShopsTable()

-- helper: Notify (uses notify helper if present, falls back to chat)
local function safeNotify(src, msg, opts)
  if not src or not msg then return end
  opts = opts or {}
  if type(notify) == "function" then
    pcall(notify, src, msg, opts)
    return
  end
  local ok = pcall(function()
    TriggerClientEvent('ox_lib:notify', src, {
      id = opts.id or ("shop_notify_"..tostring(src).."_"..tostring(os.time())),
      title = opts.title or (opts.type == "error" and "Error" or "Notice"),
      description = msg,
      duration = opts.duration or 3000,
      type = opts.type or "inform"
    })
  end)
  if not ok then
    TriggerClientEvent('chat:addMessage', src, { args = { '^2SHOP', tostring(msg) } })
  end
end

-- Helper: extract Discord ID from identifiers
local function getDiscordFromIdentifiers(src)
  local ids = GetPlayerIdentifiers(src) or {}
  for _, id in ipairs(ids) do
    if type(id) == "string" then
      local d = id:match("^discord:(%d+)$")
      if d and #d >= 17 then return d end
      d = id:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d?)")
      if d and #d >= 17 then return d end
    end
  end
  return ""
end

-- Synchronous helper: get keys (discord, char)
local function getPlayerKeysSync(src)
  local discordID = getDiscordFromIdentifiers(src) or ""
  local charID = ""
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    local ok, res = pcall(function() return exports['Az-Framework']:GetPlayerCharacter(src) end)
    if ok and res and res ~= "" then
      charID = tostring(res)
      ActiveCharID[src] = charID
    end
  end
  if charID == "" then
    charID = ActiveCharID[src] or ""
  end
  return discordID, charID
end

local function getPlayerKeys(src) return getPlayerKeysSync(src) end

-- Compute total carry weight
local function computeWeight(inv)
  local total = 0.0
  for item, cnt in pairs(inv) do
    local def = Items and Items[item]
    if def and def.weight then
      total = total + def.weight * cnt
    else
      -- fallback: count as 1 weight per unit if no definition
      total = total + (tonumber(cnt) or 0) * 1.0
    end
  end
  return total
end

-- Load player's inventory from DB (synchronous)
local function loadInv(src)
  local discordID, charID = getPlayerKeysSync(src)
  if discordID == "" or charID == "" then
    -- Preserve any existing in-memory inventory for this source.
    PlayerInv[src] = PlayerInv[src] or {}
    PlayerW[src] = computeWeight(PlayerInv[src])
    return PlayerInv[src]
  end

  local rows = {}
  local ok, res = pcall(function()
    return MySQL.Sync.fetchAll([[
      SELECT item, count
        FROM user_inventory
       WHERE discordid = @discordid
         AND charid    = @charid
    ]], { ['@discordid'] = discordID, ['@charid'] = charID })
  end)
  if ok and type(res) == "table" then rows = res else rows = {} end

  local inv = {}
  for _, row in ipairs(rows) do
    inv[row.item] = row.count
  end
  PlayerInv[src] = inv
  PlayerW[src] = computeWeight(inv)
  return inv
end

function ensureInv(src)
  if not PlayerInv[src] then loadInv(src) end
  return PlayerInv[src] or {}
end

local function sendInv(src)
  local inv = ensureInv(src)
  local weight = computeWeight(inv)
  PlayerW[src] = weight
  TriggerClientEvent("inventory:refresh", src, inv, weight, MAX_WEIGHT)
end

-- Synchronous save item slot (logs when skipping DB write)
local function saveItemSlot(src, itemKey)
  local inv = ensureInv(src)
  local count = inv[itemKey] or 0
  local discordID = getDiscordFromIdentifiers(src) or ""

  if (discordID == "" or discordID == nil) and exports['Az-Framework'] then
    if exports['Az-Framework'].getDiscordID then
      local ok, res = pcall(function() return exports['Az-Framework']:getDiscordID(src) end)
      if ok and res and res ~= "" then discordID = tostring(res) end
    elseif exports['Az-Framework'].GetDiscordID then
      local ok, res = pcall(function() return exports['Az-Framework']:GetDiscordID(src) end)
      if ok and res and res ~= "" then discordID = tostring(res) end
    end
  end

  local charID = ""
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    local ok, res = pcall(function() return exports['Az-Framework']:GetPlayerCharacter(src) end)
    if ok and res and res ~= "" then charID = tostring(res); ActiveCharID[src] = charID end
  end
  if charID == "" then charID = ActiveCharID[src] or "" end

  if discordID == "" or charID == "" then
    print(("[inventory] saveItemSlot: skipping DB save for src=%s item=%s (discord=%s char=%s)"):format(tostring(src), tostring(itemKey), tostring(discordID), tostring(charID)))
    return
  end

  if count > 0 then
    MySQL.Sync.execute([[
      INSERT INTO user_inventory (discordid,charid,item,count)
      VALUES (@discordid,@charid,@item,@count)
      ON DUPLICATE KEY UPDATE count = @count
    ]], {
      ['@discordid'] = discordID,
      ['@charid']    = charID,
      ['@item']      = itemKey,
      ['@count']     = count
    })
    print(("[inventory] saveItemSlot: saved src=%s item=%s count=%s"):format(tostring(src), tostring(itemKey), tostring(count)))
  else
    MySQL.Sync.execute([[
      DELETE FROM user_inventory
       WHERE discordid = @discordid
         AND charid    = @charid
         AND item      = @item
    ]], {
      ['@discordid'] = discordID,
      ['@charid']    = charID,
      ['@item']      = itemKey
    })
    print(("[inventory] saveItemSlot: deleted src=%s item=%s (count=0)"):format(tostring(src), tostring(itemKey)))
  end
end

-- Replace the existing isPoliceJob with this version (with debug prints).
-- Supports Config.Police as:
--   - a string: "police" or "police,sheriff"
--   - a table: { "police", "sheriff" }
local function isPoliceJob(job)
  -- small helper to stringify simple tables for debug output
  local function tableToString(t)
    if type(t) ~= "table" then return tostring(t) end
    local pieces = {}
    for k, v in pairs(t) do
      local val = v
      if type(v) == "table" then val = "<table>" end
      table.insert(pieces, tostring(k) .. "=" .. tostring(val))
    end
    return "{" .. table.concat(pieces, ", ") .. "}"
  end

  local dbg = Config and Config.Debug

  if dbg then
    print("[isPoliceJob] called. job =", (type(job) == "table" and tableToString(job) or tostring(job)))
  end

  -- If the server operator configured Config.Police, prefer that
  if Config and Config.Police then
    if dbg then print("[isPoliceJob] Config.Police present. type:", type(Config.Police), "value:", (type(Config.Police) == "table" and tableToString(Config.Police) or tostring(Config.Police))) end

    local cfg = Config.Police
    local allowed = {}

    -- normalize string -> list (comma-separated allowed)
    if type(cfg) == "string" then
      for token in cfg:gmatch("[^,]+") do
        local t = token:match("^%s*(.-)%s*$") -- trim
        if t and t ~= "" then
          table.insert(allowed, t:lower())
          if dbg then print(("[isPoliceJob] added allowed (from string): %s"):format(t:lower())) end
        end
      end
    elseif type(cfg) == "table" then
      for _, v in pairs(cfg) do
        if v ~= nil then
          local s = tostring(v):match("^%s*(.-)%s*$")
          if s and s ~= "" then
            table.insert(allowed, s:lower())
            if dbg then print(("[isPoliceJob] added allowed (from table): %s"):format(s:lower())) end
          end
        end
      end
    end

    if dbg then
      print("[isPoliceJob] allowed list:", table.concat(allowed, ", "))
    end

    -- helper to test a job value (job may be string or table)
    local function jobMatches(jobVal)
      if not jobVal then
        if dbg then print("[isPoliceJob.jobMatches] jobVal is nil -> false") end
        return false
      end

      if type(jobVal) == "string" then
        local jl = jobVal:lower()
        if dbg then print("[isPoliceJob.jobMatches] testing string job:", jl) end
        for _, a in ipairs(allowed) do
          if jl == a then
            if dbg then print(("[isPoliceJob.jobMatches] match found: %s == %s"):format(jl, a)) end
            return true
          end
        end
        if dbg then print(("[isPoliceJob.jobMatches] no match for string job: %s"):format(jl)) end
        return false
      end

      if type(jobVal) == "table" then
        if dbg then print("[isPoliceJob.jobMatches] testing table job:", tableToString(jobVal)) end
        local name = nil
        if type(jobVal.name) == "string" then name = jobVal.name end
        if not name and type(jobVal.job) == "string" then name = jobVal.job end
        if name then
          local jl = name:lower()
          if dbg then print("[isPoliceJob.jobMatches] extracted name/job:", jl) end
          for _, a in ipairs(allowed) do
            if jl == a then
              if dbg then print(("[isPoliceJob.jobMatches] match found: %s == %s"):format(jl, a)) end
              return true
            end
          end
          if dbg then print(("[isPoliceJob.jobMatches] no match for extracted name: %s"):format(jl)) end
        else
          if dbg then print("[isPoliceJob.jobMatches] table job has no name/job string field") end
        end
        return false
      end

      if dbg then print("[isPoliceJob.jobMatches] unsupported jobVal type:", type(jobVal)) end
      return false
    end

    local result = jobMatches(job)
    if dbg then print("[isPoliceJob] returning (from Config.Police path):", tostring(result)) end
    return result
  end

  -- Fallback: existing behaviour (detect 'police' from common job shapes)
  if dbg then print("[isPoliceJob] no Config.Police set -> using fallback behaviour") end

  if not job then
    if dbg then print("[isPoliceJob] job is nil -> false") end
    return false
  end

  if type(job) == "string" then
    local res = (job:lower() == "police")
    if dbg then print(("[isPoliceJob] string job '%s' -> %s"):format(job, tostring(res))) end
    return res
  end

  if type(job) == "table" then
    local name = nil
    if type(job.name) == "string" then name = job.name end
    if not name and type(job.job) == "string" then name = job.job end
    if name then
      local res = (name:lower() == "police")
      if dbg then print(("[isPoliceJob] table job name '%s' -> %s"):format(name, tostring(res))) end
      return res
    else
      if dbg then print("[isPoliceJob] table job has no name/job string field -> false") end
    end
  end

  if dbg then print("[isPoliceJob] final return false") end
  return false
end

-- Simple helper: resolve a player's current character ID using only Az-Framework
local function getPlayerCharID(src)
  if not src then return nil end
  src = tonumber(src) or src

  -- 1) Prefer in-memory cache
  if ActiveCharID and ActiveCharID[src] and tostring(ActiveCharID[src]) ~= "" then
    if DEBUG then
      print(("[SHOP] getPlayerCharID: returning ActiveCharID cache for src=%s -> %s"):format(tostring(src), tostring(ActiveCharID[src])))
    end
    return tostring(ActiveCharID[src])
  end

  -- 2) Try Az-Framework export (colon-call) only
  if exports['Az-Framework'] and type(exports['Az-Framework'].GetPlayerCharacter) == 'function' then
    local ok, res = pcall(function() return exports['Az-Framework']:GetPlayerCharacter(src) end)
    if ok and res and tostring(res) ~= "" then
      ActiveCharID[src] = tostring(res)
      if DEBUG then print(("[SHOP] getPlayerCharID: Az-Framework:GetPlayerCharacter for src=%s -> %s"):format(tostring(src), tostring(res))) end
      return tostring(res)
    else
      if DEBUG then print(("[SHOP] getPlayerCharID: Az-Framework:GetPlayerCharacter returned nil/empty for src=%s (ok=%s res=%s)"):format(tostring(src), tostring(ok), tostring(res))) end
    end
  else
    if DEBUG then print("[SHOP] getPlayerCharID: exports['Az-Framework'].GetPlayerCharacter not available") end
  end

  -- 3) Fallback: cached ActiveCharID (if any) or nil
  if ActiveCharID and ActiveCharID[src] and tostring(ActiveCharID[src]) ~= "" then
    if DEBUG then print(("[SHOP] getPlayerCharID: falling back to ActiveCharID for src=%s -> %s"):format(tostring(src), tostring(ActiveCharID[src]))) end
    return tostring(ActiveCharID[src])
  end

  if DEBUG then print(("[SHOP] getPlayerCharID: could not resolve character for src=%s"):format(tostring(src))) end
  return nil
end

-- Simple helper: synchronously fetch a player's job using only Az-Framework
local function getPlayerJobSync(src)
  if not src then return nil end
  src = tonumber(src) or src

  if exports['Az-Framework'] and type(exports['Az-Framework'].getPlayerJob) == 'function' then
    local ok, res = pcall(function() return exports['Az-Framework']:getPlayerJob(src) end)
    if ok and res ~= nil then
      if DEBUG then print(("[SHOP] getPlayerJobSync: Az-Framework:getPlayerJob for src=%s -> %s"):format(tostring(src), tostring(res))) end
      return res
    else
      if DEBUG then print(("[SHOP] getPlayerJobSync: Az-Framework:getPlayerJob returned nil for src=%s (ok=%s res=%s)"):format(tostring(src), tostring(ok), tostring(res))) end
      return nil
    end
  else
    if DEBUG then print("[SHOP] getPlayerJobSync: exports['Az-Framework'].getPlayerJob not available") end
    return nil
  end
end

-- Fixed countOnlineCops() using only the above Az-Framework helpers
local function countOnlineCops()
  local cnt = 0
  local players = GetPlayers() or {}

  for _, plyId in ipairs(players) do
    local src = tonumber(plyId) or plyId

    -- Resolve character id (cache or Az-Framework)
    local char = getPlayerCharID(src)
    if DEBUG then print(("[SHOP] countOnlineCops: GetPlayerCharacter for src=%s -> %s"):format(tostring(src), tostring(char))) end

    if not char or char == "" then
      if DEBUG then
        print(("[SHOP] countOnlineCops: skipping src=%s because GetPlayerCharacter returned nil/empty."):format(tostring(src)))
        local ids = GetPlayerIdentifiers(src) or {}
        print(("[SHOP] countOnlineCops: src=%s identifiers: %s"):format(tostring(src), table.concat(ids, ", ")))
      end
      goto continue_player_loop
    end

    -- Resolve job using Az-Framework only
    local jobVal = getPlayerJobSync(src)
    if DEBUG then print(("[SHOP] countOnlineCops: getPlayerJob for src=%s -> %s"):format(tostring(src), tostring(jobVal))) end

    -- Normalize jobVal to a string name for isPoliceJob()
    local jobName = nil
    if jobVal then
      if type(jobVal) == "string" then
        jobName = jobVal
      elseif type(jobVal) == "table" then
        jobName = jobVal.name or jobVal.job or jobVal.active_department or jobVal.label
      end
    end

    if not jobName then
      if DEBUG then print(("[SHOP] countOnlineCops: could not resolve job name for src=%s (jobVal=%s)"):format(tostring(src), tostring(jobVal))) end
      goto continue_player_loop
    end

    if isPoliceJob(jobName) then
      cnt = cnt + 1
      if DEBUG then print(("[SHOP] countOnlineCops: counted police -> src=%s job=%s (total=%d)"):format(tostring(src), tostring(jobName), cnt)) end
    else
      if DEBUG then print(("[SHOP] countOnlineCops: not police -> src=%s job=%s"):format(tostring(src), tostring(jobName))) end
    end

    ::continue_player_loop::
  end

  if DEBUG then print(("[SHOP] countOnlineCops -> counted %d cops online (required maybe %s)"):format(cnt, tostring(Config and Config.RequiredCops))) end
  return cnt
end

-- Fixed notifyPoliceViaAzFramework() using only the above Az-Framework helpers
local function notifyPoliceViaAzFramework(shopName, locIndex, coords, closedUntil, robberSrc)
  -- Broadcast generic event for any listener
  TriggerClientEvent('shop:robberyAlert', -1, {
    shop = shopName,
    locIndex = locIndex,
    coords = coords,
    closedUntil = closedUntil,
    robberSrc = robberSrc
  })

  if not Config or (Config.NotifyPolice == false) then
    if DEBUG then print("[SHOP] notifyPoliceViaAzFramework: Config.NotifyPolice disabled or Config nil; aborting police-specific notify") end
    return
  end

  for _, plyId in ipairs(GetPlayers()) do
    local src = tonumber(plyId) or plyId

    -- Ensure active character (cache or Az-Framework)
    local char = getPlayerCharID(src)
    if not char or char == "" then
      if DEBUG then print(("[SHOP] notifyPoliceViaAzFramework: skipping src=%s - no active character"):format(tostring(src))) end
      goto continue_notify_loop
    end

    -- Resolve job (Az-Framework only)
    local jobVal = getPlayerJobSync(src)
    if DEBUG then print(("[SHOP] notifyPoliceViaAzFramework: getPlayerJob for src=%s -> %s"):format(tostring(src), tostring(jobVal))) end

    local jobName = nil
    if jobVal then
      if type(jobVal) == "string" then
        jobName = jobVal
      elseif type(jobVal) == "table" then
        jobName = jobVal.name or jobVal.job or jobVal.active_department or jobVal.label
      end
    end

    if jobName and isPoliceJob(jobName) then
      if DEBUG then print(("[SHOP] notifyPoliceViaAzFramework: notifying police src=%s job=%s"):format(tostring(src), tostring(jobName))) end
      TriggerClientEvent('shop:robberyAlertPolice', src, {
        shop = shopName,
        locIndex = locIndex,
        coords = coords,
        closedUntil = closedUntil,
        robberSrc = robberSrc
      })
    else
      if DEBUG then print(("[SHOP] notifyPoliceViaAzFramework: skipping src=%s (not police or job unknown)"):format(tostring(src))) end
    end

    ::continue_notify_loop::
  end
end



-- Inventory RPCs (preserve in-memory inv when no identifiers)
RegisterNetEvent("inventory:refreshRequest")
AddEventHandler("inventory:refreshRequest", function()
  local src = source
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    local ok, newCharID = pcall(function() return exports['Az-Framework']:GetPlayerCharacter(src) end)
    if ok and newCharID and newCharID ~= "" then
      ActiveCharID[src] = newCharID
    end
  end

  local discordID, charID = getPlayerKeysSync(src)
  if discordID == "" or charID == "" then
    -- Keep any in-memory inventory for the session; do not zero it out.
    if not PlayerInv[src] then
      PlayerInv[src] = {}
      PlayerW[src] = 0.0
    end
    TriggerClientEvent("inventory:refresh", src, PlayerInv[src] or {}, PlayerW[src] or 0.0, MAX_WEIGHT)
    return
  end

  loadInv(src)
  sendInv(src)
end)

-- giveitem / removeitem / useItem / dropItem / pickupDrop
RegisterCommand("giveitem", function(src, args)
  local target = tonumber(args[1]) or src
  local key    = args[2]
  local qty    = tonumber(args[3]) or 1
  if not Items or not Items[key] then
    safeNotify(src, "Invalid item: ".. tostring(key), { type = "error", title = "Inventory" })
    return
  end
  local inv = ensureInv(target)
  local newW = (PlayerW[target] or computeWeight(inv)) + (Items[key].weight or 0) * qty
  if newW > MAX_WEIGHT then
    safeNotify(src, "Cannot carry that much.", { type = "error", title = "Inventory" })
    return
  end
  inv[key] = (inv[key] or 0) + qty
  saveItemSlot(target, key)
  sendInv(target)
  safeNotify(src, ("Gave %d× %s to ID %d"):format(qty, Items[key].label or key, target), { type = "success", title = "Inventory" })
  if target ~= src then
    safeNotify(target, ("You received %d× %s from ID %d"):format(qty, Items[key].label or key, src), { type = "success", title = "Inventory" })
  end
end, false)

RegisterCommand("removeitem", function(src, args)
  local key = args[1]
  local qty = tonumber(args[2]) or 1
  local inv = ensureInv(src)
  if not inv[key] or inv[key] < qty then
    safeNotify(src, "Not enough items.", { type = "error", title = "Inventory" })
    return
  end
  inv[key] = inv[key] - qty
  if inv[key] <= 0 then inv[key] = nil end
  saveItemSlot(src, key)
  sendInv(src)
  safeNotify(src, ("Removed %d× %s"):format(qty, Items[key] and Items[key].label or key), { type = "success", title = "Inventory" })
end, false)

-- === Deterministic inventory:useItem (server-side) ===
RegisterNetEvent("inventory:useItem")
AddEventHandler("inventory:useItem", function(key, qty)
  local src = source
  qty = tonumber(qty) or 1
  if qty < 1 then qty = 1 end
  if not key then return end

  local inv = ensureInv(src)
  if not inv then
    print(("[inventory] useItem: no inventory table for src=%s"):format(tostring(src)))
    safeNotify(src, "Inventory error.", { type = "error", title = "Inventory" })
    return
  end

  local beforeCount = inv[key] or 0
  print(("[inventory] useItem - before remove (src=%s item=%s count=%s)"):format(tostring(src), tostring(key), tostring(beforeCount)))

  if beforeCount < qty then
    safeNotify(src, ("You don't have %d× %s to use."):format(qty, key), { type = "error", title = "Inventory" })
    return
  end

  -- remove item from inventory (in-memory)
  inv[key] = beforeCount - qty
  if inv[key] <= 0 then inv[key] = nil end

  local afterCount = inv[key] or 0
  print(("[inventory] useItem - after remove (src=%s item=%s count=%s)"):format(tostring(src), tostring(key), tostring(afterCount)))

  -- persist that slot (if possible) and send immediate refresh to client
  local ok, err = pcall(function() saveItemSlot(src, key) end)
  if not ok then
    print(("[inventory] useItem - saveItemSlot failed for src=%s item=%s err=%s"):format(tostring(src), tostring(key), tostring(err)))
  end

  -- update weight & send immediate refresh
  PlayerW[src] = computeWeight(inv)
  TriggerClientEvent("inventory:refresh", src, inv, PlayerW[src] or 0.0, MAX_WEIGHT)

  safeNotify(src, ("Used %d× %s"):format(qty, key), { type = "inform", title = "Inventory" })

  -- post-use routing: broadcast and call handlers (server-side)
  local def = nil
  if GetItemDefinition then
    local okd, resd = pcall(function() return GetItemDefinition(key) end)
    if okd and resd then def = resd end
  end
  if not def and Items then def = Items[key] end

  pcall(function() TriggerEvent('inventory:itemUsed', src, key, qty, def) end)

  if def and def.server and def.server.event and type(def.server.event) == 'string' then
    pcall(function() TriggerEvent(def.server.event, src, key, qty, def) end)
  end

  if def and def.server and (def.server.export or def.server.exports) then
    local exp = def.server.export or def.server.exports
    local resourceName, funcName
    if type(exp) == 'string' then
      resourceName, funcName = exp:match("^([^:]+):(.+)$")
    elseif type(exp) == 'table' then
      resourceName, funcName = exp.resource, exp.func
    end

    if resourceName and funcName and exports[resourceName] then
      local ok2, res = pcall(function()
        return exports[resourceName][funcName](src, key, qty, def)
      end)
      if not ok2 then
        print(("inventory:useItem - export call %s:%s failed: %s"):format(tostring(resourceName), tostring(funcName), tostring(res)))
      end
    end
  end

  if def and def.client and def.client.event and type(def.client.event) == 'string' then
    pcall(function() TriggerClientEvent(def.client.event, src, key, qty, def) end)
  end

  if def and def.client and (def.client.export or def.client.exports) then
    local exp = def.client.export or def.client.exports
    pcall(function() TriggerClientEvent('inventory:callClientExport', src, exp, key, qty, def) end)
  end

  -- === NEW: server-decided weapon give (authoritative) ===
  if def and (def.weaponName or def.weapon) then
    local wname = def.weaponName or def.weapon
    local wammo = tonumber(def.ammo) or tonumber(def.ammoCount) or 0

    print(("[inventory] useItem -> requesting giveWeapon to src=%s weapon=%s ammo=%s"):format(tostring(src), tostring(wname), tostring(wammo)))

    local ok3, err3 = pcall(function()
      TriggerClientEvent('inventory:giveWeapon', src, wname, wammo)
    end)
    if not ok3 then
      print(("[inventory] FAILED to TriggerClientEvent giveWeapon for src=%s err=%s"):format(tostring(src), tostring(err3)))
    end
  else
    if not def then
      print(("[inventory] useItem -> no server-side def found for key=%s (src=%s)"):format(tostring(key), tostring(src)))
    end
  end
end)

-- Drop/pickup handlers
RegisterNetEvent("inventory:dropItem")
AddEventHandler("inventory:dropItem", function(itemKey, x, y, z, qty)
  local src = source
  qty = tonumber(qty) or 1
  if qty < 1 then qty = 1 end

  local now = GetGameTimer and GetGameTimer() or (os.time()*1000)
  if LastDropAt[src] and (now - LastDropAt[src]) < 300 then
    safeNotify(src, "Dropping too fast — please slow down.", { type = "warning", title = "Inventory" })
    return
  end
  LastDropAt[src] = now

  local discordID, charID = getPlayerKeysSync(src)
  if discordID == "" or charID == "" then
    safeNotify(src, "Cannot drop items: Discord or character data missing.", { type = "error", title = "Inventory" })
    return
  end

  local inv = ensureInv(src)
  local have = inv[itemKey] or 0
  if have < qty then
    safeNotify(src, ("You don't have %d× %s to drop."):format(qty, tostring(itemKey)), { type = "error", title = "Inventory" })
    return
  end

  inv[itemKey] = have - qty
  if inv[itemKey] <= 0 then inv[itemKey] = nil end

  saveItemSlot(src, itemKey)
  sendInv(src)

  local dropId = nextDropId
  nextDropId = nextDropId + 1
  Drops[dropId] = { id = dropId, item = itemKey, count = qty, coords = { x=x, y=y, z=z } }

  TriggerClientEvent("inventory:spawnDrop", -1, Drops[dropId])
  safeNotify(src, ("Dropped %d× %s. (Drop ID: %d)"):format(qty, itemKey, dropId), { type = "inform", title = "Inventory" })
end)

RegisterNetEvent("inventory:pickupDrop")
AddEventHandler("inventory:pickupDrop", function(dropId)
  local src = source
  local now = GetGameTimer and GetGameTimer() or (os.time()*1000)
  if LastPickupAt[src] and (now - LastPickupAt[src]) < 300 then
    safeNotify(src, "Picking up too fast — please slow down.", { type = "warning", title = "Inventory" })
    return
  end
  LastPickupAt[src] = now

  local d = Drops[dropId]
  if not d then
    safeNotify(src, "That drop no longer exists.", { type = "error", title = "Inventory" })
    return
  end

  local inv = ensureInv(src)
  local addCount = tonumber(d.count) or 1
  local newW = (PlayerW[src] or computeWeight(inv)) + (Items[d.item] and (Items[d.item].weight * addCount) or 0)
  if newW > MAX_WEIGHT then
    safeNotify(src, "You cannot carry that many items.", { type = "error", title = "Inventory" })
    return
  end

  Drops[dropId] = nil
  TriggerClientEvent("inventory:removeDrop", -1, dropId)

  inv[d.item] = (inv[d.item] or 0) + addCount
  saveItemSlot(src, d.item)
  sendInv(src)

  safeNotify(src, ("Picked up %d× %s. (Drop ID: %d)"):format(addCount, d.item, dropId), { type = "success", title = "Inventory" })
end)

-- ===== NEW: shop:buyItem helper and handler =====

-- tryChargePlayer: attempts to charge player via common economy exports (Az-Framework, QBCore, ESX).
-- returns true if charged (or if price == 0), false if insufficient funds or no supported economy integration.
local function tryChargePlayer(src, amount)
  amount = tonumber(amount) or 0
  if amount <= 0 then return true end

  -- 1) Az-Framework (common pattern)
  local ok, res = pcall(function()
    if exports['Az-Framework'] and type(exports['Az-Framework'].RemoveMoney) == 'function' then
      -- hypothetical API: RemoveMoney(src, amount, account) -> boolean (adjust as needed)
      return exports['Az-Framework']:RemoveMoney(src, amount)
    elseif exports['Az-Framework'] and type(exports['Az-Framework'].removeMoney) == 'function' then
      return exports['Az-Framework']:removeMoney(src, amount)
    end
    return nil
  end)
  if ok and res == true then
    if DEBUG then print(("[SHOP] tryChargePlayer: Az-Framework removed $%s from %s"):format(tostring(amount), tostring(src))) end
    return true
  end

  -- 2) QBCore
  ok, res = pcall(function()
    if QBCore and QBCore.Functions and QBCore.Functions.GetPlayer then
      local player = QBCore.Functions.GetPlayer(src)
      if player and player.Functions and player.Functions.RemoveMoney then
        -- try cash then bank
        if player.Functions.RemoveMoney("cash", amount) then return true end
        if player.Functions.RemoveMoney("bank", amount) then return true end
      end
    elseif exports['qb-core'] and exports['qb-core'].GetPlayer then
      local player = exports['qb-core'].GetPlayer(src)
      if player and player.Functions and player.Functions.RemoveMoney then
        if player.Functions.RemoveMoney("cash", amount) then return true end
        if player.Functions.RemoveMoney("bank", amount) then return true end
      end
    end
    return nil
  end)
  if ok and res == true then
    if DEBUG then print(("[SHOP] tryChargePlayer: QBCore removed $%s from %s"):format(tostring(amount), tostring(src))) end
    return true
  end

  -- 3) ESX (older)
  ok, res = pcall(function()
    if ESX and ESX.GetPlayerFromId then
      local xPlayer = ESX.GetPlayerFromId(src)
      if xPlayer then
        local money = 0
        if xPlayer.getMoney then money = xPlayer.getMoney() end
        if money and money >= amount then
          xPlayer.removeMoney(amount)
          return true
        end
        -- try bank
        if xPlayer.getAccount and xPlayer.getAccount('bank') and xPlayer.getAccount('bank').money and xPlayer.getAccount('bank').money >= amount then
          xPlayer.removeAccountMoney('bank', amount)
          return true
        end
      end
    end
    return nil
  end)
  if ok and res == true then
    if DEBUG then print(("[SHOP] tryChargePlayer: ESX removed $%s from %s"):format(tostring(amount), tostring(src))) end
    return true
  end

  -- 4) No supported economy found or insufficient funds.
  if DEBUG then print(("[SHOP] tryChargePlayer: no supported economy integration or insufficient funds for src=%s amount=%s"):format(tostring(src), tostring(amount))) end
  return false
end

-- shop:buyItem - client calls with (itemName, price) where price is usually passed by the NUI
RegisterNetEvent("shop:buyItem")
AddEventHandler("shop:buyItem", function(itemName, price)
  local src = source
  if not src then return end
  itemName = tostring(itemName or "")
  local offerPrice = tonumber(price) or 0

  if itemName == "" then
    safeNotify(src, "Invalid item.", { type = "error", title = "Shop" })
    print(("[SHOP] buyItem: invalid itemName from src=%s"):format(tostring(src)))
    return
  end

  if not Items or not Items[itemName] then
    -- still allow purchases of any strings? safer to reject
    safeNotify(src, ("Item '%s' not available."):format(itemName), { type = "error", title = "Shop" })
    print(("[SHOP] buyItem: unknown item '%s' requested by src=%s"):format(tostring(itemName), tostring(src)))
    return
  end

  -- load inventory & compute weight
  local inv = ensureInv(src)
  local itemDef = Items[itemName]
  local itemWeight = tonumber(itemDef.weight) or 0
  local currentW = PlayerW[src] or computeWeight(inv)
  local newW = currentW + (itemWeight * 1)

  if newW > MAX_WEIGHT then
    safeNotify(src, "You cannot carry that item (weight limit).", { type = "error", title = "Shop" })
    print(("[SHOP] buyItem: rejected due to weight for src=%s item=%s (newW=%.2f max=%.2f)"):format(tostring(src), tostring(itemName), tonumber(newW), tonumber(MAX_WEIGHT)))
    return
  end

  -- Attempt to charge player (if price > 0). If tryChargePlayer returns false => insufficient or integration missing
  local charged = true
  if offerPrice and offerPrice > 0 then
    charged = tryChargePlayer(src, offerPrice)
    if not charged then
      -- If no economy integration, we default to allowing purchase but warn in the log.
      -- You can uncomment the below to block purchases if not charged:
      -- safeNotify(src, "Insufficient funds.", { type = "error", title = "Shop" }); return
      print(("[SHOP] buyItem: could not charge src=%s amount=%s. Allowing fallback give (no integration or insufficient funds)"):format(tostring(src), tostring(offerPrice)))
    end
  end

  -- Add item to inventory (in-memory + persist)
  inv[itemName] = (inv[itemName] or 0) + 1
  PlayerInv[src] = inv
  PlayerW[src] = computeWeight(inv)
  saveItemSlot(src, itemName)

  -- immediate client refresh
  sendInv(src)

  -- feedback
  if offerPrice and offerPrice > 0 then
    safeNotify(src, ("You bought %s for $%s"):format(itemDef.label or itemName, tostring(offerPrice)), { type = "success", title = "Shop" })
  else
    safeNotify(src, ("You received %s"):format(itemDef.label or itemName), { type = "success", title = "Shop" })
  end

  print(("[SHOP] buyItem: src=%s bought %s for %s (charged=%s)"):format(tostring(src), tostring(itemName), tostring(offerPrice), tostring(charged)))
end)

-- === END shop:buyItem ===


-- ===== PER-LOCATION Shop state persistence helpers =====

local function ensureShopStateTable(name)
  shopState[name] = shopState[name] or { closed = {} }
  return shopState[name]
end

local function saveShopStatesToFile()
  if not Config.PersistStates then return end
  local data = {}
  for shopName, entry in pairs(shopState) do
    local out = { closed = {} }
    if entry and entry.closed then
      for idx, ts in pairs(entry.closed) do
        if tonumber(ts) and tonumber(ts) > os.time() then
          out.closed[tostring(idx)] = tonumber(ts)
        end
      end
    end
    if next(out.closed) ~= nil then
      data[shopName] = out
    end
  end
  local ok, encoded = pcall(function() return json.encode(data) end)
  if not ok then
    print("[SHOP] Failed to json.encode shopState for persistence")
    return
  end
  local resOk = SaveResourceFile(GetCurrentResourceName(), Config.StateFile, encoded, -1)
  if not resOk then
    print(("[SHOP] SaveResourceFile failed for %s"):format(Config.StateFile))
  else
    print(("[SHOP] shopState persisted to %s"):format(Config.StateFile))
  end
end

local function loadShopStatesFromFile()
  if not Config.PersistStates then return end
  local content = LoadResourceFile(GetCurrentResourceName(), Config.StateFile)
  if not content or content == "" then print("[SHOP] No persisted shop state file found"); return end
  local ok, decoded = pcall(function() return json.decode(content) end)
  if not ok or type(decoded) ~= 'table' then print("[SHOP] Failed to parse persisted shop state file"); return end
  for shopName, entry in pairs(decoded) do
    if entry and type(entry) == 'table' and entry.closed then
      local ent = ensureShopStateTable(shopName)
      for idxStr, ts in pairs(entry.closed) do
        local idx = tonumber(idxStr) or tonumber(idx)
        if idx and tonumber(ts) and tonumber(ts) > os.time() then
          ent.closed[idx] = tonumber(ts)
        end
      end
    end
  end
  print("[SHOP] Loaded persisted shop states from file")
end

-- Call load on script start (keeps compatibility with existing onResourceStart handler)
loadShopStatesFromFile()

-- Broadcast a single location change to all clients (shopName, locIndex, closedUntil or nil)
local function broadcastShopState(shopName, locIndex)
  local state = shopState[shopName]
  local ts = nil
  if state and state.closed and state.closed[locIndex] and state.closed[locIndex] > os.time() then
    ts = state.closed[locIndex]
  end
  TriggerClientEvent('shop:markRobbed', -1, shopName, locIndex, ts)
end

-- Are specific location closed?
local function isShopClosed(shopName, locIndex)
  local s = shopState[shopName]
  if not s or not s.closed then return false end
  local ts = s.closed[locIndex]
  if not ts then return false end
  return ts > os.time()
end

-- Ensure Shops table exists server-side; attempt to require shops.lua if not present
local Shops = Shops or {}

local function tryLoadShopsFile()
  if next(Shops or {}) then return end
  local ok, res = pcall(function() return require("shops") end)
  if ok and type(res) == "table" and #res > 0 then
    Shops = res
    print("[SHOP] Loaded shops from shops.lua via require()")
  end
end

-- vector helpers for server-side distance checks
local function isVectorLike(v)
  if not v then return false end
  if type(v) == "table" then
    if (v.x ~= nil and v.y ~= nil and v.z ~= nil) then return true end
    if (v[1] ~= nil and v[2] ~= nil and v[3] ~= nil) then return true end
    return false
  end
  local s = tostring(v)
  if type(s) == "string" then
    local found = 0
    for _ in s:gmatch("([%-]?%d+%.?%d*)") do found = found + 1 end
    if found >= 3 then return true end
  end
  return false
end

local function toVecTable(v)
  if not v then return nil end
  local t = type(v)
  if t == "table" then
    if v.x ~= nil and v.y ~= nil and v.z ~= nil then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
    if v[1] ~= nil and v[2] ~= nil and v[3] ~= nil then
      return { x = tonumber(v[1]), y = tonumber(v[2]), z = tonumber(v[3]), w = tonumber(v[4]) or 0.0 }
    end
    return nil
  end
  local s = tostring(v)
  local nums = {}
  for num in s:gmatch("([%-]?%d+%.?%d*)") do
    nums[#nums+1] = tonumber(num)
  end
  if #nums >= 3 then
    return { x = nums[1], y = nums[2], z = nums[3], w = nums[4] or 0.0 }
  end
  return nil
end

-- Helper: get array of location vector tables for a shop (server)
local function getShopLocations(shop)
  if not shop then return {} end
  if shop.locations and type(shop.locations) == "table" and #shop.locations > 0 then
    local out = {}
    for i, loc in ipairs(shop.locations) do
      if isVectorLike(loc) then
        local vt = toVecTable(loc)
        if vt then table.insert(out, vt) end
      end
    end
    return out
  end
  if shop.coords and isVectorLike(shop.coords) then
    local vt = toVecTable(shop.coords)
    if vt then return { vt } end
  end
  return {}
end

-- Find a shop by name (case-sensitive)
local function findShopByName(name)
  if not name then return nil end
  tryLoadShopsFile()
  if Shops and type(Shops) == "table" then
    for _, s in ipairs(Shops) do
      if s and s.name and tostring(s.name) == tostring(name) then
        return s
      end
    end
  end
  return nil
end

-- Debugging helper: print known shops on resource start (server-side)
AddEventHandler('onResourceStart', function(resourceName)
  if resourceName == GetCurrentResourceName() then
    tryLoadShopsFile()
    if Shops and type(Shops) == "table" then
      local count = #Shops
      print(("[SHOP] Server knows %d shops:"):format(count))
      for i, s in ipairs(Shops) do
        print(("[SHOP]   %d) %s (radius=%s)"):format(i, tostring(s.name or "nil"), tostring(s.radius or "nil")) )
      end
    else
      print("[SHOP] No Shops table found on server.")
    end
  end
end)

-- shop:attemptRob (server-side) — selects nearest location index and closes only that one
RegisterNetEvent('shop:attemptRob')
AddEventHandler('shop:attemptRob', function(shopName, px, py, pz)
  local src = source
  if not shopName or type(shopName) ~= 'string' then
    safeNotify(src, "Invalid shop.", { type = "error", title = "Shop" })
    return
  end

  local shopDef = findShopByName(shopName)
  if not shopDef then
    safeNotify(src, "Shop not found.", { type = "error", title = "Shop" })
    print(("[SHOP] attemptRob: shop '%s' not found on server (src=%s)"):format(tostring(shopName), tostring(src)))
    return
  end

  -- anti-spam
  local now = os.time()
  LastRobAttempt = LastRobAttempt or {}
  if LastRobAttempt[src] and (now - LastRobAttempt[src]) < (Config.AntiSpam and (Config.AntiSpam.PerPlayerAttemptCooldown or 5) or 5) then
    safeNotify(src, "Robbing too fast — please wait a moment.", { type = "warning", title = "Shop" })
    return
  end
  LastRobAttempt[src] = now

  -- cops requirement
  local cops = countOnlineCops and countOnlineCops() or 0
  local required = tonumber(Config.RequiredCops or 0) or 0
  if cops < required then
    -- Detailed debug output to server console (user requested)
    print(("[SHOP] attemptRob: Not enough police online for src=%s (counted=%d required=%d)"):format(tostring(src), cops, required))
    -- attempt to list each player's job for debugging
    for _, plyId in ipairs(GetPlayers()) do
      local psrc = tonumber(plyId) or plyId
      local ok, job = pcall(function()
        -- try common synchronous exports
        if exports['Az-Framework'] and type(exports['Az-Framework'].GetPlayerJob) == 'function' then
          return exports['Az-Framework']:GetPlayerJob(psrc)
        elseif exports['Az-Framework'] and type(exports['Az-Framework'].getPlayerJob) == 'function' then
          return exports['Az-Framework']:getPlayerJob(psrc)
        elseif exports['esx'] and type(exports['esx'].getPlayerFromId) == 'function' then
          local xPlayer = exports['esx']:getPlayerFromId(psrc)
          if xPlayer and xPlayer.job then return xPlayer.job.name or xPlayer.job.label or xPlayer.job end
        end
        return nil
      end)
      if ok and job ~= nil then
        print(("[SHOP] player %s job (sync) -> %s"):format(tostring(psrc), tostring(job)))
      else
        print(("[SHOP] player %s job (sync) -> <unknown or sync fetch failed>"):format(tostring(psrc)))
        -- try callback-style fetch if available
        if exports['Az-Framework'] and type(exports['Az-Framework'].getPlayerJob) == 'function' then
          pcall(function()
            exports['Az-Framework']:getPlayerJob(psrc, function(jobCb)
              print(("[SHOP] player %s job (cb) -> %s"):format(tostring(psrc), tostring(jobCb)))
            end)
          end)
        end
      end
    end

    safeNotify(src, ("Not enough police online to attempt a robbery. (%d/%d)"):format(cops, required), { type = "error", title = "Shop" })
    return
  end

  -- parse client coords (if provided)
  local cpx,cpy,cpz = tonumber(px), tonumber(py), tonumber(pz)
  if cpx and cpy and cpz then
    if DEBUG then print(("[SHOP] attemptRob: client coords for src=%s -> %.6f, %.6f, %.6f"):format(tostring(src), cpx, cpy, cpz)) end
  else
    if DEBUG then print(("[SHOP] attemptRob: no/invalid client coords provided by src=%s - skipping verbose distance check"):format(tostring(src))) end
  end

  -- compute nearest distance to any defined shop location
  local radius = tonumber(shopDef.radius) or 2.0
  local locs = getShopLocations(shopDef)
  if (not locs) or (#locs == 0) then
    -- fallback to coords field if locations is empty
    if shopDef.coords and isVectorLike(shopDef.coords) then
      local vt = toVecTable(shopDef.coords)
      if vt then locs = { vt } end
    end
  end

  -- determine nearest location index (if coords provided)
  local chosenIndex = 1
  local nearest = math.huge
  if cpx and cpy and cpz and locs and #locs > 0 then
    for i, loc in ipairs(locs) do
      local lx,ly,lz = tonumber(loc.x) or 0, tonumber(loc.y) or 0, tonumber(loc.z) or 0
      local dx,dy,dz = (cpx - lx), (cpy - ly), (cpz - lz)
      local d = math.sqrt(dx*dx + dy*dy + dz*dz)
      if DEBUG then
        print(("[SHOP] attemptRob: src=%s -> loc[%d] = (%.6f, %.6f, %.6f) dist=%.6f"):format(tostring(src), i, lx, ly, lz, d))
      end
      if d < nearest then nearest = d; chosenIndex = i end
    end

    -- tolerance: use radius + 0.6 (prevents float/heading tiny mismatches)
    local tolerance = (radius or 2.0) + 0.6
    if DEBUG then print(("[SHOP] attemptRob: nearest=%.6f radius=%.3f tolerance=%.3f for src=%s shop=%s chosenIndex=%d"):format(nearest, radius, tolerance, tostring(src), tostring(shopName), chosenIndex)) end

    if nearest > tolerance then
      safeNotify(src, "You are too far from the shop to start a robbery.", { type = "error", title = "Shop" })
      print(("[SHOP] attemptRob: rejected - nearest=%.6f tolerance=%.3f src=%s shop=%s"):format(nearest, tolerance, tostring(src), tostring(shopName)))
      return
    end
  else
    -- no client coords: choose index 1 by default (for shops with single location)
    chosenIndex = 1
    if DEBUG then print(("[SHOP] attemptRob: choosing default locIndex=%d for shop=%s (no client coords)"):format(chosenIndex, tostring(shopName))) end
  end

  -- Check robbable flag on shopDef
  if shopDef.robbable == false then
    safeNotify(src, "This shop cannot be robbed.", { type = "error", title = "Shop" })
    return
  end

  -- Check if chosen location already closed
  if isShopClosed(shopName, chosenIndex) then
    local ts = shopState[shopName] and shopState[shopName].closed and shopState[shopName].closed[chosenIndex] or 0
    local remaining = ts - os.time()
    safeNotify(src, ("That store location is already closed (reopens in %d seconds)."):format(math.max(0, remaining)), { type = "error", title = "Shop" })
    return
  end

  -- passed checks: mark the specific location robbed
  local cooldown = tonumber(shopDef.robCooldown) or tonumber(Config.RobCooldown or 600) or 600
  local closedUntil = os.time() + cooldown
  ensureShopStateTable(shopName)
  shopState[shopName].closed[chosenIndex] = closedUntil
  saveShopStatesToFile()
  broadcastShopState(shopName, chosenIndex)

  safeNotify(src, ("Robbery started at %s (location #%d)! The location will be closed for %d seconds."):format(tostring(shopName), chosenIndex, cooldown), { type = "success", title = "Shop" })
  print(("[SHOP] Player %d attempted robbery at shop '%s' locIndex=%d -> closedUntil=%s"):format(src, tostring(shopName), chosenIndex, tostring(closedUntil)))

  -- === POLICE NOTIFICATION ===
  do
    -- best-effort coords for the alert
    local alertCoords = nil
    if cpx and cpy and cpz then
      alertCoords = { x = cpx, y = cpy, z = cpz }
    elseif locs and locs[chosenIndex] then
      local ll = locs[chosenIndex]
      alertCoords = { x = tonumber(ll.x) or 0, y = tonumber(ll.y) or 0, z = tonumber(ll.z) or 0 }
    end

    if type(notifyPoliceViaAzFramework) == "function" then
      local ok, err = pcall(function()
        -- signature: notifyPoliceViaAzFramework(shopName, chosenIndex, coordsTable, closedUntilTs, robberSrc)
        notifyPoliceViaAzFramework(shopName, chosenIndex, alertCoords, closedUntil, src)
      end)
      if not ok then
        print(("[SHOP] notifyPoliceViaAzFramework failed: %s"):format(tostring(err)))
        -- fallback to generic broadcast below if helper failed
        TriggerClientEvent('shop:robberyAlertPolice', -1, {
          shop = shopName,
          locIndex = chosenIndex,
          coords = alertCoords,
          closedUntil = closedUntil,
          robberSrc = src
        })
        print(("[SHOP] fallback broadcast sent for shop '%s' locIndex=%d"):format(tostring(shopName), chosenIndex))
      else
        if DEBUG then print(("[SHOP] notifyPoliceViaAzFramework called for shop '%s' locIndex=%d"):format(tostring(shopName), chosenIndex)) end
      end
    else
      -- fallback: broadcast generic event to all clients (police-side should filter by job)
      TriggerClientEvent('shop:robberyAlertPolice', -1, {
        shop = shopName,
        locIndex = chosenIndex,
        coords = alertCoords,
        closedUntil = closedUntil,
        robberSrc = src
      })
      print(("[SHOP] fallback: TriggerClientEvent('shop:robberyAlertPolice', -1, ...) sent for shop '%s' locIndex=%d"):format(tostring(shopName), chosenIndex))
    end
  end
  -- === END POLICE NOTIFICATION ===

end)



-- Admin reopen command - supports reopening a specific locIndex or all locations if no index provided
RegisterCommand("shopreopen", function(source, args)
  local src = source
  local name = args[1]
  local idx = tonumber(args[2]) -- optional
  if not name then
    if src == 0 then print("Usage: shopreopen <shopName> [locationIndex]") else safeNotify(src, "Usage: /shopreopen <shopName> [locationIndex]", { type = "error", title = "Shop" }) end
    return
  end
  if idx and idx > 0 then
    ensureShopStateTable(name)
    shopState[name].closed[idx] = nil
    saveShopStatesToFile()
    broadcastShopState(name, idx)
    if src == 0 then print(("Shop %s location %d reopened (console)"):format(name, idx)) else safeNotify(src, ("Shop reopened: %s (location %d)"):format(name, idx), { type = "success", title = "Shop" }) end
  else
    -- reopen all locations
    shopState[name] = nil
    saveShopStatesToFile()
    -- broadcast nil for index 1..n based on shop locations (best-effort)
    local shopDef = findShopByName(name)
    if shopDef then
      local locs = getShopLocations(shopDef)
      if locs and #locs > 0 then
        for i=1,#locs do broadcastShopState(name, i) end
      else
        -- fallback: broadcast single nil
        broadcastShopState(name, 1)
      end
    else
      broadcastShopState(name, 1)
    end
    if src == 0 then print(("Shop %s reopened (console)"):format(name)) else safeNotify(src, ("Shop reopened: %s"):format(name), { type = "success", title = "Shop" }) end
  end
end, false)

-- Debug command to list shops (server console)
RegisterCommand("listshops", function(src)
  tryLoadShopsFile()
  if src == 0 then
    print("[SHOP] Available shops:")
    for i,s in ipairs(Shops) do print(i, s.name) end
  else
    TriggerClientEvent('chat:addMessage', src, { args = { '^2SHOP', 'Check server console for shop list.' } })
    print(("[SHOP] Player %d requested shop list:"):format(src))
    for i,s in ipairs(Shops) do print(i, s.name) end
  end
end, true)

-- Provide current states to a client (per-location mapping)
RegisterNetEvent('shop:requestStates')
AddEventHandler('shop:requestStates', function()
  local src = source
  local out = {}
  for shopName, entry in pairs(shopState) do
    if entry and entry.closed then
      local copy = {}
      for idx, ts in pairs(entry.closed) do
        if tonumber(ts) and tonumber(ts) > os.time() then
          copy[tostring(idx)] = tonumber(ts)
        end
      end
      if next(copy) ~= nil then out[shopName] = copy end
    end
  end
  TriggerClientEvent('shop:syncStates', src, out)
end)

-- Cleanup on disconnect
AddEventHandler("playerDropped", function(reason)
  local src = source
  PlayerInv[src] = nil
  PlayerW[src] = nil
  ActiveCharID[src] = nil
end)

-- When a character is selected, merge any in-memory inventory into the DB inventory
RegisterNetEvent('Az-Framework:selectCharacter')
AddEventHandler('Az-Framework:selectCharacter', function(charID)
  local src = source
  if not src or src <= 0 then return end
  ActiveCharID[src] = tostring(charID) or ActiveCharID[src]

  local discordID, _ = getPlayerKeysSync(src)
  local charIDResolved = ActiveCharID[src] or tostring(charID or "")
  if discordID == "" or charIDResolved == "" then
    print(("[inventory] selectCharacter: missing discord or char for src=%s (discord=%s char=%s)"):format(tostring(src), tostring(discordID), tostring(charIDResolved)))
    sendInv(src)
    return
  end

  local rows = MySQL.Sync.fetchAll([[
    SELECT item, count
      FROM user_inventory
     WHERE discordid = @discordid
       AND charid    = @charid
  ]], { ['@discordid'] = discordID, ['@charid'] = charIDResolved })

  local dbInv = {}
  for _, row in ipairs(rows) do dbInv[row.item] = row.count end

  local memInv = PlayerInv[src] or {}
  local merged = {}
  for k,v in pairs(dbInv) do merged[k] = v end
  for k,v in pairs(memInv) do merged[k] = (merged[k] or 0) + v end

  PlayerInv[src] = merged
  PlayerW[src] = computeWeight(merged)

  for itemKey, count in pairs(merged) do
    saveItemSlot(src, itemKey)
  end

  sendInv(src)
end)

-- Exports
exports('GetPlayerInventory', function(src)
  src = tonumber(src) or source
  return ensureInv(src)
end)

local function isAdmin(src)
  if exports['Az-Framework'] and exports['Az-Framework'].isAdmin then
    local ok, res = pcall(function() return exports['Az-Framework']:isAdmin(src) end)
    if ok then return res end
  end
  return false
end

local function openPlayerInventory(requester, target)
  requester = tonumber(requester) or 0
  target = tonumber(target) or 0
  if requester <= 0 or target <= 0 then return false, "invalid args" end
  if not GetPlayerName(target) then return false, "target offline" end
  ensureInv(target)
  local inv = ensureInv(target) or {}
  local w = computeWeight(inv) or 0.0
  TriggerClientEvent('inventory:openOther', requester, inv, w, MAX_WEIGHT, target, GetPlayerName(target))
  return true
end

exports('OpenPlayerInventory', function(requester, target)
  local ok, err = pcall(function() return openPlayerInventory(requester, target) end)
  if not ok then return false, tostring(err) end
  return true
end)

RegisterServerEvent('inventory:requestOpenOther')
AddEventHandler('inventory:requestOpenOther', function(targetId)
  local src = source
  targetId = tonumber(targetId) or 0
  if targetId <= 0 then safeNotify(src, "Invalid target ID.", { type = "error", title = "Inventory" }); return end
  if targetId == src then
    sendInv(src)
    TriggerClientEvent('inventory:openSelf', src, PlayerInv[src] or {}, PlayerW[src] or 0.0, MAX_WEIGHT)
    return
  end
  local allowed = true
  if exports['Az-Framework'] and exports['Az-Framework'].isAdmin then allowed = isAdmin(src) end
  if not allowed then safeNotify(src, "You don't have permission to view another player's inventory.", { type = "error", title = "Inventory" }); return end
  local ok, res = pcall(function() return openPlayerInventory(src, targetId) end)
  if not ok then safeNotify(src, ("Failed to open inventory: %s"):format(tostring(res)), { type = "error", title = "Inventory" }) end
end)
