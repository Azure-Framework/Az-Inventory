fx_version 'cerulean'
game 'gta5'

author 'YourName'
description 'AZ-Framework NUI Inventory'
version '1.4.1'

-- ox_lib is used for progress bars / notify in item definitions
shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'shared/items.lua',
  'shared/shops.lua'
}

client_scripts {
  'client/main.lua'
}

-- If you use a different SQL library, swap this.
-- This provides MySQL.Sync.* which the server script uses.
server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua'
}

ui_page 'html/index.html'

files {
  'html/index.html'
}
