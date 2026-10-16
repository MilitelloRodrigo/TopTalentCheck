local ADDON, ns = ...

local LIB_NAME = "LibClassTalentsImportExport-1.0"
local PREFIX = "|cff4fc3f7TopTalentCheck|r: "
local LOADOUT_NAME = "TopTalentCheck"
local STALE_DAYS = 10

local DEFAULTS = {
    enabled = true,
    verbose = false,     -- avisar también cuando todo coincide
    sound = true,
    heroMode = "top",    -- "top": árbol de héroe más usado | "own": mejor build dentro de TU árbol de héroe
    pick = "popular",    -- "popular": build con más runs | "recommended": el que Raider.IO marca como recomendado
    bracket = "auto",    -- "auto": el bracket de llave más alto con datos suficientes | o una clave como "15-99"
    minRuns = 30,        -- mínimo de runs para fiarse de un bracket en modo "auto"
}

local DB
local Lib

-- Raider.IO usa estas dificultades para raid. Agrego 17 (LFR) como "normal" porque no tiene datos propios.
local RAID_DIFF_KEY = {}
for key, ids in pairs({
    normal = { 1, 12, 14, 17, 38, 147, 150 },
    heroic = { 2, 5, 6, 11, 15, 39, 149, 230 },
    mythic = { 8, 16, 23, 40, 233 },
}) do
    for _, id in ipairs(ids) do
        RAID_DIFF_KEY[id] = key
    end
end

--- MARK: Utilidades

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

local function GetBuildsData()
    return ns.TALENT_BUILDS or ns.talentBuilds
end

local function Pct(value)
    return floor((value or 0) * 100 + 0.5)
end

local function Join(list, max)
    local n = #list
    if n <= max then
        return table.concat(list, ", ")
    end
    return format("%s (+%d)", table.concat(list, ", ", 1, max), n - max)
end

local function ListContains(list, value)
    if type(list) ~= "table" then
        return false
    end
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end

local function DataAgeDays(dateString)
    if type(dateString) ~= "string" then
        return
    end
    local y, m, d, H, M, S = dateString:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return
    end
    local t = time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(H), min = tonumber(M), sec = tonumber(S) })
    return floor((time() - t) / 86400)
end

--- Devuelve t.all si existe, si no el primer valor de la tabla.
local function AllOrFirst(t)
    if type(t) ~= "table" then
        return
    end
    if t.all ~= nil then
        return t.all
    end
    local _, v = next(t)
    return v
end

local function SumRuns(stats)
    local total = 0
    for _, row in ipairs(stats) do
        total = total + (row[3] or 0)
    end
    return total
end

--- MARK: Zona -> clave de mazmorra de Raider.IO

--- Intenta traducir la instancia actual a la clave de mazmorra que usan los datos (`mplus[clave]`).
--- 1) Si cargaste el archivo de mazmorras de Raider.IO (ns.DUNGEONS), usa instance_map_ids (exacto).
--- 2) Si no, compara el nombre de la zona con C_Map.GetAreaInfo(<clave>) (asume que la clave es un AreaID).
---@return string? dungeonKey, string? instanceName, string? method
local function ResolveDungeonKey(data)
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    if instanceType ~= "party" then
        return
    end

    for _, list in ipairs({ ns.DUNGEONS or ns.dungeons or {}, ns.EXPANSION_DUNGEONS or ns.expansionDungeons or {} }) do
        for _, dungeon in ipairs(list) do
            if ListContains(dungeon.instance_map_ids, instanceID) or dungeon.instance_map_id == instanceID then
                return tostring(dungeon.id), name, "datos de mazmorras de Raider.IO"
            end
        end
    end

    local dungeons = data and data.routes and data.routes.dungeons
    if type(dungeons) == "table" and C_Map and C_Map.GetAreaInfo then
        local zone = GetRealZoneText()
        for key in pairs(dungeons) do
            local areaID = tonumber(key)
            local areaName = areaID and C_Map.GetAreaInfo(areaID)
            if areaName and (areaName == name or areaName == zone) then
                return key, name, "nombre de zona"
            end
        end
    end

    return nil, name
end

--- MARK: Resolver el build objetivo (el más usado por los top)

local function GetRaidDifficultyKey()
    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType == "raid" then
        return RAID_DIFF_KEY[difficultyID] or "mythic"
    end
    return RAID_DIFF_KEY[GetRaidDifficultyID()] or "mythic"
end

local function IsRaidContext()
    local _, instanceType = GetInstanceInfo()
    if instanceType == "raid" then
        return true
    elseif instanceType == "party" then
        return false
    end
    return IsInRaid() -- fuera de instancia: grupo de raid -> raid, si no -> M+
end

--- `dungeon` = mplus[clave] = { [bracket] = { [arma] = stats[] } }
--- Elige el bracket configurado; en "auto" el de mayor nivel con al menos DB.minRuns runs
--- (si ninguno llega, el de mayor nivel que tenga datos).
local function PickBracket(dungeon)
    if type(dungeon) ~= "table" then
        return
    end
    if DB.bracket ~= "auto" and dungeon[DB.bracket] then
        local stats = AllOrFirst(dungeon[DB.bracket])
        if type(stats) == "table" and #stats > 0 then
            return stats, DB.bracket
        end
    end
    local candidates = {}
    for key, weapons in pairs(dungeon) do
        local stats = AllOrFirst(weapons)
        local level = tonumber(tostring(key):match("^(%d+)"))
        if level and type(stats) == "table" and #stats > 0 then
            candidates[#candidates + 1] = { key = key, level = level, stats = stats, runs = SumRuns(stats) }
        end
    end
    table.sort(candidates, function(a, b) return a.level > b.level end)
    for _, c in ipairs(candidates) do
        if c.runs >= DB.minRuns then
            return c.stats, c.key
        end
    end
    if candidates[1] then
        return candidates[1].stats, candidates[1].key
    end
end

--- Datos de la mazmorra actual; si no se reconoce o no tiene datos, cae a "todas las mazmorras".
---@return table? stats, string? bracket, string? instanceName, boolean specific
local function GetMplusStats(spec, data)
    local mplus = spec.mplus
    if type(mplus) ~= "table" then
        return
    end
    local dungeonKey, instanceName = ResolveDungeonKey(data)
    if dungeonKey and type(mplus[dungeonKey]) == "table" then
        local stats, bracket = PickBracket(mplus[dungeonKey])
        if stats then
            return stats, bracket, instanceName, true
        end
    end
    local stats, bracket = PickBracket(mplus["all"])
    return stats, bracket, instanceName, false
end

--- Entre todas las raids con datos usa la que tenga más runs (normalmente la del tier actual).
local function GetRaidStats(spec, diffKey)
    local best, bestRuns
    for _, encounters in pairs(spec.raid or {}) do
        local diffs = type(encounters) == "table" and encounters["all"]
        local speeds = type(diffs) == "table" and diffs[diffKey]
        local weapons = AllOrFirst(speeds)
        local stats = AllOrFirst(weapons)
        if type(stats) == "table" and #stats > 0 then
            local total = SumRuns(stats)
            if not bestRuns or total > bestRuns then
                best, bestRuns = stats, total
            end
        end
    end
    return best
end

--- row = { heroTreeId, popularityShare, heroTreeRunCount, recIdx, recRuns, recScore, altIdx, altRuns, altScore, otherIdx, otherRuns, otherScore }
local function PickRow(stats, heroID)
    local best
    for _, row in ipairs(stats) do
        if (not heroID or row[1] == heroID) and (not best or (row[2] or 0) > (best[2] or 0)) then
            best = row
        end
    end
    return best
end

local function PickBuildFromRow(row)
    local candidates = {
        { row[4], row[5] },
        { row[7], row[8] },
        { row[10], row[11] },
    }
    local chosen
    for _, c in ipairs(candidates) do
        if c[1] then
            if DB.pick == "recommended" then
                chosen = c
                break
            elseif not chosen or (c[2] or 0) > (chosen[2] or 0) then
                chosen = c
            end
        end
    end
    if not chosen then
        return
    end
    return chosen[1], chosen[2]
end

local function GetActiveHeroID()
    if C_ClassTalents and C_ClassTalents.GetActiveHeroTalentSpec then
        return C_ClassTalents.GetActiveHeroTalentSpec()
    end
end

---@return table? target, string? errorKey
local function ResolveTarget()
    local data = GetBuildsData()
    if not data or not data.specs then
        return nil, "nodata"
    end
    local specID = Lib.GetSpecialization()
    local spec = specID and data.specs[tostring(specID)]
    if not spec then
        return nil, "nospec"
    end

    local stats, label
    if IsRaidContext() then
        local diffKey = GetRaidDifficultyKey()
        stats = GetRaidStats(spec, diffKey)
        label = "Raid " .. diffKey
    else
        local bracket, instanceName, specific
        stats, bracket, instanceName, specific = GetMplusStats(spec, data)
        if specific then
            label = format("M+ %s · %s", tostring(bracket), tostring(instanceName))
        else
            label = format("M+ %s · todas las mazmorras", tostring(bracket))
            if instanceName then
                label = format("%s (sin datos de %s)", label, instanceName)
            end
        end
    end
    if not stats or #stats == 0 then
        return nil, "nostats"
    end

    local heroID
    if DB.heroMode == "own" then
        heroID = GetActiveHeroID()
    end
    local row = PickRow(stats, heroID) or PickRow(stats)
    if not row then
        return nil, "nostats"
    end

    local index, runs = PickBuildFromRow(row)
    local suffix = index and spec.builds and spec.builds[index]
    if not suffix then
        return nil, "nobuild"
    end

    local heroInfo = spec.heroTrees and spec.heroTrees[tostring(row[1])]
    local heroCount = row[3] or 0
    return {
        importString = (spec.prefix or "") .. suffix,
        heroID = row[1],
        heroName = heroInfo and heroInfo.name,
        heroShare = row[2],
        buildShare = heroCount > 0 and runs and (runs / heroCount) or nil,
        runs = runs,
        label = label,
    }
end

--- MARK: Comparación detallada

local function EntryName(configID, entryID)
    if not entryID then
        return
    end
    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
    if not entryInfo then
        return
    end
    if entryInfo.definitionID then
        local def = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
        if def then
            if def.overrideName and def.overrideName ~= "" then
                return def.overrideName
            end
            local spellID = def.overriddenSpellID or def.spellID
            if spellID and C_Spell and C_Spell.GetSpellName then
                local name = C_Spell.GetSpellName(spellID)
                if name then
                    return name
                end
            end
        end
    end
    if entryInfo.subTreeID then
        local subTreeInfo = C_Traits.GetSubTreeInfo(configID, entryInfo.subTreeID)
        if subTreeInfo and subTreeInfo.name then
            return subTreeInfo.name
        end
    end
end

local function NodeLabel(configID, nodeID, entryID)
    local name = EntryName(configID, entryID)
    if name then
        return name
    end
    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
    if nodeInfo and nodeInfo.entryIDs then
        name = EntryName(configID, nodeInfo.entryIDs[1])
    end
    return name or ("#" .. tostring(nodeID))
end

--- Misma lógica que usa la librería para comparar: rangos comprados y entrada elegida por nodo.
local function Flatten(infos)
    local ranks, choice = {}, {}
    for _, info in ipairs(infos) do
        local nodeID = info.nodeID
        local r = info.ranksPurchased
        if r and r > 0 then
            ranks[nodeID] = (ranks[nodeID] or 0) + r
        end
        local s = info.selectionEntryID
        if s and s > 0 then
            choice[nodeID] = s
        end
    end
    return ranks, choice
end

local function Diff(configID, currentInfos, targetInfos)
    local curRanks, curChoice = Flatten(currentInfos)
    local tgtRanks, tgtChoice = Flatten(targetInfos)
    local missing, extra, changed = {}, {}, {}
    local seen = {}

    local function consider(nodeID)
        if seen[nodeID] then
            return
        end
        seen[nodeID] = true
        local c, t = curRanks[nodeID] or 0, tgtRanks[nodeID] or 0
        local ce, te = curChoice[nodeID], tgtChoice[nodeID]
        if c == 0 and t == 0 then
            return
        end
        if t > 0 and c == 0 then
            missing[#missing + 1] = NodeLabel(configID, nodeID, te)
        elseif c > 0 and t == 0 then
            extra[#extra + 1] = NodeLabel(configID, nodeID, ce)
        elseif ce ~= te then
            changed[#changed + 1] = format("%s -> %s", NodeLabel(configID, nodeID, ce), NodeLabel(configID, nodeID, te))
        elseif c ~= t then
            changed[#changed + 1] = format("%s (%d -> %d)", NodeLabel(configID, nodeID, te), c, t)
        end
    end

    for nodeID in pairs(curRanks) do consider(nodeID) end
    for nodeID in pairs(tgtRanks) do consider(nodeID) end

    return { missing = missing, extra = extra, changed = changed, total = #missing + #extra + #changed }
end

--- MARK: Importar el build (crear/cambiar loadout)

local function OnceEvent(event, callback, timeout)
    local f = CreateFrame("Frame")
    local fired = false
    local function fire()
        if fired then
            return
        end
        fired = true
        f:UnregisterAllEvents()
        f:SetScript("OnEvent", nil)
        callback()
    end
    f:RegisterEvent(event)
    f:SetScript("OnEvent", fire)
    C_Timer.After(timeout or 2, fire)
end

--- Misma estrategia que usa Raider.IO: reutiliza un loadout idéntico si existe; si no, borra el
--- nuestro (si hay) y crea uno nuevo con el build; luego cambia a él.
---@param done fun(success: boolean, text: string)
local function ImportBuild(importString, done)
    local canChange, _, changeError = C_ClassTalents.CanChangeTalents()
    if not canChange then
        done(false, changeError or "No podés cambiar talentos ahora (¿combate o llave en curso?).")
        return
    end

    local activeConfigID = C_ClassTalents.GetActiveConfigID()
    if activeConfigID and C_Traits.ConfigHasStagedChanges(activeConfigID) then
        C_Traits.RollbackConfig(activeConfigID)
    end

    local function matches(configID)
        local current = Lib.ExportLoadout(configID)
        return current and Lib.AreImportStringsEqual(nil, current, nil, importString)
    end

    local activeLoadout = Lib.GetActiveLoadout()
    if activeLoadout and matches(activeLoadout.ID) then
        Lib.PersistentSwitchToLoadout(activeLoadout)
        done(true, "Ese build ya está activo.")
        return
    end

    local loadouts = Lib.GetLoadouts()
    for _, loadout in ipairs(loadouts) do
        if matches(loadout.ID) then
            Lib.PersistentSwitchToLoadout(loadout)
            done(true, format("Cambiando al loadout existente \"%s\"...", tostring(loadout.name)))
            return
        end
    end

    local existing
    for _, loadout in ipairs(loadouts) do
        if loadout.name == LOADOUT_NAME then
            existing = loadout
            break
        end
    end

    local function create()
        local accepted, errorText = Lib.CreateLoadout(importString, LOADOUT_NAME, true, function(info, success)
            Lib.PersistentSwitchToLoadout(info)
            if success then
                done(true, format("Importado en el loadout \"%s\"; cambiando talentos...", tostring(info.name or LOADOUT_NAME)))
            else
                done(true, "Importado, pero no pude ajustar el nombre o las barras de acción; cambiando talentos...")
            end
        end)
        if not accepted then
            done(false, errorText or "No pude crear el loadout (¿llegaste al máximo de loadouts?).")
        end
    end

    if existing then
        if not Lib.DeleteLoadout(existing) then
            done(false, format("No pude borrar el loadout anterior \"%s\".", LOADOUT_NAME))
            return
        end
        OnceEvent("TRAIT_CONFIG_DELETED", create, 2)
    else
        create()
    end
end

--- MARK: Panel de aviso

local panel

local function SavePanelPosition(self)
    local point, _, relPoint, x, y = self:GetPoint(1)
    DB.panelPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function ApplyPanelPosition(self)
    self:ClearAllPoints()
    local p = DB.panelPos
    if p and p.point then
        self:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
    else
        self:SetPoint("TOP", UIParent, "TOP", 0, -180)
    end
end

local function LayoutPanel(f)
    local bodyHeight = f.body:GetStringHeight()
    local statusText = f.status:GetText()
    local statusHeight = (statusText and statusText ~= "") and f.status:GetStringHeight() or 0
    local gap = statusHeight > 0 and 8 or 0
    f:SetHeight(32 + bodyHeight + 10 + statusHeight + gap + 26 + 14)
end

local function SetPanelStatus(f, text, r, g, b)
    f.status:SetText(text or "")
    f.status:SetTextColor(r or 1, g or 1, b or 1)
    LayoutPanel(f)
end

local function OnImportClick()
    local f = panel
    if not f or not f.importString then
        return
    end
    f.importButton:Disable()
    SetPanelStatus(f, "Importando...", 1, 0.82, 0)
    local token = f.token
    ImportBuild(f.importString, function(success, text)
        if not panel or panel.token ~= token then
            return
        end
        if success then
            SetPanelStatus(panel, text, 0.33, 1, 0.33)
            C_Timer.After(4, function()
                if panel and panel.token == token then
                    panel:Hide()
                end
            end)
        else
            SetPanelStatus(panel, text, 1, 0.33, 0.33)
            panel.importButton:Enable()
        end
    end)
end

local function GetPanel()
    if panel then
        return panel
    end
    local f = CreateFrame("Frame", "TopTalentCheckPanel", UIParent, "BasicFrameTemplateWithInset")
    f:SetWidth(420)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePanelPosition(self)
    end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f, "TOP", 0, -6)

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    f.body:SetWidth(392)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(3)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.status:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -10)
    f.status:SetWidth(392)
    f.status:SetJustifyH("LEFT")

    f.importButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.importButton:SetSize(170, 26)
    f.importButton:SetText("Importar build")
    f.importButton:SetScript("OnClick", OnImportClick)

    f.dismissButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.dismissButton:SetSize(170, 26)
    f.dismissButton:SetScript("OnClick", function() f:Hide() end)

    tinsert(UISpecialFrames, "TopTalentCheckPanel") -- Esc también cierra el panel
    panel = f
    return f
end

---@param opts { title: string, body: string, importString?: string }
local function ShowPanel(opts)
    local f = GetPanel()
    f.token = (f.token or 0) + 1
    f.importString = opts.importString
    f.title:SetText(opts.title)
    f.body:SetText(opts.body)
    f.status:SetText("")

    f.dismissButton:ClearAllPoints()
    if opts.importString then
        f.importButton:ClearAllPoints()
        f.importButton:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 14)
        f.importButton:Enable()
        f.importButton:Show()
        f.dismissButton:SetText("Rechazar")
        f.dismissButton:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 14)
    else
        f.importButton:Hide()
        f.dismissButton:SetText("Cerrar")
        f.dismissButton:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    end

    ApplyPanelPosition(f)
    LayoutPanel(f)
    f:Show()
    LayoutPanel(f)

    if DB.sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
        PlaySound(SOUNDKIT.RAID_WARNING)
    end
end

--- MARK: Comprobación

local ERROR_TEXT = {
    nodata = "No hay datos de builds cargados (revisá la línea de datos en el .toc).",
    nospec = "No hay datos de builds para tu especialización.",
    nostats = "No hay estadísticas para este contexto (instancia/dificultad/bracket).",
    nobuild = "El build top referenciado no existe en los datos (datos inconsistentes).",
}

local function RunCheck(manual)
    if not DB.enabled and not manual then
        return
    end
    -- Con una llave en curso no se pueden cambiar talentos: no molestar en ready checks automáticos.
    -- (El /ttc manual sigue funcionando para poder comprobar.)
    if not manual and C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive and C_ChallengeMode.IsChallengeModeActive() then
        return
    end
    if C_SpecializationInfo and C_SpecializationInfo.CanPlayerUseTalentUI and not C_SpecializationInfo.CanPlayerUseTalentUI() then
        if manual then Print("Todavía no podés usar talentos.") end
        return
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        if manual then Print("No se pudo obtener la configuración de talentos activa.") end
        return
    end
    if C_Traits.ConfigHasStagedChanges(configID) then
        ShowPanel({
            title = "TopTalentCheck",
            body = "Tenés cambios de talentos sin confirmar. No puedo comparar hasta que los apliques o los descartes.",
        })
        return
    end

    local target, errorKey = ResolveTarget()
    if not target then
        if manual or DB.verbose then Print(ERROR_TEXT[errorKey] or errorKey) end
        return
    end

    local currentInfos = Lib.GetLoadoutEntryInfos(configID)
    local targetInfos = Lib.GetLoadoutEntryInfos(configID, target.importString)
    if not currentInfos or not targetInfos then
        if manual or DB.verbose then Print("No pude decodificar los talentos para compararlos.") end
        return
    end

    local diff = Diff(configID, currentInfos, targetInfos)
    local hero = target.heroName or ("#" .. tostring(target.heroID))
    local sourceLine = format("Más usado: %s (%d%% de los top)", hero, Pct(target.heroShare))
    if target.buildShare then
        sourceLine = format("%s · este build: %d%%", sourceLine, Pct(target.buildShare))
    end

    if diff.total == 0 then
        if manual or DB.verbose then
            Print(format("|cff55ff55Tus talentos coinciden|r con el build más usado (%s). %s", target.label, sourceLine))
        end
        return
    end

    local lines = {
        format("|cffffd100%s|r", target.label),
        sourceLine,
    }

    local curHero = GetActiveHeroID()
    if curHero and target.heroID and curHero ~= target.heroID then
        local curInfo = C_Traits.GetSubTreeInfo(configID, curHero)
        local curName = curInfo and curInfo.name or tostring(curHero)
        lines[#lines + 1] = format("|cffff8080Árbol de héroe:|r tenés %s, el top usa %s (%d diferencias en total).", curName, hero, diff.total)
    else
        if #diff.missing > 0 then lines[#lines + 1] = "|cff80ff80Faltan:|r " .. Join(diff.missing, 6) end
        if #diff.extra > 0 then lines[#lines + 1] = "|cffff8080Sobran:|r " .. Join(diff.extra, 6) end
        if #diff.changed > 0 then lines[#lines + 1] = "|cffffd100Cambiar:|r " .. Join(diff.changed, 6) end
    end

    ShowPanel({
        title = format("Talentos distintos al build top (%d)", diff.total),
        body = table.concat(lines, "\n"),
        importString = target.importString,
    })
end

--- MARK: Ventana para copiar el string

local copyFrame

local function ShowCopy(text)
    if not copyFrame then
        copyFrame = CreateFrame("Frame", "TopTalentCheckCopyFrame", UIParent, "BasicFrameTemplateWithInset")
        copyFrame:SetSize(480, 90)
        copyFrame:SetPoint("CENTER")
        copyFrame:SetFrameStrata("DIALOG")
        copyFrame:EnableMouse(true)
        copyFrame:SetMovable(true)
        copyFrame:RegisterForDrag("LeftButton")
        copyFrame:SetScript("OnDragStart", copyFrame.StartMoving)
        copyFrame:SetScript("OnDragStop", copyFrame.StopMovingOrSizing)
        copyFrame.title = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        copyFrame.title:SetPoint("TOP", 0, -5)
        copyFrame.title:SetText("TopTalentCheck - Ctrl+C para copiar")
        local editBox = CreateFrame("EditBox", nil, copyFrame, "InputBoxTemplate")
        editBox:SetSize(440, 24)
        editBox:SetPoint("CENTER", 0, -8)
        editBox:SetAutoFocus(false)
        editBox:SetMaxLetters(0)
        editBox:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
        copyFrame.editBox = editBox
        tinsert(UISpecialFrames, "TopTalentCheckCopyFrame")
    end
    copyFrame.editBox:SetText(text)
    copyFrame:Show()
    copyFrame.editBox:SetFocus()
    copyFrame.editBox:HighlightText()
end

--- MARK: Eventos

local lastCheck = 0

local function OnReadyCheck()
    local now = GetTime()
    if now - lastCheck < 5 then
        return
    end
    lastCheck = now
    C_Timer.After(0.2, function()
        local ok, err = pcall(RunCheck, false)
        if not ok then
            Print("error interno: " .. tostring(err))
        end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        TopTalentCheckDB = TopTalentCheckDB or {}
        DB = TopTalentCheckDB
        for k, v in pairs(DEFAULTS) do
            if DB[k] == nil then
                DB[k] = v
            end
        end
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_LOGIN")
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        Lib = LibStub and LibStub(LIB_NAME, true)
        if not Lib or not Lib.IsCompatible() then
            Print("No encontré " .. LIB_NAME .. " (la trae Raider.IO) o no es compatible con este cliente. Addon desactivado.")
            return
        end
        local data = GetBuildsData()
        if not data then
            Print("No hay datos de builds. Revisá la línea de datos en el .toc (ver README).")
            return
        end
        local age = DataAgeDays(data.date)
        if age and age > STALE_DAYS then
            Print(format("|cffffaa00Los datos de builds tienen ~%d días.|r Actualizá Raider.IO y hacé /reload.", age))
        end
        self:RegisterEvent("READY_CHECK")
    elseif event == "READY_CHECK" then
        OnReadyCheck()
    end
end)

--- MARK: Comandos

local function SetChoice(key, value, allowed)
    if allowed and not allowed[value] then
        local t = {}
        for k in pairs(allowed) do t[#t + 1] = k end
        table.sort(t)
        Print("Valor inválido. Opciones: " .. table.concat(t, ", "))
        return
    end
    DB[key] = value
    Print(format("%s = %s", key, tostring(value)))
end

local function PrintZoneInfo()
    local name, instanceType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
    Print(format("Instancia: %s | tipo=%s | mapID=%s | dificultad=%s | zona=%s", tostring(name), tostring(instanceType), tostring(instanceID), tostring(difficultyID), tostring(GetRealZoneText())))
    if instanceType ~= "party" then
        Print("No estás en una mazmorra: se usan los datos generales (\"todas las mazmorras\") o de raid.")
        return
    end
    local key, _, method = ResolveDungeonKey(GetBuildsData())
    if key then
        Print(format("Mazmorra reconocida: clave %s (por %s).", key, method))
        local specID = Lib.GetSpecialization()
        local data = GetBuildsData()
        local spec = specID and data and data.specs and data.specs[tostring(specID)]
        local hasData = spec and spec.mplus and type(spec.mplus[key]) == "table"
        Print(hasData and "Hay datos específicos de esta mazmorra para tu spec." or "No hay datos específicos para tu spec en esta mazmorra: se usará \"todas\".")
    else
        Print("Mazmorra NO reconocida: se usará \"todas las mazmorras\". Ver README (archivo de mazmorras de Raider.IO).")
    end
end

SLASH_TOPTALENTCHECK1 = "/ttc"
SLASH_TOPTALENTCHECK2 = "/toptalentcheck"
SlashCmdList["TOPTALENTCHECK"] = function(msg)
    if not DB or not Lib then
        Print("El addon no está activo (falta la librería o los datos).")
        return
    end
    local cmd, arg = strsplit(" ", (msg or ""):lower(), 2)
    cmd = cmd or ""
    arg = arg and strtrim(arg) or ""

    if cmd == "" or cmd == "check" then
        local ok, err = pcall(RunCheck, true)
        if not ok then Print("error interno: " .. tostring(err)) end
    elseif cmd == "copy" then
        local target, errorKey = ResolveTarget()
        if not target then
            Print(ERROR_TEXT[errorKey] or errorKey)
        else
            ShowCopy(target.importString)
        end
    elseif cmd == "zone" then
        PrintZoneInfo()
    elseif cmd == "on" or cmd == "off" then
        DB.enabled = cmd == "on"
        Print("enabled = " .. tostring(DB.enabled))
    elseif cmd == "verbose" then
        DB.verbose = not DB.verbose
        Print("verbose = " .. tostring(DB.verbose))
    elseif cmd == "sound" then
        DB.sound = not DB.sound
        Print("sound = " .. tostring(DB.sound))
    elseif cmd == "hero" then
        SetChoice("heroMode", arg, { top = true, own = true })
    elseif cmd == "pick" then
        SetChoice("pick", arg, { popular = true, recommended = true })
    elseif cmd == "bracket" then
        if arg == "" then
            Print("Uso: /ttc bracket auto | <clave> (ej. 15-99, 20-99)")
        else
            SetChoice("bracket", arg)
        end
    elseif cmd == "minruns" then
        local n = tonumber(arg)
        if n and n >= 0 then
            DB.minRuns = n
            Print("minRuns = " .. n)
        else
            Print("Uso: /ttc minruns <número>")
        end
    elseif cmd == "resetpos" then
        DB.panelPos = nil
        if panel then ApplyPanelPosition(panel) end
        Print("Posición del panel restablecida.")
    else
        Print("Comandos: /ttc (comprobar ahora), copy, zone, on|off, verbose, sound, hero top|own, pick popular|recommended, bracket auto|<clave>, minruns <n>, resetpos")
        Print(format("Estado: enabled=%s verbose=%s sound=%s hero=%s pick=%s bracket=%s minRuns=%s", tostring(DB.enabled), tostring(DB.verbose), tostring(DB.sound), DB.heroMode, DB.pick, DB.bracket, tostring(DB.minRuns)))
    end
end
