fx_version 'cerulean'
game        'gta5'

author       'YourName'
description  'AZ-Framework NUI Inventory'
version      '1.5.0'

shared_scripts {
  'shared/items.lua',
  'shared/shops.lua',
  'config.lua'
}

server_scripts {
  '@mysql-async/lib/MySQL.lua',  -- if you want to persist
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
