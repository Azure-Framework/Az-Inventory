




local RESOURCE = GetCurrentResourceName()

local Items = Items or {}
local Shops = Shops or {}

local worldDrops = {}
local open = false
local inventory = {}
local OxSlots = {}
local currentWeight = 0.0
local maxWeight = 0.0
local storageInventory = {}
local storageWeight = 0.0
local storageMaxWeight = 0.0
local currentStorage = nil

local activeRobberyBlips = activeRobberyBlips or {}
local stashTarget = nil
local currentWeapon = nil


local function emitOxInventorySync()
  TriggerEvent('ox_inventory:updateInventory', { refresh = true })
  TriggerEvent('ox_inventory:updateSlots', OxSlots, { player = currentWeight, other = storageWeight })
  TriggerEvent('ox_inventory:refreshMaxWeight', maxWeight)
  TriggerEvent('ox_inventory:refreshSlotCount', tonumber(Config.MaxSlots) or 50)
end





Config = Config or {}
Config.Debug = Config.Debug or false

Config.Control = Config.Control or {}
Config.Control.UseKeyMapping = (Config.Control.UseKeyMapping ~= false) 
Config.Control.DefaultKey = Config.Control.DefaultKey or 'F2'
Config.Control.ToggleInventory = tonumber(Config.Control.ToggleInventory) or 289 

Config.RobCooldown = Config.RobCooldown or 600
Config.BlipDuration = tonumber(Config.BlipDuration) or 30

local DEBUG = Config.Debug == true


local shopStates = {}

local isShopOpen = false
local currentShop = nil 

local viewingOther = false
local viewingOwnerId = nil
local viewingOwnerName = nil

local shopBlips = {}
local spawnedPeds = {}
local shopRuntime = {}
local defsCache = nil
local dropModelHash = GetHashKey('prop_med_bag_01b')




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


local serverTimeOffset = 0 

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
  if defsCache then return defsCache end

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

  defsCache = safe
  return defsCache
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


local function closeTrackedVehicleDoor()
  if not currentStorage or currentStorage.kind ~= 'trunk' then return end
  if not (Config.VehicleStorage and Config.VehicleStorage.CloseTrunkOnClose ~= false) then return end
  if not currentStorage.vehicleNetId then return end

  local veh = NetToVeh(currentStorage.vehicleNetId)
  if veh and veh ~= 0 and DoesEntityExist(veh) then
    SetVehicleDoorShut(veh, 5, false)
  end
end

local function clearStorageView(closeDoor)
  if closeDoor then closeTrackedVehicleDoor() end
  storageInventory = {}
  storageWeight = 0.0
  storageMaxWeight = 0.0
  currentStorage = nil
end

local function pushStorageUI(action)
  if not currentStorage then
    pushUI(action)
    return
  end

  SendNUIMessage({
    action = action,
    items = inventory,
    defs = buildDefs(),
    playerId = GetPlayerServerId(PlayerId()),
    weight = currentWeight,
    maxWeight = maxWeight,
    storageItems = storageInventory,
    storageWeight = storageWeight,
    storageMaxWeight = storageMaxWeight,
    storageMeta = {
      kind = currentStorage.kind,
      plate = currentStorage.plate,
      label = currentStorage.label,
    }
  })
end

local function normalizePlateText(plate)
  return tostring(plate or ''):upper():gsub('%s+', '')
end

local function isVehicleStorageClassBlocked(vehicle)
  local blocked = (Config.VehicleStorage and Config.VehicleStorage.BlockedClasses) or {}
  local class = GetVehicleClass(vehicle)
  return blocked[class] == true
end

local function getStoragePoint(vehicle, kind)
  if kind == 'trunk' then
    local boneIndex = GetEntityBoneIndexByName(vehicle, 'boot')
    if boneIndex and boneIndex ~= -1 then
      return GetWorldPositionOfEntityBone(vehicle, boneIndex)
    end
    return GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -2.5, 0.2)
  end

  return GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 1.25, 0.2)
end

local function findNearbyVehicleForStorage(kind)
  local ped = PlayerPedId()
  local pcoords = GetEntityCoords(ped)
  local maxDist = tonumber((Config.VehicleStorage and Config.VehicleStorage.MaxDistance) or 2.7) or 2.7

  if kind == 'glovebox' and IsPedInAnyVehicle(ped, false) then
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 then return veh end
  end

  local bestVeh, bestDist = 0, maxDist + 0.01
  for _, veh in ipairs(GetGamePool('CVehicle')) do
    if DoesEntityExist(veh) then
      local point = getStoragePoint(veh, kind)
      local dist = #(pcoords - point)
      if dist <= maxDist and dist < bestDist then
        bestVeh = veh
        bestDist = dist
      end
    end
  end

  return bestVeh
end

local function openVehicleStorage(kind)
  if not (Config.VehicleStorage and Config.VehicleStorage.Enabled ~= false) then
    ShowNotification('Vehicle storage is disabled.')
    return
  end

  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
  end

  local ped = PlayerPedId()
  local veh = findNearbyVehicleForStorage(kind)
  if not veh or veh == 0 or not DoesEntityExist(veh) then
    ShowNotification(kind == 'glovebox' and 'No vehicle glovebox nearby.' or 'No vehicle trunk nearby.')
    return
  end

  if isVehicleStorageClassBlocked(veh) then
    ShowNotification(kind == 'glovebox' and 'This vehicle has no glovebox storage.' or 'This vehicle has no trunk storage.')
    return
  end

  local lockStatus = GetVehicleDoorLockStatus(veh)
  local allowTrunk = (lockStatus == 0 or lockStatus == 1 or lockStatus == 8)
  local allowCabin = (lockStatus == 0 or lockStatus == 1)
  local insideSameVehicle = IsPedInVehicle(ped, veh, false)
  if Config.VehicleStorage.RequireUnlocked ~= false then
    if kind == 'trunk' and not allowTrunk then
      ShowNotification('Vehicle is locked.')
      return
    elseif kind == 'glovebox' and not (allowCabin or insideSameVehicle) then
      ShowNotification('Vehicle is locked.')
      return
    end
  end

  local plate = normalizePlateText(GetVehicleNumberPlateText(veh))
  if not plate or plate == '' then
    ShowNotification('Could not read the vehicle plate.')
    return
  end

  if kind == 'trunk' and (Config.VehicleStorage.OpenTrunkDoor ~= false) then
    SetVehicleDoorOpen(veh, 5, false, false)
  end

  currentStorage = {
    kind = kind,
    plate = plate,
    label = ((kind == 'glovebox') and 'Glovebox' or 'Trunk') .. ' [' .. plate .. ']',
    vehicleNetId = VehToNet(veh)
  }

  open = true
  SetNuiFocus(true, true)
  TriggerServerEvent('inventory:openVehicleStorage', { kind = kind, plate = plate })
end




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

local function rebuildShopRuntime()
  shopRuntime = {}

  for _, shop in ipairs(Shops) do
    local runtime = {
      shop = shop,
      radius = tonumber(shop.radius) or 2.0,
      locations = {},
      pedLocations = getShopPedLocations(shop),
    }

    for _, loc in ipairs(getShopLocations(shop)) do
      if loc and loc.x and loc.y and loc.z then
        runtime.locations[#runtime.locations + 1] = {
          x = loc.x,
          y = loc.y,
          z = loc.z,
          vec = vector3(loc.x, loc.y, loc.z),
        }
      end
    end

    shopRuntime[#shopRuntime + 1] = runtime
  end
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




print(('[Az-Inventory] client loaded (%s)'):format(RESOURCE))

CreateThread(function()
  local totalLocs = 0

  rebuildShopRuntime()

  for _, runtime in ipairs(shopRuntime) do
    local shop = runtime.shop
    local locs = runtime.locations
    totalLocs = totalLocs + #locs

    
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

    
    local pedLocs = runtime.pedLocations
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
  closeTrackedVehicleDoor()
  for _, ped in ipairs(spawnedPeds) do
    if DoesEntityExist(ped) then DeleteEntity(ped) end
  end
  for _, blip in ipairs(shopBlips) do
    if DoesBlipExist(blip) then RemoveBlip(blip) end
  end
end)




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


RegisterNetEvent('inventory:removeWeapon', function(weaponName)
  if not weaponName then return end

  local ped = PlayerPedId()
  local hash = (type(weaponName) == 'string') and GetHashKey(weaponName) or tonumber(weaponName)
  if not hash or hash == 0 then return end

  if GetSelectedPedWeapon(ped) == hash then
    SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
  end

  RemoveWeaponFromPed(ped, hash)
end)


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


RegisterNUICallback('closeUI', function(_, cb)
  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
    SetNuiFocus(false, false)
  else
    clearStorageView(true)
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
  clearStorageView(true)
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


RegisterNUICallback('storageDeposit', function(data, cb)
  if not currentStorage or not data or not data.item then
    cb({ success = false })
    return
  end

  TriggerServerEvent('inventory:transferVehicleStorage', currentStorage.kind, currentStorage.plate, 'deposit', data.item, tonumber(data.qty) or 1)
  cb({ success = true })
end)

RegisterNUICallback('storageWithdraw', function(data, cb)
  if not currentStorage or not data or not data.item then
    cb({ success = false })
    return
  end

  TriggerServerEvent('inventory:transferVehicleStorage', currentStorage.kind, currentStorage.plate, 'withdraw', data.item, tonumber(data.qty) or 1)
  cb({ success = true })
end)




RegisterNetEvent('inventory:refresh', function(inv, w, mw)
  inventory = inv or {}
  currentWeight = w or 0.0
  maxWeight = mw or maxWeight
  if open then
    if currentStorage then
      pushStorageUI('updateVehicleStorage')
    else
      pushUI('updateItems')
    end
  end
  emitOxInventorySync()
end)




RegisterNetEvent('shop:markRobbed', function(shopName, a, b)
  if not shopName then return end

  
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




CreateThread(function()
  while true do
    local waitMs = isShopOpen and 0 or 250

    local playerPed = PlayerPedId()
    local pos = GetEntityCoords(playerPed)
    local foundAny = false
    local nearestDist = math.huge

    for _, runtime in ipairs(shopRuntime) do
      local shop = runtime.shop
      local radius = runtime.radius

      for locIndex, loc in ipairs(runtime.locations) do
        local dist = #(pos - loc.vec)
        if dist < nearestDist then nearestDist = dist end

        if dist < radius then
          foundAny = true
          waitMs = 0

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

          if not isShopOpen and IsControlJustReleased(0, 38) then
            local now2 = currentTimeSeconds()
            if closedUntil and closedUntil > now2 then
              local remaining = closedUntil - now2
              ShowNotification(('This shop location is closed due to a recent robbery. Reopens in %dm %ds'):format(math.floor(remaining/60), remaining % 60))
            else
              if open then
                clearStorageView(true)
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

    if isShopOpen and not foundAny then
      SendNUIMessage({ action = 'hideShop' })
      if open then
        clearStorageView(true)
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

    if not isShopOpen then
      if nearestDist < 12.0 then
        waitMs = 0
      elseif nearestDist < 40.0 then
        waitMs = math.min(waitMs, 100)
      end
    end

    Wait(waitMs)
  end
end)


CreateThread(function()
  while true do
    if isShopOpen or open then
      Wait(0)
      if IsControlJustReleased(0, 322) or IsControlJustReleased(0, 200) then
        if isShopOpen then
          SendNUIMessage({ action = 'hideShop' })
          isShopOpen = false
          currentShop = nil
        end
        if open then
          clearStorageView(true)
          pushUI('hide')
          open = false
          viewingOther = false
          viewingOwnerId = nil
          viewingOwnerName = nil
        end
        SetNuiFocus(false, false)
      end
    else
      Wait(200)
    end
  end
end)




local lastToggleAt = 0

local function _toggleInventory()
  local now = GetGameTimer()
  if (now - lastToggleAt) < 250 then return end
  lastToggleAt = now

  
  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
    SetNuiFocus(false, false)
    return
  end

  if currentStorage then
    clearStorageView(true)
    pushUI('hide')
    SetNuiFocus(false, false)
    open = false
    return
  end

  -- The inventory key is context-aware: while seated in a vehicle it opens
  -- that vehicle's glovebox instead of the standalone player inventory.
  if not open
      and Config.VehicleStorage
      and Config.VehicleStorage.Enabled ~= false
      and IsPedInAnyVehicle(PlayerPedId(), false) then
    openVehicleStorage('glovebox')
    return
  end

  open = not open
  SetNuiFocus(open, open)

  if open then
    pushUI('show')
    TriggerServerEvent('inventory:refreshRequest')
  else
    clearStorageView(true)
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


CreateThread(function()
  while true do
    if Config.Control.UseKeyMapping == false then
      Wait(0)
      local openKey = tonumber(Config.Control.ToggleInventory) or 0
      if openKey > 0 and IsControlJustPressed(0, openKey) then
        _toggleInventory()
      end
    else
      Wait(250)
    end
  end
end)




RegisterNetEvent('inventory:clientOpen', function()
  if not open then _toggleInventory() end
end)

RegisterNetEvent('inventory:clientClose', function()
  if open then _toggleInventory() end
end)

RegisterNetEvent('inventory:openSelf', function(inv, w, mw)
  clearStorageView(false)
  viewingOther = false
  viewingOwnerId = nil
  viewingOwnerName = nil
  inventory = inv or inventory or {}
  currentWeight = w or 0.0
  maxWeight = mw or maxWeight
  open = true
  SetNuiFocus(true, true)
  pushUI('show')
end)

RegisterNetEvent('inventory:openOther', function(inv, w, mw, ownerId, ownerName)
  clearStorageView(false)
  viewingOther = true
  viewingOwnerId = ownerId
  viewingOwnerName = ownerName
  inventory = inv or {}
  currentWeight = w or 0.0
  maxWeight = mw or maxWeight
  open = true
  SetNuiFocus(true, true)
  SendNUIMessage({
    action = 'showOtherInventory',
    items = inventory,
    defs = buildDefs(),
    ownerId = ownerId,
    ownerName = ownerName,
    weight = currentWeight,
    maxWeight = maxWeight,
    playerId = ownerId,
  })
end)

RegisterNetEvent('inventory:vehicleStorageData', function(data)
  if not data then return end

  inventory = data.playerItems or {}
  currentWeight = data.playerWeight or 0.0
  maxWeight = data.playerMaxWeight or maxWeight
  storageInventory = data.storageItems or {}
  storageWeight = data.storageWeight or 0.0
  storageMaxWeight = data.storageMaxWeight or storageMaxWeight

  currentStorage = currentStorage or {}
  currentStorage.kind = data.kind or currentStorage.kind or 'trunk'
  currentStorage.plate = data.plate or currentStorage.plate or 'UNKNOWN'
  currentStorage.label = ((currentStorage.kind == 'glovebox') and 'Glovebox' or 'Trunk') .. ' [' .. tostring(currentStorage.plate) .. ']'

  open = true
  SetNuiFocus(true, true)
  pushStorageUI('showVehicleStorage')
end)

RegisterCommand('aztrunk', function()
  openVehicleStorage('trunk')
end, false)

RegisterCommand('azglovebox', function()
  openVehicleStorage('glovebox')
end, false)

RegisterKeyMapping('aztrunk', 'Open vehicle trunk storage', 'keyboard', tostring((Config.VehicleStorage and Config.VehicleStorage.DefaultTrunkKey) or 'K'))




RegisterNetEvent('inventory:spawnDrop', function(drop)
  if not drop or not drop.coords or not drop.id then return end
  local x, y, z = drop.coords.x, drop.coords.y, drop.coords.z

  if not HasModelLoaded(dropModelHash) then
    RequestModel(dropModelHash)
    while not HasModelLoaded(dropModelHash) do Wait(10) end
  end

  RequestCollisionAtCoord(x, y, z)

  local obj = CreateObjectNoOffset(dropModelHash, x, y, z + 0.2, true, true, false)
  if not obj or obj == 0 or not DoesEntityExist(obj) then return end

  for _ = 1, 20 do
    if HasCollisionLoadedAroundEntity(obj) then break end
    Wait(0)
  end

  PlaceObjectOnGroundProperly(obj)
  FreezeEntityPosition(obj, true)
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
    local waitMs = 300
    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)

    for dropId, netId in pairs(worldDrops) do
      local obj = NetToObj(netId)
      if DoesEntityExist(obj) then
        local coords = GetEntityCoords(obj)
        local dist = #(pcoords - coords)

        if dist < 1.5 then
          waitMs = 0
          DrawText3D(coords.x, coords.y, coords.z + 0.3, '[~g~E~w~] Pick up')
          if IsControlJustReleased(0, 38) then
            TriggerServerEvent('inventory:pickupDrop', dropId)
            TriggerServerEvent('inventory:refreshRequest')
          end
        elseif dist < 12.0 then
          waitMs = math.min(waitMs, 100)
        end
      end
    end

    Wait(waitMs)
  end
end)




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


RegisterNetEvent('az_inventory:syncOxSlots', function(slots)
  OxSlots = slots or {}
  emitOxInventorySync()
end)

RegisterNetEvent('inventory:callClientExport', function(exp, key, qty, def)
  local resourceName, funcName
  if type(exp) == 'string' then
    resourceName, funcName = exp:match('^([^:%.]+)[:%.](.+)$')
  elseif type(exp) == 'table' then
    resourceName, funcName = exp.resource, exp.func
  end
  if not resourceName or not funcName or not exports[resourceName] then return end
  local slotData
  for _, slot in pairs(OxSlots or {}) do
    if slot and slot.name == key then slotData = slot break end
  end
  local data = { slot = slotData and slotData.slot or nil, name = key, count = qty }
  pcall(function()
    exports[resourceName][funcName](data, slotData)
  end)
end)

exports('Search', function(search, item)
  if search == 'count' then
    return tonumber(inventory[item] or 0) or 0
  end
  return 0
end)

exports('GetPlayerItems', function()
  return OxSlots
end)

exports('GetPlayerWeight', function()
  return currentWeight or 0.0
end)

exports('GetPlayerMaxWeight', function()
  return maxWeight or 0.0
end)

exports('GetSlotWithItem', function(item)
  for _, slot in pairs(OxSlots or {}) do
    if slot and slot.name == item then return slot end
  end
end)

exports('GetItemCount', function(item)
  return tonumber(inventory[item] or 0) or 0
end)

exports('openInventory', function(invType, data)
  if invType == 'stash' then
    TriggerServerEvent('inventory:openStash', tostring(data or ''))
    return true
  elseif invType == 'player' then
    TriggerServerEvent('inventory:requestOpenOther', tonumber(data) or 0)
    return true
  end
  return false
end)


exports('OpenInventory', function(...) return exports[RESOURCE]:openInventory(...) end)
exports('closeInventory', function()
  if isShopOpen then
    SendNUIMessage({ action = 'hideShop' })
    isShopOpen = false
    currentShop = nil
  end
  clearStorageView(true)
  if open then
    open = false
    SetNuiFocus(false, false)
    pushUI('hide')
  end
  TriggerEvent('ox_inventory:closeInventory')
  return true
end)
exports('openNearbyInventory', function() return false end)
exports('useItem', function(data, cb)
  local item = type(data) == 'table' and (data.name or data.item) or data
  if item then TriggerServerEvent('inventory:useItem', item, 1) end
  if cb then cb(true) end
  return true
end)
exports('useSlot', function(slot)
  slot = tonumber(slot)
  if not slot then return false end
  local slotData = OxSlots and OxSlots[slot]
  if slotData and slotData.name then
    TriggerServerEvent('inventory:useItem', slotData.name, 1)
    return true
  end
  return false
end)
exports('GetSlotIdWithItem', function(item)
  for slotId, slot in pairs(OxSlots or {}) do
    if slot and slot.name == item then return slotId end
  end
end)
exports('GetSlotsWithItem', function(item)
  local out = {}
  for _, slot in pairs(OxSlots or {}) do
    if slot and slot.name == item then out[#out+1] = slot end
  end
  return out
end)
exports('Items', function(item)
  if item then return Items and Items[item] or nil end
  return Items
end)
exports('ItemList', function(item)
  if item then return Items and Items[item] or nil end
  return Items
end)
exports('getCurrentWeapon', function() return currentWeapon end)
exports('setStashTarget', function(id, owner) stashTarget = { id = id, owner = owner }; return true end)
exports('displayMetadata', function(...) return true end)
exports('notify', function(data)
  if lib and lib.notify then lib.notify(data) else ShowNotification((data and (data.description or data.title)) or 'Notification') end
end)
exports('weaponWheel', function(state) return true end)
exports('Keyboard', function(fields, cb)
  if lib and lib.inputDialog then return lib.inputDialog('Input', fields) end
  return nil
end)
exports('Progress', function(options, completed)
  local result = true
  if lib and lib.progressBar then result = lib.progressBar(options) end
  if completed then completed(result) end
  return result
end)
exports('CancelProgress', function() if lib and lib.cancelProgress then lib.cancelProgress() end end)
exports('ProgressActive', function() if lib and lib.progressActive then return lib.progressActive() end return false end)
exports('giveItemToTarget', function(serverId, slotId, count)
  return false
end)

RegisterNetEvent('ox_inventory:openInventory', function(invType, data)
  exports[RESOURCE]:openInventory(invType, data)
end)
RegisterNetEvent('ox_inventory:closeInventory', function()
  exports[RESOURCE]:closeInventory()
end)
RegisterNetEvent('ox_inventory:forceOpenInventory', function(invType, data)
  exports[RESOURCE]:openInventory(invType, data)
end)
RegisterNetEvent('ox_inventory:setPlayerInventory', function(currentDrops, inv, weight, player)
  OxSlots = inv or OxSlots or {}
  currentWeight = weight or currentWeight or 0.0
  emitOxInventorySync()
end)
RegisterNetEvent('ox_inventory:viewInventory', function(left, right)
  if left and left.type == 'player' and left.id then
    TriggerServerEvent('inventory:requestOpenOther', tonumber(left.id) or 0)
  end
end)
RegisterNetEvent('ox_inventory:notify', function(data)
  exports[RESOURCE]:notify(data)
end)
RegisterNetEvent('ox_inventory:itemNotify', function(data)
  exports[RESOURCE]:notify(data)
end)
RegisterNetEvent('ox_inventory:disarm', function(noAnim)
  currentWeapon = nil
  RemoveAllPedWeapons(PlayerPedId(), true)
end)
RegisterNetEvent('ox_inventory:clearWeapons', function()
  currentWeapon = nil
  RemoveAllPedWeapons(PlayerPedId(), true)
end)
RegisterNetEvent('ox_inventory:inventoryReturned', function(data) end)
RegisterNetEvent('ox_inventory:inventoryConfiscated', function(message) end)
RegisterNetEvent('ox_inventory:createDrop', function(dropId, data, owner, slot) end)
RegisterNetEvent('ox_inventory:removeDrop', function(dropId) end)
RegisterNetEvent('ox_inventory:refreshMaxWeight', function(data) maxWeight = tonumber(data) or maxWeight end)
RegisterNetEvent('ox_inventory:refreshSlotCount', function(data) end)
RegisterNetEvent('ox_inventory:updateSlots', function(items, weights) end)
RegisterNetEvent('ox_inventory:updateInventory')
RegisterNetEvent('ox_inventory:currentWeapon', function(weapon) currentWeapon = weapon end)
RegisterNetEvent('ox_inventory:itemCount', function(item, count)
  inventory[item] = count
end)
RegisterNetEvent('ox_inventory:updateWeaponComponent', function(...) end)
