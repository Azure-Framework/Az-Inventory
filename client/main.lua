-- client.lua (Az-Inventory)
-- Inventory client; NUI handling, shop logic, world drops, ox-style keymapping/commands.
-- FIX: F2 opening then instantly closing was caused by BOTH KeyMapping AND Control-index fallback firing.
-- This version uses KeyMapping by default and only uses control-index fallback if Config.Control.UseKeyMapping = false

local RESOURCE = GetCurrentResourceName()

local Items = Items or {}
local Shops = Shops or {}

local worldDrops = {}
local open = false
local inventory = {}
local currentWeight = 0.0
local maxWeight = 0.0

local activeRobberyBlips = activeRobberyBlips or {}

-- -----------------------------
-- Config (defensive defaults)
-- -----------------------------
Config = Config or {}
Config.Debug = Config.Debug or false

Config.Control = Config.Control or {}
Config.Control.UseKeyMapping = (Config.Control.UseKeyMapping ~= false) -- default true
Config.Control.DefaultKey = Config.Control.DefaultKey or 'F2'
Config.Control.ToggleInventory = tonumber(Config.Control.ToggleInventory) or 289 -- only used if UseKeyMapping=false

Config.RobCooldown = Config.RobCooldown or 600
Config.BlipDuration = tonumber(Config.BlipDuration) or 30

local DEBUG = Config.Debug == true

-- shopStates: shopName -> { [locIndex] = closedUntilEpochSeconds }
local shopStates = {}

local isShopOpen = false
local currentShop = nil -- { shop=shopTable, loc=vecTable, locIndex=n }

local viewingOther = false
local viewingOwnerId = nil
local viewingOwnerName = nil

local shopBlips = {}
local spawnedPeds = {}

-- -----------------------------
-- Helpers
-- -----------------------------
local jsonEncode = (json and json.encode) or EncodeJson

local function dprint(...)
  if not DEBUG then return end
  local t = {}
  for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end
  print(("^3[%s]^7 %s"):format(RESOURCE, table.concat(t, " ")))
end

local function ShowNotification(text)
  SetNotificationTextEntry("STRING")
  AddTextComponentString(text)
  DrawNotification(false, false)
end

-- time handling (robbery cooldown)
local serverTimeOffset = 0 -- serverEpochSeconds - floor(GetGameTimer()/1000)

local function currentTimeSeconds()
  if type(os) == "table" and type(os.time) == "function" then
    return os.time()
  end
  local ms = GetGameTimer() or 0
  return math.floor(ms / 1000 + (serverTimeOffset or 0))
end

local function safeSerialize(tbl)
  if not tbl then return "nil" end
  local ok, j = pcall(function() return jsonEncode(tbl) end)
  if ok and j then return j end
  if type(tbl) == "table" then
    local parts = {}
    for k, v in pairs(tbl) do parts[#parts+1] = tostring(k) .. "=" .. tostring(v) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return tostring(tbl)
end

local function isVectorLike(v)
  if not v then return false end
  local t = type(v)

  if t == "table" then
    if v.x ~= nil and v.y ~= nil and v.z ~= nil then return true end
    if v[1] ~= nil and v[2] ~= nil and v[3] ~= nil then return true end
    return false
  end

  if t == "userdata" then
    local ok, res = pcall(function() return v.x ~= nil and v.y ~= nil and v.z ~= nil end)
    if ok and res then return true end
  end

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

  if t == "table" then
    if v.x ~= nil and v.y ~= nil and v.z ~= nil then
      return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
    end
    if v[1] ~= nil and v[2] ~= nil and v[3] ~= nil then
      return { x = tonumber(v[1]), y = tonumber(v[2]), z = tonumber(v[3]), w = tonumber(v[4]) or 0.0 }
    end
    return nil
  end

  local ok = pcall(function() return v.x end)
  if ok then
    return { x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z), w = tonumber(v.w) or 0.0 }
  end

  local s = tostring(v)
  local startAt = s:find("%(")
  if startAt then s = s:sub(startAt + 1) end
  local nums = {}
  for num in s:gmatch("([%-]?%d+%.?%d*)") do nums[#nums+1] = tonumber(num) end
  if #nums >= 3 then
    return { x = nums[1], y = nums[2], z = nums[3], w = nums[4] or 0.0 }
  end

  return nil
end

local function shallowCopy(t)
  if not t then return nil end
  local copy = {}
  for k, v in pairs(t) do copy[k] = v end
  return copy
end

local function enrichShopForUI(shop)
  if not shop then return shop end
  local copy = shallowCopy(shop)

  if shop.items and type(shop.items) == "table" then
    copy.items = {}
    for _, it in ipairs(shop.items) do
      local itcopy = shallowCopy(it)
      local key = it.name or it.item or it[1]
      if key and Items and Items[key] then
        local def = Items[key]
        itcopy.imageUrl = itcopy.imageUrl or def.imageUrl or def.image
        itcopy.image = itcopy.image or def.image
        itcopy.label = itcopy.label or def.label
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
      weaponName = d.weaponName,
      consume = d.consume,
      close = d.close,
      anim = d.anim,
      prop = d.prop,
      disable = d.disable,
      useWhileDead = d.useWhileDead,
      allowRagdoll = d.allowRagdoll,
      allowSwimming = d.allowSwimming,
      allowCuffed = d.allowCuffed,
      allowFalling = d.allowFalling,
    }

    if d.buttons then
      for _, btn in ipairs(d.buttons) do
        local key = tostring(btn.label or ""):lower():gsub("%s+", "_")
        safe[name].buttons[#safe[name].buttons + 1] = { label = btn.label, actionKey = key }
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

-- -----------------------------
-- Shop helpers
-- -----------------------------
local function getShopLocations(shop)
  if not shop then return {} end

  if shop.locations and type(shop.locations) == "table" and #shop.locations > 0 then
    local out = {}
    for i, loc in ipairs(shop.locations) do
      if isVectorLike(loc) then
        local vt = toVecTable(loc)
        if vt then
          out[#out+1] = vt
        else
          print(("[SHOP DEBUG] invalid locations[%d] for shop '%s'"):format(i, tostring(shop.name)))
        end
      else
        print(("[SHOP DEBUG] locations[%d] not vector-like for shop '%s'"):format(i, tostring(shop.name)))
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

local function getShopPedLocations(shop)
  if not shop or not shop.ped then return {} end
  local p = shop.ped
  if p.coords and type(p.coords) == "table" then
    if #p.coords > 0 and isVectorLike(p.coords[1]) then
      local out = {}
      for _, loc in ipairs(p.coords) do
        local vt = toVecTable(loc)
        if vt then
          vt.h = tonumber(loc.w) or tonumber(loc[4]) or 0.0
          out[#out+1] = vt
        end
      end
      return out
    else
      local vt = toVecTable(p.coords)
      if vt then
        vt.h = tonumber(p.coords.w) or tonumber(p.coords[4]) or 0.0
        return { vt }
      end
    end
  end
  return {}
end

local function LoadModel(hash)
  if not HasModelLoaded(hash) then
    RequestModel(hash)
    local tick = 0
    while not HasModelLoaded(hash) and tick < 200 do
      Wait(10)
      tick = tick + 1
    end
    if not HasModelLoaded(hash) then
      print(("[SHOP DEBUG] Failed to load model %s after timeout"):format(tostring(hash)))
      return false
    end
  end
  return true
end

-- -----------------------------
-- Startup
-- -----------------------------
print(('[Az-Inventory] client loaded (%s)'):format(RESOURCE))

CreateThread(function()
  local totalLocs = 0

  for _, shop in ipairs(Shops) do
    local locs = getShopLocations(shop)
    totalLocs = totalLocs + #locs

    -- Blips per-location
    if shop.blip and #locs > 0 then
      local ok, err = pcall(function()
        for _, loc in ipairs(locs) do
          if loc.x and loc.y and loc.z then
            local b = shop.blip
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
          end
        end
      end)
      if not ok then
        print(("[SHOP DEBUG] error creating blips for shop '%s': %s"):format(tostring(shop.name), tostring(err)))
      end
    end

    -- Peds per-location
    local pedLocs = getShopPedLocations(shop)
    if shop.ped and #pedLocs > 0 then
      local ok, err = pcall(function()
        local m = shop.ped.model
        local hash = type(m) == "string" and GetHashKey(m) or m
        if not LoadModel(hash) then return end

        for _, pc in ipairs(pedLocs) do
          if pc.x and pc.y and pc.z then
            local ped = CreatePed(4, hash, pc.x, pc.y, pc.z - 1.0, pc.h or 0.0, false, true)
            if shop.ped.freeze then FreezeEntityPosition(ped, true) end
            if shop.ped.invincible then SetEntityInvincible(ped, true) end
            if shop.ped.blockEvents then SetBlockingOfNonTemporaryEvents(ped, true) end
            spawnedPeds[#spawnedPeds+1] = ped
          end
        end
      end)
      if not ok then
        print(("[SHOP DEBUG] error spawning peds for shop '%s': %s"):format(tostring(shop.name), tostring(err)))
      end
    end
  end

  print(("--- [SHOP DEBUG] client started. Shops found: %d. Total locations: %d ---"):format(#Shops, totalLocs))
  if #Shops == 0 then
    print("[SHOP DEBUG] Shops table empty or not loaded. Ensure shared/shops.lua is included in fxmanifest.")
  end
end)

AddEventHandler('onResourceStop', function(resName)
  if resName ~= RESOURCE then return end
  for _, ped in ipairs(spawnedPeds) do
    if DoesEntityExist(ped) then DeleteEntity(ped) end
  end
  for _, blip in ipairs(shopBlips) do
    if DoesBlipExist(blip) then RemoveBlip(blip) end
  end
end)

-- -----------------------------
-- Police robbery alert (client)
-- -----------------------------
RegisterNetEvent('shop:robberyAlertPolice', function(data)
  if DEBUG then print("[shop:robberyAlertPolice] received:", safeSerialize(data)) end
  data = data or {}

  local coords = data.coords or data.pos or data.position
  if type(coords) == "table" and coords.x and coords.y and coords.z then
    coords = vector3(coords.x, coords.y, coords.z)
  end

  local blip
  if coords and coords.x and coords.y and coords.z then
    blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(blip, 161)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 1.0)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(("Robbery: %s"):format(tostring(data.shop or "Unknown")))
    EndTextCommandSetBlipName(blip)
    activeRobberyBlips[#activeRobberyBlips+1] = blip
  end

  local msg = ("Robbery reported at %s"):format(tostring(data.shop or "unknown"))
  if lib and lib.notify then
    lib.notify({ title = "Dispatch", description = msg, type = "warning", position = "top" })
  else
    TriggerEvent('chat:addMessage', { args = { '^1DISPATCH', msg } })
  end

  local removeAfter = tonumber(Config.BlipDuration) or 30
  if removeAfter <= 0 then removeAfter = 30 end

  CreateThread(function()
    Wait(removeAfter * 1000)
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    for i = #activeRobberyBlips, 1, -1 do
      if activeRobberyBlips[i] == blip then table.remove(activeRobberyBlips, i) end
    end
  end)
end)

RegisterNetEvent('shop:robberyAlert', function(data)
  if lib and lib.notify then
    lib.notify({
      title = "Alert",
      description = ("Robbery reported near %s"):format(tostring((data or {}).shop or "unknown")),
      type = "info",
      position = "top"
    })
  end
end)

-- -----------------------------
-- Give weapon (server -> client)
-- -----------------------------
RegisterNetEvent('inventory:giveWeapon', function(weaponName, ammo)
  if DEBUG then
    print(("[inventory-client] giveWeapon -> name=%s ammo=%s"):format(tostring(weaponName), tostring(ammo)))
  end

  if not weaponName then return end
  local ped = PlayerPedId()

  local hash = (type(weaponName) == "string") and GetHashKey(weaponName) or tonumber(weaponName)
  if not hash then return end

  local ok, err = pcall(function()
    if not HasPedGotWeapon(ped, hash, false) then
      GiveWeaponToPed(ped, hash, tonumber(ammo) or 0, false, true)
    else
      if tonumber(ammo) and tonumber(ammo) > 0 then
        AddAmmoToPed(ped, hash, tonumber(ammo))
      end
    end
  end)

  if not ok then
    print(("[inventory-client] giveWeapon handler error: %s"):format(tostring(err)))
  end
end)

-- -----------------------------
-- NUI callbacks
-- -----------------------------
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
  currentShop = nil

  cb({ success = true })
end)

-- closeUI: if shop open, close shop; else close inventory
RegisterNUICallback('closeUI', function(_, cb)
  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
    SetNuiFocus(false, false)
  else
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

-- inventory close alias
RegisterNUICallback('close', function(_, cb)
  pushUI('hide')
  SetNuiFocus(false, false)
  open = false
  viewingOther = false
  viewingOwnerId = nil
  viewingOwnerName = nil
  cb('ok')
end)

RegisterNUICallback('useItem', function(data, cb)
  if viewingOther then
    ShowNotification("Cannot use items while viewing another player's inventory.")
    cb('ok')
    return
  end

  local def = Items[data.item]
  if not def then cb('ok'); return end

  local amount = tonumber(def.consume) or 1
  if amount < 1 then amount = 1 end

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

  if def.usetime and type(def.usetime) == 'number' and lib and lib.progressBar then
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
    if def.anim and def.anim.dict and def.anim.clip then
      RequestAnimDict(def.anim.dict)
      while not HasAnimDictLoaded(def.anim.dict) do Wait(10) end
      TaskPlayAnim(PlayerPedId(), def.anim.dict, def.anim.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
    end
    doUse()
  end

  cb('ok')
end)

RegisterNUICallback('dropItem', function(data, cb)
  if viewingOther then
    ShowNotification("Cannot drop items while viewing another player's inventory.")
    cb('ok')
    return
  end

  if not data.item then cb('ok'); return end
  local qty = tonumber(data.qty) or 1

  local ped = PlayerPedId()
  local x, y, z = table.unpack(GetEntityCoords(ped))
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
      if btn._actionKey == data.actionKey then
        btn.action(data.slot)
        break
      end
    end
  end
  cb('ok')
end)

-- -----------------------------
-- Inventory refresh
-- -----------------------------
RegisterNetEvent('inventory:refresh', function(inv, w, mw)
  inventory = inv or {}
  currentWeight = w or 0.0
  maxWeight = mw or maxWeight
  if open then pushUI('updateItems') end
end)

-- -----------------------------
-- Shop robbed state sync
-- -----------------------------
RegisterNetEvent('shop:markRobbed', function(shopName, a, b)
  if not shopName then return end

  -- old style: (shopName, closedUntil)
  if b == nil and type(a) == 'number' then
    local closedUntil = tonumber(a)
    shopStates[shopName] = shopStates[shopName] or {}
    shopStates[shopName][1] = closedUntil

    if (type(os) ~= "table" or type(os.time) ~= "function") and closedUntil and closedUntil > 0 then
      serverTimeOffset = closedUntil - math.floor((GetGameTimer() or 0) / 1000)
    end

    if currentShop and currentShop.shop and currentShop.shop.name == shopName and currentShop.locIndex == 1 then
      if isShopOpen then
        ShowNotification("~r~This shop was just robbed and its doors are closed.")
        SendNUIMessage({ action = 'hideShop' })
        isShopOpen = false
        currentShop = nil
        SetNuiFocus(false, false)
      end
    end

    return
  end

  -- new style: (shopName, locIndex, closedUntil)
  local locIndex = tonumber(a) or 1
  local closedUntil = tonumber(b)

  if (type(os) ~= "table" or type(os.time) ~= "function") and closedUntil and closedUntil > 0 then
    serverTimeOffset = closedUntil - math.floor((GetGameTimer() or 0) / 1000)
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
      if isShopOpen then
        SendNUIMessage({ action = 'hideShop' })
        isShopOpen = false
        currentShop = nil
        SetNuiFocus(false, false)
      end
    end
  end
end)

RegisterNetEvent('shop:syncStates', function(states)
  if type(states) ~= 'table' then return end
  local now = currentTimeSeconds()

  for shopName, v in pairs(states) do
    shopStates[shopName] = shopStates[shopName] or {}

    if type(v) == 'number' then
      if v > now then
        shopStates[shopName][1] = v
      else
        shopStates[shopName][1] = nil
      end
    elseif type(v) == 'table' then
      for idxStr, ts in pairs(v) do
        local idx = tonumber(idxStr)
        ts = tonumber(ts)
        if idx and ts and ts > now then
          shopStates[shopName][idx] = ts
        elseif idx then
          shopStates[shopName][idx] = nil
        end
      end
    end
  end
end)

AddEventHandler('onClientResourceStart', function(res)
  if res ~= RESOURCE then return end
  TriggerServerEvent('shop:requestStates')
  TriggerServerEvent('inventory:refreshRequest')
end)

-- -----------------------------
-- Shop proximity loop (E open, H rob)
-- -----------------------------
CreateThread(function()
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
            local now = currentTimeSeconds()
            local isRobbable = (shop.robbable ~= false)

            if closedUntil and closedUntil > now then
              DrawMarker(2, loc.x, loc.y, loc.z + 0.3, 0,0,0,0,0,0,0.4,0.4,0.4,255,50,50,100,false,true)
              local remaining = closedUntil - now
              DrawText3D(loc.x, loc.y, loc.z + 0.6, ('~r~Closed (robbed) - %02dm %02ds'):format(math.floor(remaining/60), remaining % 60))
            else
              DrawMarker(2, loc.x, loc.y, loc.z + 0.3, 0,0,0,0,0,0,0.4,0.4,0.4,0,255,100,100,false,true)
              if isRobbable then
                DrawText3D(loc.x, loc.y, loc.z + 0.6, '[~g~E~w~] Open Shop    [~r~H~w~] Rob Shop')
              else
                DrawText3D(loc.x, loc.y, loc.z + 0.6, '[~g~E~w~] Open Shop')
              end
            end

            -- OPEN (E)
            if not isShopOpen and IsControlJustReleased(0, 38) then
              local now2 = currentTimeSeconds()
              if closedUntil and closedUntil > now2 then
                local remaining = closedUntil - now2
                ShowNotification(('This shop location is closed due to a recent robbery. Reopens in %dm %ds'):format(math.floor(remaining/60), remaining % 60))
              else
                if open then
                  pushUI('hide')
                  SetNuiFocus(false, false)
                  open = false
                  viewingOther = false
                  viewingOwnerId = nil
                  viewingOwnerName = nil
                end

                currentShop = { shop = shop, loc = loc, locIndex = locIndex }
                local enriched = enrichShopForUI(shop)
                SendNUIMessage({ action = 'showShop', shop = enriched, defs = buildDefs() })
                SetNuiFocus(true, true)
                isShopOpen = true
              end
            end

            -- ROB (H)
            if IsControlJustPressed(0, 74) then
              if not isRobbable then
                ShowNotification("~r~This shop cannot be robbed.")
              else
                local now3 = currentTimeSeconds()
                if closedUntil and closedUntil > now3 then
                  local remaining = closedUntil - now3
                  ShowNotification(('Shop is closed. Reopens in %dm %02ds'):format(math.floor(remaining/60), remaining % 60))
                else
                  local pedWeapon = GetSelectedPedWeapon(playerPed)
                  local isUnarmed = (pedWeapon == GetHashKey("WEAPON_UNARMED"))
                  local freeAiming = IsPlayerFreeAiming(PlayerId())
                  local targetting = IsPlayerTargettingAnything(PlayerId())

                  local holdingAim = (not isUnarmed) and (freeAiming or targetting or IsControlPressed(0, 24))

                  if not holdingAim then
                    ShowNotification("~r~You must be holding and aiming a firearm to rob the shop.")
                  else
                    local pedPos = GetEntityCoords(playerPed)
                    TriggerServerEvent('shop:attemptRob', shop.name, pedPos.x, pedPos.y, pedPos.z)
                  end
                end
              end
            end

            break
          end
        end
      end
    end

    -- walked away while shop open -> close it
    if isShopOpen and not foundAny then
      SendNUIMessage({ action = 'hideShop' })
      if open then
        pushUI('hide')
        open = false
        viewingOther = false
        viewingOwnerId = nil
        viewingOwnerName = nil
      end
      SetNuiFocus(false, false)
      isShopOpen = false
      currentShop = nil
    end
  end
end)

-- ESC/back closes UI (shop or inventory)
CreateThread(function()
  while true do
    Wait(0)
    if isShopOpen or open then
      if IsControlJustReleased(0, 322) or IsControlJustReleased(0, 200) then
        if isShopOpen then
          SendNUIMessage({ action = 'hideShop' })
          isShopOpen = false
          currentShop = nil
        end
        if open then
          pushUI('hide')
          open = false
          viewingOther = false
          viewingOwnerId = nil
          viewingOwnerName = nil
        end
        SetNuiFocus(false, false)
      end
    end
  end
end)

-- =========================================================
-- Inventory toggle (command + keymapping) - FIXED
-- =========================================================
local lastToggleAt = 0

local function _toggleInventory()
  local now = GetGameTimer()
  if (now - lastToggleAt) < 250 then return end
  lastToggleAt = now

  -- If shop is open, close shop first (prevents weird focus fights)
  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
    SetNuiFocus(false, false)
    return
  end

  open = not open
  SetNuiFocus(open, open)

  if open then
    pushUI('show')
    TriggerServerEvent('inventory:refreshRequest')
  else
    pushUI('hide')
    viewingOther = false
    viewingOwnerId = nil
    viewingOwnerName = nil
  end
end

RegisterCommand('azinv', function()
  _toggleInventory()
end, false)

RegisterCommand('inventory', function()
  _toggleInventory()
end, false)

RegisterKeyMapping('azinv', 'Toggle Az-Inventory', 'keyboard', tostring(Config.Control.DefaultKey or 'F2'))

-- Control-index fallback ONLY if keymapping is disabled
CreateThread(function()
  while true do
    Wait(0)
    if Config.Control.UseKeyMapping == false then
      local openKey = tonumber(Config.Control.ToggleInventory) or 0
      if openKey > 0 and IsControlJustPressed(0, openKey) then
        _toggleInventory()
      end
    end
  end
end)

-- -----------------------------
-- Allow server to force open/close (optional)
-- -----------------------------
RegisterNetEvent('inventory:clientOpen', function()
  if not open then _toggleInventory() end
end)

RegisterNetEvent('inventory:clientClose', function()
  if open then _toggleInventory() end
end)

-- -----------------------------
-- World drops
-- -----------------------------
RegisterNetEvent('inventory:spawnDrop', function(drop)
  if not drop or not drop.coords or not drop.id then return end
  local x, y, z = drop.coords.x, drop.coords.y, drop.coords.z

  local modelName = 'prop_med_bag_01b'
  local modelHash = GetHashKey(modelName)
  RequestModel(modelHash)
  while not HasModelLoaded(modelHash) do Wait(10) end

  local obj = CreateObject(modelHash, x, y, z + 1.0, true, true, false)
  NetworkRegisterEntityAsNetworked(obj)
  worldDrops[drop.id] = ObjToNet(obj)
end)

RegisterNetEvent('inventory:removeDrop', function(dropId)
  local netId = worldDrops[dropId]
  if netId then
    local obj = NetToObj(netId)
    if DoesEntityExist(obj) then DeleteObject(obj) end
    worldDrops[dropId] = nil
  end
end)

CreateThread(function()
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

-- -----------------------------
-- DrawText3D
-- -----------------------------
function DrawText3D(x, y, z, text, scale)
  scale = scale or 0.35
  SetTextScale(scale, scale)
  SetTextFont(4)
  SetTextProportional(1)
  SetTextColour(255, 255, 255, 215)
  SetTextCentre(true)
  SetTextEntry('STRING')
  AddTextComponentString(text)
  SetDrawOrigin(x, y, z, 0)
  DrawText(0.0, 0.0)
  ClearDrawOrigin()
end
