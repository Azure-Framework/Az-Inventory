-- config.lua
local Config = {}

-- Toggle detailed in-game notifications for every action (set false to quiet the user)
Config.NotifyEverything = true

-- Default notify configuration (change these to globally affect all notifications)
Config.Notify = {
  idPrefix     = "az_inv_",     -- used to build the default id (idPrefix .. src .. "_" .. os.time())
  title        = "Inventory",
  duration     = 3000,
  showDuration = true,
  position     = "top",         -- default position used by your ox_lib notify
  type         = "inform",      -- inform | error | success | warning
  style        = nil,
  icon         = nil,
  iconColor    = nil,
  iconAnimation= nil,
  alignIcon    = nil,
  sound        = nil,
}
-- Which job names should be considered police (string or table supported by isPoliceJob)
-- Examples: "police" or "police,sheriff" or { "police", "sheriff" }
Config.Police = { "police" }

-- If true, robbery alerts will automatically notify players whose job matches Config.Police
Config.AutoNotifyPolice = true

-- Whether the RequiredCops count should consider only Config.Police jobs
-- If false, the original behaviour (counting 'police' only) will remain unless server code is updated.
Config.UsePoliceForRequiredCount = true

-- Minimum number of online police required to allow robberies (used by server logic if implemented)
Config.RequiredCops = 1

-- Cooldown (seconds) between robberies for the same location
Config.RobberyCooldown = 600 -- 10 minutes

-- Blip/alert settings sent to police clients
Config.AlertBlip = true        -- create a temporary blip on police maps
Config.BlipDuration = 120      -- seconds the blip remains
Config.BlipRadius = 50         -- radius of the blip (if you render a radius)

-- Notification / message format
-- Use %s where you want the location/store name to be substituted.
Config.AlertText = "Robbery in progress at %s"
Config.AlertTitle = "Robbery Alert"

-- How far police clients will receive the initial client-side notification (if applicable)
Config.NotifyDistance = 300.0 -- meters
-- Robbery cooldowns (seconds)
Config.RobCooldown = 600                -- 10 minutes (client-friendly name)
Config.robberyCooldown = Config.RobCooldown -- server-friendly alias (keeps compatibility)

-- Controls (safe defaults)
Config.Control = Config.Control or {}
Config.Control.ToggleInventory = tonumber(Config.Control.ToggleInventory) or 289 -- default F2

-- Persistence for shop states
Config.PersistStates = false
Config.StateFile = "shop_states.json"

-- Gameplay options used by server.lua
Config.RequiredWeaponItems = Config.RequiredWeaponItems or {} -- e.g. { "pistol" }
Config.RequiredCops = tonumber(Config.RequiredCops) or 0
Config.MaxRobDistance = tonumber(Config.MaxRobDistance) or 4.0

-- Reward defaults
Config.MinReward = tonumber(Config.MinReward) or 100
Config.MaxReward = tonumber(Config.MaxReward) or 500

-- Cop job names (optional explicit list for police counting)
Config.CopJobs = Config.CopJobs or { "Police", "sheriff" }

-- Anti-spam options
Config.AntiSpam = Config.AntiSpam or { PerPlayerAttemptCooldown = 5 }

return Config
