fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'MadebyAzure, Zhahna'
description 'AZ-Framework NUI Inventory'
version '1.4.1'



shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'shared/items.lua',
  'shared/shops.lua'
}

client_scripts {
  'client/main.lua'
}



server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua'
}

ui_page 'html/index.html'

files {
  'html/index.html'
}
