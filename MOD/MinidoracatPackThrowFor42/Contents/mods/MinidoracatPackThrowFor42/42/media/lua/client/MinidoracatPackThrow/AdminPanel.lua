-- Pack & Throw (client): the admin panel, opened from the family Dock (MinidoracatUIFor42 rev 18).
--   Records: search by capsule id or player, state chips (crash-uncertain and "not seen for a week" among them), one
--     page of 50 rows from the server index, and the detail of the selected capsule: timeline, cargo list, last
--     sighting, go to the recorded spot or to the last sighting, restore, and the verdicts "car is there, close" /
--     "car is gone" for records a crash left uncertain.
--     Every action is a server command (server/AdminCommands.lua) checked there; this file only shows replies.
--   Settings, Types and Loot: every sandbox option of the mod (Settings: return an empty one, who can pack, the
--     zombie radius of the capsule sound, taking cargo out, animals, the wild catch chance and its three bonuses, days
--     to keep closed records; Types: per capsule type and Pal Sphere tier the use and loot switches, "List..." into
--     Minidoracat Economy's shop and a preview played here only; Loot: the master switch and the seven places (four
--     for capsules, three for spheres) with their weights). They are the sandbox options of the vanilla sandbox pages
--     and are sent the same way (copy, set, sendToServer; ISServerSandboxOptionsUI.lua:762-771), so the server checks
--     Capability.SandboxOptions; server/Loot.lua rebuilds the loot tables within a second.
--   The window is opaque (text over other windows stayed under 4.5:1; design vcap-types-1012 review).
-- Entry: Dock (visible for admins, player option "show in the Dock"); without the Dock, the world context menu.
require "MinidoracatPackThrow/Core"
require "MinidoracatPackThrow/Info"
require "MinidoracatPackThrow/UIKit"
require "MinidoracatPackThrow/ThrowCursor"
require "MinidoracatPackThrow/Effects"
require "PZAPI/ModOptions"
local M = MinidoracatPackThrow
local Info, Kit = M.Info, M.UIKit
local Panel = {}
M.AdminPanel = Panel

local function U(key, a, b, c)
    local k = "UI_MinidoracatPackThrow_" .. key
    if a == nil then return getText(k) end
    if b == nil then return getText(k, a) end
    if c == nil then return getText(k, a, b) end
    return getText(k, a, b, c)
end
Panel.U = U

-- Client-side gate for showing the entry; the server checks every command again.
function Panel.isAdmin(player)
    if not player then return false end
    if not isClient() then return true end
    local role = player:getRole()
    return role ~= nil and Capability ~= nil and role:hasCapability(Capability.ManipulateVehicle) == true
end

function Panel.canEditSandbox(player)
    if not player then return false end
    if not isClient() then return true end
    local role = player:getRole()
    return role ~= nil and Capability ~= nil and role:hasCapability(Capability.SandboxOptions) == true
end

-- ---------------------------------------------------------------- server link

local COMMANDS = { adminPage = true, adminDetail = true, adminResolve = true, adminRestore = true }

function Panel.send(cmd, args)
    local player = getSpecificPlayer(0)
    if not player then return end
    if isClient() then
        sendClientCommand(player, M.MODULE, cmd, args)
    elseif M.AdminCommands then -- SP: same handler, same reply path
        Panel.onReply(cmd, M.AdminCommands.handle(player, cmd, args) or { ok = false, why = "ERROR" })
    end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= M.MODULE or not COMMANDS[command] or type(args) ~= "table" then return end
    Panel.onReply(command, args)
end)

-- ---------------------------------------------------------------- player option and entry

local showDock = true
local docked = false

local function registerOptions()
    local options = PZAPI.ModOptions:getOptions("MinidoracatPackThrow")
    if options == nil then
        options = PZAPI.ModOptions:create("MinidoracatPackThrow", "UI_MinidoracatPackThrow_OptionsTitle")
        options:addTickBox("ShowDock", "UI_MinidoracatPackThrow_OptShowDock", true,
            "UI_MinidoracatPackThrow_OptShowDock_tooltip")
    end
    function options:apply()
        showDock = self:getOption("ShowDock"):getValue() ~= false
        if docked then Kit.UI.Dock.refresh() end
    end
    PZAPI.ModOptions:load()
    showDock = options:getOption("ShowDock"):getValue() ~= false
end
if PZAPI and PZAPI.ModOptions then
    local ok, err = pcall(registerOptions)
    if not ok then M.log("mod options failed: " .. tostring(err)) end
end

if not Kit.ok then
    -- no framework: the entry tells admins why instead of opening half a window
    function Panel.open()
        Kit.notify(nil, U("NeedFramework"))
    end
    function Panel.onReply() end
end

function Panel.toggle()
    local w = Panel.window
    if w and w.win:getIsVisible() then w.win:close() else Panel.open() end
end

local dockIcon = "media/textures/Item_MinidoracatCapsuleCartoonLoaded.png"
docked = Kit.ok and Kit.CAPS.dock == true and Kit.UI.Dock ~= nil and Kit.UI.Dock.register({
    id = "packthrow", order = 50, icon = dockIcon,
    label = function() return U("PanelTitle") end,
    onClick = function() Panel.toggle() end,
    isAvailable = function() return showDock and Panel.isAdmin(getSpecificPlayer(0)) end,
    isActive = function() local w = Panel.window; return w ~= nil and w.win:getIsVisible() end,
}) == true

-- Without the Dock: admins get the panel from the world context menu.
Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, _, test)
    if docked or test or playerNum ~= 0 or not Panel.isAdmin(getSpecificPlayer(0)) then return end
    context:addOption(U("PanelTitle"), nil, function() Panel.open() end)
end)

if not Kit.ok then return Panel end

-- ---------------------------------------------------------------- layout helpers

local UI, COL, FS, FH, theme = Kit.UI, Kit.COL, Kit.FS, Kit.FH, Kit.theme
local text, fit = Kit.text, Kit.fit
local PAD, GAP = 12, 8
local CH = FH + 10 -- control height
Panel.STATES = { "ALL", "PACKED", "UNPACKED", "RESTORED", "VOID", "UNCERTAIN", "UNSEEN" }

-- " · " between fields; a translation key because Lua source stays ASCII (Kahlua truncates other characters).
local SEP
local function sep()
    SEP = SEP or U("Sep")
    return SEP
end

local function stateLabel(state, uncertain)
    local s = U("State_" .. tostring(state))
    if uncertain then s = s .. sep() .. U("State_UNCERTAIN") end
    return s
end
Panel.stateLabel = stateLabel

function Panel.whyText(why)
    return getTextOrNull("UI_MinidoracatPackThrow_Why_" .. tostring(why)) or U("WhyOther", tostring(why))
end

-- "10/09 18:40  Packed, Bob, (10598, 9861, 0)" plus verdict, reason and note when there are any.
function Panel.eventLine(e)
    local s = Info.date(e.t) .. "  " .. (getTextOrNull("UI_MinidoracatPackThrow_Ev_" .. tostring(e.ev)) or tostring(e.ev))
        .. sep() .. tostring(e.by or "-")
    if e.x then s = s .. sep() .. "(" .. tostring(e.x) .. ", " .. tostring(e.y) .. ", " .. tostring(e.z or 0) .. ")" end
    if e.verdict then s = s .. sep() .. U("Verdict_" .. tostring(e.verdict)) end
    if e.why then s = s .. sep() .. tostring(e.why) end
    if e.note then s = s .. sep() .. U("NoteShown", tostring(e.note)) end
    return s
end

local function cargoText(manifest)
    local list = {}
    for _, e in ipairs(manifest or {}) do list[#list + 1] = { name = Info.itemName(e.ft), n = tonumber(e.n) or 0 } end
    Info.isort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    if #list == 0 then return U("CargoNone") end
    local parts = {}
    for _, e in ipairs(list) do parts[#parts + 1] = Info.T("CargoLine", e.name, tostring(e.n)) end
    return U("CargoList", table.concat(parts, ", "))
end

-- The animal of an animal record, where a vehicle record lists its cargo: "Animal: Holstein Cow, Gender: Female ...".
local function animalText(a)
    local parts = {}
    for _, row in ipairs(Info.animalRows(a)) do parts[#parts + 1] = Info.T("Row", row[1], row[2]) end
    return table.concat(parts, sep())
end

-- "Last seen: 10/10 18:40 · on Bob (10763, 9775, 0)": where the server last saw the capsule (Store.seen). In an
-- Economy trade it is in Economy's hands (Trade.escrow), with no square to go to.
local function seenText(s)
    if type(s) ~= "table" then return U("SeenNone") end
    if s.where == "economy" then return U("SeenLine", Info.date(s.t), U("SeenEconomy", tostring(s.by or "-"))) end
    local spot = "(" .. tostring(s.x or "-") .. ", " .. tostring(s.y or "-") .. ", " .. tostring(s.z or 0) .. ")"
    local place
    if s.where == "player" then place = U("SeenPlayer", tostring(s.by or "-"), spot)
    elseif s.where == "container" then place = U("SeenContainer", spot)
    elseif s.where == "vehicle" then place = U("SeenVehicle", spot)
    else place = U("SeenGround", spot) end
    return U("SeenLine", Info.date(s.t), place)
end
Panel.seenText = seenText

-- List cell: one or two lines, strings computed in bind (render does not allocate).
local Cell = ISPanel:derive("MinidoracatPackThrowCell")
function Cell:render()
    if not self.line1 then return end
    local list = self.list
    if list:isSelected(self.index) then
        theme:fill(self, 0, 0, self.width, self.height, "selected")
    elseif list:isMouseOver() and list:indexAt(list:getMouseX(), list:getMouseY()) == self.index then
        theme:fill(self, 0, 0, self.width, self.height, "hover")
    end
    if self.line2 then
        local mid = math.floor(self.height / 2)
        text(self, self.line1, 8, mid - FH - 1, self.token1 or "text")
        text(self, self.line2, 8, mid + 1, self.token2 or "textMuted")
    else
        text(self, self.line1, 8, math.floor((self.height - FH) / 2), self.token1 or "text")
    end
end

local function newList(parent, x, y, w, h, twoLines, bind, onSelect)
    local list = UI.VirtualList.new({ x = x, y = y, width = w, height = h, rowHeight = twoLines and FH * 2 + 10 or FH + 6,
        padding = 2,
        createCell = function(l)
            local c = Cell:new(0, 0, 0, 0)
            c.background = false
            c.list = l
            return c
        end,
        bindCell = function(_, c, row, index)
            c.index = index
            bind(c, row, c.width - 16)
        end,
        unbindCell = function(_, c) c.line1, c.line2 = nil, nil end,
        onSelect = onSelect,
        colors = { thumb = COL.textFaint, thumbHover = COL.textMuted, track = COL.hover } })
    list:initialise()
    parent:addChild(list)
    return list
end

local Pane = ISPanel:derive("MinidoracatPackThrowPane")
function Pane:prerender()
    if self.drawBack then self.drawBack(self) end
end
function Pane:render()
    if self.draw then self.draw(self) end
end
local function newPane(parent, x, y, w, h)
    local p = Pane:new(x, y, w, h)
    p.background = false
    p:initialise()
    parent:addChild(p)
    return p
end

-- ---------------------------------------------------------------- window

local Win = {}
Win.__index = Win

function Win.new()
    local self = setmetatable({ q = "", state = "ALL", page = 1, pages = 1, total = 0, counts = {}, rows = {} }, Win)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    -- 720 high: with a larger font (e.g. a font mod) and the detail buttons on two rows, 640 left the timeline at
    -- its minimum and the status line one row (French, 2026-10-10)
    local w, h = math.min(980, sw - 40), math.min(720, sh - 40)
    self.w, self.h = w, h
    self.win = UI.Window.new({ x = math.floor((sw - w) / 2), y = math.floor((sh - h) / 2), width = w, height = h,
        title = U("PanelTitle"), theme = theme, icon = "carPickup", opaque = true, onClose = function() end })
    local top = self.win:contentTop() + GAP
    self.tabs = UI.Tabs.new({ x = PAD, y = top, items = { { id = "records", label = U("TabRecords") },
        { id = "settings", label = U("TabSettings") }, { id = "types", label = U("TabTypes") },
        { id = "loot", label = U("TabLoot") } }, selected = "records",
        theme = theme, target = self, onSelect = function(target, id) target:showTab(id) end })
    self.win:addChild(self.tabs)
    local py = top + self.tabs.height + GAP
    self.records = newPane(self.win, 0, py, w, h - py)
    self.settings = newPane(self.win, 0, py, w, h - py)
    self.types = newPane(self.win, 0, py, w, h - py)
    self.loot = newPane(self.win, 0, py, w, h - py)
    self:buildRecords(self.records)
    self:buildSettings(self.settings)
    self:buildTypes(self.types)
    self:buildLoot(self.loot)
    self:showTab("records")
    return self
end

function Win:showTab(id)
    self.tab = id
    self.records:setVisible(id == "records")
    self.settings:setVisible(id == "settings")
    self.types:setVisible(id == "types")
    self.loot:setVisible(id == "loot")
    if id == "settings" then self:loadSettings() end
    if id == "types" then self:loadTypes() end
    if id == "loot" then self:loadLoot() end
end

-- ------------------------------------------------ records tab

function Win:buildRecords(p)
    local w = p.width
    local x, y = PAD, 0
    -- the field fits its (translated) hint; the button sits right after it
    local go = UI.Button.new({ y = y, height = CH, title = U("Search"), style = "primary",
        theme = theme, target = self, onClick = function(t) t:runSearch() end })
    local sw = math.min(math.max(300, Kit.measure(U("SearchHint")) + 40), w - PAD * 2 - GAP - go.width)
    self.search = UI.TextField.new({ x = x, y = y, width = sw, height = CH, placeholder = U("SearchHint"),
        theme = theme, clearButton = true })
    p:addChild(self.search)
    go:setX(x + sw + GAP)
    p:addChild(go)
    y = y + CH + GAP
    self.chips = {}
    self.chipY = y
    for i, st in ipairs(Panel.STATES) do
        local b = UI.Button.new({ x = x, y = y, height = CH, title = U("Chip_" .. st, "9999"), style = "chip",
            active = st == self.state, theme = theme, target = self, onClick = function(t) t:setStateFilter(st) end })
        p:addChild(b)
        self.chips[i] = b
    end
    -- the chips flow into as many rows as four-digit counts would need (longer translations wrap), reserved once
    self.chipRows = Kit.flow(self.chips, w - PAD * 2, 6)
    for i, st in ipairs(Panel.STATES) do self.chips[i]:setTitle(U("Chip_" .. st, "0")) end
    self:layoutChips()
    y = y + self.chipRows * (CH + GAP)
    local listW = math.floor((w - PAD * 3) * 0.42)
    local listH = p.height - y - CH - GAP - PAD
    self.listY, self.listW, self.listH = y, listW, listH
    self.list = newList(p, x, y, listW, listH, true, function(c, row, cw) self:bindRow(c, row, cw) end,
        function() self:onPick() end)
    local py = y + listH + GAP
    local function pagerW(key) return math.max(90, Kit.measure(U(key)) + 20) end
    self.prevBtn = UI.Button.new({ x = x, y = py, width = pagerW("PrevPage"), height = CH, title = U("PrevPage"),
        theme = theme, target = self, onClick = function(t) t:goPage(t.page - 1) end })
    self.nextBtn = UI.Button.new({ x = x + listW - pagerW("NextPage"), y = py, width = pagerW("NextPage"), height = CH,
        title = U("NextPage"), theme = theme, target = self, onClick = function(t) t:goPage(t.page + 1) end })
    p:addChild(self.prevBtn)
    p:addChild(self.nextBtn)
    self.pagerY = py

    -- detail column
    local dx = x + listW + PAD
    local dw = w - dx - PAD
    self.dx, self.dw = dx, dw
    local dy = y
    self.headY = dy                                    -- title, state (two lines: the crash help is long)
    dy = dy + getTextManager():getFontHeight(UIFont.Medium) + FH * 2 + GAP
    self.infoY = dy                                    -- recorded spot; car; last sighting
    dy = dy + FH * 3 + GAP
    self.timelineHeadY = dy
    dy = dy + FH + 4
    -- action buttons size to their (translated) titles and flow into as many rows as the column needs; the
    -- timeline gives up that height. Added to the pane below, in the original order.
    local function btn(key, style, fn)
        return UI.Button.new({ height = CH, title = U(key), style = style, theme = theme, target = self, onClick = fn })
    end
    self.gotoBtn = btn("GoTo", "normal", function(t) t:goTo() end)
    self.seenBtn = btn("GoSeen", "normal", function(t) t:goSeen() end)
    -- "Restore vehicle" / "Restore animal" (onDetail): laid out at the longer title, so the shorter never overflows
    local restoreTitles = { U("Restore"), U("RestoreAnimal") }
    self.restoreBtn = UI.Button.new({ height = CH, style = "primary", theme = theme, target = self,
        title = Kit.measure(restoreTitles[2]) > Kit.measure(restoreTitles[1]) and restoreTitles[2] or restoreTitles[1],
        onClick = function(t) t:pickRestore() end })
    self.presentBtn = btn("VerdictPresent", "normal", function(t) t:resolve("present") end)
    self.missingBtn = btn("VerdictMissing", "danger", function(t) t:resolve("missing") end)
    local actions = { self.gotoBtn, self.seenBtn, self.restoreBtn, self.presentBtn, self.missingBtn }
    local btnRows = Kit.flow(actions, dw, GAP)
    self.restoreBtn:setTitle(restoreTitles[1])
    local bottomBlock = (FH + 2) * 2 + GAP + CH + GAP + CH + GAP + btnRows * (CH + GAP) + FH
    local tlH = math.max(FH * 4, listH - (dy - y) - bottomBlock)
    self.whyRows = math.max(1, math.floor((dy - self.headY) / FH)) -- a refused detail shows its reason above the timeline
    self.timeline = newList(p, dx, dy, dw, tlH, false, function(c, row, cw)
        c.line1 = fit(Panel.eventLine(row), cw)
        c.token1 = (row.ev == "REJECTED" or row.ev == "RESTORE_FAILED" or row.ev == "UNPACK_FAILED") and "errorText" or "text"
    end)
    dy = dy + tlH + GAP
    self.cargoY = dy
    dy = dy + (FH + 2) * 2 + GAP
    self.note = UI.TextField.new({ x = dx, y = dy, width = dw, height = CH, placeholder = U("NoteHint"), theme = theme,
        maxLength = 200 })
    p:addChild(self.note)
    dy = dy + CH + GAP
    self.checked = UI.Checkbox.new({ x = dx, y = dy, width = dw, label = U("CheckedSite"), theme = theme })
    p:addChild(self.checked)
    dy = dy + CH + GAP
    for _, b in ipairs(actions) do
        b:setX(dx + b.flowX)
        b:setY(dy + b.flowRow * (CH + GAP))
        p:addChild(b)
    end
    dy = dy + btnRows * (CH + GAP)
    self.msgY = dy
    self.msgRows = math.max(1, math.floor((p.height - PAD - dy) / FH))
    p.drawBack = function(el)
        theme:fill(el, PAD, self.listY, self.listW, self.listH, "well")
        theme:fill(el, self.dx, self.timeline:getY(), self.dw, self.timeline.height, "well")
    end
    p.draw = function(el) self:drawRecords(el) end
    self:refreshButtons()
end

function Win:layoutChips()
    Kit.flow(self.chips, self.records.width - PAD * 2, 6)
    for _, b in ipairs(self.chips) do
        b:setX(PAD + b.flowX)
        b:setY(self.chipY + math.min(b.flowRow, self.chipRows - 1) * (CH + GAP))
    end
end

function Win:bindRow(c, row, cw)
    local name = row.kind == "animal" and Info.animalName({ type = row.atype, breed = row.breed, name = row.name })
        or Info.carName(row.script, row.name)
    c.line1 = fit(tostring(row.id) .. "   " .. name, cw)
    c.line2 = fit(tostring(row.by or "-") .. sep() .. Info.date(row.t) .. sep() .. stateLabel(row.state, row.uncertain), cw)
    c.token1 = "text"
    c.token2 = row.uncertain and "errorText" or "textMuted"
end

function Win:drawRecords(el)
    local px = PAD + math.floor(self.listW / 2)
    local pager = U("PageOf", tostring(self.page), tostring(self.pages), tostring(self.total))
    text(el, pager, px - math.floor(Kit.measure(pager) / 2), self.pagerY + 5, "textMuted")
    if #self.rows == 0 then
        text(el, self.loading and U("Loading") or U("NoRecords"), PAD + 8, self.listY + 8, "textFaint")
    end
    local d = self.detail
    local x = self.dx
    if not d then
        text(el, self.pickedId and U("Loading") or U("PickRecord"), x, self.headY, "textFaint")
    elseif not d.ok then
        for i, line in ipairs(self.dWhy) do text(el, line, x, self.headY + (i - 1) * FH, "errorText") end
    else
        text(el, self.dTitle, x, self.headY, "text", UIFont.Medium)
        local sy = self.headY + getTextManager():getFontHeight(UIFont.Medium)
        local token = d.uncertain and "errorText" or "accent"
        for i, line in ipairs(self.dState) do text(el, line, x, sy + (i - 1) * FH, token) end
        for i, line in ipairs(self.dInfo) do text(el, line, x, self.infoY + (i - 1) * FH, "textMuted") end
        text(el, self.dTimelineHead, x, self.timelineHeadY, "textMuted")
        for i, line in ipairs(self.dCargo) do
            text(el, line, x, self.cargoY + (i - 1) * (FH + 2), "text")
        end
    end
    if self.msgLines then
        for i, line in ipairs(self.msgLines) do text(el, line, x, self.msgY + (i - 1) * FH, self.msgToken) end
    end
end

function Win:refreshButtons()
    local d = self.detail
    local ok = d ~= nil and d.ok == true and not self.busy
    local restorable = ok and (d.state == "PACKED" or (d.state == "UNPACKED" and d.uncertain))
    local undecided = ok and d.uncertain and (d.state == "PACKED" or d.state == "UNPACKED")
    self.gotoBtn:setEnabled(ok and d.x ~= nil)
    self.seenBtn:setEnabled(ok and type(d.seen) == "table" and d.seen.x ~= nil)
    self.restoreBtn:setEnabled(restorable == true)
    self.presentBtn:setVisible(undecided == true)
    self.missingBtn:setVisible(undecided == true)
    self.prevBtn:setEnabled(self.page > 1 and not self.loading)
    self.nextBtn:setEnabled(self.page < self.pages and not self.loading)
end

-- Every request carries a sequence number; a reply to an older request (the admin clicked on) is dropped.
function Win:requestPage()
    self.loading = true
    self.seq = (self.seq or 0) + 1
    self:refreshButtons()
    Panel.send("adminPage", { q = self.q, state = self.state, page = self.page, seq = self.seq })
end

function Win:runSearch()
    self.q = self.search:getText() or ""
    self.page = 1
    self:requestPage()
end

function Win:setStateFilter(st)
    self.state = st
    for i, b in ipairs(self.chips) do b:setActive(Panel.STATES[i] == st) end
    self.page = 1
    self:requestPage()
end

-- Status line under the buttons: wrapped to the detail column, as many rows as fit above the pane's bottom.
function Win:setMsg(s, token)
    self.msg, self.msgToken = s, token
    self.msgLines = s and Kit.lines(s, self.dw, self.msgRows) or nil
end

function Win:goPage(n)
    if n < 1 or n > self.pages then return end
    self.page = n
    self:requestPage()
end

function Win:onPage(res)
    if res.seq ~= nil and res.seq ~= self.seq then return end
    self.loading = false
    if not res.ok then
        self:setMsg(Panel.whyText(res.why), "errorText")
        self:refreshButtons()
        return
    end
    self.rows = type(res.rows) == "table" and res.rows or {}
    self.page, self.pages, self.total = tonumber(res.page) or 1, tonumber(res.pages) or 1, tonumber(res.total) or 0
    self.counts = type(res.counts) == "table" and res.counts or {}
    for i, st in ipairs(Panel.STATES) do self.chips[i]:setTitle(U("Chip_" .. st, tostring(self.counts[st] or 0))) end
    self:layoutChips()
    self.list:setItems(self.rows)
    -- keep the selection when the picked capsule is still on this page
    for i, row in ipairs(self.rows) do
        if row.id == self.pickedId then self.list:setSelectedIndex(i) end
    end
    self:refreshButtons()
end

function Win:onPick()
    local row = self.list:getSelectedItem()
    if not row or row.id == self.pickedId then return end
    self:select(row.id)
end

function Win:select(id)
    self.pickedId, self.detail = id, nil
    self:setMsg(nil)
    self.timeline:setItems({})
    self.note:setText("")
    self.checked:setChecked(false, true)
    self:refreshButtons()
    Panel.send("adminDetail", { id = id })
end

function Win:onDetail(d)
    if tonumber(d.id) ~= self.pickedId then return end
    self.detail = d
    if not d.ok then
        self.dWhy = Kit.lines(Panel.whyText(d.why), self.dw, self.whyRows)
    else
        local animal = d.kind == "animal"
        self.dTitle = fit(tostring(d.id) .. "   " .. Info.thingName(d), self.dw)
        self.restoreBtn:setTitle(U(animal and "RestoreAnimal" or "Restore"))
        self.dState = Kit.lines(stateLabel(d.state, d.uncertain) .. (d.uncertain and ("  " .. U("UncertainHelp")) or ""),
            self.dw, 2)
        local spot = d.x and U("Spot", tostring(d.x), tostring(d.y), tostring(d.z or 0)) or U("SpotNone")
        local car = animal and U(d.carLoaded and "AnimalLoaded" or "AnimalNotLoaded", tostring(d.car or "-"))
            or U(d.carLoaded and "CarLoaded" or "CarNotLoaded", tostring(d.car or "-"))
        self.dInfo = { fit(spot, self.dw), fit(car, self.dw), fit(seenText(d.seen), self.dw) }
        local more = (tonumber(d.historyTotal) or 0) - #(d.history or {})
        self.dTimelineHead = more > 0 and U("TimelineMore", tostring(more)) or U("Timeline")
        self.dCargo = Kit.lines(animal and animalText(d.animal) or cargoText(d.manifest), self.dw, 2)
        local h = {}
        for i = #(d.history or {}), 1, -1 do h[#h + 1] = d.history[i] end -- newest first
        self.timeline:setItems(h)
    end
    self:refreshButtons()
end

function Win:goTo()
    local d, player = self.detail, getSpecificPlayer(0)
    if not (d and d.x and player) then return end
    -- East of the spot, two tiles clear of the vehicle's ground when it is restored there facing away (west): the
    -- default click of "Restore vehicle" (the white frame) is then not blocked by the admin. Same path as the vanilla
    -- admin tools (ISSafehousesList.lua:98-102): the server command in MP, a direct teleport in SP.
    local x, y, z = d.x + 4, d.y, d.z or 0
    local w, l = M.Footprint.size(d.script and getScriptManager():getVehicle(d.script))
    if w then x = M.Footprint.box(d.x, d.y, "E", w, l).x2 + 2 end
    if d.kind == "animal" then x = d.x + 2 end -- an animal takes one square
    if isClient() then
        SendCommandToServer("/teleportto " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
    else
        player:teleportTo(x, y, z)
    end
    self:setMsg(U("WentTo", tostring(d.x), tostring(d.y)), "accent")
end

-- The square where the capsule was last seen: an admin checks whether it is still there (a player says it is lost).
function Win:goSeen()
    local d, player = self.detail, getSpecificPlayer(0)
    local s = d and d.seen
    if not (type(s) == "table" and s.x and player) then return end
    local x, y, z = s.x, s.y, s.z or 0
    if isClient() then
        SendCommandToServer("/teleportto " .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
    else
        player:teleportTo(x, y, z)
    end
    self:setMsg(U("WentToSeen", tostring(x), tostring(y)), "accent")
end

local function noteText(field)
    local s = field:getText() or ""
    s = string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")
    return s
end

function Win:act(cmd, args)
    self.busy = true
    self:setMsg(U("Sending"), "textMuted")
    self:refreshButtons()
    Panel.send(cmd, args)
end

-- args: the square and facing picked with the restore cursor (pickRestore); the dialog names that square.
function Win:confirmRestore(args)
    local d = self.detail
    if not d then return end
    if not (Kit.CAPS.dialog and UI.Dialog) then return self:act("adminRestore", args) end
    local animal = d.kind == "animal"
    local title = U(animal and "RestoreAnimal" or "Restore")
    self.dialog = UI.Dialog.show({ title = title, text = U(animal and "RestoreAnimalConfirm" or "RestoreConfirm",
        Info.thingName(d), tostring(args.x), tostring(args.y)), theme = theme, confirmText = title,
        cancelText = U("Cancel"),
        onResult = function(ok)
            self.dialog = nil
            if ok then self:act("adminRestore", args) end
        end })
end

-- "Restore vehicle": the panel steps aside while the admin places the vehicle with the ground cursor (green where it
-- fits, facing away from them; the recorded spot drawn as a white frame, the default choice), then comes back for
-- the confirmation and the server's answer.
function Win:pickRestore()
    local d, player = self.detail, getSpecificPlayer(0)
    if not (d and d.ok and player) then return end
    local args = { id = d.id, note = noteText(self.note), checked = self.checked:getChecked() }
    local home = d.x and { x = d.x, y = d.y, z = d.z or 0 } or nil
    self.win:setVisible(false)
    M.ThrowCursor.openRestore(player, d, home, function(x, y, z, dir)
        self.win:setVisible(true)
        self.win:bringToTop()
        if x == nil then return end
        args.x, args.y, args.z, args.dir = x, y, z, dir
        self:confirmRestore(args)
    end)
end

function Win:resolve(verdict)
    local d = self.detail
    if not d then return end
    self:act("adminResolve", { id = d.id, verdict = verdict, note = noteText(self.note), checked = self.checked:getChecked() })
end

function Win:onAction(cmd, res)
    self.busy = false
    if res.ok then
        -- an animal restore answers animalId (Admin.restore): "Animal restored", not "Vehicle restored"
        local done = cmd ~= "adminRestore" and "Resolved" or (res.animalId and "RestoredAnimal" or "Restored")
        self:setMsg(U(done), "accent")
        Kit.notify(U("PanelTitle"), self.msg)
    else
        self:setMsg(Panel.whyText(res.why), "errorText")
    end
    self:refreshButtons()
    self:requestPage()
    if self.pickedId then Panel.send("adminDetail", { id = self.pickedId }) end
end

-- ------------------------------------------------ config tabs (settings, types, loot)

-- The three sandbox tabs share one frame: the rows in a scroll area (UI.ScrollPanel, rev 16) over a fixed footer with
-- "Discard", "Apply" and the status line, so Apply stays on screen however tall the rows get (French text reached
-- y=687 of the 720-high window; review). body: a pane in the scroll area, under the controls, that draws the labels;
-- its height sets the scroll height. A tab's fields carry its prefix: a set* field would shadow a Win method (setMsg).
local FOOT = CH + GAP * 2

local function newConfig(self, p, onDiscard, onApply)
    local c = {}
    c.scroll = UI.ScrollPanel.new({ x = 0, y = 0, width = p.width, height = p.height - FOOT, theme = theme })
    p:addChild(c.scroll)
    c.w = c.scroll:contentWidth()
    c.body = newPane(c.scroll, 0, 0, c.w, 1)
    local y = p.height - FOOT + GAP
    c.discard = UI.Button.new({ x = PAD, y = y, height = CH, title = U("Discard"), theme = theme, target = self,
        onClick = onDiscard })
    c.apply = UI.Button.new({ x = PAD + c.discard.width + GAP, y = y, height = CH, title = U("Apply"),
        style = "primary", theme = theme, target = self, onClick = onApply })
    p:addChild(c.discard)
    p:addChild(c.apply)
    c.msgX = c.apply:getX() + c.apply.width + GAP * 2
    c.msgY = y + math.floor((CH - FH) / 2)
    p.draw = function(el)
        if c.msgFit then text(el, c.msgFit, c.msgX, c.msgY, c.msgToken or "accent") end
    end
    return c
end

-- The footer's status line, fitted here (draw does not allocate). nil clears it.
local function setStatus(c, msg, token)
    c.msgToken = token
    c.msgFit = msg and fit(msg, c.w - c.msgX - PAD) or nil
end

-- Every paragraph of a text wrapped to w (a translation's "\n" starts a paragraph).
local function paragraphs(s, w)
    local out = {}
    for para in string.gmatch(tostring(s) .. "\n", "([^\n]*)\n") do
        if para ~= "" then
            for _, line in ipairs(Kit.wrap(para, w)) do out[#out + 1] = line end
        end
    end
    return out
end

local function option(key)
    local opts = getSandboxOptions()
    local o = opts and opts:getOptionByName("MinidoracatPackThrow." .. key)
    return o and o:getValue()
end

-- Draft values that differ from the base: { { key, value } }. Numbers compare at one decimal (the weight sliders'
-- step; the integer sliders move by whole numbers).
local function diff(draft, base)
    local out = {}
    for k, v in pairs(draft) do
        local b = base and base[k]
        local differ = type(v) == "number" and math.abs(v - (tonumber(b) or 0)) > 0.05 or (type(v) ~= "number" and v ~= b)
        if differ then out[#out + 1] = { k, v } end
    end
    return out
end

-- Same path as the vanilla sandbox page: MP sends a full copy (the server checks Capability.SandboxOptions, saves
-- and broadcasts it); SP sets the native options and refreshes SandboxVars.
function Panel.applySandbox(changes)
    if #changes == 0 then return end
    if isClient() then
        local copy = SandboxOptions.new()
        copy:copyValuesFrom(getSandboxOptions())
        for _, c in ipairs(changes) do copy:set("MinidoracatPackThrow." .. c[1], c[2]) end
        copy:sendToServer()
    else
        local opts = getSandboxOptions()
        for _, c in ipairs(changes) do opts:set("MinidoracatPackThrow." .. c[1], c[2]) end
        opts:toLua()
    end
end

-- ------------------------------------------------ loot tab

Panel.PLACES = {
    { "LootMechanic", "LootMechanicWeight" },
    { "LootCarSupply", "LootCarSupplyWeight" },
    { "LootGasStation", "LootGasStationWeight" },
    { "LootGarage", "LootGarageWeight" },
    { "LootSphereBarn", "LootSphereBarnWeight" },
    { "LootSpherePet", "LootSpherePetWeight" },
    { "LootSphereHunting", "LootSphereHuntingWeight" },
}

local function fmtWeight(v) return string.format("%.1f", v) end

-- Weight sliders carry their name for keyboard and gamepad focus and their vanilla tooltip (the scale).
function Win:buildLoot(p)
    local c = newConfig(self, p, function(t) t:loadLoot() end, function(t) t:applyLoot() end)
    self.lootCfg = c
    local s, w = c.scroll, c.w
    local y = GAP
    self.lootRows = {}
    self.master = UI.Checkbox.new({ x = PAD, y = y, width = w - PAD * 2, theme = theme, target = self,
        label = getText("Sandbox_MinidoracatPackThrow_LootEnabled"),
        tooltip = getTextOrNull("Sandbox_MinidoracatPackThrow_LootEnabled_tooltip"),
        onChange = function(t) t:lootChanged() end })
    s:addChild(self.master)
    y = y + CH + GAP * 2
    local sliderW = 260
    for i, pl in ipairs(Panel.PLACES) do
        local box = UI.Checkbox.new({ x = PAD + 16, y = y, width = w - PAD * 2 - sliderW - 40,
            label = getText("Sandbox_MinidoracatPackThrow_" .. pl[1]), theme = theme, target = self,
            onChange = function(t) t:lootChanged() end })
        local slider = UI.Slider.new({ x = w - PAD - sliderW, y = y, width = sliderW, min = 0, max = 10, step = 0.1,
            value = 0, theme = theme, format = fmtWeight, target = self,
            tooltip = getTextOrNull("Sandbox_MinidoracatPackThrow_" .. pl[2] .. "_tooltip"),
            onChange = function(t) t:lootChanged() end })
        slider._focusLabel = getText("Sandbox_MinidoracatPackThrow_" .. pl[2])
        s:addChild(box)
        s:addChild(slider)
        local tables = paragraphs(getText("Sandbox_MinidoracatPackThrow_" .. pl[1] .. "_tooltip"), w - PAD * 2 - 56)
        self.lootRows[i] = { box = box, slider = slider, y = y, tables = tables }
        y = y + CH + #tables * FH + GAP
    end
    self.lootNote = paragraphs(U("LootNote"), w - PAD * 2)
    self.lootNoteY = y + GAP
    c.body:setHeight(self.lootNoteY + #self.lootNote * FH + GAP)
    c.body.draw = function(el)
        for _, r in ipairs(self.lootRows) do
            for k, line in ipairs(r.tables) do text(el, line, PAD + 56, r.y + CH + (k - 1) * FH, "textMuted") end
        end
        local ny = self.lootNoteY
        for _, line in ipairs(self.lootNote) do
            text(el, line, PAD, ny, "textMuted")
            ny = ny + FH
        end
    end
end

-- Values the dialog started from (current native options) into the controls.
function Win:loadLoot()
    self.lootBase = { LootEnabled = option("LootEnabled") ~= false }
    self.master:setChecked(self.lootBase.LootEnabled, true)
    for i, pl in ipairs(Panel.PLACES) do
        local on, wt = option(pl[1]) ~= false, tonumber(option(pl[2])) or 0
        self.lootBase[pl[1]], self.lootBase[pl[2]] = on, wt
        self.lootRows[i].box:setChecked(on, true)
        self.lootRows[i].slider:setValue(wt, true)
    end
    setStatus(self.lootCfg, nil)
    self:lootChanged()
end

function Win:lootDraft()
    local d = { LootEnabled = self.master:getChecked() }
    for i, pl in ipairs(Panel.PLACES) do
        d[pl[1]] = self.lootRows[i].box:getChecked()
        d[pl[2]] = self.lootRows[i].slider:getValue()
    end
    return d
end

function Win:lootChanges()
    return diff(self:lootDraft(), self.lootBase)
end

function Win:lootChanged()
    local allowed = Panel.canEditSandbox(getSpecificPlayer(0))
    local n = #self:lootChanges()
    local on = self.master:getChecked()
    for _, r in ipairs(self.lootRows) do
        r.box:setEnabled(on and allowed)
        r.slider:setEnabled(on and allowed and r.box:getChecked())
    end
    self.master:setEnabled(allowed)
    self.lootCfg.apply:setEnabled(allowed and n > 0)
    self.lootCfg.discard:setEnabled(n > 0)
    if not allowed then setStatus(self.lootCfg, U("NoSandboxRight"), "errorText") end
end

function Win:applyLoot()
    local changes = self:lootChanges()
    if #changes == 0 or not Panel.canEditSandbox(getSpecificPlayer(0)) then return end
    Panel.applySandbox(changes)
    self.lootBase = self:lootDraft()
    setStatus(self.lootCfg, U("LootApplied", tostring(#changes)), "accent")
    self:lootChanged()
end

-- ------------------------------------------------ types tab

-- Minidoracat Economy's client facade when it can open its shop page with drafts (rev 4 shopAdd), else nil.
local function economyShop()
    local api = MinidoracatEconomy and MinidoracatEconomy.v1 and MinidoracatEconomy.v1.Client
    local caps = api and api.CAPABILITIES
    if type(caps) == "table" and caps.shopAdd == true and type(api.openAdminShop) == "function" then return api end
    return nil
end

local TOGGLE_W = 36 -- a MinidoracatUI Checkbox drawn without a label (Controls.lua TOGGLE_WIDTH)

-- One row per capsule type (Core M.TYPES): its icon, name and look in words; the use and loot switches (sandbox
-- Type<id>, Type<id>Loot; loot needs use); "List..." (Minidoracat Economy opens its shop page with this empty capsule
-- as a new product draft, the price is set there) and "Preview". Columns are laid out from the right with the
-- translated widths; the look wraps under the name. Every control is named "<type>: <column>" for focus.
function Win:buildTypes(p)
    local c = newConfig(self, p, function(t) t:loadTypes() end, function(t) t:applyTypes() end)
    self.typ = c
    local s, w = c.scroll, c.w
    local shop = economyShop()
    local heads = { use = U("TypeColUse"), loot = U("TypeColLoot") }
    self.typRows = {}
    for i, t in ipairs(M.TYPES) do
        local name = Info.itemName(t.empty)
        local row = { t = t, name = name, look = getText("Tooltip_MinidoracatPackThrow_Look_" .. t.id),
            icon = getTexture("media/textures/Item_" .. t.icon .. ".png") }
        row.use = UI.Checkbox.new({ width = TOGGLE_W, label = "", theme = theme, target = self, tooltip = U("TypeUseTip"),
            onChange = function(o) o:typesChanged() end })
        row.loot = UI.Checkbox.new({ width = TOGGLE_W, label = "", theme = theme, target = self,
            tooltip = U("TypeLootTip"), onChange = function(o) o:typesChanged() end })
        row.list = UI.Button.new({ height = CH, title = U("TypeList"), theme = theme, target = self,
            tooltip = shop and U("TypeListTip") or U("TypeListNoEconomy"), onClick = function(o) o:listType(t) end })
        row.preview = UI.Button.new({ height = CH, title = U("TypePreview"), theme = theme, target = self,
            tooltip = U("TypePreviewTip"), onClick = function(o) o:previewType(t) end })
        row.use._focusLabel = name .. sep() .. heads.use
        row.loot._focusLabel = name .. sep() .. heads.loot
        row.list._focusLabel = name .. sep() .. row.list.title
        row.preview._focusLabel = name .. sep() .. row.preview.title
        s:addChild(row.use)
        s:addChild(row.loot)
        s:addChild(row.list)
        s:addChild(row.preview)
        self.typRows[i] = row
    end
    local r1 = self.typRows[1]
    local xPrev = w - PAD - r1.preview.width
    local xList = xPrev - GAP - r1.list.width
    local lootW = math.max(TOGGLE_W, Kit.measure(heads.loot))
    local useW = math.max(TOGGLE_W, Kit.measure(heads.use))
    local xLoot = xList - GAP * 2 - lootW
    local xUse = xLoot - GAP * 2 - useW
    local nameX = PAD + 32 + GAP
    local nameW = math.max(40, xUse - GAP - nameX)
    self.typHeadY = GAP
    self.typHeads = {
        { fit(U("TypeColName"), nameW), nameX },
        { heads.use, xUse + math.floor((useW - Kit.measure(heads.use)) / 2) },
        { heads.loot, xLoot + math.floor((lootW - Kit.measure(heads.loot)) / 2) },
        { fit(U("TypeColShop"), w - PAD - xList), xList },
    }
    local y = GAP + FH + GAP
    for _, row in ipairs(self.typRows) do
        row.nameFit = fit(row.name, nameW)
        row.lookLines = Kit.wrap(row.look, nameW)
        row.offLines = Kit.wrap(U("TypeOffLine"), nameW)
        local h = math.max(36, CH + 8, (1 + math.max(#row.lookLines, #row.offLines)) * FH + 8)
        row.y, row.h = y, h
        local cy, ty = y + math.floor((h - CH) / 2), y + math.floor((h - row.use.height) / 2)
        row.use:setX(xUse + math.floor((useW - TOGGLE_W) / 2))
        row.use:setY(ty)
        row.loot:setX(xLoot + math.floor((lootW - TOGGLE_W) / 2))
        row.loot:setY(ty)
        row.list:setX(xList)
        row.list:setY(cy)
        row.preview:setX(xPrev)
        row.preview:setY(cy)
        y = y + h
    end
    self.typNoteY = y + GAP
    self.typNote = {}
    c.body:setHeight(self.typNoteY + FH * 3 + GAP)
    c.body.draw = function(el)
        for _, hd in ipairs(self.typHeads) do text(el, hd[1], hd[2], self.typHeadY, "textMuted") end
        local b = COL.border
        el:drawRect(PAD, self.typHeadY + FH + 3, w - PAD * 2, 1, b.a, b.r, b.g, b.b)
        for _, row in ipairs(self.typRows) do
            if row.icon then
                el:drawTextureScaled(row.icon, PAD, row.y + math.floor((row.h - 32) / 2), 32, 32, row.on and 1 or 0.5,
                    1, 1, 1)
            end
            local lines = row.on and row.lookLines or row.offLines
            local ty = row.y + math.floor((row.h - FH * (1 + #lines)) / 2)
            text(el, row.nameFit, nameX, ty, row.on and "text" or "textMuted")
            for k, line in ipairs(lines) do text(el, line, nameX, ty + k * FH, row.on and "textMuted" or "warning") end
        end
        local ny = self.typNoteY
        for _, line in ipairs(self.typNote) do
            text(el, line, PAD, ny, "textMuted")
            ny = ny + FH
        end
    end
end

function Win:loadTypes()
    self.typBase = {}
    for _, row in ipairs(self.typRows) do
        local id = row.t.id
        local use, loot = option("Type" .. id) ~= false, option("Type" .. id .. "Loot") ~= false
        self.typBase["Type" .. id], self.typBase["Type" .. id .. "Loot"] = use, loot
        row.use:setChecked(use, true)
        row.loot:setChecked(loot, true)
    end
    setStatus(self.typ, nil)
    self:typesChanged()
end

function Win:typesDraft()
    local d = {}
    for _, row in ipairs(self.typRows) do
        d["Type" .. row.t.id] = row.use:getChecked()
        d["Type" .. row.t.id .. "Loot"] = row.loot:getChecked()
    end
    return d
end

-- A switched-off type greys its loot switch (it never drops) and says what off means instead of its look.
function Win:typesChanged()
    local allowed = Panel.canEditSandbox(getSpecificPlayer(0))
    local shop, dropping = economyShop() ~= nil, 0
    for _, row in ipairs(self.typRows) do
        row.on = row.use:getChecked()
        row.use:setEnabled(allowed)
        row.loot:setEnabled(allowed and row.on)
        row.list:setEnabled(shop)
        if row.on and row.loot:getChecked() then dropping = dropping + 1 end
    end
    self.typNote = paragraphs(dropping > 0 and U("TypesNote", tostring(dropping)) or U("TypesNoteNone"),
        self.typ.w - PAD * 2)
    local n = #diff(self:typesDraft(), self.typBase)
    self.typ.apply:setEnabled(allowed and n > 0)
    self.typ.discard:setEnabled(n > 0)
    if not allowed then setStatus(self.typ, U("NoSandboxRight"), "errorText") end
end

function Win:applyTypes()
    local changes = diff(self:typesDraft(), self.typBase)
    if #changes == 0 or not Panel.canEditSandbox(getSpecificPlayer(0)) then return end
    Panel.applySandbox(changes)
    self.typBase = self:typesDraft()
    setStatus(self.typ, U("SettingsApplied", tostring(#changes)), "accent")
    self:typesChanged()
end

-- A capsule of this type thrown beside the admin, applied or not, on this client only (Effects.preview); the panel
-- steps aside until the smoke is gone.
function Win:previewType(t)
    local p = getSpecificPlayer(0)
    if not p then return end
    self.win:setVisible(false)
    M.Effects.preview(t.index, p, math.floor(p:getX()) + 4, math.floor(p:getY()), math.floor(p:getZ()), function()
        self.win:setVisible(true)
        self.win:bringToTop()
    end)
end

-- "List...": Economy opens its admin shop page with this empty capsule as a new product draft (a type it already
-- sells is skipped there); the admin sets the price and applies it in Economy.
function Win:listType(t)
    local api = economyShop()
    if not api then return end
    local ok, why = api.openAdminShop(M.MOD_ID, { t.empty })
    if ok then
        setStatus(self.typ, U("ShopOpened", Info.itemName(t.empty)), "accent")
    else
        setStatus(self.typ, getTextOrNull("UI_MinidoracatPackThrow_ShopOpen_" .. tostring(why))
            or U("ShopOpen_other"), "errorText")
    end
end

-- ------------------------------------------------ settings tab

-- The general sandbox page, in the order of sandbox-options.txt. kind: bool (checkbox), choice (one chip per value of
-- an enum option) or int (slider; pct: its value shown as a percentage).
Panel.GENERAL = {
    { key = "ReturnEmptyCapsule", kind = "bool", default = true },
    { key = "ReturnEmptySphere", kind = "bool", default = true },
    { key = "AllowCraftCapsules", kind = "bool", default = false },
    { key = "AllowCraftSpheres", kind = "bool", default = false },
    { key = "PackPermission", kind = "choice", count = 3, default = 1 },
    { key = "ZombieSoundRadius", kind = "int", min = 0, max = 50, default = 0 },
    { key = "AllowCargoTakeOut", kind = "bool", default = false },
    { key = "AllowAnimals", kind = "bool", default = true },
    { key = "WildCaptureChance", kind = "int", min = 0, max = 100, default = 50, pct = true },
    { key = "WildCaptureFailConsumes", kind = "bool", default = false },
    { key = "WildCaptureInjuredBonus", kind = "int", min = 0, max = 100, default = 30, pct = true },
    { key = "WildCaptureYoungBonus", kind = "int", min = 0, max = 100, default = 15, pct = true },
    { key = "WildCaptureUnawareBonus", kind = "int", min = 0, max = 100, default = 20, pct = true },
    { key = "RecordRetentionDays", kind = "int", min = 1, max = 90, default = 30 },
}

local function fmtInt(v) return tostring(math.floor(v + 0.5)) end
local function fmtPct(v) return getText("Tooltip_MinidoracatPackThrow_Percent", math.floor(v + 0.5)) end

-- Each option: its control (the label is the checkbox's own, or drawn left of a slider or the chips) and its whole
-- vanilla tooltip under it. A choice option shows the first paragraph there and gives each chip its own line as a
-- tooltip (the vanilla tooltip lists the values in order). Chips sit right of the label when they fit on its row;
-- else they flow on rows under it. Sliders and chips are named for keyboard and gamepad focus (_focusLabel; the chips
-- of one option share a _focusGroup, FilterBar.lua:613-614). Strings are computed here: draw does not allocate.
function Win:buildSettings(p)
    local c = newConfig(self, p, function(t) t:loadSettings() end, function(t) t:applySettings() end)
    self.cfg = c
    local s, w = c.scroll, c.w
    local y = GAP
    local sliderW = 260
    self.cfgRows = {}
    for i, f in ipairs(Panel.GENERAL) do
        local label = getText("Sandbox_MinidoracatPackThrow_" .. f.key)
        local tip = getText("Sandbox_MinidoracatPackThrow_" .. f.key .. "_tooltip")
        local row = { field = f, y = y }
        local controlX, extra = PAD, 0
        if f.kind == "bool" then
            row.box = UI.Checkbox.new({ x = PAD, y = y, width = w - PAD * 2, label = label, theme = theme, target = self,
                onChange = function(t) t:settingsChanged() end })
            s:addChild(row.box)
        elseif f.kind == "int" then
            controlX = w - PAD - sliderW
            row.slider = UI.Slider.new({ x = controlX, y = y, width = sliderW, min = f.min, max = f.max, step = 1,
                value = f.default, theme = theme, format = f.pct and fmtPct or fmtInt, target = self,
                onChange = function(t) t:settingsChanged() end })
            row.slider._focusLabel = label
            s:addChild(row.slider)
        else
            local lines = {}
            for para in string.gmatch(tip .. "\n", "([^\n]*)\n") do lines[#lines + 1] = para end
            row.chips = {}
            local need = 0
            for v = 1, f.count do
                local own = lines[v + 1]
                local b = UI.Button.new({ y = y, height = CH, style = "chip", theme = theme, target = self,
                    title = getText("Sandbox_MinidoracatPackThrow_" .. f.key .. "_option" .. v),
                    tooltip = own ~= nil and own ~= "" and own or nil, onClick = function(t) t:pickChoice(i, v) end })
                b._focusGroup, b._focusLabel = f.key, label
                s:addChild(b)
                row.chips[v] = b
                need = need + b.width + (v > 1 and 6 or 0)
            end
            tip = lines[1]
            if PAD + Kit.measure(label) + GAP + need <= w - PAD then
                controlX = w - PAD - need
                local x = controlX
                for _, b in ipairs(row.chips) do
                    b:setX(x)
                    x = x + b.width + 6
                end
            else
                controlX = w - PAD
                local rows = Kit.flow(row.chips, w - PAD * 2, 6)
                for _, b in ipairs(row.chips) do
                    b:setX(PAD + b.flowX)
                    b:setY(y + (CH + 6) * (b.flowRow + 1))
                end
                extra = rows * (CH + 6)
            end
        end
        if not row.box then row.label = fit(label, controlX - PAD - GAP) end
        row.desc = paragraphs(tip, w - PAD * 2)
        row.descY = y + CH + extra + 2
        y = y + CH + extra + #row.desc * FH + GAP * 2
        self.cfgRows[i] = row
    end
    self.cfgNote = paragraphs(U("SettingsNote"), w - PAD * 2)
    self.cfgNoteY = y
    c.body:setHeight(y + #self.cfgNote * FH + GAP)
    c.body.draw = function(el)
        for _, r in ipairs(self.cfgRows) do
            if r.label then text(el, r.label, PAD, r.y + math.floor((CH - FH) / 2), "text") end
            for k, line in ipairs(r.desc) do text(el, line, PAD, r.descY + (k - 1) * FH, "textMuted") end
        end
        local ny = self.cfgNoteY
        for _, line in ipairs(self.cfgNote) do
            text(el, line, PAD, ny, "textMuted")
            ny = ny + FH
        end
    end
end

function Win:showChoice(row, v)
    row.choice = v
    for k, b in pairs(row.chips) do b:setActive(k == v) end
end

function Win:pickChoice(i, v)
    self:showChoice(self.cfgRows[i], v)
    self:settingsChanged()
end

-- Current native option values into the controls; they are the base the changes are counted against.
function Win:loadSettings()
    self.cfgBase = {}
    for i, f in ipairs(Panel.GENERAL) do
        local r, v = self.cfgRows[i], option(f.key)
        if f.kind == "bool" then
            if v == nil then v = f.default end
            v = v == true
            r.box:setChecked(v, true)
        else
            v = math.floor((tonumber(v) or f.default) + 0.5)
            if r.slider then r.slider:setValue(v, true) else self:showChoice(r, v) end
        end
        self.cfgBase[f.key] = v
    end
    setStatus(self.cfg, nil)
    self:settingsChanged()
end

function Win:settingsDraft()
    local d = {}
    for i, f in ipairs(Panel.GENERAL) do
        local r = self.cfgRows[i]
        if r.box then
            d[f.key] = r.box:getChecked()
        elseif r.slider then
            d[f.key] = math.floor(r.slider:getValue() + 0.5)
        else
            d[f.key] = r.choice
        end
    end
    return d
end

function Win:settingsChanges()
    return diff(self:settingsDraft(), self.cfgBase)
end

function Win:settingsChanged()
    local allowed = Panel.canEditSandbox(getSpecificPlayer(0))
    for _, r in ipairs(self.cfgRows) do
        if r.box then
            r.box:setEnabled(allowed)
        elseif r.slider then
            r.slider:setEnabled(allowed)
        else
            for _, b in pairs(r.chips) do b:setEnabled(allowed) end
        end
    end
    local n = #self:settingsChanges()
    self.cfg.apply:setEnabled(allowed and n > 0)
    self.cfg.discard:setEnabled(n > 0)
    if not allowed then setStatus(self.cfg, U("NoSandboxRight"), "errorText") end
end

function Win:applySettings()
    local changes = self:settingsChanges()
    if #changes == 0 or not Panel.canEditSandbox(getSpecificPlayer(0)) then return end
    Panel.applySandbox(changes)
    self.cfgBase = self:settingsDraft()
    setStatus(self.cfg, U("SettingsApplied", tostring(#changes)), "accent")
    self:settingsChanged()
end

-- ---------------------------------------------------------------- entry points

function Panel.open()
    local player = getSpecificPlayer(0)
    if not Panel.isAdmin(player) then
        Kit.notify(U("PanelTitle"), Panel.whyText("NOT_ADMIN"))
        return
    end
    local w = Panel.window
    if not w then
        w = Win.new()
        Panel.window = w
        w.win:addToUIManager()
    end
    w.win:setVisible(true)
    w.win:bringToTop()
    if w.tab == "settings" then w:loadSettings() end
    if w.tab == "types" then w:loadTypes() end
    if w.tab == "loot" then w:loadLoot() end
    w:requestPage()
    return w
end

function Panel.onReply(cmd, res)
    local w = Panel.window
    if not w then return end
    if cmd == "adminPage" then
        w:onPage(res)
    elseif cmd == "adminDetail" then
        w:onDetail(res)
    else
        w:onAction(cmd, res)
    end
end

return Panel
