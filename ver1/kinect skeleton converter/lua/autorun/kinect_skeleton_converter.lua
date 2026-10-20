--[[
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
    ["ValveBiped.Bip01_Spine4"] = {"ValveBiped.Bip01_Spine4", "bip_spine_3", "bip_spine_2", "bip_spine_1", "spine_3", "spine_2"},
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
                local phys = ent:TranslateBoneToPhysBone(idx)
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
    -- Kept for compatibility with any other scripts calling this function.
    return ResolveAnatomicalPhysics(ent, false) ~= nil
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

if CLIENT then
    concommand.Add("kinect_skeleton_diagnose", function()
        local player = LocalPlayer()
        if not IsValid(player) then return end
        PrintModelDiagnostic(player:GetEyeTrace().Entity)
    end)
end

------------------------------------------------------------
-- CREATE SKELETON BUILDER
------------------------------------------------------------

function SetBuilder(tbl, mdl, fixed)

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

            if not pos or not ang then
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
                return true
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

------------------------------------------------------------
-- PROPERTY FILTER
------------------------------------------------------------

function PFilter(self, ent, ply)

    KinectDebug("PFilter called")

    --------------------------------------------------------
    -- MOTION SENSOR CHECK
    --------------------------------------------------------

    if not motionsensor then

        print(
            "[Kinect Skeleton] ERROR: motionsensor library is missing."
        )

        return false
    end

    if not motionsensor.IsAvailable() then

        print(
            "[Kinect Skeleton] Motion sensor is not available."
        )

        return false
    end

    --------------------------------------------------------
    -- ENTITY CHECK
    --------------------------------------------------------

    if not IsValid(ent) then
        return false
    end

    if not ent:IsRagdoll() then
        return false
    end

    --------------------------------------------------------
    -- BONE COUNT
    --------------------------------------------------------

    if ent:GetBoneCount() < 13 then

        print(
            "[Kinect Skeleton] Ragdoll has too few bones."
        )

        return false
    end

    --------------------------------------------------------
    -- VALVE BIPED CHECK
    --------------------------------------------------------

    if not IsModelValveBiped(ent) then return false end

    return true
end

------------------------------------------------------------
-- PROPERTY ACTION
------------------------------------------------------------

function PAction(self, ent)

    KinectDebug("PAction called")

    if not IsValid(ent) then

        print(
            "[Kinect Skeleton] ERROR: Invalid entity in PAction."
        )

        return
    end

    KinectDebug(
        "Sending entity:",
        ent,
        "Model:",
        ent:GetModel()
    )

    self:MsgStart()

    net.WriteEntity(ent)

    self:MsgEnd()

    KinectDebug("PAction finished")
end

------------------------------------------------------------
-- NORMAL HAND VERSION
------------------------------------------------------------

properties.Add(
    "kinect_skeleton_convertor_creator_valvebipeds",
    {

        MenuLabel =
            "Create Kinect Skeleton (Anatomical / Kinect v1)",

        Order = 23,

        MenuIcon =
            "icon16/emoticon_tongue.png",

        Filter = PFilter,

        Action = PAction,

        Receive = function(self, length, player)

            print(
                "[Kinect Skeleton] Receive called."
            )

            ------------------------------------------------
            -- READ ENTITY
            ------------------------------------------------

            local ent = net.ReadEntity()

            if not IsValid(ent) then

                print(
                    "[Kinect Skeleton] ERROR: Invalid entity received."
                )

                return
            end

            print(
                "[Kinect Skeleton] Received:",
                ent,
                "Model:",
                ent:GetModel()
            )

            ------------------------------------------------
            -- BUILD BONE TABLE
            ------------------------------------------------

            local t, err = ResolveAnatomicalPhysics(ent, true)
            if not t then
                print("[Kinect Skeleton] Conversion blocked:", err)
                return
            end

            ------------------------------------------------
            -- CREATE BUILDER
            ------------------------------------------------

            print(
                "[Kinect Skeleton] Creating skeleton converter..."
            )

            SetBuilder(
                t,
                ent:GetModel(),
                false
            )

            print(
                "[Kinect Skeleton] Skeleton converter created."
            )
        end
    }
)

------------------------------------------------------------
-- FIXED HAND VERSION
------------------------------------------------------------

properties.Add(
    "kinect_skeleton_convertor_creator_valvebipeds_handfixed",
    {

        MenuLabel =
            "Create Kinect Skeleton (Anatomical / Fixed Hand)",

        Order = 24,

        MenuIcon =
            "icon16/emoticon_tongue.png",

        Filter = PFilter,

        Action = PAction,

        Receive = function(self, length, player)

            print(
                "[Kinect Skeleton] Fixed-hand Receive called."
            )

            ------------------------------------------------
            -- READ ENTITY
            ------------------------------------------------

            local ent = net.ReadEntity()

            if not IsValid(ent) then

                print(
                    "[Kinect Skeleton] ERROR: Invalid entity received."
                )

                return
            end

            print(
                "[Kinect Skeleton] Received:",
                ent,
                "Model:",
                ent:GetModel()
            )

            ------------------------------------------------
            -- BUILD BONE TABLE
            ------------------------------------------------

            local t, err = ResolveAnatomicalPhysics(ent, true)
            if not t then
                print("[Kinect Skeleton] Conversion blocked:", err)
                return
            end

            ------------------------------------------------
            -- CREATE BUILDER
            ------------------------------------------------

            print(
                "[Kinect Skeleton] Creating fixed-hand skeleton converter..."
            )

            SetBuilder(
                t,
                ent:GetModel(),
                true
            )

            print(
                "[Kinect Skeleton] Fixed-hand skeleton converter created."
            )
        end
    }
)

print(
    "[Kinect Skeleton] Valve Biped Kinect converter loaded."
)