local Items     = Items or {}        -- your Items table
local Shops     = Shops or {}        -- defined in shops.lua

-- Inventory variables
local worldDrops     = {}
local open           = false
local inventory      = {}
local currentWeight  = 0.0
local maxWeight      = 0.0
local openKey        = 289 -- F2

-- State for shop UI
local isShopOpen   = false
local currentShop  = nil

-- Blip storage
local shopBlips = {}


local spawnedPeds = {}

-- helper: load model
local function LoadModel(hash)
  if not HasModelLoaded(hash) then
    RequestModel(hash)
    while not HasModelLoaded(hash) do Citizen.Wait(10) end
  end
end

-- spawn configured shop peds & blips on resource start
Citizen.CreateThread(function()
  for _, shop in ipairs(Shops) do
    -- spawn ped if defined
    if shop.ped then
      local m = shop.ped.model
      local hash = type(m) == "string" and GetHashKey(m) or m
      LoadModel(hash)
      local x,y,z,h = table.unpack(shop.ped.coords)
      local ped = CreatePed(4, hash, x, y, z - 1.0, h, false, true)
      if shop.ped.freeze      then FreezeEntityPosition(ped, true) end
      if shop.ped.invincible  then SetEntityInvincible(ped, true) end
      if shop.ped.blockEvents then SetBlockingOfNonTemporaryEvents(ped, true) end
      spawnedPeds[#spawnedPeds+1] = ped
    end

    -- add blip if defined
    if shop.blip then
      local b = shop.blip
      local blip = AddBlipForCoord(shop.coords.x, shop.coords.y, shop.coords.z)
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

-- cleanup on resource stop
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

Citizen.CreateThread(function()
  while true do
    Wait(0)
    local playerPed = PlayerPedId()
    local pos       = GetEntityCoords(playerPed)
    local foundAny  = false

    for _, shop in ipairs(Shops) do
      local dist = #(pos - shop.coords)
      if dist < shop.radius then
        DrawMarker(2, shop.coords.x, shop.coords.y, shop.coords.z + 0.3,
                   0,0,0, 0,0,0, 0.4,0.4,0.4, 0,255,100,100, false, true)
        foundAny = true

        if not isShopOpen and IsControlJustReleased(0, 38) then -- E key
          currentShop = shop
          SendNUIMessage({ action = 'showShop', shop = shop })
          SetNuiFocus(true, true)
          isShopOpen = true
        end
      end
    end

    if isShopOpen and not foundAny then
      SendNUIMessage({ action = 'hideShop' })
      SetNuiFocus(false, false)
      isShopOpen  = false
      currentShop = nil
    end
  end
end)

-- NUI callback: buyItem
RegisterNUICallback('buyItem', function(data, cb)
  print('🟢 [shop] NUI → buyItem:' , data.name, data.price)
  TriggerServerEvent('shop:buyItem', data.name, data.price)
  -- immediately refresh inventory after purchase
  TriggerServerEvent('inventory:refreshRequest')
  SetNuiFocus(false, false)
  SendNUIMessage({ action = 'hideShop' })
  isShopOpen = false
  cb({ success = true })
end)

-- NUI callback: closeUI
RegisterNUICallback('closeUI', function(_, cb)
  SendNUIMessage({ action = 'hideShop' })
  SetNuiFocus(false, false)
  isShopOpen  = false
  currentShop = nil
  cb({})
end)

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

local function pushUI(action)
  SendNUIMessage({
    action    = action,
    items     = inventory,
    defs      = buildDefs(),
    playerId  = GetPlayerServerId(PlayerId()),
    weight    = currentWeight,
    maxWeight = maxWeight,
  })
end

local function performUse(def)
  local ped = PlayerPedId()
  if def.anim then
    RequestAnimDict(def.anim.dict)
    while not HasAnimDictLoaded(def.anim.dict) do Wait(10) end
    TaskPlayAnim(ped, def.anim.dict, def.anim.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
  end
  local prop
  if def.prop then
    RequestModel(def.prop.model)
    while not HasModelLoaded(def.prop.model) do Wait(10) end
    prop = CreateObject(def.prop.model, 0,0,0, true, true, false)
    AttachEntityToEntity(prop, ped, def.prop.bone or 18905,
      def.prop.pos.x,def.prop.pos.y,def.prop.pos.z,
      def.prop.rot.x,def.prop.rot.y,def.prop.rot.z,
      true,true,false,false,2,true)
  end
  local endT = GetGameTimer() + (def.usetime or 5000)
  while GetGameTimer() < endT do
    if def.disable then
      if def.disable.move   then DisableControlAction(0,30,true) end
      if def.disable.combat then DisableControlAction(0,24,true) end
      if def.disable.sprint then DisableControlAction(0,21,true) end
      if def.disable.mouse  then DisableControlAction(0,1,true); DisableControlAction(0,2,true) end
      if def.disable.car    then DisableControlAction(0,75,true) end
    end
    if def.cancel and IsControlJustPressed(0,200) then break end
    Wait(0)
  end
  if def.anim then
    StopAnimTask(ped, def.anim.dict, def.anim.clip, 1.0)
    ClearPedTasks(ped)
  end
  if prop and DoesEntityExist(prop) then DeleteObject(prop) end
end

RegisterNUICallback('useItem', function(data, cb)
  local def = Items[data.item]
  if def then
    performUse(def)
    TriggerServerEvent('inventory:useItem', data.item, def.consume or 1)
    -- immediately refresh inventory after use
    TriggerServerEvent('inventory:refreshRequest')
    if def.server and def.server.export then
      TriggerServerEvent(def.server.export, data.item)
    end
    if def.event then
      TriggerEvent(def.event, data.item)
    end
    if def.status then
      for k,v in pairs(def.status) do
        TriggerEvent('status:add', k, v)
      end
    end
    if def.close ~= false then
      pushUI('hide')
      SetNuiFocus(false,false)
      open = false
    end
  end
  cb('ok')
end)

RegisterNUICallback('dropItem', function(data, cb)
  print("🟡 [CLIENT] dropItem NUI callback fired! data=", data.item)
  if not data.item then
    return cb('ok')
  end

  local ped = PlayerPedId()
  local x,y,z = table.unpack(GetEntityCoords(ped))
  print(("🟡 [CLIENT] sending dropItem → %s at %.2f, %.2f, %.2f")
        :format(data.item, x, y, z))

  TriggerServerEvent('inventory:dropItem', data.item, x, y, z)
  -- immediately refresh inventory after drop
  TriggerServerEvent('inventory:refreshRequest')
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

RegisterNUICallback('close', function(_, cb)
  pushUI('hide')
  SetNuiFocus(false,false)
  open = false
  cb('ok')
end)

RegisterNetEvent('inventory:refresh')
AddEventHandler('inventory:refresh', function(inv, w, mw)
  inventory     = inv or {}
  currentWeight = w or 0.0
  maxWeight     = mw or maxWeight
  if open then
    pushUI('updateItems')
  end
end)

Citizen.CreateThread(function()
  while true do
    Wait(0)
    if IsControlJustPressed(0, openKey) then
      open = not open
      SetNuiFocus(open, open)
      if open then
        pushUI('show')
        TriggerServerEvent('inventory:refreshRequest')
      else
        pushUI('hide')
      end
    end
  end
end)

-- Spawn world drop on client
RegisterNetEvent('inventory:spawnDrop')
AddEventHandler('inventory:spawnDrop', function(drop)
  local x,y,z = drop.coords.x, drop.coords.y, drop.coords.z
  local modelName = 'prop_med_bag_01b'
  local modelHash = GetHashKey(modelName)

  RequestModel(modelHash)
  while not HasModelLoaded(modelHash) do Wait(10) end

  local obj = CreateObject(modelHash, x, y, z + 1.0, true, true, false)
  if not DoesEntityExist(obj) then
    print("[inventory] ERROR: CreateObject failed")
    return
  end

  NetworkRegisterEntityAsNetworked(obj)
  local netId = ObjToNet(obj)
  print("[inventory] spawned bag network ID →", netId)

  PlaceObjectOnGroundProperly(obj)
  local fx,fy,fz = table.unpack(GetEntityCoords(obj))
  print(("[inventory] final object coords → %.2f, %.2f, %.2f"):format(fx,fy,fz))

  worldDrops[drop.id] = netId
end)

-- Remove world drop on client
RegisterNetEvent('inventory:removeDrop')
AddEventHandler('inventory:removeDrop', function(dropId)
  local netId = worldDrops[dropId]
  if netId then
    local obj = NetToObj(netId)
    if DoesEntityExist(obj) then
      DeleteObject(obj)
    end
    worldDrops[dropId] = nil
  end
end)

-- Pickup loop
Citizen.CreateThread(function()
  while true do
    Wait(100)
    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    for dropId, netId in pairs(worldDrops) do
      local obj = NetToObj(netId)
      if DoesEntityExist(obj) then
        local coords = GetEntityCoords(obj)
        if #(pcoords - coords) < 1.5 then
          DrawText3D(coords.x,coords.y,coords.z+0.3,'[~g~E~w~] Pick up')
          if IsControlJustReleased(0,38) then
            TriggerServerEvent('inventory:pickupDrop', dropId)
            -- immediately refresh inventory after pickup
            TriggerServerEvent('inventory:refreshRequest')
          end
        end
      end
    end
  end
end)

function DrawText3D(x,y,z,text)
  SetTextScale(0.35,0.35)
  SetTextFont(4)
  SetTextProportional(1)
  SetTextColour(255,255,255,215)
  SetTextEntry('STRING')
  SetTextCentre(true)
  AddTextComponentString(text)
  SetDrawOrigin(x,y,z,0)
  DrawText(0.0,0.0)
  ClearDrawOrigin()
end

AddEventHandler('onClientResourceStart', function(res)
  if GetCurrentResourceName() == res then
    TriggerServerEvent('inventory:refreshRequest')
  end
end)

RegisterNetEvent("inventory:refresh")
AddEventHandler("inventory:refresh", function(inv, weight, maxWeight)

  SendNUIMessage({ action = "clearInventory" })

  -- add each item from the DB snapshot
  for itemKey, count in pairs(inv) do
    SendNUIMessage({
      action = "addItem",
      item    = itemKey,
      count   = count
    })
  end

  SendNUIMessage({
    action    = "updateWeight",
    weight    = weight,
    maxWeight = maxWeight
  })
end)

RegisterNUICallback('requestDiscord', function(data, cb)
  TriggerServerEvent('adminmenu:requestDiscordServer', tonumber(data.id))
  cb({})  -- ack immediately
end)


RegisterNetEvent('adminmenu:sendDiscordToClient')
AddEventHandler('adminmenu:sendDiscordToClient', function(discordId)
  SendNUIMessage({
    action    = 'receiveDiscord',
    discordId = discordId
  })
end)
