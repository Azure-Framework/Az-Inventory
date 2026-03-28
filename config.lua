Config = Config or {}

-- General debug
Config.Debug = Config.Debug == true

-- Toggle detailed in-game notifications for every action (set false to quiet the user)
if Config.NotifyEverything == nil then Config.NotifyEverything = true end

-- Default notify configuration (change these to globally affect all notifications)
Config.Notify = Config.Notify or {
  idPrefix      = "az_inv_",
  title         = "Inventory",
  duration      = 3000,
  showDuration  = true,
  position      = "top",
  type          = "inform",
  style         = nil,
  icon          = nil,
  iconColor     = nil,
  iconAnimation = nil,
  alignIcon     = nil,
  sound         = nil,
}

-- Base player carry weight
Config.MaxWeight = tonumber(Config.MaxWeight) or 120.0

-- Which job names should be considered police
Config.Police = Config.Police or { "police" }
Config.AutoNotifyPolice = Config.AutoNotifyPolice ~= false
Config.UsePoliceForRequiredCount = Config.UsePoliceForRequiredCount ~= false
Config.RequiredCops = tonumber(Config.RequiredCops) or 1

-- Robbery settings
Config.RobberyCooldown = tonumber(Config.RobberyCooldown) or 600
Config.RobCooldown = tonumber(Config.RobCooldown or Config.RobberyCooldown) or 600
Config.robberyCooldown = Config.RobCooldown
Config.AlertBlip = Config.AlertBlip ~= false
Config.BlipDuration = tonumber(Config.BlipDuration) or 120
Config.BlipRadius = tonumber(Config.BlipRadius) or 50
Config.AlertText = Config.AlertText or "Robbery in progress at %s"
Config.AlertTitle = Config.AlertTitle or "Robbery Alert"
Config.NotifyDistance = tonumber(Config.NotifyDistance) or 300.0

-- Controls
Config.Control = Config.Control or {}
Config.Control.UseKeyMapping = (Config.Control.UseKeyMapping ~= false)
Config.Control.DefaultKey = Config.Control.DefaultKey or 'F2'
Config.Control.ToggleInventory = tonumber(Config.Control.ToggleInventory) or 289

-- Vehicle storage
Config.VehicleStorage = Config.VehicleStorage or {}
Config.VehicleStorage.Enabled = (Config.VehicleStorage.Enabled ~= false)
Config.VehicleStorage.TrunkMaxWeight = tonumber(Config.VehicleStorage.TrunkMaxWeight) or 75.0
Config.VehicleStorage.GloveboxMaxWeight = tonumber(Config.VehicleStorage.GloveboxMaxWeight) or 12.0
Config.VehicleStorage.MaxDistance = tonumber(Config.VehicleStorage.MaxDistance) or 2.7
Config.VehicleStorage.RequireUnlocked = (Config.VehicleStorage.RequireUnlocked ~= false)
Config.VehicleStorage.OpenTrunkDoor = (Config.VehicleStorage.OpenTrunkDoor ~= false)
Config.VehicleStorage.CloseTrunkOnClose = (Config.VehicleStorage.CloseTrunkOnClose ~= false)
Config.VehicleStorage.DefaultTrunkKey = Config.VehicleStorage.DefaultTrunkKey or 'K'
Config.VehicleStorage.DefaultGloveboxKey = Config.VehicleStorage.DefaultGloveboxKey or 'L'
Config.VehicleStorage.BlockedClasses = Config.VehicleStorage.BlockedClasses or {
  [8] = true,  -- motorcycles
  [13] = true, -- cycles
  [14] = true, -- boats
  [15] = true, -- helicopters
  [16] = true, -- planes
  [21] = true, -- trains
}

-- Persistence for shop states
Config.PersistStates = Config.PersistStates == true
Config.StateFile = Config.StateFile or "shop_states.json"

-- Gameplay options used by server.lua
Config.RequiredWeaponItems = Config.RequiredWeaponItems or {}
Config.MaxRobDistance = tonumber(Config.MaxRobDistance) or 4.0
Config.MinReward = tonumber(Config.MinReward) or 100
Config.MaxReward = tonumber(Config.MaxReward) or 500
Config.CopJobs = Config.CopJobs or { "Police", "sheriff" }
Config.AntiSpam = Config.AntiSpam or { PerPlayerAttemptCooldown = 5 }

return Config
