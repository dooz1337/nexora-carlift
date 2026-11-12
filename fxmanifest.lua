fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'carlift'
author 'fs'
description 'Car lifts: admin-placed networked platforms (DB persisted); mechanics lock a vehicle onto the platform and raise/lower it'
version '1.1.0'

dependencies {
    'es_extended',
    'oxmysql',
    'ox_lib',
    'ox_target',
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'locales/locale.lua',
    'locales/en.lua',
    'locales/hu.lua',
}

client_scripts {
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}
