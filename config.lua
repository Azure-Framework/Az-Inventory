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

return Config
