local MAX_WEIGHT = 120.0
local PlayerInv   = {}  -- src → { [item]=count }
local PlayerW     = {}  -- src → weight
local Drops       = {}
local nextDropId  = 1
local ActiveCharID = {} -- src → charID

-- helper: fetch discordID & charID
local function getPlayerKeys(src)
  local discordID = exports['Az-Framework']:getDiscordID(src) or ""
  local charID    = ActiveCharID[src] or "" -- <- use stored charID
  print(("[DEBUG] getPlayerKeys for src=%d → discordID=%q, charID=%q"):format(src, discordID, charID))
  return discordID, charID
end


-- Compute total carry weight
local function computeWeight(inv)
  local total = 0.0
  for item, cnt in pairs(inv) do
    local def = Items[item]
    if def and def.weight then
      total = total + def.weight * cnt
    end
  end
  return total
end

-- Load a character’s inventory from DB
local function loadInv(src)
  local discordID, charID = getPlayerKeys(src)
  if not discordID or not charID then
    PlayerInv[src] = {}
    PlayerW[src]   = 0.0
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
  return inv
end

local function saveItemSlot(src, itemKey)
  local inv = ensureInv(src)
  local count = inv[itemKey] or 0
  local discordID, charID = getPlayerKeys(src)

  -- debug
  print(("[DEBUG] saveItemSlot for src=%d item=%s count=%d → discordID=%q, charID=%q")
    :format(src, itemKey, count, discordID, charID))

  if discordID == "" or charID == "" then
    -- warn but don’t silently return
    print(("[ERROR] Cannot save inventory: missing discordID or charID for src=%d")
      :format(src))
    return
  end

  if count > 0 then
    MySQL.Async.execute([[
      INSERT INTO user_inventory (discordid,charid,item,count)
      VALUES (@discordid,@charid,@item,@count)
      ON DUPLICATE KEY UPDATE count = @count
    ]], {
      ['@discordid'] = discordID,
      ['@charid']    = charID,
      ['@item']      = itemKey,
      ['@count']     = count
    }, function(rowsChanged)
      print(("[DEBUG] upserted %d rows for %s/%s/%s")
        :format(rowsChanged or 0, discordID, charID, itemKey))
    end)
  else
    MySQL.Async.execute([[
      DELETE FROM user_inventory
       WHERE discordid = @discordid
         AND charid    = @charid
         AND item      = @item
    ]], {
      ['@discordid'] = discordID,
      ['@charid']    = charID,
      ['@item']      = itemKey
    }, function(rowsChanged)
      print(("[DEBUG] deleted %d rows for %s/%s/%s")
        :format(rowsChanged or 0, discordID, charID, itemKey))
    end)
  end
end

-- Ensure a player's inventory is loaded (from memory or DB)
function ensureInv(src)
  if not PlayerInv[src] then
    loadInv(src)
  end
  return PlayerInv[src]
end

-- Send inventory snapshot to client
local function sendInv(src)
  local inv    = ensureInv(src)
  local weight = computeWeight(inv)
  PlayerW[src] = weight
  TriggerClientEvent("inventory:refresh", src, inv, weight, MAX_WEIGHT)
end

-- Notify helper
local function notify(src, msg)
  TriggerClientEvent("inventory:notify", src, msg)
end

-- Handle UI requests for data
RegisterNetEvent("inventory:refreshRequest")
AddEventHandler("inventory:refreshRequest", function()
  sendInv(source)
end)

-- Give item: /giveitem [targetID] [itemKey] [qty]
RegisterCommand("giveitem", function(src, args)
  local target = tonumber(args[1]) or src
  local key    = args[2]
  local qty    = tonumber(args[3]) or 1
  if not Items[key] then
    return notify(src, "Invalid item: ".. tostring(key))
  end
  local inv = ensureInv(target)
  local newW = (PlayerW[target] or computeWeight(inv)) + Items[key].weight * qty
  if newW > MAX_WEIGHT then
    return notify(src, "Cannot carry that much.")
  end
  inv[key] = (inv[key] or 0) + qty
  saveItemSlot(target, key)
  sendInv(target)
  notify(src, ("Gave %d× %s to ID %d"):format(qty, Items[key].label, target))
end, false)

-- Remove item: /removeitem [itemKey] [qty]
RegisterCommand("removeitem", function(src, args)
  local key = args[1]
  local qty = tonumber(args[2]) or 1
  local inv = ensureInv(src)
  if not inv[key] or inv[key] < qty then
    return notify(src, "Not enough items.")
  end
  inv[key] = inv[key] - qty
  if inv[key] <= 0 then inv[key] = nil end
  saveItemSlot(src, key)
  sendInv(src)
  notify(src, ("Removed %d× %s"):format(qty, Items[key].label))
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
  end
  sendInv(src)
end)

-- Drop item (no coords)
RegisterNetEvent("inventory:dropItem")
AddEventHandler("inventory:dropItem", function(itemKey, x, y, z)
  local src = source
  local inv = ensureInv(src)
  local count = inv[itemKey] or 0

  print(("🔶 [SERVER] inventory:dropItem → %s (has %d) at coords"):format(itemKey, count))
  if count >= 1 then
    inv[itemKey] = count - 1
    if inv[itemKey] <= 0 then inv[itemKey] = nil end
    saveItemSlot(src, itemKey)
    sendInv(src)
  else
    print(("🔶 [SERVER] warning: player %d had none of %s"):format(src, itemKey))
  end

  -- Broadcast the drop
  local dropId = nextDropId
  nextDropId = nextDropId + 1
  Drops[dropId] = { id = dropId, item = itemKey, coords = { x=x, y=y, z=z } }
  TriggerClientEvent("inventory:spawnDrop", -1, Drops[dropId])
end)

-- Pickup dropped item
RegisterNetEvent("inventory:pickupDrop")
AddEventHandler("inventory:pickupDrop", function(dropId)
  local src = source
  local d = Drops[dropId]
  if not d then return end

  local inv = ensureInv(src)
  inv[d.item] = (inv[d.item] or 0) + 1
  saveItemSlot(src, d.item)
  sendInv(src)

  Drops[dropId] = nil
  TriggerClientEvent("inventory:removeDrop", -1, dropId)
end)

-- Shop purchase
RegisterNetEvent("shop:buyItem")
AddEventHandler("shop:buyItem", function(itemName, price)
  local src     = source
  local priceNum= tonumber(price) or 0
  local money   = exports['Az-Framework']:GetPlayerMoney(src)
  local cash    = (type(money)=="table" and tonumber(money.cash)) or tonumber(money) or 0

  if cash < priceNum then
    return notify(src, ("You need $%d to buy %s. You only have $%d."):format(priceNum, itemName, cash))
  end

  exports['Az-Framework']:deductMoney(src, priceNum)

  local inv = ensureInv(src)
  inv[itemName] = (inv[itemName] or 0) + 1
  saveItemSlot(src, itemName)
  sendInv(src)

  local label = (Items[itemName] and Items[itemName].label) or itemName
  notify(src, ("Purchased 1× %s for $%d."):format(label, priceNum))
  print(("🔵 [SERVER] shop:buyItem → %s for $%d by src=%d"):format(itemName, priceNum, src))
end)

-- Cleanup on disconnect
AddEventHandler("playerDropped", function()
  local src = source
  PlayerInv[src] = nil
  PlayerW[src]   = nil
  ActiveCharID[src] = nil
end)

RegisterNetEvent('adminmenu:requestDiscordServer')
AddEventHandler('adminmenu:requestDiscordServer', function(playerServerId)
  local src      = source
  local ok, discordId = pcall(function()
    return exports['your_resource_name']:getDiscordID(playerServerId)
  end)
  if not ok then discordId = nil end

  TriggerClientEvent('adminmenu:sendDiscordToClient', src, discordId)
end)



RegisterNetEvent('az-fw-money:selectCharacter')
AddEventHandler('az-fw-money:selectCharacter', function(charID)
  local src = source
  ActiveCharID[src] = charID
  print(("[INVENTORY] Received character select for src=%d, charID=%s"):format(src, tostring(charID)))

  loadInv(src)
  sendInv(src)
end)