
-- Keyframes Advanced Bonemerge gear from the character it's merged onto.
-- Merged items have zero-size collision bounds, so SMH can't select them by clicking; instead, keyframing the
-- ragdoll (or anything with merged children) records every merged item under it, including items merged onto
-- other merged items (e.g. NVG on helmet). Per item it stores:
--   * all bone manips, including the origin manip (bone -1) that moves the whole item
--   * AdvBone_BoneInfo (which parent bone each bone follows, and whether it follows its scale)
--   * the Invert and DisableBeardFlexifier toggles
-- Items are matched by their custom name (set in the Adv Bonemerge tool's model list) or, failing that, by model
-- path plus order, so naming gear before keyframing keeps saves stable.
-- SMH picks this file up automatically from any addon's lua/smh/modifiers/ folder.

MOD.Name = "Adv. Bonemerge Gear";

local BONEINFO_UPDATE = "AdvBone_EntBoneInfoTableUpdate_SendToCl";
local VEC_ONE = Vector(1, 1, 1);

local function IsAdvBone(entity)
    if not IsValid(entity) then return false end
    local class = entity:GetClass();
    return class == "ent_advbonemerge" or class == "prop_animated";
end

-- Returns { [key] = entity } for every merged item under root (and root itself if it is one)
local function CollectGear(root)

    local gear = {};

    local function Walk(entity, prefix)
        local kids = {};
        for _, child in ipairs(entity:GetChildren()) do
            if IsAdvBone(child) then table.insert(kids, child) end
        end
        table.sort(kids, function(a, b) return a:EntIndex() < b:EntIndex() end);

        local counts = {};
        for _, child in ipairs(kids) do
            local name = child:GetNWString("AdvBone_CustomName", "");
            if name == "" then name = tostring(child:GetModel()) end
            counts[name] = (counts[name] or 0) + 1;

            local key = prefix .. name .. "#" .. counts[name];
            gear[key] = child;
            Walk(child, key .. "/");
        end
    end

    if IsAdvBone(root) then
        gear["."] = root;
        Walk(root, "./");
    else
        Walk(root, "");
    end

    return gear;

end

local function SaveItem(entity)

    local d = {};

    -- only non-default manips, stored as a list so bone -1 survives the JSON round trip
    local manips = {};
    for b = -1, entity:GetBoneCount() - 1 do
        local pos = entity:GetManipulateBonePosition(b);
        local ang = entity:GetManipulateBoneAngles(b);
        local scale = entity:GetManipulateBoneScale(b);
        if pos ~= vector_origin or ang ~= angle_zero or scale ~= VEC_ONE then
            table.insert(manips, { Bone = b, Pos = pos, Ang = ang, Scale = scale });
        end
    end
    d.Manips = manips;

    local info = {};
    if entity.AdvBone_BoneInfo then
        for id, entry in pairs(entity.AdvBone_BoneInfo) do
            table.insert(info, { Bone = id, Parent = entry.parent, Scale = entry.scale });
        end
    end
    d.BoneInfo = info;

    if entity.GetInvert then
        d.Invert = entity:GetInvert();
    end
    d.NoBeardFlex = entity:GetNWBool("DisableBeardFlexifier");

    return d;

end

local function ManipMap(d)
    local map = {};
    for _, m in ipairs(d.Manips) do
        map[m.Bone] = m;
    end
    return map;
end

-- Adv Bonemerge overrides these to handle networking and waking up its bone builder; unchanged values aren't resent
local function ApplyBone(entity, b, pos, ang, scale)
    entity:ManipulateBonePosition(b, pos);
    entity:ManipulateBoneAngles(b, ang);
    entity:ManipulateBoneScale(b, scale);
end

-- Non-interpolatable values: snapped to whichever keyframe is active
local function ApplyStepped(entity, d)

    local info = entity.AdvBone_BoneInfo;
    if info and d.BoneInfo then

        local changed = false;

        for _, e in ipairs(d.BoneInfo) do
            local cur = info[e.Bone];
            if cur and (cur.parent ~= e.Parent or cur.scale ~= e.Scale) then
                cur.parent = e.Parent;
                cur.scale = e.Scale;
                changed = true;
            end
        end

        if changed then
            -- same as the tool does after editing BoneInfo: mark non-default, tell clients to refetch, wake up
            if IsValid(entity:GetParent()) then
                entity.AdvBone_BoneInfo_IsDefault = false;
            end

            if util.NetworkStringToID(BONEINFO_UPDATE) ~= 0 then
                net.Start(BONEINFO_UPDATE);
                    net.WriteEntity(entity);
                net.Broadcast();
            end

            if AdvBone_ResetBoneChangeTime then AdvBone_ResetBoneChangeTime(entity); end
            if AdvBone_ResetBoneChangeTimeOnChildren then AdvBone_ResetBoneChangeTimeOnChildren(entity, true); end
        end

    end

    if d.Invert ~= nil and entity.SetInvert and entity:GetInvert() ~= d.Invert then
        entity:SetInvert(d.Invert);
    end

    if d.NoBeardFlex ~= nil and entity:GetNWBool("DisableBeardFlexifier") ~= d.NoBeardFlex then
        entity:SetNWBool("DisableBeardFlexifier", d.NoBeardFlex);
    end

end

local function LoadItem(entity, d)

    local map = ManipMap(d);

    for b = -1, entity:GetBoneCount() - 1 do
        local m = map[b];
        if m then
            ApplyBone(entity, b, m.Pos, m.Ang, m.Scale);
        else
            ApplyBone(entity, b, vector_origin, angle_zero, VEC_ONE);
        end
    end

    ApplyStepped(entity, d);

end

local function LoadItemBetween(entity, d1, d2, percentage)

    local map1, map2 = ManipMap(d1), ManipMap(d2);

    for b = -1, entity:GetBoneCount() - 1 do
        local m1, m2 = map1[b], map2[b];

        local pos1, ang1, scale1 = vector_origin, angle_zero, VEC_ONE;
        if m1 then pos1, ang1, scale1 = m1.Pos, m1.Ang, m1.Scale end
        local pos2, ang2, scale2 = vector_origin, angle_zero, VEC_ONE;
        if m2 then pos2, ang2, scale2 = m2.Pos, m2.Ang, m2.Scale end

        local Pos = SMH.LerpLinearVector(pos1, pos2, percentage);
        local Ang = SMH.LerpLinearAngle(ang1, ang2, percentage);
        local Scale = SMH.LerpLinearVector(scale1, scale2, percentage);

        ApplyBone(entity, b, Pos, Ang, Scale);
    end

    ApplyStepped(entity, d1);

end

function MOD:Save(entity)

    if self:IsEffect(entity) then
        entity = entity.AttachedEntity;
    end

    local gear = CollectGear(entity);
    if next(gear) == nil then return nil; end

    local data = {};
    for key, item in pairs(gear) do
        data[key] = SaveItem(item);
    end

    return data;

end

function MOD:Load(entity, data)

    if not data then return; end

    if self:IsEffect(entity) then
        entity = entity.AttachedEntity;
    end

    for key, item in pairs(CollectGear(entity)) do
        if data[key] then
            LoadItem(item, data[key]);
        end
    end

end

function MOD:LoadBetween(entity, data1, data2, percentage)

    if not data1 or not data2 then return; end

    if self:IsEffect(entity) then
        entity = entity.AttachedEntity;
    end

    for key, item in pairs(CollectGear(entity)) do
        local d1, d2 = data1[key], data2[key];
        if d1 and d2 then
            LoadItemBetween(item, d1, d2, percentage);
        elseif d1 or d2 then
            LoadItem(item, d1 or d2);
        end
    end

end
