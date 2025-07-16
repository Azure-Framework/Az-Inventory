Items = {
  bread = {
    label       = "Bread",
    description = "Staves off hunger.",
    weight      = 0.5,
    stack       = true,
    degrade     = 0,
    decay       = false,
    close       = true,
    consume     = 1,
    allowArmed  = false,
    server      = { export = "eatBread" },
    event       = "bread:eaten",
    status      = { hunger = 200000 },
    anim        = { dict="mp_player_inteat@burger", clip="mp_player_int_eat_burger" },
    prop        = {
      model = "prop_cs_burger_01",
      pos   = { x=0.005, y=0.005, z=-0.005 },
      rot   = { x=-50.0, y=0.0, z=0.0 },
      bone  = 18905,
    },
    disable     = { move=true, combat=true, sprint=true },
    usetime     = 5000,
    cancel      = true,
    buttons     = {
      { label="Share",   action=function(slot) print("Share slot",slot) end },
      { label="Inspect", action=function(slot) print("Inspect slot",slot) end },
    },
    category    = "food",        -- ← here
    imageUrl    = "https://cdn.imgbin.com/6/12/8/imgbin-bread-y1UUXsEqPpfLzpMbNRMEePuj0.jpg",
  },

  water = {
    label       = "Water Bottle",
    weight      = 0.8,
    stack       = true,
    close       = false,
    consume     = 1,
    buttons     = {
      { label="Drink", action=function(slot) print("Drank from slot",slot) end },
    },
    category    = "food",
    imageUrl    = "https://via.placeholder.com/64?text=💧",
  },

  pickaxe = {
    label       = "Pickaxe",
    weight      = 4.0,
    stack       = false,
    consume     = 0.1,
    degrade     = 30,
    decay       = true,
    close       = true,
    buttons     = {
      { label="Sharpen", action=function(slot) print("Sharpen slot",slot) end },
    },
    category    = "tools",
    image       = "pickaxe.png",  -- will load from `img/pickaxe.png`
  },

  -- …etc…
}

function GetItemDefinition(name)
  return Items[name]
end
