-- client.lua (inventory client; NUI handling, shop logic, client exports)
-- Includes improved ROB detection and a giveWeapon handler
-- Client updated to handle per-location shop state (fixes closing all locations when one is robbed)
-- Fix: Make the "closeUI" NUI callback actually close the SHOP UI when it's open (ESC from NUI)

local Items     = Items or {}
local Shops     = Shops or {}

local worldDrops     = {}
local open           = false
local inventory      = {}
local currentWeight  = 0.0
local maxWeight      = 0.0
-- CLIENT: listen for police-only robbery alert and show blip + lib.notify
-- CLIENT: listen for police-only robbery alert and show blip + lib.notify
local activeRobberyBlips = activeRobberyBlips or {}
-- Config fallback
Config = Config or {}
Config.Control = Config.Control or {}
Config.Control.ToggleInventory = tonumber(Config.Control.ToggleInventory) or 289 -- F2 default
Config.RobCooldown = Config.RobCooldown or 600
local DEBUG = Config.Debug or false

local openKey = Config.Control.ToggleInventory

-- shopStates: shopName -> { [locIndex] = closedUntil }
local shopStates = {}

local isShopOpen   = false
local currentShop  = nil -- { shop = shopTable, loc = vector3, locIndex = n }
local viewingOther     = false
local viewingOwnerId   = nil
local viewingOwnerName = nil

local shopBlips = {}    -- list of blip ids (per-location)
local spawnedPeds = {}  -- list of ped entities (per-location)


local function isVectorLike(v)
  if not v then return false end
  local t = type(v)
  if t == "table" then
    if (v.x ~= nil and v.y ~= nil and v.z ~= nil) then return true end
    if (v[1] ~= nil and v[2] ~= nil and v[3] ~= nil) then return true end
    return false
  end

  -- userdata / vector3 / vector4 etc: try reading fields safely
  if t == "userdata" then
    local ok, res = pcall(function() return v.x ~= nil and v.y ~= nil and v.z ~= nil end)
    if ok and res then return true end
  end

  -- final fallback: parse numbers only *after* the first '(' to avoid capturing the '3' in "vector3"
  local s = tostring(v)
  if type(s) == "string" then
    local startAt = s:find("%(")
    if startAt then s = s:sub(startAt + 1) end
    local found = 0
    for _ in s:gmatch("([%-]?%d+%.?%d*)") do found = found + 1 end
    if found >= 3 then return true end
  end

  return false
end

local function toVecTable(v)
  if not v then return nil end
  local t = type(v)

  -- table form: { x=..., y=..., z=... } or array-style { x,y,z, [w] }
  if t == "table" then
    if v.x ~= nil and v.y ~= nil and v.z ~= nil then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
    if v[1] ~= nil and v[2] ~= nil and v[3] ~= nil then
      return { x = tonumber(v[1]), y = tonumber(v[2]), z = tonumber(v[3]), w = tonumber(v[4]) or 0.0 }
    end
    return nil
  end

  -- userdata/vector3: try reading fields in a protected call
  local ok, _ = pcall(function() return v.x end)
  if ok then
    return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
  end

  -- final fallback: parse numbers from tostring AFTER the first '(' to avoid "vector3" prefix
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

-- DEBUG helper for safe serialization
local function safeSerialize(tbl)
  if not tbl then return "nil" end
  local ok, j = pcall(function() return json.encode(tbl) end)
  if ok and j then return j end
  -- fallback crude
  local parts = {}
  if type(tbl) == "table" then
    for k,v in pairs(tbl) do
      table.insert(parts, tostring(k).."="..tostring(v))
    end
    return "{"..table.concat(parts,",").."}"
  end
  return tostring(tbl)
end

RegisterNetEvent('shop:robberyAlertPolice', function(data)
  -- data: { shop, locIndex, coords = vector3 or {x,y,z}, closedUntil, robberSrc }
  if DEBUG then
    print("[shop:robberyAlertPolice] received event. raw data:", safeSerialize(data))
  end

  -- defensive: ensure data exists
  data = data or {}
  local src = data.robberSrc
  local coords = data.coords or data.pos or data.position

  -- normalize coords to vector3 if table-like
  if type(coords) == "table" and coords.x and coords.y and coords.z then
    coords = vector3(coords.x, coords.y, coords.z)
  else
    -- if coords is a vector-like userdata it's okay; else attempt to coerce
    if not isVectorLike(coords) then
      -- fallback: try building from provided loc in case server sent shop.locations[locIndex]
      if data.loc and type(data.loc) == "table" and data.loc.x and data.loc.y and data.loc.z then
        coords = vector3(data.loc.x, data.loc.y, data.loc.z)
      else
        -- attempt to use shop location if available
        if data.shop and type(data.shop) == "table" and data.locIndex then
          local locs = data.shop.locations
          local li = tonumber(data.locIndex) or 1
          local candidate = locs and (locs[li] or locs[1])
          if candidate and isVectorLike(candidate) then
            local vt = toVecTable(candidate)
            if vt then coords = vector3(vt.x, vt.y, vt.z) end
          end
        end
      end
    end
  end

  if not coords or not (coords.x and coords.y and coords.z) then
    if DEBUG then print("[shop:robberyAlertPolice] no valid coords available; aborting blip/notify creation. data:", safeSerialize(data)) end
    -- still attempt to call Az-Framework notify (some systems may handle server-side)
  end

  -- create blip if possible
  local blip = nil
  if coords and coords.x and coords.y and coords.z then
    blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 161)         -- robbery / crime-like icon (change if you want)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 1.0)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(("Robbery: %s"):format(tostring(data.shop or "Unknown")))
    EndTextCommandSetBlipName(blip)

    table.insert(activeRobberyBlips, blip)
  end

  -- notify using lib.notify if available, otherwise fallback to simple chat message
  local notif_msg = ("Robbery reported at %s"):format(tostring(data.shop or "unknown"))
  if lib and lib.notify then
    if DEBUG then print("[shop:robberyAlertPolice] using lib.notify ->", notif_msg) end
    lib.notify({
      title = "Dispatch",
      description = notif_msg,
      type = "warning",
      position = "top"
    })
  else
    if DEBUG then print("[shop:robberyAlertPolice] lib.notify unavailable, using chat:addMessage ->", notif_msg) end
    TriggerEvent('chat:addMessage', { args = { '^1DISPATCH', notif_msg } })
  end

  -- Attempt to call Az-Framework notification helper (various possible export/event names)
  local function tryAzNotifyCall()
    local ok, res

    -- 1) exports['Az-Framework']:notifyPoliceViaAzFramework(shopName, coordsTable, robberSrc)
    if exports and exports['Az-Framework'] and type(exports['Az-Framework'].notifyPoliceViaAzFramework) == 'function' then
      if DEBUG then print("[shop:robberyAlertPolice] calling exports['Az-Framework']:notifyPoliceViaAzFramework") end
      ok, res = pcall(function()
        exports['Az-Framework']:notifyPoliceViaAzFramework({
          shop = data.shop,
          coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil,
          robberSrc = src,
          locIndex = data.locIndex
        })
      end)
      if ok then if DEBUG then print("[shop:robberyAlertPolice] exports['Az-Framework'] notify call succeeded") end else print("[shop:robberyAlertPolice] exports['Az-Framework'] notify call error:", tostring(res)) end
      return
    end

    -- 2) exports['az-framework'] (different casing)
    if exports and exports['az-framework'] and type(exports['az-framework'].notifyPoliceViaAzFramework) == 'function' then
      if DEBUG then print("[shop:robberyAlertPolice] calling exports['az-framework']:notifyPoliceViaAzFramework") end
      ok, res = pcall(function()
        exports['az-framework']:notifyPoliceViaAzFramework({
          shop = data.shop,
          coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil,
          robberSrc = src,
          locIndex = data.locIndex
        })
      end)
      if ok then if DEBUG then print("[shop:robberyAlertPolice] exports['az-framework'] notify call succeeded") end else print("[shop:robberyAlertPolice] exports['az-framework'] notify call error:", tostring(res)) end
      return
    end

    -- 3) global event fallback (some frameworks use TriggerEvent)
    if DEBUG then print("[shop:robberyAlertPolice] attempting TriggerEvent('notifyPoliceViaAzFramework', ...)") end
    ok, res = pcall(function()
      TriggerEvent('notifyPoliceViaAzFramework', {
        shop = data.shop,
        coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil,
        robberSrc = src,
        locIndex = data.locIndex
      })
    end)
    if ok then
      if DEBUG then print("[shop:robberyAlertPolice] TriggerEvent('notifyPoliceViaAzFramework') executed (no error)") end
      return
    else
      if DEBUG then print("[shop:robberyAlertPolice] TriggerEvent('notifyPoliceViaAzFramework') error:", tostring(res)) end
    end

    -- 4) direct global function if present
    if type(notifyPoliceViaAzFramework) == 'function' then
      if DEBUG then print("[shop:robberyAlertPolice] calling global notifyPoliceViaAzFramework()") end
      ok, res = pcall(function()
        notifyPoliceViaAzFramework({
          shop = data.shop,
          coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil,
          robberSrc = src,
          locIndex = data.locIndex
        })
      end)
      if ok then if DEBUG then print("[shop:robberyAlertPolice] global notify call succeeded") end else print("[shop:robberyAlertPolice] global notify call error:", tostring(res)) end
      return
    end

    -- nothing found
    if DEBUG then print("[shop:robberyAlertPolice] no Az-Framework notify export/event/function found on client") end
  end

  -- run the attempt (pcall wrappers inside)
  tryAzNotifyCall()

  -- remove blip after a timeout (seconds). Default now 30s (or set Config.BlipDuration)
  local removeAfter = tonumber(Config and Config.BlipDuration) or 30
  if not removeAfter or removeAfter <= 0 then removeAfter = 30 end

  CreateThread(function()
    Wait(removeAfter * 1000)
    if blip and DoesBlipExist(blip) then
      RemoveBlip(blip)
    end
    -- remove from table
    for i = #activeRobberyBlips, 1, -1 do
      if activeRobberyBlips[i] == blip then table.remove(activeRobberyBlips, i) end
    end
  end)
end)

-- optional: handle generic broadcast too (e.g., other resources)
RegisterNetEvent('shop:robberyAlert', function(data)
  -- do nothing here or show a small local notification for all players
  -- e.g. show a quiet notifdddication for civs
  if lib and lib.notify then
    lib.notify({
      title = "Alert",
      description = ("Robbery reported near %s"):format(tostring(data.shop or "unknown")),
      type = "info",
      position = "top"
    })
  end
end)

-- Client handler: give weapon when server instructs
RegisterNetEvent('inventory:giveWeapon')
AddEventHandler('inventory:giveWeapon', function(weaponName, ammo)
  print(("[inventory-client] giveWeapon received -> name=%s ammo=%s"):format(tostring(weaponName), tostring(ammo)))
  if not weaponName then return end
  local ped = PlayerPedId()

  local hash = nil
  if type(weaponName) == "string" then
    hash = GetHashKey(weaponName)
  else
    hash = tonumber(weaponName)
  end
  if not hash then
    print("[inventory-client] giveWeapon -> invalid hash")
    return
  end

  local ok, err = pcall(function()
    if not HasPedGotWeapon(ped, hash, false) then
      GiveWeaponToPed(ped, hash, tonumber(ammo) or 0, false, true)
      print(("[inventory-client] GiveWeaponToPed -> given %s with %s ammo"):format(tostring(weaponName), tostring(ammo)))
    else
      if tonumber(ammo) and tonumber(ammo) > 0 then
        AddAmmoToPed(ped, hash, tonumber(ammo))
        print(("[inventory-client] AddAmmoToPed -> added %s ammo to %s"):format(tostring(ammo), tostring(weaponName)))
      else
        print(("[inventory-client] Player already has %s; no ammo to add"):format(tostring(weaponName)))
      end
    end
  end)
  if not ok then print(("[inventory-client] giveWeapon handler error: %s"):format(tostring(err))) end
end)


-- Helper: get array of location vector tables for a shop
local function getShopLocations(shop)
  if not shop then return {} end

  if shop.locations and type(shop.locations) == "table" and #shop.locations > 0 then
    local out = {}
    for i, loc in ipairs(shop.locations) do
      if isVectorLike(loc) then
        local vt = toVecTable(loc)
        if vt then table.insert(out, vt) else print(("[SHOP DEBUG] invalid locations[%d] for shop '%s'"):format(i, tostring(shop.name))) end
      else
        print(("[SHOP DEBUG] locations[%d] is not vector-like for shop '%s'"):format(i, tostring(shop.name)))
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

-- Helper: get array of ped coords (vector4) for a shop.ped
local function getShopPedLocations(shop)
  if not shop or not shop.ped then return {} end
  local p = shop.ped
  if p.coords and type(p.coords) == "table" then
    if #p.coords > 0 and isVectorLike(p.coords[1]) then
      local out = {}
      for i, loc in ipairs(p.coords) do
        local vt = toVecTable(loc)
        if vt then
          vt.h = tonumber(loc.w) or tonumber(loc[4]) or 0.0
          table.insert(out, vt)
        end
      end
      return out
    else
      local vt = toVecTable(p.coords)
      if vt then vt.h = tonumber(p.coords.w) or tonumber(p.coords[4]) or 0.0 end
      if vt then return { vt } end
    end
  end
  return {}
end

-- Model loader (defensive)
local function LoadModel(hash)
  if not HasModelLoaded(hash) then
    RequestModel(hash)
    local tick = 0
    while not HasModelLoaded(hash) and tick < 200 do Citizen.Wait(10); tick = tick + 1 end
    if not HasModelLoaded(hash) then
      print(("[SHOP DEBUG] Failed to load model %s after timeout"):format(tostring(hash)))
      return false
    end
  end
  return true
end

-- Spawn peds & blips per-location (defensive)
Citizen.CreateThread(function()
  local shopCount = 0
  local totalLocs = 0
  for _, shop in ipairs(Shops) do
    shopCount = shopCount + 1
    local locs = getShopLocations(shop)
    totalLocs = totalLocs + #locs

    if shop.blip and #locs > 0 then
      local ok,err = pcall(function()
        for _, loc in ipairs(locs) do
          local b = shop.blip
          if loc.x and loc.y and loc.z then
            local blip = AddBlipForCoord(loc.x, loc.y, loc.z)
            SetBlipSprite(blip, b.sprite or 52)
            SetBlipDisplay(blip, 4)
            SetBlipScale(blip, b.scale or 0.8)
            SetBlipColour(blip, b.color or 2)
            SetBlipAsShortRange(blip, true)
            if b.text then
              BeginTextCommandSetBlipName("STRING")
              AddTextComponentString(b.text)
              EndTextCommandSetBlipName(blip)
            end
            shopBlips[#shopBlips+1] = blip
          else
            print(("[SHOP DEBUG] blip location malformed for shop '%s'"):format(tostring(shop.name)))
          end
        end
      end)
      if not ok then print(("[SHOP DEBUG] error creating blips for shop '%s': %s"):format(tostring(shop.name), tostring(err))) end
    end

    local pedLocs = getShopPedLocations(shop)
    if shop.ped and #pedLocs > 0 then
      local ok,err = pcall(function()
        local m = shop.ped.model
        local hash = type(m) == "string" and GetHashKey(m) or m
        if not LoadModel(hash) then return end
        for _, pc in ipairs(pedLocs) do
          if pc.x and pc.y and pc.z then
            local ped = CreatePed(4, hash, pc.x, pc.y, pc.z - 1.0, pc.h or 0.0, false, true)
            if shop.ped.freeze      then FreezeEntityPosition(ped, true) end
            if shop.ped.invincible  then SetEntityInvincible(ped, true) end
            if shop.ped.blockEvents then SetBlockingOfNonTemporaryEvents(ped, true) end
            spawnedPeds[#spawnedPeds+1] = ped
          else
            print(("[SHOP DEBUG] ped location malformed for shop '%s'"):format(tostring(shop.name)))
          end
        end
      end)
      if not ok then print(("[SHOP DEBUG] error spawning peds for shop '%s': %s"):format(tostring(shop.name), tostring(err))) end
    end
  end

  print(("--- [SHOP DEBUG] client started. Shops found: %d. Total locations: %d ---"):format(#Shops, totalLocs))
  if #Shops == 0 then
    print("[SHOP DEBUG] Shops table empty or not loaded. Ensure shops.lua is present and included in fxmanifest.lua.")
  end
end)

AddEventHandler('onResourceStop', function(resName)
  if resName == GetCurrentResourceName() then
    for _, ped in ipairs(spawnedPeds) do
      if DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    for _, blip in ipairs(shopBlips) do
      RemoveBlip(blip)
    end
  end
end)

-- Small helpers: shallow copy / enrich UI
local function shallowCopy(t)
  if not t then return nil end
  local copy = {}
  for k,v in pairs(t) do copy[k] = v end
  return copy
end

local function enrichShopForUI(shop)
  if not shop then return shop end
  local copy = shallowCopy(shop)
  if shop.items and type(shop.items) == "table" then
    copy.items = {}
    for i, it in ipairs(shop.items) do
      local itcopy = shallowCopy(it)
      local key = it.name or it.item or it[1]
      if key and Items and Items[key] then
        local def = Items[key]
        itcopy.imageUrl = itcopy.imageUrl or def.imageUrl or def.image
        itcopy.image    = itcopy.image or def.image
        itcopy.label    = itcopy.label or def.label
        itcopy._defAvailable = true
      else
        itcopy._defAvailable = false
      end
      copy.items[#copy.items+1] = itcopy
    end
  end
  return copy
end

local function buildDefs()
  local safe = {}
  for name, d in pairs(Items) do
    safe[name] = {
      label    = d.label,
      usetime  = d.usetime,
      cancel   = d.cancel,
      buttons  = {},
      category = d.category or "misc",
      imageUrl = d.imageUrl,
      image    = d.image,
    }
    if d.buttons then
      for _, btn in ipairs(d.buttons) do
        local key = btn.label:lower():gsub("%s+","_")
        safe[name].buttons[#safe[name].buttons + 1] = {
          label     = btn.label,
          actionKey = key
        }
        btn._actionKey = key
      end
    end
  end
  return safe
end

local function pushUI(action, meta)
  meta = meta or {}
  SendNUIMessage({
    action    = action,
    items     = inventory,
    defs      = buildDefs(),
    playerId  = GetPlayerServerId(PlayerId()),
    weight    = currentWeight,
    maxWeight = maxWeight,
    meta      = meta
  })
end

-- core UI/callback handlers
RegisterNUICallback('buyItem', function(data, cb)
  if viewingOther then
    ShowNotification("Cannot buy items while viewing another player's inventory.")
    return cb({ success = false, reason = "viewing_other" })
  end
  TriggerServerEvent('shop:buyItem', data.name, data.price)
  TriggerServerEvent('inventory:refreshRequest')
  SetNuiFocus(false, false)
  SendNUIMessage({ action = 'hideShop' })
  isShopOpen = false
  cb({ success = true })
end)

-- FIXED: closeUI now closes the shop if open, otherwise falls back to hiding inventory UI.
RegisterNUICallback('closeUI', function(_, cb)
  -- If the shop UI is visible, hide it (this fixes ESC while inside the shop NUI)
  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
    -- ensure the NUI focus is cleared
    SetNuiFocus(false, false)
  else
    -- fallback to existing inventory hide behavior
    pushUI('hide')
    SetNuiFocus(false, false)
    open = false
    viewingOther = false
    viewingOwnerId = nil
    viewingOwnerName = nil
    currentShop = nil
  end
  cb({})
end)

RegisterNUICallback('close', function(_, cb)
  pushUI('hide'); SetNuiFocus(false,false); open = false
  viewingOther = false; viewingOwnerId = nil; viewingOwnerName = nil
  cb('ok')
end)

-- NEW: useItem handler called from the NUI (client side)
RegisterNUICallback('useItem', function(data, cb)
  if viewingOther then
    ShowNotification("Cannot use items while viewing another player's inventory.")
    return cb('ok')
  end

  local def = Items[data.item]
  if not def then
    return cb('ok')
  end

  -- Defensive: coerce consume to number and ensure at least 1
  local amount = tonumber(def.consume) or 1
  if amount < 1 then amount = 1 end

  -- helper to actually perform the "use" (server events + UI close/refresh)
  local function doUse()
    if DEBUG then
      print(("[inventory-client] useItem -> item=%s amount=%s"):format(tostring(data.item), tostring(amount)))
    end

    TriggerServerEvent('inventory:useItem', data.item, amount)
    TriggerServerEvent('inventory:refreshRequest')

    if def.close ~= false then
      pushUI('hide')
      SetNuiFocus(false, false)
      open = false
    end
  end

  -- If the item has a usetime, show progress bar and only perform use when finished
  if def.usetime and type(def.usetime) == 'number' then
    if def.close ~= false then
      pushUI('hide')
      SetNuiFocus(false, false)
      open = false
    end

    local finished = lib.progressBar({
      duration = def.usetime,
      label = def.label or "Using item",
      useWhileDead = def.useWhileDead or false,
      allowRagdoll = def.allowRagdoll,
      allowSwimming = def.allowSwimming,
      allowCuffed = def.allowCuffed,
      allowFalling = def.allowFalling,
      canCancel = def.cancel == true,
      anim = def.anim,
      prop = def.prop,
      disable = def.disable or {},
    })

    if finished then
      doUse()
    else
      ShowNotification("Action cancelled.")
    end

  else
    if def.anim then
      RequestAnimDict(def.anim.dict)
      while not HasAnimDictLoaded(def.anim.dict) do Wait(10) end
      TaskPlayAnim(PlayerPedId(), def.anim.dict, def.anim.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
    end

    doUse()
  end

  cb('ok')
end)

-- client receives a generic call to run a client export
RegisterNetEvent('inventory:callClientExport', function(exportSpec, itemName, amount, def)
  local resourceName, funcName
  if type(exportSpec) == 'string' then
    resourceName, funcName = exportSpec:match("^([^:]+):(.+)$")
  elseif type(exportSpec) == 'table' then
    resourceName, funcName = exportSpec.resource, exportSpec.func
  end

  if not resourceName or not funcName then
    print("inventory:callClientExport - invalid exportSpec", json.encode(exportSpec))
    return
  end

  local ok, res = pcall(function()
    if exports[resourceName] and exports[resourceName][funcName] then
      return exports[resourceName][funcName](itemName, amount, def)
    elseif exports[resourceName] and type(exports[resourceName][funcName]) == 'function' then
      return exports[resourceName][funcName](itemName, amount, def)
    else
      if exports[resourceName] and exports[resourceName][funcName] then
        return exports[resourceName][funcName](itemName, amount, def)
      end
    end
  end)

  if not ok then
    print(("inventory:callClientExport - error calling %s:%s -> %s"):format(tostring(resourceName), tostring(funcName), tostring(res)))
  end
end)

-- Example: apply server-sent status changes
RegisterNetEvent('inventory:statusApply', function(statusTable)
  for k, v in pairs(statusTable or {}) do
    print(("inventory:statusApply -> %s = %s"):format(tostring(k), tostring(v)))
  end
end)

RegisterNUICallback('dropItem', function(data, cb)
  if viewingOther then ShowNotification("Cannot drop items while viewing another player's inventory."); return cb('ok') end
  if not data.item then return cb('ok') end
  local qty = tonumber(data.qty) or 1
  local ped = PlayerPedId()
  local x,y,z = table.unpack(GetEntityCoords(ped))
  TriggerServerEvent('inventory:dropItem', data.item, x, y, z, qty)
  if inventory[data.item] then
    inventory[data.item] = inventory[data.item] - qty
    if inventory[data.item] <= 0 then inventory[data.item] = nil end
    pushUI('updateItems')
  end
  cb('ok')
end)

RegisterNUICallback('buttonAction', function(data, cb)
  local def = Items[data.slot]
  if def and def.buttons then
    for _, btn in ipairs(def.buttons) do
      if btn._actionKey == data.actionKey then btn.action(data.slot); break end
    end
  end
  cb('ok')
end)

RegisterNUICallback('close', function(_, cb)
  pushUI('hide'); SetNuiFocus(false,false); open = false
  viewingOther = false; viewingOwnerId=nil; viewingOwnerName=nil
  cb('ok')
end)

RegisterNetEvent('inventory:refresh')
AddEventHandler('inventory:refresh', function(inv, w, mw)
  inventory     = inv or {}
  currentWeight = w or 0.0
  maxWeight     = mw or maxWeight
  if open then pushUI('updateItems') end
end)

local function ShowNotification(text)
  SetNotificationTextEntry("STRING"); AddTextComponentString(text); DrawNotification(false,false)
end

local function isHoldingAndAiming(ped)
  local weapon = GetSelectedPedWeapon(ped)
  if weapon == GetHashKey("WEAPON_UNARMED") then return false end
  if IsPlayerFreeAiming(PlayerId()) or IsPlayerTargettingAnything(PlayerId()) then return true end
  return false
end
-- local at top of client file (near other locals)
local serverTimeOffset = 0        -- serverEpochSeconds - math.floor(GetGameTimer()/1000)
local function currentTimeSeconds()
  -- Prefer real os.time if available (some client envs have it)
  if type(os) == "table" and type(os.time) == "function" then
    return os.time()
  end
  -- Fallback: use client game timer + offset mapped to server epoch
  local ms = GetGameTimer() or 0
  return math.floor(ms / 1000 + (serverTimeOffset or 0))
end


-- Shop state handlers from server (backwards compatible)
RegisterNetEvent('shop:markRobbed')
AddEventHandler('shop:markRobbed', function(shopName, a, b)
  if not shopName then return end

  -- If server sent old style: (shopName, closedUntil) where b == nil and a is number
  if b == nil and type(a) == 'number' then
    local closedUntil = tonumber(a)
    shopStates[shopName] = shopStates[shopName] or {}
    shopStates[shopName][1] = closedUntil

    -- If client doesn't have os.time, attempt to set serverTimeOffset so comparisons work later
    if (type(os) ~= "table" or type(os.time) ~= "function") and closedUntil and closedUntil > 0 then
      serverTimeOffset = closedUntil - math.floor((GetGameTimer() or 0) / 1000)
      if DEBUG then print(("[SHOP CLIENT] mapped serverTimeOffset -> %s (closedUntil=%s)"):format(tostring(serverTimeOffset), tostring(closedUntil))) end
    end

    -- if current shop is this and locIndex == 1, close UI
    if currentShop and currentShop.shop and currentShop.shop.name == shopName and currentShop.locIndex == 1 then
      ShowNotification("~r~This shop was just robbed and its doors are closed.")
      if isShopOpen then SendNUIMessage({ action = 'hideShop' }); isShopOpen = false; currentShop = nil; SetNuiFocus(false,false) end
    end
    return
  end

  -- New style: (shopName, locIndex, closedUntil)
  local locIndex = tonumber(a) or 1
  local closedUntil = tonumber(b) or nil

  -- If client doesn't have os.time() available, compute serverTimeOffset using this closedUntil
  if (type(os) ~= "table" or type(os.time) ~= "function") and closedUntil and closedUntil > 0 then
    serverTimeOffset = closedUntil - math.floor((GetGameTimer() or 0) / 1000)
    if DEBUG then print(("[SHOP CLIENT] mapped serverTimeOffset -> %s (closedUntil=%s)"):format(tostring(serverTimeOffset), tostring(closedUntil))) end
  end

  shopStates[shopName] = shopStates[shopName] or {}
  if closedUntil and closedUntil > currentTimeSeconds() then
    shopStates[shopName][locIndex] = closedUntil
  else
    shopStates[shopName][locIndex] = nil
  end

  if currentShop and currentShop.shop and currentShop.shop.name == shopName and currentShop.locIndex == locIndex then
    if closedUntil and closedUntil > currentTimeSeconds() then
      ShowNotification("~r~This shop was just robbed and its doors are closed.")
      if isShopOpen then SendNUIMessage({ action = 'hideShop' }); isShopOpen = false; currentShop = nil; SetNuiFocus(false,false) end
    else
      -- reopened: optionally notify
    end
  end
end)

RegisterNetEvent('shop:syncStates')
AddEventHandler('shop:syncStates', function(states)
  -- states expected: { shopName = { [locIndexStr] = closedUntil, ... }, ... }
  if type(states) ~= 'table' then return end
  for shopName, v in pairs(states) do
    if type(v) == 'number' then
      -- backwards compat: single number means locIndex 1
      shopStates[shopName] = shopStates[shopName] or {}
      if v and v > os.time() then shopStates[shopName][1] = v else shopStates[shopName][1] = nil end
    elseif type(v) == 'table' then
      shopStates[shopName] = shopStates[shopName] or {}
      for idxStr, ts in pairs(v) do
        local idx = tonumber(idxStr) or tonumber(idxStr)
        if idx then
          if tonumber(ts) and tonumber(ts) > os.time() then
            shopStates[shopName][idx] = tonumber(ts)
          else
            shopStates[shopName][idx] = nil
          end
        end
      end
    end
  end
end)

AddEventHandler('onClientResourceStart', function(res)
  if GetCurrentResourceName() == res then
    TriggerServerEvent('shop:requestStates')
    TriggerServerEvent('inventory:refreshRequest')
  end
end)

-- Main proximity loop (supports multiple locations)
Citizen.CreateThread(function()
  while true do
    Wait(0)
    local playerPed = PlayerPedId()
    local pos = GetEntityCoords(playerPed)
    local foundAny = false

    for _, shop in ipairs(Shops) do
      local locs = getShopLocations(shop)
      local radius = tonumber(shop.radius) or 2.0
      for locIndex, loc in ipairs(locs) do
        if loc and loc.x and loc.y and loc.z then
          local dist = #(pos - vector3(loc.x, loc.y, loc.z))
          if dist < radius then
            foundAny = true
            local closedEntry = shopStates[shop.name] or {}
            local closedUntil = closedEntry[locIndex]
            local isRobbable = (shop.robbable ~= false)

            -- draw marker + text
            if closedUntil and closedUntil > os.time() then
              DrawMarker(2, loc.x, loc.y, loc.z + 0.3, 0,0,0,0,0,0,0.4,0.4,0.4,255,50,50,100,false,true)
              local remaining = closedUntil - os.time()
              DrawText3D(loc.x, loc.y, loc.z + 0.6, ('~r~Closed (robbed) - %02dm %02ds'):format(math.floor(remaining/60), remaining % 60))
            else
              DrawMarker(2, loc.x, loc.y, loc.z + 0.3, 0,0,0,0,0,0,0.4,0.4,0.4,0,255,100,100,false,true)
              if isRobbable then
                DrawText3D(loc.x, loc.y, loc.z + 0.6, ('[~g~E~w~] Open Shop    [~r~H~w~] Rob Shop'))
              else
                DrawText3D(loc.x, loc.y, loc.z + 0.6, ('[~g~E~w~] Open Shop'))
              end
            end

            -- OPEN (E)
            if not isShopOpen and IsControlJustReleased(0, 38) then
              local closedEntry = shopStates[shop.name] or {}
              local closedUntil = closedEntry[locIndex]
              if closedUntil and closedUntil > os.time() then
                local remaining = closedUntil - os.time()
                ShowNotification(('This shop location is closed due to a recent robbery. Reopens in %dm %ds'):format(math.floor(remaining/60), remaining % 60))
              else
                if open then pushUI('hide'); SetNuiFocus(false,false); open=false; viewingOther=false; viewingOwnerId=nil; viewingOwnerName=nil end
                currentShop = { shop = shop, loc = loc, locIndex = locIndex }
                local enriched = enrichShopForUI(shop)
                SendNUIMessage({ action = 'showShop', shop = enriched, defs = buildDefs() })
                SetNuiFocus(true, true)
                isShopOpen = true
              end
            end

            -- ROB (H) — improved detection + use same dist/radius and send coords to server
            if IsControlJustPressed(0, 74) then
              if DEBUG then
                print(("[inventory-client] Rob key pressed near shop '%s' (dist=%s radius=%s)"):format(tostring(shop.name), tostring(dist), tostring(radius)))
              end

              if not isRobbable then
                ShowNotification("~r~This shop cannot be robbed.")
              else
                local closedEntry = shopStates[shop.name] or {}
                local closedUntil = closedEntry[locIndex]
                if closedUntil and closedUntil > os.time() then
                  local remaining = closedUntil - os.time()
                  ShowNotification(('Shop is closed. Reopens in %dm %02ds'):format(math.floor(remaining/60), remaining % 60))
                else
                  -- use the already computed dist/radius (consistency with E/open)
                  if not dist or not radius then
                    if DEBUG then print("[inventory-client] Rob blocked: missing dist/radius") end
                    ShowNotification("Cannot start robbery right now.")
                  else
                    -- aiming checks
                    local holdingAim = false
                    local pedWeapon = GetSelectedPedWeapon(playerPed)
                    local isUnarmed = (pedWeapon == GetHashKey("WEAPON_UNARMED"))
                    local freeAiming = IsPlayerFreeAiming(PlayerId())
                    local targetting = IsPlayerTargettingAnything(PlayerId())

                    if DEBUG then
                      print(("[inventory-client] isHoldingAndAiming check -> weaponHash=%s isUnarmed=%s freeAiming=%s targetting=%s"):format(tostring(pedWeapon), tostring(isUnarmed), tostring(freeAiming), tostring(targetting)))
                    end

                    if not isUnarmed and (freeAiming or targetting or IsControlPressed(0, 24)) then
                      holdingAim = true
                    end

                    if not holdingAim then
                      ShowNotification("~r~You must be holding and aiming a firearm to rob the shop.")
                      if DEBUG then print("[inventory-client] Rob blocked: player not holding/aiming a weapon") end
                    else
                      if dist > radius then
                        if DEBUG then print(("[inventory-client] Rob blocked: too far from shop (dist=%s radius=%s)"):format(tostring(dist), tostring(radius))) end
                        ShowNotification("You are too far away to start a robbery.")
                      else
                        -- send player coords so server can validate and so server can pick the exact locIndex
                        local pedPos = GetEntityCoords(playerPed)
                        if DEBUG then print(("[inventory-client] Triggering shop:attemptRob for '%s' (pos=%s,%s,%s)"):format(tostring(shop.name), tostring(pedPos.x), tostring(pedPos.y), tostring(pedPos.z))) end
                        TriggerServerEvent('shop:attemptRob', shop.name, pedPos.x, pedPos.y, pedPos.z)
                      end
                    end
                  end
                end
              end
            end


            -- break after first matching location so we don't open multiple UIs
            break
          end
        end
      end
    end

    if isShopOpen and not foundAny then
      SendNUIMessage({ action = 'hideShop' })
      if open then pushUI('hide'); open=false; viewingOther=false; viewingOwnerId=nil; viewingOwnerName=nil end
      SetNuiFocus(false,false)
      isShopOpen = false
      currentShop = nil
    end
  end
end)

-- ESC/back closes UI
Citizen.CreateThread(function()
  while true do
    Wait(0)
    if isShopOpen or open then
      if IsControlJustReleased(0, 322) or IsControlJustReleased(0, 200) then
        if isShopOpen then SendNUIMessage({ action = 'hideShop' }); isShopOpen = false; currentShop = nil end
        if open then pushUI('hide'); viewingOther=false; viewingOwnerId=nil; viewingOwnerName=nil; open=false end
        SetNuiFocus(false,false)
      end
    end
  end
end)

-- Toggle inventory key
Citizen.CreateThread(function()
  while true do
    Wait(0)
    if IsControlJustPressed(0, openKey) then
      open = not open
      SetNuiFocus(open, open)
      if open then pushUI('show'); TriggerServerEvent('inventory:refreshRequest') else pushUI('hide') end
    end
  end
end)

-- world drops
RegisterNetEvent('inventory:spawnDrop')
AddEventHandler('inventory:spawnDrop', function(drop)
  local x,y,z = drop.coords.x, drop.coords.y, drop.coords.z
  local modelName = 'prop_med_bag_01b'
  local modelHash = GetHashKey(modelName)
  RequestModel(modelHash)
  while not HasModelLoaded(modelHash) do Wait(10) end
  local obj = CreateObject(modelHash, x, y, z + 1.0, true, true, false)
  NetworkRegisterEntityAsNetworked(obj)
  worldDrops[drop.id] = ObjToNet(obj)
end)

RegisterNetEvent('inventory:removeDrop')
AddEventHandler('inventory:removeDrop', function(dropId)
  local netId = worldDrops[dropId]
  if netId then
    local obj = NetToObj(netId)
    if DoesEntityExist(obj) then DeleteObject(obj) end
    worldDrops[dropId] = nil
  end
end)

Citizen.CreateThread(function()
  while true do
    Wait(0)
    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    for dropId, netId in pairs(worldDrops) do
      local obj = NetToObj(netId)
      if DoesEntityExist(obj) then
        local coords = GetEntityCoords(obj)
        if #(pcoords - coords) < 1.5 then
          DrawText3D(coords.x, coords.y, coords.z + 0.3, '[~g~E~w~] Pick up')
          if IsControlJustReleased(0, 38) then
            TriggerServerEvent('inventory:pickupDrop', dropId)
            TriggerServerEvent('inventory:refreshRequest')
          end
        end
      end
    end
  end
end)

-- DrawText3D
function DrawText3D(x, y, z, text, scale)
  scale = scale or 0.35
  SetTextScale(scale, scale)
  SetTextFont(4)
  SetTextProportional(1)
  SetTextColour(255,255,255,215)
  SetTextCentre(true)
  SetTextEntry('STRING')
  AddTextComponentString(text)
  SetDrawOrigin(x,y,z,0)
  DrawText(0.0,0.0)
  ClearDrawOrigin()
end
