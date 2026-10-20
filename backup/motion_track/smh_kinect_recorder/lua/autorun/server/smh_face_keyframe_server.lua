-- SMH Face Tracking: server-side bridge (v5)
-- Install as lua/autorun/server/smh_face_keyframe_server.lua  (replace the existing file)
--
-- What it does:
--   1. Receives one facial-flex keyframe at a time from the client tracker and
--      stores it in the chosen SMH timeline. It also stores the tracked EYE TARGET
--      in the same keyframe when the timeline has "Eye target" ticked.
--   2. Optional head overlay: turns the tracked head rotation into a small extra
--      rotation of the head physics bone and writes it into the EXISTING physics
--      bone keyframes of a body timeline (so a Kinect body animation gets a more
--      accurate, fluid head). Keeps an in-session copy so  smh_face_head_undo  can
--      restore it. Save your SMH animation first.
--   3. Live head preview: rotates the ragdoll's head physics bone while you track.
--
-- v5 changes: eye target recording, head overlay, live head helper (own message
-- name, so it cannot clash with another helper), diagnostics.
-- Still true from v3/v4: modifier name "flex", weights numbered from 0, quiet by
-- default (smh_face_debug 1 prints every step).
if not SERVER then return end

local NET = "SMHFaceTracking_CaptureFlexKeyframe"
local HEAD_LIVE_NET = "SMHFaceTracking_Head"
local HEAD_DONE_NET = "SMHFaceTracking_HeadOverlayDone"
util.AddNetworkString(NET)
util.AddNetworkString(HEAD_LIVE_NET)
util.AddNetworkString(HEAD_DONE_NET)

local debugCvar = CreateConVar("smh_face_debug", "0", FCVAR_NONE,
    "Print every step of the SMH face keyframe bridge to the console")

local function diag(msg)
    if debugCvar:GetBool() then
        print("[SMH Face Diag] " .. msg)
    end
end

-- Problems are always printed, but each reason at most once every 2 seconds.
local lastProblem = {}
local function problem(reason)
    local now = CurTime()
    if not lastProblem[reason] or now - lastProblem[reason] > 2 then
        lastProblem[reason] = now
        print("[SMH Face Track] " .. reason)
    end
end

-- Accept the internal name, and the menu label just in case
local function isFlexName(name)
    return name == "flex" or name == "Facial flexes"
end
local function isEyeName(name)
    return name == "eyetarget" or name == "Eye target"
end
local function isPhysName(name)
    return name == "physbones" or name == "Physics Bones" or name == "Physics bones"
end

-- Modifiers that are fine on a face-only timeline
local FACE_OK = { flex = true, eyetarget = true }

local sentProperties = {}   -- entity index -> true once SMH properties were sent back
local warnedTimeline = {}   -- "entity:timeline" -> text of the last warning shown
local warnedEyeTip = {}     -- "entity:timeline" -> true once the eye tip was shown

local function finite(v)
    return v == v and math.abs(v) < 1e7
end

-- ===========================================================================
-- Head overlay (writes into existing physics-bone keyframes)
-- ===========================================================================
local headBackup = {}    -- entity -> { [frame] = { Ang = Angle, LocalAng = Angle|nil } }
local overlayStats = {}  -- player -> { changed, skipped, timeline, verified, disabled }

local function angNear(a, b)
    local function d(x, y)
        local v = math.abs(math.NormalizeAngle(x - y))
        return v
    end
    return d(a.p, b.p) < 0.05 and d(a.y, b.y) < 0.05 and d(a.r, b.r) < 0.05
end

local function headPhysIndex(entity)
    local bone = entity:LookupBone("ValveBiped.Bip01_Head1")
    if not bone or bone < 0 then return nil end
    local pb = entity:TranslateBoneToPhysBone(bone)
    if pb == nil or pb < 0 then return nil end
    return pb
end

-- Find this entity's physics-bone keyframe at a frame. Returns keyframe, modifier key.
local function findPhysKeyframe(ply, entity, frame)
    local list
    local ok, res = pcall(SMH.KeyframeManager.GetAllForEntity, ply, entity)
    if ok and type(res) == "table" and next(res) ~= nil then list = res end
    if not list then
        ok, res = pcall(SMH.KeyframeManager.GetAllForEntity, ply, { entity })
        if ok and type(res) == "table" then list = res end
    end
    if not list then return nil end
    for _, kf in pairs(list) do
        if type(kf) == "table" and (kf.Frame or kf.Position) == frame and type(kf.Modifiers) == "table" then
            for k, data in pairs(kf.Modifiers) do
                if isPhysName(k) and type(data) == "table" then return kf, k end
            end
        end
    end
    return nil
end

local function statsFor(ply)
    local s = overlayStats[ply]
    if not s then
        s = { changed = 0, skipped = 0, timeline = 0, verified = false, disabled = false }
        overlayStats[ply] = s
    end
    return s
end

-- off: Angle (pitch, yaw, roll) in the head's own frame
local function applyHeadOverlay(ply, entity, frame, bodyTimeline, off)
    local stats = statsFor(ply)
    stats.timeline = bodyTimeline
    if stats.disabled then return end

    local props = SMH.PropertiesManager.GetAllEntityProperties(ply, entity)
    local mods = props and props.TimelineMods and props.TimelineMods[bodyTimeline]
    if not mods then
        problem("Head overlay: SMH timeline " .. bodyTimeline .. " does not exist for this entity.")
        stats.disabled = true
        return
    end
    local hasPhys = false
    for _, m in ipairs(mods) do if isPhysName(m) then hasPhys = true end end
    if not hasPhys then
        problem("Head overlay: timeline " .. bodyTimeline .. " does not have 'Physics bones' ticked.")
        stats.disabled = true
        return
    end

    local pb = headPhysIndex(entity)
    if not pb then
        problem("Head overlay: this model has no ValveBiped head physics bone.")
        stats.disabled = true
        return
    end

    local kf, key = findPhysKeyframe(ply, entity, frame)
    if not kf then
        stats.skipped = stats.skipped + 1   -- no body keyframe on this frame
        return
    end
    local d = kf.Modifiers[key][pb]
    if type(d) ~= "table" or not d.Ang then
        problem("Head overlay: the body keyframe at frame " .. frame .. " has no head data.")
        stats.skipped = stats.skipped + 1
        return
    end

    -- Remember the untouched angles the first time a frame is changed, and always
    -- build from them, so recording twice replaces the overlay instead of stacking.
    local store = headBackup[entity]
    if not store then store = {}; headBackup[entity] = store end
    local orig = store[frame]
    if not orig then
        orig = { Ang = Angle(d.Ang.p, d.Ang.y, d.Ang.r) }
        if d.LocalAng then orig.LocalAng = Angle(d.LocalAng.p, d.LocalAng.y, d.LocalAng.r) end
        store[frame] = orig
    end

    local _, newAng = LocalToWorld(vector_origin, off, d.Pos or vector_origin, orig.Ang)
    d.Ang = newAng
    if orig.LocalAng then
        local _, newLocal = LocalToWorld(vector_origin, off, d.LocalPos or vector_origin, orig.LocalAng)
        d.LocalAng = newLocal
    end

    -- One-time check that SMH really keeps this data (and did not hand us a copy).
    if not stats.verified then
        local kf2, key2 = findPhysKeyframe(ply, entity, frame)
        local d2 = kf2 and kf2.Modifiers[key2][pb]
        if not d2 or not d2.Ang or not angNear(d2.Ang, newAng) then
            problem("Head overlay: SMH did not keep the change (this SMH version hands out copies). Nothing was modified. Run smh_face_dump_keyframes and send me the output.")
            d.Ang = orig.Ang
            if orig.LocalAng then d.LocalAng = orig.LocalAng end
            store[frame] = nil
            stats.disabled = true
            return
        end
        stats.verified = true
    end
    stats.changed = stats.changed + 1
end

local function undoHeadOverlay(ply)
    local restored = 0
    local pbCache = {}
    for entity, store in pairs(headBackup) do
        if IsValid(entity) then
            local pb = headPhysIndex(entity)
            for frame, orig in pairs(store) do
                local kf, key = findPhysKeyframe(ply, entity, frame)
                local d = kf and pb and kf.Modifiers[key][pb]
                if type(d) == "table" then
                    d.Ang = orig.Ang
                    if orig.LocalAng then d.LocalAng = orig.LocalAng end
                    restored = restored + 1
                end
            end
        end
    end
    headBackup = {}
    return restored
end

concommand.Add("smh_face_head_undo", function(ply)
    if not IsValid(ply) then ply = player.GetAll()[1] end
    if not IsValid(ply) then return end
    local n = undoHeadOverlay(ply)
    local text = "[SMH Face Track] Head overlay undone on " .. n .. " body keyframe(s)."
    print(text)
    ply:ChatPrint(text)
end)

-- Diagnostic: print how SMH stores keyframes for the entity under your crosshair.
concommand.Add("smh_face_dump_keyframes", function(ply)
    if not IsValid(ply) then ply = player.GetAll()[1] end
    if not IsValid(ply) or not SMH or not SMH.KeyframeManager then
        print("[SMH Face Dump] SMH is not loaded.")
        return
    end
    local ent = ply:GetEyeTrace().Entity
    if not IsValid(ent) then
        print("[SMH Face Dump] Look at the ragdoll and run this again.")
        return
    end
    print("[SMH Face Dump] entity " .. tostring(ent) .. " model " .. tostring(ent:GetModel()))
    for _, form in ipairs({ "single", "array" }) do
        local ok, res = pcall(SMH.KeyframeManager.GetAllForEntity, ply, form == "single" and ent or { ent })
        print("[SMH Face Dump] GetAllForEntity(" .. form .. "): ok=" .. tostring(ok) .. " type=" .. type(res) ..
            " count=" .. (type(res) == "table" and table.Count(res) or 0))
        if ok and type(res) == "table" then
            local shown = 0
            for k, kf in pairs(res) do
                if shown >= 4 then break end
                shown = shown + 1
                print("  entry key=" .. tostring(k) .. " type=" .. type(kf))
                if type(kf) == "table" then
                    for fk, fv in pairs(kf) do
                        print("    field " .. tostring(fk) .. " = " .. tostring(fv) .. " (" .. type(fv) .. ")")
                        if fk == "Modifiers" and type(fv) == "table" then
                            for mk, mv in pairs(fv) do
                                print("      modifier " .. tostring(mk) .. " (" .. type(mv) .. ")")
                                if type(mv) == "table" and isPhysName(mk) then
                                    local pb = headPhysIndex(ent)
                                    local d = pb and mv[pb]
                                    if type(d) == "table" then
                                        for dk, dv in pairs(d) do
                                            print("        head[" .. pb .. "]." .. tostring(dk) .. " = " .. tostring(dv))
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if next(res) ~= nil then break end
        end
    end
end)

net.Receive(HEAD_DONE_NET, function(_, ply)
    local s = overlayStats[ply]
    if not s then return end
    local text
    if s.disabled then
        text = "[SMH Face Track] Head overlay did not run (see the console for the reason)."
    else
        text = "[SMH Face Track] Head overlay: changed " .. s.changed .. " keyframe(s) on timeline " ..
            s.timeline .. ", skipped " .. s.skipped .. " frame(s) that have no body keyframe." ..
            " Undo with smh_face_head_undo."
    end
    print(text)
    if IsValid(ply) then ply:ChatPrint(text) end
    overlayStats[ply] = nil
end)

-- ===========================================================================
-- Live head preview (rotates the head physics bone while you track)
-- ===========================================================================
local liveHead = {}   -- entity -> { phys, base, lastSet, moveable }

local function liveHeadPhys(entity)
    local pb = headPhysIndex(entity)
    if not pb then return nil end
    local phys = entity:GetPhysicsObjectNum(pb)
    if not IsValid(phys) then return nil end
    return phys
end

net.Receive(HEAD_LIVE_NET, function(_, ply)
    local entity = net.ReadEntity()
    local active = net.ReadBool()
    local off = net.ReadAngle()
    if not IsValid(ply) or not IsValid(entity) or entity == ply then return end

    local ok, err = pcall(function()
        local st = liveHead[entity]
        if not active then
            if st and IsValid(st.phys) then
                st.phys:SetAngles(st.base)
                st.phys:EnableMotion(st.moveable)
                st.phys:Wake()
            end
            liveHead[entity] = nil
            return
        end

        local phys = liveHeadPhys(entity)
        if not phys then
            problem("Live head: this model has no ValveBiped head physics bone.")
            return
        end
        local cur = phys:GetAngles()
        if not st or st.phys ~= phys then
            st = { phys = phys, moveable = phys:IsMoveable(), base = cur }
            liveHead[entity] = st
        elseif not st.lastSet or not angNear(cur, st.lastSet) then
            st.base = cur   -- the animation (or physics) moved the head: new base pose
        end
        local _, newAng = LocalToWorld(vector_origin, off, phys:GetPos(), st.base)
        phys:EnableMotion(false)
        phys:SetAngles(newAng)
        phys:Wake()
        st.lastSet = phys:GetAngles()
    end)
    if not ok then problem("Live head error: " .. tostring(err)) end
end)

hook.Add("EntityRemoved", "SMHFaceKeyframe_Cleanup", function(ent)
    if IsValid(ent) then
        sentProperties[ent:EntIndex()] = nil
        liveHead[ent] = nil
        headBackup[ent] = nil
    end
end)

-- ===========================================================================
-- Face keyframes
-- ===========================================================================
local function sendProperties(properties)
    local name, timelines, colors, counts, modifiers = SMH.TableSplit.DProperties(properties)
    net.WriteString(name)
    net.WriteUInt(timelines, 32)
    for i = 1, timelines do
        net.WriteUInt(i, 4)
        net.WriteColor(colors[i])
        net.WriteUInt(counts[i], 32)
        for j = 1, counts[i] do net.WriteString(modifiers[i][j]) end
    end
end

net.Receive(NET, function(_, ply)
    local entity = net.ReadEntity()
    local frame = net.ReadUInt(32)
    local timeline = net.ReadUInt(8)
    local scale = net.ReadFloat()
    local count = net.ReadUInt(10)
    local weights = {}
    -- SMH numbers facial weights from 0 (Weights[0] .. Weights[count - 1])
    for i = 0, count - 1 do weights[i] = net.ReadFloat() end

    -- Optional extras (older clients stop after the weights; reads then give false/0)
    local eye = nil
    if net.ReadBool() then
        local ex, ey, ez = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
        if finite(ex) and finite(ey) and finite(ez) then eye = Vector(ex, ey, ez) end
    end
    local overlayTimeline = net.ReadUInt(8)
    local headOff = nil
    if overlayTimeline > 0 then
        local hp, hy, hr = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
        if finite(hp) and finite(hy) and finite(hr) then
            headOff = Angle(math.Clamp(hp, -60, 60), math.Clamp(hy, -60, 60), math.Clamp(hr, -60, 60))
        end
    end

    diag("keyframe received: entity " .. tostring(entity) .. "  frame " .. frame ..
        "  timeline " .. timeline .. "  flexes " .. count ..
        "  eye " .. tostring(eye ~= nil) .. "  head overlay timeline " .. overlayTimeline)

    if not IsValid(ply) or not IsValid(entity) or entity == ply then
        problem("Ignored a keyframe: the player or entity is not valid.")
        return
    end
    if not SMH or not SMH.PropertiesManager or not SMH.KeyframeManager or not SMH.TableSplit then
        problem("Ignored a keyframe: Stop Motion Helper is not loaded on the server.")
        return
    end
    if frame > 1000000 or timeline < 1 or timeline > 10 then
        problem("Ignored a keyframe: frame or timeline out of range.")
        return
    end
    if count == 0 or count ~= entity:GetFlexNum() then
        problem("Ignored a keyframe: the flex count does not match the model.")
        return
    end
    if scale ~= scale or math.abs(scale) > 100 then
        problem("Ignored a keyframe: bad flex scale.")
        return
    end
    for i = 0, count - 1 do
        if weights[i] ~= weights[i] or math.abs(weights[i]) > 100 then
            problem("Ignored a keyframe: a flex weight was not a valid number.")
            return
        end
    end

    local isNew = SMH.PropertiesManager.CheckEntity(ply, entity)
    SMH.PropertiesManager.AddEntity(ply, entity)
    local properties = SMH.PropertiesManager.GetAllEntityProperties(ply, entity)
    if not properties or not properties.TimelineMods or not properties.TimelineMods[timeline] then
        problem("No SMH timeline " .. timeline .. " exists for this entity. Add it in SMH first.")
        return
    end

    local enabled = false
    local eyeEnabled = false
    local others = {}
    for _, mod in ipairs(properties.TimelineMods[timeline]) do
        if isFlexName(mod) then
            enabled = true
        elseif isEyeName(mod) then
            eyeEnabled = true
        elseif not FACE_OK[mod] then
            others[#others + 1] = tostring(mod)
        end
    end

    if not enabled then
        problem("Turn on 'Facial flexes' for timeline " .. timeline .. " in SMH's timeline settings.")
        return
    end

    -- A face-only timeline is cleaner: every other ticked modifier would also
    -- save the ragdoll's current pose into this timeline for each face frame.
    local warnKey = entity:EntIndex() .. ":" .. timeline
    local warnText = table.concat(others, ", ")
    if warnedTimeline[warnKey] ~= warnText then
        warnedTimeline[warnKey] = warnText
        if #others > 0 then
            local text = "[SMH Face Track] Timeline " .. timeline .. " also records: " .. warnText ..
                ". For a face-only timeline, untick those in SMH's timeline settings."
            print(text)
            ply:ChatPrint(text)
        end
    end

    -- Eye movement is recorded whenever the timeline has 'Eye target' ticked.
    if eye and not eyeEnabled and not warnedEyeTip[warnKey] then
        warnedEyeTip[warnKey] = true
        local text = "[SMH Face Track] Tip: tick 'Eye target' on timeline " .. timeline ..
            " in SMH's timeline settings to record eye movement too."
        print(text)
        ply:ChatPrint(text)
    end

    local keyframes = SMH.KeyframeManager.Create(ply, entity, frame, timeline)
    if type(keyframes) ~= "table" then
        problem("SMH did not create a keyframe at frame " .. frame .. ".")
        return
    end

    local facial = nil
    local eyeKf = nil
    for _, kf in ipairs(keyframes) do
        if isFlexName(kf.Modifier) then facial = kf end
        if isEyeName(kf.Modifier) then eyeKf = kf end
    end
    if not facial then
        problem("SMH returned no facial flex keyframe at frame " .. frame .. ".")
        return
    end
    if type(facial.Modifiers) ~= "table" then
        problem("The facial flex keyframe has an unexpected layout; nothing was saved.")
        return
    end

    -- Use whichever key the keyframe already uses, otherwise the internal name
    local key = "flex"
    for k in pairs(facial.Modifiers) do
        if isFlexName(k) then key = k end
    end
    facial.Modifiers[key] = { Scale = scale, Weights = weights }

    -- Eye target: SMH stores one vector, { EyeTarget = Vector }
    if eye and eyeEnabled then
        if eyeKf and type(eyeKf.Modifiers) == "table" then
            local eyeKey = "eyetarget"
            for k in pairs(eyeKf.Modifiers) do
                if isEyeName(k) then eyeKey = k end
            end
            eyeKf.Modifiers[eyeKey] = { EyeTarget = eye }
        else
            problem("'Eye target' is ticked on timeline " .. timeline ..
                " but SMH made no eye keyframe (the model needs an 'eyes' attachment).")
        end
    end

    local total, ids, _, frames, ins, outs, _, mods = SMH.TableSplit.DKeyframes(keyframes)

    local entIndex = entity:EntIndex()
    local sendNew = isNew and not sentProperties[entIndex]

    net.Start(SMH.MessageTypes.UpdateKeyframeResponse)
    net.WriteEntity(entity)
    net.WriteUInt(math.min(total, 1000), 32)
    for i = 1, math.min(total, 1000) do
        net.WriteUInt(ids[i], 32)
        net.WriteUInt(frames[i], 32)
        net.WriteFloat(ins[i])
        net.WriteFloat(outs[i])
        net.WriteString(mods[i])
    end
    net.WriteBool(sendNew and true or false)
    if sendNew then
        sendProperties(properties)
        sentProperties[entIndex] = true
    end
    net.Send(ply)

    diag("recorded facial flex keyframe at frame " .. frame .. " on timeline " .. timeline)

    -- Head overlay onto the chosen body timeline (never the face timeline itself)
    if headOff and overlayTimeline ~= timeline then
        local ok, err = pcall(applyHeadOverlay, ply, entity, frame, overlayTimeline, headOff)
        if not ok then
            statsFor(ply).disabled = true
            problem("Head overlay error: " .. tostring(err))
        end
    end
end)
