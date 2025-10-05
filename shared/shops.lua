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
      blockEvents = true,
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
    ped = {
      model      = "a_m_m_farmer_01",
      coords     = vector4(2747.023, 3472.354, 55.670, 244.654),
      freeze     = true,
      invincible = true,
      blockEvents = true,
    },
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
      { name = "bandage",     price = 15 },
      { name = "painkillers", price = 25 },
    },
    ped = {
      model      = "s_m_m_doctor_01",
      coords     = vector4(196.38, -933.56, 30.69, 270.0),
      freeze     = true,
      invincible = true,
      blockEvents = true,
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
    -- no ped defined for this shop
    blip = {
      sprite = 110,       -- gun shop icon
      color  = 1,
      scale  = 0.8,
      text   = "Weapon Dealer"
    }
  },

  -- Police Armory: only accessible to police/sheriff jobs
  {
    name   = "Police Armory",
    coords = vector3(454.2, -990.1, 30.6),
    radius = 2.0,
    jobs   = { "Police", "sheriff" }, -- whole shop restricted
    items  = {
      { name = "pistol",  price = 100 },   -- allowed for police/sheriff
      { name = "rifle",   price = 1200 },  -- allowed for police/sheriff
      { name = "taser",   price = 50 },    -- allowed for police/sheriff
    },
    ped = {
      model = "s_m_y_cop_01",
      coords = vector4(454.2, -990.1, 30.6, 90.0),
      freeze = true, invincible = true, blockEvents = true
    },
    blip = {
      sprite = 60, color = 38, scale = 0.9, text = "Police Armory"
    }
  },

  -- Mechanic tools: specific items restricted to mechanics, spark_plug available to all
  {
    name   = "Mechanic Tools",
    coords = vector3(-338.1, -137.6, 38.0),
    radius = 2.0,
    -- NOTE: we do NOT set shop-level `jobs` here because we want one item (spark_plug)
    -- to be purchasable by anyone while other items require the mechanic job.
    items  = {
      { name = "repair_kit", price = 150, jobs = { "mechanic" } }, -- only mechanics
      { name = "toolbox",    price = 200, jobs = { "mechanic" } }, -- only mechanics
      { name = "spark_plug", price = 5 } -- no jobs field -> available to everyone
    },
    blip = {
      sprite = 446, color = 47, scale = 0.8, text = "Mechanic Tools"
    }
  },
}
