-- shops.lua

-- Define your shops here. Each shop can include coords, radius, items,
-- optional ped definition, and optional blip definition.
Shops = {
  {
    name   = "General Store",
    coords = vector3(-47.4, -1757.2, 29.4),
    radius = 2.0,
    items  = {
      { name = "bread",  price = 5 },
      { name = "water",  price = 3 },
      { name = "pickaxe", price = 50 },
    },
    ped = {
      model      = "a_m_m_farmer_01",
      coords     = vector4(-47.4, -1757.2, 29.4, 158.0),
      freeze     = true,
      invincible = true,
      blockEvents= true,
    },
    blip = {
      sprite = 52,        -- default store icon
      color  = 2,         -- green
      scale  = 0.8,
      text   = "General Store"
    }
  },

  {
    name   = "Tool Shop",
    coords = vector3(2747.7, 3472.0, 55.6),
    radius = 2.0,
    items  = {
      { name = "pickaxe", price = 45 },
      { name = "bread",   price = 2 },
    },
    -- no ped here, so no NPC will spawn
    blip = {
      sprite = 566,       -- wrench icon
      color  = 47,        -- dark orange
      scale  = 0.8,
      text   = "Tool Shop"
    }
  },

  {
    name   = "Pharmacy",
    coords = vector3(196.38, -933.56, 30.69),
    radius = 1.5,
    items  = {
      { name = "bandage",   price = 15 },
      { name = "painkillers", price = 25 },
    },
    ped = {
      model      = "s_m_m_doctor_01",
      coords     = vector4(196.38, -933.56, 30.69, 270.0),
      freeze     = true,
      invincible = true,
      blockEvents= true,
    },
    blip = {
      sprite = 51,        -- pharmacy icon
      color  = 1,         -- blue
      scale  = 0.8,
      text   = "Pharmacy"
    }
  },

  {
    name   = "Weapon Dealer",
    coords = vector3(-662.1, -935.3, 21.8),
    radius = 2.0,
    items  = {
      { name = "pistol",   price = 500 },
      { name = "rifle",    price = 1500 },
    },
    -- optional ped omitted
    blip = {
      sprite = 110,       -- gun shop icon
      color  = 1,
      scale  = 0.8,
      text   = "Weapon Dealer"
    }
  },
}
