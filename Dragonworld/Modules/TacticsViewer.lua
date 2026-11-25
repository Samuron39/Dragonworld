-- Dragonworld - Tactics: the slideshow
--
-- The window that shows a plan scene by scene. The leader steps through the
-- scenes, and everyone in the group who has the addon sees the same scene.
-- The plan as data is described at the top of TacticsCore.lua.
--
-- The window is used in three ways, and goes from one to the other without
-- being closed:
--   preview    T.Preview: you read a plan alone. "Show to group" starts a
--              slideshow of it.
--   showing    you lead a slideshow (T.Presenting): the buttons move the whole
--              group to another scene, and a click on the board points at a
--              spot for everyone. Ending it leaves the window open as a preview.
--   watching   someone else leads (T.Watching): the board follows the leader's
--              scene. You may look through the scenes yourself, and go back
--              with "Follow the leader". When the slideshow ends, the window
--              stays on the plan, for reading.
--
-- For the ones watching, a new slideshow opens the window by itself with a
-- soft sound. Never in a fight: then it opens when the fight is over. And not
-- at all when the player has turned that off: then there is a line in chat.
-- A fight that starts hides the window; it comes back afterwards if a
-- slideshow is still running. The Close button and Escape only hide the
-- window. While a slideshow is running and the window is not on it, a small
-- button on the screen (the pill) brings it back; the x on the pill is what
-- closes a slideshow for good for someone watching.
--
-- Saved in DragonworldDB.modules.tactics:
--   viewer   = { point, relativePoint, x, y }: where the window was moved to
--   pill     = the same for the pill
--   autoOpen = false when the window must not open by itself
--
-- What other files may call:
--   T.Preview(plan, sceneNumber)  opens the window on a plan, for you alone
--   T.ShowSlideshow()             opens the window on the slideshow that is
--                                 running; false when there is none
--
-- All text is in Locales.lua (the names that start with TAC_VIEW_, and some
-- of the tab's own).

local ADDON_NAME, DW = ...
local L = DW.L
local T = DW.Tactics
local U = T.UI -- the small things Tactics.lua shares

local floor, min, max = math.floor, math.min, math.max

-- The functions, and what they remember, are kept in one table (the game's
-- Lua lets a function reach for at most 60 names outside itself).
local V = {}

V.NAME = "DragonworldTacticsViewer"
V.PILL = "DragonworldTacticsPill"

-- The window is 1000 x 616. On the left, from the top: the plan's name and
-- what it is for (y 11 to 40), the scene's number and title (46), the board
-- (704 x 440, y 74 to 514) and the scene's notes (five lines from 520). On the
-- right (x 732 to 986): what the window is doing now (46 to 98), Previous and
-- Next (106), the scenes by number (142 and 170), then what comes and goes
-- (from 202: a warning, a message, where the leader is, "this concerns you",
-- how it is going), and at the bottom the one thing to do (542) and the choice
-- to open by itself (580).
V.W, V.H = 1000, 616
V.LEVEL = 210 -- above the editor (100) and its question (164), in the same strata
V.BOARD_X, V.BOARD_Y, V.BOARD_W = 14, 74, 704
V.NOTES_Y, V.NOTE_H, V.NOTE_FONT = 520, 17, 14
V.SIDE_X, V.SIDE_Y, V.SIDE_W = 732, 46, 254
V.FLOW_Y, V.FLOW_GAP = 202, 8
V.PILL_W, V.PILL_H = 240, 30
V.OPEN_SOUND = 844 -- SOUNDKIT.IG_QUEST_LOG_OPEN, should the table be missing
V.POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
    RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- What the window shows.
--   V.plan       the plan (the core's own table while a slideshow runs: not changed here)
--   V.scene      the number of the scene on the board
--   V.total      for a plan a leader shows: how many scenes it has (V.plan.scenes
--                has holes until they arrive); nil for a plan that is all here
--   V.live       "show" or "watch" while the window is on the running slideshow
--   V.following  watching: the board goes where the leader goes
--   V.ended      "show" or "watch": the slideshow the window was on is over
--   V.notice     { key, colour }: a line about what just happened
-- What is running, whether the window is on it or not.
--   V.session, V.sessionKind   the plan of the running slideshow (the table
--                              itself tells one slideshow from the next) and
--                              "show" or "watch"
--   V.waiting    a slideshow started during a fight: open when the fight is over
--   V.byCombat   the window was hidden because a fight started
--   V.pillOff    the slideshow whose pill the one showing it has put away
V.scene = 1
V.following = true
V.fighting = false -- between the game's two events about a fight
V.waiting = false
V.byCombat = false
V.keepStale = true

-- Small things ------------------------------------------------------------------

-- May the window open by itself? Yes, until the player says no.
function V.AutoOpen()
    local db = U.DB()
    return not (db and db.autoOpen == false)
end

-- A plain yes from a function of the game: not when the function is missing,
-- fails, or answers with a secret value.
function V.Yes(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    local ok, value = pcall(fn, ...)
    if not ok or DW.IsSecret(value) then
        return false
    end
    return value == true or value == 1
end

-- In a fight? From the game's events (V.fighting, see V.OnCombat) and from
-- the game itself, which also knows after a reload in the middle of one.
function V.InCombat()
    return V.fighting or V.Yes(InCombatLockdown) or V.Yes(UnitAffectingCombat, "player")
end

-- A name to show; "?" when there is none.
function V.Who(name)
    if type(name) == "string" and not DW.IsSecret(name) and name ~= "" then
        return name
    end
    return "?"
end

-- A text in a colour, inside a longer text.
function V.Tint(text, colour)
    return ("|cff%02x%02x%02x%s|r"):format(floor(colour[1] * 255 + 0.5), floor(colour[2] * 255 + 0.5), floor(colour[3] * 255 + 0.5), text)
end

-- A soft sound when the window opens by itself.
function V.Chime()
    if type(PlaySound) ~= "function" then
        return
    end
    local kit = type(SOUNDKIT) == "table" and SOUNDKIT.IG_QUEST_LOG_OPEN
    pcall(PlaySound, type(kit) == "number" and kit or V.OPEN_SOUND)
end

-- Gives a text the game's ordinary font at another size.
function V.SetFontSize(fontString, size)
    local file = GameFontHighlight and GameFontHighlight.GetFont and GameFontHighlight:GetFont()
    if type(file) ~= "string" or file == "" then
        file = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    end
    fontString:SetFont(file, size, "")
end

-- Puts a frame where it was moved to (saved under `key`), or at its usual place.
function V.Place(frame, key, point, x, y)
    local db = U.DB()
    local saved = db and db[key]
    frame:ClearAllPoints()
    if type(saved) == "table" and V.POINTS[saved.point] then
        local relative = V.POINTS[saved.relativePoint] and saved.relativePoint or saved.point
        frame:SetPoint(saved.point, UIParent, relative, tonumber(saved.x) or 0, tonumber(saved.y) or 0)
    else
        frame:SetPoint(point, UIParent, point, x, y)
    end
end

-- Lets a frame be dragged, and remembers where it was left.
function V.MakeMovable(frame, key)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        local db = U.DB()
        if point and db then
            db[key] = { point = point, relativePoint = relativePoint, x = x, y = y }
        end
    end)
end

function V.SetNotice(key, colour)
    V.notice = key and { key = key, colour = colour or U.GREY } or nil
end

-- The plan in the window -----------------------------------------------------------

-- How many scenes the plan has (also the ones that have not arrived).
function V.Count()
    local plan = V.plan
    if type(plan) ~= "table" or type(plan.scenes) ~= "table" then
        return 0
    end
    if type(V.total) == "number" then
        return V.total
    end
    return #plan.scenes
end

-- Scene n of the plan (the one on the board when n is left out); nil when the
-- plan has none there, or it has not arrived.
function V.Scene(n)
    local plan = V.plan
    local scenes = type(plan) == "table" and plan.scenes
    local scene = type(scenes) == "table" and scenes[n or V.scene]
    if type(scene) == "table" then
        return scene
    end
    return nil
end

-- A scene number the plan has.
function V.Clamp(n)
    if DW.IsSecret(n) or type(n) ~= "number" or n ~= n then
        return 1
    end
    return max(1, min(max(1, V.Count()), floor(n)))
end

-- The slideshow that is running: "show" or "watch", and what the core says
-- about it. nil when there is none.
function V.Running()
    local showing = T.Presenting()
    if showing then
        return "show", showing
    end
    local watching = T.Watching()
    if watching then
        return "watch", watching
    end
    return nil
end

-- What the core says about the slideshow the window is on; nil when the
-- window is on none, or that one is over.
function V.Live()
    local state
    if V.live == "show" then
        state = T.Presenting()
    elseif V.live == "watch" then
        state = T.Watching()
    end
    if state and state.plan == V.plan then
        return state
    end
    return nil
end

-- Puts the window on the running slideshow.
function V.Attach(kind, state)
    V.live = kind
    V.plan = state.plan
    V.scene = state.scene
    V.ended = nil
    V.following = true
    V.keepStale = true
    V.SetNotice(nil)
    if kind == "watch" then
        V.total = state.total
    else
        V.total = nil
    end
    V.scene = V.Clamp(V.scene)
end

-- The slideshow the window was on is over. The plan stays, for reading.
function V.Detach()
    local was = V.live
    V.live, V.ended, V.following = nil, was, false
    V.keepStale = true
    if was == "show" then
        V.SetNotice("TAC_VIEW_STOPPED", U.GREY)
        if V.frame then
            U.Disarm(V.frame.stop, "TAC_VIEW_END")
        end
    end
end

-- What "Keep a copy" can do with a plan a leader showed: "keep", "kept" (a
-- copy is in your library already) or "wait" (not all of it is here). The
-- core keeps a received plan, by its id, once every scene has arrived.
function V.KeepState()
    local plan = V.plan
    if type(plan) ~= "table" or type(plan.scenes) ~= "table" or type(V.total) ~= "number" then
        return nil
    end
    for index = 1, V.total do
        if not plan.scenes[index] then
            return "wait"
        end
    end
    for _, entry in ipairs(T.Received()) do
        if entry.id == plan.id then
            return entry.kept and "kept" or "keep"
        end
    end
    return "wait"
end

-- Which of the scene's items are the player's own, as a text ("2,5"); "" when
-- none is. The board is drawn again when this changes (the raid's groups were
-- moved around).
function V.MineKey(scene)
    local items = scene and scene.items
    if type(items) ~= "table" then
        return ""
    end
    local mine = {}
    for index = 1, #items do
        if T.IsMine(items[index]) then
            mine[#mine + 1] = index
        end
    end
    return table.concat(mine, ",")
end

-- Drawing the window again ------------------------------------------------------------

-- Makes the window as large as it can be on this screen, at most its own size.
function V.FitScreen()
    local f = V.frame
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

-- The plan's name and what it is for, the scene's number and title, the board
-- and the notes.
function V.RefreshScene()
    local f, plan = V.frame, V.plan
    local count, n = V.Count(), V.scene
    local scene = V.Scene()

    f.title:SetText(plan and U.PlanName(plan) or "")
    f.place:SetText(plan and type(plan.instName) == "string" and type(plan.boss) == "string" and U.Place(plan) or "")

    local title = scene and type(scene.title) == "string" and scene.title or ""
    if count == 0 then
        f.heading:SetText("")
    elseif title ~= "" then
        f.heading:SetText(L.TAC_SCENE_OF_TITLE:format(n, count, title))
    else
        f.heading:SetText(L.TAC_SCENE_OF:format(n, count))
    end

    -- The board is drawn again only for another scene, or when what is the
    -- player's own on it has changed.
    local mine = V.MineKey(scene)
    if scene ~= V.board.scene or mine ~= V.mineKey then
        V.mineKey = mine
        V.board:SetScene(scene)
    end

    -- A scene that is not here: say so instead of showing an empty board.
    if scene then
        f.wait:Hide()
    else
        local key = "TAC_ERR_BAD_PLAN"
        if V.live == "watch" then
            key = "TAC_VIEW_WAITING"
        elseif V.ended == "watch" then
            key = "TAC_VIEW_MISSING"
        end
        f.wait.text:SetText(L[key])
        f.wait:Show()
    end

    local notes = scene and type(scene.notes) == "table" and scene.notes or nil
    for index, line in ipairs(f.notes) do
        local text = notes and notes[index]
        if type(text) == "string" and text ~= "" then
            line:SetText(text)
            line:Show()
            f.noteDots[index]:Show()
        else
            line:SetText("")
            line:Hide()
            f.noteDots[index]:Hide()
        end
    end
end

-- Previous, Next and the scenes by number.
function V.RefreshNav(state)
    local f = V.frame
    local count, n = V.Count(), V.scene
    local leaderAt = V.live == "watch" and state and state.scene or nil
    f.prev.label:SetText(L.TAC_VIEW_PREV)
    f.next.label:SetText(L.TAC_VIEW_NEXT)
    f.prev:SetActive(n > 1)
    f.next:SetActive(n < count)
    for index, chip in ipairs(f.chips) do
        if index <= count then
            chip.label:SetText(tostring(index))
            chip:SetSelected(index == n)
            -- Grey while it has not arrived (the one on the board stays lit).
            chip:SetDimmed(index ~= n and V.Scene(index) == nil)
            chip.mark:SetShown(index == leaderAt)
            chip:Show()
        else
            chip:Hide()
        end
    end
end

-- Puts the parts of the right column that come and go under each other, from
-- V.FLOW_Y down. Each is { region, inset, above, below }: how far in from the
-- column's left edge it starts, and the room it needs above and below itself
-- (for the box around a warning).
function V.Flow(parts)
    local previous
    for _, part in ipairs(parts) do
        local region, inset, above = part[1], part[2] or 0, part[3] or 0
        region:ClearAllPoints()
        if previous then
            region:SetPoint("TOPLEFT", previous[1], "BOTTOMLEFT", inset - (previous[2] or 0), -((previous[4] or 0) + V.FLOW_GAP + above))
        else
            region:SetPoint("TOPLEFT", V.frame, "TOPLEFT", V.SIDE_X + inset, -(V.FLOW_Y + above))
        end
        previous = part
    end
end

-- How a slideshow you show is going, as the lines of a text.
function V.ShowLines(state, lines)
    local sent, total = tonumber(state.sent) or 0, tonumber(state.total) or 0
    if sent < total then
        lines[#lines + 1] = L.TAC_VIEW_SENDING:format(sent, total)
    else
        lines[#lines + 1] = L.TAC_VIEW_SENT
    end
    local viewers = tonumber(state.viewerCount) or 0
    lines[#lines + 1] = V.Tint(L.TAC_VIEW_VIEWERS:format(viewers), viewers > 0 and U.GREEN or U.GREY)
    -- (While the slideshow is still going out, the core shows a ping to the
    -- one who points only: the hint waits until it is true.)
    if sent >= total and not state.problem then
        lines[#lines + 1] = V.Tint(L.TAC_VIEW_PING_HINT, U.GREY)
    end
end

-- The right column: what the window is doing now, what the player should
-- know, and what can be done.
function V.RefreshSide(state)
    local f = V.frame
    local live = V.live
    local parts = {}

    -- What this is.
    local text
    if live == "show" then
        text = L.TAC_VIEW_MODE_SHOW
    elseif live == "watch" then
        text = L.TAC_VIEW_MODE_WATCH:format(V.Who(state.from))
    elseif V.ended == "watch" then
        text = L.TAC_VIEW_MODE_ENDED
    else
        text = L.TAC_VIEW_MODE_PREVIEW
    end
    f.mode.text:SetText(text)
    if live then
        f.mode:SetBackdropColor(0.30, 0.22, 0.05, 0.95)
        f.mode:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
        U.Paint(f.mode.text, U.GOLD)
    else
        f.mode:SetBackdropColor(0.10, 0.10, 0.12, 0.90)
        f.mode:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
        f.mode.text:SetTextColor(0.90, 0.90, 0.90)
    end

    -- The game refuses the messages: a box nobody can miss.
    local problem = live == "show" and state.problem or nil
    local warning, colour
    if problem == "TAC_ERR_BLOCKED" then
        warning, colour = L.TAC_VIEW_BLOCKED, U.RED
    elseif problem == "TAC_ERR_LOCKED" then
        warning, colour = L.TAC_VIEW_LOCKED, U.ORANGE
    elseif type(problem) == "string" then
        warning, colour = U.Words(problem), U.ORANGE
    end
    if warning then
        f.warn:SetText(warning)
        f.warnEdge:SetColorTexture(colour[1], colour[2], colour[3], 1)
        f.warnFill:SetColorTexture(colour[1] * 0.22, colour[2] * 0.22, colour[3] * 0.22, 1)
        parts[#parts + 1] = { f.warn, 9, 9, 9 }
    else
        f.warn:SetText("")
    end
    f.warn:SetShown(warning ~= nil)
    f.warnEdge:SetShown(warning ~= nil)
    f.warnFill:SetShown(warning ~= nil)

    -- What just happened.
    local notice = V.notice
    if notice then
        f.notice:SetText(L[notice.key])
        U.Paint(f.notice, notice.colour)
        parts[#parts + 1] = { f.notice }
    else
        f.notice:SetText("")
    end
    f.notice:SetShown(notice ~= nil)

    -- Looking through the scenes on your own while someone shows them.
    local astray = live == "watch" and not V.following
    if astray then
        f.leader:SetText(L.TAC_VIEW_LEADER_AT:format(V.Who(state.from), tonumber(state.scene) or 1))
        f.follow.label:SetText(L.TAC_VIEW_FOLLOW)
        parts[#parts + 1] = { f.leader }
        parts[#parts + 1] = { f.follow }
    else
        f.leader:SetText("")
    end
    f.leader:SetShown(astray)
    f.follow:SetShown(astray)

    -- Something in the scene is about you.
    local mine = V.mineKey ~= nil and V.mineKey ~= ""
    f.mine:SetText(mine and L.TAC_VIEW_MINE or "")
    f.mine:SetShown(mine)
    if mine then
        parts[#parts + 1] = { f.mine }
    end

    -- How it is going.
    local lines = {}
    if live == "show" then
        V.ShowLines(state, lines)
    elseif live == "watch" then
        local ready, total = tonumber(state.ready) or 0, tonumber(state.total) or 0
        if ready < total then
            lines[#lines + 1] = L.TAC_VIEW_ARRIVING:format(ready, total)
        end
        if V.following then
            lines[#lines + 1] = V.Tint(L.TAC_VIEW_WATCH_HINT, U.GREY)
        end
    end
    f.info:SetText(table.concat(lines, "\n\n"))
    f.info:SetShown(#lines > 0)
    f.infoHover:SetShown(live == "show")
    if #lines > 0 then
        parts[#parts + 1] = { f.info }
    end
    V.Flow(parts)

    -- The one thing to do: show it, end it, or keep it.
    local received = type(V.total) == "number"
    f.present:SetShown(not live and not received)
    f.stop:SetShown(live == "show")
    f.keep:SetShown(received)
    f.present.label:SetText(L.TAC_PRESENT)
    local can, reason = U.PresentState()
    f.present:SetActive(can)
    f.present.reason = reason
    if not f.stop.armedAt then
        f.stop.label:SetText(L.TAC_VIEW_END)
    end
    if received then
        if V.keepStale then
            V.keepStale = false
            V.keepState = V.KeepState()
        end
        f.keep.label:SetText(V.keepState == "kept" and L.TAC_KEPT or L.TAC_KEEP)
        f.keep:SetActive(V.keepState == "keep")
    end

    f.close.label:SetText(L.TAC_ED_CLOSE)
    f.auto:SetChecked(V.AutoOpen())
    f.auto.label:SetText(L.TAC_VIEW_AUTO)
end

-- Draws the window again.
function V.Refresh()
    local f = V.frame
    if not f or not f:IsVisible() then
        return
    end
    local state = V.Live()
    if V.live and not state then
        V.Detach() -- the slideshow went away without a word
    end
    V.scene = V.Clamp(V.scene)
    V.RefreshScene()
    V.RefreshNav(state)
    V.RefreshSide(state)
end

-- The pill: the small button on the screen while a slideshow is running and
-- the window is not on it.
function V.RefreshPill()
    local kind, state = V.Running()
    local f = V.frame
    local onIt = f ~= nil and f:IsShown() and V.live ~= nil
    if not kind or onIt or V.pillOff == state.plan then
        if V.pill then
            V.pill:Hide()
        end
        return
    end
    if not V.pill then
        V.CreatePill()
    end
    V.pill.text:SetText(L.TAC_VIEW_PILL:format(U.PlanName(state.plan)))
    V.pill:Show()
end

-- Opening, and what the buttons do ------------------------------------------------------

-- Shows the window on what it has been given.
function V.Open()
    if not V.frame then
        V.Create()
    end
    V.byCombat, V.waiting = false, false
    if V.frame:IsShown() then
        V.Refresh()
    else
        V.frame:Show() -- draws everything
    end
    V.RefreshPill()
end

-- Opens the window on a plan, at a scene, for you alone. The window gets a
-- copy: the plan handed in may be the editor's working copy. False when it is
-- not a plan.
function V.Preview(plan, sceneNumber)
    if not DW.GuardPersonal() then
        return false
    end
    local copy = T.Sanitize(plan)
    if not copy then
        return false
    end
    V.live, V.ended, V.total = nil, nil, nil
    V.following = false
    V.keepStale = true
    V.SetNotice(nil)
    V.plan = copy
    V.scene = V.Clamp(sceneNumber)
    V.Open()
    return true
end

-- Opens the window on the slideshow that is running (yours, or the one you
-- watch), at the scene being shown. False when there is none.
function V.ShowSlideshow()
    local kind, state = V.Running()
    if not kind then
        return false
    end
    V.Attach(kind, state)
    V.Open()
    return true
end

T.Preview = V.Preview
T.ShowSlideshow = V.ShowSlideshow

-- Previous, Next and the numbered buttons. The one who shows moves the whole
-- group; everyone else only their own window.
function V.Go(n)
    n = V.Clamp(n)
    if V.live == "show" then
        T.ShowScene(n) -- comes back as the "scene" event
        return
    end
    if V.live == "watch" then
        V.following = false
    end
    V.scene = n
    V.Refresh()
end

-- "Follow the leader": back to the scene being shown.
function V.Follow()
    local state = V.Live()
    if V.live ~= "watch" or not state then
        return
    end
    V.following = true
    V.scene = V.Clamp(state.scene)
    V.Refresh()
end

-- "Show to group": the plan in the window becomes a slideshow. The core's
-- "present" event then puts the window on it.
function V.StartShow()
    if V.live or not V.plan or V.total then
        return
    end
    V.SetNotice(nil)
    local ok, reason = T.Present(V.plan)
    if not ok then
        V.SetNotice(U.Words(reason) and reason or "TAC_ERR_BAD_PLAN", U.RED)
    end
    V.Refresh()
end

-- "End the slideshow": red, and asks first, as elsewhere in the addon.
function V.EndShow(button)
    if V.live ~= "show" then
        return
    end
    if U.Confirmed(button, V.plan) then
        U.Disarm(button, "TAC_VIEW_END")
        T.StopPresenting() -- the "present" event leaves the window as a preview
    end
end

-- "Keep a copy" of what a leader showed.
function V.Keep()
    local plan = V.plan
    if type(plan) ~= "table" or not V.total then
        return
    end
    local kept, reason = T.KeepReceived(plan.id)
    V.keepStale = true
    if kept then
        V.SetNotice("TAC_VIEW_KEPT_NOW", U.GREEN)
    else
        V.SetNotice(U.Words(reason) and reason or "TAC_ERR_BAD_PLAN", U.RED)
    end
    V.Refresh()
end

-- The x on the pill. For someone watching it closes the slideshow for good;
-- the one showing only puts the pill away (the slideshow is ended in its window).
function V.DismissPill()
    U.HideTip()
    local kind, state = V.Running()
    if kind == "watch" then
        T.StopWatching() -- the "watch" event takes the pill away
    elseif kind == "show" then
        V.pillOff = state.plan
        V.RefreshPill()
    end
end

-- Who has received all of the slideshow you show, as a tooltip.
function V.ShowViewers(owner)
    local state = V.live == "show" and V.Live()
    if not state then
        return
    end
    local names = {}
    for name in pairs(type(state.viewers) == "table" and state.viewers or {}) do
        if type(name) == "string" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine(L.TAC_VIEW_VIEWERS_TITLE)
    if #names == 0 then
        GameTooltip:AddLine(L.TAC_VIEW_VIEWERS_NONE, 1, 1, 1)
    end
    for _, name in ipairs(names) do
        GameTooltip:AddLine(name, 1, 1, 1)
    end
    GameTooltip:AddLine(L.TAC_VIEW_VIEWERS_TIP, U.GREY[1], U.GREY[2], U.GREY[3], true)
    GameTooltip:Show()
end

-- What the core tells ---------------------------------------------------------------------

-- A leader has started a slideshow. Whether the window opens: see the top of
-- the file. (What it does not open, the pill offers.)
function V.Announce(watching)
    local f = V.frame
    if f and f:IsShown() and V.ended == "watch" then
        -- Already looking at what a leader showed: go on with the new one.
        V.Attach("watch", watching)
        return
    end
    if not V.AutoOpen() then
        DW.Print(L.TAC_VIEW_CHAT:format(V.Who(watching.from), U.PlanName(watching.plan)))
        return
    end
    if V.InCombat() then
        V.waiting = true
        return
    end
    V.Attach("watch", watching)
    V.Open()
    V.Chime()
end

function V.OnWatch()
    V.keepStale = true
    local watching = T.Watching()
    if watching and watching.plan ~= V.session then
        if V.live then
            V.Detach()
        end
        V.session, V.sessionKind, V.pillOff, V.waiting = watching.plan, "watch", nil, false
        V.Announce(watching)
    elseif not watching and V.sessionKind == "watch" then
        V.session, V.sessionKind, V.waiting = nil, nil, false
        if V.live == "watch" then
            V.Detach()
        end
    elseif watching and V.live == "watch" then
        V.total = watching.total
    end
    V.Refresh()
    V.RefreshPill()
end

function V.OnPresent()
    local showing = T.Presenting()
    if showing and showing.plan ~= V.session then
        -- You have started a slideshow: the window becomes its controls.
        V.session, V.sessionKind, V.pillOff = showing.plan, "show", nil
        V.Attach("show", showing)
        V.Open()
        return
    end
    if not showing and V.sessionKind == "show" then
        V.session, V.sessionKind = nil, nil
        if V.live == "show" then
            V.Detach()
        end
    end
    V.Refresh()
    V.RefreshPill()
end

-- The scene being shown changed.
function V.OnScene(n)
    if V.live == "show" or (V.live == "watch" and V.following) then
        V.scene = V.Clamp(n)
    end
    V.Refresh()
end

-- The one who shows pointed at a spot: on our board too, when it has that scene.
function V.OnPing(x, y)
    local f = V.frame
    local state = V.Live()
    if f and f:IsVisible() and state and state.scene == V.scene then
        V.board:Ping(x, y)
    end
end

-- A fight starts: nobody wants a large window over it. When it is over, the
-- window comes back if a slideshow is still running, and a slideshow that
-- started meanwhile opens.
function V.OnCombat(event)
    local f = V.frame
    if event == "PLAYER_REGEN_DISABLED" then
        V.fighting = true
        if f and f:IsShown() then
            V.byCombat = true
            f:Hide()
        end
        return
    end
    V.fighting = false
    local back, waiting = V.byCombat, V.waiting
    V.byCombat, V.waiting = false, false
    local kind, state = V.Running()
    if not kind then
        return
    end
    if waiting and kind == "watch" and state.plan == V.session and V.AutoOpen() then
        V.Attach("watch", state)
        V.Open()
        V.Chime()
    elseif back then
        V.Open()
    end
end

-- Building the window ------------------------------------------------------------------------

-- The top: the plan, Close, and the scene's number and title above the board.
function V.CreateTop(f)
    f.title = U.Label(f, "GameFontNormalLarge", 16, -11)
    f.title:SetWidth(860)
    f.title:SetWordWrap(false)
    f.place = U.Label(f, "GameFontHighlightSmall", 16, -29)
    f.place:SetWidth(860)
    f.place:SetWordWrap(false)
    U.Paint(f.place, U.GREY)

    f.close = U.Chip(f, 84, 24)
    f.close:SetPoint("TOPRIGHT", -12, -10)
    f.close:SetScript("OnClick", function()
        U.HideTip()
        f:Hide()
    end)
    U.AddTip(f.close, "TAC_ED_CLOSE", "TAC_VIEW_CLOSE_TIP", "ANCHOR_BOTTOM")

    f.heading = U.Label(f, "GameFontNormalHuge", V.BOARD_X, -46)
    f.heading:SetWidth(V.BOARD_W)
    f.heading:SetWordWrap(false)
end

-- The board with a thin edge around it, what lies over it when a scene is
-- not here, and the notes under it.
function V.CreateBoard(f)
    local height = V.BOARD_W * T.BOARD_H / T.BOARD_W
    f.boardEdge = f:CreateTexture(nil, "BORDER")
    f.boardEdge:SetPoint("TOPLEFT", V.BOARD_X - 1, -(V.BOARD_Y - 1))
    f.boardEdge:SetSize(V.BOARD_W + 2, height + 2)
    f.boardEdge:SetColorTexture(0.45, 0.36, 0.15, 1)

    local board = T.CreateBoard(f, V.BOARD_W)
    board:SetPoint("TOPLEFT", V.BOARD_X, -V.BOARD_Y)
    board:SetHighlightMine(true)
    -- The one who shows points at a spot with a click; the "ping" event draws
    -- it, here as for everyone else.
    board.onClick = function(_, x, y)
        if V.live == "show" then
            T.Ping(x, y)
        end
    end
    V.board = board
    f.board = board

    -- Over the board (which uses the levels up to board.levels above its own).
    local wait = CreateFrame("Frame", nil, f)
    wait:SetAllPoints(board)
    wait:SetFrameLevel(board:GetFrameLevel() + board.levels + 2)
    wait.shade = wait:CreateTexture(nil, "BACKGROUND")
    wait.shade:SetAllPoints()
    wait.shade:SetColorTexture(0, 0, 0, 0.60)
    wait.text = wait:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    wait.text:SetPoint("CENTER", 0, 0)
    wait.text:SetWidth(V.BOARD_W - 120)
    wait:Hide()
    f.wait = wait

    -- The notes: a gold dot and a line each.
    f.notes, f.noteDots = {}, {}
    for index = 1, T.MAX_NOTES do
        local y = -(V.NOTES_Y + (index - 1) * V.NOTE_H)
        local dot = f:CreateTexture(nil, "ARTWORK")
        dot:SetPoint("TOPLEFT", V.BOARD_X + 3, y - 5)
        dot:SetSize(5, 5)
        dot:SetColorTexture(1.00, 0.82, 0.00, 1)
        dot:Hide()
        local line = U.Label(f, "GameFontHighlight", V.BOARD_X + 16, y)
        line:SetWidth(V.BOARD_W - 16)
        line:SetWordWrap(false)
        V.SetFontSize(line, V.NOTE_FONT)
        line:Hide()
        f.noteDots[index], f.notes[index] = dot, line
    end
end

-- Previous, Next and the scenes by number: five to a row, 46 wide and 52
-- apart (4 * 52 + 46 = 254).
function V.CreateNav(f)
    local x = V.SIDE_X
    f.prev = DW.CreateButton(f, 124, 30, "gold")
    f.prev:SetPoint("TOPLEFT", x, -106)
    f.prev:SetScript("OnClick", function()
        V.Go(V.scene - 1)
    end)
    f.next = DW.CreateButton(f, 124, 30, "gold")
    f.next:SetPoint("TOPLEFT", x + 130, -106)
    f.next:SetScript("OnClick", function()
        V.Go(V.scene + 1)
    end)

    f.chips = {}
    for index = 1, T.MAX_SCENES do
        local chip = U.Chip(f, 46, 24, true)
        chip:SetPoint("TOPLEFT", x + ((index - 1) % 5) * 52, -(142 + floor((index - 1) / 5) * 28))
        chip.index = index
        -- A gold bar on the scene the leader is on.
        chip.mark = chip:CreateTexture(nil, "OVERLAY")
        chip.mark:SetPoint("BOTTOMLEFT", 6, 3)
        chip.mark:SetPoint("BOTTOMRIGHT", -6, 3)
        chip.mark:SetHeight(2)
        chip.mark:SetColorTexture(1.00, 0.82, 0.00, 1)
        chip.mark:Hide()
        chip:SetScript("OnClick", function(self)
            V.Go(self.index)
        end)
        chip:HookScript("OnEnter", function(self)
            local scene = V.Scene(self.index)
            local title = scene and type(scene.title) == "string" and scene.title or nil
            U.ShowTip(self, L.TAC_SCENE_N:format(self.index), scene and title or L.TAC_VIEW_NOT_ARRIVED, nil, nil, nil, "ANCHOR_TOP")
        end)
        chip:HookScript("OnLeave", U.HideTip)
        chip:Hide()
        f.chips[index] = chip
    end
end

-- The right column: what the window is doing now, the parts that come and go
-- (placed by V.Flow), and at the bottom the one thing to do and the choice to
-- open by itself.
function V.CreateSide(f)
    local x, width = V.SIDE_X, V.SIDE_W

    f.mode = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.mode:SetPoint("TOPLEFT", x, -V.SIDE_Y)
    f.mode:SetSize(width, 52)
    f.mode:SetBackdrop(DW.PANEL_BACKDROP)
    f.mode.text = f.mode:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.mode.text:SetPoint("LEFT", 10, 0)
    f.mode.text:SetPoint("RIGHT", -10, 0)
    f.mode.text:SetJustifyH("LEFT")

    V.CreateNav(f)

    -- A warning: a text in a box of its colour, which follows the text's size.
    f.warn = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.warn:SetWidth(width - 18)
    f.warn:SetJustifyH("LEFT")
    f.warnEdge = f:CreateTexture(nil, "BORDER")
    f.warnEdge:SetPoint("TOPLEFT", f.warn, "TOPLEFT", -9, 9)
    f.warnEdge:SetPoint("BOTTOMRIGHT", f.warn, "BOTTOMRIGHT", 9, -9)
    f.warnFill = f:CreateTexture(nil, "ARTWORK")
    f.warnFill:SetPoint("TOPLEFT", f.warn, "TOPLEFT", -8, 8)
    f.warnFill:SetPoint("BOTTOMRIGHT", f.warn, "BOTTOMRIGHT", 8, -8)

    f.notice = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.notice:SetWidth(width)
    f.notice:SetJustifyH("LEFT")

    f.leader = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.leader:SetWidth(width)
    f.leader:SetJustifyH("LEFT")
    f.follow = DW.CreateButton(f, width, 28, "gold")
    f.follow:SetScript("OnClick", V.Follow)
    U.AddTip(f.follow, "TAC_VIEW_FOLLOW", "TAC_VIEW_FOLLOW_TIP", "ANCHOR_LEFT")

    f.mine = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.mine:SetWidth(width)
    f.mine:SetJustifyH("LEFT")

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.info:SetWidth(width)
    f.info:SetJustifyH("LEFT")
    -- With the mouse over how it is going: who has received all of it.
    f.infoHover = CreateFrame("Frame", nil, f)
    f.infoHover:SetAllPoints(f.info)
    f.infoHover:EnableMouse(true)
    f.infoHover:SetScript("OnEnter", V.ShowViewers)
    f.infoHover:SetScript("OnLeave", U.HideTip)

    -- One of these three shows, at the same place.
    f.present = DW.CreateButton(f, width, 30, "gold")
    f.present:SetPoint("BOTTOMLEFT", x, 44)
    f.present:SetScript("OnClick", V.StartShow)
    U.AddTip(f.present, "TAC_PRESENT", U.PresentTip, "ANCHOR_TOP")
    U.TipWhileDisabled(f.present)

    f.stop = DW.CreateButton(f, width, 30, "red")
    f.stop:SetPoint("BOTTOMLEFT", x, 44)
    f.stop:SetScript("OnClick", V.EndShow)
    f.stop:HookScript("OnLeave", function(self)
        U.Disarm(self, "TAC_VIEW_END")
    end)
    U.AddTip(f.stop, "TAC_VIEW_END", "TAC_VIEW_END_TIP", "ANCHOR_TOP")

    f.keep = DW.CreateButton(f, width, 30, "gold")
    f.keep:SetPoint("BOTTOMLEFT", x, 44)
    f.keep:SetScript("OnClick", V.Keep)
    U.AddTip(f.keep, "TAC_KEEP", function()
        if V.keepState == "wait" then
            return L.TAC_VIEW_KEEP_WAIT
        end
        return L.TAC_KEEP_TIP
    end, "ANCHOR_TOP")
    U.TipWhileDisabled(f.keep)

    -- "Open by itself when a leader shows a tactic": a box and two lines of text.
    f.auto = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.auto:SetSize(24, 24)
    f.auto:SetPoint("BOTTOMLEFT", x - 2, 12)
    f.auto:SetScript("OnClick", function(self)
        local db = U.DB()
        if db then
            db.autoOpen = self:GetChecked() and true or false
        end
    end)
    f.auto.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.auto.label:SetPoint("LEFT", f.auto, "RIGHT", 2, 0)
    f.auto.label:SetWidth(width - 26)
    f.auto.label:SetJustifyH("LEFT")
    U.AddTip(f.auto, "TAC_VIEW_AUTO", "TAC_VIEW_AUTO_TIP", "ANCHOR_TOP")
end

function V.Create()
    local f = CreateFrame("Frame", V.NAME, UIParent, "BackdropTemplate")
    V.frame = f
    f:Hide()
    f:SetSize(V.W, V.H)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(V.LEVEL)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    V.Place(f, "viewer", "CENTER", 0, 0)
    V.MakeMovable(f, "viewer")
    -- Escape hides the window. That ends nothing: see OnHide.
    table.insert(UISpecialFrames, V.NAME)

    V.CreateTop(f)
    V.CreateBoard(f)
    V.CreateSide(f)

    f:SetScript("OnShow", function()
        V.FitScreen()
        V.Refresh()
    end)
    f:SetScript("OnHide", function(self)
        -- Hidden only because the whole interface is: still open.
        if self:IsShown() then
            return
        end
        U.HideTip()
        U.Disarm(self.stop, "TAC_VIEW_END")
        -- A slideshow goes on without the window: the pill brings it back.
        V.RefreshPill()
    end)
    return f
end

function V.PaintPill(pill, hovered)
    if hovered then
        pill:SetBackdropColor(0.42, 0.31, 0.07, 0.95)
    else
        pill:SetBackdropColor(0.30, 0.22, 0.05, 0.95)
    end
    pill:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
end

-- The pill: the tab's icon, "Tactics: <the plan>", and a small x.
function V.CreatePill()
    local pill = CreateFrame("Button", V.PILL, UIParent, "BackdropTemplate")
    V.pill = pill
    pill:Hide()
    pill:SetSize(V.PILL_W, V.PILL_H)
    pill:SetFrameStrata("HIGH")
    pill:SetBackdrop(DW.PANEL_BACKDROP)
    V.PaintPill(pill, false)
    V.Place(pill, "pill", "TOP", 0, -120)
    V.MakeMovable(pill, "pill")

    pill.icon = pill:CreateTexture(nil, "ARTWORK")
    pill.icon:SetSize(20, 20)
    pill.icon:SetPoint("LEFT", 6, 0)
    pill.icon:SetTexture(T.module.icon)
    pill.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    pill.text = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pill.text:SetPoint("LEFT", pill.icon, "RIGHT", 6, 0)
    pill.text:SetPoint("RIGHT", -28, 0)
    pill.text:SetJustifyH("LEFT")
    pill.text:SetWordWrap(false)

    pill:SetScript("OnClick", function()
        U.HideTip()
        V.ShowSlideshow()
    end)
    pill:SetScript("OnEnter", function(self)
        V.PaintPill(self, true)
        local kind, state = V.Running()
        if kind then
            local what = kind == "show" and L.TAC_VIEW_PILL_SHOW or L.TAC_VIEW_PILL_WATCH:format(V.Who(state.from))
            U.ShowTip(self, U.PlanName(state.plan), what .. "\n" .. L.TAC_VIEW_PILL_DRAG, nil, nil, nil, "ANCHOR_BOTTOM")
        end
    end)
    pill:SetScript("OnLeave", function(self)
        V.PaintPill(self, false)
        U.HideTip()
    end)

    pill.close = U.Chip(pill, 20, 20, true)
    pill.close:SetPoint("RIGHT", -5, 0)
    pill.close.label:SetText("x")
    pill.close:SetScript("OnClick", V.DismissPill)
    pill.close:HookScript("OnEnter", function(self)
        local kind = V.Running()
        if kind then
            U.ShowTip(self, L.TAC_ED_CLOSE, kind == "show" and L.TAC_VIEW_PILL_X_SHOW or L.TAC_VIEW_PILL_X_WATCH, nil, nil, nil, "ANCHOR_BOTTOM")
        end
    end)
    pill.close:HookScript("OnLeave", U.HideTip)
    return pill
end

-- Events ---------------------------------------------------------------------------------------

T.On("present", V.OnPresent)
T.On("watch", V.OnWatch)
T.On("scene", V.OnScene)
T.On("ping", V.OnPing)
T.On("received", function()
    V.keepStale = true
    V.Refresh()
end)
T.On("plans", function()
    V.keepStale = true
    V.Refresh()
end)
T.On("roster", function()
    V.Refresh()
end)

DW.OnLanguageChanged(function()
    V.Refresh()
    V.RefreshPill()
end)

-- The window is for those who may use the tab. (The core has ended the
-- slideshow by now, which takes the pill away.)
DW.OnAccessChanged(function(access)
    if not access and V.frame then
        V.frame:Hide()
    end
end)

V.events = CreateFrame("Frame")
V.events:SetScript("OnEvent", function(_, event)
    V.OnCombat(event)
end)
pcall(V.events.RegisterEvent, V.events, "PLAYER_REGEN_DISABLED")
pcall(V.events.RegisterEvent, V.events, "PLAYER_REGEN_ENABLED")

-- When the saved data is read (again): the window and the pill go where that
-- data says they were moved to.
V.earlierOnLoad = T.module.OnLoad
T.module.OnLoad = function(self, db)
    if V.earlierOnLoad then
        V.earlierOnLoad(self, db)
    end
    V.keepStale = true
    if V.frame then
        V.Place(V.frame, "viewer", "CENTER", 0, 0)
    end
    if V.pill then
        V.Place(V.pill, "pill", "TOP", 0, -120)
    end
    V.Refresh()
end
