if not CLIENT then return end

-- SMH Face Tracking (Stage 6: live tracking + timed face recording + eye + head overlay)
--
-- Replace your existing smh_face_tracking.lua with this file (same folder).
-- Keep face_tracker.py running while you use "Start Live Tracking".
--
-- Workflow:
--   1. Select an entity with facial flexes in SMH
--   2. Open the window with the console command:  smh_face_menu
--   3. Press "Apply Face Tracking"
--   4. Press "Start Live Tracking"
--   5. Press "Calibrate Face" once (relax, then make every expression)
--
-- Console commands:
--   smh_face_menu     open the window
--   smh_face_calibrate / smh_face_calibrate_cancel   start or cancel calibration
--   smh_face_neutral  save the current face as the neutral face
--   smh_face_pulse / smh_face_sweep   diagnostic tests (smh_face_headtest for the head)
--   smh_face_flexes   print the selected entity's flex names to the console

local DATA_FILE     = "smh_face_tracking.txt"  -- written by face_tracker.py into garrysmod/data/
local POLL_INTERVAL = 1 / 30                   -- how often the file is read
local STALE_SECONDS = 3                        -- tracker data older than this counts as "not running"
local SMOOTH_RATE   = 40                       -- higher = snappier, lower = smoother
local SWEEP_TIME    = 1.2                      -- seconds per flex in the sweep test
local HEAD_NET      = "SMHFaceTracking_Head"   -- live head preview (handled by the v5 server file)
local HEAD_DONE_NET = "SMHFaceTracking_HeadOverlayDone"
local FACE_KEYFRAME_NET = "SMHFaceTracking_CaptureFlexKeyframe"
local nextHeadNetSend = 0

local target = nil
local mode = "none"            -- "none", "pulse", "sweep" or "live"
local sweepIndex = -1
local sweepStart = 0
local lastThink = 0

local swapSides = false        -- flip left/right if the wrong eye winks
local strength = 1.5           -- overall expression strength
local neutral = {}             -- the "relaxed face" baseline
local neutralGaze = { x = 0, y = 0 }
local latest = nil             -- newest raw tracker values (nil when no usable data)
local smoothedShapes = nil     -- adaptive (One Euro) filtered incoming blendshapes
local euroFilters = {}         -- filter memory per tracker value
local lastTrackerT = nil       -- timestamp of the last tracker frame that was filtered
local smoothness = 0.5         -- 0..1, set by the Smoothness slider
local rawInput = false         -- true = use the camera values exactly as they arrive (no smoothing)
local inGameOverlayEnabled = false -- optional in-game live tracking monitor
local calibHi = {}             -- your own maximum for each tracker value (Calibrate Face)
local latestGaze = nil         -- signed eye direction from Python
local latestHead = nil         -- approximate head rotation from Python
local neutralHead = { pitch = 0, yaw = 0, roll = 0 }
local headTrackingEnabled = false -- live webcam head rotation; not connected to SMH recording
local headBone = nil
local headBoneOriginal = nil
local headPhysBone = nil
local headPhysObj = nil
local headPhysOriginalAngle = nil
local eyeGazeX, eyeGazeY = 0, 0
local trackerState = "missing" -- "live", "noface", "stale" or "missing"
local shownState = ""
local nextPoll = 0
local liveFlexes = {}
local flexProfile = {}       -- per-model gain/mute settings, keyed by flex name
local profilePath = nil

-- Pose base: default auto-detects; explicit choices override detection.
local poseBase = "default"
local detectedPoseBase = "unknown"
local poseBaseLabel = nil

local frame, statusLabel
local profileEditorFrame -- the flex profile editor window (tracked so the recorder can hide it)

-- State for the timed "Record Tracked Face" recorder (its code is further down).
local FaceRec = {
    phase = "idle",      -- "idle", "countdown", "recording" or "saving"
    prepSeconds = 3,     -- get-ready time, 0-10 s
    frames = 100,        -- how many SMH frames to record
    interval = 1,        -- keyframe every N frames
    latency = 0,         -- shift recorded frames earlier by this many frames
    timeline = 1,        -- SMH timeline that receives the face keyframes
    playSMH = true,      -- play the SMH timeline while recording
    corner = "tr",       -- overlay corner: tr, tl, br, bl
    headOverlay = false, -- also write the tracked head rotation into a body timeline
    headTimeline = 1,    -- the existing timeline (with Physics bones) that gets the head overlay
    usedOverlay = false, -- this recording included head data
    buffer = {},
    hidden = {},
    lost = 0,
    lastIndex = -1,
    sendIndex = 1,
    startFrame = 0,
    rate = 30,
    status = "",
}
local SetStatus -- forward declaration; recorder functions are defined before its implementation

-- Calibration state (its code lives just before the Think hook).
local CALIB_FILE = "smh_face_calibration.json"
local Calib = {
    phase = "idle",   -- "idle", "relax" or "range"
    elapsed = 0,
    n = 0,
    sums = {},
    gaze = { x = 0, y = 0 },
    head = { pitch = 0, yaw = 0, roll = 0 },
    hi = {},
    msg = "",
}

-- The eye target the model is currently looking at (same maths as the live eye code).
local function CurrentEyeVector()
    return Angle((eyeGazeY or 0) * 35, (eyeGazeX or 0) * 35, 0):Forward() * 1000
end

-- Experimental separate face-track recorder. It never calls SMH pose recording.
local FACE_RECORD_FILE = "smh_face_track_test.json"
local faceTrack = { version = 1, tracks = {} }
local faceRecordCount = 0

local function SaveFaceTrack()
    file.Write(FACE_RECORD_FILE, util.TableToJSON(faceTrack, true) or "{}")
end

local function CaptureFaceTrackFrame()
    if not SMH or not SMH.State then
        SetStatus("SMH state is not available.")
        return false
    end
    if not IsValid(target) then
        SetStatus("Apply Face Tracking to a target first.")
        return false
    end
    local timeline = tonumber(SMH.State.Timeline)
    local currentFrame = tonumber(SMH.State.Frame)
    if not timeline or timeline < 1 or not currentFrame or currentFrame < 0 then
        SetStatus("Select a valid SMH timeline and frame first.")
        return false
    end
    local key = tostring(timeline)
    faceTrack.tracks[key] = faceTrack.tracks[key] or { model = target:GetModel(), frames = {} }
    local values = {}
    for _, f in ipairs(liveFlexes) do
        if f.idx ~= nil and target:GetFlexName(f.idx) then
            values[target:GetFlexName(f.idx)] = target:GetFlexWeight(f.idx) or 0
        end
    end
    faceTrack.tracks[key].model = target:GetModel()
    faceTrack.tracks[key].frames[tostring(currentFrame)] = {
        frame = currentFrame,
        time = CurTime(),
        flexes = values,
        gaze = { x = eyeGazeX or 0, y = eyeGazeY or 0 }
    }
    faceRecordCount = faceRecordCount + 1
    SaveFaceTrack()
    -- Capture every flex, including those not driven by the webcam mapping.
    local flexCount = math.min(target:GetFlexNum() or 0, 1023)
    if flexCount > 0 then
        net.Start(FACE_KEYFRAME_NET)
        net.WriteEntity(target)
        net.WriteUInt(math.floor(currentFrame), 32)
        net.WriteUInt(math.floor(timeline), 8)
        net.WriteFloat(target:GetFlexScale() or 1)
        net.WriteUInt(flexCount, 10)
        for i = 0, flexCount - 1 do
            net.WriteFloat(target:GetFlexWeight(i) or 0)
        end
        -- Eye target is included while live tracking runs (see FaceRec.WriteExtras)
        FaceRec.WriteExtras(mode == "live" and CurrentEyeVector() or nil, nil, nil)
        net.SendToServer()
    end
    SetStatus("Face frame saved: timeline " .. timeline .. ", frame " .. currentFrame ..
        "\nFlexes: " .. table.Count(values) .. " | captures this session: " .. faceRecordCount ..
        "\nFile: data/" .. FACE_RECORD_FILE)
    print("[SMH Face Track] Saved timeline " .. timeline .. ", frame " .. currentFrame .. " (" .. table.Count(values) .. " flexes).")
    return true
end

-- Which tracker values drive which model flex.
-- If a flex has several values, the largest one wins.
-- Flexes not listed here are left alone.
local MAP = {
    -- eyelids
    right_lid_closer       = { "eyeBlinkRight" },
    left_lid_closer        = { "eyeBlinkLeft" },
    right_lid_raiser       = { "eyeWideRight" },
    left_lid_raiser        = { "eyeWideLeft" },
    right_lid_tightener    = { "eyeSquintRight" },
    left_lid_tightener     = { "eyeSquintLeft" },

    -- brows
    right_inner_raiser     = { "browInnerUp" },
    left_inner_raiser      = { "browInnerUp" },
    right_outer_raiser     = { "browOuterUpRight" },
    left_outer_raiser      = { "browOuterUpLeft" },
    right_lowerer          = { "browDownRight" },
    left_lowerer           = { "browDownLeft" },

    -- cheeks and nose
    right_cheek_raiser     = { "cheekSquintRight" },
    left_cheek_raiser      = { "cheekSquintLeft" },
    right_cheek_puffer     = { "cheekPuff" },
    left_cheek_puffer      = { "cheekPuff" },
    wrinkler               = { "noseSneerLeft", "noseSneerRight" },

    -- mouth and jaw
    jaw_drop               = { "jawOpen" },
    right_upper_raiser     = { "mouthUpperUpRight" },
    left_upper_raiser      = { "mouthUpperUpLeft" },
    right_corner_puller    = { "mouthSmileRight" },
    left_corner_puller     = { "mouthSmileLeft" },
    right_corner_depressor = { "mouthFrownRight" },
    left_corner_depressor  = { "mouthFrownLeft" },
    chin_raiser            = { "mouthShrugLower" },
    right_puckerer         = { "mouthPucker" },
    left_puckerer          = { "mouthPucker" },
    right_funneler         = { "mouthFunnel" },
    left_funneler          = { "mouthFunnel" },
    right_stretcher        = { "mouthStretchRight" },
    left_stretcher         = { "mouthStretchLeft" },
    presser                = { "mouthPressLeft", "mouthPressRight" },
    right_mouth_drop       = { "mouthLowerDownRight" },
    left_mouth_drop        = { "mouthLowerDownLeft" },
    right_dimpler          = { "mouthDimpleRight" },
    left_dimpler           = { "mouthDimpleLeft" },
}

-- Additional name compatibility for mixed Garry's Mod model collections.
-- The tracker already outputs MediaPipe/ARKit-style blendshape names. These
-- direct mappings allow models whose flexes use those names to work without
-- changing face_tracker.py or the live tracking loop.
local ARKIT_MAP = {}
local ARKIT_SHAPES = {
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight",
    "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
    "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight",
    "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthPressLeft", "mouthPressRight", "mouthPucker", "mouthRight", "mouthRollLower",
    "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight",
    "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
    "noseSneerLeft", "noseSneerRight", "tongueOut",
}
for _, shapeName in ipairs(ARKIT_SHAPES) do
    ARKIT_MAP[shapeName] = { shapeName }
end

-- Naming conventions were informed by the public vlazed/face-tracker preset files;
-- no source code from that repository is copied into this script.
-- HWM-style names from common Source character rigs. These are aliases to
-- tracker values, not copied code from another addon. Composite/constant HWM
-- presets are deliberately left for a later step because they need expressions
-- rather than a simple one-to-one mapping.
local FLEX_NAME_ALIASES = {
    -- Additional generic Source flex names found in the test model.
    -- These are approximate aliases; ambiguous motion/pupil flexes are
    -- intentionally not mapped to unrelated facial signals.
    -- Kleiner / generic Face Poser-style flex names.
    right_lid_raiser = { "eyeWideRight" },
    left_lid_raiser = { "eyeWideLeft" },
    right_lid_tightener = { "eyeSquintRight" },
    left_lid_tightener = { "eyeSquintLeft" },
    right_lid_droop = { "eyeBlinkRight" },
    left_lid_droop = { "eyeBlinkLeft" },
    right_lid_closer = { "eyeBlinkRight" },
    left_lid_closer = { "eyeBlinkLeft" },
    half_closed = { "eyeBlinkLeft", "eyeBlinkRight" },
    blink = { "eyeBlinkLeft", "eyeBlinkRight" },
    right_inner_raiser = { "browInnerUp" },
    left_inner_raiser = { "browInnerUp" },
    right_outer_raiser = { "browOuterUpRight" },
    left_outer_raiser = { "browOuterUpLeft" },
    right_lowerer = { "browDownRight" },
    left_lowerer = { "browDownLeft" },
    right_cheek_raiser = { "cheekSquintRight" },
    left_cheek_raiser = { "cheekSquintLeft" },
    right_upper_raiser = { "mouthUpperUpRight" },
    left_upper_raiser = { "mouthUpperUpLeft" },
    right_corner_puller = { "mouthSmileRight" },
    left_corner_puller = { "mouthSmileLeft" },
    right_corner_depressor = { "mouthFrownRight" },
    left_corner_depressor = { "mouthFrownLeft" },
    chin_raiser = { "mouthShrugLower" },
    sneer_left = { "noseSneerLeft" },
    sneer_right = { "noseSneerRight" },
    right_dimpler = { "mouthDimpleRight" },
    left_dimpler = { "mouthDimpleLeft" },
    right_cheek_puffer = { "cheekPuff" },
    left_cheek_puffer = { "cheekPuff" },
    lip_bite = { "mouthRollLower" },
    lower_lip = { "mouthLowerDownLeft", "mouthLowerDownRight" },
    right_part = { "mouthSmileRight" },
    left_part = { "mouthSmileLeft" },
    right_puckerer = { "mouthPucker" },
    left_puckerer = { "mouthPucker" },
    right_funneler = { "mouthFunnel" },
    left_funneler = { "mouthFunnel" },
    right_stretcher = { "mouthStretchRight" },
    left_stretcher = { "mouthStretchLeft" },
    bite = { "mouthClose" },
    presser = { "mouthPressLeft", "mouthPressRight" },
    tightener = { "mouthPressLeft", "mouthPressRight" },
    jaw_clencher = { "mouthPressLeft", "mouthPressRight" },
    jaw_drop = { "jawOpen" },
    right_mouth_drop = { "mouthLowerDownRight" },
    left_mouth_drop = { "mouthLowerDownLeft" },
    -- Signed horizontal motion is handled by the formula table below where
    -- a rig exposes the HWM JawH flex; do not max opposing directions here.
    mouth_sideways = { "mouthLeft", "mouthRight" },
    jaw_sideways = { "jawLeft", "jawRight" },
    lip_bite = { "mouthRollLower" },
    lower_lip = { "mouthLowerDownLeft", "mouthLowerDownRight" },
    left_smile = { "mouthSmileLeft" },
    right_smile = { "mouthSmileRight" },
    left_browoutv = { "browOuterUpLeft" },
    right_browoutv = { "browOuterUpRight" },
    left_outersquint = { "eyeSquintLeft" },
    right_outersquint = { "eyeSquintRight" },
    left_innersquint = { "eyeSquintLeft" },
    right_innersquint = { "eyeSquintRight" },
    left_puckerliplo = { "mouthPucker" },
    right_puckerliplo = { "mouthPucker" },
    left_puckerlipup = { "mouthPucker" },
    right_puckerlipup = { "mouthPucker" },
    left_lipcnrtwst = { "mouthFrownLeft" },
    right_lipcnrtwst = { "mouthFrownRight" },
    left_frown = { "browDownLeft" },
    right_frown = { "browDownRight" },
    left_closelid = { "eyeBlinkLeft" },
    right_closelid = { "eyeBlinkRight" },
    left_cheekv = { "cheekSquintLeft" },
    right_cheekv = { "cheekSquintRight" },
    left_cheekh = { "cheekPuff" },
    right_cheekh = { "cheekPuff" },
    left_dimple = { "mouthDimpleLeft" },
    right_dimple = { "mouthDimpleRight" },
    left_foldlipup = { "mouthRollUpper" },
    right_foldlipup = { "mouthRollUpper" },
    left_foldliplo = { "mouthRollLower" },
    right_foldliplo = { "mouthRollLower" },
    left_lipupv = { "mouthUpperUpLeft" },
    right_lipupv = { "mouthUpperUpRight" },
    left_liplov = { "mouthLowerDownLeft" },
    right_liplov = { "mouthLowerDownRight" },
}

local function NormalizeFlexName(name)
    return string.lower(string.gsub(name or "", "[^%w]", ""))
end

local NORMALIZED_MAP = {}
local NORMALIZED_ARKIT_MAP = {}
local NORMALIZED_ALIASES = {}
for flexName, sources in pairs(MAP) do
    NORMALIZED_MAP[NormalizeFlexName(flexName)] = sources
end
for flexName, sources in pairs(ARKIT_MAP) do
    NORMALIZED_ARKIT_MAP[NormalizeFlexName(flexName)] = sources
end
for flexName, sources in pairs(FLEX_NAME_ALIASES) do
    NORMALIZED_ALIASES[NormalizeFlexName(flexName)] = sources
end

-- Per-model profile storage. These files live in garrysmod/data/smh_face_profiles/.
local function GetProfilePath(ent)
    if not IsValid(ent) then return nil end
    local model = string.lower(ent:GetModel() or "unknown")
    local safe = string.gsub(model, "[^%w_%-]", "_")
    return "smh_face_profiles/" .. safe .. ".json"
end

local function LoadProfile(ent)
    profilePath = GetProfilePath(ent)
    flexProfile = {}
    if not profilePath then return end

    file.CreateDir("smh_face_profiles")
    local raw = file.Read(profilePath, "DATA")
    if not raw or raw == "" then return end

    local decoded = util.JSONToTable(raw)
    if istable(decoded) then
        flexProfile = decoded
    else
        print("[SMH Face] Could not read profile; using defaults for " .. (ent:GetModel() or "unknown"))
    end
end

local function SaveProfile()
    if not profilePath then return end
    file.CreateDir("smh_face_profiles")
    file.Write(profilePath, util.TableToJSON(flexProfile, true) or "{}")
end

local function GetSMHEntity()
    if SMH and SMH.State and IsValid(SMH.State.Entity) then
        return SMH.State.Entity
    end
    return nil
end

SetStatus = function(text)
    if IsValid(statusLabel) then
        statusLabel:SetText(text)
    end
end

local function ResetFlexes()
    if not IsValid(target) then return end
    for i = 0, target:GetFlexNum() - 1 do
        target:SetFlexWeight(i, 0)
    end
end

local function SendHeadRotation(active, ang)
    if not IsValid(target) then return end
    -- Limit active pose updates to about 30 Hz; always allow reset/test messages through.
    if active and CurTime() < nextHeadNetSend then return end
    if active then nextHeadNetSend = CurTime() + (1 / 30) end
    net.Start(HEAD_NET)
    net.WriteEntity(target)
    net.WriteBool(active and true or false)
    net.WriteAngle(ang or angle_zero)
    net.SendToServer()
end

-- The head rotation to apply right now (tracked head minus neutral, limited and
-- softened). Used by the live preview and by the recorded head overlay.
local function CurrentHeadOffset()
    if not latestHead then return nil end
    local pitch = math.Clamp((tonumber(latestHead.pitch) or 0) - neutralHead.pitch, -25, 25)
    local yaw = math.Clamp((tonumber(latestHead.yaw) or 0) - neutralHead.yaw, -35, 35)
    local roll = math.Clamp((tonumber(latestHead.roll) or 0) - neutralHead.roll, -25, 25)
    return Angle(pitch * 0.65, yaw * 0.65, roll * 0.65)
end

local function ResetHeadRotation()
    -- The actual prop_ragdoll physics objects are managed by the server.
    -- Ask the server helper to restore the original head-physics angle.
    SendHeadRotation(false, angle_zero)
    if IsValid(target) and headBone ~= nil and headBone >= 0 then
        target:ManipulateBoneAngles(headBone, headBoneOriginal or angle_zero)
    end
end

-- Diagnostic: briefly rotate the actual server-side head physics object.
local function TestHeadBone()
    if not IsValid(target) then
        SetStatus("Press Apply Face Tracking first.")
        return
    end
    if headBone == nil or headBone < 0 then
        SetStatus("Head bone not found. Press Apply Face Tracking again.")
        return
    end

    mode = "none"
    SendHeadRotation(true, Angle(25, 25, 25))
    SetStatus("Sent a head-physics test to the server. Watch the head now; it should reset automatically after a few seconds. Check the server console for [SMH Face Server] messages if nothing moves.")
    print("[SMH Face] Sent head physics test for entity " .. tostring(target:EntIndex()) .. " (" .. tostring(target:GetModel()) .. ").")
end

-- Diagnostic only: list the model-bone to physics-object mapping for this ragdoll.
local function ListHeadPhysicsMappings()
    if not IsValid(target) then
        SetStatus("Press Apply Face Tracking first.")
        return
    end

    print("[SMH Face] ---- Bone / physics mapping for " .. tostring(target:GetModel()) .. " ----")
    print("[SMH Face] head bone index=" .. tostring(headBone) .. ", mapped physics bone=" .. tostring(headPhysBone) .. ", head physics object valid=" .. tostring(IsValid(headPhysObj)))

    local boneCount = target:GetBoneCount() or 0
    for bone = 0, boneCount - 1 do
        local name = target:GetBoneName(bone) or "?"
        local physBone = target:TranslateBoneToPhysBone(bone)
        local physObj = (physBone ~= nil and physBone >= 0) and target:GetPhysicsObjectNum(physBone) or nil
        if string.find(string.lower(name), "head", 1, true)
            or string.find(string.lower(name), "neck", 1, true)
            or string.find(string.lower(name), "spine", 1, true)
            or bone == headBone then
            print("[SMH Face] model bone " .. bone .. " '" .. name .. "' -> physics bone " .. tostring(physBone) .. " -> valid object " .. tostring(IsValid(physObj)))
        end
    end

    local physCount = target:GetPhysicsObjectCount() or 0
    print("[SMH Face] Physics object count=" .. physCount)
    for physBone = 0, physCount - 1 do
        local physObj = target:GetPhysicsObjectNum(physBone)
        local mappedBone = target:TranslatePhysBoneToBone(physBone)
        local mappedName = (mappedBone ~= nil and mappedBone >= 0) and target:GetBoneName(mappedBone) or "?"
        print("[SMH Face] physics bone " .. physBone .. " -> model bone " .. tostring(mappedBone) .. " '" .. tostring(mappedName) .. "' -> valid object " .. tostring(IsValid(physObj)))
    end
    SetStatus("Printed head/neck/spine physics mappings to the console. Copy the [SMH Face] lines here.")
end

local function StopTest()
    mode = "none"
    sweepIndex = -1
    ResetFlexes()
    if IsValid(target) and target.SetEyeTarget then
        target:SetEyeTarget(vector_origin)
    end
    ResetHeadRotation()
    eyeGazeX, eyeGazeY = 0, 0
end

-- Swap Left and Right in a tracker value name (used by the swap checkbox)
local function Side(name)
    if not swapSides then return name end
    local s = string.gsub(name, "Left", "@@")
    s = string.gsub(s, "Right", "Left")
    s = string.gsub(s, "@@", "Right")
    return s
end

-- One tracker value, with the neutral face removed, scaled to 0..1
local function ShapeValue(name)
    if not latest then return 0 end
    local key = Side(name)
    local source = smoothedShapes or latest
    local v = source[key] or 0
    local n = neutral[key] or 0
    -- Top of the range: your own calibrated maximum when it is a believable
    -- range, otherwise the full 0..1 range the tracker can report.
    local top = 1
    local hi = calibHi[key]
    if hi and hi - n >= 0.2 then
        top = math.min(1, math.max(hi * 0.95, n + 0.15))
    end
    local denom = math.max(top - n, 0.1)
    return math.Clamp((v - n) / denom, 0, 1)
end



-- HWM preset expressions reproduced as explicit arithmetic functions.
-- These use the same 0..1 ARKit inputs as the tracker and preserve the
-- HWM rig's centered (0.5) flexes instead of treating every flex as zero.
local function SV(name) return ShapeValue(name) end
local function Mean(a, b) return (SV(a) + SV(b)) * 0.5 end
local HWM_FORMULAS = {
    left_smile = function() return SV("mouthSmileLeft") end,
    right_smile = function() return SV("mouthSmileRight") end,
    left_browoutv = function() return SV("browOuterUpLeft") end,
    right_browoutv = function() return SV("browOuterUpRight") end,
    left_outersquint = function() return SV("eyeSquintLeft") end,
    right_outersquint = function() return SV("eyeSquintRight") end,
    left_innersquint = function() return SV("eyeSquintLeft") end,
    right_innersquint = function() return SV("eyeSquintRight") end,
    left_puckerliplo = function() return SV("mouthPucker") end,
    right_puckerliplo = function() return SV("mouthPucker") end,
    left_puckerlipup = function() return SV("mouthPucker") end,
    right_puckerlipup = function() return SV("mouthPucker") end,
    left_lipcnrtwst = function() return SV("mouthFrownLeft") end,
    right_lipcnrtwst = function() return SV("mouthFrownRight") end,
    left_frown = function() return SV("browDownLeft") end,
    right_frown = function() return SV("browDownRight") end,
    left_closelid = function() return math.Clamp(SV("eyeBlinkLeft") + 0.5 - SV("eyeWideLeft") * 0.5, 0, 1) end,
    right_closelid = function() return math.Clamp(SV("eyeBlinkRight") + 0.5 - SV("eyeWideRight") * 0.5, 0, 1) end,
    left_cheekv = function() return SV("cheekSquintLeft") end,
    right_cheekv = function() return SV("cheekSquintRight") end,
    left_cheekh = function() return SV("cheekPuff") * 0.5 + 0.5 end,
    right_cheekh = function() return SV("cheekPuff") * 0.5 + 0.5 end,
    left_dimple = function() return SV("mouthDimpleLeft") end,
    right_dimple = function() return SV("mouthDimpleRight") end,
    left_foldlipup = function() return -SV("mouthRollUpper") * 0.5 + 0.5 end,
    right_foldlipup = function() return -SV("mouthRollUpper") * 0.5 + 0.5 end,
    left_foldliplo = function() return -SV("mouthRollLower") * 0.5 + 0.5 end,
    right_foldliplo = function() return -SV("mouthRollLower") * 0.5 + 0.5 end,
    left_lipupv = function() return 0.5 + 0.25 * SV("jawOpen") + 0.5 * SV("mouthUpperUpLeft") end,
    right_lipupv = function() return 0.5 + 0.25 * SV("jawOpen") + 0.5 * SV("mouthUpperUpRight") end,
    left_liplov = function() return 0.5 + 0.25 * SV("jawOpen") + 0.5 * SV("mouthLowerDownLeft") end,
    right_liplov = function() return 0.5 + 0.25 * SV("jawOpen") + 0.5 * SV("mouthLowerDownRight") end,
    left_browinv = function() return 0.5 + 0.5 * SV("browInnerUp") - 0.5 * SV("browDownLeft") end,
    right_browinv = function() return 0.5 + 0.5 * SV("browInnerUp") - 0.5 * SV("browDownRight") end,
    left_nosev = function() return SV("noseSneerLeft") * 0.5 + 0.5 end,
    right_nosev = function() return SV("noseSneerRight") * 0.5 + 0.5 end,
    jawv = function() return SV("jawOpen") * 0.5 + 0.5 end,
    jawd = function() return 0.5 end,
    jawh = function() return -SV("jawLeft") * 0.5 + SV("jawRight") * 0.5 + 0.5 end,
    tonguecurl = function() return 0.5 end,
    tongued = function() return SV("tongueOut") * 0.5 + 0.5 end,
    tongueh = function() return 0.5 end,
    left_platysmus = function() return 0 end,
    right_platysmus = function() return 0 end,
    multi_smile = function() return 0.5 end,
    multi_closelid = function() return 0.5 end,
    blink = function() return 0 end,
    left_nostrilflare = function() return 0.5 end,
    right_nostrilflare = function() return 0.5 end,
    right_lipsv = function() return 0.5 + SV("jawOpen") + 0.25 * SV("mouthUpperUpRight") - 0.25 * SV("mouthLowerDownRight") end,
    left_lipsv = function() return 0.5 + SV("jawOpen") + 0.25 * SV("mouthUpperUpLeft") - 0.5 * SV("mouthLowerDownLeft") end,
}
-- Generic/Kleiner-style controls use directional formulas rather than
-- taking the maximum of opposing signals.
HWM_FORMULAS.mouth_sideways = function()
    -- Source-style sideways flex is centered: equal left/right input is neutral.
    -- Never take max(left,right), which biases the mouth toward one side.
    return math.Clamp(0.5 + (SV("mouthRight") - SV("mouthLeft")) * 0.5, 0, 1)
end
HWM_FORMULAS.jaw_sideways = function()
    -- Same signed difference for sideways jaw motion on Source/HL2 rigs.
    return math.Clamp(0.5 + (SV("jawRight") - SV("jawLeft")) * 0.5, 0, 1)
end
HWM_FORMULAS.right_lid_raiser = function() return SV("eyeWideRight") end
HWM_FORMULAS.left_lid_raiser = function() return SV("eyeWideLeft") end
HWM_FORMULAS.right_lid_tightener = function() return SV("eyeSquintRight") end
HWM_FORMULAS.left_lid_tightener = function() return SV("eyeSquintLeft") end
HWM_FORMULAS.right_lid_droop = function() return SV("eyeBlinkRight") end
HWM_FORMULAS.left_lid_droop = function() return SV("eyeBlinkLeft") end
HWM_FORMULAS.right_lid_closer = function() return SV("eyeBlinkRight") end
HWM_FORMULAS.left_lid_closer = function() return SV("eyeBlinkLeft") end
HWM_FORMULAS.half_closed = function() return Mean("eyeBlinkLeft", "eyeBlinkRight") end
HWM_FORMULAS.blink = function() return Mean("eyeBlinkLeft", "eyeBlinkRight") end
HWM_FORMULAS.right_part = function() return SV("mouthSmileRight") end
HWM_FORMULAS.left_part = function() return SV("mouthSmileLeft") end
HWM_FORMULAS.jaw_drop = function() return SV("jawOpen") end
HWM_FORMULAS.right_mouth_drop = function() return SV("mouthLowerDownRight") end
HWM_FORMULAS.left_mouth_drop = function() return SV("mouthLowerDownLeft") end
HWM_FORMULAS.right_puckerer = function() return SV("mouthPucker") end
HWM_FORMULAS.left_puckerer = function() return SV("mouthPucker") end
HWM_FORMULAS.right_funneler = function() return SV("mouthFunnel") end
HWM_FORMULAS.left_funneler = function() return SV("mouthFunnel") end
HWM_FORMULAS.right_stretcher = function() return SV("mouthStretchRight") end
HWM_FORMULAS.left_stretcher = function() return SV("mouthStretchLeft") end
HWM_FORMULAS.right_cheek_puffer = function() return SV("cheekPuff") end
HWM_FORMULAS.left_cheek_puffer = function() return SV("cheekPuff") end
HWM_FORMULAS.presser = function() return Mean("mouthPressLeft", "mouthPressRight") end
HWM_FORMULAS.tightener = function() return Mean("mouthPressLeft", "mouthPressRight") end
HWM_FORMULAS.jaw_clencher = function() return Mean("mouthPressLeft", "mouthPressRight") end

local NORMALIZED_HWM_FORMULAS = {}
for flexName, fn in pairs(HWM_FORMULAS) do
    NORMALIZED_HWM_FORMULAS[NormalizeFlexName(flexName)] = fn
end

-- Read the file written by face_tracker.py
-- One Euro filter: smooth when you hold still, quicker when you move fast.
-- The Smoothness slider sets the base cutoff (Hz) and how much fast moves are
-- let through. The middle setting (50) is tuned to behave like the original
-- fixed input smoothing, which handled normal speech well; lower = snappier,
-- higher = steadier.
local EURO_DCUTOFF = 1.0

local function EuroParams()
    local s = math.Clamp(smoothness, 0, 1)
    local minCut
    if s <= 0.5 then
        minCut = 1.6 * (8 / 1.6) ^ ((0.5 - s) / 0.5)   -- 1.6 Hz at 50, 8 Hz at 0
    else
        minCut = 1.6 * (0.5 / 1.6) ^ ((s - 0.5) / 0.5) -- 1.6 Hz at 50, 0.5 Hz at 100
    end
    local beta = 0.2 + (1 - s) * 0.6                   -- 0.5 at 50
    return minCut, beta
end

local function EuroAlpha(cutoff, dt)
    local tau = 1 / (2 * math.pi * cutoff)
    return 1 / (1 + tau / dt)
end

-- scale: typical size of the value (1 for blendshapes and gaze, ~60 for degrees)
local function EuroFilter(key, x, dt, scale)
    scale = scale or 1
    local f = euroFilters[key]
    if not f then
        euroFilters[key] = { x = x, dx = 0 }
        return x
    end
    local dx = (x - f.x) / dt / scale
    f.dx = f.dx + (dx - f.dx) * EuroAlpha(EURO_DCUTOFF, dt)
    local minCut, beta = EuroParams()
    local cutoff = minCut + beta * math.abs(f.dx)
    f.x = f.x + (x - f.x) * EuroAlpha(cutoff, dt)
    return f.x
end

local function ResetInput()
    latest = nil
    smoothedShapes = nil
    euroFilters = {}
    lastTrackerT = nil
    latestGaze = nil
    latestHead = nil
end

local function PollTracker()
    local raw = file.Read(DATA_FILE, "DATA")
    if not raw or raw == "" then
        ResetInput()
        trackerState = "missing"
        return
    end

    local data = util.JSONToTable(raw)
    if not data or not data.shapes then
        return -- half-written file; keep the previous values
    end

    if math.abs(os.time() - (data.t or 0)) > STALE_SECONDS then
        ResetInput()
        trackerState = "stale"
        return
    end

    if not data.face then
        ResetInput()
        trackerState = "noface"
        return
    end

    latest = data.shapes
    trackerState = "live"

    -- Raw mode: use every value exactly as the camera program wrote it.
    if rawInput then
        smoothedShapes = smoothedShapes or {}
        for k, v in pairs(latest) do smoothedShapes[k] = tonumber(v) or 0 end
        for k in pairs(smoothedShapes) do
            if latest[k] == nil then smoothedShapes[k] = nil end
        end
        latestGaze = istable(data.gaze) and data.gaze or { x = 0, y = 0 }
        latestHead = istable(data.head) and data.head or { pitch = 0, yaw = 0, roll = 0 }
        lastTrackerT = tonumber(data.t)
        return
    end

    -- The tracker stamps every frame. Filter each frame once, using the real
    -- time between frames, and skip repeats of a frame we already used.
    local frameT = tonumber(data.t) or 0
    if lastTrackerT and frameT <= lastTrackerT and smoothedShapes then
        return
    end
    local dt = lastTrackerT and math.Clamp(frameT - lastTrackerT, 1 / 120, 0.25) or POLL_INTERVAL
    lastTrackerT = frameT

    smoothedShapes = smoothedShapes or {}
    for k, v in pairs(latest) do
        smoothedShapes[k] = EuroFilter(k, tonumber(v) or 0, dt, 1)
    end
    -- Values absent from a frame ease back to zero instead of sticking.
    for k in pairs(smoothedShapes) do
        if latest[k] == nil then smoothedShapes[k] = EuroFilter(k, 0, dt, 1) end
    end

    local g = istable(data.gaze) and data.gaze or { x = 0, y = 0 }
    latestGaze = {
        x = EuroFilter("@gazeX", tonumber(g.x) or 0, dt, 1),
        y = EuroFilter("@gazeY", tonumber(g.y) or 0, dt, 1),
    }
    local h = istable(data.head) and data.head or { pitch = 0, yaw = 0, roll = 0 }
    latestHead = {
        pitch = EuroFilter("@headPitch", tonumber(h.pitch) or 0, dt, 60),
        yaw = EuroFilter("@headYaw", tonumber(h.yaw) or 0, dt, 60),
        roll = EuroFilter("@headRoll", tonumber(h.roll) or 0, dt, 60),
    }
end

local function DetectPoseBase(ent)
    if not IsValid(ent) or not ent.GetFlexNum then return "unknown", "No target selected" end
    local names = {}
    for i = 0, ent:GetFlexNum() - 1 do
        local n = NormalizeFlexName(ent:GetFlexName(i) or "")
        if n ~= "" then names[n] = true end
    end
    local function hasAny(list)
        for _, n in ipairs(list) do if names[NormalizeFlexName(n)] then return true end end
        return false
    end
    -- Prefer distinctive naming signatures, not model filenames alone.
    local hwmScore = 0
    for _, n in ipairs({"left_smile", "right_smile", "jawh", "jawv", "left_browinv", "right_closelid", "eyes_updown"}) do
        if names[NormalizeFlexName(n)] then hwmScore = hwmScore + 1 end
    end
    local arkitScore = 0
    for _, n in ipairs({"jawopen", "mouthsmileleft", "mouthsmileright", "eyeblinkleft", "browinnerup", "mouthpucker"}) do
        if names[NormalizeFlexName(n)] then arkitScore = arkitScore + 1 end
    end
    local sourceScore = 0
    for _, n in ipairs({"right_lid_raiser", "left_lid_raiser", "mouth_sideways", "jaw_sideways", "jaw_drop", "right_part", "left_part", "right_mouth_drop"}) do
        if names[NormalizeFlexName(n)] then sourceScore = sourceScore + 1 end
    end
    if hwmScore >= 2 and hwmScore >= arkitScore and hwmScore >= sourceScore then
        return "tf2_hwm", "Detected TF2 HWM-style flex names (" .. hwmScore .. " signatures)"
    elseif sourceScore >= 2 and sourceScore >= arkitScore then
        return "source_kleiner", "Detected Source/Kleiner-style flex names (" .. sourceScore .. " signatures)"
    elseif arkitScore >= 2 then
        return "arkit", "Detected ARKit-style flex names (" .. arkitScore .. " signatures)"
    end
    return "unknown", "Could not confidently identify this rig from flex names; choose a pose base manually."
end

local function EffectivePoseBase()
    if poseBase == "default" then return detectedPoseBase end
    return poseBase
end

local function BuildLiveFlexes()
    liveFlexes = {}
    local unmapped = {}

    for i = 0, target:GetFlexNum() - 1 do
        local name = target:GetFlexName(i)
        local normalizedName = NormalizeFlexName(name)
        local effectiveBase = EffectivePoseBase()
        local formula = (effectiveBase == "tf2_hwm") and NORMALIZED_HWM_FORMULAS[normalizedName] or nil
        local entry = name and MAP[name]
            or NORMALIZED_MAP[normalizedName]
            or ARKIT_MAP[name]
            or NORMALIZED_ARKIT_MAP[normalizedName]
            or NORMALIZED_ALIASES[normalizedName]
        if entry or formula then
            local settings = flexProfile[name]
            if not istable(settings) then
                settings = { gain = 1, muted = false }
                flexProfile[name] = settings
            end
            settings.gain = tonumber(settings.gain) or 1
            settings.muted = settings.muted == true

            local minB, maxB = target:GetFlexBounds(i)
            liveFlexes[#liveFlexes + 1] = {
                idx = i,
                name = name or ("flex_" .. i),
                sources = entry or {},
                formula = formula,
                min = minB,
                max = maxB,
                value = 0,
                gain = math.Clamp(settings.gain, 0, 3),
                muted = settings.muted,
            }
        else
            unmapped[#unmapped + 1] = name or "?"
        end
    end

    SaveProfile()
    print("[SMH Face] Pose Base: " .. tostring(EffectivePoseBase()) .. " (selected: " .. tostring(poseBase) .. ", detected: " .. tostring(detectedPoseBase) .. ")")
    print("[SMH Face] Driving " .. #liveFlexes .. " mapped flexes.")
    print("[SMH Face] Profile: " .. (profilePath or "not loaded"))
    print("[SMH Face] Not driven: " .. table.concat(unmapped, ", "))
end

local function UpdateLiveStatus()
    if trackerState == shownState then return end
    shownState = trackerState

    local text
    if trackerState == "live" then
        text = next(calibHi) ~= nil and "Face found." or "Face found. For best accuracy press Calibrate Face."
    elseif trackerState == "noface" then
        text = "Tracker is running but sees no face."
    else
        text = "No data from the tracker. Is face_tracker.py running?"
    end
    SetStatus("Live: " .. #liveFlexes .. " flexes driven.\n" .. text)
end

local function ApplyFaceTracking()
    local ent = GetSMHEntity()
    if not ent then
        SetStatus("No SMH entity selected.\nSelect one in Stop Motion Helper first.")
        return
    end

    local count = ent:GetFlexNum()
    if count == 0 then
        SetStatus("This model has no facial flexes.\nPick a model that has them.")
        return
    end

    StopTest()
    target = ent
    headBone = target:LookupBone("ValveBiped.Bip01_Head1")
    headBoneOriginal = (headBone ~= nil and headBone >= 0) and target:GetManipulateBoneAngles(headBone) or angle_zero
    -- Client-side ragdolls may report zero physics objects; the server helper resolves these.
    headPhysBone = nil
    headPhysObj = nil
    headPhysOriginalAngle = nil
    LoadProfile(ent)
    detectedPoseBase = select(1, DetectPoseBase(ent))
    -- Build the mapped flex list immediately so the profile editor works
    -- after Apply Face Tracking; live tracking does not need to be running.
    BuildLiveFlexes()
    SetStatus("Applied to:\n" .. ent:GetModel() .. "\n" .. count .. " flexes found. Profile editor is ready; press Start Live Tracking when ready.")
end

local function StartLive()
    if not IsValid(target) then
        SetStatus("Press Apply Face Tracking first.")
        return
    end
    StopTest()
    BuildLiveFlexes()
    nextPoll = 0
    shownState = ""
    mode = "live"
end

local function SetNeutral()
    if not latest then
        SetStatus("No face data yet. Start Live Tracking and make sure the tracker sees your face.")
        return
    end
    neutral = table.Copy(latest)
    if latestGaze then
        neutralGaze = table.Copy(latestGaze)
    end
    if latestHead then
        neutralHead.pitch = tonumber(latestHead.pitch) or 0
        neutralHead.yaw = tonumber(latestHead.yaw) or 0
        neutralHead.roll = tonumber(latestHead.roll) or 0
    end
    Calib.Save()
    SetStatus("Neutral face and eye direction saved.")
    shownState = trackerState -- keep this message until the tracker state changes
end

local function StartPulse()
    if not IsValid(target) then
        SetStatus("Press Apply Face Tracking first.")
        return
    end
    StopTest()
    mode = "pulse"
    SetStatus("Pulse test: all flexes moving together.")
end

local function StartSweep()
    if not IsValid(target) then
        SetStatus("Press Apply Face Tracking first.")
        return
    end
    StopTest()
    sweepIndex = -1
    sweepStart = CurTime()
    mode = "sweep"
    SetStatus("Sweep test: one flex at a time.\nNames print to the console.")
end

-- ===========================================================================
-- Calibrate Face
-- Step 1: relax (becomes your neutral face).
-- Step 2: make every expression as far as you can, so each tracker value is
--         scaled to YOUR face's range. Saved to data/smh_face_calibration.json
--         and loaded automatically next time.
-- ===========================================================================
local CALIB_RELAX = 3
local CALIB_RANGE = 10

function Calib.Load()
    local raw = file.Read(CALIB_FILE, "DATA")
    if not raw or raw == "" then return end
    local d = util.JSONToTable(raw)
    if not istable(d) then return end
    if istable(d.neutral) then neutral = d.neutral end
    if istable(d.hi) then calibHi = d.hi end
    if istable(d.gaze) then
        neutralGaze = { x = tonumber(d.gaze.x) or 0, y = tonumber(d.gaze.y) or 0 }
    end
    if istable(d.head) then
        neutralHead.pitch = tonumber(d.head.pitch) or 0
        neutralHead.yaw = tonumber(d.head.yaw) or 0
        neutralHead.roll = tonumber(d.head.roll) or 0
    end
end

function Calib.Save()
    file.Write(CALIB_FILE, util.TableToJSON({
        neutral = neutral, hi = calibHi, gaze = neutralGaze, head = neutralHead,
    }, true) or "{}")
end

Calib.Load()

function Calib.Cancel(msg)
    Calib.phase = "idle"
    if msg then SetStatus(msg) end
end

function Calib.Start()
    if not IsValid(target) then
        SetStatus("Press Apply Face Tracking first.")
        return
    end
    if FaceRec.phase ~= "idle" then
        SetStatus("Finish the recording first.")
        return
    end
    if mode ~= "live" then StartLive() end
    Calib.phase = "relax"
    Calib.elapsed = 0
    Calib.n = 0
    Calib.sums = {}
    Calib.gaze = { x = 0, y = 0 }
    Calib.head = { pitch = 0, yaw = 0, roll = 0 }
    Calib.hi = {}
    Calib.msg = ""
    SetStatus("Calibration started. Follow the instructions on screen.\nPress END to cancel.")
end

function Calib.Tick(dt)
    if Calib.phase == "idle" then return end
    if mode ~= "live" or not IsValid(target) then
        Calib.Cancel("Calibration cancelled: live tracking stopped.")
        return
    end
    if input.IsKeyDown(KEY_END) then
        Calib.Cancel("Calibration cancelled.")
        return
    end
    local source = smoothedShapes
    if trackerState ~= "live" or not source then
        Calib.msg = "Waiting for the tracker to see your face..."
        return
    end
    Calib.msg = ""
    Calib.elapsed = Calib.elapsed + dt

    if Calib.phase == "relax" then
        if Calib.elapsed >= 1 then -- skip the first second while you settle
            Calib.n = Calib.n + 1
            for k, v in pairs(source) do Calib.sums[k] = (Calib.sums[k] or 0) + v end
            if latestGaze then
                Calib.gaze.x = Calib.gaze.x + (tonumber(latestGaze.x) or 0)
                Calib.gaze.y = Calib.gaze.y + (tonumber(latestGaze.y) or 0)
            end
            if latestHead then
                Calib.head.pitch = Calib.head.pitch + (tonumber(latestHead.pitch) or 0)
                Calib.head.yaw = Calib.head.yaw + (tonumber(latestHead.yaw) or 0)
                Calib.head.roll = Calib.head.roll + (tonumber(latestHead.roll) or 0)
            end
        end
        if Calib.elapsed >= CALIB_RELAX then
            if Calib.n > 0 then
                neutral = {}
                for k, s in pairs(Calib.sums) do neutral[k] = s / Calib.n end
                neutralGaze = { x = Calib.gaze.x / Calib.n, y = Calib.gaze.y / Calib.n }
                neutralHead.pitch = Calib.head.pitch / Calib.n
                neutralHead.yaw = Calib.head.yaw / Calib.n
                neutralHead.roll = Calib.head.roll / Calib.n
            end
            calibHi = {} -- measure the range fresh; the model shows the raw scale meanwhile
            Calib.phase = "range"
            Calib.elapsed = 0
        end
    else
        for k, v in pairs(source) do
            if v > (Calib.hi[k] or 0) then Calib.hi[k] = v end
        end
        if Calib.elapsed >= CALIB_RANGE then
            calibHi = Calib.hi
            Calib.phase = "idle"
            Calib.Save()
            SetStatus("Calibration saved. Expressions now use your own range.\nRe-run it if you move to a different camera or lighting.")
        end
    end
end

hook.Add("Think", "SMHFaceTracking_Calibrate", function()
    Calib.Tick(math.min(FrameTime(), 0.1))
end)

function Calib.Draw()
    if Calib.phase == "idle" then return end
    local cx = ScrW() / 2
    local title, body, left, total
    if Calib.phase == "relax" then
        title = "CALIBRATION 1/2: RELAX"
        body = "Relax your face and look at the camera"
        total = CALIB_RELAX
    else
        title = "CALIBRATION 2/2: EXPRESSIONS"
        body = "Open wide, smile, frown, pucker, blink, brows up and down, puff cheeks, look around"
        total = CALIB_RANGE
    end
    left = math.max(0, total - Calib.elapsed)
    if Calib.msg ~= "" then body = Calib.msg end

    draw.RoundedBox(8, cx - 380, 40, 760, 130, Color(0, 0, 0, 190))
    draw.SimpleText(title, "DermaLarge", cx, 50, Color(255, 210, 90), TEXT_ALIGN_CENTER)
    draw.SimpleText(body, "DermaDefaultBold", cx, 92, color_white, TEXT_ALIGN_CENTER)
    draw.SimpleText(string.format("%.0f s left   (END cancels)", left), "DermaDefault", cx, 114,
        Color(200, 200, 200), TEXT_ALIGN_CENTER)
    draw.RoundedBox(3, cx - 340, 142, 680, 8, Color(60, 60, 60))
    draw.RoundedBox(3, cx - 340, 142, 680 * math.Clamp(Calib.elapsed / total, 0, 1), 8, Color(255, 210, 90))
end

hook.Add("Think", "SMHFaceTracking_Think", function()
    local now = CurTime()
    local dt = math.min(now - lastThink, 0.1)
    lastThink = now

    if mode == "none" then return end

    if not IsValid(target) then
        mode = "none"
        SetStatus("Target entity is gone. Select it and press Apply again.")
        return
    end

    local count = target:GetFlexNum()

    if mode == "live" then
        if now >= nextPoll then
            nextPoll = now + POLL_INTERVAL
            PollTracker()
            UpdateLiveStatus()
        end

        -- Raw mode skips the model-side smoothing too (alpha 1 = jump straight to the value).
        local alpha = rawInput and 1 or (1 - math.exp(-SMOOTH_RATE * dt))
        for _, f in ipairs(liveFlexes) do
            local goal = 0
            if f.formula then
                goal = f.formula()
            else
                -- Ordinary aliases use the strongest relevant source. HWM
                -- formulas above deliberately bypass this for signed/composite flexes.
                for _, src in ipairs(f.sources) do
                    local v = ShapeValue(src)
                    if v > goal then goal = v end
                end
            end
            if f.muted then
                goal = f.min
            else
                -- Preserve centered HWM defaults: apply tracking around 0.5
                -- for formula flexes, while retaining the user's gain control.
                if f.formula then
                    goal = 0.5 + (goal - 0.5) * strength * f.gain
                else
                    goal = goal * strength * f.gain
                end
            end
            goal = math.Clamp(goal, f.min, f.max)

            f.value = f.value + (goal - f.value) * alpha
            target:SetFlexWeight(f.idx, math.Clamp(f.value, f.min, f.max))
        end

        -- Eye direction is separate from facial flexes. The Eye target SMH
        -- modifier can record this target for timeline playback.
        if target.SetEyeTarget and latestGaze then
            -- Invert both axes: current user test reports gaze is mirrored.
            local gx = -math.Clamp((tonumber(latestGaze.x) or 0) - (neutralGaze.x or 0), -1, 1)
            local gy = -math.Clamp((tonumber(latestGaze.y) or 0) - (neutralGaze.y or 0), -1, 1)
            eyeGazeX = eyeGazeX + (gx - eyeGazeX) * alpha
            eyeGazeY = eyeGazeY + (gy - eyeGazeY) * alpha
            -- Match Garry's Mod's Eye Poser convention: pitch/yaw angles
            -- converted to a long local-space direction from the eye attachment.
            target:SetEyeTarget(Angle(eyeGazeY * 35, eyeGazeX * 35, 0):Forward() * 1000)
        elseif target.SetEyeTarget then
            target:SetEyeTarget(vector_origin)
            eyeGazeX, eyeGazeY = 0, 0
        end

        -- Send webcam head pose to the server-side ragdoll physics helper.
        -- This drives the visible ragdoll head live; it is not recorded to SMH.
        if headTrackingEnabled and latestHead and headBone ~= nil and headBone >= 0 then
            SendHeadRotation(true, CurrentHeadOffset())
        elseif headTrackingEnabled then
            SendHeadRotation(false, angle_zero)
        end

    elseif mode == "pulse" then
        local w = (math.sin(now * 3) + 1) * 0.5 * 0.6
        for i = 0, count - 1 do
            local _, max = target:GetFlexBounds(i)
            target:SetFlexWeight(i, w * max)
        end

    elseif mode == "sweep" then
        local t = (now - sweepStart) / SWEEP_TIME
        local idx = math.floor(t)

        if idx >= count then
            StopTest()
            SetStatus("Sweep finished.")
            return
        end

        if idx ~= sweepIndex then
            if sweepIndex >= 0 then
                target:SetFlexWeight(sweepIndex, 0)
            end
            sweepIndex = idx
            local name = target:GetFlexName(idx) or "?"
            print("[SMH Face] flex " .. idx .. ": " .. name)
            SetStatus("Sweep " .. (idx + 1) .. "/" .. count .. ": " .. name)
        end

        local _, max = target:GetFlexBounds(idx)
        target:SetFlexWeight(idx, math.sin((t - idx) * math.pi) * max)
    end
end)

local function AddButton(parent, text, func)
    local b = vgui.Create("DButton", parent)
    b:SetText(text)
    b:SetTall(30)
    b:Dock(TOP)
    b:DockMargin(0, 0, 0, 6)
    b.DoClick = func
    return b
end

local function OpenProfileEditor()
    if not IsValid(target) then
        SetStatus("Apply Face Tracking to a model first.")
        return
    end
    if #liveFlexes == 0 then
        BuildLiveFlexes()
    end
    if #liveFlexes == 0 then
        SetStatus("No flexes match the current tracker mapping on this model.")
        return
    end

    local editor = vgui.Create("DFrame")
    profileEditorFrame = editor
    editor:SetTitle("Face Flex Profile - " .. (target:GetModel() or "model"))
    -- Fit the editor to the current screen; the flex list itself scrolls.
    local editorW = math.min(650, math.max(420, ScrW() - 40))
    local editorH = math.min(720, math.max(360, ScrH() - 60))
    editor:SetSize(editorW, editorH)
    editor:Center()
    editor:DockPadding(10, 34, 10, 10)
    editor:MakePopup()
    -- Use a light editor surface with dark text for better contrast.
    editor.Paint = function(self, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(235, 235, 235))
        draw.RoundedBoxEx(6, 0, 0, w, 28, Color(205, 205, 205), true, true, false, false)
    end

    local help = vgui.Create("DLabel", editor)
    help:Dock(TOP)
    help:SetTall(38)
    help:SetWrap(true)
    help:SetTextColor(Color(45, 45, 45))
    help:SetText("Search by flex name or tracking input. Mute a flex that deforms the model badly; settings save per model.")

    local search = vgui.Create("DTextEntry", editor)
    search:Dock(TOP)
    search:SetTall(28)
    search:DockMargin(0, 0, 0, 8)
    search:SetPlaceholderText("Search flexes or inputs...")

    local scroll = vgui.Create("DScrollPanel", editor)
    scroll:Dock(FILL)

    local profileRows = {}
    for _, f in ipairs(liveFlexes) do
        local row = vgui.Create("DPanel", scroll)
        row:Dock(TOP)
        row:SetTall(64)
        row:DockMargin(0, 0, 0, 4)
        row.Paint = function(self, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(250, 250, 250))
        end
        profileRows[#profileRows + 1] = { panel = row, flex = f, searchText = string.lower(f.name .. " " .. table.concat(f.sources, " ")) }

        local title = vgui.Create("DLabel", row)
        title:SetPos(8, 4)
        title:SetSize(220, 20)
        title:SetFont("DermaDefault")
        title:SetText(f.name .. "  <-  " .. table.concat(f.sources, ", "))
        title:SetTextColor(Color(35, 35, 35))

        local mute = vgui.Create("DCheckBoxLabel", row)
        mute:SetPos(270, 4)
        mute:SetText("Muted")
        mute:SetTextColor(Color(35, 35, 35))
        mute:SetValue(f.muted and 1 or 0)
        mute:SizeToContents()
        mute.OnChange = function(_, value)
            f.muted = value and true or false
            flexProfile[f.name] = flexProfile[f.name] or {}
            flexProfile[f.name].muted = f.muted
            SaveProfile()
        end

        local gain = vgui.Create("DNumSlider", row)
        gain:SetPos(6, 25)
        gain:SetSize(470, 32)
        gain:SetText("Gain")
        if IsValid(gain.Label) then
            gain.Label:SetTextColor(Color(35, 35, 35))
        end
        gain:SetMin(0)
        gain:SetMax(3)
        gain:SetDecimals(2)
        gain:SetValue(f.gain)
        gain.OnValueChanged = function(_, value)
            f.gain = math.Clamp(value, 0, 3)
            flexProfile[f.name] = flexProfile[f.name] or {}
            flexProfile[f.name].gain = f.gain
            SaveProfile()
        end

        -- Reflow controls when the scroll panel finishes assigning row width.
        row.PerformLayout = function(self, w, h)
            title:SetSize(math.max(120, w - 130), 20)
            mute:SetPos(math.max(250, w - 105), 4)
            gain:SetSize(math.max(280, w - 12), 32)
        end
    end

    local function FilterProfileRows()
        local query = string.Trim(string.lower(search:GetValue() or ""))
        for _, item in ipairs(profileRows) do
            local show = query == "" or string.find(item.searchText, query, 1, true) ~= nil
            item.panel:SetVisible(show)
            if show then
                item.panel:SetTall(64)
            else
                item.panel:SetTall(0)
            end
        end
        scroll:InvalidateLayout(true)
    end
    search.OnChange = FilterProfileRows
end

local function OpenMenu()
    if IsValid(frame) then
        if frame.SetVisible then frame:SetVisible(true) end
        if frame.SetMinimized then frame:SetMinimized(false) end
        frame:MakePopup()
        return
    end

    frame = vgui.Create("DFrame")
    frame:SetTitle("SMH Face Tracking")
    -- Responsive window plus a scrollable content area prevents controls from
    -- being cut off on shorter screens or when the UI scale is increased.
    local frameW = math.min(360, math.max(300, ScrW() - 30))
    local frameH = math.min(520, math.max(320, ScrH() - 70))
    frame:SetSize(frameW, frameH)
    frame:SetPos(20, math.min(80, math.max(10, ScrH() - frameH - 20)))
    frame:DockPadding(10, 34, 10, 10)
    frame:MakePopup()
    frame.OnClose = function()
        StopTest()
    end

    local content = vgui.Create("DScrollPanel", frame)
    content:Dock(FILL)

    statusLabel = vgui.Create("DLabel", content)
    statusLabel:Dock(TOP)
    statusLabel:SetTall(60)
    statusLabel:SetWrap(true)
    statusLabel:SetText("Select an entity in SMH, then press Apply Face Tracking.")

    -- Main steps, in the order you use them.
    AddButton(content, "Apply Face Tracking", ApplyFaceTracking)

    local liveButton = AddButton(content, "Start Live Tracking", function()
        if mode == "live" then
            StopTest()
            SetStatus("Live tracking stopped. Face reset.")
        else
            StartLive()
        end
    end)
    liveButton.Think = function(self)
        local want = (mode == "live") and "Stop Live Tracking" or "Start Live Tracking"
        if self._shownText ~= want then
            self._shownText = want
            self:SetText(want)
        end
    end

    AddButton(content, "Calibrate Face", function() Calib.Start() end)
    AddButton(content, "Record Tracked Face", function() FaceRec.OpenWindow() end)
    AddButton(content, "Capture Face at Current SMH Frame", CaptureFaceTrackFrame)

    -- Live tuning
    local smoothSlider = vgui.Create("DNumSlider", content)
    smoothSlider:Dock(TOP)
    smoothSlider:SetTall(30)
    smoothSlider:DockMargin(0, 4, 0, 4)
    smoothSlider:SetText("Smoothness")
    smoothSlider:SetTooltip("Higher = steadier face with less jitter. Fast moves such as blinks stay quick either way.")
    smoothSlider:SetMin(0)
    smoothSlider:SetMax(100)
    smoothSlider:SetDecimals(0)
    smoothSlider:SetValue(math.floor(smoothness * 100 + 0.5))
    smoothSlider.OnValueChanged = function(_, val)
        smoothness = math.Clamp((tonumber(val) or 50) / 100, 0, 1)
    end

    local rawToggle = vgui.Create("DCheckBoxLabel", content)
    rawToggle:SetText("Raw camera input (no smoothing)")
    rawToggle:SetTooltip("Uses the camera values exactly as they arrive. Try this if the smoothing looks wrong.")
    rawToggle:SetValue(rawInput and 1 or 0)
    rawToggle:Dock(TOP)
    rawToggle:DockMargin(0, 0, 0, 8)
    rawToggle.OnChange = function(_, val)
        rawInput = val and true or false
        euroFilters = {} -- start the adaptive filter fresh when it is switched back on
        lastTrackerT = nil
        SetStatus(rawInput and "Raw camera input is ON: no smoothing at all."
            or "Smoothing is back on.")
    end

    local slider = vgui.Create("DNumSlider", content)
    slider:Dock(TOP)
    slider:SetTall(30)
    slider:DockMargin(0, 0, 0, 6)
    slider:SetText("Strength")
    slider:SetMin(0.5)
    slider:SetMax(3)
    slider:SetDecimals(1)
    slider:SetValue(strength)
    slider.OnValueChanged = function(_, val)
        strength = val
    end

    local overlayToggle = vgui.Create("DCheckBoxLabel", content)
    overlayToggle:SetText("Show live tracking overlay in-game")
    overlayToggle:SetTooltip("Shows what is being tracked in the corner of the screen.")
    overlayToggle:SetValue(inGameOverlayEnabled and 1 or 0)
    overlayToggle:Dock(TOP)
    overlayToggle:DockMargin(0, 0, 0, 8)
    overlayToggle.OnChange = function(_, val)
        inGameOverlayEnabled = val and true or false
    end

    local headToggle = vgui.Create("DCheckBoxLabel", content)
    headToggle:SetText("Show head movement live on the model (preview)")
    headToggle:SetTooltip("Rotates the model's head while you track. To RECORD the head, use the option in Record Tracked Face.")
    headToggle:SetValue(headTrackingEnabled and 1 or 0)
    headToggle:Dock(TOP)
    headToggle:DockMargin(0, 0, 0, 8)
    headToggle.OnChange = function(_, val)
        headTrackingEnabled = val and true or false
        if not headTrackingEnabled then ResetHeadRotation() end
        if headTrackingEnabled and (headBone == nil or headBone < 0) then
            SetStatus("Head tracking enabled, but this model has no ValveBiped.Bip01_Head1 bone.")
        else
            SetStatus(headTrackingEnabled and "Head tracking enabled. Run Calibrate Face while facing forward." or "Head tracking disabled.")
        end
    end

    -- Rarely needed settings are folded away.
    local advOpen = false
    local advPanel
    local advButton
    local ADV_HEIGHT = 170

    advButton = AddButton(content, "Advanced  >", function()
        advOpen = not advOpen
        advPanel:SetVisible(advOpen)
        advPanel:SetTall(advOpen and ADV_HEIGHT or 0)
        advButton:SetText(advOpen and "Advanced  v" or "Advanced  >")
        content:InvalidateLayout(true)
    end)

    advPanel = vgui.Create("DPanel", content)
    advPanel:Dock(TOP)
    advPanel:SetPaintBackground(false)
    advPanel:SetTall(0)
    advPanel:SetVisible(false)

    local poseTitle = vgui.Create("DLabel", advPanel)
    poseTitle:Dock(TOP)
    poseTitle:SetTall(20)
    poseTitle:SetText("Pose Base (rig type)")
    poseTitle:SetFont("DermaDefaultBold")

    local poseCombo = vgui.Create("DComboBox", advPanel)
    poseCombo:Dock(TOP)
    poseCombo:SetTall(26)
    poseCombo:DockMargin(0, 0, 0, 5)
    poseCombo:SetValue("Default (auto-detect)")
    local poseChoices = {
        { label = "Default (auto-detect)", value = "default" },
        { label = "TF2 HWM", value = "tf2_hwm" },
        { label = "Source / Kleiner", value = "source_kleiner" },
        { label = "ARKit", value = "arkit" },
        { label = "Custom / aliases only", value = "custom" },
    }
    for _, choice in ipairs(poseChoices) do poseCombo:AddChoice(choice.label, choice.value) end
    poseCombo.OnSelect = function(_, _, label, value)
        poseBase = value or "default"
        poseCombo:SetValue(label or "Default (auto-detect)")
        if IsValid(target) then
            BuildLiveFlexes()
            SetStatus("Pose Base: " .. (label or poseBase) .. "\n" .. (detectedPoseBase or "unknown") .. "\nRebuilt mapping for current target.")
        else
            SetStatus("Pose Base selected: " .. (label or poseBase) .. "\nSelect a target and press Apply Face Tracking.")
        end
    end

    local swap = vgui.Create("DCheckBoxLabel", advPanel)
    swap:SetText("Swap left / right")
    swap:SetValue(swapSides and 1 or 0)
    swap:Dock(TOP)
    swap:DockMargin(0, 0, 0, 8)
    swap.OnChange = function(_, val)
        swapSides = val and true or false
    end

    AddButton(advPanel, "Edit Model Flex Profile", OpenProfileEditor)
    AddButton(advPanel, "Reset Face", function()
        StopTest()
        SetStatus("Face reset.")
    end)
end

-- In-game overlay. The drawing code lives in FaceRec.DrawOverlay (further down)
-- so the same panel can also show the countdown and the recording status.
hook.Add("HUDPaint", "SMH_FaceTracking_InGameOverlay", function()
    if FaceRec and FaceRec.DrawOverlay then FaceRec.DrawOverlay() end
    if Calib and Calib.Draw then Calib.Draw() end
end)

concommand.Add("smh_face_menu", OpenMenu)

-- Follow the Stop Motion Helper UI, like the Kinect recorder does.
-- The face panel is created when SMH opens, starts minimized, and closes when
-- SMH closes. It no longer opens by itself when the game starts. The user can
-- restore it from the taskbar/title bar or use smh_face_menu at any time.
local smhFaceWasOpen = false
local smhFacePanelAutoMinimize = false

local function IsSMHMenuOpen()
    return SMH ~= nil
        and SMH.UI ~= nil
        and isfunction(SMH.UI.IsOpen)
        and SMH.UI.IsOpen() == true
end

hook.Add("Think", "SMH_FaceTracking_FollowSMH", function()
    local smhOpen = IsSMHMenuOpen()

    if smhOpen and not smhFaceWasOpen then
        smhFaceWasOpen = true
        smhFacePanelAutoMinimize = true

        if not IsValid(frame) then
            OpenMenu()
        else
            frame:SetVisible(true)
        end

        -- Minimize after the panel has been created/shown so it does not cover
        -- the SMH timeline or the Kinect recorder window.
        timer.Simple(0, function()
            if IsValid(frame) and frame.SetMinimized then
                frame:SetMinimized(true)
            end
        end)

    elseif not smhOpen and smhFaceWasOpen then
        smhFaceWasOpen = false
        if IsValid(frame) and FaceRec.phase == "idle" then
            frame:Close()
        end
    end
end)

-- ===========================================================================
-- Record Tracked Face
-- Timed recording of the live tracked face into a chosen SMH timeline.
--   * get-ready countdown (0-10 s) with a big on-screen number
--   * our windows hide while you perform; they come back when it ends
--   * the SMH timeline can play along so you can act to the body animation
--   * an in-game overlay shows what is being tracked while you record
--   * frames are kept in memory while recording and sent to SMH afterwards,
--     a few per tick, so the reliable channel is never flooded
-- Stop early with the END key (or the small Stop button, or smh_face_record_stop).
-- ===========================================================================

surface.CreateFont("SMHFaceCountdown", { font = "Arial", size = 180, weight = 900, antialias = true })

-- Bars shown in the overlay. Values are the same neutral-corrected numbers the
-- flex mapping uses, so the overlay shows what the model is actually receiving.
local OVERLAY_BARS = {
    { "Jaw open",   { "jawOpen" } },
    { "Smile L",    { "mouthSmileLeft" } },
    { "Smile R",    { "mouthSmileRight" } },
    { "Frown",      { "mouthFrownLeft", "mouthFrownRight" } },
    { "Pucker",     { "mouthPucker" } },
    { "Funnel",     { "mouthFunnel" } },
    { "Blink L",    { "eyeBlinkLeft" } },
    { "Blink R",    { "eyeBlinkRight" } },
    { "Brow up",    { "browInnerUp", "browOuterUpLeft", "browOuterUpRight" } },
    { "Brow down",  { "browDownLeft", "browDownRight" } },
    { "Squint",     { "eyeSquintLeft", "eyeSquintRight" } },
    { "Cheek puff", { "cheekPuff" } },
}

FaceRec.sendPerTick = 4   -- keyframes sent to the server per tick while saving

function FaceRec.Say(text)
    FaceRec.status = text
    SetStatus(text)
end

-- --------------------------------------------------------------------------
-- Hiding and restoring our own windows
-- --------------------------------------------------------------------------

function FaceRec.HideUI()
    FaceRec.hidden = {}
    local panels = {}
    if IsValid(frame) then panels[#panels + 1] = frame end
    if IsValid(FaceRec.window) then panels[#panels + 1] = FaceRec.window end
    if IsValid(profileEditorFrame) then panels[#panels + 1] = profileEditorFrame end
    for _, p in ipairs(panels) do
        if p:IsVisible() then
            FaceRec.hidden[#FaceRec.hidden + 1] = p
            p:SetVisible(false)
        end
    end
end

function FaceRec.ShowUI()
    local smhOpen = SMH ~= nil and SMH.UI ~= nil and isfunction(SMH.UI.IsOpen) and SMH.UI.IsOpen() == true
    for _, p in ipairs(FaceRec.hidden) do
        if IsValid(p) then
            if p == frame and not smhOpen then
                p:Close() -- same as the follow-SMH behaviour: no SMH menu, no face panel
            else
                p:SetVisible(true)
            end
        end
    end
    FaceRec.hidden = {}
end

function FaceRec.CreateStopButton()
    if IsValid(FaceRec.stopButton) then FaceRec.stopButton:Remove() end
    local b = vgui.Create("DButton")
    b:SetText("Stop recording  (END)")
    b:SetSize(190, 30)
    b:SetPos(ScrW() / 2 - 95, ScrH() - 70)
    b.DoClick = function() FaceRec.StopRequest() end
    FaceRec.stopButton = b
end

-- --------------------------------------------------------------------------
-- Recording
-- --------------------------------------------------------------------------

function FaceRec.MatchLength()
    local st = SMH and SMH.State
    if not st then return end
    local length = tonumber(st.PlaybackLength) or 100
    local current = tonumber(st.Frame) or 0
    FaceRec.frames = math.Clamp(math.floor(length - current), 1, 1000)
end

function FaceRec.StopSMH(resetFrame)
    if FaceRec.playing then
        if SMH and SMH.Controller and isfunction(SMH.Controller.StopPlayback) then
            SMH.Controller.StopPlayback()
        end
        FaceRec.playing = false
        if resetFrame and SMH and SMH.Controller and isfunction(SMH.Controller.SetFrame) then
            SMH.Controller.SetFrame(FaceRec.startFrame)
        end
    end
end

function FaceRec.Close(msg)
    FaceRec.phase = "idle"
    FaceRec.buffer = {}
    if IsValid(FaceRec.stopButton) then FaceRec.stopButton:Remove() end
    FaceRec.ShowUI()
    FaceRec.Say(msg or "Done.")
    FaceRec.UpdateInfo()
end

function FaceRec.Cancel(msg)
    FaceRec.StopSMH(true)
    FaceRec.Close(msg)
end

function FaceRec.StopRequest()
    if FaceRec.phase == "countdown" then
        FaceRec.Cancel("Cancelled during the countdown. Nothing was recorded.")
    elseif FaceRec.phase == "recording" then
        FaceRec.Finish("Stopped early.")
    end
end

function FaceRec.Start()
    if FaceRec.phase ~= "idle" then return end
    if not SMH or not SMH.State or not SMH.Controller then
        FaceRec.Say("Stop Motion Helper is not available.")
        return
    end
    if not IsValid(target) then
        FaceRec.Say("Press Apply Face Tracking first.")
        return
    end
    if FaceRec.headOverlay and FaceRec.headTimeline == FaceRec.timeline then
        FaceRec.Say("The body timeline for the head overlay must be a different timeline from the face timeline.")
        return
    end
    if mode ~= "live" then StartLive() end

    FaceRec.usedOverlay = FaceRec.headOverlay
    FaceRec.buffer = {}
    FaceRec.lost = 0
    FaceRec.lastIndex = -1
    FaceRec.sendIndex = 1
    FaceRec.playing = false
    FaceRec.endHeld = input.IsKeyDown(KEY_END)
    FaceRec.goTime = SysTime() + FaceRec.prepSeconds
    FaceRec.phase = "countdown"
    FaceRec.HideUI()
    FaceRec.CreateStopButton()
    FaceRec.Say("Countdown running. Recording starts when it reaches 0.")
end

function FaceRec.BeginRecording(now)
    local st = SMH.State
    FaceRec.startFrame = math.max(0, math.floor(tonumber(st.Frame) or 0))
    FaceRec.rate = math.Clamp(tonumber(st.PlaybackRate) or 30, 1, 240)
    FaceRec.t0 = now
    FaceRec.lastIndex = -1
    FaceRec.playing = false
    if FaceRec.playSMH and isfunction(SMH.Controller.StartPlayback) then
        SMH.Controller.StartPlayback()
        FaceRec.playing = true
    end
    FaceRec.phase = "recording"
end

-- Remember the face for sampled frame number i (0 = first recorded frame).
function FaceRec.Sample(i)
    if trackerState ~= "live" then FaceRec.lost = FaceRec.lost + 1 end

    local keep = (i % FaceRec.interval == 0) or (i == FaceRec.frames - 1)
    if not keep then return end

    -- Webcam data arrives a little late; the latency setting shifts it earlier.
    local f = FaceRec.startFrame + i - FaceRec.latency
    if f < 0 then return end

    local n = math.min(target:GetFlexNum() or 0, 1023)
    local w = {}
    for k = 0, n - 1 do
        w[k] = target:GetFlexWeight(k) or 0
    end
    local head = nil
    if FaceRec.headOverlay then
        local off = CurrentHeadOffset()
        if off then head = { p = off.p, y = off.y, r = off.r } end
    end
    FaceRec.buffer[#FaceRec.buffer + 1] = {
        frame = f,
        scale = target:GetFlexScale() or 1,
        count = n,
        w = w,
        eye = CurrentEyeVector(), -- eye movement is always recorded
        head = head,
    }
end

-- Keep the JSON backup that the single-frame capture also writes.
function FaceRec.WriteBackup()
    local key = tostring(FaceRec.timeline)
    faceTrack.tracks[key] = faceTrack.tracks[key] or { model = target:GetModel(), frames = {} }
    faceTrack.tracks[key].model = target:GetModel()
    for _, e in ipairs(FaceRec.buffer) do
        local values = {}
        for k = 0, e.count - 1 do
            local name = target:GetFlexName(k)
            if name then values[name] = e.w[k] or 0 end
        end
        faceTrack.tracks[key].frames[tostring(e.frame)] = { frame = e.frame, flexes = values }
    end
    faceRecordCount = faceRecordCount + #FaceRec.buffer
    SaveFaceTrack()
end

function FaceRec.Finish(msg)
    FaceRec.StopSMH(false)
    FaceRec.finishMsg = msg
    if #FaceRec.buffer == 0 then
        FaceRec.Close(msg .. " Nothing was captured.")
        return
    end
    FaceRec.WriteBackup()
    FaceRec.sendIndex = 1
    FaceRec.phase = "saving"
    FaceRec.Say(msg .. " Saving " .. #FaceRec.buffer .. " keyframes to SMH timeline " .. FaceRec.timeline .. "...")
end

-- Optional extras after the weights: the eye target, and the head rotation that
-- the server writes into an existing body timeline (overlayTimeline).
function FaceRec.WriteExtras(eye, overlayTimeline, head)
    net.WriteBool(eye ~= nil)
    if eye then
        net.WriteFloat(eye.x)
        net.WriteFloat(eye.y)
        net.WriteFloat(eye.z)
    end
    local ot = (overlayTimeline and head) and math.floor(overlayTimeline) or 0
    net.WriteUInt(ot, 8)
    if ot > 0 then
        net.WriteFloat(head.p)
        net.WriteFloat(head.y)
        net.WriteFloat(head.r)
    end
end

function FaceRec.SendKeyframe(ent, frameNumber, timelineNumber, scale, weights, count, eye, head)
    net.Start(FACE_KEYFRAME_NET)
    net.WriteEntity(ent)
    net.WriteUInt(math.floor(frameNumber), 32)
    net.WriteUInt(math.floor(timelineNumber), 8)
    net.WriteFloat(scale)
    net.WriteUInt(count, 10)
    for i = 0, count - 1 do
        net.WriteFloat(weights[i] or 0)
    end
    FaceRec.WriteExtras(eye, FaceRec.headOverlay and FaceRec.headTimeline or nil, head)
    net.SendToServer()
end

function FaceRec.Tick()
    local phase = FaceRec.phase
    if phase == "idle" then return end

    if not IsValid(target) then
        FaceRec.Cancel("The target entity is gone. Nothing was saved.")
        return
    end

    if phase == "saving" then
        local sent = 0
        while sent < FaceRec.sendPerTick and FaceRec.sendIndex <= #FaceRec.buffer do
            local e = FaceRec.buffer[FaceRec.sendIndex]
            FaceRec.SendKeyframe(target, e.frame, FaceRec.timeline, e.scale, e.w, e.count, e.eye, e.head)
            FaceRec.sendIndex = FaceRec.sendIndex + 1
            sent = sent + 1
        end
        if FaceRec.sendIndex > #FaceRec.buffer then
            local count = #FaceRec.buffer
            local lostText = FaceRec.lost > 0 and (" Tracking was lost on " .. FaceRec.lost .. " frame(s).") or ""
            if SMH and SMH.Controller and isfunction(SMH.Controller.SetFrame) then
                SMH.Controller.SetFrame(FaceRec.startFrame)
            end
            if FaceRec.usedOverlay then
                net.Start(HEAD_DONE_NET)
                net.WriteEntity(target)
                net.SendToServer()
            end
            FaceRec.Close((FaceRec.finishMsg or "Done.") .. " Saved " .. count .. " keyframes to SMH timeline " ..
                FaceRec.timeline .. "." .. lostText)
        end
        return
    end

    -- END key stops (or cancels) without needing any window.
    local down = input.IsKeyDown(KEY_END)
    if down and not FaceRec.endHeld then
        FaceRec.endHeld = true
        FaceRec.StopRequest()
        return
    end
    if not down then FaceRec.endHeld = false end

    if mode ~= "live" then
        if phase == "countdown" then
            FaceRec.Cancel("Live tracking stopped, so the recording was cancelled.")
        else
            FaceRec.Finish("Live tracking stopped.")
        end
        return
    end

    local now = SysTime()

    if phase == "countdown" then
        if now >= FaceRec.goTime then FaceRec.BeginRecording(now) end
        return
    end

    -- recording
    local elapsed = (now - FaceRec.t0) * FaceRec.rate
    local idx = math.min(math.floor(elapsed), FaceRec.frames - 1)
    while FaceRec.lastIndex < idx do
        FaceRec.lastIndex = FaceRec.lastIndex + 1
        FaceRec.Sample(FaceRec.lastIndex)
    end
    if elapsed >= FaceRec.frames then
        FaceRec.Finish("Finished.")
    end
end

hook.Add("Think", "SMHFaceTracking_Recorder", function()
    FaceRec.Tick()
end)

concommand.Add("smh_face_record", function() FaceRec.OpenWindow() end)
concommand.Add("smh_face_record_stop", function() FaceRec.StopRequest() end)

-- --------------------------------------------------------------------------
-- Overlay
-- --------------------------------------------------------------------------

function FaceRec.DrawOverlay()
    local phase = FaceRec.phase
    if not inGameOverlayEnabled and phase == "idle" then return end

    local sw, sh = ScrW(), ScrH()
    local now = SysTime()
    local recording = phase == "recording"

    -- A pulsing red frame around the screen while recording.
    if recording then
        local a = 90 + 80 * (0.5 + 0.5 * math.sin(now * 6))
        surface.SetDrawColor(225, 45, 45, a)
        surface.DrawOutlinedRect(0, 0, sw, sh, 4)
        draw.SimpleText("Recording...  press END to stop early", "DermaLarge", sw / 2, sh - 100,
            Color(255, 255, 255, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- Big countdown number in the middle of the screen.
    if phase == "countdown" then
        local remain = math.max(0, FaceRec.goTime - now)
        draw.SimpleTextOutlined(tostring(math.max(1, math.ceil(remain))), "SMHFaceCountdown",
            sw / 2, sh / 2, Color(255, 60, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 3, Color(0, 0, 0, 220))
        draw.SimpleText("Get ready - recording starts at 0", "DermaLarge", sw / 2, sh / 2 + 120,
            Color(255, 255, 255, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText("Press END to cancel", "DermaDefaultBold", sw / 2, sh / 2 + 150,
            Color(220, 225, 234, 235), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    -- Panel contents depend on the phase.
    local line1, line2, progress
    if phase == "countdown" then
        line1 = string.format("Starts in %.1f s", math.max(0, FaceRec.goTime - now))
        line2 = string.format("Timeline %d  |  keyframe every %d frame(s)", FaceRec.timeline, FaceRec.interval)
    elseif recording then
        local done = math.min(FaceRec.lastIndex + 1, FaceRec.frames)
        line1 = string.format("Frame %d / %d   (%.1f / %.1f s)", done, FaceRec.frames,
            done / FaceRec.rate, FaceRec.frames / FaceRec.rate)
        if FaceRec.lost > 0 then
            line2 = string.format("Tracking lost on %d frame(s)", FaceRec.lost)
        else
            line2 = string.format("Timeline %d  |  start frame %d", FaceRec.timeline, FaceRec.startFrame)
        end
        progress = done / FaceRec.frames
    elseif phase == "saving" then
        local doneSending = math.min(FaceRec.sendIndex - 1, #FaceRec.buffer)
        line1 = string.format("Saving keyframes %d / %d", doneSending, #FaceRec.buffer)
        line2 = "Keep the game running until this finishes"
        progress = doneSending / math.max(1, #FaceRec.buffer)
    else
        line1 = "Calibration: " .. (next(calibHi) ~= nil and "done" or "not done (press Calibrate Face)")
        line2 = FaceRec.headOverlay and ("Head is recorded onto timeline " .. FaceRec.headTimeline)
            or (headTrackingEnabled and "Head is a live preview only (not recorded)" or "")
    end

    local W = 300
    local rows = #OVERLAY_BARS
    local H = 30 + 24 + 46 + rows * 15 + 22
    local margin = 16
    local corner = FaceRec.corner
    local x = (corner == "tl" or corner == "bl") and margin or (sw - W - margin)
    local y = (corner == "tl" or corner == "tr") and 80 or (sh - H - 80)

    draw.RoundedBox(8, x, y, W, H, Color(18, 21, 27, 225))
    draw.RoundedBoxEx(8, x, y, W, 30, Color(38, 45, 56, 245), true, true, false, false)
    draw.SimpleText("FACE TRACKING", "DermaDefaultBold", x + 12, y + 15,
        Color(235, 240, 248), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    local tag, tagColor
    if recording then
        tag = (math.floor(now * 2) % 2 == 0) and "REC" or "rec"
        tagColor = Color(255, 80, 80)
    elseif phase == "countdown" then
        tag, tagColor = "GET READY", Color(255, 200, 90)
    elseif phase == "saving" then
        tag, tagColor = "SAVING", Color(120, 200, 255)
    else
        tag, tagColor = "LIVE", Color(90, 225, 140)
    end
    draw.SimpleText(tag, "DermaDefaultBold", x + W - 12, y + 15, tagColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

    local stateText = trackerState == "live" and "FACE TRACKED"
        or trackerState == "noface" and "NO FACE DETECTED"
        or trackerState == "stale" and "TRACKER STALE"
        or "WAITING FOR TRACKER"
    local stateColor = trackerState == "live" and Color(90, 225, 140) or Color(245, 185, 90)
    draw.SimpleText(stateText, "DermaDefaultBold", x + 12, y + 30 + 12, stateColor,
        TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    local iy = y + 30 + 24
    draw.SimpleText(line1, "DermaDefault", x + 12, iy + 8, Color(235, 240, 248), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    draw.SimpleText(line2, "DermaDefault", x + 12, iy + 24, Color(190, 197, 210), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    if progress then
        draw.RoundedBox(3, x + 12, iy + 36, W - 24, 6, Color(55, 61, 72, 255))
        local pw = math.floor((W - 24) * math.Clamp(progress, 0, 1))
        if pw > 0 then
            draw.RoundedBox(3, x + 12, iy + 36, pw, 6, recording and Color(235, 85, 85) or Color(85, 195, 235))
        end
    end

    local by0 = iy + 46
    for i, item in ipairs(OVERLAY_BARS) do
        local sum = 0
        for _, src in ipairs(item[2]) do sum = sum + ShapeValue(src) end
        local v = math.Clamp(sum / #item[2], 0, 1)

        local by = by0 + (i - 1) * 15 + 7
        draw.SimpleText(item[1], "DermaDefault", x + 12, by, Color(220, 225, 234),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.RoundedBox(3, x + 100, by - 4, 112, 8, Color(55, 61, 72, 255))
        local bw = math.floor(112 * v)
        if bw > 0 then draw.RoundedBox(3, x + 100, by - 4, bw, 8, Color(85, 195, 235, 255)) end
        draw.SimpleText(string.format("%.2f", v), "DermaDefault", x + 222, by,
            Color(235, 240, 248), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    draw.SimpleText("END = stop / cancel", "DermaDefault", x + 12, y + H - 12,
        Color(150, 158, 172), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
end

-- --------------------------------------------------------------------------
-- The "Record Tracked Face" window
-- --------------------------------------------------------------------------

function FaceRec.UpdateInfo()
    if not IsValid(FaceRec.info) then return end

    local trackerText
    if mode ~= "live" then
        trackerText = "not started (it starts when you press Start)"
    elseif trackerState == "live" then
        trackerText = "face found"
    elseif trackerState == "noface" then
        trackerText = "running, but no face seen"
    elseif trackerState == "stale" then
        trackerText = "tracker data is old - is face_tracker.py running?"
    else
        trackerText = "no data - is face_tracker.py running?"
    end

    local st = SMH and SMH.State or {}
    local lines = {
        IsValid(target) and ("Target: " .. tostring(target:GetModel()))
            or "Target: none (press Apply Face Tracking first)",
        "Tracker: " .. trackerText,
        "Calibration: " .. (next(calibHi) ~= nil and "done" or "not done (press Calibrate Face for best accuracy)"),
        string.format("SMH: frame %s, rate %s fps, length %s frames",
            tostring(st.Frame or "?"), tostring(st.PlaybackRate or "?"), tostring(st.PlaybackLength or "?")),
    }
    if FaceRec.status and FaceRec.status ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Last: " .. FaceRec.status
    end
    FaceRec.info:SetText(table.concat(lines, "\n"))
end

function FaceRec.UpdateFramesLabel()
    if not IsValid(FaceRec.framesInfo) then return end
    local rate = (SMH and SMH.State and tonumber(SMH.State.PlaybackRate)) or 30
    FaceRec.framesInfo:SetText(string.format("= %.1f seconds at %d fps", FaceRec.frames / math.max(1, rate), rate))
end

function FaceRec.OpenWindow()
    if FaceRec.phase ~= "idle" then return end

    if IsValid(FaceRec.window) then
        FaceRec.window:SetVisible(true)
        FaceRec.window:MakePopup()
        FaceRec.UpdateInfo()
        return
    end

    if not FaceRec.initialised then
        FaceRec.initialised = true
        if SMH and SMH.State then
            FaceRec.timeline = math.Clamp(math.floor(tonumber(SMH.State.Timeline) or 1), 1, 10)
        end
        FaceRec.MatchLength()
    end

    local win = vgui.Create("DFrame")
    win:SetTitle("Record Tracked Face")
    win:SetSize(math.min(380, math.max(300, ScrW() - 30)), math.min(640, math.max(380, ScrH() - 70)))
    win:Center()
    win:DockPadding(10, 34, 10, 10)
    win:MakePopup()
    win.OnClose = function()
        timer.Remove("SMHFaceRecInfo")
    end
    FaceRec.window = win

    local content = vgui.Create("DScrollPanel", win)
    content:Dock(FILL)

    local info = vgui.Create("DLabel", content)
    info:Dock(TOP)
    info:SetTall(130)
    info:SetWrap(true)
    info:SetText("")
    FaceRec.info = info

    local function AddSlider(text, min, max, decimals, value, tip, onChange)
        local s = vgui.Create("DNumSlider", content)
        s:Dock(TOP)
        s:SetTall(30)
        s:DockMargin(0, 0, 0, 4)
        s:SetText(text)
        s:SetTooltip(tip)
        s:SetMin(min)
        s:SetMax(max)
        s:SetDecimals(decimals)
        s:SetValue(value)
        s.OnValueChanged = function(_, v) onChange(v) end
        return s
    end

    AddSlider("Get ready (seconds)", 0, 10, 0, FaceRec.prepSeconds,
        "Countdown before recording starts. Your windows hide when it begins.",
        function(v) FaceRec.prepSeconds = math.Clamp(math.floor(v + 0.5), 0, 10) end)

    AddSlider("Record to timeline", 1, 10, 0, FaceRec.timeline,
        "The SMH timeline that receives the face keyframes. Use one that only has Facial flexes ticked.",
        function(v) FaceRec.timeline = math.Clamp(math.floor(v + 0.5), 1, 10) end)

    local framesSlider = AddSlider("Frames to record", 1, 1000, 0, FaceRec.frames,
        "How many SMH frames to record, starting from the current SMH frame.",
        function(v)
            FaceRec.frames = math.Clamp(math.floor(v + 0.5), 1, 1000)
            FaceRec.UpdateFramesLabel()
        end)

    local framesInfo = vgui.Create("DLabel", content)
    framesInfo:Dock(TOP)
    framesInfo:SetTall(18)
    framesInfo:DockMargin(0, 0, 0, 4)
    framesInfo:SetText("")
    FaceRec.framesInfo = framesInfo
    FaceRec.UpdateFramesLabel()

    local matchButton = vgui.Create("DButton", content)
    matchButton:Dock(TOP)
    matchButton:SetTall(26)
    matchButton:DockMargin(0, 0, 0, 6)
    matchButton:SetText("Match SMH length from the current frame")
    matchButton.DoClick = function()
        FaceRec.MatchLength()
        framesSlider:SetValue(FaceRec.frames)
        FaceRec.UpdateFramesLabel()
    end

    AddSlider("Keyframe every N frames", 1, 5, 0, FaceRec.interval,
        "1 records every frame (best for speech). Higher numbers make fewer, smoother-looking keyframes.",
        function(v) FaceRec.interval = math.Clamp(math.floor(v + 0.5), 1, 5) end)

    AddSlider("Latency fix (frames)", 0, 10, 0, FaceRec.latency,
        "Webcam tracking arrives slightly late. Raise this to shift the recorded face earlier on the timeline.",
        function(v) FaceRec.latency = math.Clamp(math.floor(v + 0.5), 0, 10) end)

    local headCheck = vgui.Create("DCheckBoxLabel", content)
    headCheck:SetText("Record head movement onto a body timeline")
    headCheck:SetTooltip("Adds your tracked head rotation to the head bone of the EXISTING physics-bone keyframes. Off by default because it changes existing keyframes.")
    headCheck:SetValue(FaceRec.headOverlay and 1 or 0)
    headCheck:Dock(TOP)
    headCheck:DockMargin(0, 4, 0, 4)
    headCheck.OnChange = function(_, v) FaceRec.headOverlay = v and true or false end

    AddSlider("Body timeline (with Physics bones)", 1, 10, 0, FaceRec.headTimeline,
        "The existing timeline that holds the animated physics bones, for example your Kinect recording. It must differ from the face timeline.",
        function(v) FaceRec.headTimeline = math.Clamp(math.floor(v + 0.5), 1, 10) end)

    local headNote = vgui.Create("DLabel", content)
    headNote:Dock(TOP)
    headNote:SetTall(48)
    headNote:SetWrap(true)
    headNote:DockMargin(0, 0, 0, 6)
    headNote:SetText("Head overlay changes the body timeline's existing keyframes (only frames that already have one). Save your SMH animation first. Undo: type smh_face_head_undo in the console. Needs Calibrate Face done while facing forward.")

    local play = vgui.Create("DCheckBoxLabel", content)
    play:SetText("Play the SMH timeline while recording")
    play:SetTooltip("Starts SMH playback at the same moment, so you can act along to the body animation.")
    play:SetValue(FaceRec.playSMH and 1 or 0)
    play:Dock(TOP)
    play:DockMargin(0, 4, 0, 8)
    play.OnChange = function(_, v) FaceRec.playSMH = v and true or false end

    local cornerLabel = vgui.Create("DLabel", content)
    cornerLabel:Dock(TOP)
    cornerLabel:SetTall(18)
    cornerLabel:SetText("Overlay corner")

    local combo = vgui.Create("DComboBox", content)
    combo:Dock(TOP)
    combo:SetTall(24)
    combo:DockMargin(0, 0, 0, 10)
    local names = { tr = "Top right", tl = "Top left", br = "Bottom right", bl = "Bottom left" }
    combo:SetValue(names[FaceRec.corner] or "Top right")
    combo:AddChoice("Top right", "tr")
    combo:AddChoice("Top left", "tl")
    combo:AddChoice("Bottom right", "br")
    combo:AddChoice("Bottom left", "bl")
    combo.OnSelect = function(_, _, label, value)
        FaceRec.corner = value or "tr"
        combo:SetValue(label)
    end

    local startButton = vgui.Create("DButton", content)
    startButton:Dock(TOP)
    startButton:SetTall(40)
    startButton:DockMargin(0, 0, 0, 6)
    startButton:SetText("Start Recording")
    startButton.DoClick = function() FaceRec.Start() end

    local closeButton = vgui.Create("DButton", content)
    closeButton:Dock(TOP)
    closeButton:SetTall(28)
    closeButton:SetText("Close")
    closeButton.DoClick = function() win:Close() end

    timer.Create("SMHFaceRecInfo", 0.25, 0, function()
        if not IsValid(FaceRec.window) then
            timer.Remove("SMHFaceRecInfo")
            return
        end
        FaceRec.UpdateInfo()
    end)
    FaceRec.UpdateInfo()
end

concommand.Add("smh_face_physbones", ListHeadPhysicsMappings)

concommand.Add("smh_face_flexes", function()
    local ent = GetSMHEntity()
    if not ent then
        print("[SMH Face] No SMH entity selected.")
        return
    end
    print("[SMH Face] " .. ent:GetModel() .. " has " .. ent:GetFlexNum() .. " flexes:")
    for i = 0, ent:GetFlexNum() - 1 do
        print("  " .. i .. ": " .. (ent:GetFlexName(i) or "?"))
    end
end)


concommand.Add("smh_face_profile", function()
    if not IsValid(target) then
        print("[SMH Face] Apply Face Tracking to a model first.")
        return
    end
    print("[SMH Face] Current model: " .. (target:GetModel() or "unknown"))
    print("[SMH Face] Profile file: garrysmod/data/" .. (profilePath or "not loaded"))
    print("[SMH Face] Use the Edit Model Flex Profile button to change per-flex gain and mute settings.")
end)

concommand.Add("smh_face_capture_frame", function() CaptureFaceTrackFrame() end)
concommand.Add("smh_face_neutral", function() SetNeutral() end)
concommand.Add("smh_face_calibrate", function() Calib.Start() end)
concommand.Add("smh_face_calibrate_cancel", function() Calib.Cancel("Calibration cancelled.") end)
concommand.Add("smh_face_pulse", StartPulse)
concommand.Add("smh_face_sweep", StartSweep)
concommand.Add("smh_face_headtest", TestHeadBone)
