-- Kinect Skeleton Converter | Clean Rewrite
--
-- Converts any ragdoll (ValveBiped or not) to work with Garry's Mod's built-in
-- Kinect motion sensor ("Control With Motion Sensor"), with automatic bone
-- detection and a visual manual-mapping editor as a fallback/override.
--
-- Right-click a ragdoll -> "Convert Skeleton" to open the editor.
--
-- This is a cleaned-up rewrite of an earlier version that had accumulated a
-- lot of experimental retargeting/calibration code which ended up blocking
-- all movement by default. The conversion logic here is the same pattern
-- Valve's own stock ValveBiped Kinect builder uses: a PositionTable and
-- AnglesTable tell the engine which sensor joint drives which physics bone,
-- the engine solves the pose, and Complete() only does small cleanup
-- (spine curve, foot alignment) afterward.

AddCSLuaFile()

------------------------------------------------------------
-- ANATOMICAL ROLE RESOLUTION
-- Canonical ValveBiped names are the 15 roles every Kinect v1 skeleton
-- needs. Candidate aliases let non-ValveBiped models (HWM, L4D, custom
-- ports, etc.) be auto-detected by anatomy instead of exact bone names.
------------------------------------------------------------

local ROLE_CANDIDATES = {
    ["ValveBiped.Bip01_Pelvis"] = {"ValveBiped.Bip01_Pelvis", "bip_pelvis", "bip_hip", "pelvis", "hips"},
    ["ValveBiped.Bip01_Spine4"] = {"ValveBiped.Bip01_Spine4", "bip_spine_1", "bip_spine_2", "bip_spine_3", "spine_1", "spine_2", "spine_3"},
    ["ValveBiped.Bip01_Head1"] = {"ValveBiped.Bip01_Head1", "bip_head", "head"},
    ["ValveBiped.Bip01_L_UpperArm"] = {"ValveBiped.Bip01_L_UpperArm", "bip_upperArm_L", "upperarm_l", "leftupperarm"},
    ["ValveBiped.Bip01_R_UpperArm"] = {"ValveBiped.Bip01_R_UpperArm", "bip_upperArm_R", "upperarm_r", "rightupperarm"},
    ["ValveBiped.Bip01_L_Forearm"] = {"ValveBiped.Bip01_L_Forearm", "bip_lowerArm_L", "lowerarm_l", "leftforearm"},
    ["ValveBiped.Bip01_R_Forearm"] = {"ValveBiped.Bip01_R_Forearm", "bip_lowerArm_R", "lowerarm_r", "rightforearm"},
    ["ValveBiped.Bip01_L_Hand"] = {"ValveBiped.Bip01_L_Hand", "bip_hand_L", "hand_l", "lefthand"},
    ["ValveBiped.Bip01_R_Hand"] = {"ValveBiped.Bip01_R_Hand", "bip_hand_R", "hand_r", "righthand"},
    ["ValveBiped.Bip01_L_Thigh"] = {"ValveBiped.Bip01_L_Thigh", "bip_hip_L", "thigh_l", "leftupleg"},
    ["ValveBiped.Bip01_R_Thigh"] = {"ValveBiped.Bip01_R_Thigh", "bip_hip_R", "thigh_r", "rightupleg"},
    ["ValveBiped.Bip01_L_Calf"] = {"ValveBiped.Bip01_L_Calf", "bip_knee_L", "calf_l", "leftleg"},
    ["ValveBiped.Bip01_R_Calf"] = {"ValveBiped.Bip01_R_Calf", "bip_knee_R", "calf_r", "rightleg"},
    ["ValveBiped.Bip01_L_Foot"] = {"ValveBiped.Bip01_L_Foot", "bip_foot_L", "foot_l", "leftfoot"},
    ["ValveBiped.Bip01_R_Foot"] = {"ValveBiped.Bip01_R_Foot", "bip_foot_R", "foot_r", "rightfoot"}
}

-- Stable order so the same role always gets the same physics part on a
-- given model, and so index 1..15 lines up with LABELS/JOINT_POINTS below.
local ROLE_ORDER = {
    "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine4", "ValveBiped.Bip01_Head1",
    "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_R_UpperArm",
    "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_R_Forearm",
    "ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_R_Hand",
    "ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_R_Thigh",
    "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_R_Calf",
    "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Foot"
}

function GetBoneIndexByName(ent, name)
    if not IsValid(ent) or not name then return -1 end
    local boneCount = ent:GetBoneCount() or 0
    for i = 0, boneCount - 1 do
        local actual = ent:GetBoneName(i)
        if actual and string.lower(actual) == string.lower(name) then return i end
    end
    return -1
end

-- Resolve an animation bone to ITS OWN physics body (not an ancestor's), and
-- only if exactly one physics body claims it. This is the part that actually
-- identifies which physics object a role belongs to; everything downstream
-- (the builder's PositionTable/AnglesTable keys) is a physics index, not a
-- bone index, because that's what SetRagdollBuildFunction solves against.
local function ResolveExactPhysicsIndex(ent, animationBone)
    if not IsValid(ent) or animationBone == nil or animationBone < 0 then return -1 end
    local matches = {}
    for phys = 0, (ent:GetPhysicsObjectCount() or 0) - 1 do
        if ent:TranslatePhysBoneToBone(phys) == animationBone and
            IsValid(ent:GetPhysicsObjectNum(phys)) then
            matches[#matches + 1] = phys
        end
    end
    if #matches == 1 then return matches[1] end
    return -1 -- Never silently use a conflicting translation.
end

-- Find the physics-bearing bone that is the nearest common ancestor of the
-- two upper-arm bones. This identifies the "chest" bone by anatomy instead
-- of by name: whatever a model calls its spine bones, and whichever
-- direction it numbers them (pelvis-up or chest-down -- this differs
-- between models, especially SFM/HWM ports), the chest is definitionally
-- where the left and right arm chains join. Picking the wrong spine bone
-- by name instead puts the "chest" target down near the hips, which
-- collapses the whole upper body toward the pelvis when converted.
local function FindChestBoneName(ent, leftArmBone, rightArmBone)
    if not leftArmBone or not rightArmBone or leftArmBone < 0 or rightArmBone < 0 then return nil end
    local rightAncestors, seenRight = {}, {}
    local b = rightArmBone
    while b and b >= 0 and not seenRight[b] do
        seenRight[b] = true
        rightAncestors[b] = true
        b = ent:GetBoneParent(b)
    end
    local bone, seenLeft = leftArmBone, {}
    while bone and bone >= 0 and not seenLeft[bone] do
        seenLeft[bone] = true
        if rightAncestors[bone] then
            -- Walk up from the shared ancestor until one has its own
            -- physics body (the shared bone itself might be a decorative
            -- collarbone-chain root with no independent physics object).
            local search, seenUp = bone, {}
            while search and search >= 0 and not seenUp[search] do
                seenUp[search] = true
                if ResolveExactPhysicsIndex(ent, search) >= 0 then
                    return ent:GetBoneName(search)
                end
                search = ent:GetBoneParent(search)
            end
            return nil
        end
        bone = ent:GetBoneParent(bone)
    end
    return nil
end

-- Finds a collarbone physics body sitting between the chest and a shoulder,
-- if the model has one as its own separate physics object (common on HWM
-- rigs; stock ValveBiped has no such bone). Our 15 Kinect roles don't cover
-- it, so left alone it gets no position/angle target at all -- just passive
-- constraints to its neighbors. If the chest and shoulder targets imply a
-- distance the collarbone's fixed length can't satisfy, the ragdoll solver
-- has nothing valid to settle into and fights itself (seen as the ragdoll
-- launching, curling or jittering instead of posing). SetBuilder drives it
-- explicitly instead, as a blend between the chest and shoulder targets.
local function FindCollarPhysics(ent, shoulderPhys, chestPhys)
    if not ent or not IsValid(ent) or not shoulderPhys or shoulderPhys < 0 then return nil end
    local shoulderBone = ent:TranslatePhysBoneToBone(shoulderPhys)
    if not shoulderBone or shoulderBone < 0 then return nil end
    local bone, seen, steps = ent:GetBoneParent(shoulderBone), {}, 0
    while bone and bone >= 0 and not seen[bone] and steps < 64 do
        seen[bone] = true
        steps = steps + 1
        local phys = ResolveExactPhysicsIndex(ent, bone)
        if phys and phys >= 0 then
            if phys == chestPhys then return nil end -- nothing physical in between
            return phys
        end
        bone = ent:GetBoneParent(bone)
    end
    return nil
end

local function ResolveAnatomicalPhysics(ent, verbose)
    if not IsValid(ent) or not ent:IsRagdoll() then return nil, "Not a ragdoll" end
    local result, names, used = {}, {}, {}

    local function resolveByName(role)
        for _, candidate in ipairs(ROLE_CANDIDATES[role]) do
            local idx = GetBoneIndexByName(ent, candidate)
            if idx >= 0 then
                local phys = ResolveExactPhysicsIndex(ent, idx)
                local obj = phys and phys >= 0 and ent:GetPhysicsObjectNum(phys) or nil
                if obj and obj:IsValid() and not used[phys] then
                    return phys, candidate, idx
                end
            end
        end
        return nil
    end

    -- Resolve the shoulders first so the chest role below can be found by
    -- anatomy (shared ancestor of both arms) instead of by bone name.
    local leftArmPhys, leftArmName, leftArmBone = resolveByName("ValveBiped.Bip01_L_UpperArm")
    local rightArmPhys, rightArmName, rightArmBone = resolveByName("ValveBiped.Bip01_R_UpperArm")

    for _, role in ipairs(ROLE_ORDER) do
        local selected, selectedName, modelBone
        local reason = "No matching animation bone"

        if role == "ValveBiped.Bip01_L_UpperArm" then
            selected, selectedName, modelBone = leftArmPhys, leftArmName, leftArmBone
        elseif role == "ValveBiped.Bip01_R_UpperArm" then
            selected, selectedName, modelBone = rightArmPhys, rightArmName, rightArmBone
        elseif role == "ValveBiped.Bip01_Spine4" then
            local chestName = FindChestBoneName(ent, leftArmBone, rightArmBone)
            if chestName then
                local idx = GetBoneIndexByName(ent, chestName)
                local phys = idx >= 0 and ResolveExactPhysicsIndex(ent, idx) or -1
                if phys >= 0 and not used[phys] and IsValid(ent:GetPhysicsObjectNum(phys)) then
                    selected, selectedName, modelBone = phys, chestName, idx
                end
            end
            if not selected then
                selected, selectedName, modelBone = resolveByName(role)
                if not selected then reason = "Could not find a chest bone (common ancestor of both arms) with its own physics body" end
            end
        else
            selected, selectedName, modelBone = resolveByName(role)
        end

        if not selected then
            if verbose then print("[Kinect Skeleton] UNMAPPED:", role, reason) end
            return nil, role .. ": " .. reason
        end
        result[role] = selected
        names[role] = selectedName
        used[selected] = role
        if verbose then print("[Kinect Skeleton]", role, "->", selectedName,
            "model bone", modelBone, "physics bone", selected) end
    end
    return result, nil, names
end

local function PrintModelDiagnostic(ent)
    if not IsValid(ent) then print("[Kinect Skeleton] Aim at a ragdoll first") return end
    print("[Kinect Skeleton] DIAGNOSTIC", ent:GetModel(), "physics objects", ent:GetPhysicsObjectCount())
    local mapping, err = ResolveAnatomicalPhysics(ent, true)
    print(mapping and "[Kinect Skeleton] All 15 Kinect v1 anatomical roles have unique physics bodies" or
        ("[Kinect Skeleton] Cannot auto-map: " .. (err or "unknown error") .. " -- use manual mapping instead"))
end

if SERVER then
    -- Server owns the authoritative ragdoll physics bodies.
    concommand.Add("kinect_skeleton_diagnose_server", function(player)
        if not IsValid(player) then
            print("[Kinect Skeleton] Run this as a player while aiming at a ragdoll")
            return
        end
        PrintModelDiagnostic(player:GetEyeTrace().Entity)
    end)
else
    concommand.Add("kinect_skeleton_diagnose", function()
        RunConsoleCommand("kinect_skeleton_diagnose_server")
        print("[Kinect Skeleton] Requested server-side physics diagnostic; check server console")
    end)
end

------------------------------------------------------------
-- RIG PROFILES (TF2-style rigs: bip_* bones)
--
-- The generic angle tables above assume the ValveBiped bone axes. TF2 /
-- HWM rigs (bip_pelvis, bip_upperArm_L ...) use different local axes, which
-- is why a generic conversion folds them up. GMod ships per-class builders
-- with per-bone axis corrections, but they only match the exact stock model
-- paths and hard-code stock physics indices. The profiles below reproduce
-- those stock per-class tables, mapped by role onto whatever physics bodies
-- the model actually has, and apply to any model whose class can be detected.
--
-- Override detection with the server convar kinect_converter_profile:
--   auto (default), generic, scout, spy, soldier, heavy, pyro, demo,
--   medic, engineer, sniper
------------------------------------------------------------

if SERVER then CreateConVar("kinect_converter_swap_sides", "0", FCVAR_ARCHIVE, "1 = swap left/right limb roles in Kinect conversions") end

local profileCvar = SERVER and CreateConVar("kinect_converter_profile", "auto", FCVAR_ARCHIVE,
    "Rig profile for Kinect conversion: auto, generic, scout, spy, soldier, heavy, pyro, demo, medic, engineer, sniper") or nil

local PROFILE_FAMILY = {
    scout = "scout", spy = "spy", soldier = "spy",
    heavy = "common", pyro = "common", demo = "common", medic = "common",
    engineer = "engineer", sniper = "engineer",
}

function Kinect_ChooseProfile(ent)
    local forced = profileCvar and string.lower(profileCvar:GetString()) or "auto"
    if forced == "generic" then return nil end
    if PROFILE_FAMILY[forced] then return forced end
    if not ent or not IsValid(ent) then return nil end
    local mdl = string.lower(ent:GetModel() or "")
    local base = string.match(mdl, "([%w_]+)%.mdl$") or ""
    local cls = string.match(base, "^bot_(.+)$") or base
    if cls == "demoman" then cls = "demo" end
    if PROFILE_FAMILY[cls] then return cls end
    -- Unknown model but TF2-style bone names: use the most common TF2 layout.
    if ent:LookupBone("bip_pelvis") and ent:LookupBone("bip_upperArm_L") then return "heavy" end
    return nil
end

function Kinect_ApplyProfile(name, B, R, DriveExtras)
    local family = PROFILE_FAMILY[name]
    if not family then return end
    local PLVS, SPNE, RSLD, LSLD = R.PLVS, R.SPNE, R.RSLD, R.LSLD
    local LARM, LHND, RARM, RHND = R.LARM, R.LHND, R.RARM, R.RHND
    local RTHY, RCLF, LTHY, LCLF = R.RTHY, R.RCLF, R.LTHY, R.LCLF
    local HEAD, LFOT, RFOT = R.HEAD, R.LFOT, R.RFOT
    local S = SENSORBONE

    B.PrePosition = function(self, sensor)
        if not sensor then return end
        local spinestretch = (sensor[S.SHOULDER] - sensor[S.SPINE]) * 0.5
        local acrossshoulders = (sensor[S.SHOULDER_RIGHT] - sensor[S.SHOULDER_LEFT]):GetNormal() * 0.08
        sensor[S.SHOULDER]:Add(spinestretch * 0.7)
        sensor[S.SHOULDER_RIGHT]:Add(spinestretch + acrossshoulders)
        sensor[S.SHOULDER_LEFT]:Add(spinestretch - acrossshoulders)
        sensor[S.ELBOW_LEFT]:Add(spinestretch - acrossshoulders)
        sensor[S.ELBOW_RIGHT]:Add(spinestretch + acrossshoulders)
        sensor[S.WRIST_LEFT]:Add(spinestretch - acrossshoulders)
        sensor[S.WRIST_RIGHT]:Add(spinestretch + acrossshoulders)
        sensor[S.HAND_LEFT]:Add(spinestretch - acrossshoulders)
        sensor[S.HAND_RIGHT]:Add(spinestretch + acrossshoulders)
        sensor[S.HEAD]:Add(spinestretch * 0.9)
        local acrosships = (sensor[S.HIP_LEFT] - sensor[S.HIP_RIGHT]):GetNormal() * 0.06
        sensor[S.HIP_LEFT]:Add(spinestretch * -0.1 + acrosships)
        sensor[S.HIP_RIGHT]:Add(spinestretch * -0.1 + acrosships * -1)
        sensor[S.KNEE_LEFT]:Add((sensor[S.KNEE_LEFT] - sensor[S.HIP_LEFT]) * 0.3 + acrosships)
        sensor[S.KNEE_RIGHT]:Add((sensor[S.KNEE_RIGHT] - sensor[S.HIP_RIGHT]) * 0.3 - acrosships)
        sensor[S.FOOT_LEFT]:Add((sensor[S.ANKLE_LEFT] - sensor[S.KNEE_LEFT]) * 1.2 + acrosships)
        sensor[S.FOOT_RIGHT]:Add((sensor[S.ANKLE_RIGHT] - sensor[S.KNEE_RIGHT]) * 1.2 - acrosships)
        sensor[S.ANKLE_LEFT]:Add((sensor[S.ANKLE_LEFT] - sensor[S.KNEE_LEFT]) * 1.2 + acrosships)
        sensor[S.ANKLE_RIGHT]:Add((sensor[S.ANKLE_RIGHT] - sensor[S.KNEE_RIGHT]) * 1.2 - acrosships)
    end

    B.PositionTable = {
        [PLVS] = S.HIP,
        [RSLD] = S.SHOULDER_RIGHT, [LSLD] = S.SHOULDER_LEFT,
        [LARM] = S.ELBOW_LEFT, [LHND] = S.WRIST_LEFT,
        [RARM] = S.ELBOW_RIGHT, [RHND] = S.WRIST_RIGHT,
        [LTHY] = S.HIP_LEFT, [RTHY] = S.HIP_RIGHT,
        [RCLF] = S.KNEE_RIGHT, [LCLF] = S.KNEE_LEFT,
        [RFOT] = S.ANKLE_RIGHT, [LFOT] = S.ANKLE_LEFT,
        [HEAD] = S.HEAD,
        [SPNE] = { type = "lerp", value = 0.8, from = S.SHOULDER, to = S.SPINE },
    }

    -- Shared torso/head rows (stock TF2).
    local A = {
        [PLVS] = { from = PLVS, to = SPNE, up = "hips_back" },
        [SPNE] = { from = PLVS, to = SPNE, up = "chest_bck" },
        [HEAD] = { from = SPNE, to = HEAD, up = "head_back" },
        [RSLD] = { from = RARM, to = RSLD, up_rgt = SPNE },
        [RARM] = { from = RHND, to = RARM, up_rgt = RSLD },
        [RHND] = { from_sensor = S.HAND_RIGHT, to_sensor = S.WRIST_RIGHT, up_fwd = RARM },
        [LSLD] = { from = LARM, to = LSLD, up_lft = SPNE },
        [LARM] = { from = LHND, to = LARM, up_up = LSLD },
        [LHND] = { from_sensor = S.WRIST_LEFT, to_sensor = S.HAND_LEFT, up_up = LARM },
    }

    local function FeetFromCalves(ang, r, l)
        if ang[RCLF] then ang[RFOT] = ang[RCLF]:Right():AngleEx(ang[RCLF]:Up()) + r end
        if ang[LCLF] then ang[LFOT] = ang[LCLF]:Right():AngleEx(ang[LCLF]:Up()) + l end
    end
    local function Rot(ang, k, axis, deg)
        if ang[k] then ang[k]:RotateAroundAxis(ang[k][axis](ang[k]), deg) end
    end

    if family == "scout" then
        A[LSLD] = { from = LARM, to = LSLD, up_dn = SPNE }
        A[RTHY] = { from = RCLF, to = RTHY, up = "right" }
        A[RCLF] = { from = RFOT, to = RCLF, up_up = RTHY }
        A[LTHY] = { from = LCLF, to = LTHY, up = "forward" }
        A[LCLF] = { from = LFOT, to = LCLF, up_up = LTHY }
    elseif family == "spy" then
        -- Stock spy/soldier drive a TRSO body we may not have; SPNE stands in.
        A[RARM] = { from = RHND, to = RARM, up_up = RSLD }
        A[RHND] = { from_sensor = S.HAND_RIGHT, to_sensor = S.WRIST_RIGHT, up_dn = RARM }
        A[RTHY] = { from = RCLF, to = RTHY, up = "right" }
        A[RCLF] = { from = RFOT, to = RCLF, up_up = RTHY }
        A[LTHY] = { from = LCLF, to = LTHY, up = "forward" }
        A[LCLF] = { from = LFOT, to = LCLF, up_up = LTHY }
    elseif family == "engineer" then
        A[RTHY] = { from = RCLF, to = RTHY, up_dn = PLVS }
        A[RCLF] = { from = RFOT, to = RCLF, up_up = RTHY }
        A[RFOT] = { from = RCLF, to = RFOT, up_up = RTHY }
        A[LTHY] = { from = LCLF, to = LTHY, up_dn = PLVS }
        A[LCLF] = { from = LFOT, to = LCLF, up_up = LTHY }
        A[LFOT] = { from = LFOT, to = LCLF, up_up = LTHY }
        if name == "sniper" then A[RCLF] = { from = RFOT, to = RCLF, up_lft = RTHY } end
        A[RFOT].from, A[RFOT].to = RCLF, RFOT
    else -- common: heavy / pyro / demo / medic
        A[RTHY] = { from = RCLF, to = RTHY, up = "right" }
        A[RCLF] = { from = RFOT, to = RCLF, up_up = RTHY }
        A[LTHY] = { from = LCLF, to = LTHY, up = "forward" }
        A[LCLF] = { from = LFOT, to = LCLF, up_up = LTHY }
    end
    B.AnglesTable = A

    B.Complete = function(self, player, sensor, rotation, pos, ang)
        if not pos or not ang then return end

        if family == "scout" or family == "common" then
            FeetFromCalves(ang, Angle(0, 180, -40), Angle(0, -90, 130))
        elseif family == "spy" then
            FeetFromCalves(ang, Angle(0, 90, -70), Angle(0, -90, 110))
        else
            Rot(ang, RFOT, "Up", -90); Rot(ang, RFOT, "Forward", 180)
            Rot(ang, LFOT, "Up", 90);  Rot(ang, LFOT, "Forward", -45)
            if ang[LFOT] and ang[RFOT] then ang[RFOT]:RotateAroundAxis(ang[LFOT]:Forward(), -45) end
        end

        Rot(ang, PLVS, "Up", -90)
        Rot(ang, SPNE, "Up", -90)
        Rot(ang, HEAD, "Up", -90)

        -- Hands copy the forearm orientation (stock TF2 behavior).
        if ang[LARM] then
            ang[LHND] = ang[LARM] * 1
            Rot(ang, LHND, "Up", 90)
        end
        if ang[RARM] then
            ang[RHND] = ang[RARM] * 1
            Rot(ang, RHND, "Up", -90)
            Rot(ang, RHND, "Right", 180)
        end

        DriveExtras(pos, ang)
    end
end

------------------------------------------------------------
-- REST-POSE CALIBRATION
--
-- Instead of trusting any rig's bone-axis conventions, this records, at
-- Apply time, how each physics body is rotated relative to a frame built
-- purely from joint positions (limb direction + a torso-derived roll hint).
-- At runtime the same frame is built from the Kinect joints and the recorded
-- offset is applied on top. It works for any rig because the rig's own axis
-- layout is measured, not assumed. Requires the ragdoll to be in a normal
-- upright pose when Apply is pressed.
--
-- kinect_converter_calibrate (server convar): arms (default), all, off
------------------------------------------------------------

local calibCvar = SERVER and CreateConVar("kinect_converter_calibrate", "arms", FCVAR_ARCHIVE,
    "Rest-pose calibration for Kinect conversion: arms, all, off") or nil

local CAL_ARMS = { "RSLD", "LSLD", "RARM", "LARM", "RHND", "LHND" }
local CAL_REST = { "PLVS", "SPNE", "HEAD", "RTHY", "LTHY", "RCLF", "LCLF", "RFOT", "LFOT" }
local CAL_ROLES = { "PLVS", "SPNE", "HEAD", "RSLD", "LSLD", "RARM", "LARM", "RHND", "LHND",
                    "RTHY", "LTHY", "RCLF", "LCLF", "RFOT", "LFOT" }

local function CalFrame(f, h, alt)
    if f:LengthSqr() < 1e-10 then return nil end
    f = f:GetNormalized()
    local u = h - f * f:Dot(h)
    if u:LengthSqr() < 0.04 then u = alt - f * f:Dot(alt) end
    if u:LengthSqr() < 1e-10 then return nil end
    return f:AngleEx(u:GetNormalized())
end

-- P: role name -> position. Returns role name -> frame angle, or nil.
local function CalFrames(P)
    for _, k in ipairs(CAL_ROLES) do if not P[k] then return nil end end
    local mid = (P.RSLD + P.LSLD) * 0.5
    local upT = mid - P.PLVS
    if upT:LengthSqr() < 1e-10 then return nil end
    upT = upT:GetNormalized()
    local across = P.RSLD - P.LSLD
    across = across - upT * across:Dot(upT)
    if across:LengthSqr() < 1e-10 then return nil end
    across = across:GetNormalized()
    local back = across:Cross(upT):GetNormalized()

    local out = {}
    out.PLVS = CalFrame(upT, back, across)
    out.SPNE = out.PLVS
    out.HEAD = CalFrame(P.HEAD - mid, back, across)
    out.RSLD = CalFrame(P.RARM - P.RSLD, back, upT)
    out.LSLD = CalFrame(P.LARM - P.LSLD, back, upT)
    out.RARM = CalFrame(P.RHND - P.RARM, back, upT)
    out.LARM = CalFrame(P.LHND - P.LARM, back, upT)
    out.RHND, out.LHND = out.RARM, out.LARM
    out.RTHY = CalFrame(P.RCLF - P.RTHY, across, back)
    out.LTHY = CalFrame(P.LCLF - P.LTHY, across, back)
    out.RCLF = CalFrame(P.RFOT - P.RCLF, across, back)
    out.LCLF = CalFrame(P.LFOT - P.LCLF, across, back)
    out.RFOT, out.LFOT = out.RCLF, out.LCLF
    for _, k in ipairs(CAL_ROLES) do if not out[k] then return nil end end
    return out, upT
end

-- Returns true if calibration was installed on Builder.
function Kinect_ApplyCalibration(B, R, ent, mode, DriveExtras)
    if mode ~= "arms" and mode ~= "all" then return false end
    if not ent or not IsValid(ent) then return false end

    local restP, restA = {}, {}
    for _, k in ipairs(CAL_ROLES) do
        local obj = ent:GetPhysicsObjectNum(R[k])
        if not obj or not IsValid(obj) then
            print("[Kinect Skeleton] Calibration skipped: missing physics body for", k)
            return false
        end
        local stored = ent.KinectFrozen and ent.KinectRestPose and ent.KinectRestPose[R[k]]
        if stored then
            restP[k], restA[k] = stored.pos, stored.ang
        else
            restP[k], restA[k] = obj:GetPos(), obj:GetAngles()
        end
    end
    local frames, upT = CalFrames(restP)
    if not frames then
        print("[Kinect Skeleton] Calibration skipped: rest pose is degenerate (bodies overlap?)")
        return false
    end
    if upT.z < 0.7 then
        print("[Kinect Skeleton] WARNING: the ragdoll is not upright right now (torso tilt too large). " ..
              "Reset the ragdoll to a standing pose and press Apply again, or the calibration will be wrong.")
    end

    local offset = {}
    for _, k in ipairs(CAL_ROLES) do
        local _, la = WorldToLocal(vector_origin, restA[k], vector_origin, frames[k])
        offset[k] = la
    end

    local set = {}
    for _, k in ipairs(CAL_ARMS) do set[#set + 1] = k end
    if mode == "all" then for _, k in ipairs(CAL_REST) do set[#set + 1] = k end end

    -- Drop the table rows we are replacing so they are not computed twice.
    for _, k in ipairs(set) do B.AnglesTable[R[k]] = nil end

    local baseComplete = B.Complete
    B.Complete = function(self, player, sensor, rotation, pos, ang)
        if baseComplete then baseComplete(self, player, sensor, rotation, pos, ang) end
        if not pos or not ang then return end
        local P = {}
        for _, k in ipairs(CAL_ROLES) do P[k] = pos[R[k]] end
        local live = CalFrames(P)
        if not live then return end
        for _, k in ipairs(set) do
            local _, a = LocalToWorld(vector_origin, offset[k], vector_origin, live[k])
            ang[R[k]] = a
        end
        DriveExtras(pos, ang)
    end
    return true
end

------------------------------------------------------------
-- BUILDER REGISTRATION
--
-- Registers a Kinect "SkeletonConvertor" (motionsensor builder) for a given
-- model, using the physics-bone mapping in `tbl` (role name -> physics index,
-- as produced by ResolveAnatomicalPhysics or the manual editor below).
--
-- One builder is registered per model name, keyed only by model -- applying
-- a new mapping on the same model replaces the previous builder outright
-- instead of leaving two "_fixed"/"_normal" variants both claiming to be
-- applicable (which made the engine's builder choice arbitrary).
------------------------------------------------------------

function SetBuilder(tbl, mdl, fixed, ent, swap)

    if not tbl then
        print("[Kinect Skeleton] ERROR: Bone table is missing.")
        return
    end

    if not mdl then
        print("[Kinect Skeleton] ERROR: Model is missing.")
        return
    end

    -- Swap left/right: exchange every paired limb role, so the Kinect's left
    -- side drives the model's right-side bodies and vice versa. Also forced
    -- by the server convar kinect_converter_swap_sides.
    local swapCvar = GetConVar("kinect_converter_swap_sides")
    if swap or (swapCvar and swapCvar:GetBool()) then
        local copy = table.Copy(tbl)
        for _, part in ipairs({ "UpperArm", "Forearm", "Hand", "Thigh", "Calf", "Foot" }) do
            local l, r = "ValveBiped.Bip01_L_" .. part, "ValveBiped.Bip01_R_" .. part
            copy[l], copy[r] = tbl[r], tbl[l]
        end
        tbl = copy
        print("[Kinect Skeleton] Left/right swapped for this conversion")
    end

    --------------------------------------------------------
    -- PHYSICS BONE INDICES (per role, resolved already)
    --------------------------------------------------------

    local PLVS = tbl['ValveBiped.Bip01_Pelvis']
    local SPNE = tbl['ValveBiped.Bip01_Spine4']

    local RSLD = tbl['ValveBiped.Bip01_R_UpperArm']
    local LSLD = tbl['ValveBiped.Bip01_L_UpperArm']

    local LARM = tbl['ValveBiped.Bip01_L_Forearm']
    local LHND = tbl['ValveBiped.Bip01_L_Hand']

    local RARM = tbl['ValveBiped.Bip01_R_Forearm']
    local RHND = tbl['ValveBiped.Bip01_R_Hand']

    local RTHY = tbl['ValveBiped.Bip01_R_Thigh']
    local RCLF = tbl['ValveBiped.Bip01_R_Calf']

    local HEAD = tbl['ValveBiped.Bip01_Head1']

    local LTHY = tbl['ValveBiped.Bip01_L_Thigh']
    local LCLF = tbl['ValveBiped.Bip01_L_Calf']

    local LFOT = tbl['ValveBiped.Bip01_L_Foot']
    local RFOT = tbl['ValveBiped.Bip01_R_Foot']

    --------------------------------------------------------
    -- VERIFY
    --------------------------------------------------------

    local requiredBones = {
        PLVS = PLVS, SPNE = SPNE, RSLD = RSLD, LSLD = LSLD,
        LARM = LARM, LHND = LHND, RARM = RARM, RHND = RHND,
        RTHY = RTHY, RCLF = RCLF, HEAD = HEAD, LTHY = LTHY,
        LCLF = LCLF, LFOT = LFOT, RFOT = RFOT
    }

    for name, index in pairs(requiredBones) do
        if index == nil or index < 0 then
            print("[Kinect Skeleton] ERROR: Invalid physics bone:", name, index)
            return
        end
    end

    -- Detect separate collarbone physics bodies (common on HWM rigs, absent
    -- on stock ValveBiped) between the chest and each shoulder, so they get a
    -- target instead of being left passive. ent is only used here, once, at
    -- registration time.
    local LCOLLAR = ent and FindCollarPhysics(ent, LSLD, SPNE) or nil
    local RCOLLAR = ent and FindCollarPhysics(ent, RSLD, SPNE) or nil
    if LCOLLAR then print("[Kinect Skeleton] Found left collarbone physics body:", LCOLLAR, "-- will be driven as a chest/shoulder blend") end
    if RCOLLAR then print("[Kinect Skeleton] Found right collarbone physics body:", RCOLLAR, "-- will be driven as a chest/shoulder blend") end

    -- Every other physics body that isn't one of the 15 roles (coat panels,
    -- dogtags, spine_2, ...) would otherwise get no target. Each one is
    -- attached to its nearest driven ancestor bone: we record where it sits
    -- relative to that ancestor's physics object right now, and in Complete()
    -- re-apply the same relative placement to the ancestor's target.
    local extras = {}
    if ent and IsValid(ent) then
        local isRole = {}
        for _, v in pairs(tbl) do isRole[v] = true end
        local driven = {}
        for _, v in pairs(tbl) do driven[v] = true end
        if LCOLLAR then driven[LCOLLAR] = true end
        if RCOLLAR then driven[RCOLLAR] = true end
        local pending = {}
        for i = 0, ent:GetPhysicsObjectCount() - 1 do
            if not driven[i] and IsValid(ent:GetPhysicsObjectNum(i)) then pending[#pending + 1] = i end
        end
        local progress = true
        while #pending > 0 and progress do
            progress = false
            for n = #pending, 1, -1 do
                local i = pending[n]
                local bone = ent:TranslatePhysBoneToBone(i)
                local anchor, guard = nil, 0
                bone = bone and ent:GetBoneParent(bone) or -1
                while bone and bone >= 0 and guard < 64 do
                    guard = guard + 1
                    local ph = ResolveExactPhysicsIndex(ent, bone)
                    if ph and ph >= 0 and driven[ph] then anchor = ph break end
                    bone = ent:GetBoneParent(bone)
                end
                if anchor then
                    local ao, eo = ent:GetPhysicsObjectNum(anchor), ent:GetPhysicsObjectNum(i)
                    local lp, la = WorldToLocal(eo:GetPos(), eo:GetAngles(), ao:GetPos(), ao:GetAngles())
                    extras[#extras + 1] = { idx = i, anchor = anchor, lp = lp, la = la }
                    driven[i] = true
                    table.remove(pending, n)
                    progress = true
                end
            end
        end
        if #extras > 0 then print("[Kinect Skeleton] Extra physics bodies attached to their parent bones:", #extras) end
        if #pending > 0 then print("[Kinect Skeleton] Extra physics bodies left passive (no driven ancestor):", #pending) end
    end

    local SENSOR_SCALE = 36 -- ragdoll_motion default Scale; sensor units -> world units

    local function DriveExtras(pos, ang)
        if LCOLLAR and pos[SPNE] and pos[LSLD] and ang[SPNE] and ang[LSLD] then
            pos[LCOLLAR] = LerpVector(0.5, pos[SPNE], pos[LSLD])
            ang[LCOLLAR] = LerpAngle(0.5, ang[SPNE], ang[LSLD])
        end
        if RCOLLAR and pos[SPNE] and pos[RSLD] and ang[SPNE] and ang[RSLD] then
            pos[RCOLLAR] = LerpVector(0.5, pos[SPNE], pos[RSLD])
            ang[RCOLLAR] = LerpAngle(0.5, ang[SPNE], ang[RSLD])
        end
        for _, e in ipairs(extras) do
            if pos[e.anchor] and ang[e.anchor] then
                local p, a = LocalToWorld(e.lp / SENSOR_SCALE, e.la, pos[e.anchor], ang[e.anchor])
                pos[e.idx] = p
                ang[e.idx] = a
            end
        end
    end

    -- Rig profile (see TF2 profiles below). Chosen once, at registration.
    local profileName = Kinect_ChooseProfile and Kinect_ChooseProfile(ent) or nil

    --------------------------------------------------------
    -- BUILDER
    --------------------------------------------------------

    local Builder = {

        -- Nudges the sensor's shoulder/arm/head/hip joints outward from the
        -- spine before the table-driven solve below, so a stretched-out
        -- Kinect skeleton doesn't compress the model's torso. Standard
        -- Kinect-v1 Source-engine adjustment.
        PrePosition = function(self, sensor)
            if not sensor then return end

            local spinestretch = (sensor[SENSORBONE.SHOULDER] - sensor[SENSORBONE.SPINE]) * 0.7

            sensor[SENSORBONE.SHOULDER]:Add(spinestretch * 0.7)
            sensor[SENSORBONE.SHOULDER_RIGHT]:Add(spinestretch)
            sensor[SENSORBONE.SHOULDER_LEFT]:Add(spinestretch)
            sensor[SENSORBONE.ELBOW_LEFT]:Add(spinestretch)
            sensor[SENSORBONE.ELBOW_RIGHT]:Add(spinestretch)
            sensor[SENSORBONE.WRIST_LEFT]:Add(spinestretch)
            sensor[SENSORBONE.WRIST_RIGHT]:Add(spinestretch)
            sensor[SENSORBONE.HAND_LEFT]:Add(spinestretch)
            sensor[SENSORBONE.HAND_RIGHT]:Add(spinestretch)
            sensor[SENSORBONE.HEAD]:Add(spinestretch * 0.5)
            sensor[SENSORBONE.HIP_LEFT]:Add(spinestretch * 0.3)
            sensor[SENSORBONE.HIP_RIGHT]:Add(spinestretch * 0.3)

            sensor[SENSORBONE.KNEE_RIGHT]:Add(
                (sensor[SENSORBONE.HIP_RIGHT] - sensor[SENSORBONE.KNEE_RIGHT]) * 0.2
            )
            sensor[SENSORBONE.KNEE_LEFT]:Add(
                (sensor[SENSORBONE.HIP_LEFT] - sensor[SENSORBONE.KNEE_LEFT]) * 0.2
            )
        end,

        -- Which sensor joint drives each physics bone's position.
        PositionTable = {
            [PLVS] = SENSORBONE.HIP,

            [RSLD] = SENSORBONE.SHOULDER_RIGHT,
            [LSLD] = SENSORBONE.SHOULDER_LEFT,

            [LARM] = SENSORBONE.ELBOW_LEFT,
            [LHND] = SENSORBONE.WRIST_LEFT,

            [RARM] = SENSORBONE.ELBOW_RIGHT,
            [RHND] = SENSORBONE.WRIST_RIGHT,

            [LTHY] = SENSORBONE.HIP_LEFT,
            [RTHY] = SENSORBONE.HIP_RIGHT,

            [RCLF] = SENSORBONE.KNEE_RIGHT,
            [LCLF] = SENSORBONE.KNEE_LEFT,

            [RFOT] = SENSORBONE.ANKLE_RIGHT,
            [LFOT] = SENSORBONE.ANKLE_LEFT,

            [HEAD] = SENSORBONE.HEAD,

            [SPNE] = SENSORBONE.SPINE
        },

        -- Which sensor joint pair (or physics bone pair) orients each bone,
        -- and which direction counts as "up" for that bone's basis.
        AnglesTable = {
            [PLVS] = { from = LTHY, to = RTHY, up = 'hips_fwd' },

            [SPNE] = { from_sensor = SENSORBONE.HEAD, to_sensor = SENSORBONE.SPINE, up = 'chest_rgt' },
            [HEAD] = { from_sensor = SENSORBONE.HEAD, to_sensor = SENSORBONE.SHOULDER, up = 'chest_lft' },

            [RSLD] = { from = RARM, to = RSLD, up = 'chest_up' },
            [LSLD] = { from = LARM, to = LSLD, up = 'chest_dn' },

            [RARM] = { from = RHND, to = RARM, up_up = RSLD },
            [LARM] = { from = LHND, to = LARM, up_up = LSLD },

            [RTHY] = { from = RCLF, to = RTHY, up_up = SPNE },
            [RCLF] = { from = RFOT, to = RCLF, up_up = RTHY },

            [LTHY] = { from = LCLF, to = LTHY, up_up = SPNE },
            [LCLF] = { from = LFOT, to = LCLF, up_up = LTHY },

            [RHND] = { from_sensor = SENSORBONE.HAND_RIGHT, to_sensor = SENSORBONE.WRIST_RIGHT, up_lft = RARM },
            [LHND] = { from_sensor = SENSORBONE.HAND_LEFT, to_sensor = SENSORBONE.WRIST_LEFT, up_rgt = LARM }
        },

        -- Small cleanup pass after the engine has solved pos/ang from the
        -- tables above. This intentionally does NOT touch anything the
        -- solver already computed correctly.
        Complete = function(self, player, sensor, rotation, pos, ang)
            if not pos or not ang then return end

            -- Curve the torso slightly toward the head instead of a rigid line.
            if pos[SPNE] and pos[HEAD] then
                pos[SPNE] = LerpVector(0.45, pos[SPNE], pos[HEAD])
            end

            -- Keep the feet flat under the calves rather than at whatever
            -- angle the raw Kinect ankle/foot data implies.
            if ang[LCLF] then
                ang[LFOT] = ang[LCLF]:Right():AngleEx(ang[LCLF]:Up()) + Angle(20, 0, 0)
            end
            if ang[RCLF] then
                ang[RFOT] = ang[RCLF]:Right():AngleEx(ang[RCLF]:Up()) + Angle(20, 0, 0)
            end

            DriveExtras(pos, ang)
        end,

        IsApplicable = function(self, ent)
            if not IsValid(ent) then return false end
            local model = ent:GetModel()
            if not model then return false end
            return string.EndsWith(model, mdl)
        end
    }

    if profileName and Kinect_ApplyProfile then
        Kinect_ApplyProfile(profileName, Builder, {
            PLVS = PLVS, SPNE = SPNE, RSLD = RSLD, LSLD = LSLD, LARM = LARM, LHND = LHND,
            RARM = RARM, RHND = RHND, RTHY = RTHY, RCLF = RCLF, HEAD = HEAD,
            LTHY = LTHY, LCLF = LCLF, LFOT = LFOT, RFOT = RFOT,
        }, DriveExtras)
        print("[Kinect Skeleton] Using rig profile:", profileName)
    end

    do
        local mode = calibCvar and string.lower(calibCvar:GetString()) or "arms"
        if Kinect_ApplyCalibration(Builder, {
            PLVS = PLVS, SPNE = SPNE, RSLD = RSLD, LSLD = LSLD, LARM = LARM, LHND = LHND,
            RARM = RARM, RHND = RHND, RTHY = RTHY, RCLF = RCLF, HEAD = HEAD,
            LTHY = LTHY, LCLF = LCLF, LFOT = LFOT, RFOT = RFOT,
        }, ent, mode, DriveExtras) then
            print("[Kinect Skeleton] Rest-pose calibration active for:", mode)
        end
    end

    --------------------------------------------------------
    -- FIXED HAND MODE (wrists copy the forearm angle instead of tracking
    -- the Kinect's hand joints, for when hand tracking is too jittery)
    --------------------------------------------------------

    if fixed then
        Builder.AnglesTable[RHND] = Builder.AnglesTable[RARM]
        Builder.AnglesTable[LHND] = Builder.AnglesTable[LARM]
    end

    --------------------------------------------------------
    -- REGISTER (one builder per model; re-applying replaces it)
    --------------------------------------------------------

    local name = "AnatomicalKinect_" .. mdl

    list.Set("SkeletonConvertor", name, Builder)

    print("[Kinect Skeleton] Registered:", name, fixed and "(fixed-hand mode)" or "")
end


------------------------------------------------------------
-- VISUAL BONE MAPPING EDITOR
-- Right-click a ragdoll -> Convert Skeleton. Automatic mode auto-detects
-- bones by anatomy; Manual mode lets you click bones in a 3D preview (or
-- pick from a dropdown) to assign each of the 15 Kinect roles yourself.
------------------------------------------------------------

local EDIT_APPLY = "KinectEditor_Apply_v1"
local EDIT_RESULT = "KinectEditor_Result_v1"
local EDIT_VALIDATE_BONE = "KinectEditor_ValidateBone_v1"
local EDIT_VALIDATE_REPLY = "KinectEditor_ValidateBoneReply_v1"
local EDIT_POSE = "KinectEditor_Pose_v1"
local EDIT_TESTRIG = "KinectEditor_TestRig_v1"
local EDIT_DANCE = "KinectEditor_Dance_v1"
local EDIT_DANCE_REPLY = "KinectEditor_DanceReply_v1"
local EDIT_DIAG = "KinectEditor_Diagnose_v1"
local EDIT_DIAG_REPLY = "KinectEditor_DiagReply_v1"

local LABELS = {
    "Pelvis", "Spine / Chest", "Head", "Left shoulder", "Right shoulder",
    "Left elbow", "Right elbow", "Left wrist", "Right wrist",
    "Left hip", "Right hip", "Left knee", "Right knee", "Left ankle", "Right ankle"
}

local JOINT_POINTS = {
    {0.50,0.59},{0.50,0.36},{0.50,0.13},
    {0.35,0.39},{0.65,0.39},{0.22,0.48},{0.78,0.48},
    {0.13,0.58},{0.87,0.58},{0.42,0.62},{0.58,0.62},
    {0.39,0.79},{0.61,0.79},{0.37,0.94},{0.63,0.94}
}
local JOINT_EDGES = {
    {1,2},{2,3},{2,4},{2,5},{4,6},{5,7},{6,8},{7,9},
    {1,10},{1,11},{10,12},{11,13},{12,14},{13,15}
}

local openEditor -- shared upvalue for the right-click Action callback

if SERVER then
    util.AddNetworkString(EDIT_APPLY)
    util.AddNetworkString(EDIT_RESULT)
    util.AddNetworkString(EDIT_VALIDATE_BONE)
    util.AddNetworkString(EDIT_VALIDATE_REPLY)
    util.AddNetworkString(EDIT_POSE)
    util.AddNetworkString(EDIT_TESTRIG)
    util.AddNetworkString(EDIT_DANCE)
    util.AddNetworkString(EDIT_DANCE_REPLY)
    util.AddNetworkString(EDIT_DIAG)
    util.AddNetworkString(EDIT_DIAG_REPLY)

    -- Read-only report: current mapping, physics hierarchy, which builder
    -- the engine would currently pick for this entity. Changes nothing.
    local function diagnostics(ply, ent, names)
        local out = {}
        local function add(...)
            local t = {}
            for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
            out[#out + 1] = table.concat(t, " ")
        end
        add("KINECT MAPPING / PHYSICS DIAGNOSTIC")
        add("Model:", ent:GetModel(), " entity:", ent:EntIndex())
        add("Physics bodies:", ent:GetPhysicsObjectCount(), " animation bones:", ent:GetBoneCount())
        add("Registered by Apply Conversion:", ent.KinectEditorLastBuilder or "NOT RECORDED - apply conversion first")
        if motionsensor and motionsensor.ChooseBuilderFromEntity then
            local ok, chosen = pcall(motionsensor.ChooseBuilderFromEntity, ent)
            if ok then
                add("Current ChooseBuilderFromEntity selection:", tostring(chosen))
                if isstring(chosen) then
                    add("Matches our Apply Conversion:", tostring(chosen == ent.KinectEditorLastBuilder))
                end
            else
                add("Builder selection call failed:", tostring(chosen))
            end
        else
            add("ChooseBuilderFromEntity unavailable on this realm")
        end
        local ctrl = ent.MotionSensorController
        add("Attached Kinect controller:", IsValid(ctrl) and (ctrl:GetClass() .. " #" .. ctrl:EntIndex()) or "none")
        add("-----------------------------------------------")

        -- Resolve every role as given, then correct the chest/spine role by
        -- anatomy -- same as Apply Conversion actually does -- so this
        -- report reflects what gets registered, not just the raw guess.
        local resolvedBone, resolvedPhys = {}, {}
        for i in ipairs(ROLE_ORDER) do
            local bone = GetBoneIndexByName(ent, names[i])
            resolvedBone[i] = bone
            resolvedPhys[i] = ResolveExactPhysicsIndex(ent, bone)
        end
        local spineIdx, leftArmIdx, rightArmIdx
        for i, role in ipairs(ROLE_ORDER) do
            if role == "ValveBiped.Bip01_Spine4" then spineIdx = i end
            if role == "ValveBiped.Bip01_L_UpperArm" then leftArmIdx = i end
            if role == "ValveBiped.Bip01_R_UpperArm" then rightArmIdx = i end
        end
        local correctedNote = ""
        if spineIdx and leftArmIdx and rightArmIdx and
            (resolvedBone[leftArmIdx] or -1) >= 0 and (resolvedBone[rightArmIdx] or -1) >= 0 then
            local chestName = FindChestBoneName(ent, resolvedBone[leftArmIdx], resolvedBone[rightArmIdx])
            if chestName then
                local chestBone = GetBoneIndexByName(ent, chestName)
                local chestPhys = chestBone >= 0 and ResolveExactPhysicsIndex(ent, chestBone) or -1
                if chestPhys >= 0 and IsValid(ent:GetPhysicsObjectNum(chestPhys)) then
                    if chestName ~= names[spineIdx] then
                        correctedNote = "  [Apply Conversion actually uses " .. chestName .. ", resolved by anatomy]"
                    end
                    names[spineIdx] = chestName
                    resolvedBone[spineIdx] = chestBone
                    resolvedPhys[spineIdx] = chestPhys
                end
            end
        end

        local byPhysics = {}
        local failed = 0
        for i, role in ipairs(ROLE_ORDER) do
            local boneName = names[i]
            local bone = resolvedBone[i]
            local phys = resolvedPhys[i]
            local valid = phys >= 0 and IsValid(ent:GetPhysicsObjectNum(phys))
            if not valid then failed = failed + 1 end
            if valid and byPhysics[phys] then failed = failed + 1 end
            if valid then byPhysics[phys] = LABELS[i] end
            add(LABELS[i], "->", boneName, "anim:", bone, "physics:", phys, "valid:", tostring(valid),
                i == spineIdx and correctedNote or "")
        end
        add("Mapping warnings:", failed)
        add("-----------------------------------------------")
        add("PHYSICS BODIES")
        for phys = 0, ent:GetPhysicsObjectCount() - 1 do
            local modelBone = ent:TranslatePhysBoneToBone(phys)
            local name = modelBone >= 0 and ent:GetBoneName(modelBone) or "(none)"
            local obj = ent:GetPhysicsObjectNum(phys)
            local p = IsValid(obj) and obj:GetPos() or nil
            add("PHYS", phys, "modelBone", modelBone, tostring(name),
                "mappedRole", byPhysics[phys] or "(unmapped)",
                "pos", p and tostring(p) or "invalid")
        end
        file.CreateDir("kinect_mapping_editor")
        file.CreateDir("kinect_mapping_editor/diagnostics")
        local filename = "kinect_mapping_editor/diagnostics/" .. string.gsub(ent:GetModel(), "[^%w]", "_") .. "_" .. os.time() .. ".txt"
        file.Write(filename, table.concat(out, "\n"))
        add("Saved: garrysmod/data/" .. filename)
        return table.concat(out, "\n"), filename
    end

    net.Receive(EDIT_DIAG, function(_, ply)
        local ent = net.ReadEntity()
        local count = net.ReadUInt(5)
        if not IsValid(ply) or not IsValid(ent) or not ent:IsRagdoll() then return end
        if ply:GetPos():DistToSqr(ent:GetPos()) > 1500 * 1500 then return end
        if count ~= #ROLE_ORDER then return end
        local names = {}
        for i = 1, count do
            names[i] = net.ReadString()
            if #names[i] > 128 then return end
        end
        local report, filename = diagnostics(ply, ent, names)
        print("[Kinect Diagnostic]", report)
        net.Start(EDIT_DIAG_REPLY)
        net.WriteString(filename)
        net.WriteString(string.sub(report, 1, 60000))
        net.Send(ply)
    end)

    -- Manual mapping validation: resolve the chosen bone (or its nearest
    -- physical ancestor) to a physics body and check it isn't already used
    -- by another role, before accepting it client-side.
    net.Receive(EDIT_VALIDATE_BONE, function(_, ply)
        if not IsValid(ply) then return end
        local ent = net.ReadEntity()
        local role = net.ReadUInt(5)
        local requested = net.ReadString()
        local others = {}
        local count = net.ReadUInt(5)
        for i = 1, math.min(count, #ROLE_ORDER) do others[i] = net.ReadString() end

        local function reply(ok, message, resolved, phys)
            net.Start(EDIT_VALIDATE_REPLY)
            net.WriteUInt(math.Clamp(role, 0, 31), 5)
            net.WriteString(requested)
            net.WriteBool(ok)
            net.WriteString(message)
            net.WriteString(resolved or "")
            net.WriteInt(phys or -1, 16)
            net.Send(ply)
        end

        if not IsValid(ent) or not ent:IsRagdoll() then reply(false, "Selected ragdoll no longer exists") return end
        if ply:GetPos():DistToSqr(ent:GetPos()) > 1500 * 1500 then reply(false, "Move closer to the ragdoll") return end
        if role < 1 or role > #ROLE_ORDER or #requested > 128 or count ~= #ROLE_ORDER then
            reply(false, "Invalid Kinect role or bone request") return
        end

        local bone = GetBoneIndexByName(ent, requested)
        if bone < 0 then reply(false, "Model bone not found: " .. requested) return end

        local chosenPhys, chosenBone = -1, -1
        local seen = {}
        while bone >= 0 and not seen[bone] do
            seen[bone] = true
            local phys = ResolveExactPhysicsIndex(ent, bone)
            if phys >= 0 then
                chosenPhys, chosenBone = phys, bone
                break
            end
            bone = ent:GetBoneParent(bone)
        end
        if chosenPhys < 0 then
            reply(false, "No physics body on this bone or its ancestors; choose another bone") return
        end

        local canonical = ent:GetBoneName(chosenBone)
        if not canonical or canonical == "__INVALIDBONE__" then
            reply(false, "Could not identify the resolved physics bone") return
        end

        for i = 1, #ROLE_ORDER do
            if i ~= role then
                local otherIdx = GetBoneIndexByName(ent, others[i] or "")
                if otherIdx >= 0 and ResolveExactPhysicsIndex(ent, otherIdx) == chosenPhys then
                    reply(false, "Physics body " .. chosenPhys .. " is already mapped to " .. LABELS[i]) return
                end
            end
        end

        local note = requested ~= canonical and
            ("Selected " .. requested .. " has no independent physics body; using " .. canonical .. " instead") or
            ("Mapped " .. requested .. " to physics body " .. chosenPhys)
        reply(true, LABELS[role] .. ": " .. note, canonical, chosenPhys)
    end)

    ------------------------------------------------------------
    -- STAND POSE: when the editor opens, put the ragdoll into the model's
    -- standing animation pose and hold it there, so rest-pose calibration
    -- always sees a clean upright pose. The pose is also stored on the entity
    -- so calibration does not depend on physics settling. Released on Apply
    -- or when the editor closes.
    ------------------------------------------------------------
    local STAND_SEQUENCES = { "ragdoll", "idle_all_01", "reference", "ref", "idle", "idle_all" }

    local function ReleaseRagdoll(ent)
        if not IsValid(ent) then return end
        if ent.KinectFrozen then
            for i = 0, ent:GetPhysicsObjectCount() - 1 do
                local obj = ent:GetPhysicsObjectNum(i)
                if IsValid(obj) then obj:EnableMotion(true) obj:Wake() end
            end
        end
        ent.KinectFrozen = false
    end

    local function StandRagdoll(ent, ply)
        local count = ent:GetPhysicsObjectCount()
        local root = ent:GetPhysicsObjectNum(0)
        if count < 1 or not IsValid(root) then return false end

        local dyn = ents.Create("prop_dynamic")
        if not IsValid(dyn) then return false end
        dyn:SetModel(ent:GetModel())

        local rootPos = root:GetPos()
        local tr = util.TraceLine({ start = rootPos + Vector(0, 0, 64), endpos = rootPos - Vector(0, 0, 4000),
                                    filter = { ent, dyn, ply } })
        local origin = tr.Hit and tr.HitPos or rootPos
        local yaw = IsValid(ply) and (ply:EyeAngles().y + 180) or 0
        dyn:SetPos(origin)
        dyn:SetAngles(Angle(0, yaw, 0))
        dyn:Spawn()
        SafeRemoveEntityDelayed(dyn, 2) -- backstop: never leave the temporary copy behind, even if something errors below

        for _, name in ipairs(STAND_SEQUENCES) do
            local seq = dyn:LookupSequence(name)
            if seq and seq > 0 then dyn:ResetSequence(seq) break end
        end
        dyn:SetCycle(0)
        dyn:SetPlaybackRate(0)
        if dyn.SetupBones then dyn:SetupBones() end -- client-only; the server computes bones on demand

        local pose, ok = {}, false
        for i = 0, count - 1 do
            local obj = ent:GetPhysicsObjectNum(i)
            local bone = ent:TranslatePhysBoneToBone(i)
            if IsValid(obj) and bone and bone >= 0 then
                local bpos, bang = dyn:GetBonePosition(bone)
                if bpos and bang then
                    pose[i] = { pos = bpos, ang = bang }
                    ok = true
                end
            end
        end
        dyn:Remove()
        if not ok then return false end

        for i, d in pairs(pose) do
            local obj = ent:GetPhysicsObjectNum(i)
            obj:EnableMotion(true)
            obj:SetVelocity(vector_origin)
            obj:SetPos(d.pos)
            obj:SetAngles(d.ang)
        end
        for i = 0, count - 1 do
            local obj = ent:GetPhysicsObjectNum(i)
            if IsValid(obj) then obj:EnableMotion(false) end
        end
        ent.KinectRestPose = pose
        ent.KinectFrozen = true
        return true
    end

    net.Receive(EDIT_POSE, function(_, ply)
        local ent = net.ReadEntity()
        local hold = net.ReadBool()
        if not IsValid(ply) or not IsValid(ent) or not ent:IsRagdoll() then return end
        if ply:GetPos():DistToSqr(ent:GetPos()) > 1500 * 1500 then return end
        if hold then
            if not StandRagdoll(ent, ply) then
                ply:ChatPrint("[Kinect Skeleton] Could not pose this ragdoll standing; calibration will use its current pose.")
            end
        else
            ReleaseRagdoll(ent)
        end
    end)

    ------------------------------------------------------------
    -- LIVE TEST RIG
    --
    -- Runs the REAL conversion path with recorded (or built-in) Kinect joint
    -- data instead of the live sensor: a genuine ragdoll_motion controller is
    -- created for the ragdoll, and Player:MotionSensorPos is temporarily
    -- replaced so it reads the clip's current frame. Everything after that
    -- (builder, calibration, ragdoll solver) is exactly what a real Kinect
    -- session uses.
    --
    -- Clips are saved as raw sensor joints in
    -- data/kinect_mapping_editor/testclips/<name>.json. Select one with the
    -- console variable kinect_testrig_clip (default: builtin).
    ------------------------------------------------------------
    local TR = { active = nil, orig = nil }
    local TR_SCALE = 36
    local TR_DIR = "kinect_mapping_editor/testclips"
    CreateConVar("kinect_testrig_clip", "builtin", FCVAR_ARCHIVE, "Test rig clip name ('builtin' or a saved clip)")

    local JOINT_ORDER = {
        "HIP", "SPINE", "SHOULDER", "HEAD",
        "SHOULDER_LEFT", "ELBOW_LEFT", "WRIST_LEFT", "HAND_LEFT",
        "SHOULDER_RIGHT", "ELBOW_RIGHT", "WRIST_RIGHT", "HAND_RIGHT",
        "HIP_LEFT", "KNEE_LEFT", "ANKLE_LEFT", "FOOT_LEFT",
        "HIP_RIGHT", "KNEE_RIGHT", "ANKLE_RIGHT", "FOOT_RIGHT",
    }

    -- "World-like" frame (meters, hip near origin, facing +X, character's left = +Y)
    -- -> raw sensor space as ragdoll_motion expects it (it rotates raw by
    -- (controller yaw - 90), so raw = world-like rotated by +90 yaw).
    local function ToRaw(joints)
        local out = {}
        for name, v in pairs(joints) do
            local r = Vector(v.x, v.y, v.z)
            r:Rotate(Angle(0, 90, 0))
            out[SENSORBONE[name]] = r
        end
        return out
    end

    local function BuiltinClip()
        local function rotX(v, a) local c, s = math.cos(a), math.sin(a) return Vector(v.x, v.y * c - v.z * s, v.y * s + v.z * c) end
        local function rotY(v, a) local c, s = math.cos(a), math.sin(a) return Vector(v.x * c + v.z * s, v.y, -v.x * s + v.z * c) end
        local function smooth(x) x = math.Clamp(x, 0, 1) return x * x * (3 - 2 * x) end

        local frames = {}
        for n = 0, 8 * 30 - 1 do
            local t = n / 30
            -- 0-2s: standing A pose. 2-3s arms rise overhead. 3.5-5s wave. 5-6s arms lower. 6-8s squat.
            local raise = smooth(t - 2) * (1 - smooth(t - 5))
            local wave = smooth(t - 3.2) * (1 - smooth(t - 4.8))
            local squat = math.sin(math.pi * math.Clamp((t - 6) / 2, 0, 1))
            local k = math.rad(70) * squat
            local drop = 0.42 * (1 - math.cos(k)) + 0.40 * (1 - math.cos(0.35 * k))
            local lean = math.rad(15) * squat
            local hipC = Vector(0, 0, -drop)
            local function torso(x, y, z) return hipC + rotY(Vector(x, y, z), lean) end

            local J = {}
            J.HIP = hipC
            J.SPINE = torso(0, 0, 0.25)
            J.SHOULDER = torso(0, 0, 0.55)
            J.HEAD = torso(0, 0, 0.75)

            local function arm(sign, key)
                local sh = torso(0, 0.2 * sign, 0.5)
                local d0 = Vector(0, 0.5 * sign, -0.87)
                local a = math.rad(150) * raise * sign
                local bend = math.rad(60) * (0.5 + 0.5 * math.sin(t * 9)) * wave * sign
                local upper = rotX(d0, a)
                local fore = rotX(d0, a + bend)
                local el = sh + upper * 0.30
                local wr = el + fore * 0.27
                J["SHOULDER_" .. key], J["ELBOW_" .. key], J["WRIST_" .. key], J["HAND_" .. key] = sh, el, wr, wr + fore * 0.08
            end
            arm(1, "LEFT")
            arm(-1, "RIGHT")

            local function leg(sign, key)
                local hp = hipC + Vector(0, 0.09 * sign, -0.05)
                local thigh = rotY(Vector(0, 0, -1), -k)
                local shin = rotY(Vector(0, 0, -1), 0.35 * k)
                local kn = hp + thigh * 0.42 + Vector(0, 0.01 * sign, 0)
                local an = kn + shin * 0.40
                J["HIP_" .. key], J["KNEE_" .. key], J["ANKLE_" .. key], J["FOOT_" .. key] = hp, kn, an, an + Vector(0.1, 0, -0.05)
            end
            leg(1, "LEFT")
            leg(-1, "RIGHT")

            frames[#frames + 1] = ToRaw(J)
        end
        return { fps = 30, frames = frames }
    end

    local function SafeClipName(name)
        name = string.gsub(tostring(name or ""), "[^%w_%-]", "")
        return name ~= "" and name or nil
    end

    local function LoadClip(name)
        name = SafeClipName(name)
        if not name or name == "builtin" then return BuiltinClip() end
        local raw = file.Read(TR_DIR .. "/" .. name .. ".json", "DATA")
        local data = raw and util.JSONToTable(raw)
        if not data or not data.frames or #data.frames == 0 then return nil end
        local frames = {}
        for i, flat in ipairs(data.frames) do
            local f = {}
            for j = 0, 19 do
                f[j] = Vector(flat[j * 3 + 1], flat[j * 3 + 2], flat[j * 3 + 3])
            end
            frames[i] = f
        end
        return { fps = data.fps or 30, frames = frames }
    end

    local function SaveClip(name, fps, frames)
        file.CreateDir("kinect_mapping_editor")
        file.CreateDir(TR_DIR)
        local flatFrames = {}
        for i, f in ipairs(frames) do
            local flat = {}
            for j = 0, 19 do
                local v = f[j]
                flat[#flat + 1] = math.Round(v.x, 4)
                flat[#flat + 1] = math.Round(v.y, 4)
                flat[#flat + 1] = math.Round(v.z, 4)
            end
            flatFrames[i] = flat
        end
        file.Write(TR_DIR .. "/" .. name .. ".json", util.TableToJSON({ version = 1, fps = fps, frames = flatFrames }))
    end

    local function StopTestRig()
        hook.Remove("Think", "KinectTestRig")
        if TR.active then
            if IsValid(TR.active.rm) then TR.active.rm:Remove() end
            if IsValid(TR.active.clone) then TR.active.clone:Remove() end
            TR.active = nil
        end
        local meta = FindMetaTable("Player")
        if meta and TR.orig then meta.MotionSensorPos = TR.orig end
        TR.orig = nil
    end

    -- asClone: run the test on an invisible duplicate of the ragdoll instead of
    -- the real one (used by the in-window dance preview, which mirrors the
    -- duplicate's bones onto the preview model). Returns the entity driven.
    local function StartTestRig(ply, srcEnt, asClone)
        StopTestRig()
        local ent = srcEnt
        local clone
        local builderName = "AnatomicalKinect_" .. srcEnt:GetModel()
        if not list.GetEntry("SkeletonConvertor", builderName) then
            ply:ChatPrint("[Kinect Skeleton] Press Apply Conversion first -- there is no converted builder for this model yet.")
            return false
        end
        local clipName = GetConVar("kinect_testrig_clip"):GetString()
        local clip = LoadClip(clipName)
        if not clip then
            ply:ChatPrint("[Kinect Skeleton] Test clip not found: " .. clipName .. " (using builtin)")
            clip = BuiltinClip()
        end

        if asClone then
            clone = ents.Create("prop_ragdoll")
            if not IsValid(clone) then return false end
            clone:SetModel(srcEnt:GetModel())
            clone:SetPos(srcEnt:GetPos() + ply:GetRight() * 220)
            clone:Spawn()
            clone:Activate()
            clone:SetRenderMode(RENDERMODE_TRANSALPHA)
            clone:SetColor(Color(255, 255, 255, 0))
            clone:DrawShadow(false)
            clone:SetNoDraw(true) -- model materials can ignore alpha, so also hide it outright
            clone:SetCollisionGroup(COLLISION_GROUP_WORLD)
            ent = clone
        end

        -- Stand the ragdoll up and let go of it; the controller takes over below.
        StandRagdoll(ent, ply)
        ReleaseRagdoll(ent)
        local root = ent:GetPhysicsObjectNum(0)
        if not IsValid(root) then return false end

        local theta = ply:EyeAngles().y + 180
        local hip = Vector(clip.frames[1][SENSORBONE.HIP])
        hip:Rotate(Angle(0, theta - 90, 0))
        local center = root:GetPos() - hip * TR_SCALE

        local rm = ents.Create("ragdoll_motion")
        if not IsValid(rm) then ply:ChatPrint("[Kinect Skeleton] Could not create a test controller.") return false end
        rm:SetPos(center)
        rm:SetAngles(Angle(0, theta, 0))
        rm:SetRagdoll(ent)
        rm:SetController(ply)
        rm:Spawn()
        local rmPhys = rm:GetPhysicsObject()
        if IsValid(rmPhys) then rmPhys:EnableMotion(false) end
        if asClone then rm:SetNoDraw(true) end

        local meta = FindMetaTable("Player")
        TR.orig = meta.MotionSensorPos
        TR.active = { ply = ply, rm = rm, clone = clone, clip = clip, start = CurTime(), frame = 1 }
        meta.MotionSensorPos = function(p, i)
            local a = TR.active
            if a and a.ply == p then
                return Vector(a.clip.frames[a.frame][i]) -- copy: callers rotate it in place
            end
            if TR.orig then return TR.orig(p, i) end
            return Vector(0, 0, 0)
        end

        hook.Add("Think", "KinectTestRig", function()
            local a = TR.active
            if not a or not IsValid(a.ply) or not IsValid(ent) or not IsValid(a.rm) or CurTime() - a.start > 120 then
                StopTestRig()
                return
            end
            a.frame = math.floor((CurTime() - a.start) * a.clip.fps) % #a.clip.frames + 1
        end)
        return asClone and clone or true
    end

    net.Receive(EDIT_TESTRIG, function(_, ply)
        local ent = net.ReadEntity()
        local start = net.ReadBool()
        if not IsValid(ply) or not IsValid(ent) or not ent:IsRagdoll() then return end
        if ply:GetPos():DistToSqr(ent:GetPos()) > 1500 * 1500 then return end
        if start then StartTestRig(ply, ent) else StopTestRig() end
    end)

    net.Receive(EDIT_DANCE, function(_, ply)
        local ent = net.ReadEntity()
        local start = net.ReadBool()
        if not IsValid(ply) or not IsValid(ent) or not ent:IsRagdoll() then return end
        if ply:GetPos():DistToSqr(ent:GetPos()) > 1500 * 1500 then return end
        if not start then StopTestRig() return end
        local clone = StartTestRig(ply, ent, true)
        if IsValid(clone) then
            net.Start(EDIT_DANCE_REPLY)
            net.WriteUInt(clone:EntIndex(), 16)
            net.Send(ply)
        end
    end)

    -- Record raw joints from the live Kinect (needs the sensor running).
    concommand.Add("kinect_testclip_record", function(ply, _, args)
        if not IsValid(ply) then return end
        local name, seconds = SafeClipName(args[1]), math.Clamp(tonumber(args[2]) or 10, 1, 60)
        if not name then ply:ChatPrint("Usage: kinect_testclip_record <name> [seconds]") return end
        local frames, fps, total = {}, 30, 0
        ply:ChatPrint("[Kinect Skeleton] Recording " .. seconds .. "s of live Kinect data as '" .. name .. "'...")
        timer.Create("KinectTestClipRecord", 1 / fps, seconds * fps, function()
            if not IsValid(ply) then timer.Remove("KinectTestClipRecord") return end
            local f = {}
            for j = 0, 19 do f[j] = ply:MotionSensorPos(j) end
            frames[#frames + 1] = f
            total = total + 1
            if total >= seconds * fps then
                SaveClip(name, fps, frames)
                ply:ChatPrint("[Kinect Skeleton] Saved test clip '" .. name .. "' (" .. #frames .. " frames).")
            end
        end)
    end)

    -- Record from a normal (unconverted) ValveBiped ragdoll that is playing an
    -- SMH animation: start the SMH playback, then run this while aiming at it.
    concommand.Add("kinect_testclip_from_ragdoll", function(ply, _, args)
        if not IsValid(ply) then return end
        local name = SafeClipName(args[1])
        local seconds = math.Clamp(tonumber(args[2]) or 10, 1, 60)
        local delay = math.Clamp(tonumber(args[3]) or 3, 0, 30)
        local ent = ply:GetEyeTrace().Entity
        if not name or not IsValid(ent) or not ent:IsRagdoll() then
            ply:ChatPrint("Usage: aim at the ragdoll, then: kinect_testclip_from_ragdoll <name> [seconds] [delay]")
            return
        end
        local map = ResolveAnatomicalPhysics(ent, false)
        if not map then ply:ChatPrint("[Kinect Skeleton] Could not find all 15 body roles on that ragdoll.") return end
        local function body(role) return ent:GetPhysicsObjectNum(map["ValveBiped.Bip01_" .. role]) end
        local roles = { "Pelvis", "Spine4", "Head1", "L_UpperArm", "R_UpperArm", "L_Forearm", "R_Forearm",
                        "L_Hand", "R_Hand", "L_Thigh", "R_Thigh", "L_Calf", "R_Calf", "L_Foot", "R_Foot" }
        local frames, fps, total = {}, 30, 0
        ply:ChatPrint("[Kinect Skeleton] Recording starts in " .. delay .. "s -- start the SMH playback now.")
        timer.Simple(delay, function()
            if not IsValid(ply) or not IsValid(ent) then return end
            ply:ChatPrint("[Kinect Skeleton] Recording...")
            timer.Create("KinectTestClipRecord", 1 / fps, seconds * fps, function()
                if not IsValid(ent) then timer.Remove("KinectTestClipRecord") return end
                local P = {}
                for _, r in ipairs(roles) do
                    local b = body(r)
                    if not IsValid(b) then timer.Remove("KinectTestClipRecord") return end
                    P[r] = b:GetPos()
                end
                -- Face +X: the character's left is the hip-to-hip vector.
                local left = P.L_Thigh - P.R_Thigh
                local yawFacing = math.deg(math.atan2(left.y, left.x)) - 90
                local hip = P.Pelvis
                local function rel(v)
                    local r = (v - hip) / TR_SCALE
                    r:Rotate(Angle(0, -yawFacing, 0))
                    return r
                end
                local mid = (P.L_UpperArm + P.R_UpperArm) * 0.5
                local J = {
                    HIP = rel(P.Pelvis), SPINE = rel(P.Spine4), SHOULDER = rel(mid), HEAD = rel(P.Head1),
                    SHOULDER_LEFT = rel(P.L_UpperArm), ELBOW_LEFT = rel(P.L_Forearm),
                    WRIST_LEFT = rel(P.L_Hand), HAND_LEFT = rel(P.L_Hand + (P.L_Hand - P.L_Forearm) * 0.3),
                    SHOULDER_RIGHT = rel(P.R_UpperArm), ELBOW_RIGHT = rel(P.R_Forearm),
                    WRIST_RIGHT = rel(P.R_Hand), HAND_RIGHT = rel(P.R_Hand + (P.R_Hand - P.R_Forearm) * 0.3),
                    HIP_LEFT = rel(P.L_Thigh), KNEE_LEFT = rel(P.L_Calf),
                    ANKLE_LEFT = rel(P.L_Foot), FOOT_LEFT = rel(P.L_Foot + (P.L_Foot - P.L_Calf) * 0.25),
                    HIP_RIGHT = rel(P.R_Thigh), KNEE_RIGHT = rel(P.R_Calf),
                    ANKLE_RIGHT = rel(P.R_Foot), FOOT_RIGHT = rel(P.R_Foot + (P.R_Foot - P.R_Calf) * 0.25),
                }
                frames[#frames + 1] = ToRaw(J)
                total = total + 1
                if total >= seconds * fps then
                    SaveClip(name, fps, frames)
                    ply:ChatPrint("[Kinect Skeleton] Saved test clip '" .. name .. "' (" .. #frames .. " frames). Use it with: kinect_testrig_clip " .. name)
                end
            end)
        end)
    end)

    net.Receive(EDIT_APPLY, function(_, ply)
        local ent = net.ReadEntity()
        local fixed = net.ReadBool()
        local swap = net.ReadBool()
        local count = net.ReadUInt(5)

        local function report(success, message)
            net.Start(EDIT_RESULT)
            net.WriteBool(success)
            net.WriteString(message)
            net.Send(ply)
        end

        if not IsValid(ply) or not IsValid(ent) or not ent:IsRagdoll() then return end
        if ply:GetPos():DistToSqr(ent:GetPos()) > 1500 * 1500 then return end
        if count ~= #ROLE_ORDER then report(false, "Incorrect role count") return end

        local map, used, modelBoneByRole = {}, {}, {}
        for i = 1, count do
            local boneName = net.ReadString()
            if #boneName > 128 then report(false, "Invalid bone name") return end
            local modelIndex = GetBoneIndexByName(ent, boneName)
            if modelIndex < 0 then
                report(false, LABELS[i] .. ": bone not found: " .. boneName)
                return
            end
            local physIndex = ResolveExactPhysicsIndex(ent, modelIndex)
            if not physIndex or physIndex < 0 or physIndex >= ent:GetPhysicsObjectCount() then
                report(false, LABELS[i] .. ": no directly mapped physics bone (" .. boneName .. ")")
                return
            end
            if not IsValid(ent:GetPhysicsObjectNum(physIndex)) then
                report(false, LABELS[i] .. ": physics object invalid")
                return
            end
            if used[physIndex] then
                report(false, LABELS[i] .. " shares physics bone " .. physIndex .. " with " .. used[physIndex])
                return
            end
            map[ROLE_ORDER[i]] = physIndex
            modelBoneByRole[ROLE_ORDER[i]] = modelIndex
            used[physIndex] = LABELS[i]
        end

        -- Re-derive the chest/spine role by anatomy (the bone where the left
        -- and right arm chains share a common ancestor) rather than trusting
        -- whatever name-based guess was sent, since spine-numbering
        -- direction differs between models (notably SFM/HWM ports) and the
        -- server has reliable physics access to verify this properly. This
        -- silently upgrades automatic mode's guess, and also protects
        -- against picking a bad spine bone in manual mode.
        local leftArmBone = modelBoneByRole["ValveBiped.Bip01_L_UpperArm"]
        local rightArmBone = modelBoneByRole["ValveBiped.Bip01_R_UpperArm"]
        local chestName = FindChestBoneName(ent, leftArmBone, rightArmBone)
        if chestName then
            local chestBone = GetBoneIndexByName(ent, chestName)
            local chestPhys = chestBone >= 0 and ResolveExactPhysicsIndex(ent, chestBone) or -1
            if chestPhys >= 0 and IsValid(ent:GetPhysicsObjectNum(chestPhys)) then
                local oldPhys = map["ValveBiped.Bip01_Spine4"]
                if chestPhys ~= oldPhys and (not used[chestPhys] or used[chestPhys] == "Spine / Chest") then
                    if oldPhys then used[oldPhys] = nil end
                    map["ValveBiped.Bip01_Spine4"] = chestPhys
                    used[chestPhys] = "Spine / Chest"
                end
            end
        end

        SetBuilder(map, ent:GetModel(), fixed, ent, swap)
        ReleaseRagdoll(ent)
        ent.KinectEditorLastBuilder = "AnatomicalKinect_" .. ent:GetModel()
        report(true, "Mapping registered. If a Kinect controller is already attached, detach and reattach it to pick up the new builder.")
    end)

    concommand.Add("kinect_editor_status", function(ply)
        if not IsValid(ply) then return end
        local ent = ply:GetEyeTrace().Entity
        if not IsValid(ent) or not ent:IsRagdoll() then
            print("[Kinect Skeleton] Aim at a ragdoll first")
            return
        end
        print("[Kinect Skeleton] model:", ent:GetModel(),
            "registered builder:", ent.KinectEditorLastBuilder or "(none yet, click Apply Conversion)",
            "chosen builder:", motionsensor and motionsensor.ChooseBuilderFromEntity and
                tostring(motionsensor.ChooseBuilderFromEntity(ent)) or "unknown",
            "controller attached:", IsValid(ent.MotionSensorController))
    end)
else
    local editor
    local SETUP_DIR = "kinect_mapping_editor/setups"

    local function cleanSetupName(value)
        local name = string.Trim(tostring(value or ""))
        name = string.gsub(name, "[^%w%s_%-]", "")
        name = string.Trim(name)
        name = string.sub(name, 1, 48)
        return name
    end
    local function setupPath(name)
        return SETUP_DIR .. "/" .. cleanSetupName(name) .. ".txt"
    end
    local function safeBonePosition(ent, index)
        if not IsValid(ent) or not index or index < 0 then return nil end
        local matrix = ent:GetBoneMatrix(index)
        if matrix then return matrix:GetTranslation() end
        return ent:GetBonePosition(index)
    end
    -- Plain name-based matching only. This client-side pass is just a
    -- starting guess for the editor UI to show; it does NOT need to verify
    -- physics bodies (client-side physics queries on a networked ragdoll
    -- aren't reliable enough for that) because the server re-validates
    -- every role -- including re-deriving the chest/spine role by anatomy
    -- -- when Apply Conversion is clicked.
    local function autoMap(ent)
        local out = {}
        for i, role in ipairs(ROLE_ORDER) do
            local chosen = ""
            for _, alias in ipairs(ROLE_CANDIDATES[role]) do
                if GetBoneIndexByName(ent, alias) >= 0 then chosen = alias break end
            end
            out[i] = chosen
        end
        return out
    end

    openEditor = function(ent)
        if not IsValid(ent) then return end
        if editor and IsValid(editor.frame) then editor.frame:Remove() end

        local state = {
            target = ent, mapping = autoMap(ent), selected = 1,
            pendingBone = nil, lastMappedBone = nil, lastMapMessage = nil,
            mode = "automatic", fixed = false, testActive = false, testStart = 0,
            showAllBones = false
        }
        editor = state

        local frame = vgui.Create("DFrame")
        state.frame = frame
        frame:SetSize(math.min(ScrW() - 40, 1100), math.min(ScrH() - 50, 700))
        frame:Center()
        frame:SetTitle("Kinect Skeleton Converter | Visual Bone Mapper")
        frame:SetSizable(true)
        frame:MakePopup()
        frame.OnRemove = function()
            if editor == state then editor = nil end
            if IsValid(ent) then
                net.Start(EDIT_POSE) net.WriteEntity(ent) net.WriteBool(false) net.SendToServer()
            end
        end
        -- Stand the ragdoll up (and hold it) so calibration sees a clean pose.
        net.Start(EDIT_POSE) net.WriteEntity(ent) net.WriteBool(true) net.SendToServer()

        local top = vgui.Create("DPanel", frame)
        top:Dock(TOP)
        top:SetTall(166)
        top:DockMargin(8, 4, 8, 4)

        local title = vgui.Create("DLabel", top)
        title:SetPos(12, 6) title:SetSize(940, 22)
        title:SetText("MODEL: " .. ent:GetModel())
        title:SetTextColor(Color(16, 22, 34))

        local info = vgui.Create("DLabel", top)
        info:SetPos(12, 28) info:SetSize(950, 19)
        info:SetText("Manual: choose a Kinect joint, select a model bone, then press Map Selected Bone.")
        info:SetTextColor(Color(28, 35, 48))

        local modeSelect = vgui.Create("DComboBox", top)
        modeSelect:SetPos(12, 52) modeSelect:SetSize(190, 24)
        modeSelect:SetValue("Automatic mapping")
        modeSelect:AddChoice("Automatic mapping", "automatic")
        modeSelect:AddChoice("Manual mapping", "manual")

        local autoButton = vgui.Create("DButton", top)
        autoButton:SetPos(210, 52) autoButton:SetSize(150, 24)
        autoButton:SetText("Auto-detect bones")

        local mirrorButton = vgui.Create("DButton", top)
        mirrorButton:SetPos(368, 52) mirrorButton:SetSize(170, 24)
        mirrorButton:SetText("Mirror Mapped Bones")

        local fixedBox = vgui.Create("DCheckBoxLabel", top)
        fixedBox:SetPos(546, 54) fixedBox:SetText("Fixed-hand mode") fixedBox:SizeToContents()
        fixedBox:SetTextColor(Color(20, 28, 40))
        fixedBox.OnChange = function(_, checked) state.fixed = checked end

        local danceButton = vgui.Create("DButton", top)
        danceButton:SetPos(368, 82) danceButton:SetSize(170, 24)
        danceButton:SetText("Dance in Preview")
        danceButton.running = false

        local liveTest = vgui.Create("DButton", top)
        liveTest:SetPos(170, 82) liveTest:SetSize(190, 24)
        liveTest:SetText("Live Test (world ragdoll)")
        liveTest.running = false
        liveTest.DoClick = function()
            if not IsValid(ent) then return end
            liveTest.running = not liveTest.running
            if liveTest.running and danceButton.running then
                danceButton.running = false
                danceButton:SetText("Dance in Preview")
                if state then state.mirror = nil end
            end
            net.Start(EDIT_TESTRIG) net.WriteEntity(ent) net.WriteBool(liveTest.running) net.SendToServer()
            liveTest:SetText(liveTest.running and "Stop Live Test" or "Live Test (world ragdoll)")
        end

        local swapBox = vgui.Create("DCheckBoxLabel", top)
        swapBox:SetPos(546, 80) swapBox:SetText("Swap left/right (if arms/legs are controlled by the wrong side)") swapBox:SizeToContents()
        swapBox:SetTextColor(Color(20, 28, 40))
        state.swap = cookie.GetNumber("kinect_converter_swap", 0) == 1
        swapBox:SetChecked(state.swap)
        swapBox.OnChange = function(_, checked)
            state.swap = checked
            cookie.Set("kinect_converter_swap", checked and "1" or "0")
        end

        local showAll = vgui.Create("DCheckBoxLabel", top)
        showAll:SetPos(700, 54) showAll:SetText("Show all model bones") showAll:SizeToContents()
        showAll:SetChecked(false)
        showAll:SetTextColor(Color(20, 28, 40))
        showAll:SetVisible(false)
        showAll.OnChange = function(_, checked)
            state.showAllBones = state.mode == "manual" and checked or false
        end

        local testButton = vgui.Create("DButton", top)
        testButton:SetPos(12, 82) testButton:SetSize(150, 24)
        testButton:SetText("Limb Check (mapping)")

        local activeTestLabel = vgui.Create("DLabel", top)
        activeTestLabel:SetPos(12, 138) activeTestLabel:SetSize(700, 22)
        activeTestLabel:SetText("Preview-only: swings the mapped limbs on this model, no physics involved")
        activeTestLabel:SetTextColor(Color(12, 65, 115))

        local flatBox = vgui.Create("DCheckBoxLabel", top)
        flatBox:SetPos(12, 110) flatBox:SetText("Flat front view (uncheck to orbit)")
        flatBox:SetTextColor(Color(20, 28, 40))
        flatBox:SizeToContents()
        flatBox:SetChecked(true)

        local cameraHelp = vgui.Create("DLabel", top)
        cameraHelp:SetPos(240, 110) cameraHelp:SetSize(700, 22)
        cameraHelp:SetText("Right-drag: orbit   |   Wheel: zoom   |   Left-click: choose model bone")
        cameraHelp:SetTextColor(Color(25, 35, 47))

        local bottom = vgui.Create("DPanel", frame)
        bottom:Dock(BOTTOM) bottom:SetTall(158)
        bottom:DockMargin(8, 3, 8, 6)

        local status = vgui.Create("DLabel", bottom)
        status:SetPos(8, 4) status:SetSize(1000, 23)
        status:SetText("Auto Detect active. Use Manual mode to edit bones; setups are saved locally as text files.")
        status:SetTextColor(Color(18, 26, 40))
        state.manualStatus = status

        local apply = vgui.Create("DButton", bottom)
        apply:SetPos(8, 36) apply:SetSize(220, 32) apply:SetText("Apply Conversion")
        local save = vgui.Create("DButton", bottom)
        save:SetPos(240, 36) save:SetSize(160, 32) save:SetText("Save Setup")
        local load = vgui.Create("DButton", bottom)
        load:SetPos(412, 36) load:SetSize(160, 32) load:SetText("Load Setup")

        local diagnose = vgui.Create("DButton", bottom)
        diagnose:SetPos(8, 78) diagnose:SetSize(220, 32)
        diagnose:SetText("Diagnose Conversion")
        diagnose.DoClick = function()
            if not IsValid(ent) then status:SetText("Selected ragdoll no longer exists") return end
            net.Start(EDIT_DIAG)
            net.WriteEntity(ent)
            net.WriteUInt(#ROLE_ORDER, 5)
            for i = 1, #ROLE_ORDER do net.WriteString(state.mapping[i] or "") end
            net.SendToServer()
            status:SetText("Requesting read-only server physics report...")
        end

        local pickerLabel = vgui.Create("DLabel", bottom)
        pickerLabel:SetPos(8, 120) pickerLabel:SetSize(265, 26)
        pickerLabel:SetText("Selected model bone (not yet mapped):")
        pickerLabel:SetTextColor(Color(18, 26, 40))
        local picker = vgui.Create("DComboBox", bottom)
        picker:SetPos(275, 115) picker:SetSize(365, 30)
        picker:SetVisible(false)
        picker:SetEnabled(false)
        local mapBoneButton = vgui.Create("DButton", bottom)
        mapBoneButton:SetPos(651, 115) mapBoneButton:SetSize(300, 30)
        mapBoneButton:SetText("Map Selected Bone")
        mapBoneButton:SetVisible(false)
        mapBoneButton:SetEnabled(false)

        local names = {}
        for i = 0, (ent:GetBoneCount() or 0) - 1 do
            local name = ent:GetBoneName(i)
            if name and name ~= "__INVALIDBONE__" then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do picker:AddChoice(name) end
        picker.OnSelect = function(_, _, _, value)
            if state.mode ~= "manual" then return end
            state.pendingBone = value
            state.lastMappedBone = nil
            state.lastMapMessage = nil
            notification.AddLegacy("Selected bone: " .. value .. " | Press Map Selected Bone", NOTIFY_GENERIC, 3)
            if state.refresh then state.refresh() end
        end

        local function refresh()
            local role = LABELS[state.selected]
            local bone = state.mapping[state.selected] or ""
            local pending = state.pendingBone
            status:SetText(role .. " -> " .. (bone ~= "" and bone or "UNMAPPED") ..
                (pending and ("  | Selected: " .. pending .. " (not mapped yet)") or ""))
            picker:SetValue(pending or (bone ~= "" and bone or "Choose a model bone..."))
        end
        state.refresh = refresh

        mapBoneButton.DoClick = function()
            if state.mode ~= "manual" then return end
            if not IsValid(ent) then status:SetText("Ragdoll no longer exists") return end
            local name = state.pendingBone
            if not name or name == "" then
                status:SetText("Select a model bone (dot or dropdown) before pressing Map Selected Bone")
                notification.AddLegacy("Select a model bone first", NOTIFY_ERROR, 5)
                return
            end
            local role = state.selected
            net.Start(EDIT_VALIDATE_BONE)
            net.WriteEntity(ent)
            net.WriteUInt(role, 5)
            net.WriteString(name)
            net.WriteUInt(#ROLE_ORDER, 5)
            for i = 1, #ROLE_ORDER do net.WriteString(state.mapping[i] or "") end
            net.SendToServer()
            status:SetText("Checking " .. LABELS[role] .. " -> " .. name .. " against real physics bodies...")
        end

        local function setMappingMode(mode)
            state.mode = mode == "manual" and "manual" or "automatic"
            local manual = state.mode == "manual"
            picker:SetVisible(manual)
            picker:SetEnabled(manual)
            pickerLabel:SetVisible(manual)
            mapBoneButton:SetVisible(manual)
            mapBoneButton:SetEnabled(manual)
            showAll:SetVisible(manual)
            showAll:SetEnabled(manual)
            if not manual then
                state.lastMappedBone = nil
                state.showAllBones = false
                showAll:SetChecked(false)
            end
            refresh()
        end
        modeSelect.OnSelect = function(_, _, _, mode) setMappingMode(mode) end

        autoButton.DoClick = function()
            state.mapping = autoMap(ent)
            state.pendingBone = nil
            state.lastMappedBone = nil
            modeSelect:SetValue("Automatic mapping")
            setMappingMode("automatic")
        end

        -- Swap left/right role assignments. Press again to undo.
        local mirrorPairs = {{4,5},{6,7},{8,9},{10,11},{12,13},{14,15}}
        mirrorButton.DoClick = function()
            if state.testActive then
                state.testActive = false
                testButton:SetText("Limb Check (mapping)")
            end
            for _, pair in ipairs(mirrorPairs) do
                local left, right = pair[1], pair[2]
                state.mapping[left], state.mapping[right] = state.mapping[right], state.mapping[left]
            end
            refresh()
            status:SetText("Mirrored left/right role assignments. Click Mirror again to reverse. Check before Apply!")
        end

        save.DoClick = function()
            if not IsValid(ent) then status:SetText("Ragdoll no longer exists") return end
            Derma_StringRequest("Save Skeleton Setup", "Enter a name for this mapping setup:", "My Ragdoll", function(input)
                local name = cleanSetupName(input)
                if name == "" then
                    Derma_Message("Please enter a name with letters or numbers.", "Invalid setup name", "OK")
                    return
                end
                local path = setupPath(name)
                local function writeSetup()
                    file.CreateDir("kinect_mapping_editor")
                    file.CreateDir(SETUP_DIR)
                    local savedMapping = {}
                    for i = 1, #ROLE_ORDER do savedMapping[i] = state.mapping[i] or "" end
                    local data = {version = 1, name = name, model = ent:GetModel(), mapping = savedMapping, fixed = state.fixed}
                    local encoded = util.TableToJSON(data, true)
                    if not encoded then
                        status:SetText("Could not encode mapping setup")
                        return
                    end
                    file.Write(path, encoded)
                    status:SetText("Saved setup: " .. name .. " (garrysmod/data/" .. path .. ")")
                end
                if file.Exists(path, "DATA") then
                    Derma_Query("A setup called '" .. name .. "' already exists. Overwrite it?", "Overwrite Setup", "Overwrite", writeSetup, "Cancel", function() end)
                else
                    writeSetup()
                end
            end)
        end

        load.DoClick = function()
            if not IsValid(ent) then status:SetText("Ragdoll no longer exists") return end
            file.CreateDir("kinect_mapping_editor")
            file.CreateDir(SETUP_DIR)
            local filenames = file.Find(SETUP_DIR .. "/*.txt", "DATA") or {}
            local listFrame = vgui.Create("DFrame")
            listFrame:SetSize(550, 390)
            listFrame:Center()
            listFrame:SetTitle("Load Kinect Mapping Setup")
            listFrame:MakePopup()
            local description = vgui.Create("DLabel", listFrame)
            description:Dock(TOP)
            description:SetTall(46)
            description:DockMargin(10, 5, 10, 2)
            description:SetWrap(true)
            description:SetTextColor(Color(20, 28, 40))
            description:SetText("Select a saved setup. Bone names must exist on the currently selected ragdoll.")
            local setupList = vgui.Create("DListView", listFrame)
            setupList:Dock(FILL)
            setupList:DockMargin(10, 0, 10, 8)
            setupList:AddColumn("Setup name")
            setupList:AddColumn("Original model")
            local records = {}
            for _, filename in ipairs(filenames) do
                local path = SETUP_DIR .. "/" .. filename
                local raw = file.Read(path, "DATA")
                local decoded = raw and util.JSONToTable(raw)
                if istable(decoded) and istable(decoded.mapping) then
                    local idx = #records + 1
                    records[idx] = decoded
                    local entry = setupList:AddLine(decoded.name or string.StripExtension(filename), decoded.model or "Unknown")
                    entry.setupIndex = idx
                end
            end
            local loadSelected = vgui.Create("DButton", listFrame)
            loadSelected:Dock(BOTTOM)
            loadSelected:DockMargin(10, 0, 10, 10)
            loadSelected:SetTall(34)
            loadSelected:SetText("Load Selected Setup")
            local function selectSetup()
                local lineId = setupList:GetSelectedLine()
                local line = lineId and setupList:GetLine(lineId)
                local data = line and records[line.setupIndex]
                if not data then
                    Derma_Message("Select a setup from the list first.", "Load Setup", "OK")
                    return
                end
                local missing, loaded = {}, {}
                for i = 1, #ROLE_ORDER do
                    local boneName = data.mapping[i]
                    if not isstring(boneName) or boneName == "" or GetBoneIndexByName(ent, boneName) < 0 then
                        missing[#missing + 1] = LABELS[i] .. " -> " .. tostring(boneName or "(none)")
                    else
                        loaded[i] = boneName
                    end
                end
                if #missing > 0 then
                    Derma_Message("This setup cannot be loaded onto the selected model. Missing bones:\n" .. table.concat(missing, "\n"), "Incompatible mapping", "OK")
                    return
                end
                state.mapping = loaded
                if isbool(data.fixed) then
                    state.fixed = data.fixed
                    fixedBox:SetChecked(data.fixed)
                end
                modeSelect:SetValue("Manual mapping")
                setMappingMode("manual")
                if state.testActive then
                    state.testActive = false
                    testButton:SetText("Limb Check (mapping)")
                end
                listFrame:Close()
                status:SetText("Loaded setup: " .. tostring(data.name or "Untitled") .. " — ready to Apply Conversion")
            end
            loadSelected.DoClick = selectSetup
            setupList.DoDoubleClick = selectSetup
            if #records == 0 then
                description:SetText("No saved setups found. Use Save Setup to create one first.")
                loadSelected:SetEnabled(false)
            end
        end

        apply.DoClick = function()
            if not IsValid(ent) then status:SetText("Ragdoll no longer exists") return end
            for i = 1, #ROLE_ORDER do
                if not isstring(state.mapping[i]) or state.mapping[i] == "" then
                    status:SetText("Missing mapping: " .. LABELS[i]) return
                end
            end
            net.Start(EDIT_APPLY)
            net.WriteEntity(ent)
            net.WriteBool(state.fixed)
            net.WriteBool(state.swap == true)
            net.WriteUInt(#ROLE_ORDER, 5)
            for i = 1, #ROLE_ORDER do net.WriteString(state.mapping[i]) end
            net.SendToServer()
            status:SetText("Validating 15 physics assignments on server...")
        end

        --------------------------------------------------------
        -- 2D role diagram (left) + 3D model preview with bone overlay (right)
        --------------------------------------------------------

        local body = vgui.Create("DPanel", frame)
        body:Dock(FILL) body:DockMargin(8, 0, 8, 0)
        body.Paint = function() end
        local left = vgui.Create("DPanel", body)
        left:Dock(LEFT) left:SetWide(260) left:DockMargin(0, 0, 6, 0)
        local right = vgui.Create("DPanel", body)
        right:Dock(FILL)

        local green = Color(64, 245, 115)
        local selectedColor = Color(255, 215, 70)
        left.Paint = function(panel, w, h)
            draw.RoundedBox(6, 0, 0, w, h, Color(16, 27, 26))
            draw.SimpleText("KINECT V1 / A-POSE", "DermaDefaultBold", 12, 12, green)
            for _, line in ipairs(JOINT_EDGES) do
                local a, b = JOINT_POINTS[line[1]], JOINT_POINTS[line[2]]
                surface.SetDrawColor(55, 190, 95)
                surface.DrawLine(a[1] * w, 40 + a[2] * (h - 65), b[1] * w, 40 + b[2] * (h - 65))
            end
            for i, p in ipairs(JOINT_POINTS) do
                local x, y = p[1] * w, 40 + p[2] * (h - 65)
                draw.NoTexture()
                surface.SetDrawColor(i == state.selected and selectedColor or green)
                surface.DrawCircle(x, y, 6, i == state.selected and selectedColor or green)
                if i == state.selected then draw.SimpleText(LABELS[i], "DermaDefault", 8, h - 17, selectedColor) end
            end
        end
        left.OnMousePressed = function(panel)
            if state.mode ~= "manual" then
                status:SetText("Auto Detect is active. Switch to Manual mapping to select joints.")
                return
            end
            local mx, my = panel:CursorPos()
            local w, h = panel:GetSize()
            local closest, d = 1, math.huge
            for i, p in ipairs(JOINT_POINTS) do
                local x, y = p[1] * w, 40 + p[2] * (h - 65)
                local dist = (mx - x) ^ 2 + (my - y) ^ 2
                if dist < d then closest, d = i, dist end
            end
            if d < 600 then
                state.selected = closest
                state.pendingBone = nil
                state.lastMappedBone = nil
                if state.refresh then state.refresh() end
            end
        end

        local model = vgui.Create("DModelPanel", right)
        model:Dock(FILL)
        model:SetModel(ent:GetModel())
        model:SetFOV(35)
        model.LayoutEntity = function() end -- preview holds reference pose
        local camera = {yaw = 0, pitch = 0, distance = 120, zoom = 1, flat = true, drag = false}
        local modelCenter = Vector(0, 0, 42)
        local modelFloor = 0
        local modelSpan = 90
        if IsValid(model.Entity) then
            model.Entity:SetAngles(Angle(0, 0, 0))
            model.Entity:ResetSequence(0)
            model.Entity:SetupBones()
            local mn, mx = model.Entity:GetRenderBounds()
            modelCenter = (mn + mx) * 0.5
            modelFloor = mn.z - 1.0
            modelSpan = math.max(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z, 45)
        end
        local function updateCamera()
            if not IsValid(model) then return end
            local w, h = math.max(model:GetWide(), 1), math.max(model:GetTall(), 1)
            local hfov = math.rad(model:GetFOV())
            local vfov = 2 * math.atan(math.tan(hfov / 2) * h / w)
            local halfHeight = modelSpan * 0.52
            local halfWidth = modelSpan * 0.44
            local fitDist = math.max(halfHeight / math.tan(vfov / 2), halfWidth / math.tan(hfov / 2)) * 1.30
            camera.distance = math.Clamp(fitDist * camera.zoom, 30, 5000)
            local yaw, pitch = math.rad(camera.yaw), math.rad(camera.pitch)
            local offset = Vector(math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)) * camera.distance
            model:SetLookAt(modelCenter)
            model:SetCamPos(modelCenter + offset)
        end
        camera.update = updateCamera
        flatBox.OnChange = function(_, checked)
            camera.flat = checked
            if checked then camera.yaw = 0 camera.pitch = 0 end
            updateCamera()
        end
        model.OnMouseWheeled = function(_, delta)
            camera.zoom = math.Clamp(camera.zoom * math.pow(0.89, delta), 0.30, 3.5)
            updateCamera()
            return true
        end
        model.OnMouseReleased = function(_, code)
            if code == MOUSE_RIGHT then
                camera.drag = false
                model:MouseCapture(false)
            end
        end
        model.OnCursorMoved = function(panel, x, y)
            if camera.drag and not camera.flat then
                if camera.previousX then
                    camera.yaw = camera.yaw + (x - camera.previousX) * 0.4
                    camera.pitch = math.Clamp(camera.pitch + (camera.previousY - y) * 0.4, -75, 75)
                    updateCamera()
                end
                camera.previousX, camera.previousY = x, y
            end
        end
        local lastW, lastH = 0, 0
        local function fitOnResize()
            if model:GetWide() ~= lastW or model:GetTall() ~= lastH then
                lastW, lastH = model:GetWide(), model:GetTall()
                updateCamera()
            end
        end
        updateCamera()

        local boneDot = Color(80, 192, 255)
        local boneLink = Color(78, 172, 237, 130)
        local mappedDot = Color(66, 237, 136)
        local pickedGreen = Color(34, 255, 87)
        local pickedHalo = Color(8, 80, 35, 220)
        local function projectedPoint(world, w, h)
            local origin = model:GetCamPos()
            local forward = (model:GetLookAt() - origin):GetNormalized()
            local right = forward:Cross(Vector(0, 0, 1)):GetNormalized()
            local up = right:Cross(forward):GetNormalized()
            local offset = world - origin
            local depth = offset:Dot(forward)
            if depth <= 0.01 then return nil end
            local horizontalFov = math.rad(model:GetFOV())
            local focal = (w * 0.5) / math.tan(horizontalFov * 0.5)
            return w * 0.5 + offset:Dot(right) * focal / depth,
                   h * 0.5 - offset:Dot(up) * focal / depth
        end
        local function getPreviewPoints()
            local preview = model.Entity
            if not IsValid(preview) then return {} end
            preview:SetupBones()
            local results = {}
            for index = 0, (preview:GetBoneCount() or 0) - 1 do
                local pos = safeBonePosition(preview, index)
                local name = preview:GetBoneName(index)
                if pos and name and name ~= "__INVALIDBONE__" then
                    results[index] = {pos = pos, name = name, parent = preview:GetBoneParent(index)}
                end
            end
            return results
        end
        local function mappedNames()
            local names = {}
            for _, name in ipairs(state.mapping) do
                if name and name ~= "" then names[string.lower(name)] = true end
            end
            return names
        end

        model.PaintOver = function(panel, w, h)
            fitOnResize()
            local step = math.max(8, math.floor(modelSpan / 9))
            local extent = step * 7
            for i = -7, 7 do
                local off = i * step
                local x1, y1 = projectedPoint(Vector(modelCenter.x + off, modelCenter.y - extent, modelFloor), w, h)
                local x2, y2 = projectedPoint(Vector(modelCenter.x + off, modelCenter.y + extent, modelFloor), w, h)
                if x1 and x2 then
                    surface.SetDrawColor(i == 0 and Color(130, 160, 195, 155) or Color(90, 125, 156, 85))
                    surface.DrawLine(x1, y1, x2, y2)
                end
                local a, b = projectedPoint(Vector(modelCenter.x - extent, modelCenter.y + off, modelFloor), w, h)
                local c, d = projectedPoint(Vector(modelCenter.x + extent, modelCenter.y + off, modelFloor), w, h)
                if a and c then
                    surface.SetDrawColor(i == 0 and Color(130, 160, 195, 155) or Color(90, 125, 156, 85))
                    surface.DrawLine(a, b, c, d)
                end
            end
            local cx, cy = w - 52, 57
            draw.RoundedBox(5, w - 101, 8, 93, 94, Color(10, 20, 30, 190))
            for _, axis in ipairs({
                {name = "X", dir = Vector(1, 0, 0), color = Color(252, 109, 109)},
                {name = "Y", dir = Vector(0, 1, 0), color = Color(100, 215, 110)},
                {name = "Z", dir = Vector(0, 0, 1), color = Color(115, 171, 255)}
            }) do
                local p, q = projectedPoint(modelCenter + axis.dir * modelSpan * 0.26, w, h)
                local o, r = projectedPoint(modelCenter, w, h)
                if p and o then
                    local dx, dy = p - o, q - r
                    local length = math.sqrt(dx * dx + dy * dy)
                    if length > 0.001 then
                        dx, dy = dx / length * 27, dy / length * 27
                        surface.SetDrawColor(axis.color)
                        surface.DrawLine(cx, cy, cx + dx, cy + dy)
                        draw.SimpleTextOutlined(axis.name, "DermaDefaultBold", cx + dx * 1.28, cy + dy * 1.28, axis.color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
                    end
                end
            end
            local points = getPreviewPoints()
            local mapped = mappedNames()
            local activeName = string.lower(state.mapping[state.selected] or "")
            local pickedName = state.mode == "manual" and string.lower(state.pendingBone or state.lastMappedBone or "") or ""
            state.screenPoints = {}
            local visible = {}
            for index, entry in pairs(points) do
                local mappedBone = mapped[string.lower(entry.name)]
                if (state.mode == "manual" and (state.showAllBones or string.lower(entry.name) == pickedName)) or mappedBone then
                    local x, y = projectedPoint(entry.pos, w, h)
                    if x and x >= 6 and x <= w - 6 and y >= 8 and y <= h - 8 then
                        visible[index] = {x = x, y = y}
                        state.screenPoints[#state.screenPoints + 1] = {x = x, y = y, name = entry.name, index = index}
                    end
                end
            end
            for index, point in pairs(visible) do
                local parent = points[index] and points[index].parent
                local parentPt = parent and visible[parent]
                if parentPt then
                    surface.SetDrawColor(boneLink)
                    surface.DrawLine(point.x, point.y, parentPt.x, parentPt.y)
                end
            end
            for _, point in ipairs(state.screenPoints) do
                local key = string.lower(point.name)
                local isPicked = pickedName ~= "" and key == pickedName
                local isSelected = key == activeName
                local isMapped = mapped[key]
                local c = isPicked and pickedGreen or (isSelected and selectedColor or (isMapped and mappedDot or boneDot))
                if isPicked then
                    surface.SetDrawColor(pickedHalo)
                    surface.DrawRect(point.x - 9, point.y - 9, 18, 18)
                    surface.SetDrawColor(pickedGreen)
                    surface.DrawOutlinedRect(point.x - 9, point.y - 9, 18, 18, 2)
                end
                surface.SetDrawColor(c)
                local radius = isPicked and 5 or (isSelected and 5 or 3)
                surface.DrawRect(point.x - radius, point.y - radius, radius * 2, radius * 2)
                if isPicked or isSelected then
                    draw.SimpleTextOutlined(point.name .. (isPicked and "  [SELECTED]" or ""),
                        "DermaDefaultBold", point.x + 12, point.y - 10,
                        c, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black)
                end
            end
            if state.mode == "manual" and pickedName ~= "" then
                local labelText = "SELECTED BONE: " .. (state.pendingBone or state.lastMappedBone or "")
                local labelWidth = math.max(150, math.min(w - 18, 550))
                draw.RoundedBox(5, 8, 50, labelWidth, 42, Color(7, 43, 22, 236))
                draw.SimpleText(labelText, "DermaDefaultBold", 15, 58, pickedGreen)
                draw.SimpleText(state.pendingBone and "Press Map Selected Bone to confirm" or "Last accepted selection (green)",
                    "DermaDefault", 15, 75, Color(204, 255, 218))
            end
            draw.RoundedBox(4, 8, 8, 270, 37, Color(12, 18, 28, 200))
            draw.SimpleText("MODEL BONES OVERLAY", "DermaDefaultBold", 15, 14, Color(185, 221, 255))
            local hint = state.mode == "manual"
                and (state.showAllBones and "Click to SELECT, then Map Selected Bone below" or "Manual: enable Show all to select bones")
                or "Auto Detect: current mapping (read-only)"
            draw.SimpleText(hint, "DermaDefault", 15, 29, color_white)
        end

        model.OnMousePressed = function(panel, mouseCode)
            if mouseCode == MOUSE_RIGHT then
                if camera.flat then
                    status:SetText("Uncheck Flat front view to orbit around the model")
                    return
                end
                camera.drag = true
                camera.previousX, camera.previousY = panel:CursorPos()
                panel:MouseCapture(true)
                return
            end
            if mouseCode ~= MOUSE_LEFT then return end
            if state.mode ~= "manual" then
                status:SetText("Switch to Manual to assign model bones") return
            end
            local mx, my = panel:CursorPos()
            local nearest, dist = nil, math.huge
            for _, point in ipairs(state.screenPoints or {}) do
                local d = (mx - point.x) ^ 2 + (my - point.y) ^ 2
                if d < dist then nearest, dist = point, d end
            end
            if nearest and dist <= 240 then
                state.pendingBone = nearest.name
                state.lastMappedBone = nil
                state.lastMapMessage = nil
                notification.AddLegacy("Selected bone: " .. nearest.name .. " | Press Map Selected Bone", NOTIFY_GENERIC, 3)
                if state.refresh then state.refresh() end
            end
        end

        -- Preview-only limb swing test: moves the DModelPanel preview's
        -- ANIMATION bones only, so you can confirm you mapped the right
        -- limb before touching the real ragdoll's physics at all.
        local testRoles = {4, 5, 6, 7, 10, 11, 12, 13}
        local testDuration = 2.2
        local function clearTestAngles()
            if not IsValid(model.Entity) then return end
            local affected = {}
            for _, role in ipairs(testRoles) do
                local idx = GetBoneIndexByName(model.Entity, state.mapping[role] or "")
                if idx >= 0 then affected[idx] = true end
            end
            for idx in pairs(affected) do
                model.Entity:ManipulateBoneAngles(idx, Angle(0, 0, 0))
            end
            if model.Entity.InvalidateBoneCache then model.Entity:InvalidateBoneCache() end
        end
        testButton.DoClick = function()
            state.testActive = not state.testActive
            state.testStart = RealTime()
            if not state.testActive then clearTestAngles() end
            testButton:SetText(state.testActive and "Stop Limb Check" or "Limb Check (mapping)")
            status:SetText(state.testActive and "Rig test running on PREVIEW ONLY; limbs animate one at a time" or "Rig test stopped")
        end
        model.Think = function(panel)
            fitOnResize()
            if not state.testActive or not IsValid(panel.Entity) then return end
            local elapsed = RealTime() - state.testStart
            local step = math.floor(elapsed / testDuration) % #testRoles + 1
            local phase = (elapsed % testDuration) / testDuration
            local role = testRoles[step]
            local amplitudes = {[4] = 35, [5] = 35, [6] = 48, [7] = 48, [10] = 30, [11] = 30, [12] = 44, [13] = 44}
            for _, roleIndex in ipairs(testRoles) do
                local boneName = state.mapping[roleIndex] or ""
                local boneIndex = GetBoneIndexByName(panel.Entity, boneName)
                if boneIndex >= 0 then
                    local amount = (roleIndex == role) and math.sin(phase * math.pi * 2) * amplitudes[roleIndex] or 0
                    panel.Entity:ManipulateBoneAngles(boneIndex, Angle(amount, 0, 0))
                end
            end
            if panel.Entity.InvalidateBoneCache then panel.Entity:InvalidateBoneCache() end
            activeTestLabel:SetText("Moving: " .. LABELS[role] .. " (" .. (state.mapping[role] or "unmapped") .. ")")
        end
        model.OnRemove = function() state.testActive = false end

        -- Dance in Preview: the server runs the REAL conversion on an invisible
        -- duplicate ragdoll; this mirrors that duplicate's bones onto the
        -- preview model every frame.
        local mirrorCallback
        local function installMirror()
            if mirrorCallback or not IsValid(model.Entity) then return end
            local pe = model.Entity
            mirrorCallback = pe:AddCallback("BuildBonePositions", function(e, nbones)
                local c = state.mirror
                if not IsValid(c) or not IsValid(e) then return end
                c:SetupBones() -- keep the (hidden) source's bones current even though it is not drawn
                local rootC = c:GetBoneMatrix(0)
                local rootP = e:GetBoneMatrix(0)
                if not rootC or not rootP then return end
                local inv = rootC:GetInverse()
                if not inv then return end
                state.mirrorFrames = (state.mirrorFrames or 0) + 1
                for i = 0, nbones - 1 do
                    local m = c:GetBoneMatrix(i)
                    if m then
                        local fm = rootP * (inv * m)
                        e:SetBonePosition(i, fm:GetTranslation(), fm:GetAngles())
                    end
                end
            end)
        end
        local function stopDance(notifyServer)
            danceButton.running = false
            danceButton:SetText("Dance in Preview")
            state.mirror = nil
            if notifyServer and IsValid(ent) then
                net.Start(EDIT_DANCE) net.WriteEntity(ent) net.WriteBool(false) net.SendToServer()
            end
        end
        state.stopDance = stopDance
        danceButton.DoClick = function()
            if not IsValid(ent) then return end
            if danceButton.running then
                stopDance(true)
                status:SetText("Dance stopped")
                return
            end
            if liveTest.running then
                liveTest.running = false
                liveTest:SetText("Live Test (world ragdoll)")
            end
            danceButton.running = true
            danceButton:SetText("Stop Dance")
            status:SetText("Starting the test dance (apply the conversion first)...")
            net.Start(EDIT_DANCE) net.WriteEntity(ent) net.WriteBool(true) net.SendToServer()
        end
        state.onDanceReply = function(index)
            local tries = 0
            timer.Create("KinectDanceMirrorLookup", 0.1, 50, function()
                tries = tries + 1
                local c = Entity(index)
                if IsValid(c) and IsValid(model) and IsValid(model.Entity) then
                    installMirror()
                    state.mirror = c
                    state.mirrorFrames = 0
                    status:SetText("Dance preview running: this is the real conversion output on a hidden copy")
                    timer.Simple(1.5, function()
                        if danceButton.running and IsValid(status) and (state.mirrorFrames or 0) == 0 then
                            status:SetText("Dance is running on the server, but the preview did not receive bone data (callback not firing)")
                        end
                    end)
                    timer.Remove("KinectDanceMirrorLookup")
                elseif tries >= 50 then
                    stopDance(false)
                    status:SetText("Could not find the test ragdoll on the client")
                end
            end)
        end

        frame.OnRemove = function()
            state.testActive = false
            state.mirror = nil
            if IsValid(model.Entity) then clearTestAngles() end
            if editor == state then editor = nil end
            if IsValid(ent) then
                if liveTest.running then net.Start(EDIT_TESTRIG) net.WriteEntity(ent) net.WriteBool(false) net.SendToServer() end
                if danceButton.running then net.Start(EDIT_DANCE) net.WriteEntity(ent) net.WriteBool(false) net.SendToServer() end
                -- let go of the ragdoll we froze when the window opened
                net.Start(EDIT_POSE) net.WriteEntity(ent) net.WriteBool(false) net.SendToServer()
            end
        end

        setMappingMode("automatic")
        refresh()
    end

    net.Receive(EDIT_DANCE_REPLY, function()
        local index = net.ReadUInt(16)
        if editor and editor.onDanceReply then editor.onDanceReply(index) end
    end)

    net.Receive(EDIT_DIAG_REPLY, function()
        local filename = net.ReadString()
        local report = net.ReadString()
        local win = vgui.Create("DFrame")
        win:SetSize(math.min(ScrW() - 80, 1000), math.min(ScrH() - 80, 700))
        win:Center() win:SetTitle("Kinect | Physics and Builder Report")
        win:MakePopup()
        local topBar = vgui.Create("DPanel", win)
        topBar:Dock(TOP) topBar:SetTall(37)
        topBar.Paint = function() end
        local info = vgui.Create("DLabel", topBar)
        info:Dock(LEFT) info:SetWide(760) info:DockMargin(0, 8, 0, 0)
        info:SetText(" Saved on server in data/" .. filename)
        info:SetTextColor(Color(20, 28, 40))
        local copyButton = vgui.Create("DButton", topBar)
        copyButton:Dock(RIGHT) copyButton:SetWide(180) copyButton:DockMargin(0, 4, 0, 4)
        copyButton:SetText("Copy Report to Clipboard")
        copyButton.DoClick = function()
            SetClipboardText(report)
            copyButton:SetText("Copied!")
            timer.Simple(1.4, function()
                if IsValid(copyButton) then copyButton:SetText("Copy Report to Clipboard") end
            end)
        end
        local textBox = vgui.Create("DTextEntry", win)
        textBox:Dock(FILL) textBox:SetMultiline(true)
        textBox:SetText(report) textBox:SetEditable(false)
        print("[Kinect Diagnostic]", report)
    end)

    net.Receive(EDIT_VALIDATE_REPLY, function()
        local role = net.ReadUInt(5)
        local requested = net.ReadString()
        local ok = net.ReadBool()
        local message = net.ReadString()
        local canonical = net.ReadString()
        local phys = net.ReadInt(16)
        local state = editor
        if not state or not IsValid(state.frame) then return end
        if ok and state.mode == "manual" and state.selected == role and state.pendingBone == requested then
            state.mapping[role] = canonical
            state.pendingBone = nil
            state.lastMappedBone = requested
            state.lastMapMessage = message
            if state.refresh then state.refresh() end
        end
        if state.manualStatus and IsValid(state.manualStatus) then
            state.manualStatus:SetText((ok and "SUCCESS: " or "FAILED: ") .. message)
        end
        if state.frame and IsValid(state.frame) then
            notification.AddLegacy(message, ok and NOTIFY_GENERIC or NOTIFY_ERROR, 8)
            Derma_Message(message, ok and "Bone mapped successfully" or "Bone mapping rejected", "OK")
        end
        print("[Kinect Manual Map]", ok and "SUCCESS" or "FAILED", message)
    end)

    net.Receive(EDIT_RESULT, function()
        local ok = net.ReadBool()
        local msg = net.ReadString()
        if editor and IsValid(editor.frame) then
            notification.AddLegacy(msg, ok and NOTIFY_GENERIC or NOTIFY_ERROR, 8)
            if editor.refresh then editor.refresh() end
            if not ok then Derma_Message(msg, "Kinect mapping validation", "OK") end
        end
        print("[Kinect Editor]", ok and "SUCCESS" or "FAILED", msg)
    end)
end

properties.Add("kinect_skeleton_universal_editor_v1", {
    MenuLabel = "Convert Skeleton",
    Order = 23,
    MenuIcon = "icon16/wrench.png",
    Filter = function(self, ent, ply)
        return IsValid(ent) and ent:IsRagdoll() and (ent:GetBoneCount() or 0) > 0
    end,
    Action = function(self, ent)
        if CLIENT and openEditor then openEditor(ent) end
    end,
    Receive = function(self, len, ply) end
})

print("[Kinect Editor] Kinect Skeleton Converter loaded.")
