-- new_client.lua (fixed + hardened)
local Items = Items or {}

local function safeCall(fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then
    print(("[new_client.lua] safeCall error: %s"):format(tostring(res)))
  end
  return ok, res
end

local function notify(text)
  if not text then return end
  local ok = pcall(function()
    TriggerEvent('ox_lib:notify', { description = text, type = 'inform' })
  end)
  if not ok then
    SetNotificationTextEntry("STRING"); AddTextComponentString(text); DrawNotification(false,false)
  end
end

-- Try multiple exports to apply statuses; returns true if something was applied
local function applyStatus(statusTable)
  if not statusTable or type(statusTable) ~= 'table' then return false end
  local applied = false

  local tries = {
    function() return exports['status'] end,
    function() return exports['status_system'] end,
    function() return exports['ox_status'] end,
    function() return exports['esx_status'] end,
  }

  for _, getter in ipairs(tries) do
    local ok, e = pcall(getter)
    if ok and e then
      for k, v in pairs(statusTable) do
        pcall(function()
          if type(e.Add) == 'function' then e.Add(k, v); applied = true end
          if type(e.add) == 'function' then e.add(k, v); applied = true end
          if type(e.Set) == 'function' then e.Set(k, v); applied = true end
          if type(e.set) == 'function' then e.set(k, v); applied = true end
        end)
      end
      if applied then return true end
    end
  end

  -- Fallback local health change
  local ped = PlayerPedId()
  for k, v in pairs(statusTable) do
    if k == "health" then
      local hp = GetEntityHealth(ped)
      local add = math.floor((tonumber(v) or 0) / 1000)
      if add > 0 then SetEntityHealth(ped, math.min(200, hp + add)); applied = true end
    end
  end

  return applied
end

-- NEW playAnim (replace old implementation)
local function playAnim(anim, duration)
  if not anim or type(anim) ~= 'table' or not anim.dict or not anim.clip then return end
  safeCall(function()
    local ped = PlayerPedId()
    local durMs = tonumber(duration) or tonumber(anim.duration) or -1

    RequestAnimDict(anim.dict)
    local tries = 0
    while not HasAnimDictLoaded(anim.dict) and tries < 100 do
      Wait(10); tries = tries + 1
    end
    if not HasAnimDictLoaded(anim.dict) then
      print(("[new_client.lua] Failed to load anim dict: %s"):format(anim.dict))
      return
    end

    -- Choose a safe default flag: 0 = normal (no loop). If the anim must loop, the caller can pass a flag in anim.flag
    local flag = anim.flag or 0
    local playbackRate = anim.playbackRate or 1.0

    -- TaskPlayAnim signature: (ped, dict, name, blendIn, blendOut, duration(ms), flag, playbackRate, lockX, lockY, lockZ)
    TaskPlayAnim(ped, anim.dict, anim.clip, anim.blendIn or 8.0, anim.blendOut or -8.0, durMs, flag, playbackRate, false, false, false)

    -- If a finite duration was provided, schedule a stop to ensure the animation is cleared.
    if durMs and durMs > 0 then
      Citizen.SetTimeout(durMs + 150, function()
        if DoesEntityExist(ped) then
          -- Stop the specific anim and clear any leftover secondary tasks
          StopAnimTask(ped, anim.dict, anim.clip, 3.0)
          ClearPedSecondaryTask(ped)
        end
      end)
    end
  end)
end




local function spawnProp(prop, duration)
  if not prop or not prop.model then return nil end
  local model = type(prop.model) == "string" and GetHashKey(prop.model) or tonumber(prop.model)
  if not model then return nil end
  safeCall(function()
    RequestModel(model)
    local tick = 0
    while not HasModelLoaded(model) and tick < 200 do Wait(10); tick = tick + 1 end
    if not HasModelLoaded(model) then
      print(("[new_client.lua] Failed to load prop model: %s"):format(tostring(prop.model)))
      return
    end
    local ped = PlayerPedId()
    local bone = prop.bone or 18905
    local px,py,pz = table.unpack(GetEntityCoords(ped))
    local obj = CreateObject(model, px, py, pz + 0.2, true, true, false)
    AttachEntityToEntity(
      obj,
      ped,
      GetPedBoneIndex(ped, bone),
      (prop.pos and prop.pos.x) or 0.0,
      (prop.pos and prop.pos.y) or 0.0,
      (prop.pos and prop.pos.z) or 0.0,
      (prop.rot and prop.rot.x) or 0.0,
      (prop.rot and prop.rot.y) or 0.0,
      (prop.rot and prop.rot.z) or 0.0,
      true, true, false, true, 1, true
    )
    if duration and tonumber(duration) and duration > 0 then
      Citizen.SetTimeout(duration + 100, function()
        if DoesEntityExist(obj) then DetachEntity(obj, true, true); DeleteObject(obj) end
      end)
    end
  end)
end

-- Proper vehicle search helper (returns vehicle entity or nil)
local function findNearestVehicle(maxDist)
  maxDist = tonumber(maxDist) or 3.5
  local ped = PlayerPedId()
  local ppos = GetEntityCoords(ped)
  local handle, veh = FindFirstVehicle()
  if not handle then return nil end
  local success = true
  local foundVeh = nil
  repeat
    if veh and DoesEntityExist(veh) then
      local vpos = GetEntityCoords(veh)
      local dist = #(ppos - vpos)
      if dist <= maxDist then
        foundVeh = veh
        break
      end
    end
    success, veh = FindNextVehicle(handle)
  until not success
  EndFindVehicle(handle)
  if foundVeh and DoesEntityExist(foundVeh) then return foundVeh end
  return nil
end

-- Handlers -------------------------------------------------------------------

-- Update handlers to pass usetime -> playAnim
RegisterNetEvent('bread:clientUse', function(itemName, qty, def)
  local d = def or (Items and Items[itemName]) or {}
  playAnim(d.anim, d.usetime or 2000)
  spawnProp(d.prop, d.usetime or 2000)
  if d.status then
    local ok = applyStatus(d.status)
    if ok then notify("You ate: " .. (d.label or itemName)) else notify("You ate something.") end
  else
    notify("You ate something.")
  end
end)

RegisterNetEvent('bandage:clientUse', function(itemName, qty, def)
  local d = def or (Items and Items[itemName]) or {}
  -- bandage uses a short anim
  playAnim(d.anim, d.usetime or 1500)
  spawnProp(d.prop, d.usetime or 1500)
  if d.status then
    applyStatus(d.status)
  else
    local ped = PlayerPedId()
    local hp = GetEntityHealth(ped)
    SetEntityHealth(ped, math.min(200, hp + 15))
  end
  notify("Applied bandage.")
end)

RegisterNetEvent('medkit:clientUse', function(itemName, qty, def)
  local d = def or (Items and Items[itemName]) or {}
  local useMs = tonumber(d.usetime) or 5000

  -- play animation for the duration (our playAnim stops it)
  playAnim(d.anim, useMs)

  -- spawn a prop attached to player and remove it after useMs
  spawnProp(d.prop, useMs)

  -- If disable flags exist, block relevant controls for the duration
  if d.disable and type(d.disable) == 'table' then
    Citizen.CreateThread(function()
      local endT = GetGameTimer() + useMs + 100
      while GetGameTimer() < endT do
        if d.disable.sprint then
          DisableControlAction(0, 21, true) -- sprint
        end
        if d.disable.move then
          DisableControlAction(0, 30, true) -- move left/right
          DisableControlAction(0, 31, true) -- move up/down
        end
        if d.disable.combat then
          DisableControlAction(0, 24, true) -- attack
          DisableControlAction(0, 25, true) -- aim
          DisableControlAction(0, 45, true) -- reload
        end
        -- optional: prevent entering vehicles
        DisableControlAction(0, 75, true) -- exit vehicle (helpful if inside)
        Citizen.Wait(0)
      end
      -- Make sure tasks/animations are cleared as a safety net
      local ped = PlayerPedId()
      if DoesEntityExist(ped) then
        if d.anim and d.anim.dict and d.anim.clip then
          StopAnimTask(ped, d.anim.dict, d.anim.clip, 3.0)
        end
        ClearPedSecondaryTask(ped)
      end
    end)
  end

  -- Apply status / health change
  if d.status then
    applyStatus(d.status)
  else
    local ped = PlayerPedId()
    local hp = GetEntityHealth(ped)
    SetEntityHealth(ped, math.min(200, hp + 80))
  end

  notify("Used medkit.")
end)

RegisterNetEvent('lockpicking:clientOpenMinigame', function(itemName, qty, def)
  local tried = false
  pcall(function()
    if exports['lockpick_ui'] and type(exports['lockpick_ui'].OpenMinigame) == 'function' then
      exports['lockpick_ui'].OpenMinigame()
      tried = true
    elseif exports['lockpick'] and type(exports['lockpick'].Start) == 'function' then
      exports['lockpick'].Start()
      tried = true
    end
  end)
  if not tried then
    TriggerEvent('lockpicking:open')
    notify("Lockpick minigame requested (no UI found).")
  end
end)

local function refuelNearestVehicle(amount)
  local veh = findNearestVehicle(3.5)
  if not veh then notify("No vehicle nearby to refuel."); return false end

  local done = false
  pcall(function()
    if exports['LegacyFuel'] and type(exports['LegacyFuel'].AddFuel) == 'function' then
      exports['LegacyFuel'].AddFuel(veh, tonumber(amount) or 25); done = true
    elseif exports['fuel'] and type(exports['fuel'].AddFuel) == 'function' then
      exports['fuel'].AddFuel(veh, tonumber(amount) or 25); done = true
    end
  end)
  if done then notify("Refueled nearby vehicle."); return true end

  -- fallback: nudge engine health
  local health = GetVehicleEngineHealth(veh)
  SetVehicleEngineHealth(veh, math.min(1000.0, health + (tonumber(amount) or 25) * 5.0))
  notify("Refueled (fallback)")
  return true
end

RegisterNetEvent('vehicle:refuel', function(itemName, qty, def)
  refuelNearestVehicle(25)
end)

RegisterNetEvent('vehicle:repair', function(itemName, qty, def)
  local veh = findNearestVehicle(3.5)
  if not veh then notify("No vehicle nearby to repair."); return false end
  SetVehicleEngineHealth(veh, math.min(1000.0, GetVehicleEngineHealth(veh) + 200.0))
  SetVehicleBodyHealth(veh, math.min(1000.0, GetVehicleBodyHealth(veh) + 200.0))
  notify("Repaired nearby vehicle.")
end)

RegisterNetEvent('inventory:statusApply', function(statusTable)
  if not statusTable or type(statusTable) ~= 'table' then return end
  local ok = applyStatus(statusTable)
  if not ok then
    local parts = {}
    for k,v in pairs(statusTable) do parts[#parts+1] = ("%s: %s"):format(k, tostring(v)) end
    notify("Status applied: " .. table.concat(parts, ", "))
  end
end)

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

  local ok, err = pcall(function()
    if exports[resourceName] and type(exports[resourceName][funcName]) == 'function' then
      return exports[resourceName][funcName](itemName, amount, def)
    elseif exports[resourceName] and type(exports[resourceName]) == 'function' then
      -- Some resources export directly as functions: exports['res'](...)
      return exports[resourceName](funcName, itemName, amount, def)
    else
      -- fallback event trigger
      TriggerEvent(resourceName .. ":" .. funcName, itemName, amount, def)
    end
  end)
  if not ok then
    print(("inventory:callClientExport - error calling %s:%s -> %s"):format(tostring(resourceName), tostring(funcName), tostring(err)))
  end
end)

exports('RefuelNearestVehicle', function(itemName, amount, def) return refuelNearestVehicle(amount) end)
exports('RepairNearestVehicle', function(itemName, amount, def)
  TriggerEvent('vehicle:repair', itemName, amount, def)
  return true
end)
exports('UseBandage', function(itemName, amount, def)
  TriggerEvent('bandage:clientUse', itemName, amount, def)
  return true
end)
exports('UseMedkit', function(itemName, amount, def)
  TriggerEvent('medkit:clientUse', itemName, amount, def)
  return true
end)

Citizen.CreateThread(function()
  Wait(100)
  print("[new_client.lua] Item client handlers loaded.")
end)
