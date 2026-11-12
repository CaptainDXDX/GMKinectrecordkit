-- GMFT: server-side head-physics driver (smoothed, axis-corrected rotation)
-- Install at: garrysmod/addons/<your addon>/lua/autorun/server/smh_face_head_server.lua
-- Applies live webcam head rotation to a ragdoll. This does not write head movement to SMH keyframes.

if not SERVER then return end

local NET_NAME = "SMHFaceTracking_HeadRotationTest"
util.AddNetworkString(NET_NAME)

local saved = setmetatable({}, { __mode = "k" })
local MAX_PITCH = 25
local MAX_YAW = 35
local MAX_ROLL = 25
local STALE_AFTER = 2.5
local SMOOTH_SPEED = 9 -- higher = faster response, lower = smoother

-- On some Source ragdoll head physics objects, local pitch/yaw axes are
-- effectively exchanged relative to the tracker angles. Keep this mapping
-- isolated here so it is easy to adjust without changing face/eye tracking.
local SWAP_PITCH_YAW = true

local function GetHeadPhysics(ent)
    if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return nil end
    local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
    if not bone or bone < 0 then return nil end
    local physBone = ent:TranslateBoneToPhysBone(bone)
    if not physBone or physBone < 0 then return nil end
    local phys = ent:GetPhysicsObjectNum(physBone)
    if not IsValid(phys) then return nil end
    return phys, physBone, bone
end

local function Restore(ent, reason)
    local state = saved[ent]
    if not state then return end
    if IsValid(state.phys) and state.original then
        state.phys:SetAngles(state.original)
        state.phys:Wake()
    end
    saved[ent] = nil
    print("[SMH Face Server] Restored head physics for " .. tostring(ent) .. (reason and (" (" .. reason .. ")") or ""))
end

net.Receive(NET_NAME, function(_, ply)
    local ent = net.ReadEntity()
    local active = net.ReadBool()
    local requested = net.ReadAngle()

    if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return end
    if IsValid(ply) and ply:GetPos():DistToSqr(ent:GetPos()) > (2048 * 2048) then return end

    if not active then
        Restore(ent, "client reset")
        return
    end

    local phys = GetHeadPhysics(ent)
    if not IsValid(phys) then
        print("[SMH Face Server] Could not resolve head physics for " .. tostring(ent) .. " model=" .. tostring(ent:GetModel()))
        return
    end

    local state = saved[ent]
    if not state then
        local original = phys:GetAngles()
        state = {
            phys = phys,
            original = original,
            target = original,
            lastUpdate = CurTime(),
        }
        saved[ent] = state
    else
        state.phys = phys
        state.lastUpdate = CurTime()
    end

    local pitch = math.Clamp(requested.p, -MAX_PITCH, MAX_PITCH)
    local yaw = math.Clamp(requested.y, -MAX_YAW, MAX_YAW)
    local roll = math.Clamp(requested.r, -MAX_ROLL, MAX_ROLL)

    -- Compose the requested rotation in the head's ORIGINAL local orientation.
    -- This model/physics setup maps tracker yaw to the head physics pitch axis,
    -- so exchange pitch/yaw here. The tracker and client JSON remain unchanged.
    local localRotation
    if SWAP_PITCH_YAW then
        localRotation = Angle(yaw, pitch, roll)
    else
        localRotation = Angle(pitch, yaw, roll)
    end
    local _, targetAngle = LocalToWorld(vector_origin, localRotation, vector_origin, state.original)
    state.target = targetAngle
end)

hook.Add("Think", "SMHFaceTracking_HeadPhysicsSmooth", function()
    local now = CurTime()
    local blend = math.Clamp(FrameTime() * SMOOTH_SPEED, 0, 1)

    for ent, state in pairs(saved) do
        if not IsValid(ent) or now - (state.lastUpdate or 0) > STALE_AFTER then
            Restore(ent, "tracking timed out")
        elseif IsValid(state.phys) and state.target then
            -- Smoothly approach the target instead of snapping the physics object 30 times/sec.
            local current = state.phys:GetAngles()
            state.phys:SetAngles(LerpAngle(blend, current, state.target))
            state.phys:Wake()
        end
    end
end)

print("[GMFT Head Server] Live head-rotation helper loaded.")
