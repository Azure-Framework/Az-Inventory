print(('[Az-Inventory] server loaded (%s)'):format(GetCurrentResourceName()))






CreateThread(function()
  Wait(0)
  if not MySQL or not MySQL.Sync then
    print('^1[Az-Inventory]^7 MySQL library not found. Ensure oxmysql (or mysql-async) is installed and loaded.')
  end
end)

local MAX_WEIGHT = 120.0
local PlayerInv   = {}  
local PlayerW     = {}  
local Drops       = {}
local nextDropId  = 1
local ActiveCharID = {} 
local LastDropAt = {}
local LastPickupAt = {}
local NOTIFY_EVERYTHING = true
local PlayerMetadata = {} 
local RegisteredStashes = {}
local HookRegistry = {}
local RegisteredShops = {}
local TemporaryStashes = {}
local ConfiscatedInventories = {}

local loadPlayerMetadata
local savePlayerMetadataSlot
local ensureMetadataConsistency



local function runHooks(eventName, payload)
  for id, hook in pairs(HookRegistry) do
    if hook and hook.event == eventName and type(hook.cb) == 'function' then
      local options = hook.options or {}
      local allowed = true
      if allowed and options.itemFilter and payload and payload.itemName then
        allowed = options.itemFilter[payload.itemName] == true
      end
      if allowed and options.inventoryFilter and payload then
        allowed = false
        local fromInv = tostring(payload.fromInventory or '')
        local toInv = tostring(payload.toInventory or '')
        for _, pattern in pairs(options.inventoryFilter) do
          pattern = tostring(pattern or '')
          if pattern ~= '' and (fromInv:find(pattern) or toInv:find(pattern)) then
            allowed = true
            break
          end
        end
      end
      if allowed then
        local ok, result = pcall(hook.cb, payload)
        if not ok then
          print(('[Az-Inventory] hook %s (%s) failed: %s'):format(tostring(id), tostring(eventName), tostring(result)))
        elseif result == false then
          return false
        end
      end
    end
  end
  return true
end


Config = Config or (pcall(function() return require("config") end) and require("config") or nil) or Config or {}
Config.RobCooldown = tonumber(Config.RobCooldown or Config.robberyCooldown) or 600
Config.PersistStates = Config.PersistStates == true
Config.StateFile = Config.StateFile or "shop_states.json"
Config.RequiredWeaponItems = Config.RequiredWeaponItems or {}
Config.RequiredCops = tonumber(Config.RequiredCops or 0) or 0
Config.MaxRobDistance = tonumber(Config.MaxRobDistance or 4.0) or 4.0
Config.AntiSpam = Config.AntiSpam or { PerPlayerAttemptCooldown = 5 }
MAX_WEIGHT = tonumber(Config.MaxWeight) or MAX_WEIGHT
local DEBUG = Config.Debug == true


local shopState = {} 


local LastRobAttempt = {} 

local computeWeight
local ensureInv
local saveItemSlot
local safeNotify


CreateThread(function()
  Wait(500)
  if not MySQL or not MySQL.Sync or not MySQL.Sync.execute then return end

  local statements = {
    [[
      CREATE TABLE IF NOT EXISTS user_inventory (
        discordid VARCHAR(64) NOT NULL,
        charid VARCHAR(64) NOT NULL,
        item VARCHAR(64) NOT NULL,
        count INT NOT NULL DEFAULT 0,
        PRIMARY KEY (discordid, charid, item)
      )
    ]],
    [[
      CREATE TABLE IF NOT EXISTS vehicle_inventory (
        plate VARCHAR(16) NOT NULL,
        storage_type VARCHAR(16) NOT NULL,
        item VARCHAR(64) NOT NULL,
        count INT NOT NULL DEFAULT 0,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (plate, storage_type, item)
      )
    ]],
    [[
      CREATE TABLE IF NOT EXISTS user_inventory_metadata (
        discordid VARCHAR(64) NOT NULL,
        charid VARCHAR(64) NOT NULL,
        slot INT NOT NULL,
        item VARCHAR(64) NOT NULL,
        metadata LONGTEXT NULL,
        PRIMARY KEY (discordid, charid, slot)
      )
    ]],
    [[
      CREATE TABLE IF NOT EXISTS az_stashes (
        stash VARCHAR(128) NOT NULL,
        item VARCHAR(64) NOT NULL,
        count INT NOT NULL DEFAULT 0,
        PRIMARY KEY (stash, item)
      )
    ]]
  }

  for _, sql in ipairs(statements) do
    local ok, err = pcall(function() MySQL.Sync.execute(sql, {}) end)
    if not ok then
      print(('[Az-Inventory] failed creating table: %s'):format(tostring(err)))
    end
  end
end)

local function normalizePlate(plate)
  plate = tostring(plate or ''):upper():gsub('%s+', '')
  if plate == '' then plate = 'UNKNOWN' end
  return plate
end

local function getVehicleStorageMaxWeight(kind)
  local cfg = (Config and Config.VehicleStorage) or {}
  if kind == 'glovebox' then
    return tonumber(cfg.GloveboxMaxWeight) or 12.0
  end
  return tonumber(cfg.TrunkMaxWeight) or 75.0
end

local function loadVehicleInventory(plate, kind)
  plate = normalizePlate(plate)
  kind = tostring(kind or 'trunk')

  local rows = {}
  local ok, res = pcall(function()
    return MySQL.Sync.fetchAll([[
      SELECT item, count
        FROM vehicle_inventory
       WHERE plate = @plate
         AND storage_type = @storage_type
    ]], {
      ['@plate'] = plate,
      ['@storage_type'] = kind,
    })
  end)
  if ok and type(res) == 'table' then rows = res end

  local inv = {}
  for _, row in ipairs(rows) do
    local count = tonumber(row.count) or 0
    if row.item and count > 0 then
      inv[row.item] = count
    end
  end

  return inv
end

local function saveVehicleInventorySlot(plate, kind, itemKey, count)
  plate = normalizePlate(plate)
  kind = tostring(kind or 'trunk')
  count = tonumber(count) or 0

  if count > 0 then
    MySQL.Sync.execute([[
      INSERT INTO vehicle_inventory (plate, storage_type, item, count)
      VALUES (@plate, @storage_type, @item, @count)
      ON DUPLICATE KEY UPDATE count = @count
    ]], {
      ['@plate'] = plate,
      ['@storage_type'] = kind,
      ['@item'] = itemKey,
      ['@count'] = count,
    })
  else
    MySQL.Sync.execute([[
      DELETE FROM vehicle_inventory
       WHERE plate = @plate
         AND storage_type = @storage_type
         AND item = @item
    ]], {
      ['@plate'] = plate,
      ['@storage_type'] = kind,
      ['@item'] = itemKey,
    })
  end
end

local function sendVehicleStorageState(src, kind, plate)
  local playerInv = ensureInv(src)
  local storageInv = (kind == 'stash' and loadStashInventory(plate) or loadVehicleInventory(plate, kind))
  local playerWeight = computeWeight(playerInv)
  local storageWeight = computeWeight(storageInv)
  PlayerW[src] = playerWeight

  TriggerClientEvent('inventory:vehicleStorageData', src, {
    kind = kind,
    plate = normalizePlate(plate),
    playerItems = playerInv,
    playerWeight = playerWeight,
    playerMaxWeight = MAX_WEIGHT,
    storageItems = storageInv,
    storageWeight = storageWeight,
    storageMaxWeight = getVehicleStorageMaxWeight(kind),
  })
end



local function normalizeVectorLike(v)
  if not v then return nil end
  
  if type(v) == "table" then
    if v.x ~= nil and v.y ~= nil and v.z ~= nil then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
    if v[1] ~= nil and v[2] ~= nil and v[3] ~= nil then
      return { x = tonumber(v[1]), y = tonumber(v[2]), z = tonumber(v[3]), w = tonumber(v[4]) or 0.0 }
    end
    return nil
  end

  
  if type(v) == "userdata" then
    local ok, _ = pcall(function() return v.x end)
    if ok then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
  end

  
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
    
    if shop.coords then
      local n = normalizeVectorLike(shop.coords)
      if n then shop.coords = n end
    end

    
    if shop.ped and shop.ped.coords then
      local n = normalizeVectorLike(shop.ped.coords)
      if n then shop.ped.coords = { x = n.x, y = n.y, z = n.z, w = n.w } end
    end

    
    if shop.locations and type(shop.locations) == "table" and #shop.locations > 0 then
      local out = {}
      for j, loc in ipairs(shop.locations) do
        local n = normalizeVectorLike(loc)
        if n then
          out[#out+1] = n
        else
          
          print(("[SHOP] normalizeShopsTable: could not parse locations[%d] for shop '%s'"):format(j, tostring(shop.name)))
        end
      end
      shop.locations = out
    end

    
    if shop.radius then shop.radius = tonumber(shop.radius) or shop.radius end
  end
  
  if DEBUG then print(("[SHOP] normalizeShopsTable: normalized %d shops on server"):format(#Shops)) end
end


normalizeShopsTable()


safeNotify = function(src, msg, opts)
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


computeWeight = function(inv)
  local total = 0.0
  for item, cnt in pairs(inv) do
    local def = Items and Items[item]
    if def and def.weight then
      total = total + def.weight * cnt
    else
      
      total = total + (tonumber(cnt) or 0) * 1.0
    end
  end
  return total
end


local function loadInv(src)
  local discordID, charID = getPlayerKeysSync(src)
  if discordID == "" or charID == "" then
    
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
  loadPlayerMetadata(src)
  ensureMetadataConsistency(src)
  return inv
end

ensureInv = function(src)
  if not PlayerInv[src] then loadInv(src) end
  return PlayerInv[src] or {}
end


local function encodeJson(v)
  local ok, out = pcall(function() return json.encode(v or {}) end)
  if ok then return out end
  return '{}'
end

local function decodeJson(v)
  if type(v) == 'table' then return v end
  if type(v) ~= 'string' or v == '' then return {} end
  local ok, out = pcall(function() return json.decode(v) end)
  return (ok and type(out) == 'table') and out or {}
end

local function getPlayerSlotState(src)
  PlayerMetadata[src] = PlayerMetadata[src] or {}
  return PlayerMetadata[src]
end

loadPlayerMetadata = function(src)
  local discordID, charID = getPlayerKeysSync(src)
  local slots = {}
  if discordID == '' or charID == '' then
    PlayerMetadata[src] = slots
    return slots
  end

  local rows = {}
  local ok, res = pcall(function()
    return MySQL.Sync.fetchAll([[
      SELECT slot, item, metadata
      FROM user_inventory_metadata
      WHERE discordid = @discordid AND charid = @charid
      ORDER BY slot ASC
    ]], { ['@discordid'] = discordID, ['@charid'] = charID })
  end)
  if ok and type(res) == 'table' then rows = res end

  for _, row in ipairs(rows) do
    local slotId = tonumber(row.slot)
    if slotId and slotId > 0 then
      slots[slotId] = { item = tostring(row.item or ''), metadata = decodeJson(row.metadata) }
    end
  end

  PlayerMetadata[src] = slots
  return slots
end

savePlayerMetadataSlot = function(src, slotId)
  slotId = tonumber(slotId)
  if not slotId or slotId < 1 then return end
  local discordID, charID = getPlayerKeysSync(src)
  if discordID == '' or charID == '' then return end
  local slots = getPlayerSlotState(src)
  local entry = slots[slotId]
  if entry and entry.item then
    MySQL.Sync.execute([[
      INSERT INTO user_inventory_metadata (discordid, charid, slot, item, metadata)
      VALUES (@discordid, @charid, @slot, @item, @metadata)
      ON DUPLICATE KEY UPDATE item = @item, metadata = @metadata
    ]], {
      ['@discordid'] = discordID,
      ['@charid'] = charID,
      ['@slot'] = slotId,
      ['@item'] = entry.item,
      ['@metadata'] = encodeJson(entry.metadata or {})
    })
  else
    MySQL.Sync.execute([[
      DELETE FROM user_inventory_metadata
      WHERE discordid = @discordid AND charid = @charid AND slot = @slot
    ]], {
      ['@discordid'] = discordID,
      ['@charid'] = charID,
      ['@slot'] = slotId,
    })
  end
end

local function nextFreeSlot(src)
  local slots = getPlayerSlotState(src)
  local i = 1
  while slots[i] do i = i + 1 end
  return i
end

local function getItemCountFromSlots(src, itemName)
  local total = 0
  for _, entry in pairs(getPlayerSlotState(src)) do
    if entry.item == itemName then total = total + 1 end
  end
  return total
end

ensureMetadataConsistency = function(src)
  local inv = ensureInv(src)
  local slots = getPlayerSlotState(src)
  local expectedSingles = {}
  for itemName, count in pairs(inv) do
    local def = Items and Items[itemName] or nil
    if def and def.stack == false then
      expectedSingles[itemName] = tonumber(count) or 0
    end
  end

  local currentSingles = {}
  for slotId, entry in pairs(slots) do
    if entry and entry.item and expectedSingles[entry.item] then
      currentSingles[entry.item] = (currentSingles[entry.item] or 0) + 1
    else
      slots[slotId] = nil
      savePlayerMetadataSlot(src, slotId)
    end
  end

  for itemName, needed in pairs(expectedSingles) do
    local have = currentSingles[itemName] or 0
    while have < needed do
      local slotId = nextFreeSlot(src)
      slots[slotId] = { item = itemName, metadata = {} }
      savePlayerMetadataSlot(src, slotId)
      have = have + 1
    end
  end
end

local function buildOxSlotItems(src)
  ensureInv(src)
  if not PlayerMetadata[src] then loadPlayerMetadata(src) end
  ensureMetadataConsistency(src)

  local inv = ensureInv(src)
  local slots = getPlayerSlotState(src)
  local out = {}
  local usedStack = {}

  for slotId, entry in pairs(slots) do
    local def = Items and Items[entry.item] or {}
    out[slotId] = {
      slot = slotId,
      name = entry.item,
      label = def.label or entry.item,
      count = 1,
      weight = tonumber(def.weight) or 0,
      metadata = entry.metadata or {},
      stack = def.stack ~= false,
      description = def.description,
      close = def.close,
    }
    usedStack[entry.item] = (usedStack[entry.item] or 0) + 1
  end

  for itemName, count in pairs(inv) do
    local def = Items and Items[itemName] or {}
    if def.stack ~= false then
      local slotId = nextFreeSlot(src)
      while out[slotId] do slotId = slotId + 1 end
      out[slotId] = {
        slot = slotId,
        name = itemName,
        label = def.label or itemName,
        count = tonumber(count) or 0,
        weight = tonumber(def.weight) or 0,
        metadata = {},
        stack = true,
        description = def.description,
        close = def.close,
      }
    end
  end

  return out
end

local function findSlotForItem(src, itemName)
  local slots = buildOxSlotItems(src)
  for slotId, data in pairs(slots) do
    if data.name == itemName then return slotId, data end
  end
end

local function stashKey(name)
  return tostring(name or '')
end

local function loadStashInventory(name)
  name = stashKey(name)
  local rows = {}
  local ok, res = pcall(function()
    return MySQL.Sync.fetchAll('SELECT item, count FROM az_stashes WHERE stash = @stash', { ['@stash'] = name })
  end)
  if ok and type(res) == 'table' then rows = res end
  local inv = {}
  for _, row in ipairs(rows) do
    local count = tonumber(row.count) or 0
    if row.item and count > 0 then inv[row.item] = count end
  end
  return inv
end

local function saveStashItem(name, itemName, count)
  name = stashKey(name)
  count = tonumber(count) or 0
  if count > 0 then
    MySQL.Sync.execute([[
      INSERT INTO az_stashes (stash, item, count)
      VALUES (@stash, @item, @count)
      ON DUPLICATE KEY UPDATE count = @count
    ]], { ['@stash'] = name, ['@item'] = itemName, ['@count'] = count })
  else
    MySQL.Sync.execute('DELETE FROM az_stashes WHERE stash = @stash AND item = @item', { ['@stash'] = name, ['@item'] = itemName })
  end
end

local function sendStashState(src, stashName)
  local playerInv = ensureInv(src)
  local stashInv = loadStashInventory(stashName)
  local playerWeight = computeWeight(playerInv)
  local stashWeight = computeWeight(stashInv)
  PlayerW[src] = playerWeight
  local cfg = RegisteredStashes[stashName] or { label = stashName, slots = 20, weight = 10000 }

  TriggerClientEvent('inventory:vehicleStorageData', src, {
    kind = 'stash',
    plate = stashName,
    storageLabel = cfg.label or stashName,
    playerItems = playerInv,
    playerWeight = playerWeight,
    playerMaxWeight = MAX_WEIGHT,
    storageItems = stashInv,
    storageWeight = stashWeight,
    storageMaxWeight = tonumber(cfg.weight) or 10000,
  })
end

local function sendInv(src)
  local inv = ensureInv(src)
  local weight = computeWeight(inv)
  PlayerW[src] = weight
  TriggerClientEvent("inventory:refresh", src, inv, weight, MAX_WEIGHT)
  TriggerClientEvent('az_inventory:syncOxSlots', src, buildOxSlotItems(src))
end


RegisterNetEvent('inventory:openVehicleStorage')
AddEventHandler('inventory:openVehicleStorage', function(payload)
  local src = source
  payload = payload or {}

  if not (Config.VehicleStorage and Config.VehicleStorage.Enabled) then
    safeNotify(src, 'Vehicle storage is disabled.', { type = 'error', title = 'Inventory' })
    return
  end

  local kind = tostring(payload.kind or 'trunk')
  if kind ~= 'trunk' and kind ~= 'glovebox' then
    safeNotify(src, 'Invalid storage type.', { type = 'error', title = 'Inventory' })
    return
  end

  local plate = normalizePlate(payload.plate)
  if plate == 'UNKNOWN' then
    safeNotify(src, 'Could not read the vehicle plate.', { type = 'error', title = 'Inventory' })
    return
  end

  sendVehicleStorageState(src, kind, plate)
end)

RegisterNetEvent('inventory:transferVehicleStorage')
AddEventHandler('inventory:transferVehicleStorage', function(kind, plate, direction, itemKey, qty)
  local src = source
  kind = tostring(kind or 'trunk')
  if kind ~= 'stash' and not (Config.VehicleStorage and Config.VehicleStorage.Enabled) then return end
  direction = tostring(direction or '')
  itemKey = tostring(itemKey or '')
  qty = math.floor(tonumber(qty) or 1)
  plate = normalizePlate(plate)

  if (kind ~= 'trunk' and kind ~= 'glovebox' and kind ~= 'stash') or (direction ~= 'deposit' and direction ~= 'withdraw') then
    safeNotify(src, 'Invalid transfer request.', { type = 'error', title = 'Inventory' })
    return
  end

  if itemKey == '' or not Items or not Items[itemKey] then
    safeNotify(src, 'Invalid item.', { type = 'error', title = 'Inventory' })
    return
  end

  if qty < 1 then qty = 1 end

  local playerInv = ensureInv(src)
  local storageInv = (kind == 'stash' and loadStashInventory(plate) or loadVehicleInventory(plate, kind))
  local def = Items[itemKey]
  local itemWeight = tonumber(def.weight) or 0.0
  local storageMax = (kind == 'stash' and tonumber((RegisteredStashes[plate] or {}).weight) or getVehicleStorageMaxWeight(kind)) or 10000

  if direction == 'deposit' then
    local have = tonumber(playerInv[itemKey]) or 0
    if have < qty then
      safeNotify(src, ('You do not have %d× %s.'):format(qty, def.label or itemKey), { type = 'error', title = 'Inventory' })
      return
    end

    local newStorageWeight = computeWeight(storageInv) + (itemWeight * qty)
    if newStorageWeight > storageMax then
      safeNotify(src, 'That storage is full.', { type = 'error', title = 'Inventory' })
      return
    end

    playerInv[itemKey] = have - qty
    if playerInv[itemKey] <= 0 then playerInv[itemKey] = nil end
    storageInv[itemKey] = (storageInv[itemKey] or 0) + qty
  else
    local have = tonumber(storageInv[itemKey]) or 0
    if have < qty then
      safeNotify(src, ('There are not %d× %s in storage.'):format(qty, def.label or itemKey), { type = 'error', title = 'Inventory' })
      return
    end

    local newPlayerWeight = computeWeight(playerInv) + (itemWeight * qty)
    if newPlayerWeight > MAX_WEIGHT then
      safeNotify(src, 'You cannot carry that much.', { type = 'error', title = 'Inventory' })
      return
    end

    storageInv[itemKey] = have - qty
    if storageInv[itemKey] <= 0 then storageInv[itemKey] = nil end
    playerInv[itemKey] = (playerInv[itemKey] or 0) + qty
  end

  PlayerInv[src] = playerInv
  PlayerW[src] = computeWeight(playerInv)

  local ok1, err1 = pcall(function() saveItemSlot(src, itemKey) end)
  if not ok1 then
    print(('[Az-Inventory] saveItemSlot failed for %s: %s'):format(tostring(itemKey), tostring(err1)))
  end

  local newStorageCount = storageInv[itemKey] or 0
  local ok2, err2
  if kind == 'stash' then
    ok2, err2 = pcall(function() saveStashItem(plate, itemKey, newStorageCount) end)
  else
    ok2, err2 = pcall(function() saveVehicleInventorySlot(plate, kind, itemKey, newStorageCount) end)
  end
  if not ok2 then
    print(('[Az-Inventory] storage save failed for %s %s %s: %s'):format(tostring(plate), tostring(kind), tostring(itemKey), tostring(err2)))
  end

  if kind == 'stash' then sendStashState(src, plate) else sendVehicleStorageState(src, kind, plate) end
end)


saveItemSlot = function(src, itemKey)
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





local function isPoliceJob(job)
  
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

  
  if Config and Config.Police then
    if dbg then print("[isPoliceJob] Config.Police present. type:", type(Config.Police), "value:", (type(Config.Police) == "table" and tableToString(Config.Police) or tostring(Config.Police))) end

    local cfg = Config.Police
    local allowed = {}

    
    if type(cfg) == "string" then
      for token in cfg:gmatch("[^,]+") do
        local t = token:match("^%s*(.-)%s*$") 
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


local function getPlayerCharID(src)
  if not src then return nil end
  src = tonumber(src) or src

  
  if ActiveCharID and ActiveCharID[src] and tostring(ActiveCharID[src]) ~= "" then
    if DEBUG then
      print(("[SHOP] getPlayerCharID: returning ActiveCharID cache for src=%s -> %s"):format(tostring(src), tostring(ActiveCharID[src])))
    end
    return tostring(ActiveCharID[src])
  end

  
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

  
  if ActiveCharID and ActiveCharID[src] and tostring(ActiveCharID[src]) ~= "" then
    if DEBUG then print(("[SHOP] getPlayerCharID: falling back to ActiveCharID for src=%s -> %s"):format(tostring(src), tostring(ActiveCharID[src]))) end
    return tostring(ActiveCharID[src])
  end

  if DEBUG then print(("[SHOP] getPlayerCharID: could not resolve character for src=%s"):format(tostring(src))) end
  return nil
end


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


local function countOnlineCops()
  local cnt = 0
  local players = GetPlayers() or {}

  for _, plyId in ipairs(players) do
    local src = tonumber(plyId) or plyId

    
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

    
    local jobVal = getPlayerJobSync(src)
    if DEBUG then print(("[SHOP] countOnlineCops: getPlayerJob for src=%s -> %s"):format(tostring(src), tostring(jobVal))) end

    
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


local function notifyPoliceViaAzFramework(shopName, locIndex, coords, closedUntil, robberSrc)
  
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

    
    local char = getPlayerCharID(src)
    if not char or char == "" then
      if DEBUG then print(("[SHOP] notifyPoliceViaAzFramework: skipping src=%s - no active character"):format(tostring(src))) end
      goto continue_notify_loop
    end

    
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

  local def = nil
  if GetItemDefinition then
    local okd, resd = pcall(function() return GetItemDefinition(key) end)
    if okd and resd then def = resd end
  end
  if not def and Items then def = Items[key] end

  local shouldConsume = true
  if def and tonumber(def.consume) == 0 then
    shouldConsume = false
  end

  local slotIdForUse = nil
  if def and def.stack == false then
    slotIdForUse = findSlotForItem(src, key)
  end

  if shouldConsume then
    inv[key] = beforeCount - qty
    if inv[key] <= 0 then inv[key] = nil end
    if slotIdForUse then
      local slots = getPlayerSlotState(src)
      slots[slotIdForUse] = nil
      savePlayerMetadataSlot(src, slotIdForUse)
    end
  end

  local afterCount = inv[key] or 0
  print(("[inventory] useItem - after remove (src=%s item=%s count=%s)"):format(tostring(src), tostring(key), tostring(afterCount)))

  local ok, err = pcall(function() saveItemSlot(src, key) end)
  if not ok then
    print(("[inventory] useItem - saveItemSlot failed for src=%s item=%s err=%s"):format(tostring(src), tostring(key), tostring(err)))
  end

  PlayerW[src] = computeWeight(inv)
  TriggerClientEvent("inventory:refresh", src, inv, PlayerW[src] or 0.0, MAX_WEIGHT)
  TriggerClientEvent('az_inventory:syncOxSlots', src, buildOxSlotItems(src))

  if shouldConsume then
    safeNotify(src, ("Used %d× %s"):format(qty, key), { type = "inform", title = "Inventory" })
  else
    safeNotify(src, ("Used %s"):format((Items[key] and Items[key].label) or key), { type = "inform", title = "Inventory" })
  end

  
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





local function tryChargePlayer(src, amount)
  amount = tonumber(amount) or 0
  if amount <= 0 then return true end

  
  local ok, res = pcall(function()
    if exports['Az-Framework'] and type(exports['Az-Framework'].RemoveMoney) == 'function' then
      
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

  
  ok, res = pcall(function()
    if QBCore and QBCore.Functions and QBCore.Functions.GetPlayer then
      local player = QBCore.Functions.GetPlayer(src)
      if player and player.Functions and player.Functions.RemoveMoney then
        
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

  
  if DEBUG then print(("[SHOP] tryChargePlayer: no supported economy integration or insufficient funds for src=%s amount=%s"):format(tostring(src), tostring(amount))) end
  return false
end


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
    
    safeNotify(src, ("Item '%s' not available."):format(itemName), { type = "error", title = "Shop" })
    print(("[SHOP] buyItem: unknown item '%s' requested by src=%s"):format(tostring(itemName), tostring(src)))
    return
  end

  
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

  
  local charged = true
  if offerPrice and offerPrice > 0 then
    charged = tryChargePlayer(src, offerPrice)
    if not charged then
      
      
      
      print(("[SHOP] buyItem: could not charge src=%s amount=%s. Allowing fallback give (no integration or insufficient funds)"):format(tostring(src), tostring(offerPrice)))
    end
  end

  
  inv[itemName] = (inv[itemName] or 0) + 1
  PlayerInv[src] = inv
  PlayerW[src] = computeWeight(inv)
  saveItemSlot(src, itemName)

  
  sendInv(src)

  
  if offerPrice and offerPrice > 0 then
    safeNotify(src, ("You bought %s for $%s"):format(itemDef.label or itemName, tostring(offerPrice)), { type = "success", title = "Shop" })
  else
    safeNotify(src, ("You received %s"):format(itemDef.label or itemName), { type = "success", title = "Shop" })
  end

  print(("[SHOP] buyItem: src=%s bought %s for %s (charged=%s)"):format(tostring(src), tostring(itemName), tostring(offerPrice), tostring(charged)))
end)






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


loadShopStatesFromFile()


local function broadcastShopState(shopName, locIndex)
  local state = shopState[shopName]
  local ts = nil
  if state and state.closed and state.closed[locIndex] and state.closed[locIndex] > os.time() then
    ts = state.closed[locIndex]
  end
  TriggerClientEvent('shop:markRobbed', -1, shopName, locIndex, ts)
end


local function isShopClosed(shopName, locIndex)
  local s = shopState[shopName]
  if not s or not s.closed then return false end
  local ts = s.closed[locIndex]
  if not ts then return false end
  return ts > os.time()
end


local Shops = Shops or {}

local function tryLoadShopsFile()
  if next(Shops or {}) then return end
  local ok, res = pcall(function() return require("shops") end)
  if ok and type(res) == "table" and #res > 0 then
    Shops = res
    print("[SHOP] Loaded shops from shops.lua via require()")
  end
end


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

  
  local now = os.time()
  LastRobAttempt = LastRobAttempt or {}
  if LastRobAttempt[src] and (now - LastRobAttempt[src]) < (Config.AntiSpam and (Config.AntiSpam.PerPlayerAttemptCooldown or 5) or 5) then
    safeNotify(src, "Robbing too fast — please wait a moment.", { type = "warning", title = "Shop" })
    return
  end
  LastRobAttempt[src] = now

  
  local cops = countOnlineCops and countOnlineCops() or 0
  local required = tonumber(Config.RequiredCops or 0) or 0
  if cops < required then
    
    print(("[SHOP] attemptRob: Not enough police online for src=%s (counted=%d required=%d)"):format(tostring(src), cops, required))
    
    for _, plyId in ipairs(GetPlayers()) do
      local psrc = tonumber(plyId) or plyId
      local ok, job = pcall(function()
        
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

  
  local cpx,cpy,cpz = tonumber(px), tonumber(py), tonumber(pz)
  if cpx and cpy and cpz then
    if DEBUG then print(("[SHOP] attemptRob: client coords for src=%s -> %.6f, %.6f, %.6f"):format(tostring(src), cpx, cpy, cpz)) end
  else
    if DEBUG then print(("[SHOP] attemptRob: no/invalid client coords provided by src=%s - skipping verbose distance check"):format(tostring(src))) end
  end

  
  local radius = tonumber(shopDef.radius) or 2.0
  local locs = getShopLocations(shopDef)
  if (not locs) or (#locs == 0) then
    
    if shopDef.coords and isVectorLike(shopDef.coords) then
      local vt = toVecTable(shopDef.coords)
      if vt then locs = { vt } end
    end
  end

  
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

    
    local tolerance = (radius or 2.0) + 0.6
    if DEBUG then print(("[SHOP] attemptRob: nearest=%.6f radius=%.3f tolerance=%.3f for src=%s shop=%s chosenIndex=%d"):format(nearest, radius, tolerance, tostring(src), tostring(shopName), chosenIndex)) end

    if nearest > tolerance then
      safeNotify(src, "You are too far from the shop to start a robbery.", { type = "error", title = "Shop" })
      print(("[SHOP] attemptRob: rejected - nearest=%.6f tolerance=%.3f src=%s shop=%s"):format(nearest, tolerance, tostring(src), tostring(shopName)))
      return
    end
  else
    
    chosenIndex = 1
    if DEBUG then print(("[SHOP] attemptRob: choosing default locIndex=%d for shop=%s (no client coords)"):format(chosenIndex, tostring(shopName))) end
  end

  
  if shopDef.robbable == false then
    safeNotify(src, "This shop cannot be robbed.", { type = "error", title = "Shop" })
    return
  end

  
  if isShopClosed(shopName, chosenIndex) then
    local ts = shopState[shopName] and shopState[shopName].closed and shopState[shopName].closed[chosenIndex] or 0
    local remaining = ts - os.time()
    safeNotify(src, ("That store location is already closed (reopens in %d seconds)."):format(math.max(0, remaining)), { type = "error", title = "Shop" })
    return
  end

  
  local cooldown = tonumber(shopDef.robCooldown) or tonumber(Config.RobCooldown or 600) or 600
  local closedUntil = os.time() + cooldown
  ensureShopStateTable(shopName)
  shopState[shopName].closed[chosenIndex] = closedUntil
  saveShopStatesToFile()
  broadcastShopState(shopName, chosenIndex)

  safeNotify(src, ("Robbery started at %s (location #%d)! The location will be closed for %d seconds."):format(tostring(shopName), chosenIndex, cooldown), { type = "success", title = "Shop" })
  print(("[SHOP] Player %d attempted robbery at shop '%s' locIndex=%d -> closedUntil=%s"):format(src, tostring(shopName), chosenIndex, tostring(closedUntil)))

  
  do
    
    local alertCoords = nil
    if cpx and cpy and cpz then
      alertCoords = { x = cpx, y = cpy, z = cpz }
    elseif locs and locs[chosenIndex] then
      local ll = locs[chosenIndex]
      alertCoords = { x = tonumber(ll.x) or 0, y = tonumber(ll.y) or 0, z = tonumber(ll.z) or 0 }
    end

    if type(notifyPoliceViaAzFramework) == "function" then
      local ok, err = pcall(function()
        
        notifyPoliceViaAzFramework(shopName, chosenIndex, alertCoords, closedUntil, src)
      end)
      if not ok then
        print(("[SHOP] notifyPoliceViaAzFramework failed: %s"):format(tostring(err)))
        
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
  

end)




RegisterCommand("shopreopen", function(source, args)
  local src = source
  local name = args[1]
  local idx = tonumber(args[2]) 
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
    
    shopState[name] = nil
    saveShopStatesToFile()
    
    local shopDef = findShopByName(name)
    if shopDef then
      local locs = getShopLocations(shopDef)
      if locs and #locs > 0 then
        for i=1,#locs do broadcastShopState(name, i) end
      else
        
        broadcastShopState(name, 1)
      end
    else
      broadcastShopState(name, 1)
    end
    if src == 0 then print(("Shop %s reopened (console)"):format(name)) else safeNotify(src, ("Shop reopened: %s"):format(name), { type = "success", title = "Shop" }) end
  end
end, false)


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


AddEventHandler("playerDropped", function(reason)
  local src = source
  PlayerInv[src] = nil
  PlayerW[src] = nil
  ActiveCharID[src] = nil
end)


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



exports('Items', function(item)
  if item then return Items and Items[item] or nil end
  return Items
end)
exports('ItemList', function(item)
  if item then return Items and Items[item] or nil end
  return Items
end)
exports('GetInventoryItems', function(src)
  src = tonumber(src) or source
  return buildOxSlotItems(src)
end)
exports('Search', function(src, search, item)
  src = tonumber(src) or source
  if search == 'count' then
    local inv = ensureInv(src)
    return tonumber(inv[item] or 0) or 0
  end
  return 0
end)
exports('GetItem', function(src, item, metadata, returnsCount)
  src = tonumber(src) or source
  local inv = ensureInv(src)
  local count = tonumber(inv[item] or 0) or 0
  if returnsCount then return count end
  local def = Items and Items[item] or {}
  return { name = item, label = def.label or item, count = count, metadata = metadata or {} }
end)
exports('CanCarryItem', function(src, item, count)
  src = tonumber(src) or source
  count = tonumber(count) or 1
  local inv = ensureInv(src)
  local def = Items and Items[item] or {}
  local weight = tonumber(def.weight) or 0
  return ((computeWeight(inv) + (weight * count)) <= MAX_WEIGHT)
end)
exports('AddItem', function(src, item, count, metadata, slot)
  src = tonumber(src) or source
  count = tonumber(count) or 1
  if count < 1 then count = 1 end
  if not item or not Items or not Items[item] then return false end
  if not exports[GetCurrentResourceName()]:CanCarryItem(src, item, count) then return false end
  if runHooks('createItem', { inventoryId = src, item = { name = item }, itemName = item, metadata = metadata or {}, count = count }) == false then return false end
  local inv = ensureInv(src)
  inv[item] = (tonumber(inv[item]) or 0) + count
  if Items[item].stack == false then
    local slots = getPlayerSlotState(src)
    for i=1,count do
      local slotId = tonumber(slot) or nextFreeSlot(src)
      while slots[slotId] do slotId = slotId + 1 end
      slots[slotId] = { item = item, metadata = type(metadata) == 'table' and metadata or {} }
      savePlayerMetadataSlot(src, slotId)
    end
  end
  saveItemSlot(src, item)
  sendInv(src)
  return true
end)
exports('RemoveItem', function(src, item, count, metadata, slot)
  src = tonumber(src) or source
  count = tonumber(count) or 1
  local inv = ensureInv(src)
  if (tonumber(inv[item]) or 0) < count then return false end
  inv[item] = (tonumber(inv[item]) or 0) - count
  if inv[item] <= 0 then inv[item] = nil end
  if Items[item] and Items[item].stack == false then
    local slots = getPlayerSlotState(src)
    local removed = 0
    if slot and slots[tonumber(slot)] and slots[tonumber(slot)].item == item then
      slots[tonumber(slot)] = nil
      savePlayerMetadataSlot(src, tonumber(slot))
      removed = removed + 1
    end
    if removed < count then
      for slotId, entry in pairs(slots) do
        if removed >= count then break end
        if entry.item == item then
          slots[slotId] = nil
          savePlayerMetadataSlot(src, slotId)
          removed = removed + 1
        end
      end
    end
  end
  saveItemSlot(src, item)
  sendInv(src)
  return true
end)
exports('SetMetadata', function(src, slot, metadata)
  src = tonumber(src) or source
  slot = tonumber(slot)
  if not slot then return false end
  local slots = getPlayerSlotState(src)
  if not slots[slot] then return false end
  slots[slot].metadata = type(metadata) == 'table' and metadata or {}
  savePlayerMetadataSlot(src, slot)
  sendInv(src)
  return true
end)
exports('GetSlot', function(src, slot)
  src = tonumber(src) or source
  slot = tonumber(slot)
  local slots = buildOxSlotItems(src)
  return slot and slots[slot] or nil
end)
exports('GetSlotWithItem', function(src, item)
  src = tonumber(src) or source
  local _, data = findSlotForItem(src, item)
  return data
end)
exports('GetItemCount', function(src, item)
  src = tonumber(src) or source
  return tonumber((ensureInv(src) or {})[item] or 0) or 0
end)
exports('RegisterStash', function(name, label, slots, weight, owner)
  RegisteredStashes[stashKey(name)] = { label = label or name, slots = tonumber(slots) or 20, weight = tonumber(weight) or 10000, owner = owner }
  return true
end)
exports('registerHook', function(event, cb, options)
  local id = ('hook_%s_%s'):format(tostring(event), tostring(math.random(10000,99999)))
  HookRegistry[id] = { event = event, cb = cb, options = options }
  return id
end)
exports('removeHooks', function(id)
  if id == nil then return true end
  if type(id) == 'table' then
    for k, v in pairs(id) do
      local hookId = type(k) == 'number' and v or k
      if hookId ~= nil then HookRegistry[hookId] = nil end
    end
    return true
  end
  HookRegistry[id] = nil
  return true
end)

exports('Items', function(item)
  if item then return Items and Items[item] or nil end
  return Items
end)
exports('ItemList', function(item)
  if item then return Items and Items[item] or nil end
  return Items
end)
exports('Inventory', function(inv, owner)
  if type(inv) == 'number' then return buildOxSlotItems(inv) end
  if type(inv) == 'string' then return loadStashInventory(inv) end
  return nil
end)
exports('GetInventory', function(inv, owner)
  if type(inv) == 'number' then
    return {
      id = inv,
      label = GetPlayerName(inv) or ('Player %s'):format(inv),
      type = 'player',
      slots = tonumber(Config.MaxSlots) or 50,
      maxWeight = MAX_WEIGHT,
      weight = computeWeight(ensureInv(inv)),
      items = buildOxSlotItems(inv),
    }
  elseif type(inv) == 'string' then
    local cfg = RegisteredStashes[stashKey(inv)] or TemporaryStashes[stashKey(inv)] or { slots = 20, weight = 10000, label = tostring(inv) }
    local items = loadStashInventory(inv)
    return {
      id = stashKey(inv),
      label = cfg.label or tostring(inv),
      type = 'stash',
      slots = tonumber(cfg.slots) or 20,
      maxWeight = tonumber(cfg.weight) or 10000,
      weight = computeWeight(items),
      items = items,
    }
  end
end)
exports('GetInventoryItems', function(inv, owner)
  if type(inv) == 'number' then return buildOxSlotItems(inv) end
  if type(inv) == 'string' then
    local out, idx = {}, 1
    for itemName, count in pairs(loadStashInventory(inv)) do
      local def = Items and Items[itemName] or {}
      out[idx] = { slot = idx, name = itemName, label = def.label or itemName, count = count, weight = tonumber(def.weight) or 0, metadata = {} }
      idx = idx + 1
    end
    return out
  end
  return {}
end)
exports('GetContainerFromSlot', function(inv, slot)
  return nil
end)
exports('RemoveInventory', function(inv)
  if type(inv) == 'string' then
    inv = stashKey(inv)
    MySQL.Sync.execute('DELETE FROM az_stashes WHERE stash = @stash', { ['@stash'] = inv })
    TemporaryStashes[inv] = nil
    RegisteredStashes[inv] = nil
    return true
  end
  return false
end)
exports('UpdateVehicle', function(...) return true end)
exports('SwapSlots', function(inv, fromSlot, toSlot)
  inv = tonumber(inv) or source
  fromSlot = tonumber(fromSlot)
  toSlot = tonumber(toSlot)
  if not fromSlot or not toSlot then return false end
  local slots = getPlayerSlotState(inv)
  local payload = {
    source = inv,
    fromInventory = inv,
    toInventory = inv,
    fromType = 'player',
    toType = 'player',
    itemName = slots[fromSlot] and slots[fromSlot].item or nil,
  }
  if runHooks('swapItems', payload) == false then return false end
  slots[fromSlot], slots[toSlot] = slots[toSlot], slots[fromSlot]
  savePlayerMetadataSlot(inv, fromSlot)
  savePlayerMetadataSlot(inv, toSlot)
  sendInv(inv)
  return true
end)
exports('SetItem', function(src, item, count, metadata)
  src = tonumber(src) or source
  count = tonumber(count) or 0
  local inv = ensureInv(src)
  if count <= 0 then inv[item] = nil else inv[item] = count end
  saveItemSlot(src, item)
  sendInv(src)
  return true
end)
exports('GetCurrentWeapon', function(src)
  return nil
end)
exports('SetDurability', function(src, slot, durability)
  src = tonumber(src) or source
  slot = tonumber(slot)
  local slots = getPlayerSlotState(src)
  if not slot or not slots[slot] then return false end
  slots[slot].metadata = slots[slot].metadata or {}
  slots[slot].metadata.durability = durability
  savePlayerMetadataSlot(src, slot)
  sendInv(src)
  return true
end)
exports('SetSlotCount', function(src, slots)
  return true
end)
exports('SetMaxWeight', function(src, weight)
  if type(weight) == 'number' then MAX_WEIGHT = weight end
  sendInv(tonumber(src) or source)
  return true
end)
exports('Search', function(src, search, item, metadata)
  src = tonumber(src) or source
  if search == 'count' then
    return tonumber((ensureInv(src) or {})[item] or 0) or 0
  elseif search == 'slots' then
    return exports[GetCurrentResourceName()]:GetSlotsWithItem(src, item, metadata)
  end
  return exports[GetCurrentResourceName()]:GetInventoryItems(src)
end)
exports('GetItemSlots', function(src, item, metadata)
  src = tonumber(src) or source
  local slots = exports[GetCurrentResourceName()]:GetSlotsWithItem(src, item, metadata)
  local count = 0
  for _, slot in pairs(slots or {}) do count = count + (tonumber(slot.count) or 1) end
  return slots, count
end)
exports('CanCarryAmount', function(src, item)
  src = tonumber(src) or source
  local def = Items and Items[item] or {}
  local weight = tonumber(def.weight) or 0
  if weight <= 0 then return math.huge end
  local remaining = math.max(0, MAX_WEIGHT - computeWeight(ensureInv(src)))
  return math.floor(remaining / weight)
end)
exports('CanCarryWeight', function(src, weight)
  src = tonumber(src) or source
  weight = tonumber(weight) or 0
  return (computeWeight(ensureInv(src)) + weight) <= MAX_WEIGHT
end)
exports('CanSwapItem', function(src, firstItem, firstCount, testItem, testCount)
  src = tonumber(src) or source
  firstCount = tonumber(firstCount) or 1
  testCount = tonumber(testCount) or 1
  local firstWeight = tonumber((Items and Items[firstItem] and Items[firstItem].weight) or 0) * firstCount
  local testWeight = tonumber((Items and Items[testItem] and Items[testItem].weight) or 0) * testCount
  local current = computeWeight(ensureInv(src))
  return (current - firstWeight + testWeight) <= MAX_WEIGHT
end)
exports('CustomDrop', function(prefix, items, coords, slots, maxWeight, instance, model)
  local dropId = nextDropId
  nextDropId = nextDropId + 1
  local firstName, firstCount = nil, 1
  if type(items) == 'table' then
    for k, v in pairs(items) do
      if type(v) == 'table' and v.name then firstName, firstCount = v.name, v.count or 1 break end
      if type(k) == 'string' then firstName, firstCount = k, v break end
    end
  end
  if not firstName then firstName = prefix or 'unknown' end
  Drops[dropId] = { id = dropId, item = firstName, count = tonumber(firstCount) or 1, coords = coords or {x=0.0,y=0.0,z=0.0} }
  TriggerClientEvent('inventory:spawnDrop', -1, Drops[dropId])
  return dropId
end)
exports('CreateDropFromPlayer', function(playerId)
  playerId = tonumber(playerId)
  if not playerId then return false end
  return exports[GetCurrentResourceName()]:CustomDrop('player_drop', ensureInv(playerId), GetEntityCoords(GetPlayerPed(playerId)))
end)
exports('ConfiscateInventory', function(sourceId)
  sourceId = tonumber(sourceId)
  if not sourceId then return false end
  ConfiscatedInventories[sourceId] = { inv = ensureInv(sourceId), meta = getPlayerSlotState(sourceId) }
  PlayerInv[sourceId] = {}
  PlayerMetadata[sourceId] = {}
  sendInv(sourceId)
  TriggerClientEvent('ox_inventory:inventoryConfiscated', sourceId, 'Inventory confiscated')
  return true
end)
exports('ReturnInventory', function(sourceId)
  sourceId = tonumber(sourceId)
  local data = ConfiscatedInventories[sourceId]
  if not data then return false end
  PlayerInv[sourceId] = data.inv or {}
  PlayerMetadata[sourceId] = data.meta or {}
  ConfiscatedInventories[sourceId] = nil
  sendInv(sourceId)
  TriggerClientEvent('ox_inventory:inventoryReturned', sourceId, { label = 'Returned' })
  return true
end)
exports('ClearInventory', function(src, keep)
  src = tonumber(src) or source
  local inv = ensureInv(src)
  local keepSet = {}
  if type(keep) == 'table' then for _, item in pairs(keep) do keepSet[item] = true end end
  for itemName in pairs(inv) do
    if not keepSet[itemName] then inv[itemName] = nil end
  end
  PlayerMetadata[src] = {}
  local discordID, charID = getPlayerKeysSync(src)
  if discordID ~= '' and charID ~= '' then
    MySQL.Sync.execute('DELETE FROM user_inventory WHERE discordid = @discordid AND charid = @charid', {['@discordid']=discordID,['@charid']=charID})
    MySQL.Sync.execute('DELETE FROM user_inventory_metadata WHERE discordid = @discordid AND charid = @charid', {['@discordid']=discordID,['@charid']=charID})
    for itemName, count in pairs(inv) do saveItemSlot(src, itemName) end
  end
  sendInv(src)
  return true
end)
exports('GetEmptySlot', function(src)
  src = tonumber(src) or source
  return nextFreeSlot(src)
end)
exports('GetSlotForItem', function(src, item, metadata)
  src = tonumber(src) or source
  local slotId = findSlotForItem(src, item)
  return slotId
end)
exports('GetSlotIdWithItem', function(src, item, metadata)
  src = tonumber(src) or source
  local slotId = findSlotForItem(src, item)
  return slotId
end)
exports('GetSlotsWithItem', function(src, item, metadata)
  src = tonumber(src) or source
  local out = {}
  for _, data in pairs(buildOxSlotItems(src)) do
    if data and data.name == item then out[#out+1] = data end
  end
  return out
end)
exports('GetSlotIdsWithItem', function(src, item, metadata)
  src = tonumber(src) or source
  local out = {}
  for slotId, data in pairs(buildOxSlotItems(src)) do
    if data and data.name == item then out[#out+1] = slotId end
  end
  return out
end)
exports('CreateTemporaryStash', function(properties)
  local id = stashKey(properties and (properties.id or properties.name) or ('temp_' .. tostring(math.random(10000,99999))))
  TemporaryStashes[id] = {
    label = properties and (properties.label or properties.name) or id,
    slots = tonumber(properties and properties.slots) or 20,
    weight = tonumber(properties and properties.maxWeight or properties and properties.weight) or 10000,
    owner = properties and properties.owner,
  }
  RegisteredStashes[id] = TemporaryStashes[id]
  return id
end)
exports('InspectInventory', function(target, source)
  target = tonumber(target)
  if not target then return nil end
  return exports[GetCurrentResourceName()]:GetInventory(target)
end)
exports('RegisterShop', function(shopType, shopDetails)
  RegisteredShops[tostring(shopType)] = shopDetails
  return true
end)
exports('setPlayerInventory', function(playerId, data)
  playerId = tonumber(playerId)
  if not playerId then return false end
  PlayerInv[playerId] = {}
  PlayerMetadata[playerId] = {}
  local items = data and (data.items or data) or {}
  for slot, entry in pairs(items) do
    local itemName = entry.name or entry.item
    local count = tonumber(entry.count) or 1
    if itemName then
      PlayerInv[playerId][itemName] = (PlayerInv[playerId][itemName] or 0) + count
      if Items[itemName] and Items[itemName].stack == false then
        local slotId = tonumber(entry.slot or slot) or nextFreeSlot(playerId)
        PlayerMetadata[playerId][slotId] = { item = itemName, metadata = entry.metadata or {} }
      end
    end
  end
  for itemName in pairs(PlayerInv[playerId]) do saveItemSlot(playerId, itemName) end
  sendInv(playerId)
  TriggerClientEvent('ox_inventory:setPlayerInventory', playerId, {}, buildOxSlotItems(playerId), computeWeight(ensureInv(playerId)), playerId)
  return true
end)
exports('forceOpenInventory', function(playerId, invType, data)
  playerId = tonumber(playerId)
  if not playerId then return false end
  if invType == 'player' then
    return openPlayerInventory(playerId, tonumber(data) or 0)
  end
  TriggerClientEvent('ox_inventory:openInventory', playerId, invType, data)
  return true
end)


RegisterNetEvent('ox_inventory:usedItemInternal', function(slot)
  local src = source
  slot = tonumber(slot)
  if not slot then return end
  local slotData = exports[GetCurrentResourceName()]:GetSlot(src, slot)
  if slotData and slotData.name then
    TriggerEvent('inventory:useItem', slotData.name, 1)
  end
end)

RegisterNetEvent('ox_inventory:forceOpenInventory', function(invType, data)
  local src = source
  exports[GetCurrentResourceName()]:forceOpenInventory(src, invType, data)
end)

RegisterNetEvent('inventory:openStash', function(stashName)
  local src = source
  stashName = stashKey(stashName)
  if stashName == '' then return end
  sendStashState(src, stashName)
end)
