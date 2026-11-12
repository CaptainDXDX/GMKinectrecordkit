-- Stop Motion Helper playback fixes, applied on top of SMH without editing it:
--   * keyframes are indexed per entity/modifier and binary-searched, instead of every modifier rescanning every
--     keyframe of the entity each server tick (the main cause of playback FPS drops with dense/baked animations)
--   * stepped playback only reapplies the pose when the frame number actually changes
--   * bone manips are only set when their value changed
--   * optional cubic (Catmull-Rom) interpolation for bones/physbones/position, so motion doesn't kink at keyframes
--   * optional sub-frame playback, so playback isn't stepped at the timeline rate on a faster server tick

AddCSLuaFile()

if CLIENT then
    local cv_spline = CreateClientConVar("smh_spline", "1", true, false, "SMH: cubic interpolation between keyframes")
    local cv_subframe = CreateClientConVar("smh_subframe", "1", true, false, "SMH: play back between timeline frames")

    hook.Add("Initialize", "SMHPlaybackFix", function()
        if not SMH or not SMH.Settings then return end
        local GetAll = SMH.Settings.GetAll
        SMH.Settings.GetAll = function(...)
            local settings = GetAll(...)
            settings.Spline = cv_spline:GetBool()
            settings.Subframe = cv_subframe:GetBool()
            return settings
        end
    end)

    hook.Add("PopulateToolMenu", "SMHPlaybackFix_Menu", function()
        spawnmenu.AddToolMenuOption("Utilities", "Stop Motion Helper", "SMHPlaybackFix", "Playback", "", "", function(panel)
            panel:Help("Playback options added by the SMH playback fix.")
            panel:CheckBox("Smooth (cubic) interpolation between keyframes", "smh_spline")
            panel:ControlHelp("Removes the visible kink where motion changes direction at a keyframe. Applies to bones, physical bones and position.")
            panel:CheckBox("Play between timeline frames", "smh_subframe")
            panel:ControlHelp("Interpolates every server tick instead of stepping at the timeline frame rate.")
        end)
    end)

    return
end

local SPLINE_MODS = { physbones = true, bones = true, position = true }

---------------------------------------------------------------- keyframe index

local Index = {}   -- [player] = { [entity] = { [modifier] = keyframes sorted by Frame } }
local Dirty = true

local function MarkDirty() Dirty = true end

local function BuildIndex()
    Index = {}
    for player, pdata in pairs(SMH.KeyframeData.Players) do
        local pindex = {}
        for entity, keyframes in pairs(pdata.Entities) do
            local bymod = {}
            for _, kf in pairs(keyframes) do
                local list = bymod[kf.Modifier]
                if not list then
                    list = {}
                    bymod[kf.Modifier] = list
                end
                list[#list + 1] = kf
            end
            for _, list in pairs(bymod) do
                table.sort(list, function(a, b) return a.Frame < b.Frame end)
            end
            pindex[entity] = bymod
        end
        Index[player] = pindex
    end
    Dirty = false
end

-- index of the last keyframe with Frame <= frame (0 if frame is before the first)
local function Floor(list, frame)
    local lo, hi = 0, #list + 1
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if list[mid].Frame <= frame then lo = mid else hi = mid end
    end
    return lo
end

---------------------------------------------------------------- cubic interpolation

-- Hermite segment p1->p2 over keyframe times t1->t2, tangents from the neighbours (non-uniform Catmull-Rom)
local function Hermite(p0, p1, p2, p3, t0, t1, t2, t3, s)
    local h = t2 - t1
    local m1 = (p2 - p0) * (h / (t2 - t0))
    local m2 = (p3 - p1) * (h / (t3 - t1))
    local s2, s3 = s * s, s * s * s
    return p1 * (2 * s3 - 3 * s2 + 1) + m1 * (s3 - 2 * s2 + s) + p2 * (3 * s2 - 2 * s3) + m2 * (s3 - s2)
end

local function Unwrap(a, ref)
    return Vector(ref.x + math.NormalizeAngle(a.p - ref.x), ref.y + math.NormalizeAngle(a.y - ref.y), ref.z + math.NormalizeAngle(a.r - ref.z))
end

local function SplineValue(v0, v1, v2, v3, t, s)
    local ty = type(v1)
    if type(v2) ~= ty then return v1 end
    if type(v0) ~= ty then v0 = nil end
    if type(v3) ~= ty then v3 = nil end

    if ty == "Vector" then
        return Hermite(v0 or v1, v1, v2, v3 or v2, t[0], t[1], t[2], t[3], s)
    elseif ty == "Angle" then
        local a1 = Vector(v1.p, v1.y, v1.r)
        local a2 = Unwrap(v2, a1)
        local a0 = v0 and Unwrap(v0, a1) or a1
        local a3 = v3 and Unwrap(v3, a2) or a2
        local r = Hermite(a0, a1, a2, a3, t[0], t[1], t[2], t[3], s)
        return Angle(r.x, r.y, r.z)
    elseif ty == "number" then
        return Lerp(s, v1, v2)
    elseif ty == "table" then
        local out = {}
        for k, x in pairs(v1) do
            out[k] = SplineValue(v0 and v0[k], x, v2[k], v3 and v3[k], t, s)
        end
        return out
    end
    return v1
end

---------------------------------------------------------------- applying a frame

-- Tracks that layer on top of others are applied last (e.g. lip sync over the face track's mouth)
local APPLY_LAST = { "lipsync" }
local IS_LAST = {}
for _, name in ipairs(APPLY_LAST) do IS_LAST[name] = true end

local function ApplyModifier(entity, name, list, frame, settings)
    local mod = SMH.Modifiers[name]
    local n = #list
    if not mod or n == 0 then return end

    local i = Floor(list, frame)
    local k1, k2
    if i == 0 then
        k1 = list[1]
    elseif i == n or list[i].Frame == frame then
        k1 = list[i]
    else
        k1, k2 = list[i], list[i + 1]
    end

    local d1 = k1.Modifiers[name]
    if not d1 then return end

    if not k2 or settings.TweenDisable then
        mod:Load(entity, d1, settings)
        return
    end

    local d2 = k2.Modifiers[name]
    if not d2 then
        mod:Load(entity, d1, settings)
        return
    end

    local s = (frame - k1.Frame) / (k2.Frame - k1.Frame)
    s = math.EaseInOut(s, k1.EaseOut, k2.EaseIn)

    if settings.Spline and SPLINE_MODS[name] then
        local k0, k3 = list[i - 1], list[i + 2]
        local h = k2.Frame - k1.Frame
        local t = {
            [0] = k0 and k0.Frame or (k1.Frame - h),
            [1] = k1.Frame,
            [2] = k2.Frame,
            [3] = k3 and k3.Frame or (k2.Frame + h),
        }
        local data = SplineValue(k0 and k0.Modifiers[name], d1, d2, k3 and k3.Modifiers[name], t, s)
        mod:Load(entity, data, settings)
    else
        mod:LoadBetween(entity, d1, d2, s, settings)
    end
end

local function ApplyFrame(player, frame, settings, ignored)
    if Dirty then BuildIndex() end
    local pindex = Index[player]
    if not pindex then return end

    for entity, bymod in pairs(pindex) do
        if not IsValid(entity) or (ignored and ignored[entity]) then continue end

        if entity == player then
            if settings.EnableWorld then
                SMH.WorldKeyframesManager.Load(player, math.Round(frame), SMH.KeyframeData.Players[player].Entities[entity])
            end
            continue
        end

        for name, list in pairs(bymod) do
            if not IS_LAST[name] then ApplyModifier(entity, name, list, frame, settings) end
        end
        for _, name in ipairs(APPLY_LAST) do
            if bymod[name] then ApplyModifier(entity, name, bymod[name], frame, settings) end
        end
    end
end

---------------------------------------------------------------- playback

local Active = {}

local function Install()
    if not SMH or not SMH.PlaybackManager or not SMH.KeyframeData then
        ErrorNoHalt("SMH playback fix: Stop Motion Helper not found, not installed.\n")
        return
    end

    -- anything that adds, removes or moves keyframes invalidates the index
    local KD = SMH.KeyframeData
    local New, Delete = KD.New, KD.Delete
    KD.New = function(...) MarkDirty() return New(...) end
    KD.Delete = function(...) MarkDirty() return Delete(...) end

    local KM = SMH.KeyframeManager
    for _, fn in ipairs({ "Update", "Copy", "Delete", "ImportSave", "Create" }) do
        local orig = KM[fn]
        if orig then KM[fn] = function(...) MarkDirty() return orig(...) end end
    end
    hook.Add("EntityRemoved", "SMHPlaybackFix_Dirty", function(entity)
        for _, pindex in pairs(Index) do
            if pindex[entity] then MarkDirty() return end
        end
    end)

    local MGR = SMH.PlaybackManager

    MGR.SetFrame = function(player, frame, settings)
        ApplyFrame(player, frame, settings)
    end

    MGR.SetFrameIgnore = function(player, frame, settings, ignored)
        ApplyFrame(player, frame, settings, ignored)
    end

    MGR.StartPlayback = function(player, startFrame, endFrame, playbackRate, settings)
        Active[player] = {
            StartFrame = startFrame,
            EndFrame = endFrame,
            PlaybackRate = playbackRate,
            Timer = 0,
            Settings = settings,
            Last = nil,
        }
        ApplyFrame(player, startFrame, settings)
    end

    MGR.StopPlayback = function(player)
        Active[player] = nil
    end

    hook.Remove("Think", "SMHPlaybackManagerThink")
    hook.Add("Think", "SMHPlaybackFix_Think", function()
        for player, pb in pairs(Active) do
            if not IsValid(player) then
                Active[player] = nil
                continue
            end

            pb.Timer = pb.Timer + FrameTime()
            local frame = pb.StartFrame + pb.Timer * pb.PlaybackRate
            if frame > pb.EndFrame then
                -- loop from the start of the timeline, like SMH does
                pb.StartFrame, pb.Timer, frame = 0, 0, 0
            end

            local settings = pb.Settings
            if not ((settings.SmoothPlayback or settings.Subframe) and not settings.TweenDisable) then
                frame = math.floor(frame)
            end

            if frame ~= pb.Last then
                pb.Last = frame
                ApplyFrame(player, frame, settings)
            end
        end
    end)

    -- bone manips: skip unchanged values (each set costs networking, and Advanced Bonemerge hooks every call)
    local bones = SMH.Modifiers.bones
    if bones then
        local function Set(entity, data)
            for b = 0, entity:GetBoneCount() - 1 do
                local d = data[b]
                if d then
                    if entity:GetManipulateBonePosition(b) ~= d.Pos then entity:ManipulateBonePosition(b, d.Pos) end
                    if entity:GetManipulateBoneAngles(b) ~= d.Ang then entity:ManipulateBoneAngles(b, d.Ang) end
                    if entity:GetManipulateBoneScale(b) ~= d.Scale then entity:ManipulateBoneScale(b, d.Scale) end
                end
            end
        end

        function bones:Load(entity, data)
            if self:IsEffect(entity) then entity = entity.AttachedEntity end
            Set(entity, data)
        end

        function bones:LoadBetween(entity, data1, data2, percentage)
            if self:IsEffect(entity) then entity = entity.AttachedEntity end
            local data = {}
            for b, d1 in pairs(data1) do
                local d2 = data2[b]
                if d2 then
                    data[b] = {
                        Pos = SMH.LerpLinearVector(d1.Pos, d2.Pos, percentage),
                        Ang = SMH.LerpLinearAngle(d1.Ang, d2.Ang, percentage),
                        Scale = SMH.LerpLinear(d1.Scale, d2.Scale, percentage),
                    }
                end
            end
            Set(entity, data)
        end
    end

    MsgN("SMH playback fix installed.")
end

hook.Add("Initialize", "SMHPlaybackFix", Install)
