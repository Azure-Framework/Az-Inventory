fx_version 'cerulean'
game        'gta5'

author       'Azure(TheStoicBear)'
description  'AZ-Framework NUI Inventory'
version      '2.1.0'

shared_scripts {
  'shared/items.lua',
  'shared/shops.lua'
}

server_scripts {
  '@mysql-async/lib/MySQL.lua',
  'server/main.lua'
}

client_scripts {
  'client/main.lua'
}

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/style.css',
  'html/app.js',
  'html/img/*.png'
}
