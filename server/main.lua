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

-- require the shared config (safe fallback if not present)
local Config = Config or (function()
  local ok, cfg = pcall(require, "config")
  if ok and cfg then return cfg end
  return {
    robberyCooldown = 300,
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

local function notify(src, message, opts)
  if not src or not message then return end
  opts = opts or {}

  local id = opts.id or (tostring(Config.Notify.idPrefix or "az_inv_") .. tostring(src) .. "_" .. tostring(os.time()))

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

  for k, v in pairs(opts) do
    if data[k] == nil then data[k] = v end
  end

  if Config.NotifyEverything == false then return end

  if TriggerClientEvent then
    -- attempt ox_lib first
    local ok, _ = pcall(function()
      TriggerClientEvent('ox_lib:notify', src, data)
    end)
    if not ok then
      -- fallback: chat message
      TriggerClientEvent('chat:addMessage', src, { args = { '^2'..(data.title or "Notice"), tostring(message) } })
    end
  end
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

local function getPlayerKeysSync(src)
  local discordID = getDiscordFromIdentifiers(src) or ""
  local charID    = ""

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

  print(("[DEBUG] getPlayerKeysSync for src=%d → discordID=%q, charID=%q"):format(src, discordID, charID))
  return discordID, charID
end

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

function ensureInv(src)
  if not PlayerInv[src] then
    loadInv(src)
  end
  return PlayerInv[src] or {}
end

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

-- Synchronous save: DO or DONT (no retries).
local function saveItemSlot(src, itemKey)
  local inv = ensureInv(src)
  local count = inv[itemKey] or 0

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

  print(("[DEBUG] saveItemSlot DONE for src=%d item=%s newcount=%d"):format(src, itemKey, count))
end

-- Inventory refresh handler
RegisterNetEvent("inventory:refreshRequest")
AddEventHandler("inventory:refreshRequest", function()
    local src = source

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
      local msgParts = {}
      if discordID == "" then table.insert(msgParts, "Discord not found") end
      if charID == "" then table.insert(msgParts, "Character not selected") end

      local reason = ("Cannot load inventory: %s. Please link Discord or select a character."):format(table.concat(msgParts, " & "))
      notify(src, reason, { type = "error", title = "Inventory" })

      print(("[DEBUG] loadInv skipped for src=%d → missing discord or char (discord=%q, char=%q)"):format(src, discordID, charID))
      PlayerInv[src] = {}
      PlayerW[src] = 0.0
      TriggerClientEvent("inventory:refresh", src, PlayerInv[src], 0.0, MAX_WEIGHT)
      return
    end

    loadInv(src)
    sendInv(src)
end)

-- Give item command
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

-- Remove item command
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

-- Drop item
RegisterNetEvent("inventory:dropItem")
AddEventHandler("inventory:dropItem", function(itemKey, x, y, z, qty)
  local src = source
  qty = tonumber(qty) or 1
  if qty < 1 then qty = 1 end

  local now = GetGameTimer and GetGameTimer() or os.time()*1000
  if LastDropAt[src] and (now - LastDropAt[src]) < 300 then
    print(("[ANTI-SPAM] ignore rapid drop from src=%d"):format(src))
    if NOTIFY_EVERYTHING then
      notify(src, "Dropping too fast — please slow down.", { type = "warning", title = "Inventory" })
    end
    return
  end
  LastDropAt[src] = now

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

  inv[itemKey] = have - qty
  if inv[itemKey] <= 0 then inv[itemKey] = nil end

  saveItemSlot(src, itemKey)
  sendInv(src)

  local dropId = nextDropId
  nextDropId = nextDropId + 1
  Drops[dropId] = { id = dropId, item = itemKey, count = qty, coords = { x=x, y=y, z=z } }

  print(("🔶 [SERVER] Created dropId=%d item=%s count=%d by src=%d"):format(dropId, itemKey, qty, src))
  TriggerClientEvent("inventory:spawnDrop", -1, Drops[dropId])

  if NOTIFY_EVERYTHING then
    notify(src, ("Dropped %d× %s. (Drop ID: %d)"):format(qty, itemKey, dropId), { type = "inform", title = "Inventory" })
  end
end)

-- Pickup drop
RegisterNetEvent("inventory:pickupDrop")
AddEventHandler("inventory:pickupDrop", function(dropId)
  local src = source
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

  local inv = ensureInv(src)
  local addCount = tonumber(d.count) or 1
  local newW = (PlayerW[src] or computeWeight(inv)) + (Items[d.item] and (Items[d.item].weight * addCount) or 0)
  if newW > MAX_WEIGHT then
    notify(src, "You cannot carry that many items.", { type = "error", title = "Inventory" })
    return
  end

  Drops[dropId] = nil
  TriggerClientEvent("inventory:removeDrop", -1, dropId)

  inv[d.item] = (inv[d.item] or 0) + addCount
  saveItemSlot(src, d.item)
  sendInv(src)

  print(("🔶 [SERVER] Player %d picked up dropId=%d item=%s count=%d"):format(src, dropId, d.item, addCount))
  if NOTIFY_EVERYTHING then
    notify(src, ("Picked up %d× %s. (Drop ID: %d)"):format(addCount, d.item, dropId), { type = "success", title = "Inventory" })
  end
end)

-- Helper wrapper for getting player money that supports both direct return and callback-style exports
local function getPlayerMoneyWrapped(src, cb)
  cb = cb or function() end
  if not exports['Az-Framework'] or not exports['Az-Framework'].GetPlayerMoney then
    cb("GetPlayerMoney export missing", nil)
    return
  end

  local ok, res = pcall(function() return exports['Az-Framework']:GetPlayerMoney(src) end)
  if ok and res ~= nil then
    -- If the export returned a value synchronously
    cb(nil, res)
    return
  end

  -- Try callback style: GetPlayerMoney(src, function(err, money) ...)
  local ok2, err2 = pcall(function()
    exports['Az-Framework']:GetPlayerMoney(src, function(err, money)
      cb(err, money)
    end)
  end)
  if not ok and not ok2 then
    cb("GetPlayerMoney call failed (both sync and callback attempts)", nil)
  end
end

-- helper: find shop by name (Shops might be an array or map)
local function findShopByName(name)
  if not Shops then return nil end
  -- prefer map lookup
  if type(Shops[name]) == "table" then return Shops[name] end
  -- otherwise search array
  for _, s in pairs(Shops) do
    if type(s) == "table" and (s.name == name or s[1] == name) then return s end
  end
  return nil
end

-- helper: check if value exists in table (supports array/list)
local function tableContains(tbl, val)
  if not tbl then return false end
  for _, v in pairs(tbl) do
    if tostring(v) == tostring(val) then return true end
  end
  return false
end

-- helper: get player's job via Az-Framework safely
local function getPlayerJobSafe(src)
  if not exports['Az-Framework'] or not exports['Az-Framework'].getPlayerJob then
    return nil
  end
  local ok, job = pcall(function() return exports['Az-Framework']:getPlayerJob(src) end)
  if ok and job and job ~= "" then
    return tostring(job)
  end
  return nil
end

-- helper: check if player can access a shop/item based on jobs
-- shop: shop table or nil; itemName: string or nil
local function isPlayerAllowedForShopAndItem(src, shop, itemName)
  -- if no job restrictions at all, allow
  if not shop then return true end

  local playerJob = getPlayerJobSafe(src)

  -- Shop-level jobs array (restricts entire shop)
  if shop.jobs and type(shop.jobs) == "table" then
    if not playerJob then
      return false, shop.jobs -- player has no job but shop requires one
    end
    if not tableContains(shop.jobs, playerJob) then
      return false, shop.jobs
    end
  end

  -- Item-level jobs check (shop.items may be array of { name=..., price=..., jobs={...} })
  if itemName and shop.items and type(shop.items) == "table" then
    for _, it in pairs(shop.items) do
      local itName = it.name or it[1]
      if tostring(itName) == tostring(itemName) then
        if it.jobs and type(it.jobs) == "table" then
          if not playerJob then
            return false, it.jobs
          end
          if not tableContains(it.jobs, playerJob) then
            return false, it.jobs
          end
        end
        break
      end
    end
  end

  return true
end

-- Modified shop purchase handler — supports both old calls and new (shopName,item,price)
RegisterNetEvent('shop:buyItem')
AddEventHandler('shop:buyItem', function(firstArg, secondArg, thirdArg)
  local src = source

  -- determine invocation pattern:
  -- Pattern A (new): shopName, itemName, price
  -- Pattern B (old): itemName, price
  local shopName, itemName, priceRaw
  if firstArg and findShopByName(firstArg) then
    -- new pattern
    shopName = firstArg
    itemName = secondArg
    priceRaw = thirdArg
  else
    -- fallback to old pattern (no shop passed)
    shopName = nil
    itemName = firstArg
    priceRaw = secondArg
  end

  local priceNum = tonumber(priceRaw)
  if not priceNum then
    print(("[SHOP DEBUG] price parse failed for src=%s price=%s"):format(tostring(src), tostring(priceRaw)))
    notify(src, ("Invalid price provided: %s"):format(tostring(priceRaw)), { type = "error", title = "Shop" })
    return
  end

  if not Items then
    print("[SHOP DEBUG] Items table is nil!")
    notify(src, "Server error: Items table missing.", { type = "error", title = "Shop" })
    return
  end

  if not itemName or not Items[itemName] then
    print(("[SHOP DEBUG] invalid item requested: %s"):format(tostring(itemName)))
    notify(src, ("Invalid item: %s"):format(tostring(itemName)), { type = "error", title = "Shop" })
    return
  end

  -- find shop if shopName provided
  local shop = nil
  if shopName then shop = findShopByName(shopName) end

  -- check job restrictions (shop-level and item-level)
  local allowed, allowedJobs = isPlayerAllowedForShopAndItem(src, shop, itemName)
  if not allowed then
    local jobsText = "restricted"
    if type(allowedJobs) == "table" then
      jobsText = table.concat(allowedJobs, ", ")
    end
    notify(src, ("You cannot buy %s here — access limited to: %s."):format(itemName, jobsText), { type = "error", title = "Shop" })
    print(("[SHOP DEBUG] purchase blocked for src=%d item=%s shop=%s allowedJobs=%s"):format(src, tostring(itemName), tostring(shopName), tostring(jobsText)))
    return
  end

  -- Get current money (robust wrapper used earlier)
  getPlayerMoneyWrapped(src, function(err, money)
    if err then
      print(("[SHOP DEBUG] GetPlayerMoney error for src=%d: %s"):format(src, tostring(err)))
      notify(src, "Could not fetch your balance.", { type = "error", title = "Shop" })
      return
    end

    local cash = 0
    if type(money) == "table" then
      cash = tonumber(money.cash) or tonumber(money.amount) or 0
    else
      cash = tonumber(money) or 0
    end

    if cash < priceNum then
      notify(src, ("You need $%d to buy %s. You only have $%d."):format(priceNum, itemName, cash), { type = "error", title = "Shop" })
      return
    end

    -- Deduct money via Az-Framework addMoney(-price)
    local ok, err2 = pcall(function()
      if exports['Az-Framework'] and exports['Az-Framework'].addMoney then
        exports['Az-Framework']:addMoney(src, -priceNum)
      else
        error("addMoney export missing")
      end
    end)
    if not ok then
      print(("[SHOP DEBUG] addMoney (deduct) failed for src=%d: %s"):format(src, tostring(err2)))
      notify(src, "Purchase failed: could not deduct funds.", { type = "error", title = "Shop" })
      return
    end

    -- Grant the item
    local inv = ensureInv(src)
    inv[itemName] = (inv[itemName] or 0) + 1
    saveItemSlot(src, itemName)
    sendInv(src)

    local label = (Items[itemName] and Items[itemName].label) or itemName
    notify(src, ("Purchased 1× %s for $%d."):format(label, priceNum), { type = "success", title = "Shop" })
    print(("--- [SHOP DEBUG] Purchase complete for src=%d item=%s price=%d shop=%s"):format(src, itemName, priceNum, tostring(shopName)))
  end)
end)


-- Shop robbery state: shopState[name] = { closedUntil = os.time()+... }
local shopState = {}

local function broadcastShopState(shopName)
  local state = shopState[shopName]
  local closedUntil = state and state.closedUntil or 0
  TriggerClientEvent('shop:closedStatus', -1, shopName, closedUntil)
end

local function isShopClosed(shopName)
  local s = shopState[shopName]
  if not s then return false end
  return (s.closedUntil and s.closedUntil > os.time()) or false
end

-- Attempt robbery handler
RegisterNetEvent('shop:attemptRob')
AddEventHandler('shop:attemptRob', function(shopName)
  local src = source
  if not shopName then
    notify(src, "Invalid shop.", { type = "error", title = "Shop" })
    return
  end

  if isShopClosed(shopName) then
    notify(src, "That shop is currently closed due to a recent robbery.", { type = "error", title = "Shop" })
    return
  end

  -- Mark closed
  local cooldown = tonumber(Config.robberyCooldown) or 300
  local closedUntil = os.time() + cooldown
  shopState[shopName] = { closedUntil = closedUntil }
  broadcastShopState(shopName)

  -- Reward calculation (uses Shops table if present)
  local minReward = 100
  local maxReward = 500
  if Shops then
    -- support Shops as array or map
    if type(Shops) == "table" then
      -- try map by name
      if Shops[shopName] and type(Shops[shopName]) == "table" then
        minReward = Shops[shopName].robberyRewardMin or minReward
        maxReward = Shops[shopName].robberyRewardMax or maxReward
      else
        -- if Shops is array, search
        for _, s in pairs(Shops) do
          if s and (s.name == shopName or s[1] == shopName) then
            minReward = s.robberyRewardMin or minReward
            maxReward = s.robberyRewardMax or maxReward
            break
          end
        end
      end
    end
  end

  if minReward > maxReward then minReward, maxReward = maxReward, minReward end
  local reward = math.random(minReward, maxReward)

  -- Give reward using addMoney (positive)
  local ok, err = pcall(function()
    if exports['Az-Framework'] and exports['Az-Framework'].addMoney then
      exports['Az-Framework']:addMoney(src, reward)
    else
      error("addMoney export missing")
    end
  end)
  if not ok then
    print(("[SHOP] addMoney failed for robbery reward src=%d err=%s"):format(src, tostring(err)))
    notify(src, "Robbery succeeded but reward delivery failed.", { type = "error", title = "Shop" })
  else
    notify(src, ("Robbery successful! You received $%d."):format(reward), { type = "success", title = "Shop" })
  end
  -- Schedule reopen cleanup
  Citizen.CreateThread(function()
    Citizen.Wait((cooldown * 1000) + 500)
    if shopState[shopName] and shopState[shopName].closedUntil <= os.time() then
      shopState[shopName] = nil
      broadcastShopState(shopName)
    end
  end)
end)

-- Admin reopen command
RegisterCommand("shopreopen", function(source, args)
  local src = source
  local name = args[1]
  if not name then
    if src == 0 then
      print("Usage: shopreopen <shopName>")
    else
      notify(src, "Usage: /shopreopen <shopName>", { type = "error", title = "Shop" })
    end
    return
  end

  shopState[name] = nil
  broadcastShopState(name)

  if src == 0 then
    print(("Shop %s reopened (console)"):format(name))
  else
    notify(src, ("Shop reopened: %s"):format(name), { type = "success", title = "Shop" })
  end
end, false)

-- Cleanup on disconnect
AddEventHandler("playerDropped", function()
  local src = source
  PlayerInv[src] = nil
  PlayerW[src]   = nil
  ActiveCharID[src] = nil
  print(("[DEBUG] playerDropped cleaned memory for src=%d"):format(src))
end)

-- Admin menu: request discord server id
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

-- Character selected event from Az-Framework
RegisterNetEvent('Az-Framework:selectCharacter')
AddEventHandler('Az-Framework:selectCharacter', function(charID)
  local src = source
  ActiveCharID[src] = charID
  print(("[INVENTORY] Received character select for src=%d, charID=%s"):format(src, tostring(charID)))
  if NOTIFY_EVERYTHING then
    notify(src, ("Character selected: %s"):format(tostring(charID)), { type = "inform", title = "Inventory" })
  end

  loadInv(src)
  sendInv(src)
end)

-- On resource start: broadcast current shop states to clients (so new clients are aware)
AddEventHandler('onResourceStart', function(resourceName)
  if resourceName == GetCurrentResourceName() then
    for shopName, _ in pairs(shopState) do
      broadcastShopState(shopName)
    end
  end
end)

-- helper: check admin permission (uses Az-Framework.isAdmin if present)
local function isAdmin(src)
  if exports['Az-Framework'] and exports['Az-Framework'].isAdmin then
    local ok, res = pcall(function() return exports['Az-Framework']:isAdmin(src) end)
    if ok then return res end
  end
  return false
end

-- internal function that actually opens target's inventory for requester
local function openPlayerInventory(requester, target)
  requester = tonumber(requester) or 0
  target = tonumber(target) or 0
  if requester <= 0 or target <= 0 then
    print(("[inventory] openPlayerInventory invalid args requester=%s target=%s"):format(tostring(requester), tostring(target)))
    return false, "invalid args"
  end

  if not GetPlayerName(target) then
    print(("[inventory] openPlayerInventory: target %d not online"):format(target))
    return false, "target offline"
  end

  -- ensure target's inventory loaded
  ensureInv(target)
  local inv = ensureInv(target) or {}
  local w = computeWeight(inv) or 0.0

  -- send target inventory to requester client
  TriggerClientEvent('inventory:openOther', requester, inv, w, MAX_WEIGHT, target, GetPlayerName(target))
  if NOTIFY_EVERYTHING then
    notify(requester, ("Opened inventory of %s (ID %d)"):format(GetPlayerName(target) or "unknown", target), { type = "inform", title = "Inventory" })
  end

  print(("[DEBUG] openPlayerInventory: requester=%d opened target=%d items=%d weight=%.2f"):format(
    requester, target, (function() local c=0; for k,v in pairs(inv) do c=c+1 end; return c end)(), w))

  return true
end

RegisterServerEvent('inventory:requestOpenOther')
AddEventHandler('inventory:requestOpenOther', function(targetId)
  local src = source
  targetId = tonumber(targetId) or 0
  if targetId <= 0 then
    notify(src, "Invalid target ID.", { type = "error", title = "Inventory" })
    return
  end

  if targetId == src then
    -- open self (fast path) — send data and instruct client to open UI
    sendInv(src)

    -- Tell client to open their own inventory UI (not "other" view)
    TriggerClientEvent('inventory:openSelf', src, PlayerInv[src] or {}, PlayerW[src] or 0.0, MAX_WEIGHT)
    return
  end

  local allowed = true
  -- if Az-Framework has an admin check, require it
  if exports['Az-Framework'] and exports['Az-Framework'].isAdmin then
    allowed = isAdmin(src)
  end

  if not allowed then
    notify(src, "You don't have permission to view another player's inventory.", { type = "error", title = "Inventory" })
    print(("[inventory] Player %d attempted to open %d's inventory but is not allowed."):format(src, targetId))
    return
  end

  local ok, res = pcall(function() return openPlayerInventory(src, targetId) end)
  if not ok then
    notify(src, ("Failed to open inventory: %s"):format(tostring(res)), { type = "error", title = "Inventory" })
  end
end)

exports('GetPlayerInventory', function(src)
  src = tonumber(src) or source
  return ensureInv(src)
end)

exports('OpenPlayerInventory', function(requester, target)
  -- if called without args from server context, return false
  local ok, err = pcall(function() return openPlayerInventory(requester, target) end)
  if not ok then
    print(("[inventory] exports.OpenPlayerInventory pcall failed: %s"):format(tostring(err)))
    return false, tostring(err)
  end
  return true
end)