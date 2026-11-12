-- Kinect Physics Hierarchy Diagnostic 1.0 (SERVER)
-- Place in garrysmod/lua/autorun/server/ or an addon's lua/autorun/server/ folder.
-- Console: kinect_phys_capture before / kinect_phys_capture after
-- Aim at the SAME ragdoll. Exports snapshots and a comparison under data/kinect_physics_diagnostic/.
if not SERVER then return end

local snapshots = setmetatable({}, {__mode = 'k'})
local rootDir = 'kinect_physics_diagnostic'

local function vec(v)
    return {x=v.x, y=v.y, z=v.z}
end
local function angles(a)
    return {p=a.p, y=a.y, r=a.r}
end

local function physicsAncestor(ent, boneIndex, selfPhys)
    local visited = {}
    local parent = ent:GetBoneParent(boneIndex)
    for _ = 1, 128 do
        if not parent or parent < 0 or visited[parent] then break end
        visited[parent] = true
        local phys = ent:TranslateBoneToPhysBone(parent)
        if phys and phys >= 0 and phys ~= selfPhys then
            return phys, ent:GetBoneName(parent)
        end
        parent = ent:GetBoneParent(parent)
    end
    return nil, nil
end

local function snapshot(ent)
    local out = {
        model=ent:GetModel(), class=ent:GetClass(),
        entity_index=ent:EntIndex(), timestamp=os.date('!%Y-%m-%dT%H:%M:%SZ'),
        controller=IsValid(ent.MotionSensorController) and tostring(ent.MotionSensorController) or 'none',
        physics_count=ent:GetPhysicsObjectCount(), bodies={}
    }
    for i=0, ent:GetPhysicsObjectCount()-1 do
        local object=ent:GetPhysicsObjectNum(i)
        if IsValid(object) then
            local boneIndex=ent:TranslatePhysBoneToBone(i)
            local name=boneIndex >= 0 and ent:GetBoneName(boneIndex) or '(none)'
            local parent, parentName=physicsAncestor(ent,boneIndex,i)
            local p, a=object:GetPos(),object:GetAngles()
            out.bodies[#out.bodies+1]={index=i, bone_index=boneIndex, bone=name,
                parent_physics=parent, parent_bone=parentName,
                pos=vec(p), angles=angles(a), motion_enabled=object:IsMotionEnabled()}
        end
    end
    return out
end

local function toVec(t) return Vector(t.x,t.y,t.z) end
local function logComparison(before, after)
    print('[Kinect Physics] BEFORE -> AFTER (position displacement / relative angle differences)')
    for _,b in ipairs(before.bodies) do
        local a
        for _,candidate in ipairs(after.bodies) do
            if candidate.index==b.index then a=candidate break end
        end
        if a then
            local distance=toVec(a.pos):Distance(toVec(b.pos))
            local dp=math.AngleDifference(a.angles.p,b.angles.p)
            local dy=math.AngleDifference(a.angles.y,b.angles.y)
            local dr=math.AngleDifference(a.angles.r,b.angles.r)
            print(string.format('[Kinect Physics] %02d %-22s parent=%s moved=%.1f dAngles=(%.1f,%.1f,%.1f)',
                b.index,b.bone,tostring(b.parent_physics or '-'),distance,dp,dy,dr))
        end
    end
end

concommand.Add('kinect_phys_capture',function(ply,_,args)
    if not IsValid(ply) then print('[Kinect Physics] Run as a player in single-player') return end
    local phase=string.lower(args[1] or '')
    if phase ~= 'before' and phase ~= 'after' then
        print('[Kinect Physics] Usage: kinect_phys_capture before | after') return
    end
    local ent=ply:GetEyeTrace().Entity
    if not IsValid(ent) or not ent:IsRagdoll() then
        print('[Kinect Physics] Aim at the ragdoll first') return
    end
    file.CreateDir(rootDir)
    local snap=snapshot(ent)
    local path=rootDir..'/scout_'..ent:EntIndex()..'_'..phase..'.txt'
    file.Write(path,util.TableToJSON(snap,true))
    print('[Kinect Physics] Captured '..phase..' for '..snap.model..' ('..snap.physics_count..' bodies)')
    print('[Kinect Physics] Saved garrysmod/data/'..path)
    local state=snapshots[ent] or {}
    state[phase]=snap
    snapshots[ent]=state
    for _,b in ipairs(snap.bodies) do
        print(string.format('[Kinect Physics] %02d %-22s parent=%s (%s)',
            b.index,b.bone,tostring(b.parent_physics or '-'),b.parent_bone or '-'))
    end
    if state.before and state.after then
        logComparison(state.before,state.after)
        local report=rootDir..'/scout_'..ent:EntIndex()..'_comparison.txt'
        file.Write(report,util.TableToJSON({before=state.before,after=state.after},true))
        print('[Kinect Physics] Paired snapshots saved to garrysmod/data/'..report)
    end
end)
print('[Kinect Physics] Diagnostic loaded. Aim at ragdoll: kinect_phys_capture before / after')
