-- V12: upright translucent green diagnostic clone directly above the selected ragdoll.
-- V11: add safe in-world physics rig diagnostic on a temporary ragdoll clone.
-- V10 EXPERIMENTAL: diagnostic mode 0 by default; mode 1 is bounded live retargeting.
-- V9: experimental, safe baseline; do not test on important ragdolls.
--[[
    V7 EXPERIMENTAL: Kinect physics POSITION calibration.
    Stand in a neutral pose at first tracking frame. Movement is applied as
    displacement relative to first sensor pose; large pose mismatches can
    still produce incorrect anatomy. Original ValveBiped paths are unchanged.

    Valve Biped Kinect Skeleton Converter
    Original source:
    https://steamcommunity.com/profiles/76561198099466387/

    This version adds:
    - Better error checking
    - Debug messages
    - Safer bone handling
    - Validation of the received entity
]]

AddCSLuaFile()

------------------------------------------------------------
-- DEBUG
------------------------------------------------------------

local DEBUG = true

local function KinectDebug(...)
    if DEBUG then
        print("[Kinect Skeleton] ", ...)
    end
end

------------------------------------------------------------
-- BONE TABLE
------------------------------------------------------------

function GetBoneTable()

    local BoneTable = {

        ['ValveBiped.Bip01_Pelvis'] = 0,
        ['ValveBiped.Bip01_Spine4'] = 0,

        ['ValveBiped.Bip01_R_UpperArm'] = 0,
        ['ValveBiped.Bip01_L_UpperArm'] = 0,

        ['ValveBiped.Bip01_L_Forearm'] = 0,
        ['ValveBiped.Bip01_L_Hand'] = 0,

        ['ValveBiped.Bip01_R_Forearm'] = 0,
        ['ValveBiped.Bip01_R_Hand'] = 0,

        ['ValveBiped.Bip01_R_Thigh'] = 0,
        ['ValveBiped.Bip01_R_Calf'] = 0,

        ['ValveBiped.Bip01_Head1'] = 0,

        ['ValveBiped.Bip01_L_Thigh'] = 0,
        ['ValveBiped.Bip01_L_Calf'] = 0,
        ['ValveBiped.Bip01_L_Foot'] = 0,

        ['ValveBiped.Bip01_R_Foot'] = 0
    }

    return BoneTable
end

------------------------------------------------------------
-- ANATOMICAL ROLE RESOLUTION (Kinect v1 / Xbox 360)
-- Canonical ValveBiped names remain the keys expected by SetBuilder.
-- Candidate aliases are selected by physical anatomy, not model path.
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

-- Stable order ensures the same role receives each physics part every run.
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

-- V17: The direct animation->physics API gave inconsistent role indices on
-- HWM Scout in the V16 report. Resolve against the actual physics->model-bone
-- assignments and require an exact model bone match instead.
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

local function ResolveAnatomicalPhysics(ent, verbose)
    if not IsValid(ent) or not ent:IsRagdoll() then return nil, "Not a ragdoll" end
    local result, names, used = {}, {}, {}
    for _, role in ipairs(ROLE_ORDER) do
        local choices = ROLE_CANDIDATES[role]
        local selected, selectedName, modelBone
        local reason = "No matching animation bone"
        for _, candidate in ipairs(choices) do
            local idx = GetBoneIndexByName(ent, candidate)
            if idx >= 0 then
                local phys = ResolveExactPhysicsIndex(ent, idx)
                local obj = phys and phys >= 0 and ent:GetPhysicsObjectNum(phys) or nil
                if obj and obj:IsValid() then
                    if not used[phys] then
                        selected, selectedName, modelBone = phys, candidate, idx
                        break
                    else
                        reason = "Physics bone " .. phys .. " already assigned to " .. used[phys]
                    end
                else
                    reason = "Animation bone " .. candidate .. " has no valid physics object"
                end
            end
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

function IsModelValveBiped(ent)
    -- Menu filters run clientside; physics objects are not available reliably there.
    -- Validate only animation bone names here. Full physics validation occurs in Receive server-side.
    if not IsValid(ent) or not ent:IsRagdoll() then return false end
    for _, role in ipairs(ROLE_ORDER) do
        local matched = false
        for _, name in ipairs(ROLE_CANDIDATES[role]) do
            if GetBoneIndexByName(ent, name) >= 0 then matched = true break end
        end
        if not matched then return false end
    end
    return true
end

local function PrintModelDiagnostic(ent)
    if not IsValid(ent) then print("[Kinect Skeleton] Aim at a ragdoll first") return end
    print("[Kinect Skeleton] DIAGNOSTIC", ent:GetModel(), "physics objects", ent:GetPhysicsObjectCount())
    local mapping, err = ResolveAnatomicalPhysics(ent, true)
    print(mapping and "[Kinect Skeleton] All 15 Kinect v1 anatomical roles have unique physics bodies" or
        ("[Kinect Skeleton] Cannot build full skeleton: " .. (err or "unknown error")))
    if mapping then
        print("[Kinect Skeleton] NOTE: Physics orientation is not calibrated; a valid map does not guarantee untwisted limbs")
    end
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
-- CREATE SKELETON BUILDER
------------------------------------------------------------

-- Calibration is model-specific and server-authoritative. It is deliberately
-- never serialized as part of the bone-name mapping setup: orientations depend
-- on the ragdoll's world orientation when Kinect control begins.
local LIVE_CALIBRATION = {}
-- V10: independent reference-pose physics retargeter, Kinect v1.
-- Mode 0: hold initial physics reference pose (safe diagnostics).
-- Mode 1: retarget measured segment swing, bounded to 55 degrees.
-- The controller scales/positions pos[0] itself, so ALL returned positions
-- remain controller-relative and scale-free.
local RETARGET_MODE = SERVER and CreateConVar(
    "kinect_editor_retarget_mode", "1", FCVAR_ARCHIVE,
    "HWM retargeter: 0=reference-pose diagnostic, 1=bounded live limb swing"
) or nil
local MAX_ROOT_TRANSLATION = 32
local MAX_SWING_DEGREES = 55
local function SafeVector(v)
    if not v then return false end
    for _, n in ipairs({v.x, v.y, v.z}) do
        if not isnumber(n) or n ~= n or math.abs(n) > 100000 then return false end
    end
    return true
end
local function CopyVector(v) return Vector(v.x, v.y, v.z) end
local function CopyAngle(a) return Angle(a.p, a.y, a.r) end

-- Rotate a resting physics body's world orientation by the sensor limb's
-- change in direction. No ValveBiped Euler basis or bone-name-specific axes.
-- An upper-arm bone follows shoulder -> elbow; forearm follows elbow -> wrist.
local function SwingFromReference(restAngle, neutralDirection, currentDirection)
    if not SafeVector(neutralDirection) or not SafeVector(currentDirection) then
        return CopyAngle(restAngle)
    end
    if neutralDirection:LengthSqr() < 0.000001 or currentDirection:LengthSqr() < 0.000001 then
        return CopyAngle(restAngle)
    end
    local a, b = neutralDirection:GetNormalized(), currentDirection:GetNormalized()
    local cosine = math.Clamp(a:Dot(b), -1, 1)
    local degrees = math.deg(math.acos(cosine))
    local axis = a:Cross(b)
    if axis:LengthSqr() < 0.000001 then
        -- Opposite directions need an arbitrary perpendicular axis.
        if cosine > 0 then return CopyAngle(restAngle) end
        axis = a:Cross(Vector(0,0,1))
        if axis:LengthSqr() < 0.000001 then axis = a:Cross(Vector(0,1,0)) end
    end
    axis:Normalize()
    local out = CopyAngle(restAngle)
    out:RotateAroundAxis(axis, math.min(degrees, MAX_SWING_DEGREES))
    return out
end

local function IsValveBipedMapping(ent)
    return IsValid(ent) and GetBoneIndexByName(ent, "ValveBiped.Bip01_Pelvis") >= 0
end

function SetBuilder(tbl, mdl, fixed, targetRagdoll)

    if not tbl then
        print("[Kinect Skeleton] ERROR: Bone table is missing.")
        return
    end

    if not mdl then
        print("[Kinect Skeleton] ERROR: Model is missing.")
        return
    end

    --------------------------------------------------------
    -- MODEL BONE INDICES
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
    -- VERIFY BONE INDICES
    --------------------------------------------------------

    local requiredBones = {
        PLVS = PLVS,
        SPNE = SPNE,
        RSLD = RSLD,
        LSLD = LSLD,
        LARM = LARM,
        LHND = LHND,
        RARM = RARM,
        RHND = RHND,
        RTHY = RTHY,
        RCLF = RCLF,
        HEAD = HEAD,
        LTHY = LTHY,
        LCLF = LCLF,
        LFOT = LFOT,
        RFOT = RFOT
    }

    for name, index in pairs(requiredBones) do

        if index == nil or index < 0 then

            print(
                "[Kinect Skeleton] ERROR: Invalid physics bone:",
                name,
                index
            )

            return
        end
    end

    --------------------------------------------------------
    -- BUILDER
    --------------------------------------------------------

    -- A separate calibration per selected ragdoll, not per generic model.
    -- V18: Converted ValveBiped ragdolls MUST use the same calibrated
    -- physics-index builder as HWM ragdolls. V17 excluded the stock TF2 Scout.
    local needsCalibration = SERVER and IsValid(targetRagdoll)
    local calibration = nil
    if needsCalibration then
        calibration = {
            target = targetRagdoll, reference = {}, restPositions = {},
            neutralPositions = {}, neutralSensor = {}, initialized = false, lastStatus = 0,
            debug = {frames = 0, movedFrames = 0, rotations = 0,
                     sensorSegments = 0, lastReason = "waiting for Kinect callback",
                     lastRootDelta = 0, lastAngleDelta = 0, rawJointCount = 0, rawSegments = 0, source = "none", sampleLength = 0}
        }
        -- Include unmapped physics objects too (e.g., HWM collars) so the
        -- normalized solver can receive a complete resting orientation set.
        for index=0, targetRagdoll:GetPhysicsObjectCount()-1 do
            local obj = targetRagdoll:GetPhysicsObjectNum(index)
            if IsValid(obj) then
                calibration.reference[index] = CopyAngle(obj:GetAngles())
                calibration.restPositions[index] = CopyVector(obj:GetPos())
            end
        end
        LIVE_CALIBRATION[string.lower(mdl)] = calibration
        print("[Kinect Skeleton V19] Shared live physics-index tracking enabled (including ValveBiped):", mdl)
        print("[Kinect Skeleton V19] Reference physics pose captured:",
              mdl, "physics bodies:", table.Count(calibration.reference))
    end

    local Builder = {

        ----------------------------------------------------
        -- PRE POSITION
        ----------------------------------------------------

        PrePosition = function(self, sensor)

            if not sensor then
                return
            end

            local spinestretch =
                (sensor[SENSORBONE.SHOULDER] -
                 sensor[SENSORBONE.SPINE]) * 0.7

            sensor[SENSORBONE.SHOULDER]:Add(
                spinestretch * 0.7
            )

            sensor[SENSORBONE.SHOULDER_RIGHT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.SHOULDER_LEFT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.ELBOW_LEFT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.ELBOW_RIGHT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.WRIST_LEFT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.WRIST_RIGHT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.HAND_LEFT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.HAND_RIGHT]:Add(
                spinestretch
            )

            sensor[SENSORBONE.HEAD]:Add(
                spinestretch * 0.5
            )

            sensor[SENSORBONE.HIP_LEFT]:Add(
                spinestretch * 0.3
            )

            sensor[SENSORBONE.HIP_RIGHT]:Add(
                spinestretch * 0.3
            )

            sensor[SENSORBONE.KNEE_RIGHT]:Add(
                (
                    sensor[SENSORBONE.HIP_RIGHT] -
                    sensor[SENSORBONE.KNEE_RIGHT]
                ) * 0.2
            )

            sensor[SENSORBONE.KNEE_LEFT]:Add(
                (
                    sensor[SENSORBONE.HIP_LEFT] -
                    sensor[SENSORBONE.KNEE_LEFT]
                ) * 0.2
            )
        end,

        ----------------------------------------------------
        -- POSITION TABLE
        ----------------------------------------------------

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

        ----------------------------------------------------
        -- ANGLES TABLE
        ----------------------------------------------------

        AnglesTable = {

            [PLVS] = {
                from = LTHY,
                to = RTHY,
                up = 'hips_fwd'
            },

            [SPNE] = {
                from_sensor = SENSORBONE.HEAD,
                to_sensor = SENSORBONE.SPINE,
                up = 'chest_rgt'
            },

            [HEAD] = {
                from_sensor = SENSORBONE.HEAD,
                to_sensor = SENSORBONE.SHOULDER,
                up = 'chest_lft'
            },

            [RSLD] = {
                from = RARM,
                to = RSLD,
                up = 'chest_up'
            },

            [LSLD] = {
                from = LARM,
                to = LSLD,
                up = 'chest_dn'
            },

            [RARM] = {
                from = RHND,
                to = RARM,
                up_up = RSLD
            },

            [LARM] = {
                from = LHND,
                to = LARM,
                up_up = LSLD
            },

            [RTHY] = {
                from = RCLF,
                to = RTHY,
                up_up = SPNE
            },

            [RCLF] = {
                from = RFOT,
                to = RCLF,
                up_up = RTHY
            },

            [LTHY] = {
                from = LCLF,
                to = LTHY,
                up_up = SPNE
            },

            [LCLF] = {
                from = LFOT,
                to = LCLF,
                up_up = LTHY
            },

            [RHND] = {
                from_sensor = SENSORBONE.HAND_RIGHT,
                to_sensor = SENSORBONE.WRIST_RIGHT,
                up_lft = RARM
            },

            [LHND] = {
                from_sensor = SENSORBONE.HAND_LEFT,
                to_sensor = SENSORBONE.WRIST_LEFT,
                up_rgt = LARM
            }
        },

        ----------------------------------------------------
        -- COMPLETE
        ----------------------------------------------------

        Complete = function(self, player, sensor, rotation, pos, ang)

            if calibration then
                calibration.debug.frames = calibration.debug.frames + 1
                calibration.debug.lastReason = "callback received"
            end
            if not pos or not ang then
                if calibration then calibration.debug.lastReason = "missing position/angle table" end
                return
            end

            pos[SPNE] =
                LerpVector(
                    0.45,
                    pos[SPNE],
                    pos[HEAD]
                )

            ------------------------------------------------
            -- Lock feet to calves
            ------------------------------------------------

            if ang[LCLF] then

                ang[LFOT] =
                    ang[LCLF]:Right():AngleEx(
                        ang[LCLF]:Up()
                    ) + Angle(20, 0, 0)

            end

            if ang[RCLF] then

                ang[RFOT] =
                    ang[RCLF]:Right():AngleEx(
                        ang[RCLF]:Up()
                    ) + Angle(20, 0, 0)

            end

            -- V10 REFERENCE-POSE RETARGETING FOR NON-VALVEBIPED MODELS.
            -- Original AngleTable is used only to generate sensor points;
            -- all generated ValveBiped ANGLES are replaced below.
            if calibration and IsValid(calibration.target) then
                local controller = calibration.target.MotionSensorController
                -- Never feed a world position to the motion controller.
                -- It computes: worldRoot = controllerPos + pos[0] * scale.
                if not IsValid(controller) or not controller:GetNormalize() then
                    calibration.debug.lastReason = not IsValid(controller) and
                        "controller missing" or "Normalize disabled"
                    -- Do not move an incompatible controller configuration.
                    for k in pairs(pos) do pos[k] = nil end
                    for k in pairs(ang) do ang[k] = nil end
                    return
                end
                local scale = controller:GetScale()
                local center = controller:GetPos()
                local restRoot = calibration.restPositions[PLVS]
                if not SafeVector(center) or not SafeVector(restRoot)
                    or not isnumber(scale) or scale < 1 or scale > 512 then
                    calibration.debug.lastReason = "invalid controller origin/scale"
                    for k in pairs(pos) do pos[k] = nil end
                    for k in pairs(ang) do ang[k] = nil end
                    return
                end

                -- Save every incoming joint point before changing pos.
                local current = {}
                for k,v in pairs(pos) do
                    if SafeVector(v) then current[k] = CopyVector(v) end
                end
                if not calibration.initialized then
                    local count=0
                    for k,v in pairs(current) do
                        calibration.neutralPositions[k] = CopyVector(v)
                        count=count+1
                    end
                    if count >= 10 and current[PLVS] then
                        calibration.initialized = true
                        print("[Kinect Skeleton V10] Sensor reference captured:", count,
                              "mode:", RETARGET_MODE and RETARGET_MODE:GetInt() or 0)
                    else
                        calibration.debug.lastReason = "insufficient Kinect joint positions"
                        for k in pairs(pos) do pos[k]=nil end
                        for k in pairs(ang) do ang[k]=nil end
                        return
                    end
                end

                -- Read the ORIGINAL sensor skeleton by SENSORBONE index. The
                -- generated pos table is keyed by physics-body index instead;
                -- it is not a reliable source for measuring limb segments.
                local rawSensor = {}
                if istable(sensor) then
                    for joint, value in pairs(sensor) do
                        if isnumber(joint) and SafeVector(value) then
                            rawSensor[joint] = CopyVector(value)
                        end
                    end
                end
                calibration.debug.rawJointCount = table.Count(rawSensor)
                local rawEdges = {
                    {RSLD, SENSORBONE.SHOULDER_RIGHT, SENSORBONE.ELBOW_RIGHT},
                    {RARM, SENSORBONE.ELBOW_RIGHT, SENSORBONE.WRIST_RIGHT},
                    {LSLD, SENSORBONE.SHOULDER_LEFT, SENSORBONE.ELBOW_LEFT},
                    {LARM, SENSORBONE.ELBOW_LEFT, SENSORBONE.WRIST_LEFT},
                    {RTHY, SENSORBONE.HIP_RIGHT, SENSORBONE.KNEE_RIGHT},
                    {RCLF, SENSORBONE.KNEE_RIGHT, SENSORBONE.ANKLE_RIGHT},
                    {LTHY, SENSORBONE.HIP_LEFT, SENSORBONE.KNEE_LEFT},
                    {LCLF, SENSORBONE.KNEE_LEFT, SENSORBONE.ANKLE_LEFT},
                    {PLVS, SENSORBONE.HIP, SENSORBONE.SPINE},
                    {SPNE, SENSORBONE.SPINE, SENSORBONE.SHOULDER}
                }
                if not calibration.neutralSensorCaptured then
                    local usable = 0
                    for _, edge in ipairs(rawEdges) do
                        local a, b = rawSensor[edge[2]], rawSensor[edge[3]]
                        if a and b and (b-a):LengthSqr() > 0.000001 then
                            usable = usable + 1
                        end
                    end
                    if usable >= 5 then
                        calibration.neutralSensor = rawSensor
                        calibration.neutralSensorCaptured = true
                        print("[Kinect Skeleton V19] Raw sensor reference captured:",
                            table.Count(rawSensor), "joints;", usable, "limb segments")
                    end
                end
                local mode = RETARGET_MODE and RETARGET_MODE:GetInt() or 0
                local neutral = calibration.neutralPositions
                local desiredRoot = CopyVector(restRoot)
                if mode == 1 and current[PLVS] and neutral[PLVS] then
                    local delta = (current[PLVS] - neutral[PLVS]) * scale
                    if SafeVector(delta) then
                        if delta:Length() > MAX_ROOT_TRANSLATION then
                            delta = delta:GetNormalized() * MAX_ROOT_TRANSLATION
                        end
                        desiredRoot:Add(delta)
                    end
                end
                local relativeRoot = (desiredRoot - center) / scale
                if not SafeVector(relativeRoot) or relativeRoot:Length() > 1000 then
                    calibration.debug.lastReason = "root safety check rejected position"
                    for k in pairs(pos) do pos[k]=nil end
                    for k in pairs(ang) do ang[k]=nil end
                    return
                end

                -- Keep all 15 mapped bones valid for the builder and also
                -- carry the 19-body physics reference orientation set.
                -- With normalize=true, ONLY physics body 0 is directly positioned.
                local safeAnchor = current[PLVS] or Vector(1,1,1)
                for k in pairs(pos) do pos[k]=nil end
                for k in pairs(ang) do ang[k]=nil end
                for phys, restAngle in pairs(calibration.reference) do
                    pos[phys] = CopyVector(safeAnchor)
                    ang[phys] = CopyAngle(restAngle)
                end
                pos[PLVS] = relativeRoot

                calibration.debug.lastRootDelta = (desiredRoot - restRoot):Length()
                calibration.debug.lastReason = mode == 1 and "live retarget applied" or "mode 0 reference hold"
                if mode == 1 then
                    -- Use actual Kinect joint IDs, NOT the physics-indexed pos table.
                    local validSegments, changedSegments = 0, 0
                    local sensorSegments = 0
                    local maxAngle, sampleLength = 0, 0
                    for _,edge in ipairs(rawEdges) do
                        local phys, startJoint, endJoint = edge[1], edge[2], edge[3]
                        local a, b = rawSensor[startJoint], rawSensor[endJoint]
                        local na = calibration.neutralSensor[startJoint]
                        local nb = calibration.neutralSensor[endJoint]
                        if a and b then
                            local now = b-a
                            sampleLength = math.max(sampleLength, now:Length())
                            if now:LengthSqr() > 0.000001 then
                                sensorSegments = sensorSegments + 1
                            end
                            if calibration.reference[phys] and na and nb then
                                local initial = nb-na
                                if initial:LengthSqr() > 0.000001 and now:LengthSqr() > 0.000001 then
                                    local cosine = math.Clamp(initial:GetNormalized():Dot(now:GetNormalized()), -1, 1)
                                    local degrees = math.deg(math.acos(cosine))
                                    maxAngle = math.max(maxAngle, degrees)
                                    validSegments = validSegments + 1
                                    if degrees > 2 then changedSegments = changedSegments + 1 end
                                    ang[phys] = SwingFromReference(calibration.reference[phys],initial,now)
                                end
                            end
                        end
                    end
                    calibration.debug.source = "sensor[SENSORBONE]"
                    calibration.debug.rawSegments = sensorSegments
                    calibration.debug.sampleLength = sampleLength
                    calibration.debug.sensorSegments = validSegments
                    calibration.debug.rotations = changedSegments
                    calibration.debug.lastAngleDelta = maxAngle
                    if changedSegments > 0 then calibration.debug.movedFrames = calibration.debug.movedFrames + 1 end
                    if validSegments == 0 then
                        calibration.debug.lastReason = calibration.neutralSensorCaptured
                            and "raw Kinect limbs unavailable/zero-length"
                            or "waiting for usable raw Kinect joint reference"
                    end
                end
                -- Built-in Normalize will solve the constraint hierarchy, with
                -- pelvis location in controller coordinates and bounded swings.
            end
        end,

        ----------------------------------------------------
        -- MODEL CHECK
        ----------------------------------------------------

        IsApplicable = function(self, ent)

            if not IsValid(ent) then
                return false
            end

            local model = ent:GetModel()

            if not model then
                return false
            end

            if string.EndsWith(model, mdl) then
                return not calibration or ent == calibration.target
            end

            return false
        end
    }

    --------------------------------------------------------
    -- FIXED HAND MODE
    --------------------------------------------------------

    if fixed then

        Builder.AnglesTable[RHND] =
            Builder.AnglesTable[RARM]

        Builder.AnglesTable[LHND] =
            Builder.AnglesTable[LARM]

    end

    --------------------------------------------------------
    -- REGISTER BUILDER
    --------------------------------------------------------

    local name = "AnatomicalKinect_" .. mdl .. (fixed and "_fixed" or "_normal")

    list.Set(
        "SkeletonConvertor",
        name,
        Builder
    )

    print(
        "[Kinect Skeleton] Registered:",
        name
    )
end


-- Kinect v1 visual mapping editor (iteration 1)
-- The editor deliberately does not attempt model orientation calibration.
local EDIT_OPEN = "KinectEditor_Open_v1"
local EDIT_APPLY = "KinectEditor_Apply_v1"
local EDIT_RESULT = "KinectEditor_Result_v1"
local EDIT_RIG_TEST = "KinectEditor_TestInWorld_v11"
local EDIT_RIG_STATUS = "KinectEditor_InWorldStatus_v11"
local EDIT_DIAG = "KinectEditor_Diagnose_v16"
local EDIT_DIAG_REPLY = "KinectEditor_DiagReply_v16"

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
    util.AddNetworkString(EDIT_OPEN)
    util.AddNetworkString(EDIT_APPLY)
    util.AddNetworkString(EDIT_RESULT)

    util.AddNetworkString(EDIT_RIG_TEST)
    util.AddNetworkString(EDIT_RIG_STATUS)
    util.AddNetworkString(EDIT_DIAG)
    util.AddNetworkString(EDIT_DIAG_REPLY)


    -- V16 non-destructive server diagnostic. No RagdollSolve, positions, or rotations are changed.
    local function diagnostics(ply, ent, names)
        local out = {}
        local function add(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end out[#out+1]=table.concat(t," ") end
        add("KINECT MAPPING / PHYSICS DIAGNOSTIC V16")
        add("Model:",ent:GetModel()," entity:",ent:EntIndex())
        add("Physics bodies:",ent:GetPhysicsObjectCount()," animation bones:",ent:GetBoneCount())
        add("Registered by Apply Conversion:",ent.KinectEditorLastBuilderV16 or "NOT RECORDED - apply conversion first")
        -- This API reports the currently preferred builder name; active controllers may have cached an earlier builder.
        if motionsensor and motionsensor.ChooseBuilderFromEntity then
            local ok, chosen = pcall(motionsensor.ChooseBuilderFromEntity,ent)
            if ok then
                add("Current ChooseBuilderFromEntity selection:",tostring(chosen))
                if isstring(chosen) then
                    add("Chosen builder registered:",tostring(list.GetEntry("SkeletonConvertor",chosen) ~= nil))
                    add("Matches our Apply Conversion:",tostring(chosen==ent.KinectEditorLastBuilderV16))
                end
            else add("Builder selection call failed:",tostring(chosen)) end
        else add("ChooseBuilderFromEntity unavailable on this realm") end
        local ctrl=ent.MotionSensorController
        add("Attached Kinect controller:",IsValid(ctrl) and (ctrl:GetClass().." #"..ctrl:EntIndex()) or "none")
        if IsValid(ctrl) and ctrl.GetNormalize and ctrl.GetScale then
            add("Normalize:",tostring(ctrl:GetNormalize())," Scale:",tostring(ctrl:GetScale()))
            add("CAUTION: active controller may retain a builder chosen at attach time")
        end
        add("-----------------------------------------------")
        local byPhysics={}
        local failed=0
        for i,role in ipairs(ROLE_ORDER) do
            local boneName=names[i]
            local bone=GetBoneIndexByName(ent,boneName)
            local phys=ResolveExactPhysicsIndex(ent,bone)
            local valid=phys>=0 and IsValid(ent:GetPhysicsObjectNum(phys))
            if not valid then failed=failed+1 end
            if valid and byPhysics[phys] then failed=failed+1 end
            if valid then byPhysics[phys]=LABELS[i] end
            add(LABELS[i],"->",boneName,"anim:",bone,"exactPhys:",phys,"directAPIPhys:",bone>=0 and ent:TranslateBoneToPhysBone(bone) or -1,"valid:",tostring(valid))
        end
        add("Mapping warnings:",failed)
        add("V17 exact physics resolution: TranslatePhysBoneToBone is the authority for body identity.")
        add("-----------------------------------------------")
        add("PHYSICS HIERARCHY (nearest animation ancestor mapped to a physics body)")
        add("These are INFERRED parent links, NOT verified physics constraint links.")
        for phys=0,ent:GetPhysicsObjectCount()-1 do
            local modelBone=ent:TranslatePhysBoneToBone(phys)
            local name=modelBone>=0 and ent:GetBoneName(modelBone) or "(none)"
            local parent=-1
            local bone=modelBone
            local seen={}
            while bone and bone>=0 and not seen[bone] do
                seen[bone]=true
                bone=ent:GetBoneParent(bone)
                if bone and bone>=0 then
                    local p=ResolveExactPhysicsIndex(ent,bone)
                    if p and p>=0 and p~=phys then parent=p break end
                end
            end
            local obj=ent:GetPhysicsObjectNum(phys)
            local p=IsValid(obj) and obj:GetPos() or nil
            local a=IsValid(obj) and obj:GetAngles() or nil
            add("PHYS",phys,"modelBone",modelBone,tostring(name),"parentPhys",parent,
                "mappedRole",byPhysics[phys] or "(unmapped)",
                "pos",p and tostring(p) or "invalid", "angles",a and tostring(a) or "invalid")
        end
        add("-----------------------------------------------")
        add("REFERENCE POSE: snapshot only. No solver applied and no physics changed.")
        add("Compare this report before/after attaching Kinect to diagnose movement.")
        file.CreateDir("kinect_mapping_editor")
        file.CreateDir("kinect_mapping_editor/diagnostics")
        local filename="kinect_mapping_editor/diagnostics/"..string.gsub(ent:GetModel(),"[^%w]","_").."_"..os.time()..".txt"
        file.Write(filename,table.concat(out,"\n"))
        add("Saved:","garrysmod/data/"..filename)
        return table.concat(out,"\n"),filename
    end
    net.Receive(EDIT_DIAG,function(_,ply)
        local ent=net.ReadEntity()
        local count=net.ReadUInt(5)
        if not IsValid(ply) or not IsValid(ent) or not ent:IsRagdoll() then return end
        if ply:GetPos():DistToSqr(ent:GetPos())>1500*1500 then return end
        if count~=#ROLE_ORDER then return end
        local names={}
        for i=1,count do
            names[i]=net.ReadString()
            if #names[i]>128 then return end
        end
        local report,filename=diagnostics(ply,ent,names)
        print("[Kinect Diagnostic]",report)
        net.Start(EDIT_DIAG_REPLY)
        net.WriteString(filename)
        net.WriteString(string.sub(report,1,60000))
        net.Send(ply)
    end)

    -- V15: diagnostic motion on the SELECTED ragdoll, not a ghost copy.
    -- Uses the same solver operations as the standard Kinect motion controller.
    -- Does NOT read hardware Kinect input: controlled synthetic joint rotations.
    local rigTests = setmetatable({}, {__mode = "k"})
    local rigDuration = 3.3
    local TEST_LIFT = Vector(0, 0, 90) -- temporary viewing lift in Source units
    local rigStages = {
        {label="Reference pose hold", role=nil},
        {label="Left upper arm", role=4},
        {label="Right upper arm", role=5},
        {label="Left forearm", role=6},
        {label="Right forearm", role=7},
        {label="Left thigh", role=10},
        {label="Right thigh", role=11},
        {label="Left calf", role=12},
        {label="Right calf", role=13}
    }
    local function sendRigStatus(ply, active, message)
        if not IsValid(ply) then return end
        net.Start(EDIT_RIG_STATUS)
        net.WriteBool(active)
        net.WriteString(message)
        net.Send(ply)
    end
    local function stopRig(ply, reason)
        local state = rigTests[ply]
        if not state then
            if reason then sendRigStatus(ply,false,reason) end
            return
        end
        rigTests[ply] = nil
        local ent = state.target
        if IsValid(ent) then
            ent:SetRagdollBuildFunction(nil)
            -- Restore pre-test reference orientations, positions, and motion flags.
            -- This is best-effort: physics contacts/collisions may have changed the pose.
            for index, saved in pairs(state.reference) do
                local obj = ent:GetPhysicsObjectNum(index)
                if IsValid(obj) then
                    obj:EnableMotion(false)
                    obj:SetPos(saved.pos)
                    obj:SetAngles(saved.ang)
                    obj:SetVelocity(vector_origin)
                    obj:AddAngleVelocity(-obj:GetAngleVelocity())
                end
            end
            for index, saved in pairs(state.reference) do
                local obj = ent:GetPhysicsObjectNum(index)
                if IsValid(obj) then
                    if saved.gravity ~= nil then obj:EnableGravity(saved.gravity) end
                    obj:EnableMotion(saved.moving)
                    if saved.moving then obj:Wake() end
                end
            end
        end
        sendRigStatus(ply,false,reason or "In-game test stopped; reference pose restored")
    end
    hook.Add("PlayerDisconnected", "KinectEditor_StopRigOnLeave_V15", function(ply)
        stopRig(ply)
    end)
    net.Receive(EDIT_RIG_TEST, function(_, ply)
        if not IsValid(ply) then return end
        local start = net.ReadBool()
        if not start then stopRig(ply,"In-game test stopped; attempted pose restore") return end
        local target = net.ReadEntity()
        local count = net.ReadUInt(5)
        if not IsValid(target) or not target:IsRagdoll() or count ~= #ROLE_ORDER then
            sendRigStatus(ply,false,"Invalid ragdoll or bone count") return
        end
        if ply:GetPos():DistToSqr(target:GetPos()) > 1500*1500 then
            sendRigStatus(ply,false,"Move closer to the ragdoll") return
        end
        if IsValid(target.MotionSensorController) then
            sendRigStatus(ply,false,"Remove the live Kinect Motion Controller first; it would conflict with this test")
            return
        end
        for other, state in pairs(rigTests) do
            if other ~= ply and state.target == target then
                sendRigStatus(ply,false,"Another player is testing this ragdoll") return
            end
        end
        local mapped, used = {}, {}
        for i=1,count do
            local name = net.ReadString()
            if #name > 128 then sendRigStatus(ply,false,"Invalid bone name") return end
            local bone = GetBoneIndexByName(target,name)
            local phys = ResolveExactPhysicsIndex(target,bone)
            if not phys or phys < 0 or used[phys] or not IsValid(target:GetPhysicsObjectNum(phys)) then
                sendRigStatus(ply,false,"Mapping invalid: " .. LABELS[i] .. " -> " .. name)
                return
            end
            mapped[i]=phys
            used[phys]=true
        end
        if mapped[1] ~= 0 then
            sendRigStatus(ply,false,"Pelvis must map to physics root 0") return
        end
        stopRig(ply)
        local reference = {}
        for i=0,target:GetPhysicsObjectCount()-1 do
            local obj=target:GetPhysicsObjectNum(i)
            if IsValid(obj) then
                local a,p=obj:GetAngles(),obj:GetPos()
                reference[i]={ang=Angle(a.p,a.y,a.r),pos=Vector(p.x,p.y,p.z),
                    moving=obj:IsMotionEnabled(),
                    gravity=obj.IsGravityEnabled and obj:IsGravityEnabled() or true}
                -- The rig solver needs motion enabled even when the source was frozen.
                obj:EnableGravity(false)
                obj:EnableMotion(true)
                obj:Wake()
            end
        end
        if not reference[0] then
            sendRigStatus(ply,false,"Missing root physics body") return
        end
        local state={target=target,reference=reference,mapped=mapped,started=CurTime(),step=-1}
        rigTests[ply]=state
        target:SetRagdollBuildFunction(function(ragdoll)
            if rigTests[ply] ~= state or not IsValid(ragdoll) then return end
            local elapsed=CurTime()-state.started
            local stageIndex=(math.floor(elapsed/rigDuration) % #rigStages)+1
            local phase=(elapsed % rigDuration)/rigDuration
            local stage=rigStages[stageIndex]
            for i, saved in pairs(state.reference) do
                local desired=Angle(saved.ang.p,saved.ang.y,saved.ang.r)
                if stage.role and i == state.mapped[stage.role] then
                    desired:RotateAroundAxis(saved.ang:Right(), math.sin(phase*math.pi*2)*20)
                end
                ragdoll:SetRagdollAng(i,desired)
            end
            ragdoll:SetRagdollPos(0,state.reference[0].pos + TEST_LIFT)
            ragdoll:RagdollSolve()
            ragdoll:RagdollUpdatePhysics()
        end)
        sendRigStatus(ply,true,"Moving: Reference pose hold  |  Original physics freeze state will be restored")
    end)
    timer.Create("KinectEditor_RigWatch_V15",0.3,0,function()
        for ply,state in pairs(rigTests) do
            if not IsValid(ply) or not IsValid(state.target) then
                stopRig(ply,"Stopped: target no longer valid")
            else
                local elapsed=CurTime()-state.started
                local step=(math.floor(elapsed/rigDuration) % #rigStages)+1
                if step~=state.step then
                    state.step=step
                    sendRigStatus(ply,true,"Moving: " .. rigStages[step].label .. " (" .. step .. "/" .. #rigStages .. ")")
                    print("[Kinect Test Rig]",ply:Nick(),rigStages[step].label)
                end
                local root=state.target:GetPhysicsObjectNum(0)
                if IsValid(root) and root:GetPos():DistToSqr(state.reference[0].pos + TEST_LIFT)>200*200 then
                    stopRig(ply,"SAFETY STOP: root drift exceeded 200 units")
                end
            end
        end
    end)

    net.Receive(EDIT_APPLY, function(_, ply)
        local ent = net.ReadEntity()
        local fixed = net.ReadBool()
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
        local map, used = {}, {}
        for i=1,count do
            local boneName = net.ReadString()
            if #boneName > 128 then report(false, "Invalid bone name") return end
            local modelIndex = GetBoneIndexByName(ent, boneName)
            if modelIndex < 0 then
                report(false, LABELS[i] .. ": bone not found: " .. boneName)
                return
            end
            local physIndex = ResolveExactPhysicsIndex(ent,modelIndex)
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
            used[physIndex] = LABELS[i]
        end
        SetBuilder(map, ent:GetModel(), fixed, ent)
        ent.KinectEditorLastBuilderV16 = "AnatomicalKinect_" .. ent:GetModel() .. (fixed and "_fixed" or "_normal")
        report(true, "V18 shared live physics mapping registered for " .. ent:GetModel() .. ". Run Diagnose Conversion to verify correct body names.")
    end)
    concommand.Add("kinect_editor_calibration_status", function(ply)
        if not IsValid(ply) then return end
        local ent = ply:GetEyeTrace().Entity
        if not IsValid(ent) then print("[Kinect Skeleton] Aim at your ragdoll") return end
        local c = LIVE_CALIBRATION[string.lower(ent:GetModel() or "")]
        if not c then
            print("[Kinect Skeleton V19] No calibration found. Click Apply Conversion on this ragdoll again.")
            return
        end
        print("[Kinect Skeleton V19] Retargeter:", c.initialized and "REFERENCE CAPTURED" or "AWAITING SENSOR",
            "model:", ent:GetModel(), "physics reference bodies:", table.Count(c.reference),
            "sensor points:", table.Count(c.neutralPositions),
            "mode:", RETARGET_MODE and RETARGET_MODE:GetInt() or 0)
        if c.debug then
            print("[Kinect Skeleton V19] Live diagnostic:", c.debug.lastReason,
                "Complete calls:", c.debug.frames, "frames with moving segments:", c.debug.movedFrames,
                "usable limb segments:", c.debug.sensorSegments,
                "segments changed >2deg:", c.debug.rotations,
                "largest segment delta:", math.Round(c.debug.lastAngleDelta,1), "degrees",
                "root delta:", math.Round(c.debug.lastRootDelta,1))
        end
    end)
    concommand.Add("kinect_editor_live_debug", function(ply)
        if not IsValid(ply) then return end
        local ent = ply:GetEyeTrace().Entity
        if not IsValid(ent) or not ent:IsRagdoll() then
            print("[Kinect Skeleton V19] Aim at the converted ragdoll, then retry")
            return
        end
        local c = LIVE_CALIBRATION[string.lower(ent:GetModel() or "")]
        print("[Kinect Skeleton V19] model:",ent:GetModel(),
            "chosen converter:", motionsensor and motionsensor.ChooseBuilderFromEntity and
            tostring(motionsensor.ChooseBuilderFromEntity(ent)) or "unknown",
            "controller valid:", IsValid(ent.MotionSensorController))
        if not c then
            print("[Kinect Skeleton V19] NO CALIBRATION: Apply Conversion again on this entity")
            return
        end
        local d = c.debug
        print("[Kinect Skeleton V19] initialized:",c.initialized,
            "Complete calls:",d.frames,"reason:",d.lastReason,
            "segments valid:",d.sensorSegments,"moving:",d.rotations,
            "max angle delta:", math.Round(d.lastAngleDelta,1),
            "moving frames:",d.movedFrames)
        print("[Kinect Skeleton V19] raw Kinect joints:",d.rawJointCount,
            "raw nonzero segments:",d.rawSegments,"raw largest segment length:",
            math.Round(d.sampleLength or 0,3),"source:",d.source,
            "neutral raw capture:",tostring(c.neutralSensorCaptured or false))
        print("[Kinect Skeleton V19] Normalize:",
            IsValid(ent.MotionSensorController) and tostring(ent.MotionSensorController:GetNormalize()) or "no controller",
            "mode:", RETARGET_MODE and RETARGET_MODE:GetInt() or -1)
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
        -- A name can never contain a slash, dot, or parent directory component.
        return SETUP_DIR .. "/" .. cleanSetupName(name) .. ".txt"
    end
    local function safeBonePosition(ent, index)
        if not IsValid(ent) or not index or index < 0 then return nil end
        local matrix = ent:GetBoneMatrix(index)
        if matrix then return matrix:GetTranslation() end
        local p = ent:GetBonePosition(index)
        return p
    end
    local function autoMap(ent)
        local out = {}
        for i,role in ipairs(ROLE_ORDER) do
            local chosen = ""
            for _,alias in ipairs(ROLE_CANDIDATES[role]) do
                if GetBoneIndexByName(ent, alias) >= 0 then chosen = alias break end
            end
            out[i] = chosen
        end
        return out
    end
    openEditor = function(ent)
        if not IsValid(ent) then return end
        if editor and IsValid(editor.frame) then editor.frame:Remove() end
        local state = {target = ent, mapping = autoMap(ent), selected = 1, mode = "automatic", fixed = false, testActive = false, testStart = 0, showAllBones = false}
        editor = state
        local frame = vgui.Create("DFrame")
        state.frame = frame
        frame:SetSize(math.min(ScrW()-40,1100), math.min(ScrH()-50,760))
        frame:Center()
        frame:SetTitle("Kinect Skeleton Converter | Visual Bone Mapper (v14 - Selected Ragdoll Physics Test)")
        frame:SetSizable(true)
        frame:MakePopup()
        frame.OnRemove = function() if editor == state then editor = nil end end

        local top = vgui.Create("DPanel",frame)
        top:Dock(TOP)
        top:SetTall(170)
        top:DockMargin(8,4,8,4)
        local title = vgui.Create("DLabel",top)
        title:SetPos(12,6) title:SetSize(940,22)
        title:SetText("MODEL: " .. ent:GetModel())
        local info = vgui.Create("DLabel",top)
        info:SetPos(12,28) info:SetSize(950,19)
        info:SetText("Manual: select green Kinect joint, enable Show all model bones, then click a bone dot on the model.")
        -- Maintain readable control text against the default light Derma panels.
        title:SetTextColor(Color(16,22,34))
        info:SetTextColor(Color(28,35,48))
        local modeSelect = vgui.Create("DComboBox",top)
        modeSelect:SetPos(12,52) modeSelect:SetSize(190,24)
        modeSelect:SetValue("Automatic mapping")
        modeSelect:AddChoice("Automatic mapping", "automatic")
        modeSelect:AddChoice("Manual mapping", "manual")
        local autoButton = vgui.Create("DButton",top)
        autoButton:SetPos(210,52) autoButton:SetSize(150,24)
        autoButton:SetText("Auto-detect bones")
        local mirrorButton = vgui.Create("DButton",top)
        mirrorButton:SetPos(210,82) mirrorButton:SetSize(170,24)
        mirrorButton:SetText("Mirror Mapped Bones")
        local fixedBox = vgui.Create("DCheckBoxLabel",top)
        fixedBox:SetPos(375,54) fixedBox:SetText("Fixed-hand mode") fixedBox:SizeToContents()
        fixedBox:SetTextColor(Color(20,28,40))
        fixedBox.OnChange = function(_, checked) state.fixed = checked end

        local testButton = vgui.Create("DButton",top)
        testButton:SetPos(12,82) testButton:SetSize(150,24)
        testButton:SetText("Test Rig (preview)")

        local testWorldButton = vgui.Create("DButton",top)
        testWorldButton:SetPos(12,110)
        testWorldButton:SetSize(170,24)
        testWorldButton:SetText("Test In-Game Rig")
        local worldTestActive = false
        local worldTestStatus = vgui.Create("DLabel",top)
        worldTestStatus:SetPos(190,110)
        worldTestStatus:SetSize(790,24)
        worldTestStatus:SetText("Selected ragdoll test (no clone); press F6 to stop")
        worldTestStatus:SetTextColor(Color(20,32,45))
        state.worldStatus = worldTestStatus
        state.worldButton = testWorldButton
        testWorldButton.DoClick = function()
            if worldTestActive then
                net.Start(EDIT_RIG_TEST)
                net.WriteBool(false)
                net.SendToServer()
                return
            end
            if not IsValid(ent) then return end
            for i=1,#ROLE_ORDER do
                if not isstring(state.mapping[i]) or state.mapping[i] == "" then
                    worldTestStatus:SetText("Missing bone: " .. LABELS[i]) return
                end
            end
            Derma_Query(
                "The test will temporarily unfreeze the selected ragdoll, disable gravity, and hold it 90 units above its original position. " ..
                "Its original freeze/gravity state and pose will be restored on Stop where possible, but restoration isn't guaranteed. " ..
                "Use a disposable ragdoll and remove any live Kinect controller first.",
                "Test Selected Ragdoll",
                "Start Test", function()
                    if not IsValid(ent) then return end
                    net.Start(EDIT_RIG_TEST)
                    net.WriteBool(true)
                    net.WriteEntity(ent)
                    net.WriteUInt(#ROLE_ORDER,5)
                    for i=1,#ROLE_ORDER do net.WriteString(state.mapping[i]) end
                    net.SendToServer()
                    worldTestStatus:SetText("Starting real physics test...")
                end,
                "Cancel", function() end
            )
        end
        -- Keep the editor alive but hide it while the server drives the selected ragdoll.
        -- Unlike MakePopup(), the side button does NOT capture mouse or keyboard;
        -- normal mouse-look stays enabled. Hold C (context cursor) to click it,
        -- or press F6 to stop immediately.
        local sideStop = vgui.Create("DButton")
        sideStop:SetSize(170, 47)
        sideStop:SetText("STOP TEST  [F6]")
        sideStop:SetFont("DermaDefaultBold")
        sideStop:SetTextColor(Color(255,255,255))
        sideStop:SetVisible(false)
        sideStop:SetKeyboardInputEnabled(false)
        sideStop:SetDrawOnTop(true)
        sideStop.Paint = function(panel,w,h)
            draw.RoundedBox(8,0,0,w,h,Color(20,88,44,235))
            surface.SetDrawColor(126,245,146)
            surface.DrawOutlinedRect(0,0,w,h,2)
        end
        sideStop.Think = function(panel)
            panel:SetPos(ScrW()-panel:GetWide()-22, math.floor(ScrH()*0.44))
        end
        state.sideStop = sideStop
        -- HUD is passive, so normal mouse-look still works while the editor is hidden.
        local movingHud = vgui.Create("DPanel")
        movingHud:SetSize(355, 80)
        movingHud:SetVisible(false)
        movingHud:SetMouseInputEnabled(false)
        movingHud:SetKeyboardInputEnabled(false)
        movingHud:SetDrawOnTop(true)
        movingHud.stage = "Reference pose hold"
        movingHud.Think = function(panel)
            panel:SetPos(ScrW() - panel:GetWide() - 22, math.floor(ScrH() * 0.44) - 98)
        end
        movingHud.Paint = function(panel,w,h)
            draw.RoundedBox(8,0,0,w,h,Color(10,22,18,238))
            surface.SetDrawColor(88,220,130,240)
            surface.DrawOutlinedRect(0,0,w,h,2)
            draw.SimpleText("KINECT PHYSICS TEST", "DermaDefaultBold", 12,10,Color(125,255,158))
            draw.SimpleText(panel.stage, "DermaLarge", 12,34,Color(255,255,255))
        end
        state.movingHud = movingHud
        local function requestWorldStop()
            if not worldTestActive then return end
            net.Start(EDIT_RIG_TEST)
            net.WriteBool(false)
            net.SendToServer()
            if IsValid(sideStop) then sideStop:SetText("STOPPING...") end
        end
        sideStop.DoClick = requestWorldStop
        local wasF6Down = false
        state.testHotkeyName = "KinectEditor_F6Stop_" .. tostring(frame)
        hook.Add("Think",state.testHotkeyName,function()
            if not IsValid(frame) then
                hook.Remove("Think",state.testHotkeyName)
                if IsValid(sideStop) then sideStop:Remove() end
                if IsValid(movingHud) then movingHud:Remove() end
                return
            end
            local down = input.IsKeyDown(KEY_F6)
            if worldTestActive and down and not wasF6Down then
                requestWorldStop()
            end
            wasF6Down = down
        end)
        state.setWorldActive = function(active,msg)
            worldTestActive=active
            if IsValid(testWorldButton) then testWorldButton:SetText("Test In-Game Rig") end
            if IsValid(worldTestStatus) then worldTestStatus:SetText(msg) end
            if IsValid(movingHud) then
                movingHud.stage = string.gsub(msg or "Reference pose hold", "^Moving:%s*", "")
                movingHud:SetVisible(active)
            end
            if active then
                if IsValid(sideStop) then
                    sideStop:SetText("STOP TEST  [F6]")
                    sideStop:SetVisible(true)
                end
                -- Hide without destroying controls, mapping or camera state.
                frame:SetVisible(false)
                gui.EnableScreenClicker(false)
            else
                if IsValid(sideStop) then sideStop:SetVisible(false) end
                frame:SetVisible(true)
                frame:MakePopup()
                frame:MoveToFront()
            end
        end

        local showAll = vgui.Create("DCheckBoxLabel",top)
        showAll:SetPos(605,54) showAll:SetText("Show all model bones") showAll:SizeToContents()
        showAll:SetChecked(false)
        showAll:SetTextColor(Color(20,28,40))
        showAll.OnChange = function(_, checked)
            state.showAllBones = state.mode == "manual" and checked or false
        end
        showAll:SetVisible(false)
        local testHelp = vgui.Create("DLabel",top)
        testHelp:SetPos(390,84) testHelp:SetSize(610,19)
        testHelp:SetText("Rig test: preview only; physics unchanged")
        testHelp:SetTextColor(Color(26,38,52))
        local flatBox = vgui.Create("DCheckBoxLabel",top)
        flatBox:SetPos(12,143)
        flatBox:SetText("Flat front view (uncheck to orbit)")
        flatBox:SetTextColor(Color(20,28,40))
        flatBox:SizeToContents()
        flatBox:SetChecked(true)
        local activeTestLabel = vgui.Create("DLabel",top)
        activeTestLabel:SetPos(765,82) activeTestLabel:SetSize(285,23)
        activeTestLabel:SetText("Moving: none")
        activeTestLabel:SetTextColor(Color(12,65,115))
        local cameraHelp = vgui.Create("DLabel",top)
        cameraHelp:SetPos(300,142) cameraHelp:SetSize(680,22)
        cameraHelp:SetText("Right-drag: orbit XYZ   |   Wheel: zoom   |   Left-click: select bone")
        cameraHelp:SetTextColor(Color(25,35,47))

        local bottom = vgui.Create("DPanel",frame)
        bottom:Dock(BOTTOM) bottom:SetTall(125)
        bottom:DockMargin(8,3,8,6)
        local status = vgui.Create("DLabel",bottom)
        status:SetPos(8,4) status:SetSize(1000,23)
        status:SetText("Auto Detect active. Use Manual mode to edit bones; setups are saved locally as text files.")
        status:SetTextColor(Color(18,26,40))
        local apply = vgui.Create("DButton",bottom)
        apply:SetPos(8,36) apply:SetSize(220,32) apply:SetText("Apply Conversion")
        local save = vgui.Create("DButton",bottom)
        save:SetPos(240,36) save:SetSize(160,32) save:SetText("Save Setup")
        local load = vgui.Create("DButton",bottom)
        load:SetPos(412,36) load:SetSize(160,32) load:SetText("Load Setup")

        local diagnose = vgui.Create("DButton",bottom)
        diagnose:SetPos(8,78) diagnose:SetSize(220,32)
        diagnose:SetText("Diagnose Conversion")
        diagnose.DoClick=function()
            if not IsValid(ent) then status:SetText("Selected ragdoll no longer exists") return end
            net.Start(EDIT_DIAG)
            net.WriteEntity(ent)
            net.WriteUInt(#ROLE_ORDER,5)
            for i=1,#ROLE_ORDER do net.WriteString(state.mapping[i] or "") end
            net.SendToServer()
            status:SetText("Requesting read-only server physics report...")
        end

        local body = vgui.Create("DPanel",frame)
        body:Dock(FILL) body:DockMargin(8,0,8,0)
        body.Paint = function() end
        local left = vgui.Create("DPanel",body)
        left:Dock(LEFT) left:SetWide(260) left:DockMargin(0,0,6,0)
        local right = vgui.Create("DPanel",body)
        right:Dock(FILL)
        local green = Color(64,245,115)
        local selectedColor = Color(255,215,70)
        left.Paint = function(panel,w,h)
            draw.RoundedBox(6,0,0,w,h,Color(16,27,26))
            draw.SimpleText("KINECT V1 / A-POSE","DermaDefaultBold",12,12,green)
            for _,line in ipairs(JOINT_EDGES) do
                local a,b = JOINT_POINTS[line[1]],JOINT_POINTS[line[2]]
                surface.SetDrawColor(55,190,95)
                surface.DrawLine(a[1]*w,40+a[2]*(h-65),b[1]*w,40+b[2]*(h-65))
            end
            for i,p in ipairs(JOINT_POINTS) do
                local x,y=p[1]*w,40+p[2]*(h-65)
                draw.NoTexture()
                surface.SetDrawColor(i==state.selected and selectedColor or green)
                surface.DrawCircle(x,y,6, i==state.selected and selectedColor or green)
                if i==state.selected then draw.SimpleText(LABELS[i],"DermaDefault",8,h-17,selectedColor) end
            end
        end
        left.OnMousePressed = function(panel)
            if state.mode ~= "manual" then
                status:SetText("Auto Detect is active. Switch to Manual mapping to select joints.")
                return
            end
            local mx,my=panel:CursorPos()
            local w,h=panel:GetSize()
            local closest,d=1,math.huge
            for i,p in ipairs(JOINT_POINTS) do
                local x,y=p[1]*w,40+p[2]*(h-65)
                local dist=(mx-x)^2+(my-y)^2
                if dist<d then closest,d=i,dist end
            end
            if d < 600 then state.selected=closest if state.refresh then state.refresh() end end
        end

        local model = vgui.Create("DModelPanel",right)
        model:Dock(FILL)
        model:SetModel(ent:GetModel())
        model:SetFOV(35)
        model.LayoutEntity = function() end -- preview holds reference pose
        local camera = {yaw=0,pitch=0,distance=120,zoom=1,flat=true,drag=false}
        local modelCenter = Vector(0,0,42)
        local modelFloor = 0
        local modelSpan = 90
        if IsValid(model.Entity) then
            model.Entity:SetAngles(Angle(0,0,0))
            model.Entity:ResetSequence(0)
            model.Entity:SetupBones()
            local mn,mx = model.Entity:GetRenderBounds()
            modelCenter = (mn + mx) * 0.5
            modelFloor = mn.z - 1.0
            modelSpan = math.max(mx.x-mn.x,mx.y-mn.y,mx.z-mn.z,45)
        end
        local function updateCamera()
            if not IsValid(model) then return end
            local w,h=math.max(model:GetWide(),1),math.max(model:GetTall(),1)
            local hfov=math.rad(model:GetFOV())
            local vfov=2*math.atan(math.tan(hfov/2)*h/w)
            local halfHeight=modelSpan*0.52
            local halfWidth=modelSpan*0.44
            local fitDist=math.max(halfHeight/math.tan(vfov/2),halfWidth/math.tan(hfov/2)) * 1.30
            camera.distance=math.Clamp(fitDist*camera.zoom,30,5000)
            local yaw,pitch=math.rad(camera.yaw),math.rad(camera.pitch)
            local offset=Vector(math.cos(pitch)*math.cos(yaw),math.cos(pitch)*math.sin(yaw),math.sin(pitch))*camera.distance
            model:SetLookAt(modelCenter)
            model:SetCamPos(modelCenter+offset)
        end
        camera.update=updateCamera
        flatBox.OnChange=function(_,checked)
            camera.flat=checked
            if checked then camera.yaw=0 camera.pitch=0 end
            updateCamera()
        end
        model.OnMouseWheeled=function(_,delta)
            camera.zoom=math.Clamp(camera.zoom*math.pow(0.89,delta),0.30,3.5)
            updateCamera()
            return true
        end
        model.OnMouseReleased=function(_,code)
            if code==MOUSE_RIGHT then
                camera.drag=false
                model:MouseCapture(false)
            end
        end
        local originalOnCursorMoved=model.OnCursorMoved
        model.OnCursorMoved=function(panel,x,y)
            if camera.drag and not camera.flat then
                if camera.previousX then
                    camera.yaw=camera.yaw+(x-camera.previousX)*0.4
                    camera.pitch=math.Clamp(camera.pitch+(camera.previousY-y)*0.4,-75,75)
                    updateCamera()
                end
                camera.previousX,camera.previousY=x,y
            end
        end
        local lastW,lastH=0,0
        local function fitOnResize()
            if model:GetWide()~=lastW or model:GetTall()~=lastH then
                lastW,lastH=model:GetWide(),model:GetTall()
                updateCamera()
            end
        end
        updateCamera()
        -- V3: Model-bone overlay is projected through the same camera used by DModelPanel.
        -- Unlike V1's separate flat diagram, these markers track the 3D preview model.
        local boneDot = Color(80, 192, 255)
        local boneLink = Color(78, 172, 237, 130)
        local mappedDot = Color(66, 237, 136)
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
            for index = 0, (preview:GetBoneCount() or 0)-1 do
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
            -- Draw a perspective floor grid under the preview model. The overlay
            -- uses the same viewport projection as the selectable bone markers.
            local step = math.max(8, math.floor(modelSpan / 9))
            local extent = step * 7
            for i=-7,7 do
                local off=i*step
                local x1,y1=projectedPoint(Vector(modelCenter.x+off,modelCenter.y-extent,modelFloor),w,h)
                local x2,y2=projectedPoint(Vector(modelCenter.x+off,modelCenter.y+extent,modelFloor),w,h)
                if x1 and x2 then
                    surface.SetDrawColor(i==0 and Color(130,160,195,155) or Color(90,125,156,85))
                    surface.DrawLine(x1,y1,x2,y2)
                end
                local a,b=projectedPoint(Vector(modelCenter.x-extent,modelCenter.y+off,modelFloor),w,h)
                local c,d=projectedPoint(Vector(modelCenter.x+extent,modelCenter.y+off,modelFloor),w,h)
                if a and c then
                    surface.SetDrawColor(i==0 and Color(130,160,195,155) or Color(90,125,156,85))
                    surface.DrawLine(a,b,c,d)
                end
            end
            -- World XYZ camera guide in the top right (directions rotate with camera).
            local cx,cy=w-52,57
            draw.RoundedBox(5,w-101,8,93,94,Color(10,20,30,190))
            for _,axis in ipairs({{name="X",dir=Vector(1,0,0),color=Color(252,109,109)},
                                   {name="Y",dir=Vector(0,1,0),color=Color(100,215,110)},
                                   {name="Z",dir=Vector(0,0,1),color=Color(115,171,255)}}) do
                local p,q=projectedPoint(modelCenter+axis.dir*modelSpan*0.26,w,h)
                local o,r=projectedPoint(modelCenter,w,h)
                if p and o then
                    local dx,dy=p-o,q-r
                    local length=math.sqrt(dx*dx+dy*dy)
                    if length>0.001 then
                        dx,dy=dx/length*27,dy/length*27
                        surface.SetDrawColor(axis.color)
                        surface.DrawLine(cx,cy,cx+dx,cy+dy)
                        draw.SimpleTextOutlined(axis.name,"DermaDefaultBold",cx+dx*1.28,cy+dy*1.28,axis.color,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER,1,color_black)
                    end
                end
            end
            local points = getPreviewPoints()
            local mapped = mappedNames()
            local activeName = string.lower(state.mapping[state.selected] or "")
            state.screenPoints = {}
            local visible = {}
            for index, entry in pairs(points) do
                local mappedBone = mapped[string.lower(entry.name)]
                if (state.mode == "manual" and state.showAllBones) or mappedBone then
                    local x, y = projectedPoint(entry.pos, w, h)
                    if x and x >= 6 and x <= w-6 and y >= 8 and y <= h-8 then
                        visible[index] = {x=x, y=y}
                        state.screenPoints[#state.screenPoints+1] = {
                            x=x, y=y, name=entry.name, index=index
                        }
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
                local isSelected = string.lower(point.name) == activeName
                local isMapped = mapped[string.lower(point.name)]
                local c = isSelected and selectedColor or (isMapped and mappedDot or boneDot)
                surface.SetDrawColor(c)
                surface.DrawRect(point.x-(isSelected and 5 or 3),point.y-(isSelected and 5 or 3),isSelected and 10 or 6,isSelected and 10 or 6)
                if isSelected then
                    draw.SimpleTextOutlined(point.name, "DermaDefaultBold", point.x+9, point.y-10,
                        selectedColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, color_black)
                end
            end
            draw.RoundedBox(4,8,8,270,37,Color(12,18,28,200))
            draw.SimpleText("MODEL BONES OVERLAY", "DermaDefaultBold",15,14,Color(185,221,255))
            local hint = state.mode == "manual"
                and (state.showAllBones and "All bones: click to assign" or "Manual: enable Show all to map bones")
                or "Auto Detect: current mapping (read-only)"
            draw.SimpleText(hint, "DermaDefault",15,29,color_white)
        end
        model.OnMousePressed = function(panel, mouseCode)
            if mouseCode==MOUSE_RIGHT then
                if camera.flat then
                    status:SetText("Uncheck Flat front view to orbit around the model")
                    return
                end
                camera.drag=true
                camera.previousX,camera.previousY=panel:CursorPos()
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
                local d = (mx-point.x)^2+(my-point.y)^2
                if d < dist then nearest, dist = point, d end
            end
            if nearest and dist <= 240 then
                state.mapping[state.selected] = nearest.name
                if state.refresh then state.refresh() end
            end
        end
        -- Preview test: manipulate animation bones of the temporary DModelPanel entity ONLY.
        -- Each joint moves in isolation so users can identify swapped/twisted anatomy.
        -- This is not a physics simulation or a Kinect v1 rotation calibration.
        local testRoles = {4,5,6,7,10,11,12,13}
        local testDuration = 2.2
        local function clearTestAngles()
            if not IsValid(model.Entity) then return end
            local affected = {}
            for _, role in ipairs(testRoles) do
                local idx = GetBoneIndexByName(model.Entity, state.mapping[role] or "")
                if idx >= 0 then affected[idx] = true end
            end
            for idx in pairs(affected) do
                model.Entity:ManipulateBoneAngles(idx, Angle(0,0,0))
            end
            if model.Entity.InvalidateBoneCache then model.Entity:InvalidateBoneCache() end
        end
        testButton.DoClick = function()
            state.testActive = not state.testActive
            state.testStart = RealTime()
            if not state.testActive then clearTestAngles() end
            if not state.testActive then activeTestLabel:SetText("Moving: none") end
            testButton:SetText(state.testActive and "Stop Test Rig" or "Test Rig (preview)")
            status:SetText(state.testActive and "Rig test running on PREVIEW ONLY; limbs animate one at a time" or "Rig test stopped")
        end
        model.Think = function(panel)
            fitOnResize()
            if not state.testActive or not IsValid(panel.Entity) then return end
            local elapsed = RealTime() - state.testStart
            local step = math.floor(elapsed / testDuration) % #testRoles + 1
            local phase = (elapsed % testDuration) / testDuration
            local role = testRoles[step]
            local amplitudes = {[4]=35,[5]=35,[6]=48,[7]=48,[10]=30,[11]=30,[12]=44,[13]=44}
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
            status:SetText("PREVIEW test: " .. LABELS[role] .. " -> " .. (state.mapping[role] or "unmapped") .. " | STOP to reset")
        end
        model.OnRemove = function() state.testActive = false end
        frame.OnRemove = function()
            if state.testHotkeyName then hook.Remove("Think",state.testHotkeyName) end
            if IsValid(state.sideStop) then state.sideStop:Remove() end
            if IsValid(state.movingHud) then state.movingHud:Remove() end
            net.Start(EDIT_RIG_TEST)
            net.WriteBool(false)
            net.SendToServer()
            state.testActive = false
            if IsValid(model.Entity) then clearTestAngles() end
            if editor == state then editor = nil end
        end
        local picker = vgui.Create("DComboBox",bottom)
        picker:SetPos(630,37) picker:SetSize(310,30)
        picker:SetVisible(false)
        picker:SetEnabled(false)
        local names={}
        for i=0,(ent:GetBoneCount() or 0)-1 do
            local name=ent:GetBoneName(i)
            if name and name~="__INVALIDBONE__" then names[#names+1]=name end
        end
        table.sort(names)
        for _,name in ipairs(names) do picker:AddChoice(name) end
        picker.OnSelect=function(_,_,_,value)
            if state.mode~="manual" then status:SetText("Switch to Manual mode first") return end
            state.mapping[state.selected]=value
            if state.refresh then state.refresh() end
        end
        local function refresh()
            local role=LABELS[state.selected]
            local bone=state.mapping[state.selected] or ""
            status:SetText(role .. "  ->  " .. (bone~="" and bone or "UNMAPPED") .. "  | Mode: " .. state.mode)
            picker:SetValue(bone ~= "" and bone or "Choose a bone...")
        end
        state.refresh=refresh
        local function setMappingMode(mode)
            state.mode = mode == "manual" and "manual" or "automatic"
            local manual = state.mode == "manual"
            picker:SetVisible(manual)
            picker:SetEnabled(manual)
            showAll:SetVisible(manual)
            showAll:SetEnabled(manual)
            if not manual then
                state.showAllBones = false
                showAll:SetChecked(false)
            end
            refresh()
        end
        modeSelect.OnSelect=function(_,_,_,mode)
            setMappingMode(mode)
        end
        autoButton.DoClick=function()
            state.mapping=autoMap(ent)
            modeSelect:SetValue("Automatic mapping")
            setMappingMode("automatic")
        end
        -- Mirror = swap the left/right role assignments. Press again to undo.
        -- This does not reflect the model's geometry or calibrate Kinect axes.
        local mirrorPairs = {{4,5},{6,7},{8,9},{10,11},{12,13},{14,15}}
        mirrorButton.DoClick = function()
            if state.testActive then
                state.testActive = false
                clearTestAngles()
                testButton:SetText("Test Rig (preview)")
                activeTestLabel:SetText("Moving: none")
            end
            for _,pair in ipairs(mirrorPairs) do
                local left, right = pair[1], pair[2]
                state.mapping[left], state.mapping[right] = state.mapping[right], state.mapping[left]
            end
            refresh()
            status:SetText("Mirrored left/right role assignments. Click Mirror again to reverse. Check before Convert!")
        end
        save.DoClick = function()
            if not IsValid(ent) then status:SetText("Ragdoll no longer exists") return end
            Derma_StringRequest("Save Skeleton Setup", "Enter a name for this mapping setup:", "Scout HWM", function(input)
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
                    for i=1,#ROLE_ORDER do savedMapping[i] = state.mapping[i] or "" end
                    local data = {version=1, name=name, model=ent:GetModel(), mapping=savedMapping, fixed=state.fixed}
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
            listFrame:SetSize(550,390)
            listFrame:Center()
            listFrame:SetTitle("Load Kinect Mapping Setup")
            listFrame:MakePopup()
            local description = vgui.Create("DLabel",listFrame)
            description:Dock(TOP)
            description:SetTall(46)
            description:DockMargin(10,5,10,2)
            description:SetWrap(true)
            description:SetTextColor(Color(20,28,40))
            description:SetText("Select a saved setup. Bone names must exist on the currently selected ragdoll. Setups from different models are checked before loading.")
            local setupList = vgui.Create("DListView",listFrame)
            setupList:Dock(FILL)
            setupList:DockMargin(10,0,10,8)
            setupList:AddColumn("Setup name")
            setupList:AddColumn("Original model")
            local records = {}
            for _,filename in ipairs(filenames) do
                local path = SETUP_DIR .. "/" .. filename
                local raw = file.Read(path,"DATA")
                local decoded = raw and util.JSONToTable(raw)
                if istable(decoded) and istable(decoded.mapping) then
                    local idx = #records+1
                    records[idx] = decoded
                    local entry = setupList:AddLine(decoded.name or string.StripExtension(filename), decoded.model or "Unknown")
                    entry.setupIndex = idx
                end
            end
            local loadSelected = vgui.Create("DButton",listFrame)
            loadSelected:Dock(BOTTOM)
            loadSelected:DockMargin(10,0,10,10)
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
                local missing = {}
                local loaded = {}
                for i=1,#ROLE_ORDER do
                    local boneName = data.mapping[i]
                    if not isstring(boneName) or boneName == "" or GetBoneIndexByName(ent,boneName)<0 then
                        missing[#missing+1] = LABELS[i] .. " -> " .. tostring(boneName or "(none)")
                    else
                        loaded[i] = boneName
                    end
                end
                if #missing > 0 then
                    Derma_Message("This setup cannot be loaded onto the selected model. Missing bones:\n" .. table.concat(missing,"\n"), "Incompatible mapping", "OK")
                    return
                end
                -- Apply atomically only after all fifteen roles have passed validation.
                state.mapping = loaded
                if isbool(data.fixed) then
                    state.fixed = data.fixed
                    fixedBox:SetChecked(data.fixed)
                end
                modeSelect:SetValue("Manual mapping")
                setMappingMode("manual")
                if state.testActive then
                    state.testActive = false
                    clearTestAngles()
                    testButton:SetText("Test Rig (preview)")
                    activeTestLabel:SetText("Moving: none")
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
        -- Start in Auto Detect, with manual controls hidden.
        setMappingMode("automatic")
        apply.DoClick=function()
            if not IsValid(ent) then status:SetText("Ragdoll no longer exists") return end
            for i=1,#ROLE_ORDER do
                if not isstring(state.mapping[i]) or state.mapping[i]=="" then
                    status:SetText("Missing mapping: " .. LABELS[i]) return
                end
            end
            net.Start(EDIT_APPLY)
            net.WriteEntity(ent)
            net.WriteBool(state.fixed)
            net.WriteUInt(#ROLE_ORDER,5)
            for i=1,#ROLE_ORDER do net.WriteString(state.mapping[i]) end
            net.SendToServer()
            status:SetText("Validating 15 physics assignments on server...")
        end
        refresh()
    end
    net.Receive(EDIT_RIG_STATUS,function()
        local active=net.ReadBool()
        local message=net.ReadString()
        if editor and editor.setWorldActive then editor.setWorldActive(active,message) end
        print("[Kinect Test Rig]",message)
    end)
    net.Receive(EDIT_DIAG_REPLY,function()
        local filename=net.ReadString()
        local report=net.ReadString()
        local win=vgui.Create("DFrame")
        win:SetSize(math.min(ScrW()-80,1000),math.min(ScrH()-80,700))
        win:Center() win:SetTitle("Kinect V16 | Physics and Builder Report")
        win:MakePopup()
        local info=vgui.Create("DLabel",win)
        info:Dock(TOP) info:SetTall(37)
        info:SetText(" Saved on server in data/"..filename)
        info:SetTextColor(Color(20,28,40))
        local textBox=vgui.Create("DTextEntry",win)
        textBox:Dock(FILL) textBox:SetMultiline(true)
        textBox:SetText(report) textBox:SetEditable(false)
        print("[Kinect Diagnostic]",report)
    end)
    net.Receive(EDIT_RESULT,function()
        local ok=net.ReadBool()
        local msg=net.ReadString()
        if editor and IsValid(editor.frame) then
            -- Expose status directly through notification and keep editor open to fix mistakes.
            notification.AddLegacy(msg,ok and NOTIFY_GENERIC or NOTIFY_ERROR,8)
            if editor.refresh then editor.refresh() end
            if not ok then Derma_Message(msg,"Kinect mapping validation","OK") end
        end
        print("[Kinect Editor]",ok and "SUCCESS" or "FAILED",msg)
    end)
end

properties.Add("kinect_skeleton_universal_editor_v1",{
    MenuLabel="Convert Skeleton",
    Order=23,
    MenuIcon="icon16/wrench.png",
    Filter=function(self,ent,ply)
        return IsValid(ent) and ent:IsRagdoll() and (ent:GetBoneCount() or 0)>0
    end,
    Action=function(self,ent)
        if CLIENT and openEditor then openEditor(ent) end
    end,
    Receive=function(self,len,ply) end
})

print("[Kinect Editor] Kinect v1 visual skeleton mapping editor V15 loaded.")
