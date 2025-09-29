local MAX_WEIGHT = 120.0
local PlayerInv   = {}  -- src → { [item]=count }
local PlayerW     = {}  -- src → weight
local Drops       = {}
local nextDropId  = 1
local ActiveCharID = {} -- src → charID
-- small anti-spam: last drop timestamp per player
local LastDropAt = {}
local LastPickupAt = {}

-- Toggle detailed in-game notifications for every action (set false to quiet the user)
local NOTIFY_EVERYTHING = true

-- server/main.lua (top-of-file snippet)
-- require the shared config
local Config = Config or (function() 
  -- if config was already loaded into global space via shared_scripts,
  -- it might already exist; otherwise attempt safe require
  local ok, cfg = pcall(require, "config")
  if ok and cfg then return cfg end
  -- fallback defaults if config require fails
  return {
    NotifyEverything = true,
    Notify = {
      idPrefix = "az_inv_",
      title = "Inventory",
      duration = 3000,
      showDuration = true,
      position = "top",
      type = "inform",
      style = nil,
      icon = nil,
      iconColor = nil,
      iconAnimation = nil,
      alignIcon = nil,
      sound = nil,
    }
  }
end)()

-- Notify helper using ox_lib:notify and Config.Notify defaults
local function notify(src, message, opts)
  if not src or not message then return end
  opts = opts or {}

  -- Build default id using Config.Notify.idPrefix
  local id = opts.id or (tostring(Config.Notify.idPrefix or "az_inv_") .. tostring(src) .. "_" .. tostring(os.time()))

  -- Merge per-call opts with Config.Notify defaults (opts take precedence)
  local data = {
    id = id,
    title = opts.title or Config.Notify.title,
    description = message or "",
    duration = opts.duration or Config.Notify.duration,
    showDuration = (opts.showDuration == nil) and Config.Notify.showDuration or opts.showDuration,
    position = opts.position or Config.Notify.position,
    type = opts.type or Config.Notify.type,
    style = opts.style or Config.Notify.style,
    icon = opts.icon or Config.Notify.icon,
    iconColor = opts.iconColor or Config.Notify.iconColor,
    iconAnimation = opts.iconAnimation or Config.Notify.iconAnimation,
    alignIcon = opts.alignIcon or Config.Notify.alignIcon,
    sound = opts.sound or Config.Notify.sound,
  }

  -- add any extra opts keys that don't clash
  for k, v in pairs(opts) do
    if data[k] == nil then data[k] = v end
  end

  -- if global notifications are disabled, do nothing
  if Config.NotifyEverything == false then return end

  -- Trigger ox_lib notify on the player's client
  TriggerClientEvent('ox_lib:notify', src, data)
end



local function getDiscordFromIdentifiers(src)
  local ids = GetPlayerIdentifiers(src) or {}
  for _, id in ipairs(ids) do
    if type(id) == "string" then
      local d = id:match("^discord:(%d+)$")
      if d and #d >= 17 then return d end
      -- fallback: any long numeric sequence (17+ digits)
      d = id:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d?)")
      if d and #d >= 17 then return d end
    end
  end
  return ""
end

-- Synchronous helper: get keys (discord from identifiers, char from framework or ActiveCharID)
local function getPlayerKeysSync(src)
  local discordID = getDiscordFromIdentifiers(src) or ""
  local charID    = ""

  -- Prefer Az-Framework char export if available
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    local ok, res = pcall(function() return exports['Az-Framework']:GetPlayerCharacter(src) end)
    if ok and res and res ~= "" then
      charID = tostring(res)
      ActiveCharID[src] = charID
    end
  end

  -- Fallback to locally stored ActiveCharID
  if charID == "" then
    charID = ActiveCharID[src] or ""
  end

  print(("[DEBUG] getPlayerKeysSync for src=%d → discordID=%q, charID=%q"):format(src, discordID, charID))
  return discordID, charID
end

-- Compatibility wrapper (in case other code calls getPlayerKeys)
local function getPlayerKeys(src)
  return getPlayerKeysSync(src)
end

-- Compute total carry weight
local function computeWeight(inv)
  local total = 0.0
  for item, cnt in pairs(inv) do
    local def = Items and Items[item]
    if def and def.weight then
      total = total + def.weight * cnt
    end
  end
  return total
end

-- Load a character’s inventory from DB
local function loadInv(src)
  local discordID, charID = getPlayerKeysSync(src)
  if discordID == "" or charID == "" then
    PlayerInv[src] = {}
    PlayerW[src]   = 0.0
    print(("[DEBUG] loadInv skipped for src=%d → missing discord or char (discord=%q, char=%q)"):format(src, discordID, charID))
    if NOTIFY_EVERYTHING then
      notify(src, "Inventory load skipped: missing Discord or character.", { type = "warning", title = "Inventory" })
    end
    return PlayerInv[src]
  end

  local rows = MySQL.Sync.fetchAll([[
    SELECT item, count
      FROM user_inventory
     WHERE discordid = @discordid
       AND charid    = @charid
  ]], {
    ['@discordid'] = discordID,
    ['@charid']    = charID
  })

  local inv = {}
  for _, row in ipairs(rows) do
    inv[row.item] = row.count
  end

  PlayerInv[src] = inv
  PlayerW[src]   = computeWeight(inv)
  print(("[DEBUG] loadInv loaded %d items for src=%d (discord=%s, char=%s)"):format(#rows, src, discordID, charID))
  if NOTIFY_EVERYTHING then
    notify(src, ("Loaded %d item types into inventory."):format(#rows), { type = "inform", title = "Inventory" })
  end
  return inv
end

-- Ensure a player's inventory is loaded (from memory or DB)
function ensureInv(src)
  if not PlayerInv[src] then
    loadInv(src)
  end
  return PlayerInv[src] or {}
end

-- Send inventory snapshot to client (defined after ensureInv so ensureInv is available)
local function sendInv(src)
  local inv = ensureInv(src)
  local weight = computeWeight(inv)
  PlayerW[src] = weight
  TriggerClientEvent("inventory:refresh", src, inv, weight, MAX_WEIGHT)
  print(("[DEBUG] sendInv called for src=%d (items=%d, weight=%.2f)"):format(src, (inv and (function() local n=0; for k,v in pairs(inv) do n=n+1 end; return n end)() or 0), weight))
  if NOTIFY_EVERYTHING then
    notify(src, ("Inventory updated. Weight: %.2f / %.2f"):format(weight, MAX_WEIGHT), { type = "inform", title = "Inventory" })
  end
end

-- Synchronous save: DO or DONT (no retries). Uses MySQL.Sync for immediate consistency.
local function saveItemSlot(src, itemKey)
  local inv = ensureInv(src)
  local count = inv[itemKey] or 0

  -- debug: show raw identifiers
  local ids = GetPlayerIdentifiers(src) or {}
  print(("---- RAW IDENTIFIERS for src=%d ----"):format(src))
  for i, id in ipairs(ids) do print(i, id) end
  print("---- end identifiers ----")

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

  print(("[DEBUG] saveItemSlot for src=%d BEFORE DB item=%s count=%d → discordID=%q, charID=%q")
    :format(src, itemKey, count, discordID, charID))

  if discordID == "" or charID == "" then
    print(("[ERROR] saveItemSlot SKIPPED: missing discordID or charID for src=%d (item=%s count=%d)"):format(src, itemKey, count))
    if NOTIFY_EVERYTHING then
      notify(src, "Save skipped: missing Discord or character.", { type = "warning", title = "Inventory" })
    end
    return
  end

  if count > 0 then
    -- synchronous upsert to ensure immediate consistency
    local rowsChanged = MySQL.Sync.execute([[
      INSERT INTO user_inventory (discordid,charid,item,count)
      VALUES (@discordid,@charid,@item,@count)
      ON DUPLICATE KEY UPDATE count = @count
    ]], {
      ['@discordid'] = discordID,
      ['@charid']    = charID,
      ['@item']      = itemKey,
      ['@count']     = count
    })
    print(("[DEBUG] (SYNC) upserted %s rows for %s/%s/%s (src=%d)"):format(tostring(rowsChanged or 0), discordID, charID, itemKey, src))
    if NOTIFY_EVERYTHING then
      notify(src, ("Saved %d× %s."):format(count, itemKey), { type = "inform", title = "Inventory" })
    end
  else
    local rowsChanged = MySQL.Sync.execute([[
      DELETE FROM user_inventory
       WHERE discordid = @discordid
         AND charid    = @charid
         AND item      = @item
    ]], {
      ['@discordid'] = discordID,
      ['@charid']    = charID,
      ['@item']      = itemKey
    })
    print(("[DEBUG] (SYNC) deleted %s rows for %s/%s/%s (src=%d)"):format(tostring(rowsChanged or 0), discordID, charID, itemKey, src))
    if NOTIFY_EVERYTHING then
      notify(src, ("Removed %s from your saved inventory."):format(itemKey), { type = "inform", title = "Inventory" })
    end
  end

  -- debug: confirm memory still matches DB (optional)
  print(("[DEBUG] saveItemSlot DONE for src=%d item=%s newcount=%d"):format(src, itemKey, count))
end

-- Inventory refresh handler: update charID from framework if available, then load/send
RegisterNetEvent("inventory:refreshRequest")
AddEventHandler("inventory:refreshRequest", function()
    local src = source

    -- Attempt to update ActiveCharID from Az-Framework export (synchronous)
    if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
        local ok, newCharID = pcall(function() return exports['Az-Framework']:GetPlayerCharacter(src) end)
        if ok and newCharID and newCharID ~= "" then
            ActiveCharID[src] = newCharID
            print(("[INVENTORY] Updated charID for %d → %s (on inventory open)"):format(src, tostring(newCharID)))
            if NOTIFY_EVERYTHING then
              notify(src, ("Character selected: %s"):format(tostring(newCharID)), { type = "inform", title = "Inventory" })
            end
        else
            print(("[INVENTORY] No framework charID for %d (on inventory open)"):format(src))
        end
    end

    local discordID, charID = getPlayerKeysSync(src)
    if discordID == "" or charID == "" then
      -- Inform player immediately — no retries
      local msgParts = {}
      if discordID == "" then table.insert(msgParts, "Discord not found") end
      if charID == "" then table.insert(msgParts, "Character not selected") end

      local reason = ("Cannot load inventory: %s. Please link Discord or select a character."):format(table.concat(msgParts, " & "))
      notify(src, reason, { type = "error", title = "Inventory" })

      print(("[DEBUG] loadInv skipped for src=%d → missing discord or char (discord=%q, char=%q)"):format(src, discordID, charID))
      -- still send an empty inventory so UI doesn't hang
      PlayerInv[src] = {}
      PlayerW[src] = 0.0
      TriggerClientEvent("inventory:refresh", src, PlayerInv[src], 0.0, MAX_WEIGHT)
      return
    end

    -- Normal load + send
    loadInv(src)
    sendInv(src)
end)

-- Give item: /giveitem [targetID] [itemKey] [qty]
RegisterCommand("giveitem", function(src, args)
  local target = tonumber(args[1]) or src
  local key    = args[2]
  local qty    = tonumber(args[3]) or 1
  if not Items or not Items[key] then
    notify(src, "Invalid item: ".. tostring(key), { type = "error", title = "Inventory" })
    return
  end
  local inv = ensureInv(target)
  local newW = (PlayerW[target] or computeWeight(inv)) + (Items[key].weight or 0) * qty
  if newW > MAX_WEIGHT then
    notify(src, "Cannot carry that much.", { type = "error", title = "Inventory" })
    return
  end
  inv[key] = (inv[key] or 0) + qty
  saveItemSlot(target, key)
  sendInv(target)
  notify(src, ("Gave %d× %s to ID %d"):format(qty, Items[key].label or key, target), { type = "success", title = "Inventory" })
  if target ~= src then
    notify(target, ("You received %d× %s from ID %d"):format(qty, Items[key].label or key, src), { type = "success", title = "Inventory" })
  end
end, false)

-- Remove item: /removeitem [itemKey] [qty]
RegisterCommand("removeitem", function(src, args)
  local key = args[1]
  local qty = tonumber(args[2]) or 1
  local inv = ensureInv(src)
  if not inv[key] or inv[key] < qty then
    notify(src, "Not enough items.", { type = "error", title = "Inventory" })
    return
  end
  inv[key] = inv[key] - qty
  if inv[key] <= 0 then inv[key] = nil end
  saveItemSlot(src, key)
  sendInv(src)
  notify(src, ("Removed %d× %s"):format(qty, Items[key] and Items[key].label or key), { type = "success", title = "Inventory" })
end, false)

-- Use item (consume)
RegisterNetEvent("inventory:useItem")
AddEventHandler("inventory:useItem", function(key, qty)
  local src = source
  local inv = ensureInv(src)
  qty = qty or 1
  if inv[key] and inv[key] >= qty then
    inv[key] = inv[key] - qty
    if inv[key] <= 0 then inv[key] = nil end
    saveItemSlot(src, key)
    sendInv(src)
    if NOTIFY_EVERYTHING then
      notify(src, ("Used %d× %s"):format(qty, key), { type = "inform", title = "Inventory" })
    end
  else
    notify(src, ("You don't have %d× %s to use."):format(qty, key), { type = "error", title = "Inventory" })
  end
end)

RegisterNetEvent("inventory:dropItem")
AddEventHandler("inventory:dropItem", function(itemKey, x, y, z, qty)
  local src = source
  qty = tonumber(qty) or 1
  if qty < 1 then qty = 1 end

  -- anti-spam
  local now = GetGameTimer and GetGameTimer() or os.time()*1000
  if LastDropAt[src] and (now - LastDropAt[src]) < 300 then
    print(("[ANTI-SPAM] ignore rapid drop from src=%d"):format(src))
    if NOTIFY_EVERYTHING then
      notify(src, "Dropping too fast — please slow down.", { type = "warning", title = "Inventory" })
    end
    return
  end
  LastDropAt[src] = now

  -- ensure we have keys to persist before touching PlayerInv
  local discordID, charID = getPlayerKeysSync(src)
  if discordID == "" or charID == "" then
    notify(src, "Cannot drop items: Discord or character data missing.", { type = "error", title = "Inventory" })
    print(("[ERROR] drop blocked for src=%d because discord/char missing (discord=%q, char=%q)"):format(src, discordID, charID))
    return
  end

  local inv = ensureInv(src)
  local have = inv[itemKey] or 0
  print(("🔶 [SERVER] inventory:dropItem request from src=%d → %s qty=%d (has %d) at coords"):format(src, tostring(itemKey), qty, have))

  if have < qty then
    notify(src, ("You don't have %d× %s to drop."):format(qty, tostring(itemKey)), { type = "error", title = "Inventory" })
    return
  end

  -- remove items from player's inventory (server authoritative)
  inv[itemKey] = have - qty
  if inv[itemKey] <= 0 then inv[itemKey] = nil end

  -- persist (sync) and send updated inventory
  saveItemSlot(src, itemKey)
  sendInv(src)

  -- create drop and broadcast
  local dropId = nextDropId
  nextDropId = nextDropId + 1
  Drops[dropId] = { id = dropId, item = itemKey, count = qty, coords = { x=x, y=y, z=z } }

  print(("🔶 [SERVER] Created dropId=%d item=%s count=%d by src=%d"):format(dropId, itemKey, qty, src))
  TriggerClientEvent("inventory:spawnDrop", -1, Drops[dropId])

  if NOTIFY_EVERYTHING then
    notify(src, ("Dropped %d× %s. (Drop ID: %d)"):format(qty, itemKey, dropId), { type = "inform", title = "Inventory" })
  end
end)

RegisterNetEvent("inventory:pickupDrop")
AddEventHandler("inventory:pickupDrop", function(dropId)
  local src = source
  -- anti-spam pickup
  local now = GetGameTimer and GetGameTimer() or os.time()*1000
  if LastPickupAt[src] and (now - LastPickupAt[src]) < 300 then
    print(("[ANTI-SPAM] ignore rapid pickup from src=%d"):format(src))
    if NOTIFY_EVERYTHING then
      notify(src, "Picking up too fast — please slow down.", { type = "warning", title = "Inventory" })
    end
    return
  end
  LastPickupAt[src] = now

  local d = Drops[dropId]
  if not d then
    print(("[SERVER] pickupDrop: dropId %s not found (src=%d)"):format(tostring(dropId), src))
    if NOTIFY_EVERYTHING then
      notify(src, "That drop no longer exists.", { type = "error", title = "Inventory" })
    end
    return
  end

  -- check weight before adding
  local inv = ensureInv(src)
  local addCount = tonumber(d.count) or 1
  local newW = (PlayerW[src] or computeWeight(inv)) + (Items[d.item] and (Items[d.item].weight * addCount) or 0)
  if newW > MAX_WEIGHT then
    notify(src, "You cannot carry that many items.", { type = "error", title = "Inventory" })
    return
  end

  -- remove drop immediately to prevent race
  Drops[dropId] = nil
  TriggerClientEvent("inventory:removeDrop", -1, dropId)

  -- add items to player and persist
  inv[d.item] = (inv[d.item] or 0) + addCount
  saveItemSlot(src, d.item)
  sendInv(src)

  print(("🔶 [SERVER] Player %d picked up dropId=%d item=%s count=%d"):format(src, dropId, d.item, addCount))
  if NOTIFY_EVERYTHING then
    notify(src, ("Picked up %d× %s. (Drop ID: %d)"):format(addCount, d.item, dropId), { type = "success", title = "Inventory" })
  end
end)

RegisterNetEvent("shop:buyItem")
AddEventHandler("shop:buyItem", function(itemName, price)
  local src = source
  print(("--- [SHOP DEBUG] buyItem request received from src=%s"):format(tostring(src)))
  print(("--- [SHOP DEBUG] raw params: itemName=%s, price=%s (type=%s)"):format(tostring(itemName), tostring(price), type(price)))

  local priceNum = tonumber(price)
  if not priceNum then
    print(("[SHOP DEBUG] priceNum parse failed for price=%s"):format(tostring(price)))
    notify(src, ("Invalid price provided: %s"):format(tostring(price)), { type = "error", title = "Shop" })
    return
  end
  print(("[SHOP DEBUG] parsed priceNum=%d"):format(priceNum))

  if not Items then
    print("[SHOP DEBUG] Items table is nil!")
    notify(src, "Server error: Items table missing.", { type = "error", title = "Shop" })
    return
  end

  if not Items[itemName] then
    print(("[SHOP DEBUG] invalid item requested: %s"):format(tostring(itemName)))
    notify(src, ("Invalid item: %s"):format(tostring(itemName)), { type = "error", title = "Shop" })
    return
  end

  print(("[SHOP DEBUG] Item exists. Label=%s, weight=%s"):format(tostring(Items[itemName].label or "nil"), tostring(Items[itemName].weight or "nil")))

  -- check money system export
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerMoney then
    print(("[SHOP DEBUG] Calling exports['Az-Framework']:GetPlayerMoney for src=%d"):format(src))
    local ok, _err = pcall(function()
      exports['Az-Framework']:GetPlayerMoney(src, function(err, money)
        -- callback entry
        print(("[SHOP DEBUG] GetPlayerMoney callback fired for src=%d err=%s money=%s"):format(src, tostring(err), tostring(money)))

        if err then
          print(("[SHOP DEBUG] GetPlayerMoney returned error for src=%d: %s"):format(src, tostring(err)))
          notify(src, ("Could not fetch money: %s"):format(tostring(err)), { type = "error", title = "Shop" })
          return
        end

        -- try to coerce money into a numeric cash amount
        local cash = 0
        if type(money) == "table" then
          cash = tonumber(money.cash) or tonumber(money.amount) or 0
          print(("[SHOP DEBUG] money table -> cash=%s (fields: cash=%s, amount=%s)"):format(tostring(cash), tostring(money.cash), tostring(money.amount)))
        else
          cash = tonumber(money) or 0
          print(("[SHOP DEBUG] money scalar -> cash=%s"):format(tostring(cash)))
        end

        if cash < priceNum then
          print(("--- [SHOP DEBUG] NOT ENOUGH CASH: src=%d has %d needs %d"):format(src, cash, priceNum))
          notify(src, ("You need $%d to buy %s. You only have $%d."):format(priceNum, itemName, cash), { type = "error", title = "Shop" })
          return
        end

        print(("--- [SHOP DEBUG] Enough cash for src=%d (cash=%d). Attempting to deduct %d"):format(src, cash, priceNum))
        -- deduct money (wrap in pcall in case deductMoney errors)
        local deductOk, deductErr = pcall(function()
          if exports['Az-Framework'] and exports['Az-Framework'].deductMoney then
            exports['Az-Framework']:deductMoney(src, priceNum)
          elseif exports['Az-Framework'] and exports['Az-Framework'].RemoveMoney then
            exports['Az-Framework']:RemoveMoney(src, priceNum)
          else
            error("deductMoney export missing")
          end
        end)

        if not deductOk then
          print(("[SHOP DEBUG] deductMoney failed for src=%d: %s"):format(src, tostring(deductErr)))
          notify(src, ("Failed to deduct money: %s"):format(tostring(deductErr)), { type = "error", title = "Shop" })
          return
        end

        print(("--- [SHOP DEBUG] Money deducted for src=%d. Granting item %s"):format(src, itemName))
        local inv = ensureInv(src)
        inv[itemName] = (inv[itemName] or 0) + 1

        -- persist and send
        saveItemSlot(src, itemName)
        sendInv(src)

        local label = (Items[itemName] and Items[itemName].label) or itemName
        notify(src, ("Purchased 1× %s for $%d."):format(label, priceNum), { type = "success", title = "Shop" })
        print(("--- [SHOP DEBUG] Purchase complete for src=%d item=%s price=%d"):format(src, itemName, priceNum))
      end)
    end)
    if not ok then
      print(("[SHOP DEBUG] pcall(GetPlayerMoney) error for src=%d"):format(src))
      notify(src, "Purchase failed: internal money fetch error.", { type = "error", title = "Shop" })
    end
  else
    print(("[SHOP DEBUG] Az-Framework:GetPlayerMoney export missing on server for src=%d"):format(src))
    notify(src, "Purchase disabled: money system unavailable.", { type = "error", title = "Shop" })
  end
end)

-- Cleanup on disconnect
AddEventHandler("playerDropped", function()
  local src = source
  PlayerInv[src] = nil
  PlayerW[src]   = nil
  ActiveCharID[src] = nil -- cleanup
  print(("[DEBUG] playerDropped cleaned memory for src=%d"):format(src))
end)

-- Admin menu: request discord server id (uses identifiers directly)
RegisterNetEvent('adminmenu:requestDiscordServer')
AddEventHandler('adminmenu:requestDiscordServer', function(playerServerId)
  local src = source
  local discordId = ""

  if type(playerServerId) == "number" then
    discordId = getDiscordFromIdentifiers(playerServerId) or ""
  end

  TriggerClientEvent('adminmenu:sendDiscordToClient', src, discordId)
  if NOTIFY_EVERYTHING then
    notify(src, ("Resolved Discord ID for player %s: %s"):format(tostring(playerServerId), tostring(discordId)), { type = "inform", title = "Admin" })
  end
end)

RegisterNetEvent('Az-Framework:selectCharacter')
AddEventHandler('Az-Framework:selectCharacter', function(charID)
  local src = source
  ActiveCharID[src] = charID -- <- store selected charID
  print(("[INVENTORY] Received character select for src=%d, charID=%s"):format(src, tostring(charID)))
  if NOTIFY_EVERYTHING then
    notify(src, ("Character selected: %s"):format(tostring(charID)), { type = "inform", title = "Inventory" })
  end

  loadInv(src)
  sendInv(src)
end)

