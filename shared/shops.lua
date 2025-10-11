-- shops.lua
-- Define your shops here. Each shop can include coords, radius, items,
-- optional ped definition, optional blip definition, and optional `robbable` flag.
-- By default a shop is robbable unless you explicitly set `robbable = false`.

Shops = {
  {
    name   = "General Store",
    -- keep coords for compatibility, but prefer 'locations' for multiple spots
    coords = vector3(-47.4, -1757.2, 29.4),
    locations = {
      vector3(-47.4, -1757.2, 29.4),
      vector3(25.7, -1347.3, 29.49),
      vector3(-3038.71, 585.9, 7.9),
      vector3(-3241.47, 1001.14, 12.83),
      vector3(1728.66, 6414.16, 35.03),
      vector3(1697.99, 4924.4, 42.06),
      vector3(1961.510, 3739.948, 32.344),
      vector3(547.79, 2671.79, 42.15),
      vector3(2679.25, 3280.12, 55.24),
      vector3(2557.94, 382.05, 108.62),
      vector3(373.55, 325.56, 103.56),
      
    },
    radius = 2.0,
    robbable = true, -- optional: true by default if omitted
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
      sprite = 52,
      color  = 2,
      scale  = 0.8,
      text   = "General Store"
    }
  },

  {
    name   = "Tool Shop",
    coords = vector3(2747.7, 3472.0, 55.6),
    radius = 2.0,
    robbable = true,
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
      sprite = 566,
      color  = 47,
      scale  = 0.8,
      text   = "Tool Shop"
    }
  },

  {
    name   = "Pharmacy",
    coords = vector3(196.38, -933.56, 30.69),
    radius = 1.5,
    robbable = true,
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
      sprite = 51,
      color  = 1,
      scale  = 0.8,
      text   = "Pharmacy"
    }
  },

  {
    name   = "Weapon Dealer",
    coords = vector3(-662.1, -935.3, 21.8),
    radius = 2.0,
    robbable = true,
    items  = {
      { name = "pistol",   price = 500 },
      { name = "rifle",    price = 1500 },
    },
    blip = {
      sprite = 110,
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
    robbable = false, -- police armory should NOT be robbable
    jobs   = { "Police", "sheriff" },
    items  = {
      { name = "pistol",  price = 100 },
      { name = "rifle",   price = 1200 },
      { name = "taser",   price = 50 },
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

  -- Mechanic tools: make this NOT robbable
  {
    name   = "Mechanic Tools",
    coords = vector3(-338.1, -137.6, 38.0),
    radius = 2.0,
    robbable = false, -- <- mechanic shop cannot be robbed
    items  = {
      { name = "repair_kit", price = 150, jobs = { "mechanic" } },
      { name = "toolbox",    price = 200, jobs = { "mechanic" } },
      { name = "spark_plug", price = 5 }
    },
    blip = {
      sprite = 446, color = 47, scale = 0.8, text = "Mechanic Tools"
    }
  },
}
