# Az-Inventory — Weekly Change Log

_Date range covered: recent week of chat work (conversation-based recap)._

## Main focus
- Improve compatibility with resources expecting `ox_inventory`-style behavior.
- Keep original Az-Inventory behavior while broadening compatibility.

## What changed / was requested
- User wanted Az-Inventory remade so exports / events behave like `ox_inventory` enough that dependent resources “just work.”
- Backpack integration was tested and reported as not working the same way it does with ox_inventory.
- Work shifted toward matching common ox_inventory-facing exports / events so third-party resources would not need special rewrites.

## Original preservation requirements
- Keep original inventory behavior intact
- Keep `F2` opening inventory
- Add weapon image auto-resolver using FiveM weapon image paths
- Support config toggles for remote / local / placeholder image handling
- Add attachment auto-render scaffolding
- Add lazy-load and fallback handling

## Problems found during the week
- Server startup logs indicated:
  - server loaded under an ox_inventory-style name
  - server knew 0 shops
  - MySQL library not found in one run, with message to ensure `oxmysql` or `mysql-async` is installed and loaded

## Practical direction taken
- Move toward ox-compatible export names / event surfaces
- Make dependent resources like backpacks behave as if they are talking to ox_inventory
