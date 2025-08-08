-- MM2 Trade Helper - Supreme Values Overlay
-- Executor-friendly Lua script (supports synapse, script-ware, krnl, etc.)
-- Features:
--  - Fetches and caches Supreme Values for MM2 items (multiple categories)
--  - Auto-totals Your vs. Their offers in trade UI; color-coded net outcome
--  - Heuristic auto-detection of items from MM2 trade GUI; remote hook fallback stub
--  - Manual add/search UI for when auto-detection fails
--  - Local cache with TTL to reduce requests
--
-- Notes:
--  - In live games, Roblox HttpService usually cannot be used by client scripts. This script uses
--    executor HTTP request APIs (syn.request, http_request, request) if available.
--  - DOM/GUI structure of MM2 may change; the auto-detection is best-effort. Use manual panel when needed.
--  - Supreme Values site may update HTML layout; parser is resilient but not guaranteed.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------
-- Compatibility wrappers (HTTP, FS, UI parenting)
---------------------------------------------------------------------
local function getHttpRequest()
    return (syn and syn.request)
        or (http and http.request)
        or (request)
        or (fluxus and fluxus.request)
        or (KRNL_LOADED and http_request)
        or (jit and http and http.request)
        or nil
end

local httpRequest = getHttpRequest()

local function jsonEncode(tbl)
    local ok, res = pcall(function()
        return HttpService:JSONEncode(tbl)
    end)
    return ok and res or "{}"
end

local function jsonDecode(str)
    if type(str) ~= "string" then return nil end
    local ok, res = pcall(function()
        return HttpService:JSONDecode(str)
    end)
    return ok and res or nil
end

local function hasFileApi()
    return (typeof(isfolder) == "function" and typeof(makefolder) == "function" and typeof(writefile) == "function" and typeof(readfile) == "function")
end

local function safeReadFile(path)
    if hasFileApi() then
        local ok, res = pcall(function() return readfile(path) end)
        if ok then return res end
    end
    return nil
end

local function safeWriteFile(path, content)
    if hasFileApi() then
        pcall(function()
            local dir = path:match("^(.*)/")
            if dir and dir ~= "" then
                if not isfolder(dir) then pcall(makefolder, dir) end
            end
            writefile(path, content)
        end)
    end
end

local function getUiParent()
    local ok, hui = pcall(function()
        if gethui then return gethui() end
        return nil
    end)
    if ok and hui then return hui end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
    return pg
end

local function log(msg)
    print("[MM2 Trade Helper] " .. tostring(msg))
end

---------------------------------------------------------------------
-- Supreme Values fetch and parse
---------------------------------------------------------------------
local SUPREME_BASE = "https://supremevaluelist.com/mm2/"
local SUPREME_ENDPOINTS = {
    "ancients.html",
    "godlies.html",
    "chromas.html",
    "vintages.html",
    "legendaries.html",
    "rares.html",
    "uncommons.html",
    "commons.html",
    "pets.html",
    "misc.html",
    "evos.html",
    "uniques.html",
    -- sets.html exists but are combos; we still parse in case useful
    "sets.html",
}

local CACHE_PATH = "mm2_trade_helper/cache/mm2_values.json"
local CACHE_TTL_SECONDS = 6 * 60 * 60 -- 6 hours

local function normalizeItemName(name)
    if not name or name == "" then return nil end
    local lowered = string.lower(name)
    lowered = lowered:gsub("%b()", "") -- remove parenthetical like (Knife)
    lowered = lowered:gsub("[^%w%s]", "") -- remove punctuation
    lowered = lowered:gsub("%s+", " ")
    lowered = lowered:match("^%s*(.-)%s*$") or lowered
    return lowered
end

local function tonumberValue(str)
    if not str then return nil end
    local cleaned = tostring(str):gsub(",", "")
    local num = tonumber(cleaned)
    return num
end

local function parseSupremeHtml(html)
    -- Returns map: normalizedName -> { displayName = string, value = number|nil, flags = table }
    -- Simple pattern approach: search for table rows with "| Name ... Value - **123**"
    local valuesMap = {}
    if type(html) ~= "string" then return valuesMap end

    -- Iterate over potential row lines
    for line in html:gmatch("[^\n]+") do
        -- Example line segment:
        -- | ![Zombified Knife](...) | Zombified (Knife) ...  Value - **65**
        local name = line:match("%|%s*%!%[[^%]]-%]%([^%)]+%)%s*%|%s*([^|]-)Value%s*%-%s*%*%*[

]?([%d,]+)%*%*")
        if not name then
            -- Try a more forgiving pattern (no image requirement): "| something | Name ... Value - **123**"
            name = line:match("%|%s*[^|]-%|%s*([^|]-)Value%s*%-%s*%*%*[

]?([%d,]+)%*%*")
        end
        if name then
            local valStr = line:match("Value%s*%-%s*%*%*([%d,]+)%*%*")
            local num = tonumberValue(valStr)
            local cleanName = name
            -- drop badges or images text remnants
            cleanName = cleanName:gsub("!%[[^%]]-%]", "")
            cleanName = cleanName:gsub("%b()", function(s)
                -- keep parentheses for alias cleanup later; remove if generic types
                if s:match("%((Knife)%)") or s:match("%((Gun)%)") then return "" end
                return s
            end)
            cleanName = cleanName:gsub("%s+", " ")
            cleanName = cleanName:match("^%s*(.-)%s*$") or cleanName

            if cleanName ~= "" and num then
                local norm = normalizeItemName(cleanName)
                if norm and not valuesMap[norm] then
                    valuesMap[norm] = { displayName = cleanName, value = num, flags = {} }
                end
            end
        else
            -- Handle lines with "Value - **Priceless**" or **N/A** by skipping numeric
            local altName = line:match("%|%s*[^|]-%|%s*([^|]-)Value%s*%-%s*%*%*([%a/ ]+)%*%*")
            if altName then
                local cleanName = altName:gsub("!%[[^%]]-%]", "")
                cleanName = cleanName:gsub("%b()", function(s)
                    if s:match("%((Knife)%)") or s:match("%((Gun)%)") then return "" end
                    return s
                end)
                cleanName = cleanName:gsub("%s+", " ")
                cleanName = cleanName:match("^%s*(.-)%s*$") or cleanName
                local norm = normalizeItemName(cleanName)
                if norm and not valuesMap[norm] then
                    valuesMap[norm] = { displayName = cleanName, value = nil, flags = { special = true } }
                end
            end
        end
    end

    return valuesMap
end

local function mergeMaps(dst, src)
    for k, v in pairs(src or {}) do
        if not dst[k] then
            dst[k] = v
        elseif type(v.value) == "number" and type(dst[k].value) ~= "number" then
            dst[k] = v
        end
    end
end

local function fetchAllValues(forceRefresh)
    -- Return cached if present and fresh
    if not forceRefresh then
        local cache = safeReadFile(CACHE_PATH)
        if cache then
            local obj = jsonDecode(cache)
            if obj and obj.values and obj._fetchedAt then
                local age = os.time() - tonumber(obj._fetchedAt or 0)
                if age >= 0 and age < CACHE_TTL_SECONDS then
                    return obj.values
                end
            end
        end
    end

    if not httpRequest then
        log("No HTTP request API available in executor. Using empty value map.")
        return {}
    end

    local aggregated = {}

    for _, endpoint in ipairs(SUPREME_ENDPOINTS) do
        local url = SUPREME_BASE .. endpoint
        local ok, res = pcall(function()
            return httpRequest({
                Url = url,
                Method = "GET",
                Headers = {
                    ["User-Agent"] = "MM2TradeHelper/1.0",
                    ["Accept"] = "text/html,application/xhtml+xml",
                }
            })
        end)
        if ok and res and (res.StatusCode == 200 or res.StatusCode == 0) and res.Body then
            local parsed = parseSupremeHtml(res.Body)
            mergeMaps(aggregated, parsed)
            task.wait(0.05)
        else
            log("Failed to fetch: " .. tostring(url) .. " status=" .. tostring(res and res.StatusCode))
        end
    end

    -- Cache to disk
    local payload = {
        _fetchedAt = os.time(),
        values = aggregated,
    }
    safeWriteFile(CACHE_PATH, jsonEncode(payload))

    return aggregated
end

---------------------------------------------------------------------
-- UI construction
---------------------------------------------------------------------
local Theming = {
    primary = Color3.fromRGB(25, 25, 30),
    secondary = Color3.fromRGB(34, 34, 42),
    accent = Color3.fromRGB(0, 170, 255),
    success = Color3.fromRGB(60, 200, 90),
    danger = Color3.fromRGB(220, 70, 70),
    warning = Color3.fromRGB(255, 170, 0),
    text = Color3.fromRGB(235, 235, 235),
    muted = Color3.fromRGB(150, 150, 160),
}

local function create(instance, props, children)
    local obj = Instance.new(instance)
    for k, v in pairs(props or {}) do
        obj[k] = v
    end
    for _, child in ipairs(children or {}) do
        child.Parent = obj
    end
    return obj
end

local Overlay = {}
Overlay.__index = Overlay

function Overlay.new()
    local self = setmetatable({}, Overlay)

    local parent = getUiParent()
    local gui = create("ScreenGui", {
        Name = "MM2_TradeHelper",
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        ResetOnSpawn = false,
        Parent = parent,
        DisplayOrder = 1000,
        IgnoreGuiInset = true,
    })

    local root = create("Frame", {
        Name = "Root",
        Parent = gui,
        BackgroundColor3 = Theming.primary,
        BorderSizePixel = 0,
        Size = UDim2.new(0, 360, 0, 140),
        Position = UDim2.new(0.5, -180, 0.1, 0),
        Active = true,
        Draggable = true,
    })

    create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = root})
    create("UIStroke", {Color = Theming.accent, Thickness = 1, Parent = root})

    local title = create("TextLabel", {
        Name = "Title",
        Parent = root,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -10, 0, 24),
        Position = UDim2.new(0, 8, 0, 6),
        Font = Enum.Font.GothamBold,
        Text = "MM2 Trade Helper",
        TextColor3 = Theming.text,
        TextSize = 18,
        TextXAlignment = Enum.TextXAlignment.Left,
    })

    local totals = create("Frame", {
        Name = "Totals",
        Parent = root,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -16, 0, 80),
        Position = UDim2.new(0, 8, 0, 34),
    })

    local function makeRow(y, labelText)
        local row = create("Frame", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 22),
            Position = UDim2.new(0, 0, 0, y),
        })
        local l = create("TextLabel", {
            BackgroundTransparency = 1,
            Size = UDim2.new(0, 120, 1, 0),
            Font = Enum.Font.Gotham,
            Text = labelText,
            TextColor3 = Theming.muted,
            TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
        local v = create("TextLabel", {
            Name = "Value",
            BackgroundTransparency = 1,
            Size = UDim2.new(1, -130, 1, 0),
            Position = UDim2.new(0, 130, 0, 0),
            Font = Enum.Font.GothamBold,
            Text = "-",
            TextColor3 = Theming.text,
            TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Right,
        })
        l.Parent = row
        v.Parent = row
        return row, v
    end

    local rowYou, youVal = makeRow(0, "You Give")
    local rowThem, themVal = makeRow(26, "They Give")
    local rowNet, netVal = makeRow(52, "Net (They - You)")

    rowYou.Parent = totals
    rowThem.Parent = totals
    rowNet.Parent = totals

    local status = create("TextLabel", {
        Name = "Status",
        Parent = root,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -16, 0, 20),
        Position = UDim2.new(0, 8, 1, -24),
        Font = Enum.Font.GothamSemibold,
        Text = "Loading values…",
        TextColor3 = Theming.muted,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    })

    local toggle = create("TextButton", {
        Name = "ToggleManual",
        Parent = root,
        BackgroundColor3 = Theming.secondary,
        Size = UDim2.new(0, 110, 0, 24),
        Position = UDim2.new(1, -118, 0, 6),
        AutoButtonColor = true,
        Font = Enum.Font.Gotham,
        Text = "Manual Panel",
        TextColor3 = Theming.text,
        TextSize = 14,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = toggle})

    -- Manual panel
    local manual = create("Frame", {
        Name = "Manual",
        Parent = root,
        BackgroundColor3 = Theming.secondary,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -16, 0, 0),
        Position = UDim2.new(0, 8, 0, 140),
        ClipsDescendants = true,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = manual})

    local manualOpen = false

    local function setManualOpen(open)
        manualOpen = open
        root.Size = UDim2.new(0, 360, 0, open and 320 or 140)
        manual.Size = UDim2.new(1, -16, 0, open and 170 or 0)
    end

    toggle.MouseButton1Click:Connect(function()
        setManualOpen(not manualOpen)
    end)

    -- Manual content: search box + two lists (You/Them) add/remove
    local search = create("TextBox", {
        Parent = manual,
        BackgroundColor3 = Theming.primary,
        Size = UDim2.new(1, -16, 0, 26),
        Position = UDim2.new(0, 8, 0, 8),
        ClearTextOnFocus = false,
        PlaceholderText = "Search item (e.g., Luger, Icewing)",
        Font = Enum.Font.Gotham,
        Text = "",
        TextColor3 = Theming.text,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = search})

    local results = create("ScrollingFrame", {
        Parent = manual,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, -16, 0, 80),
        Position = UDim2.new(0, 8, 0, 40),
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(),
    })

    create("UIListLayout", {Parent = results, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4)})

    local function makeResultRow(name, value, onAddYou, onAddThem)
        local row = create("Frame", {BackgroundColor3 = Theming.primary, Size = UDim2.new(1, 0, 0, 24)})
        create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = row})
        create("TextLabel", {
            Parent = row,
            BackgroundTransparency = 1,
            Size = UDim2.new(1, -160, 1, 0),
            Position = UDim2.new(0, 8, 0, 0),
            Font = Enum.Font.Gotham,
            Text = string.format("%s  |  %s", name, value and ("V=" .. value) or "V=?"),
            TextColor3 = Theming.text,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
        })
        local addYou = create("TextButton", {Parent = row, BackgroundColor3 = Theming.accent, Size = UDim2.new(0, 70, 0, 20), Position = UDim2.new(1, -150, 0.5, -10), Text = "+ You", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.Gotham, TextSize = 14})
        local addThem = create("TextButton", {Parent = row, BackgroundColor3 = Theming.accent, Size = UDim2.new(0, 70, 0, 20), Position = UDim2.new(1, -74, 0.5, -10), Text = "+ Them", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.Gotham, TextSize = 14})
        create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = addYou})
        create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = addThem})
        addYou.MouseButton1Click:Connect(onAddYou)
        addThem.MouseButton1Click:Connect(onAddThem)
        return row
    end

    local manualList = {
        you = {},
        them = {},
    }

    local function recalcManual()
        local y = 0
        for _, child in ipairs(results:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end
        results.CanvasSize = UDim2.new(0, 0, 0, 0)

        -- results populated by search; handled below
    end

    local youList = create("TextLabel", {
        Parent = manual,
        BackgroundTransparency = 1,
        Size = UDim2.new(0.5, -12, 0, 20),
        Position = UDim2.new(0, 8, 1, -26),
        Font = Enum.Font.Gotham,
        Text = "You: 0",
        TextColor3 = Theming.muted,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
    local themList = create("TextLabel", {
        Parent = manual,
        BackgroundTransparency = 1,
        Size = UDim2.new(0.5, -12, 0, 20),
        Position = UDim2.new(0.5, 4, 1, -26),
        Font = Enum.Font.Gotham,
        Text = "Them: 0",
        TextColor3 = Theming.muted,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
    })

    function Overlay:UpdateTotals(youTotal, themTotal)
        local net = (themTotal or 0) - (youTotal or 0)
        youVal.Text = (youTotal and ("" .. youTotal)) or "-"
        themVal.Text = (themTotal and ("" .. themTotal)) or "-"
        netVal.Text = tostring(net)
        if net > 0 then
            netVal.TextColor3 = Theming.success
            status.Text = "Outcome: WIN"
            status.TextColor3 = Theming.success
        elseif net < 0 then
            netVal.TextColor3 = Theming.danger
            status.Text = "Outcome: LOSS"
            status.TextColor3 = Theming.danger
        else
            netVal.TextColor3 = Theming.warning
            status.Text = "Outcome: FAIR"
            status.TextColor3 = Theming.warning
        end
    end

    function Overlay:SetStatus(text)
        status.Text = text
        status.TextColor3 = Theming.muted
    end

    -- Public fields for manual entries
    self.gui = gui
    self.root = root
    self.youVal = youVal
    self.themVal = themVal
    self.netVal = netVal
    self.status = status
    self.manual = manual
    self.search = search
    self.results = results
    self.manualList = manualList
    self.youListLabel = youList
    self.themListLabel = themList
    self.setManualOpen = setManualOpen

    return self
end

---------------------------------------------------------------------
-- Trade detection heuristics
---------------------------------------------------------------------
local Detector = {}
Detector.__index = Detector

function Detector.new(valuesLookup, overlay)
    local self = setmetatable({}, Detector)
    self.valuesLookup = valuesLookup or function() return nil end
    self.overlay = overlay

    self.currentYou = {}
    self.currentThem = {}

    self.connections = {}

    return self
end

local function sumValues(items, lookup)
    local total = 0
    for _, itemName in ipairs(items) do
        local norm = normalizeItemName(itemName)
        local info = norm and lookup(norm)
        if info and type(info.value) == "number" then
            total = total + info.value
        end
    end
    return total
end

function Detector:updateOverlay()
    local youTotal = sumValues(self.currentYou, self.valuesLookup)
    local themTotal = sumValues(self.currentThem, self.valuesLookup)
    self.overlay:UpdateTotals(youTotal, themTotal)
end

function Detector:clear()
    self.currentYou = {}
    self.currentThem = {}
    self:updateOverlay()
end

function Detector:push(side, name)
    if not name or name == "" then return end
    if side == "you" then table.insert(self.currentYou, name) else table.insert(self.currentThem, name) end
    self:updateOverlay()
end

-- Try to infer MM2 trade UI grids by scanning TextLabels and common containers
local function findTradeGui()
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end

    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") or gui:IsA("BillboardGui") or gui:IsA("SurfaceGui") then
            -- Look for a frame with keywords
            local yourLabel
            local theirLabel
            for _, desc in ipairs(gui:GetDescendants()) do
                if desc:IsA("TextLabel") then
                    local text = desc.Text and desc.Text:lower() or ""
                    if text:find("your offer") or text:find("you give") then
                        yourLabel = desc
                    elseif text:find("their offer") or text:find("they give") then
                        theirLabel = desc
                    end
                end
            end
            if yourLabel and theirLabel then
                return gui, yourLabel, theirLabel
            end
        end
    end

    return nil
end

local function extractNamesFromContainer(container)
    -- Heuristic: children frames for items may include TextLabel with item name, or have Name attribute
    local names = {}
    for _, d in ipairs(container:GetDescendants()) do
        if d:IsA("TextLabel") then
            local t = d.Text
            if t and #t > 0 and #t <= 35 then
                -- exclude generic words
                local lower = t:lower()
                if not lower:find("offer") and not lower:find("accept") and not lower:find("decline") and not lower:find("ready") then
                    -- likely an item name
                    table.insert(names, t)
                end
            end
        elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
            -- Sometimes item name may be stored as an attribute
            local attrName = d:GetAttribute("ItemName") or d:GetAttribute("Name")
            if type(attrName) == "string" and #attrName > 0 then
                table.insert(names, attrName)
            end
        end
    end
    return names
end

function Detector:startHeuristicScan()
    -- Poll for trade GUI and update items periodically
    task.spawn(function()
        while self.overlay and self.overlay.gui.Parent do
            local gui, yourLabel, theirLabel = findTradeGui()
            if gui and yourLabel and theirLabel then
                -- Find containers near labels
                local yourContainer = yourLabel.Parent
                local theirContainer = theirLabel.Parent
                if yourContainer and theirContainer then
                    local youNames = extractNamesFromContainer(yourContainer)
                    local themNames = extractNamesFromContainer(theirContainer)
                    self.currentYou = youNames
                    self.currentThem = themNames
                    self:updateOverlay()
                    self.overlay:SetStatus("Tracking trade UI (heuristic)")
                end
            else
                self.overlay:SetStatus("Trade UI not found. Use Manual Panel.")
            end
            task.wait(1.0)
        end
    end)
end

-- Placeholder for remote event hook (advanced). Requires specific game internals.
function Detector:startRemoteHook()
    -- Intentionally left minimal; MM2 may obfuscate remotes.
    -- If you know the remote event and payload, hook __namecall to capture offers and call self:push(side, name)
end

---------------------------------------------------------------------
-- Main bootstrap
---------------------------------------------------------------------
local overlay = Overlay.new()

local valueMap = nil
local function lookup(normName)
    return valueMap and valueMap[normName] or nil
end

-- Populate manual search from value map
local function wireManualSearch()
    local searchBox = overlay.search
    local results = overlay.results

    local function clearResults()
        for _, child in ipairs(results:GetChildren()) do
            if child:IsA("Frame") then child:Destroy() end
        end
        results.CanvasSize = UDim2.new(0, 0, 0, 0)
    end

    local function refreshResults(query)
        clearResults()
        if not valueMap or not query or query == "" then return end
        query = normalizeItemName(query or "") or ""
        local count = 0
        for norm, info in pairs(valueMap) do
            if norm:find(query, 1, true) then
                count += 1
                local row = (function()
                    return makeResultRow(
                        info.displayName,
                        info.value,
                        function() overlay.manualList.you[info.displayName] = (overlay.manualList.you[info.displayName] or 0) + 1 end,
                        function() overlay.manualList.them[info.displayName] = (overlay.manualList.them[info.displayName] or 0) + 1 end
                    )
                end)()
                row.Parent = results
            end
            if count >= 50 then break end
        end
        results.CanvasSize = UDim2.new(0, 0, 0, count * 28)
    end

    local recalcTotalsConn
    recalcTotalsConn = RunService.RenderStepped:Connect(function()
        -- Update manual counts to overlay totals
        local youTotal = 0
        local themTotal = 0
        local youCount = 0
        local themCount = 0
        for name, qty in pairs(overlay.manualList.you) do
            youCount += qty
            local info = lookup(normalizeItemName(name))
            if info and type(info.value) == "number" then
                youTotal += info.value * qty
            end
        end
        for name, qty in pairs(overlay.manualList.them) do
            themCount += qty
            local info = lookup(normalizeItemName(name))
            if info and type(info.value) == "number" then
                themTotal += info.value * qty
            end
        end
        overlay.youListLabel.Text = "You: " .. tostring(youCount)
        overlay.themListLabel.Text = "Them: " .. tostring(themCount)
        overlay:UpdateTotals(youTotal, themTotal)
    end)

    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        refreshResults(searchBox.Text)
    end)
end

-- Fetch values asynchronously
spawn(function()
    overlay:SetStatus("Fetching Supreme Values…")
    valueMap = fetchAllValues(false)
    local count = 0
    for _ in pairs(valueMap) do count += 1 end
    overlay:SetStatus("Loaded values: " .. tostring(count))
    wireManualSearch()

    local detector = Detector.new(function(norm)
        return valueMap[norm]
    end, overlay)

    detector:startHeuristicScan()
    -- detector:startRemoteHook() -- advanced users can implement per their findings
end)

log("Loaded. Toggle Manual Panel to add items if auto-detection fails.")