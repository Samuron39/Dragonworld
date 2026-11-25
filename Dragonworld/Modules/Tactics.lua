-- Dragonworld - Tactics: the tab and the editor
--
-- The tab in the main window lists the saved plans by dungeon or raid and
-- boss. The editor is a window of its own where a plan is made: the board,
-- the tools, the raid's groups and the scenes. The plan as data is described
-- at the top of TacticsCore.lua.
--
-- The editor works on a copy of the plan (the working copy). That copy lives
-- in the saved data as the draft, so every change is kept as it is made:
--   DragonworldDB.modules.tactics.draft  = { plan = the working copy,
--                                            scene = the scene being worked on,
--                                            dirty = true when something in it
--                                                    is not saved }
--   DragonworldDB.modules.tactics.editor = { point, relativePoint, x, y }: where
--                                            the editor window was moved to
-- Closing the editor, Escape or a reload leaves a draft with unsaved changes
-- where it is: the tab lists it first, and opening the editor for something
-- else asks what to do with it. A draft without changes is dropped.
--
-- What other files may call:
--   T.OpenEditor(id)   opens the editor on the saved plan with that id, or on a
--                      new plan when there is no id
--   T.ResumeEditor()   opens the editor on the unsaved draft, if there is one
--   T.CloseEditor()    closes the editor (unsaved work stays as the draft)
--   T.SelectPlan(id)   chooses a saved plan in the tab's list
--   T.UI               the small things under "Small things" below (colours,
--                      tooltips, chips, the click-twice question), for the
--                      slideshow window in TacticsViewer.lua
--
-- All text is in Locales.lua (the names that start with TAC_).

local ADDON_NAME, DW = ...
local L = DW.L
local T = DW.Tactics
local Geo = T.Geo

local floor, min, max = math.floor, math.min, math.max

-- The functions, and what they remember, are kept in three tables. The game's
-- Lua lets a function reach for at most 60 names outside itself, and the
-- function that builds the editor would pass that with a local for each.
local U = {}   -- small things both windows use
local Tab = {} -- the tab in the main window
local Ed = {}  -- the editor
T.UI = U       -- ...and the slideshow window (TacticsViewer.lua)

-- Small things ------------------------------------------------------------------

U.GOLD = { 1.00, 0.82, 0.00 }
U.GREY = { 0.65, 0.65, 0.65 }
U.RED = { 1.00, 0.35, 0.30 }
U.GREEN = { 0.40, 0.90, 0.40 }
U.ORANGE = { 1.00, 0.65, 0.20 }
U.CONFIRM_TIME = 5 -- seconds a "click again to delete" waits for the second click

-- The module's saved table; nil before the saved data has been read.
function U.DB()
    local db = T.module and T.module.db
    return type(db) == "table" and db or nil
end

function U.Wipe(list)
    for key in pairs(list) do
        list[key] = nil
    end
end

-- A text from Locales.lua, or nil when there is none by that name.
function U.Words(key)
    local text = L[key]
    if type(text) ~= "string" or text == key then
        return nil
    end
    return text
end

-- The names of what the board's registries offer. An icon or a room from a
-- newer version has no name here: its id is shown instead.
function U.IconName(id)
    return U.Words("TAC_ICON_" .. tostring(id):upper()) or tostring(id)
end

function U.RoomName(id)
    return U.Words("TAC_ROOM_" .. tostring(id):upper()) or tostring(id)
end

function U.ColourName(index)
    local colour = T.COLORS[index]
    return colour and U.Words("TAC_COLOR_" .. colour[4]) or ""
end

-- What was typed, cleaned by the core's own rules (the length, no "|", no
-- spaces at the ends), so the board shows a text exactly as it will be saved.
function U.CleanName(text)
    return T.SanitizeScene({ title = text }).title
end

function U.CleanNote(text)
    return T.SanitizeScene({ notes = { text } }).notes[1] or ""
end

function U.CleanLabel(text)
    local item = T.SanitizeScene({ items = { { k = "t", x = 0, y = 0, t = text } } }).items[1]
    return item and item.t or ""
end

function U.PlanName(plan)
    if type(plan.name) == "string" and plan.name ~= "" then
        return plan.name
    end
    return L.TAC_UNNAMED
end

-- "The Deadmines - Edwin VanCleef": what a plan is for.
function U.Place(plan)
    local place = plan.instName ~= "" and plan.instName or L.TAC_NO_INSTANCE
    if plan.boss ~= "" then
        return place .. " - " .. plan.boss
    end
    return place
end

function U.When(moment)
    if type(moment) ~= "number" or moment <= 0 then
        return "?"
    end
    return date("%d.%m.%Y", moment)
end

function U.Paint(fontString, colour)
    fontString:SetTextColor(colour[1], colour[2], colour[3])
end

-- Sets a text field's text, unless it says that already (setting it moves the
-- cursor to the end).
function U.SetBox(box, text)
    if box:GetText() ~= text then
        box:SetText(text)
    end
end

function U.ShowTip(owner, title, text, r, g, b, anchor)
    if type(title) ~= "string" or title == "" then
        return
    end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(title)
    if type(text) == "string" and text ~= "" then
        GameTooltip:AddLine(text, r or 1, g or 1, b or 1, true)
    end
    GameTooltip:Show()
end

function U.HideTip()
    GameTooltip:Hide()
end

-- Gives a widget a tooltip. title and text are the names of texts in
-- Locales.lua, or functions that give the text itself (text may give a colour
-- after it).
function U.AddTip(widget, title, text, anchor)
    widget:HookScript("OnEnter", function(self)
        local head, body, r, g, b
        if type(title) == "function" then
            head = title(self)
        else
            head = L[title]
        end
        if type(text) == "function" then
            body, r, g, b = text(self)
        elseif text then
            body = L[text]
        end
        U.ShowTip(self, head, body, r, g, b, anchor)
    end)
    widget:HookScript("OnLeave", U.HideTip)
end

-- Lets a button show its tooltip while it is greyed out, so it can say why.
function U.TipWhileDisabled(button)
    if button.SetMotionScriptsWhileDisabled then
        button:SetMotionScriptsWhileDisabled(true)
    end
end

function U.Label(parent, font, x, y)
    local label = parent:CreateFontString(nil, "OVERLAY", font)
    label:SetPoint("TOPLEFT", x, y)
    label:SetJustifyH("LEFT")
    return label
end

-- A text field for one line of at most `letters` characters. onTyped(text) is
-- called for what the player types, not for text set by the addon.
function U.Box(parent, width, letters, onTyped)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(letters)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    if onTyped then
        box:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                onTyped(self:GetText())
            end
        end)
    end
    return box
end

-- A chip with its text in the middle and little room around it, for narrow
-- buttons. small: with the small font, and the text nearly to the edge.
function U.Chip(parent, width, height, small)
    local chip = DW.CreateChip(parent, width, height)
    local margin = small and 3 or 4
    chip.label:ClearAllPoints()
    chip.label:SetPoint("LEFT", margin, 0)
    chip.label:SetPoint("RIGHT", -margin, 0)
    chip.label:SetJustifyH("CENTER")
    if small then
        chip.label:SetFontObject(GameFontHighlightSmall or "GameFontHighlightSmall")
    end
    return chip
end

-- Greys a chip out and makes it unclickable, or the opposite.
function U.SetChipOn(chip, on)
    chip:SetEnabled(on and true or false)
    chip:SetDimmed(not on)
end

-- A small arrow button, with the game's own arrow pictures ("Up" or "Down").
function U.Arrow(parent, direction, size)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)
    local base = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. direction .. "Button-"
    button:SetNormalTexture(base .. "Up")
    button:SetPushedTexture(base .. "Down")
    button:SetDisabledTexture(base .. "Disabled")
    button:SetHighlightTexture(base .. "Highlight", "ADD")
    return button
end

-- A small square to click: a palette icon or a colour. It has a thin edge
-- (gold when chosen), a dark middle and a picture on it.
function U.Cell(parent, size)
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(size, size)
    cell.edge = cell:CreateTexture(nil, "BACKGROUND")
    cell.edge:SetAllPoints()
    cell.fill = cell:CreateTexture(nil, "BORDER")
    cell.fill:SetPoint("TOPLEFT", 1, -1)
    cell.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetPoint("TOPLEFT", 2, -2)
    cell.icon:SetPoint("BOTTOMRIGHT", -2, 2)

    function cell:Paint()
        if self.selected then
            self.edge:SetColorTexture(1.00, 0.82, 0.00, 1)
        elseif self.hovered then
            self.edge:SetColorTexture(0.85, 0.85, 0.85, 1)
        else
            self.edge:SetColorTexture(0.35, 0.35, 0.35, 1)
        end
        if self.hovered then
            self.fill:SetColorTexture(0.22, 0.22, 0.26, 1)
        else
            self.fill:SetColorTexture(0.07, 0.07, 0.09, 1)
        end
    end

    function cell:SetSelected(isSelected)
        self.selected = isSelected and true or false
        self:Paint()
    end

    cell:SetScript("OnEnter", function(self)
        self.hovered = true
        self:Paint()
    end)
    cell:SetScript("OnLeave", function(self)
        self.hovered = false
        self:Paint()
    end)
    cell:Paint()
    return cell
end

-- For a button that must be clicked twice (delete, discard). The first click
-- asks ("Sure?") and gives false; a second within U.CONFIRM_TIME gives true.
-- `what` is what would be deleted, so that a click meant for one thing never
-- deletes another. U.Disarm takes the question back.
function U.Confirmed(button, what)
    if button.armedAt and button.armedFor == what and GetTime() - button.armedAt <= U.CONFIRM_TIME then
        button.armedAt, button.armedFor = nil, nil
        return true
    end
    button.armedAt, button.armedFor = GetTime(), what
    button.label:SetText(L.TAC_SURE)
    return false
end

function U.Disarm(button, key)
    button.armedAt, button.armedFor = nil, nil
    button.label:SetText(L[key])
end

-- What a menu's choice gives back so that the menu closes: the game leaves a
-- menu of choices open otherwise, and these are long.
function U.CloseMenu()
    return MenuResponse and MenuResponse.Close or nil
end

-- May a slideshow be started now? True, or false and why (a text).
function U.PresentState()
    local can, reason = T.CanPresent()
    if can then
        return true
    end
    return false, L[reason or "TAC_ERR_NO_GROUP"]
end

-- The tooltip of a "Show to group" button: what it does, or in red why it
-- cannot be used now.
function U.PresentTip(button)
    if button.reason then
        return button.reason, U.RED[1], U.RED[2], U.RED[3]
    end
    return L.TAC_PRESENT_TIP
end

-- The draft --------------------------------------------------------------------------

-- The draft as saved, or nil. The first time after the saved data was read it
-- is checked like every plan from outside, and thrown away when it holds
-- nothing unsaved.
function Ed.Draft()
    local db = U.DB()
    if not db then
        return nil
    end
    if not Ed.draftChecked then
        Ed.draftChecked = true
        local draft = db.draft
        local plan = type(draft) == "table" and draft.dirty == true and T.Sanitize(draft.plan) or nil
        if plan then
            local scene = type(draft.scene) == "number" and floor(draft.scene) or 1
            db.draft = { plan = plan, scene = max(1, min(#plan.scenes, scene)), dirty = true }
        else
            db.draft = nil
        end
    end
    return db.draft
end

-- The draft, when it holds changes that are not saved.
function Ed.Unsaved()
    local draft = Ed.Draft()
    if draft and draft.dirty then
        return draft
    end
    return nil
end

-- The tab -----------------------------------------------------------------------------
--
-- 612 x 434. From the top: a strip with what the tab is for, or the line about
-- a running slideshow (down to y = 35); then the list on the left (212 wide,
-- "New tactic" under it) and the chosen plan on the right (from x = 256: the
-- list's scroll bar is between them).

Tab.TOP = 40
Tab.LIST_X, Tab.LIST_W = 10, 212
Tab.DETAIL_X = 256
Tab.HEAD_H, Tab.SUB_H, Tab.ROW_H = 22, 16, 24
Tab.scene = 1 -- the scene the small board shows

-- What the list shows, from the top: the unsaved draft, your plans by dungeon
-- or raid and boss, and the plans a leader has shown you.
--   { kind = "head" or "sub", text }                       a heading
--   { kind = "row", type = "draft", "plan" or "received", plan, text }
function Tab.Entries()
    local list = {}
    local draft = Ed.Unsaved()
    if draft then
        list[#list + 1] = { kind = "head", text = L.TAC_DRAFT }
        list[#list + 1] = { kind = "row", type = "draft", plan = draft.plan, text = U.PlanName(draft.plan) }
    end
    -- T.Plans() comes sorted by dungeon or raid, boss and name.
    local lastPlace, lastBoss
    for _, plan in ipairs(T.Plans()) do
        local place, boss = plan.instName:lower(), plan.boss:lower()
        if place ~= lastPlace then
            list[#list + 1] = { kind = "head", text = plan.instName ~= "" and plan.instName or L.TAC_NO_INSTANCE }
            lastPlace, lastBoss = place, nil
        end
        if boss ~= lastBoss then
            list[#list + 1] = { kind = "sub", text = plan.boss ~= "" and plan.boss or L.TAC_NO_BOSS }
            lastBoss = boss
        end
        list[#list + 1] = { kind = "row", type = "plan", plan = plan, text = U.PlanName(plan) }
    end
    local received = T.Received()
    if #received > 0 then
        list[#list + 1] = { kind = "head", text = L.TAC_RECEIVED }
        for _, plan in ipairs(received) do
            list[#list + 1] = { kind = "row", type = "received", plan = plan, text = U.PlanName(plan) }
        end
    end
    return list
end

-- The parts of the list, each made the first time it is needed.
function Tab.Head(index)
    local f = Tab.panel
    local head = f.heads[index]
    if not head then
        head = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetWidth(Tab.LIST_W)
        head:SetJustifyH("LEFT")
        head:SetWordWrap(false)
        f.heads[index] = head
    end
    return head
end

function Tab.Sub(index)
    local f = Tab.panel
    local sub = f.subs[index]
    if not sub then
        sub = f.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sub:SetWidth(Tab.LIST_W - 8)
        sub:SetJustifyH("LEFT")
        sub:SetWordWrap(false)
        sub:SetTextColor(0.75, 0.75, 0.75)
        f.subs[index] = sub
    end
    return sub
end

function Tab.Row(index)
    local f = Tab.panel
    local row = f.rows[index]
    if not row then
        row = DW.CreateChip(f.content, Tab.LIST_W - 14, Tab.ROW_H - 2)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", 8, 0)
        row.label:SetPoint("RIGHT", -8, 0)
        row:SetScript("OnClick", function(self)
            Tab.selected = { type = self.type, id = self.id }
            Tab.Refresh()
        end)
        f.rows[index] = row
    end
    return row
end

-- The line at the top: what the tab is for, or the slideshow that is running.
function Tab.RefreshBar()
    local f = Tab.panel
    local showing, watching = T.Presenting(), T.Watching()
    if not showing and not watching then
        f.bar:Hide()
        f.hint:SetText(L.TAC_HINT)
        f.hint:Show()
        return
    end
    f.hint:Hide()
    if showing then
        f.bar.text:SetText(L.TAC_BAR_PRESENTING:format(U.PlanName(showing.plan)))
    else
        local from = type(watching.from) == "string" and watching.from ~= "" and watching.from or "?"
        f.bar.text:SetText(L.TAC_BAR_WATCHING:format(from, U.PlanName(watching.plan)))
    end
    f.bar.open.label:SetText(L.TAC_BAR_OPEN)
    f.bar.open:SetActive(type(T.ShowSlideshow) == "function")
    f.bar:Show()
end

-- The chosen plan on the right. entry is its line in the list.
function Tab.ShowPlan(entry)
    local d = Tab.panel.detail
    local plan, kind = entry.plan, entry.type
    local count = #plan.scenes
    Tab.scene = max(1, min(count, Tab.scene))
    local scene = plan.scenes[Tab.scene]

    d.name:SetText(U.PlanName(plan))
    d.place:SetText(U.Place(plan))
    if kind == "draft" then
        d.who:SetText(L.TAC_DRAFT_INFO)
        U.Paint(d.who, U.ORANGE)
    elseif kind == "received" then
        d.who:SetText(L.TAC_RECEIVED_FROM:format(plan.from ~= "" and plan.from or "?", U.When(plan.at)))
        U.Paint(d.who, U.GREY)
    else
        d.who:SetText(L.TAC_SAVED_BY:format(plan.author ~= "" and plan.author or "?", U.When(plan.updated)))
        U.Paint(d.who, U.GREY)
    end

    d.board:SetScene(scene)
    if scene.title ~= "" then
        d.sceneText:SetText(L.TAC_SCENE_OF_TITLE:format(Tab.scene, count, scene.title))
    else
        d.sceneText:SetText(L.TAC_SCENE_OF:format(Tab.scene, count))
    end
    U.SetChipOn(d.prev, Tab.scene > 1)
    U.SetChipOn(d.next, Tab.scene < count)

    -- The buttons: what can be done with this kind of plan.
    local isPlan, isReceived, isDraft = kind == "plan", kind == "received", kind == "draft"
    d.edit:SetShown(isPlan)
    d.present:SetShown(isPlan)
    d.copy:SetShown(isPlan)
    d.delete:SetShown(isPlan)
    d.keep:SetShown(isReceived)
    d.resume:SetShown(isDraft)
    d.discard:SetShown(isDraft)
    -- Play stands after Edit (100 wide), or after the one wide button (164).
    d.play:ClearAllPoints()
    d.play:SetPoint("BOTTOMLEFT", isPlan and 104 or 168, 30)

    d.edit.label:SetText(L.TAC_EDIT)
    d.play.label:SetText(L.TAC_PLAY)
    d.present.label:SetText(L.TAC_PRESENT)
    Tab.RefreshCan()
    d.copy.label:SetText(L.TAC_COPY)
    U.Disarm(d.delete, "TAC_DELETE")
    U.Disarm(d.discard, "TAC_DRAFT_DISCARD")
    d.resume.label:SetText(L.TAC_DRAFT_CONTINUE)
    local kept = plan.kept ~= nil
    d.keep.label:SetText(kept and L.TAC_KEPT or L.TAC_KEEP)
    d.keep:SetActive(not kept)
end

-- Whether the chosen plan can be played and shown to the group right now.
function Tab.RefreshCan()
    local d = Tab.panel.detail
    d.play:SetActive(type(T.Preview) == "function")
    local can, reason = U.PresentState()
    d.present:SetActive(can)
    d.present.reason = reason
end

-- What changes when the group or a slideshow does: the line at the top and
-- what can be done now. (The list stays as it is: in a raid the group changes
-- often, and drawing the board again each time would be for nothing.)
function Tab.RefreshState()
    local f = Tab.panel
    if not f or not f:IsVisible() then
        return
    end
    Tab.RefreshBar()
    Tab.RefreshCan()
end

-- Draws the tab again: the list, and the plan that is chosen in it.
function Tab.Refresh()
    local f = Tab.panel
    if not f or not f:IsVisible() then
        return
    end
    Tab.RefreshBar()
    f.newButton.label:SetText(L.TAC_NEW)

    -- The chosen plan is the one chosen before when it is still there, and
    -- otherwise the first in the list.
    local entries = Tab.Entries()
    local chosen, first
    for _, entry in ipairs(entries) do
        if entry.kind == "row" then
            first = first or entry
            if Tab.selected and entry.type == Tab.selected.type and entry.plan.id == Tab.selected.id then
                chosen = entry
            end
        end
    end
    chosen = chosen or first
    Tab.entry = chosen
    Tab.selected = chosen and { type = chosen.type, id = chosen.plan.id } or nil
    local key = chosen and (chosen.type .. ":" .. chosen.plan.id) or ""
    if key ~= Tab.shownKey then
        Tab.shownKey = key
        Tab.scene = 1
        f.detail.message:SetText("")
    end

    local heads, subs, rows, y = 0, 0, 0, 0
    for _, entry in ipairs(entries) do
        if entry.kind == "head" then
            heads = heads + 1
            local head = Tab.Head(heads)
            if y > 0 then
                y = y + 6 -- air above a new dungeon or raid
            end
            head:ClearAllPoints()
            head:SetPoint("TOPLEFT", 0, -y - 4)
            head:SetText(entry.text)
            head:Show()
            y = y + Tab.HEAD_H
        elseif entry.kind == "sub" then
            subs = subs + 1
            local sub = Tab.Sub(subs)
            sub:ClearAllPoints()
            sub:SetPoint("TOPLEFT", 8, -y - 2)
            sub:SetText(entry.text)
            sub:Show()
            y = y + Tab.SUB_H
        else
            rows = rows + 1
            local row = Tab.Row(rows)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 14, -y)
            row.type, row.id = entry.type, entry.plan.id
            row.label:SetText(entry.text)
            row:SetSelected(entry == chosen)
            row:Show()
            y = y + Tab.ROW_H
        end
    end
    for index = heads + 1, #f.heads do
        f.heads[index]:Hide()
    end
    for index = subs + 1, #f.subs do
        f.subs[index]:Hide()
    end
    for index = rows + 1, #f.rows do
        f.rows[index]:Hide()
    end
    f.content:SetHeight(max(1, y))

    if chosen then
        f.empty:Hide()
        f.detail:Show()
        Tab.ShowPlan(chosen)
    else
        f.detail:Hide()
        f.empty:SetText(L.TAC_EMPTY)
        f.empty:Show()
    end
end

-- Says under the board why something could not be done (the name of a text).
function Tab.Problem(reason)
    local message = Tab.panel.detail.message
    message:SetText(L[reason or "TAC_ERR_BAD_PLAN"])
    U.Paint(message, U.RED)
end

-- Called by the main window the first time the tab is chosen.
function Tab.Create(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f:SetSize(parent:GetWidth(), parent:GetHeight())
    Tab.panel = f
    local width, height = parent:GetWidth(), parent:GetHeight()
    local detailW = width - Tab.DETAIL_X - 14 -- 342
    local detailH = height - Tab.TOP - 12     -- 382

    -- The strip at the top: two lines of small text fit above y = 35.
    f.hint = U.Label(f, "GameFontHighlightSmall", 12, -8)
    f.hint:SetWidth(width - 24)
    f.hint:SetTextColor(0.75, 0.75, 0.75)

    f.bar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.bar:SetPoint("TOPLEFT", 8, -5)
    f.bar:SetSize(width - 16, 30)
    f.bar:SetBackdrop(DW.PANEL_BACKDROP)
    f.bar:SetBackdropColor(0.30, 0.22, 0.05, 0.95)
    f.bar:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    f.bar.open = DW.CreateButton(f.bar, 160, 22, "gold")
    f.bar.open:SetPoint("RIGHT", -4, 0)
    f.bar.open:SetScript("OnClick", function()
        if type(T.ShowSlideshow) == "function" then
            T.ShowSlideshow()
        end
    end)
    f.bar.text = f.bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.bar.text:SetPoint("LEFT", 10, 0)
    f.bar.text:SetPoint("RIGHT", f.bar.open, "LEFT", -8, 0)
    f.bar.text:SetJustifyH("LEFT")
    f.bar.text:SetWordWrap(false)
    f.bar:Hide()

    -- The list. It ends 8 above the button under it (434 - 40 - 50 = 344 high).
    local scroll = CreateFrame("ScrollFrame", "DragonworldTacticsScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", Tab.LIST_X, -Tab.TOP)
    scroll:SetSize(Tab.LIST_W, height - Tab.TOP - 50)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(Tab.LIST_W, 1)
    scroll:SetScrollChild(f.content)
    f.heads, f.subs, f.rows = {}, {}, {}

    f.newButton = DW.CreateButton(f, Tab.LIST_W, 30, "gold")
    f.newButton:SetPoint("BOTTOMLEFT", Tab.LIST_X, 12)
    f.newButton:SetScript("OnClick", function()
        T.OpenEditor()
    end)

    -- With no plans at all: what the tab is for and how to start.
    f.empty = U.Label(f, "GameFontHighlight", Tab.DETAIL_X, -Tab.TOP - 20)
    f.empty:SetWidth(detailW)

    -- The chosen plan. From its top: the name (0), what it is for (-20), who
    -- saved it (-34), the board (-50, 342 x 213.75), the line that steps
    -- through the scenes, a line for what went wrong, and at the bottom two
    -- rows of buttons (26 high, at 30 and 0 from the bottom).
    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", Tab.DETAIL_X, -Tab.TOP)
    d:SetSize(detailW, detailH)
    f.detail = d

    d.name = U.Label(d, "GameFontNormalLarge", 0, 0)
    d.name:SetWidth(detailW)
    d.name:SetWordWrap(false)
    d.place = U.Label(d, "GameFontHighlightSmall", 0, -20)
    d.place:SetWidth(detailW)
    d.place:SetWordWrap(false)
    d.who = U.Label(d, "GameFontHighlightSmall", 0, -34)
    d.who:SetWidth(detailW)
    d.who:SetWordWrap(false)

    local boardH = detailW * T.BOARD_H / T.BOARD_W
    d.edge = d:CreateTexture(nil, "BACKGROUND")
    d.edge:SetPoint("TOPLEFT", -1, -49)
    d.edge:SetSize(detailW + 2, boardH + 2)
    d.edge:SetColorTexture(0.45, 0.36, 0.15, 1)
    d.board = T.CreateBoard(d, detailW)
    d.board:SetPoint("TOPLEFT", 0, -50)

    local navY = -(50 + boardH + 4)
    d.prev = U.Chip(d, 26, 22)
    d.prev:SetPoint("TOPLEFT", 0, navY)
    d.prev.label:SetText("<")
    d.prev:SetScript("OnClick", function()
        Tab.scene = Tab.scene - 1
        Tab.Refresh()
    end)
    d.next = U.Chip(d, 26, 22)
    d.next:SetPoint("TOPRIGHT", 0, navY)
    d.next.label:SetText(">")
    d.next:SetScript("OnClick", function()
        Tab.scene = Tab.scene + 1
        Tab.Refresh()
    end)
    d.sceneText = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.sceneText:SetPoint("LEFT", d.prev, "RIGHT", 6, 0)
    d.sceneText:SetPoint("RIGHT", d.next, "LEFT", -6, 0)
    d.sceneText:SetJustifyH("CENTER")
    d.sceneText:SetWordWrap(false)

    d.message = U.Label(d, "GameFontHighlightSmall", 0, navY - 26)
    d.message:SetWidth(detailW)

    -- A plan of your own. Top row: 100 + 4 + 100 + 4 + 134 = 342.
    d.edit = DW.CreateButton(d, 100, 26, "gold")
    d.edit:SetPoint("BOTTOMLEFT", 0, 30)
    d.edit:SetScript("OnClick", function()
        local entry = Tab.entry
        if entry and entry.type == "plan" then
            T.OpenEditor(entry.plan.id)
        end
    end)

    d.play = DW.CreateButton(d, 100, 26, "gold")
    d.play:SetPoint("BOTTOMLEFT", 104, 30)
    d.play:SetScript("OnClick", function()
        local entry = Tab.entry
        if entry and type(T.Preview) == "function" then
            -- (A checked copy: for the draft, entry.plan is the table the editor works on.)
            T.Preview(T.Sanitize(entry.plan) or entry.plan, Tab.scene)
        end
    end)
    U.AddTip(d.play, "TAC_PLAY", "TAC_PLAY_TIP", "ANCHOR_TOP")

    d.present = DW.CreateButton(d, 134, 26, "gold")
    d.present:SetPoint("BOTTOMLEFT", 208, 30)
    d.present:SetScript("OnClick", function()
        local entry = Tab.entry
        if not entry then
            return
        end
        d.message:SetText("")
        local ok, reason = T.Present(entry.plan)
        if not ok then
            Tab.Problem(reason)
        end
    end)
    U.AddTip(d.present, "TAC_PRESENT", U.PresentTip, "ANCHOR_TOP")
    U.TipWhileDisabled(d.present)

    d.copy = U.Chip(d, 100, 26)
    d.copy:SetPoint("BOTTOMLEFT", 0, 0)
    d.copy:SetScript("OnClick", function()
        local entry = Tab.entry
        local copy = entry and T.CopyPlan(entry.plan)
        if not copy then
            return
        end
        d.message:SetText("")
        copy.name = U.CleanName(L.TAC_COPY_NAME:format(copy.name))
        local saved, reason = T.SavePlan(copy)
        if saved then
            T.SelectPlan(saved.id)
        else
            Tab.Problem(reason)
        end
    end)

    -- Red, and needs a second click, as elsewhere in the addon.
    d.delete = DW.CreateButton(d, 110, 26, "red")
    d.delete:SetPoint("BOTTOMRIGHT", 0, 0)
    d.delete:SetScript("OnClick", function(self)
        local entry = Tab.entry
        if entry and entry.type == "plan" and U.Confirmed(self, entry.plan.id) then
            T.DeletePlan(entry.plan.id)
        end
    end)
    d.delete:HookScript("OnLeave", function(self)
        U.Disarm(self, "TAC_DELETE")
    end)

    -- A plan a leader has shown you.
    d.keep = DW.CreateButton(d, 164, 26, "gold")
    d.keep:SetPoint("BOTTOMLEFT", 0, 30)
    d.keep:SetScript("OnClick", function()
        local entry = Tab.entry
        if not entry or entry.type ~= "received" then
            return
        end
        d.message:SetText("")
        local kept, reason = T.KeepReceived(entry.plan.id)
        if kept then
            T.SelectPlan(kept.id)
        else
            Tab.Problem(reason)
        end
    end)
    U.AddTip(d.keep, "TAC_KEEP", "TAC_KEEP_TIP", "ANCHOR_TOP")

    -- The unsaved draft.
    d.resume = DW.CreateButton(d, 164, 26, "gold")
    d.resume:SetPoint("BOTTOMLEFT", 0, 30)
    d.resume:SetScript("OnClick", function()
        T.ResumeEditor()
    end)
    d.discard = DW.CreateButton(d, 110, 26, "red")
    d.discard:SetPoint("BOTTOMRIGHT", 0, 0)
    d.discard:SetScript("OnClick", function(self)
        local entry = Tab.entry
        if entry and entry.type == "draft" and U.Confirmed(self, "draft") then
            Ed.DropDraft()
        end
    end)
    d.discard:HookScript("OnLeave", function(self)
        U.Disarm(self, "TAC_DRAFT_DISCARD")
    end)

    f:SetScript("OnShow", function()
        Tab.Refresh()
    end)
    return f
end

-- Chooses a saved plan in the tab's list.
function T.SelectPlan(id)
    if type(id) ~= "string" then
        return
    end
    Tab.selected = { type = "plan", id = id }
    Tab.Refresh()
end

-- The editor: what it works with ---------------------------------------------------------

Ed.NAME = "DragonworldTacticsEditor"
Ed.scene = 1         -- the scene on the board
Ed.armed = "select"  -- the tool in hand: a key of Ed.tools
Ed.colour, Ed.size, Ed.label = 1, 2, "" -- what the next thing placed gets
Ed.ticked = {}       -- [group] = true for the groups ticked in the raid panel
Ed.mapNames = {}     -- [uiMapID] = the name of a map the room menu has listed

-- The tools as the board wants them (see Board:SetTool). The board reads the
-- table at each click, so the colour, the size and the label are changed in
-- place (Ed.SyncTools).
Ed.tools = {
    select = { kind = "select" },
    m = { kind = "m" },
    p = { kind = "p" },
    g = { kind = "g", g = {} },
    t = { kind = "t" },
    a = { kind = "a" },
    l = { kind = "l" },
    z = { kind = "z" },
    erase = { kind = "erase" },
    bg = { kind = "bg" },
}

-- The names of the tools that have a button of their own.
Ed.TOOL_TEXT = {
    select = "TAC_TOOL_SELECT", a = "TAC_TOOL_ARROW", l = "TAC_TOOL_LINE", z = "TAC_TOOL_AREA",
    t = "TAC_TOOL_TEXT", erase = "TAC_TOOL_ERASE", bg = "TAC_TOOL_BG",
}
Ed.TOOL_ORDER = { "select", "a", "l", "z", "t", "erase" }

-- Which kinds of item have a colour, a size and a label.
Ed.HAS_COLOUR = { m = true, a = true, l = true, z = true, t = true }
Ed.HAS_SIZE = { m = true, a = true, l = true, t = true }
Ed.HAS_LABEL = { m = true, g = true, t = true }

-- Is the editor open on a plan?
function Ed.Ready()
    return Ed.frame ~= nil and Ed.plan ~= nil and Ed.frame:IsShown()
end

-- The scene on the board.
function Ed.Scene()
    local scenes = Ed.plan.scenes
    Ed.scene = max(1, min(#scenes, Ed.scene))
    return scenes[Ed.scene]
end

-- The room or map under the scene on the board; nil when there is none (or
-- no plan: a menu may still ask while the window closes).
function Ed.Background()
    local bg = Ed.plan and Ed.Scene().bg
    return type(bg) == "table" and bg or nil
end

function Ed.IsMap()
    local bg = Ed.Background()
    return bg ~= nil and bg.kind == "map"
end

-- The line next to the window's title: whether there is unsaved work, or what
-- just happened.
function Ed.Status(text, colour)
    local status = Ed.frame.status
    status:SetText(text or "")
    U.Paint(status, colour or U.GREY)
end

-- Something in the plan changed: it is unsaved from now on.
function Ed.Changed()
    if not Ed.plan then
        return
    end
    local draft = Ed.Draft()
    local was = draft and draft.dirty
    if draft then
        draft.dirty = true
    end
    Ed.RefreshMeter()
    if Ed.tooBig then
        Ed.Status(L.TAC_ERR_TOO_BIG, U.RED)
    else
        Ed.Status(L.TAC_ED_UNSAVED, U.ORANGE)
    end
    Ed.RefreshUndo()
    if not was then
        Tab.Refresh() -- the draft is in the list from now on
    end
end

-- Writes the colour, the size and the label for the next thing into the tools.
function Ed.SyncTools()
    local tools = Ed.tools
    tools.m.c, tools.m.s, tools.m.t = Ed.colour, Ed.size, Ed.label
    tools.t.c, tools.t.s, tools.t.t = Ed.colour, Ed.size, Ed.label
    tools.a.c, tools.a.s = Ed.colour, Ed.size
    tools.l.c, tools.l.s = Ed.colour, Ed.size
    tools.z.c = Ed.colour
    tools.g.t = Ed.label
end

-- Takes a tool in hand. kind is a key of Ed.tools; a marker ("m") comes with
-- its icon, a player ("p") with the name and the class. The groups ("g") are
-- the ones ticked in the raid panel.
function Ed.Arm(kind, value, class)
    local tools = Ed.tools
    if kind == "m" then
        tools.m.i = value
        Ed.colour = T.IconArt(value).c or Ed.colour -- start with the colour that suits the icon
    elseif kind == "p" then
        tools.p.n, tools.p.cl = value, class or ""
    elseif kind == "bg" and not Ed.IsMap() then
        kind = "select" -- only a map can be moved
    end
    if kind == "g" then
        local groups = {}
        for group = 1, 8 do
            if Ed.ticked[group] then
                groups[#groups + 1] = group
            end
        end
        if #groups == 0 then
            kind = "select"
        end
        tools.g.g = groups
    else
        U.Wipe(Ed.ticked)
    end
    Ed.armed = kind
    Ed.SyncTools()
    Ed.board:SetTool(tools[kind])
    if kind ~= "select" then
        Ed.board:Select(nil) -- from here on the colour, the size and the label are for what comes next
    end
    Ed.RefreshTools()
    Ed.RefreshSelection()
    if kind == "t" and Ed.label == "" and Ed.Ready() then
        Ed.frame.labelBox:SetFocus() -- a text needs its words first
    end
end

-- The selected item when the label field is about it: only with the select
-- tool. With any other tool in hand the field is for what is placed next.
function Ed.LabelTarget()
    if Ed.armed ~= "select" then
        return nil
    end
    local _, item = Ed.board:GetSelected()
    if item and Ed.HAS_LABEL[item.k] then
        return item
    end
    return nil
end

-- A colour was clicked: for what comes next, and for the selected item.
function Ed.SetColour(index)
    Ed.colour = index
    local at, item = Ed.board:GetSelected()
    if item and Ed.HAS_COLOUR[item.k] and item.c ~= index then
        Ed.board:PushUndo("colour" .. tostring(at)) -- (per item: two items recoloured quickly are two steps)
        item.c = index
        Ed.board:Redraw()
        Ed.Changed()
    end
    Ed.SyncTools()
    Ed.RefreshSelection()
end

function Ed.SetSize(size)
    Ed.size = size
    local at, item = Ed.board:GetSelected()
    if item and Ed.HAS_SIZE[item.k] and item.s ~= size then
        Ed.board:PushUndo("size" .. tostring(at))
        item.s = size
        Ed.board:Redraw()
        Ed.Changed()
    end
    Ed.SyncTools()
    Ed.RefreshSelection()
end

-- The label field was typed in.
function Ed.SetLabel(text)
    text = U.CleanLabel(text)
    local item = Ed.LabelTarget()
    if not item then
        Ed.label = text
        Ed.SyncTools()
        return
    end
    -- A text on the board must say something: an empty field leaves it alone.
    if item.t == text or (item.k == "t" and text == "") then
        return
    end
    -- The letters of one word are one step to undo (per item).
    Ed.board:PushUndo("label" .. tostring((Ed.board:GetSelected())))
    item.t = text
    Ed.board:Redraw()
    Ed.Changed()
end

-- Shows another scene of the plan on the board.
function Ed.ShowScene(index)
    Ed.scene = index
    local scene = Ed.Scene()
    local draft = Ed.Draft()
    if draft then
        draft.scene = Ed.scene
    end
    Ed.board:SetScene(scene)
    Ed.RefreshRoom()
    Ed.RefreshStrip()
    Ed.RefreshSceneFields()
    Ed.RefreshSelection()
end

-- Adds a scene after the one on the board, and shows it. copy: it starts as
-- a copy of this one (the next phase usually moves a few things); otherwise
-- it is empty, in the same room.
function Ed.AddScene(copy)
    local scenes = Ed.plan.scenes
    if #scenes >= T.MAX_SCENES then
        Ed.Status(L.TAC_SCENE_MAX:format(T.MAX_SCENES), U.RED)
        return
    end
    local current = Ed.Scene()
    local scene
    if copy then
        scene = T.NewScene(current)
    else
        scene = T.NewScene()
        scene.bg = T.SanitizeScene({ bg = current.bg }).bg
    end
    table.insert(scenes, Ed.scene + 1, scene)
    Ed.ShowScene(Ed.scene + 1)
    Ed.Changed()
end

function Ed.DeleteScene()
    local scenes = Ed.plan.scenes
    if #scenes <= 1 then
        return
    end
    table.remove(scenes, Ed.scene)
    Ed.ShowScene(min(Ed.scene, #scenes))
    Ed.Changed()
end

-- Moves the scene on the board one place earlier (-1) or later (1).
function Ed.MoveScene(step)
    local scenes = Ed.plan.scenes
    local other = Ed.scene + step
    if other < 1 or other > #scenes then
        return
    end
    scenes[Ed.scene], scenes[other] = scenes[other], scenes[Ed.scene]
    Ed.ShowScene(other) -- the same scene: the board keeps what can be undone
    Ed.Changed()
end

-- The dungeon or raid was chosen in the menu. 0 is "Other": the name is typed.
function Ed.ChooseInstance(id)
    local plan = Ed.plan
    if not plan then
        return
    end
    if id == 0 then
        Ed.otherPicked = true
        if plan.inst ~= 0 then
            plan.inst, plan.instName = 0, ""
        end
    else
        local dungeon = DW.DUNGEON_BY_ID and DW.DUNGEON_BY_ID[id]
        if not dungeon then
            return
        end
        plan.inst, plan.instName = id, U.CleanName(dungeon.name)
        Ed.otherPicked = false
    end
    Ed.Changed()
    Ed.RefreshMeta()
    if id == 0 then
        Ed.frame.otherBox:SetFocus()
    end
end

function Ed.OpenInstanceMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        Ed.ChooseInstance(0) -- without the menu the name can still be typed
        return
    end
    local instances = T.Instances()
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local function IsChosen(id)
            local plan = Ed.plan
            if not plan then
                return false
            elseif id == 0 then
                return plan.inst == 0 and (plan.instName ~= "" or Ed.otherPicked == true)
            end
            return plan.inst == id
        end
        local function Choose(id)
            Ed.ChooseInstance(id)
            return U.CloseMenu()
        end
        -- Some forty lines: the menu scrolls instead of leaving the screen.
        if root.SetScrollMode then
            root:SetScrollMode(480)
        end
        root:CreateRadio(L.TAC_ED_OTHER, IsChosen, Choose, 0)
        root:CreateTitle(L.TAC_ED_DUNGEONS)
        for _, instance in ipairs(instances) do
            if not instance.raid then
                root:CreateRadio(instance.name, IsChosen, Choose, instance.id)
            end
        end
        root:CreateTitle(L.TAC_ED_RAIDS)
        for _, instance in ipairs(instances) do
            if instance.raid then
                root:CreateRadio(instance.name, IsChosen, Choose, instance.id)
            end
        end
    end)
end

-- The bosses of the chosen dungeon or raid. Any other name can be typed.
function Ed.OpenBossMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    local bosses = {}
    for _, instance in ipairs(T.Instances()) do
        if instance.id == Ed.plan.inst then
            bosses = instance.bosses
        end
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if root.SetScrollMode then
            root:SetScrollMode(480)
        end
        root:CreateTitle(#bosses > 0 and L.TAC_ED_BOSS or L.TAC_ED_BOSS_NONE)
        for _, name in ipairs(bosses) do
            root:CreateRadio(name, function(data)
                return Ed.plan ~= nil and Ed.plan.boss == data
            end, function(data)
                if Ed.plan then
                    Ed.plan.boss = U.CleanName(data)
                    Ed.Changed()
                    Ed.RefreshMeta()
                end
                return U.CloseMenu()
            end, name)
        end
    end)
end

-- Another room for the scene on the board: a drawn one...
function Ed.ChooseRoom(id)
    if not Ed.plan then
        return
    end
    local scene = Ed.Scene()
    Ed.board:PushUndo()
    scene.bg = { kind = "room", room = id }
    Ed.board:Redraw()
    Ed.Changed()
    Ed.RefreshRoom()
end

-- ...or one of the game's maps, whole and in the middle to start with. The
-- tool that moves it is taken in hand, since that is what comes next.
function Ed.ChooseMap(map)
    if not Ed.plan then
        return
    end
    local scene = Ed.Scene()
    Ed.board:PushUndo()
    scene.bg = { kind = "map", map = map, zoom = T.MIN_ZOOM, cx = 500, cy = 500 }
    Ed.board:Redraw()
    Ed.Changed()
    Ed.RefreshRoom()
    Ed.Arm("bg")
end

function Ed.OpenRoomMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Without the menu: the next drawn room on each click.
        local bg = Ed.Background()
        local at = 0
        for index, room in ipairs(T.ROOMS) do
            if bg and bg.kind == "room" and bg.room == room.id then
                at = index
            end
        end
        Ed.ChooseRoom(T.ROOMS[at % #T.ROOMS + 1].id)
        return
    end
    -- Finding a dungeon's maps can take a moment the first time, so it is
    -- done here, when the menu is asked for, and not when the window opens.
    local maps = Ed.plan.inst ~= 0 and T.InstanceMaps(Ed.plan.inst) or {}
    for _, map in ipairs(maps) do
        Ed.mapNames[map.map] = map.name
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local function IsRoom(id)
            local now = Ed.Background()
            return now ~= nil and now.kind == "room" and now.room == id
        end
        local function IsMap(map)
            local now = Ed.Background()
            return now ~= nil and now.kind == "map" and now.map == map
        end
        local function Room(id)
            Ed.ChooseRoom(id)
            return U.CloseMenu()
        end
        local function Map(map)
            Ed.ChooseMap(map)
            return U.CloseMenu()
        end
        root:CreateTitle(L.TAC_ROOM_DRAWN)
        for _, room in ipairs(T.ROOMS) do
            root:CreateRadio(U.RoomName(room.id), IsRoom, Room, room.id)
        end
        root:CreateTitle(L.TAC_ROOM_MAPS)
        if #maps == 0 then
            local none = root:CreateButton(Ed.plan.inst ~= 0 and L.TAC_ROOM_NO_MAPS or L.TAC_ROOM_NEED_INSTANCE, function() end)
            if none and none.SetEnabled then
                none:SetEnabled(false)
            end
        end
        for _, map in ipairs(maps) do
            root:CreateRadio(map.name, IsMap, Map, map.map)
        end
    end)
end

-- The editor: drawing it again ---------------------------------------------------------------

-- Every text that does not depend on the plan, in the chosen language.
function Ed.RefreshTexts()
    local f = Ed.frame
    f.title:SetText(L.TAC_ED_TITLE)
    f.save.label:SetText(L.TAC_ED_SAVE)
    f.play.label:SetText(L.TAC_PLAY)
    f.present.label:SetText(L.TAC_PRESENT)
    f.close.label:SetText(L.TAC_ED_CLOSE)
    f.nameLabel:SetText(L.TAC_ED_NAME)
    f.instLabel:SetText(L.TAC_ED_INSTANCE)
    f.bossLabel:SetText(L.TAC_ED_BOSS)

    f.toolsLabel:SetText(L.TAC_TOOLS)
    for kind, chip in pairs(f.toolChips) do
        chip.label:SetText(L[Ed.TOOL_TEXT[kind]])
    end
    f.markersLabel:SetText(L.TAC_MARKERS)
    f.colourLabel:SetText(L.TAC_COLOR)
    f.sizeLabel:SetText(L.TAC_SIZE)
    for size, chip in ipairs(f.sizeChips) do
        chip.label:SetText(L["TAC_SIZE_" .. size])
    end
    f.labelLabel:SetText(L.TAC_LABEL)
    f.undoChip.label:SetText(L.TAC_UNDO)
    f.deleteChip.label:SetText(L.TAC_DELETE)
    f.frontChip.label:SetText(L.TAC_FRONT)
    f.backChip.label:SetText(L.TAC_BACK)
    f.roomLabel:SetText(L.TAC_ROOM)
    f.bgChip.label:SetText(L.TAC_TOOL_BG)

    f.raidLabel:SetText(L.TAC_RAID)

    f.sceneNew.label:SetText(L.TAC_SCENE_NEW)
    f.sceneEmpty.label:SetText(L.TAC_SCENE_EMPTY)
    f.sceneEarlier.label:SetText(L.TAC_SCENE_EARLIER)
    f.sceneLater.label:SetText(L.TAC_SCENE_LATER)
    U.Disarm(f.sceneDelete, "TAC_SCENE_DELETE")
    f.sceneTitleLabel:SetText(L.TAC_SCENE_TITLE)
    f.notesLabel:SetText(L.TAC_SCENE_NOTES)

    f.prompt.keep.label:SetText(L.TAC_DRAFT_KEEP)
    f.prompt.drop.label:SetText(L.TAC_DRAFT_DROP)
end

-- The name, the dungeon or raid and the boss.
function Ed.RefreshMeta()
    if not Ed.Ready() then
        return
    end
    local f, plan = Ed.frame, Ed.plan
    U.SetBox(f.nameBox, plan.name)
    U.SetBox(f.bossBox, plan.boss)
    -- The chip is 326 wide; with "Other" it leaves room for the typed name
    -- (170 + 12 + 144 = 326).
    if plan.inst ~= 0 then
        f.instChip.label:SetText(plan.instName)
        f.instChip:SetWidth(326)
        f.otherBox:Hide()
    elseif plan.instName ~= "" or Ed.otherPicked then
        f.instChip.label:SetText(L.TAC_ED_OTHER_SHORT)
        f.instChip:SetWidth(170)
        f.otherBox:Show()
        U.SetBox(f.otherBox, plan.instName)
    else
        f.instChip.label:SetText(L.TAC_ED_CHOOSE)
        f.instChip:SetWidth(326)
        f.otherBox:Hide()
    end
end

-- What the tool in hand does, under the scene's title.
function Ed.HintText()
    local kind = Ed.armed
    local name, text
    if kind == "m" then
        name, text = U.IconName(Ed.tools.m.i), L.TAC_MARKER_TIP
    elseif kind == "g" then
        name, text = L.TAC_RAID_PLACING:format(Geo.GroupText(Ed.tools.g.g)), L.TAC_GROUP_TIP
    elseif kind == "p" then
        name, text = tostring(Ed.tools.p.n), L.TAC_PLAYER_TIP
    else
        name, text = L[Ed.TOOL_TEXT[kind]], L[Ed.TOOL_TEXT[kind] .. "_TIP"]
    end
    return ("|cffffd100%s|r\n%s"):format(name, text)
end

-- Which tool is in hand: its button lit, the others not.
function Ed.RefreshTools()
    if not Ed.Ready() then
        return
    end
    local f, armed, tools = Ed.frame, Ed.armed, Ed.tools
    for kind, chip in pairs(f.toolChips) do
        chip:SetSelected(armed == kind)
    end
    for _, cell in ipairs(f.cells) do
        cell:SetSelected(armed == "m" and tools.m.i == cell.id)
    end
    f.bgChip:SetSelected(armed == "bg")
    for group, row in ipairs(f.groupRows) do
        local on = armed == "g" and Ed.ticked[group] == true
        row.check:SetChecked(on)
        row.chip:SetSelected(on)
    end
    for _, row in ipairs(f.memberRows) do
        row.mark:SetShown(armed == "p" and row:IsShown() and row.who == tools.p.n)
    end
    f.hint:SetText(Ed.HintText())

    if armed == "g" then
        f.raidHint:SetText(L.TAC_RAID_PLACING:format(Geo.GroupText(tools.g.g)))
        U.Paint(f.raidHint, U.GOLD)
    else
        f.raidHint:SetText(Ed.inGroup and L.TAC_RAID_HOW or L.TAC_RAID_SOLO)
        U.Paint(f.raidHint, U.GREY)
    end
end

function Ed.RefreshUndo()
    if not Ed.Ready() then
        return
    end
    U.SetChipOn(Ed.frame.undoChip, Ed.board:CanUndo())
end

-- The colour, the size and the label: those of the selected item, or what the
-- next thing placed will get.
function Ed.RefreshSelection()
    if not Ed.Ready() then
        return
    end
    local f = Ed.frame
    local _, item = Ed.board:GetSelected()
    local colour = item and Ed.HAS_COLOUR[item.k] and item.c or Ed.colour
    local size = item and Ed.HAS_SIZE[item.k] and item.s or Ed.size
    for index, cell in ipairs(f.swatches) do
        cell:SetSelected(index == colour)
    end
    for index, chip in ipairs(f.sizeChips) do
        chip:SetSelected(index == size)
    end
    local target = Ed.LabelTarget()
    U.SetBox(f.labelBox, target and target.t or Ed.label)
    local has = item ~= nil
    U.SetChipOn(f.deleteChip, has)
    U.SetChipOn(f.frontChip, has)
    U.SetChipOn(f.backChip, has)
    Ed.RefreshUndo()
end

-- The room: its name, whether the map can be moved, and a word when the
-- scene asks for a map this game has no picture of.
function Ed.RefreshRoom()
    if not Ed.Ready() then
        return
    end
    local f = Ed.frame
    local bg = Ed.Background()
    local isMap = bg ~= nil and bg.kind == "map"
    if isMap then
        f.roomChip.label:SetText(Ed.mapNames[bg.map] or L.TAC_ROOM_MAP)
    else
        f.roomChip.label:SetText(U.RoomName(bg and bg.room or "round"))
    end
    local movable = isMap and not Ed.board.mapMissing
    f.bgChip:SetDimmed(not movable)
    f.missing:SetText(Ed.board.mapMissing and L.TAC_MAP_MISSING or "")
    if Ed.armed == "bg" and not movable then
        Ed.Arm("select")
    end
end

-- One line of the raid panel: a player.
function Ed.MemberRow(index)
    local f = Ed.frame
    local row = f.memberRows[index]
    if not row then
        row = CreateFrame("Button", nil, f.raidContent)
        row:SetSize(122, 14)
        row.mark = row:CreateTexture(nil, "BACKGROUND")
        row.mark:SetAllPoints()
        row.mark:SetColorTexture(1.00, 0.82, 0.00, 0.30)
        row.mark:Hide()
        row.glow = row:CreateTexture(nil, "HIGHLIGHT")
        row.glow:SetAllPoints()
        row.glow:SetColorTexture(1, 1, 1, 0.12)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 2, 0)
        row.text:SetPoint("RIGHT", -2, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            Ed.Arm("p", self.who, self.class)
        end)
        U.AddTip(row, function(self)
            return self.who
        end, "TAC_PLAYER_TIP", "ANCHOR_LEFT")
        f.memberRows[index] = row
    end
    return row
end

-- The raid panel: the eight groups, always, and under each who is in it now.
-- A group's line is 22 high, a player's 14.
function Ed.RefreshRaid()
    if not Ed.Ready() then
        return
    end
    local f = Ed.frame
    local roster = T.Roster()
    Ed.inGroup = roster.inGroup == true
    local y, used = 0, 0
    for group = 1, 8 do
        local row = f.groupRows[group]
        local members = roster.groups[group] or {}
        row.check:ClearAllPoints()
        row.check:SetPoint("TOPLEFT", 0, -y)
        row.chip:ClearAllPoints()
        row.chip:SetPoint("TOPLEFT", 22, -y)
        local text = L.TAC_GROUP_N:format(group)
        if #members > 0 then
            text = ("%s (%d)"):format(text, #members)
        end
        row.chip.label:SetText(text)
        y = y + 22
        for _, member in ipairs(members) do
            used = used + 1
            local line = Ed.MemberRow(used)
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", 22, -y)
            line.who, line.class = member.name, member.class
            local role = member.role and Ed.ROLE_ICON[member.role]
            local name = member.name
            if member.online == false then
                name = "|cff808080" .. name .. "|r"
            else
                name = DW.ColoredName(name, member.class)
            end
            line.text:SetText((role and (DW.RoleIcon(role, 11) .. " ") or "") .. name)
            line:Show()
            y = y + 14
        end
        y = y + 2
    end
    for index = used + 1, #f.memberRows do
        f.memberRows[index]:Hide()
    end
    f.raidContent:SetHeight(max(1, y))
    Ed.RefreshTools()
end

-- The strip of scenes under the board, and the buttons that change it. Ten
-- scenes share the board's 600: floor((600 - 9 * 4) / 10) = 56 each; fewer
-- get up to 110.
function Ed.RefreshStrip()
    if not Ed.Ready() then
        return
    end
    local f = Ed.frame
    local scenes = Ed.plan.scenes
    local count = #scenes
    local width = min(110, floor((600 - (count - 1) * 4) / count))
    for index, chip in ipairs(f.sceneChips) do
        local scene = scenes[index]
        if scene then
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", 208 + (index - 1) * (width + 4), -463)
            chip:SetWidth(width)
            chip.label:SetText(scene.title ~= "" and (index .. " " .. scene.title) or tostring(index))
            chip:SetSelected(index == Ed.scene)
            chip:Show()
        else
            chip:Hide()
        end
    end
    local room = count < T.MAX_SCENES
    f.sceneNew:SetActive(room)
    U.SetChipOn(f.sceneEmpty, room)
    U.SetChipOn(f.sceneEarlier, Ed.scene > 1)
    U.SetChipOn(f.sceneLater, Ed.scene < count)
    f.sceneDelete:SetActive(count > 1)
end

-- The title and the notes of the scene on the board.
function Ed.RefreshSceneFields()
    if not Ed.Ready() then
        return
    end
    local f = Ed.frame
    local scene = Ed.Scene()
    U.SetBox(f.sceneTitle, scene.title or "")
    for index, box in ipairs(f.noteBoxes) do
        U.SetBox(box, type(scene.notes) == "table" and scene.notes[index] or "")
    end
end

-- How much of what can be sent to a group the plan uses.
function Ed.RefreshMeter()
    if not Ed.plan or not Ed.frame then
        return
    end
    local f = Ed.frame
    local share = T.PlanBytes(Ed.plan) / T.MAX_BYTES
    local percent = floor(share * 100 + 0.5)
    local key, colour = "TAC_METER", U.GREEN
    if share > 1 then
        key, colour = "TAC_METER_OVER", U.RED
    elseif share >= 0.8 then
        key, colour = "TAC_METER_NEAR", U.ORANGE
    end
    Ed.tooBig = share > 1
    f.meterText:SetText(L[key]:format(percent))
    U.Paint(f.meterText, share >= 0.8 and colour or U.GREY)
    f.meterFill:SetWidth(max(1, min(1, share) * 210))
    f.meterFill:SetColorTexture(colour[1], colour[2], colour[3], 1)
end

-- Play and Show to group: whether they can be used now.
function Ed.RefreshButtons()
    if not Ed.Ready() then
        return
    end
    local f = Ed.frame
    local can, reason = U.PresentState()
    f.present:SetActive(can)
    f.present.reason = reason
    f.play:SetActive(type(T.Preview) == "function")
end

function Ed.RefreshAll()
    if not Ed.Ready() then
        return
    end
    Ed.RefreshTexts()
    Ed.RefreshMeta()
    Ed.RefreshRoom()
    Ed.RefreshRaid() -- and the tools
    Ed.RefreshSelection()
    Ed.RefreshStrip()
    Ed.RefreshSceneFields()
    Ed.RefreshMeter()
    Ed.RefreshButtons()
end

-- The editor: opening, saving, closing -------------------------------------------------------

-- Makes the window as large as it can be on this screen, at most its own size.
function Ed.FitScreen()
    local f = Ed.frame
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    local scale = 1
    if type(width) == "number" and type(height) == "number" and not DW.IsSecret(width) and not DW.IsSecret(height)
        and width > 0 and height > 0 then
        scale = min(1, width / f:GetWidth(), height / f:GetHeight())
    end
    if f.SetScale then
        f:SetScale(max(0.5, scale))
    end
end

-- Puts a plan in the editor as the working copy, and with that in the draft.
function Ed.Load(plan, dirty, scene)
    local db = U.DB()
    local f = Ed.frame
    db.draft = { plan = plan, scene = scene or 1, dirty = dirty and true or false }
    Ed.plan = plan
    Ed.scene = scene or 1
    Ed.otherPicked = false
    Ed.label = ""
    Ed.board:SetScene(Ed.Scene())
    Ed.Arm("select")
    f.status:SetText("")
    if dirty then
        Ed.Status(L.TAC_ED_UNSAVED, U.ORANGE)
    end
    if f:IsShown() then
        Ed.RefreshAll()
    else
        f:Show() -- draws everything
    end
end

-- Saves the working copy to the library. True when it was saved.
function Ed.Save()
    local plan = Ed.plan
    if not plan then
        return false
    end
    local saved, reason = T.SavePlan(plan)
    if not saved then
        Ed.Status(L[reason or "TAC_ERR_BAD_PLAN"], U.RED)
        if reason == "TAC_ERR_NO_NAME" then
            Ed.frame.nameBox:SetFocus()
        end
        return false
    end
    plan.author, plan.updated = saved.author, saved.updated
    local draft = Ed.Draft()
    if draft then
        draft.dirty = false
    end
    Ed.Status(L.TAC_ED_SAVED, U.GREEN)
    T.SelectPlan(saved.id)
    return true
end

-- Throws the draft away, with everything in it that is not saved.
function Ed.DropDraft()
    local db = U.DB()
    if db then
        db.draft = nil
    end
    Ed.plan = nil
    if Ed.frame then
        Ed.frame.prompt:Hide()
        Ed.frame:Hide()
    end
    Tab.Refresh()
end

-- The question when the editor is asked for something else while there is
-- unsaved work: go on with that, or throw it away. wanted is the id of the
-- plan that was asked for (nil: a new one).
function Ed.Ask(wanted)
    local prompt = Ed.frame.prompt
    prompt.wanted = wanted
    prompt.text:SetText(L.TAC_DRAFT_ASK:format(U.PlanName(Ed.plan)))
    prompt:Show()
end

-- Opens the editor on the saved plan with this id, or on a new plan when
-- there is no id. Unsaved work on something else is not lost: the editor
-- opens on that, and asks. False when it could not be opened.
function T.OpenEditor(id)
    if not DW.GuardPersonal() then
        return false
    end
    if not U.DB() then
        return false
    end
    if id ~= nil and not T.GetPlan(id) then
        return false
    end
    if not Ed.frame then
        Ed.Create()
    end
    local unsaved = Ed.Unsaved()
    if unsaved then
        if Ed.plan ~= unsaved.plan then
            Ed.Load(unsaved.plan, true, unsaved.scene)
        else
            Ed.frame:Show()
        end
        Ed.Ask(id)
        return true
    end
    Ed.frame.prompt:Hide()
    Ed.Load(id and T.GetPlan(id) or T.NewPlan(""), false)
    return true
end

-- Opens the editor on the unsaved draft. False when there is none.
function T.ResumeEditor()
    local unsaved = Ed.Unsaved()
    if not unsaved or not DW.GuardPersonal() then
        return false
    end
    if not Ed.frame then
        Ed.Create()
    end
    Ed.frame.prompt:Hide()
    if Ed.plan ~= unsaved.plan then
        Ed.Load(unsaved.plan, true, unsaved.scene)
    else
        Ed.frame:Show()
    end
    return true
end

-- Closes the editor. Unsaved work stays as the draft.
function T.CloseEditor()
    if Ed.frame then
        Ed.frame:Hide()
    end
end

-- The editor: building the window --------------------------------------------------------------
--
-- 1000 x 640. From the top:
--   y  10 to  34   the title, a line for what just happened, and Save, Play,
--                  Show to group, Close
--   y  42 to  78   the plan's name, its dungeon or raid, its boss, the size meter
--   y  84 to 630   three columns: the tools (x 12 to 198), the board with the
--                  scenes under it (x 208 to 808) and the raid (x 818 to 988)
-- The board is 600 x 375 (y 84 to 459). Under it: the strip of scenes (463),
-- the buttons that add, move and delete a scene (488), and the scene's title
-- and notes (514 to 627).
function Ed.Create()
    local f = CreateFrame("Frame", Ed.NAME, UIParent, "BackdropTemplate")
    Ed.frame = f
    f:SetSize(1000, 640)
    -- Above the main window (strata HIGH) and above the windows that lie over
    -- it (same strata as this one, levels up to 50 above the main window's).
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)

    -- Remember where the window was moved to.
    local db = U.DB()
    local saved = db and db.editor
    if type(saved) == "table" and type(saved.point) == "string" then
        f:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, tonumber(saved.x) or 0, tonumber(saved.y) or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        local store = U.DB()
        if point and store then
            store.editor = { point = point, relativePoint = relativePoint, x = x, y = y }
        end
    end)
    -- Escape closes the window. (A text field that is being typed in takes
    -- Escape first, to leave the field.)
    table.insert(UISpecialFrames, Ed.NAME)

    -- The top row. From the right: Close 904 to 988, Show to group 748 to 898,
    -- Play 652 to 742, Save 546 to 646.
    f.title = U.Label(f, "GameFontNormalLarge", 16, -15)
    f.title:SetWidth(180)
    f.title:SetWordWrap(false)
    f.status = U.Label(f, "GameFontHighlightSmall", 204, -9)
    f.status:SetWidth(330) -- two lines fit above the next row

    f.close = U.Chip(f, 84, 24)
    f.close:SetPoint("TOPRIGHT", -12, -10)
    f.close:SetScript("OnClick", function()
        GameTooltip:Hide()
        T.CloseEditor()
    end)
    U.AddTip(f.close, "TAC_ED_CLOSE", "TAC_ED_CLOSE_TIP", "ANCHOR_BOTTOM")

    f.present = DW.CreateButton(f, 150, 24, "gold")
    f.present:SetPoint("RIGHT", f.close, "LEFT", -6, 0)
    f.present:SetScript("OnClick", function()
        local ok, reason = T.Present(Ed.plan)
        if not ok then
            Ed.Status(L[reason or "TAC_ERR_BAD_PLAN"], U.RED)
        end
    end)
    U.AddTip(f.present, "TAC_PRESENT", U.PresentTip, "ANCHOR_BOTTOM")
    U.TipWhileDisabled(f.present)

    f.play = DW.CreateButton(f, 90, 24, "gold")
    f.play:SetPoint("RIGHT", f.present, "LEFT", -6, 0)
    f.play:SetScript("OnClick", function()
        if type(T.Preview) == "function" then
            -- A copy: the working copy is the editor's alone.
            T.Preview(T.Sanitize(Ed.plan) or Ed.plan, Ed.scene)
        end
    end)
    U.AddTip(f.play, "TAC_PLAY", "TAC_PLAY_TIP", "ANCHOR_BOTTOM")

    f.save = DW.CreateButton(f, 100, 24, "gold")
    f.save:SetPoint("RIGHT", f.play, "LEFT", -6, 0)
    f.save:SetScript("OnClick", function()
        Ed.Save()
    end)

    -- The second row: a small heading at y 42 and the field at y 56 (22 high).
    -- A text field's frame art reaches some 5 further left than the field, so
    -- the fields start 6 in from their headings.
    f.nameLabel = U.Label(f, "GameFontNormalSmall", 16, -42)
    f.nameBox = U.Box(f, 180, T.MAX_NAME, function(text)
        Ed.plan.name = U.CleanName(text)
        Ed.Changed()
    end)
    f.nameBox:SetPoint("TOPLEFT", 22, -56) -- 22 to 202

    f.instLabel = U.Label(f, "GameFontNormalSmall", 214, -42)
    f.instChip = DW.CreateChip(f, 326, 22)
    f.instChip:SetPoint("TOPLEFT", 214, -56) -- 214 to 540, or to 384 with the field after it
    f.instChip:SetScript("OnClick", function(self)
        GameTooltip:Hide()
        Ed.OpenInstanceMenu(self)
    end)
    U.AddTip(f.instChip, "TAC_ED_INSTANCE", "TAC_ED_INSTANCE_TIP", "ANCHOR_BOTTOM")
    f.otherBox = U.Box(f, 144, T.MAX_NAME, function(text)
        if Ed.plan.inst == 0 then
            Ed.plan.instName = U.CleanName(text)
            Ed.Changed()
        end
    end)
    f.otherBox:SetPoint("TOPLEFT", 396, -56) -- 396 to 540
    f.otherBox:Hide()

    f.bossLabel = U.Label(f, "GameFontNormalSmall", 556, -42)
    f.bossBox = U.Box(f, 170, T.MAX_NAME, function(text)
        Ed.plan.boss = U.CleanName(text)
        Ed.Changed()
    end)
    f.bossBox:SetPoint("TOPLEFT", 562, -56) -- 562 to 732
    f.bossMenu = U.Arrow(f, "Down", 22)
    f.bossMenu:SetPoint("TOPLEFT", 738, -56) -- 738 to 760
    f.bossMenu:SetScript("OnClick", function(self)
        GameTooltip:Hide()
        Ed.OpenBossMenu(self)
    end)
    U.AddTip(f.bossMenu, "TAC_ED_BOSS", "TAC_ED_BOSS_TIP", "ANCHOR_BOTTOM")

    -- The size meter: 778 to 988.
    f.meterText = U.Label(f, "GameFontNormalSmall", 778, -42)
    f.meterText:SetWidth(210)
    f.meterText:SetWordWrap(false)
    f.meterBack = f:CreateTexture(nil, "ARTWORK")
    f.meterBack:SetPoint("TOPLEFT", 778, -62)
    f.meterBack:SetSize(210, 10)
    f.meterBack:SetColorTexture(0.14, 0.14, 0.17, 1)
    f.meterFill = f:CreateTexture(nil, "OVERLAY")
    f.meterFill:SetPoint("TOPLEFT", 778, -62)
    f.meterFill:SetSize(1, 10)
    f.meterHover = CreateFrame("Frame", nil, f)
    f.meterHover:SetPoint("TOPLEFT", 778, -40)
    f.meterHover:SetSize(210, 34)
    f.meterHover:EnableMouse(true)
    f.meterHover:SetScript("OnEnter", function(self)
        U.ShowTip(self, L.TAC_METER_TITLE, Ed.tooBig and L.TAC_ERR_TOO_BIG or L.TAC_METER_TIP, nil, nil, nil, "ANCHOR_BOTTOM")
    end)
    f.meterHover:SetScript("OnLeave", U.HideTip)

    Ed.CreateTools(f)
    Ed.CreateBoard(f)
    Ed.CreateScenes(f)
    Ed.CreateRaid(f)
    Ed.CreatePrompt(f)

    f:SetScript("OnShow", function()
        Ed.FitScreen()
        Ed.RefreshAll()
    end)
    f:SetScript("OnHide", function(self)
        -- Hidden only because the whole interface is: still open.
        if self:IsShown() then
            return
        end
        self.prompt:Hide()
        -- With nothing unsaved there is nothing to keep.
        local store = U.DB()
        local draft = store and store.draft
        if Ed.plan and draft and not draft.dirty then
            store.draft = nil
            Ed.plan = nil
        end
        Tab.Refresh()
    end)
    f:Hide()
    return f
end

-- The left column: 186 wide, at x 12, from y 84. The places below are from
-- its own top left corner.
function Ed.CreateTools(f)
    local left = CreateFrame("Frame", nil, f)
    left:SetPoint("TOPLEFT", 12, -84)
    left:SetSize(186, 546)
    f.left = left

    -- The tools: two columns of 91 (91 + 4 + 91 = 186), three rows 24 apart.
    f.toolsLabel = U.Label(left, "GameFontNormalSmall", 0, 0)
    f.toolChips = {}
    for index, kind in ipairs(Ed.TOOL_ORDER) do
        local chip = U.Chip(left, 91, 22)
        chip:SetPoint("TOPLEFT", ((index - 1) % 2) * 95, -14 - floor((index - 1) / 2) * 24)
        chip.tool = kind
        chip:SetScript("OnClick", function(self)
            Ed.Arm(self.tool)
        end)
        U.AddTip(chip, Ed.TOOL_TEXT[kind], Ed.TOOL_TEXT[kind] .. "_TIP")
        f.toolChips[kind] = chip
    end
    local y = -14 - 3 * 24 - 4 -- -90

    -- The markers: cells of 21, 23 apart, eight to a row (7 * 23 + 21 = 182).
    -- Each group starts a row of its own, except that the roles follow the
    -- enemies on the first, after a gap.
    f.markersLabel = U.Label(left, "GameFontNormalSmall", 0, y)
    y = y - 14
    f.cells = {}
    local x, lastGroup = 0, nil
    for _, icon in ipairs(T.ICONS) do
        if lastGroup and icon.group ~= lastGroup then
            if lastGroup == "enemy" and icon.group == "role" then
                x = x + 8
            else
                x, y = 0, y - 23
            end
        end
        if x + 21 > 186 then
            x, y = 0, y - 23
        end
        local cell = U.Cell(left, 21)
        cell:SetPoint("TOPLEFT", x, y)
        cell.id, cell.group = icon.id, icon.group
        T.PaintIcon(cell.icon, icon.id)
        cell:SetScript("OnClick", function(self)
            Ed.Arm("m", self.id)
        end)
        cell:HookScript("OnEnter", function(self)
            local group = U.Words("TAC_ICONS_" .. tostring(self.group):upper())
            U.ShowTip(self, U.IconName(self.id), (group and (group .. ". ") or "") .. L.TAC_MARKER_TIP)
        end)
        cell:HookScript("OnLeave", U.HideTip)
        f.cells[#f.cells + 1] = cell
        x, lastGroup = x + 23, icon.group
    end
    y = y - 21 - 6 -- -200 with the 31 icons of this version

    -- The colours, one cell each.
    f.colourLabel = U.Label(left, "GameFontNormalSmall", 0, y)
    y = y - 14
    f.swatches = {}
    for index, colour in ipairs(T.COLORS) do
        local cell = U.Cell(left, 21)
        cell:SetPoint("TOPLEFT", (index - 1) * 23, y)
        cell.index = index
        cell.icon:SetColorTexture(colour[1], colour[2], colour[3], 1)
        cell:SetScript("OnClick", function(self)
            Ed.SetColour(self.index)
        end)
        cell:HookScript("OnEnter", function(self)
            U.ShowTip(self, U.ColourName(self.index), L.TAC_COLOR_TIP)
        end)
        cell:HookScript("OnLeave", U.HideTip)
        f.swatches[index] = cell
    end
    y = y - 21 - 6

    -- The sizes: three chips of 58, 64 apart (2 * 64 + 58 = 186).
    f.sizeLabel = U.Label(left, "GameFontNormalSmall", 0, y)
    y = y - 14
    f.sizeChips = {}
    for size = 1, 3 do
        local chip = U.Chip(left, 58, 22, true)
        chip:SetPoint("TOPLEFT", (size - 1) * 64, y)
        chip.size = size
        chip:SetScript("OnClick", function(self)
            Ed.SetSize(self.size)
        end)
        U.AddTip(chip, "TAC_SIZE", "TAC_SIZE_TIP")
        f.sizeChips[size] = chip
    end
    y = y - 22 - 6

    -- The label, or the words of a text.
    f.labelLabel = U.Label(left, "GameFontNormalSmall", 0, y)
    y = y - 14
    f.labelBox = U.Box(left, 176, T.MAX_LABEL, Ed.SetLabel)
    f.labelBox:SetPoint("TOPLEFT", 6, y) -- 6 to 182
    U.AddTip(f.labelBox, "TAC_LABEL", "TAC_LABEL_TIP")
    y = y - 22 - 8

    -- Undo, delete, to the front, to the back: two columns, two rows.
    -- (The Delete key is not used for the second: a window that takes the
    -- keyboard has to pass every other key on, and the game does not let an
    -- addon change that in combat, so the keys to move and fight could get
    -- stuck in this window.)
    local function Action(column, row, title, onClick)
        local chip = U.Chip(left, 91, 22, true)
        chip:SetPoint("TOPLEFT", column * 95, y - row * 24)
        chip:SetScript("OnClick", onClick)
        U.AddTip(chip, title, title .. "_TIP")
        return chip
    end
    f.undoChip = Action(0, 0, "TAC_UNDO", function()
        Ed.board:Undo()
    end)
    f.deleteChip = Action(1, 0, "TAC_DELETE", function()
        Ed.board:DeleteSelected()
    end)
    f.frontChip = Action(0, 1, "TAC_FRONT", function()
        Ed.board:RaiseSelected()
    end)
    f.backChip = Action(1, 1, "TAC_BACK", function()
        Ed.board:LowerSelected()
    end)
    y = y - 2 * 24 - 6

    -- The room, and the tool that moves a map.
    f.roomLabel = U.Label(left, "GameFontNormalSmall", 0, y)
    y = y - 14
    f.roomChip = U.Chip(left, 186, 22)
    f.roomChip:SetPoint("TOPLEFT", 0, y)
    f.roomChip:SetScript("OnClick", function(self)
        GameTooltip:Hide()
        Ed.OpenRoomMenu(self)
    end)
    U.AddTip(f.roomChip, "TAC_ROOM", "TAC_ROOM_TIP")
    y = y - 26
    f.bgChip = U.Chip(left, 186, 22)
    f.bgChip:SetPoint("TOPLEFT", 0, y)
    f.bgChip:SetScript("OnClick", function()
        if Ed.IsMap() and not Ed.board.mapMissing then
            Ed.Arm("bg")
        else
            Ed.Status(L.TAC_TOOL_BG_OFF, U.ORANGE)
        end
    end)
    U.AddTip(f.bgChip, "TAC_TOOL_BG", function()
        if Ed.IsMap() and not Ed.board.mapMissing then
            return L.TAC_TOOL_BG_TIP
        end
        return L.TAC_TOOL_BG_OFF
    end)
    y = y - 28
    f.missing = U.Label(left, "GameFontHighlightSmall", 0, y)
    f.missing:SetWidth(186)
    f.missing:SetTextColor(U.RED[1], U.RED[2], U.RED[3])
end

-- The board, 600 x 375 at x 208, y 84, with a thin edge around it.
function Ed.CreateBoard(f)
    f.boardEdge = f:CreateTexture(nil, "BORDER")
    f.boardEdge:SetPoint("TOPLEFT", 207, -83)
    f.boardEdge:SetSize(602, 377)
    f.boardEdge:SetColorTexture(0.45, 0.36, 0.15, 1)

    local board = T.CreateBoard(f, 600)
    board:SetPoint("TOPLEFT", 208, -84)
    board:SetEditable(true)
    Ed.board = board
    f.board = board

    board.onChanged = function()
        Ed.Changed()
        Ed.RefreshRoom()      -- undo may have brought another room back
        Ed.RefreshSelection()
    end
    board.onSelect = function(_, index)
        -- With a placing tool in hand, a selection means the tool has just
        -- placed something: the label went onto it, and is not for the next.
        local armed = Ed.armed
        if index and Ed.label ~= "" and (armed == "m" or armed == "g" or armed == "t") then
            Ed.label = ""
            Ed.SyncTools()
        end
        Ed.RefreshSelection()
    end
    board.onLimit = function()
        Ed.Status(L.TAC_LIMIT_ITEMS:format(T.MAX_ITEMS), U.RED)
    end
    -- A right click puts the tool down: back to selecting.
    board.onRightClick = function(_, _, _, index)
        Ed.Arm("select")
        Ed.board:Select(index)
    end
    -- A text field keeps the keyboard until it is told otherwise: a click on
    -- the board means the typing is over. Except with the text tool and no
    -- words for it: then the words are what is wanted next.
    board:HookScript("OnMouseDown", function()
        Ed.ClearFocus()
        if Ed.armed == "t" and Ed.label == "" then
            Ed.frame.labelBox:SetFocus()
        end
    end)
end

function Ed.ClearFocus()
    local f = Ed.frame
    f.nameBox:ClearFocus()
    f.otherBox:ClearFocus()
    f.bossBox:ClearFocus()
    f.labelBox:ClearFocus()
    f.sceneTitle:ClearFocus()
    for _, box in ipairs(f.noteBoxes) do
        box:ClearFocus()
    end
end

-- Under the board (x 208 to 808): the strip of scenes at y 463, the buttons
-- at y 488, and from y 514 the scene's title (left) and its notes (right).
function Ed.CreateScenes(f)
    f.sceneChips = {}
    for index = 1, T.MAX_SCENES do
        local chip = U.Chip(f, 56, 22, true) -- placed by Ed.RefreshStrip
        chip.index = index
        chip:SetScript("OnClick", function(self)
            Ed.ShowScene(self.index)
        end)
        chip:HookScript("OnEnter", function(self)
            local scene = Ed.plan and Ed.plan.scenes[self.index]
            if scene then
                U.ShowTip(self, L.TAC_SCENE_N:format(self.index), scene.title, nil, nil, nil, "ANCHOR_TOP")
            end
        end)
        chip:HookScript("OnLeave", U.HideTip)
        chip:Hide()
        f.sceneChips[index] = chip
    end

    -- 130 + 130 + 92 + 92 + 132 and four gaps of 6 = 600.
    f.sceneNew = DW.CreateButton(f, 130, 22, "gold")
    f.sceneNew:SetPoint("TOPLEFT", 208, -488)
    f.sceneNew:SetScript("OnClick", function()
        Ed.AddScene(true)
    end)
    U.AddTip(f.sceneNew, "TAC_SCENE_NEW", "TAC_SCENE_NEW_TIP", "ANCHOR_TOP")

    f.sceneEmpty = U.Chip(f, 130, 22, true)
    f.sceneEmpty:SetPoint("TOPLEFT", 344, -488)
    f.sceneEmpty:SetScript("OnClick", function()
        Ed.AddScene(false)
    end)
    U.AddTip(f.sceneEmpty, "TAC_SCENE_EMPTY", "TAC_SCENE_EMPTY_TIP", "ANCHOR_TOP")

    f.sceneEarlier = U.Chip(f, 92, 22, true)
    f.sceneEarlier:SetPoint("TOPLEFT", 480, -488)
    f.sceneEarlier:SetScript("OnClick", function()
        Ed.MoveScene(-1)
    end)
    U.AddTip(f.sceneEarlier, "TAC_SCENE_EARLIER", "TAC_SCENE_MOVE_TIP", "ANCHOR_TOP")

    f.sceneLater = U.Chip(f, 92, 22, true)
    f.sceneLater:SetPoint("TOPLEFT", 578, -488)
    f.sceneLater:SetScript("OnClick", function()
        Ed.MoveScene(1)
    end)
    U.AddTip(f.sceneLater, "TAC_SCENE_LATER", "TAC_SCENE_MOVE_TIP", "ANCHOR_TOP")

    f.sceneDelete = DW.CreateButton(f, 132, 22, "red")
    f.sceneDelete:SetPoint("TOPLEFT", 676, -488)
    f.sceneDelete:SetScript("OnClick", function(self)
        if #Ed.plan.scenes > 1 and U.Confirmed(self, Ed.Scene()) then
            U.Disarm(self, "TAC_SCENE_DELETE")
            Ed.DeleteScene()
        end
    end)
    f.sceneDelete:HookScript("OnLeave", function(self)
        U.Disarm(self, "TAC_SCENE_DELETE")
    end)

    -- The title: the field at 214 to 394. Under it, what the tool in hand does.
    f.sceneTitleLabel = U.Label(f, "GameFontNormalSmall", 208, -514)
    f.sceneTitle = U.Box(f, 180, T.MAX_NAME, function(text)
        Ed.Scene().title = U.CleanName(text)
        Ed.Changed()
        Ed.RefreshStrip()
    end)
    f.sceneTitle:SetPoint("TOPLEFT", 214, -527)
    f.hint = U.Label(f, "GameFontHighlightSmall", 208, -554)
    f.hint:SetWidth(190)
    f.hint:SetTextColor(0.75, 0.75, 0.75)

    -- The notes: five fields of 20, from y 527 to 627, at x 416 to 808.
    f.notesLabel = U.Label(f, "GameFontNormalSmall", 410, -514)
    f.notesLabel:SetWidth(398)
    f.notesLabel:SetWordWrap(false)
    f.noteBoxes = {}
    local function NotesTyped()
        -- The lines that say something, in the order of the fields.
        local notes = {}
        for _, box in ipairs(f.noteBoxes) do
            local line = U.CleanNote(box:GetText())
            if line ~= "" then
                notes[#notes + 1] = line
            end
        end
        Ed.Scene().notes = notes
        Ed.Changed()
    end
    for index = 1, T.MAX_NOTES do
        local box = U.Box(f, 392, T.MAX_NOTE, NotesTyped)
        box:SetHeight(20)
        box:SetPoint("TOPLEFT", 416, -527 - (index - 1) * 20)
        f.noteBoxes[index] = box
    end
end

-- The game's roles, as the roster gives them, to the addon's own (for the icon).
Ed.ROLE_ICON = {}
for _, role in ipairs(DW.ROLES or {}) do
    if role.code == "T" then
        Ed.ROLE_ICON.TANK = role
    elseif role.code == "H" then
        Ed.ROLE_ICON.HEALER = role
    elseif role.code == "D" then
        Ed.ROLE_ICON.DAMAGER = role
    end
end

-- The right column: 170 wide, at x 818, from y 84. A heading, up to four
-- lines of help, and the list (144 wide, its scroll bar in the 26 beside it).
function Ed.CreateRaid(f)
    local right = CreateFrame("Frame", nil, f)
    right:SetPoint("TOPLEFT", 818, -84)
    right:SetSize(170, 546)
    f.right = right

    f.raidLabel = U.Label(right, "GameFontNormalSmall", 0, 0)
    f.raidHint = U.Label(right, "GameFontHighlightSmall", 0, -14)
    f.raidHint:SetWidth(170)

    local scroll = CreateFrame("ScrollFrame", "DragonworldTacticsRaidScroll", right, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -62)
    scroll:SetSize(144, 484)
    f.raidContent = CreateFrame("Frame", nil, scroll)
    f.raidContent:SetSize(144, 1)
    scroll:SetScrollChild(f.raidContent)

    -- A group's line: a box to tick (20) and the group's button (22 to 144).
    f.groupRows, f.memberRows = {}, {}
    for group = 1, 8 do
        local row = {}
        row.check = CreateFrame("CheckButton", nil, f.raidContent, "UICheckButtonTemplate")
        row.check:SetSize(20, 20)
        row.check.group = group
        row.check:SetScript("OnClick", function(self)
            -- Ticking adds the group to the team that is placed as one.
            if Ed.armed ~= "g" then
                U.Wipe(Ed.ticked)
            end
            Ed.ticked[self.group] = self:GetChecked() and true or nil
            Ed.Arm("g")
        end)
        U.AddTip(row.check, function(self)
            return L.TAC_GROUP_N:format(self.group)
        end, "TAC_GROUP_TICK_TIP", "ANCHOR_LEFT")

        row.chip = U.Chip(f.raidContent, 122, 20, true)
        row.chip.group = group
        row.chip:SetScript("OnClick", function(self)
            U.Wipe(Ed.ticked)
            Ed.ticked[self.group] = true
            Ed.Arm("g")
        end)
        U.AddTip(row.chip, function(self)
            return L.TAC_GROUP_N:format(self.group)
        end, "TAC_GROUP_TIP", "ANCHOR_LEFT")
        f.groupRows[group] = row
    end
end

-- The question about unsaved work lies over everything in the window (the
-- board uses the levels up to board.levels above its own).
function Ed.CreatePrompt(f)
    local prompt = CreateFrame("Frame", nil, f, "BackdropTemplate")
    prompt:SetPoint("TOPLEFT", 6, -6)
    prompt:SetPoint("BOTTOMRIGHT", -6, 6)
    prompt:SetFrameLevel(f:GetFrameLevel() + Ed.board.levels + 20)
    prompt:EnableMouse(true)
    prompt:SetBackdrop(DW.PANEL_BACKDROP)
    prompt:SetBackdropColor(0.03, 0.03, 0.05, 0.96)
    prompt:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    f.prompt = prompt

    prompt.text = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prompt.text:SetPoint("TOP", 0, -220)
    prompt.text:SetWidth(700)

    -- Two buttons of 250, 12 apart, around the middle.
    prompt.keep = DW.CreateButton(prompt, 250, 30, "gold")
    prompt.keep:SetPoint("TOP", -131, -290)
    prompt.keep:SetScript("OnClick", function()
        prompt:Hide()
    end)
    prompt.drop = DW.CreateButton(prompt, 250, 30, "red")
    prompt.drop:SetPoint("TOP", 131, -290)
    prompt.drop:SetScript("OnClick", function()
        local wanted = prompt.wanted
        prompt:Hide()
        local db = U.DB()
        if not db then
            return
        end
        db.draft = nil
        Ed.plan = nil
        Ed.Load(wanted and T.GetPlan(wanted) or T.NewPlan(""), false)
        Tab.Refresh()
    end)
    prompt:Hide()
end

-- Events ---------------------------------------------------------------------------------------

T.On("plans", function()
    Tab.Refresh()
end)
T.On("received", function()
    Tab.Refresh()
end)
T.On("present", function()
    Tab.RefreshState()
    Ed.RefreshButtons()
end)
T.On("watch", function()
    Tab.RefreshState()
    Ed.RefreshButtons()
end)
T.On("roster", function()
    Tab.RefreshState()
    Ed.RefreshRaid()
    Ed.RefreshButtons()
end)

DW.OnLanguageChanged(function()
    Tab.Refresh()
    Ed.RefreshAll()
end)

-- The editor is for those who may use the tab.
DW.OnAccessChanged(function(access)
    if not access then
        T.CloseEditor()
    end
end)

-- Module -----------------------------------------------------------------------------------------

-- The module is registered in TacticsCore.lua; the tab is added here.
T.module.CreatePanel = function(self, parent)
    return Tab.Create(parent)
end

-- When the saved data is read (again): what the editor held belongs to the
-- data from before, and the draft is checked anew.
Ed.coreOnLoad = T.module.OnLoad
T.module.OnLoad = function(self, db)
    if Ed.coreOnLoad then
        Ed.coreOnLoad(self, db)
    end
    Ed.plan = nil
    Ed.draftChecked = false
    if Ed.frame then
        Ed.frame:Hide()
    end
end
