# MM2 Trade Helper (Supreme Values Overlay)

A Roblox Lua script that overlays your Murder Mystery 2 trade window with totals based on Supreme Values. It auto-detects items from the trade UI heuristically and also provides a manual panel to add items if detection fails.

## Features
- Fetches multiple Supreme Values pages and builds a local values map (cached 6h).
- Shows "You Give", "They Give", and Net (They - You) with color-coded outcome.
- Heuristic scanner to read MM2 trade GUI; manual add/search fallback.
- Executor-friendly HTTP (syn.request/http_request/request) and file cache.

## How to use
1. Copy the contents of `mm2_trade_helper.lua` to your Roblox executor while in an MM2 server.
2. Ensure your executor supports HTTP requests and file APIs for caching.
3. Run the script. A window titled "MM2 Trade Helper" will appear.
4. Start/receive a trade:
   - If the script detects your items, it will update automatically every ~1s.
   - If not, click "Manual Panel" and search items. Use "+ You" / "+ Them" to add quantities.

## Tips
- Values are scraped from `supremevaluelist.com`. Layout changes may require updating the parser.
- If HTTP is blocked in your executor, the overlay will still load but without values.
- Cache file path: `mm2_trade_helper/cache/mm2_values.json` (created automatically).

## Disclaimer
- This tool is for informational assistance only. It does not guarantee profits and may have inaccuracies if the game UI or Supreme Values pages change.
- Respect the game's and platform's terms of service. Use at your own risk.