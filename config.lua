
Config = Config or {}


Config.Debug = Config.Debug == false


if Config.NotifyEverything == nil then Config.NotifyEverything = true end


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


Config.MaxWeight = tonumber(Config.MaxWeight) or 120.0


Config.Police = Config.Police or { "police" }
Config.AutoNotifyPolice = Config.AutoNotifyPolice ~= false
Config.UsePoliceForRequiredCount = Config.UsePoliceForRequiredCount ~= false
Config.RequiredCops = tonumber(Config.RequiredCops) or 1


Config.RobberyCooldown = tonumber(Config.RobberyCooldown) or 600
Config.RobCooldown = tonumber(Config.RobCooldown or Config.RobberyCooldown) or 600
Config.robberyCooldown = Config.RobCooldown
Config.AlertBlip = Config.AlertBlip ~= false
Config.BlipDuration = tonumber(Config.BlipDuration) or 120
Config.BlipRadius = tonumber(Config.BlipRadius) or 50
Config.AlertText = Config.AlertText or "Robbery in progress at %s"
Config.AlertTitle = Config.AlertTitle or "Robbery Alert"
Config.NotifyDistance = tonumber(Config.NotifyDistance) or 300.0


Config.Control = Config.Control or {}
Config.Control.UseKeyMapping = (Config.Control.UseKeyMapping ~= false)
Config.Control.DefaultKey = Config.Control.DefaultKey or 'F2'
Config.Control.ToggleInventory = tonumber(Config.Control.ToggleInventory) or 289


Config.VehicleStorage = Config.VehicleStorage or {}
Config.VehicleStorage.Enabled = (Config.VehicleStorage.Enabled ~= false)
Config.VehicleStorage.TrunkMaxWeight = tonumber(Config.VehicleStorage.TrunkMaxWeight) or 75.0
Config.VehicleStorage.GloveboxMaxWeight = tonumber(Config.VehicleStorage.GloveboxMaxWeight) or 12.0
Config.VehicleStorage.MaxDistance = tonumber(Config.VehicleStorage.MaxDistance) or 2.7
Config.VehicleStorage.RequireUnlocked = (Config.VehicleStorage.RequireUnlocked ~= false)
Config.VehicleStorage.OpenTrunkDoor = (Config.VehicleStorage.OpenTrunkDoor ~= false)
Config.VehicleStorage.CloseTrunkOnClose = (Config.VehicleStorage.CloseTrunkOnClose ~= false)
Config.VehicleStorage.DefaultTrunkKey = Config.VehicleStorage.DefaultTrunkKey or 'K'
Config.VehicleStorage.BlockedClasses = Config.VehicleStorage.BlockedClasses or {
  [8] = true,  
  [13] = true, 
  [14] = true, 
  [15] = true, 
  [16] = true, 
  [21] = true, 
}


Config.PersistStates = Config.PersistStates == true
Config.StateFile = Config.StateFile or "shop_states.json"


Config.RequiredWeaponItems = Config.RequiredWeaponItems or {}
Config.MaxRobDistance = tonumber(Config.MaxRobDistance) or 4.0
Config.MinReward = tonumber(Config.MinReward) or 100
Config.MaxReward = tonumber(Config.MaxReward) or 500
Config.CopJobs = Config.CopJobs or { "Police", "sheriff" }
Config.AntiSpam = Config.AntiSpam or { PerPlayerAttemptCooldown = 5 }

return Config
