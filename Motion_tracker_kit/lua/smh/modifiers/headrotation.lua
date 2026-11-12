-- SMH modifier: "Head rotation"
--
-- Stores the tracked head rotation as its own timeline option, separate from
-- "Physical Bones". Put it on its own timeline (with or without Facial flexes
-- and Eye target) and the head is rotated ON TOP of whatever pose the other
-- timelines give the ragdoll: body from a Kinect recording, head from the
-- webcam, each recorded and edited separately.
--
-- Install: garrysmod/addons/<your addon>/lua/smh/modifiers/headrotation.lua
-- Stop Motion Helper loads every file in lua/smh/modifiers/ automatically.

MOD.Name = "Head rotation"

-- Finds the head bone and its physics body on any rig.
local HEAD_NAMES = { "ValveBiped.Bip01_Head1", "bip_head", "Bip01_Head", "Bip01 Head", "Head", "head" }
local function headPhysIndex(entity)
    for _, name in ipairs(HEAD_NAMES) do
        local bone = entity:LookupBone(name)
        if bone and bone >= 0 then
            local pb = entity:TranslateBoneToPhysBone(bone)
            if pb and pb >= 0 then return pb end
        end
    end
    for bone = 0, (entity:GetBoneCount() or 0) - 1 do
        local name = string.lower(entity:GetBoneName(bone) or "")
        if string.find(name, "head", 1, true)
            and not string.find(name, "hat", 1, true)
            and not string.find(name, "prp_", 1, true)
            and not string.find(name, "headset", 1, true)
            and not string.find(name, "mic", 1, true) then
            local pb = entity:TranslateBoneToPhysBone(bone)
            if pb and pb >= 0 then return pb end
        end
    end
    return nil
end

-- Head rotation is defined by what the head DOES (yaw = turn, pitch = nod,
-- roll = tilt), using the model's "eyes" attachment as the reference, so it
-- works on any rig regardless of bone axis conventions.
local axisCache = {}
local ATTACH_NAMES = { "eyes", "forward", "head", "facial" }
local function localOffset(entity, off, pb)
    local ax = axisCache[entity]
    if ax == nil then
        ax = false
        local phys = entity:GetPhysicsObjectNum(pb)
        local att
        for _, name in ipairs(ATTACH_NAMES) do
            local id = entity:LookupAttachment(name)
            if id and id > 0 then
                att = entity:GetAttachment(id)
                if att then break end
            end
        end
        if IsValid(phys) and att then
            local headAng = phys:GetAngles()
            local function loc(v) return (WorldToLocal(v, angle_zero, vector_origin, headAng)) end
            ax = { up = loc(att.Ang:Up()), right = loc(att.Ang:Right()), fwd = loc(att.Ang:Forward()) }
        end
        axisCache[entity] = ax
    end
    if not ax then return off end
    local q = Angle(0, 0, 0)
    q:RotateAroundAxis(ax.up, off.y)
    q:RotateAroundAxis(ax.right, off.p)
    q:RotateAroundAxis(ax.fwd, off.r)
    return q
end

local function angNear(a, b)
    local function d(x, y) return math.abs(math.NormalizeAngle(x - y)) end
    return d(a.p, b.p) < 0.05 and d(a.y, b.y) < 0.05 and d(a.r, b.r) < 0.05
end

local pending = {}  -- entity -> { off = Angle, tick = engine tick it was last requested }
local state = {}    -- entity -> { base = Angle, lastSet = Angle }

-- Rotate the head from its CURRENT base pose. The base is whatever the other
-- modifiers just set; if the angle is the one we set last time, nothing else
-- has touched it and the old base is kept, so offsets never stack up.
local function applyHead(entity, off)
    local pb = headPhysIndex(entity)
    if not pb then return end
    local phys = entity:GetPhysicsObjectNum(pb)
    if not IsValid(phys) then return end

    local st = state[entity]
    if not st then
        st = {}
        state[entity] = st
    end
    local cur = phys:GetAngles()
    if not st.base or not st.lastSet or not angNear(cur, st.lastSet) then
        st.base = cur
    end
    local _, newAng = LocalToWorld(vector_origin, localOffset(entity, off, pb), phys:GetPos(), st.base)
    phys:SetAngles(newAng)
    phys:Wake()
    st.lastSet = phys:GetAngles()
end

-- SMH applies modifiers in no fixed order, so "Physical Bones" can overwrite the
-- head right after we rotated it. Hook its Load functions to re-apply our
-- offset once it is done (only while our own modifier is actively being played).
local patched = false
local function patchPhysBones()
    if patched then return end
    local pm = SMH and SMH.Modifiers and SMH.Modifiers["physbones"]
    if not pm then return end
    patched = true

    local function reapply(entity)
        local p = pending[entity]
        if p and engine.TickCount() - p.tick <= 2 then applyHead(entity, p.off) end
    end
    local origLoad, origBetween = pm.Load, pm.LoadBetween
    pm.Load = function(self, entity, data, settings)
        origLoad(self, entity, data, settings)
        reapply(entity)
    end
    pm.LoadBetween = function(self, entity, d1, d2, percentage, settings)
        origBetween(self, entity, d1, d2, percentage, settings)
        reapply(entity)
    end
end

local function request(entity, off)
    patchPhysBones()
    pending[entity] = { off = off, tick = engine.TickCount() }
    applyHead(entity, off)
end

hook.Add("EntityRemoved", "SMHHeadRotationCleanup", function(ent)
    pending[ent] = nil
    state[ent] = nil
    axisCache[ent] = nil
end)

-- ---------------------------------------------------------------------------

function MOD:Save(entity)
    if self:IsEffect(entity) then entity = entity.AttachedEntity end
    if not IsValid(entity) or not headPhysIndex(entity) then return nil end
    -- The live head helper keeps the current tracked rotation here; the face
    -- recorder overwrites it with the exact value for each recorded frame.
    local off = entity.SMHHeadRotationLive
    return { Off = off and Angle(off.p, off.y, off.r) or Angle(0, 0, 0) }
end

function MOD:Load(entity, data, settings)
    if self:IsEffect(entity) then entity = entity.AttachedEntity end
    if not IsValid(entity) or not data or not data.Off then return end
    request(entity, data.Off)
end

function MOD:LoadBetween(entity, data1, data2, percentage, settings)
    if self:IsEffect(entity) then entity = entity.AttachedEntity end
    if not IsValid(entity) or not data1 or not data2 or not data1.Off or not data2.Off then return end
    request(entity, LerpAngle(percentage, data1.Off, data2.Off))
end

-- Not meaningful for a rotation that is relative to the body pose.
function MOD:Offset(data) return data end
function MOD:OffsetDupe(entity, data) return data end
