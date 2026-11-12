if SERVER then
    AddCSLuaFile()
    return
end


------------------------------------------------------------
-- SMH KINECT RECORDER
------------------------------------------------------------

local MGR = {}

------------------------------------------------------------
-- DEFAULT SETTINGS
------------------------------------------------------------

-- 0 = every frame
-- 1 = every 1 frame
-- 2 = every 2 frames
-- ...
-- 5 = every 5 frames

MGR.RecordInterval = 0

MGR.FrameCount = 100

MGR.StartDelay = 10


------------------------------------------------------------
-- LIMITS
------------------------------------------------------------

local MIN_INTERVAL = 0
local MAX_INTERVAL = 5

local MIN_FRAME_COUNT = 1
local MAX_FRAME_COUNT = 1000

local MIN_START_DELAY = 0
local MAX_START_DELAY = 50


------------------------------------------------------------
-- STATE
------------------------------------------------------------

MGR.Target = nil

MGR.Active = false
MGR.Waiting = false

local ShowKinectStopped
local StartKinectHUDCountdown

MGR.CurrentFrame = 0
MGR.FramesRecorded = 0


------------------------------------------------------------
-- TIMER NAMES
------------------------------------------------------------

local CountdownTimer = "SMH_Kinect_Countdown"
local RecordTimer = "SMH_Kinect_Record"


------------------------------------------------------------
-- SET TARGET
------------------------------------------------------------

function MGR.SetTarget(entity)

    if not IsValid(entity) then

        print(
            "[SMH Kinect Recorder] Invalid target."
        )

        return false
    end


    if not entity:IsRagdoll() then

        print(
            "[SMH Kinect Recorder] Target is not a ragdoll."
        )

        return false
    end


    MGR.Target = entity


    print(
        "[SMH Kinect Recorder] Target set:",
        entity,
        entity:GetModel()
    )


    return true
end


------------------------------------------------------------
-- USE CURRENT SMH ENTITY
------------------------------------------------------------

function MGR.SetCurrentTarget()

    if not SMH or not SMH.State then

        print(
            "[SMH Kinect Recorder] SMH is not ready."
        )

        return false
    end


    if not IsValid(SMH.State.Entity) then

        print(
            "[SMH Kinect Recorder] SMH does not currently have " ..
            "an entity selected."
        )

        return false
    end


    return MGR.SetTarget(SMH.State.Entity)
end


------------------------------------------------------------
-- CLEAR TARGET
------------------------------------------------------------

function MGR.ClearTarget()

    MGR.Target = nil

    print(
        "[SMH Kinect Recorder] Target cleared."
    )

end


------------------------------------------------------------
-- GET TARGET
------------------------------------------------------------

function MGR.GetTarget()

    return MGR.Target

end


------------------------------------------------------------
-- SET RECORD INTERVAL
------------------------------------------------------------

function MGR.SetRecordInterval(value)

    value = tonumber(value) or 0

    value = math.floor(value)

    value = math.Clamp(
        value,
        MIN_INTERVAL,
        MAX_INTERVAL
    )

    MGR.RecordInterval = value

    return value
end


------------------------------------------------------------
-- SET FRAME COUNT
------------------------------------------------------------

function MGR.SetFrameCount(value)

    value = tonumber(value) or 100

    value = math.floor(value)

    value = math.Clamp(
        value,
        MIN_FRAME_COUNT,
        MAX_FRAME_COUNT
    )

    MGR.FrameCount = value

    return value
end


------------------------------------------------------------
-- SET START DELAY
------------------------------------------------------------

function MGR.SetStartDelay(value)

    value = tonumber(value) or 10

    value = math.floor(value)

    value = math.Clamp(
        value,
        MIN_START_DELAY,
        MAX_START_DELAY
    )

    MGR.StartDelay = value

    return value
end


------------------------------------------------------------
-- CAPTURE CURRENT POSE
------------------------------------------------------------

function MGR.CaptureFrame(frame)

    if not SMH then

        print(
            "[SMH Kinect Recorder] SMH is not available."
        )

        return false
    end


    if not SMH.MessageTypes then

        print(
            "[SMH Kinect Recorder] " ..
            "SMH message types are not ready."
        )

        return false
    end


    if not SMH.State then

        print(
            "[SMH Kinect Recorder] " ..
            "SMH state is not available."
        )

        return false
    end


    if not IsValid(MGR.Target) then

        print(
            "[SMH Kinect Recorder] " ..
            "No Kinect target is selected."
        )

        return false
    end


    if not frame or frame < 0 then

        print(
            "[SMH Kinect Recorder] Invalid recording frame."
        )

        return false
    end


    local timeline = SMH.State.Timeline


    if not timeline or timeline < 1 then

        print(
            "[SMH Kinect Recorder] " ..
            "Invalid SMH timeline."
        )

        return false
    end


    --------------------------------------------------------
    -- Send the keyframe directly to SMH.
    --
    -- We intentionally do NOT use:
    --
    -- SMH.Controller.Record()
    --
    -- because that records SMH.State.Frame.
    --
    -- We want to record our own private timeline frame.
    --------------------------------------------------------

    net.Start(
        SMH.MessageTypes.CreateKeyframe
    )

    net.WriteEntity(
        MGR.Target
    )

    net.WriteUInt(
        frame,
        32
    )

    net.WriteUInt(
        timeline,
        32
    )

    net.SendToServer()


    print(
        "[SMH Kinect Recorder] Captured frame:",
        frame,
        "Timeline:",
        timeline
    )


    return true
end


------------------------------------------------------------
-- STOP RECORDING
------------------------------------------------------------

function MGR.Stop()

    if not MGR.Active and not MGR.Waiting then
        return
    end


    timer.Remove(
        CountdownTimer
    )

    timer.Remove(
        RecordTimer
    )

    -- Remember whether something was actually running.
    local wasRunning = MGR.Active or MGR.Waiting

    MGR.Active = false
    MGR.Waiting = false

    -- Clear the countdown display.
    timer.Remove("SMH_Kinect_HUD_Countdown")

    if wasRunning then
        ShowKinectStopped()
    end

    print("")
    print(
        "[SMH Kinect Recorder] ==============================="
    )
    print(
        "[SMH Kinect Recorder] Recording stopped."
    )
    print(
        "[SMH Kinect Recorder] Frames recorded:",
        MGR.FramesRecorded
    )
    print(
        "[SMH Kinect Recorder] ==============================="
    )
    print("")

end


------------------------------------------------------------
-- BEGIN ACTUAL RECORDING
------------------------------------------------------------

function MGR.BeginRecording()

    if not IsValid(MGR.Target) then

        print(
            "[SMH Kinect Recorder] No target selected."
        )

        return false
    end


    --------------------------------------------------------
    -- Enforce limits.
    --------------------------------------------------------

    MGR.SetRecordInterval(
        MGR.RecordInterval
    )

    MGR.SetFrameCount(
        MGR.FrameCount
    )

    MGR.SetStartDelay(
        MGR.StartDelay
    )


    MGR.Active = true
    MGR.Waiting = false

    MGR.CurrentFrame = 0
    MGR.FramesRecorded = 0


    print("")
    print(
        "[SMH Kinect Recorder] ==============================="
    )
    print(
        "[SMH Kinect Recorder] KINECT RECORDING STARTED"
    )
    print(
        "[SMH Kinect Recorder] Target:",
        MGR.Target
    )
    print(
        "[SMH Kinect Recorder] Frames:",
        MGR.FrameCount
    )
    print(
        "[SMH Kinect Recorder] Interval:",
        MGR.RecordInterval
    )
    print(
        "[SMH Kinect Recorder] ==============================="
    )
    print("")


    --------------------------------------------------------
    -- Frame 0 is always captured.
    --
    -- This gives us a starting pose even when the interval
    -- is greater than 1.
    --------------------------------------------------------

    if MGR.CaptureFrame(0) then

        MGR.FramesRecorded =
            MGR.FramesRecorded + 1

    end


    --------------------------------------------------------
    -- Determine SMH playback rate.
    --------------------------------------------------------

    local playbackRate = 30


    if SMH.State
        and SMH.State.PlaybackRate
    then

        playbackRate =
            tonumber(
                SMH.State.PlaybackRate
            ) or 30

    end


    if playbackRate < 1 then
        playbackRate = 30
    end


    local frameTime =
        1 / playbackRate


    --------------------------------------------------------
    -- RECORDING TIMER
    --------------------------------------------------------

    timer.Create(
        RecordTimer,
        frameTime,
        0,
        function()

            if not MGR.Active then

                timer.Remove(
                    RecordTimer
                )

                return
            end


            ------------------------------------------------
            -- Advance our private recording frame.
            --
            -- This does NOT change SMH.State.Frame.
            ------------------------------------------------

            MGR.CurrentFrame =
                MGR.CurrentFrame + 1


            ------------------------------------------------
            -- Stop after the requested number of frames.
            --
            -- Example:
            --
            -- FrameCount = 100
            --
            -- Frames are:
            --
            -- 0 through 99
            ------------------------------------------------

            if MGR.CurrentFrame >= MGR.FrameCount then

                MGR.Stop()

                return
            end


            ------------------------------------------------
            -- INTERVAL
            --
            -- 0 = every frame
            --
            -- Otherwise capture every Nth frame.
            ------------------------------------------------

            local shouldCapture = false


            if MGR.RecordInterval == 0 then

                shouldCapture = true

            elseif
                MGR.CurrentFrame
                % MGR.RecordInterval == 0
            then

                shouldCapture = true

            end


            ------------------------------------------------
            -- CAPTURE
            ------------------------------------------------

            if shouldCapture then

                if MGR.CaptureFrame(
                    MGR.CurrentFrame
                ) then

                    MGR.FramesRecorded =
                        MGR.FramesRecorded + 1

                end

            end

        end
    )


    return true
end


------------------------------------------------------------
-- START COUNTDOWN
------------------------------------------------------------

function MGR.Start()

    if MGR.Active or MGR.Waiting then

        print(
            "[SMH Kinect Recorder] " ..
            "Recording is already running."
        )

        return false
    end


    if not IsValid(MGR.Target) then

        print(
            "[SMH Kinect Recorder] " ..
            "No Kinect target is selected."
        )

        return false
    end


    --------------------------------------------------------
    -- Don't start if SMH Physics Recorder is active.
    --------------------------------------------------------

    if SMH.PhysRecord
        and SMH.PhysRecord.IsActive
        and SMH.PhysRecord.IsActive()
    then

        print(
            "[SMH Kinect Recorder] " ..
            "SMH Physics Recorder is currently active."
        )

        return false
    end


    --------------------------------------------------------
    -- Enforce limits.
    --------------------------------------------------------

    MGR.SetRecordInterval(
        MGR.RecordInterval
    )

    MGR.SetFrameCount(
        MGR.FrameCount
    )

    MGR.SetStartDelay(
        MGR.StartDelay
    )


    MGR.Waiting = true
	--------------------------------------------------------
-- Close the settings window while recording.
--------------------------------------------------------

if IsValid(SMH_KinectRecorderMenu) then

    SMH_KinectRecorderMenu:Close()

end


    local countdown =
        MGR.StartDelay
	StartKinectHUDCountdown(
    countdown
)


    print("")
    print(
        "[SMH Kinect Recorder] ==============================="
    )
    print(
        "[SMH Kinect Recorder] GET READY"
    )
    print(
        "[SMH Kinect Recorder] Recording begins in:",
        countdown,
        "seconds"
    )
    print(
        "[SMH Kinect Recorder] ==============================="
    )
    print("")


    --------------------------------------------------------
    -- No countdown.
    --------------------------------------------------------

    if countdown <= 0 then

        MGR.Waiting = false

        MGR.BeginRecording()

        return true
    end


    --------------------------------------------------------
    -- EXACT COUNTDOWN
    --
    -- Instead of using a timer that has an extra tick,
    -- use timer.Simple().
    --
    -- If countdown = 10:
    --
    -- wait exactly 10 seconds
    -- then begin recording.
    --------------------------------------------------------

    timer.Simple(
        countdown,
        function()

            if not MGR.Waiting then
                return
            end


            MGR.Waiting = false


            print(
                "[SMH Kinect Recorder] " ..
                "Countdown complete."
            )


            MGR.BeginRecording()

        end
    )


    --------------------------------------------------------
    -- Separate countdown display timer.
    --
    -- This is only for console feedback.
    -- It does NOT control when recording begins.
    --------------------------------------------------------

    local remaining = countdown


    timer.Create(
        CountdownTimer,
        1,
        countdown,
        function()

            if not MGR.Waiting then

                timer.Remove(
                    CountdownTimer
                )

                return
            end


            remaining = remaining - 1


            if remaining > 0 then

                print(
                    "[SMH Kinect Recorder] Recording in:",
                    remaining
                )

            end

        end
    )


    return true
end


------------------------------------------------------------
-- STATUS
------------------------------------------------------------

function MGR.PrintStatus()

    print("")
    print(
        "========================================"
    )
    print(
        "       SMH KINECT RECORDER"
    )
    print(
        "========================================"
    )


    if IsValid(MGR.Target) then

        print(
            "Target: " ..
            tostring(MGR.Target)
        )

        print(
            "Model:  " ..
            tostring(
                MGR.Target:GetModel()
            )
        )

    else

        print(
            "Target: NONE"
        )

    end


    print(
        "Record Interval: " ..
        MGR.RecordInterval
    )

    print(
        "Frame Count:     " ..
        MGR.FrameCount
    )

    print(
        "Start Delay:     " ..
        MGR.StartDelay
    )

    print(
        "Active:          " ..
        tostring(MGR.Active)
    )

    print(
        "Waiting:         " ..
        tostring(MGR.Waiting)
    )

    print(
        "Current Frame:   " ..
        tostring(MGR.CurrentFrame)
    )

    print(
        "Frames Recorded: " ..
        tostring(MGR.FramesRecorded)
    )


    print(
        "========================================"
    )

    print("")

end


------------------------------------------------------------
-- REGISTER MANAGER
------------------------------------------------------------

SMH.KinectRecord = MGR


------------------------------------------------------------
-- SELECT CURRENT TARGET
------------------------------------------------------------

concommand.Add(
    "smh_kinect_target",
    function()

        if not SMH or not SMH.State then

            print(
                "[SMH Kinect Recorder] " ..
                "SMH is not ready."
            )

            return
        end


        MGR.SetCurrentTarget()

    end
)


------------------------------------------------------------
-- CAPTURE TEST FRAME
------------------------------------------------------------

concommand.Add(
    "smh_kinect_capture",
    function(ply, cmd, args)

        local frame =
            tonumber(args[1])


        if not frame then
            frame = 0
        end


        MGR.CaptureFrame(frame)

    end
)


------------------------------------------------------------
-- START RECORDING
------------------------------------------------------------

concommand.Add(
    "smh_kinect_start",
    function()

        MGR.Start()

    end
)


------------------------------------------------------------
-- STOP RECORDING
------------------------------------------------------------

concommand.Add(
    "smh_kinect_stop",
    function()

        MGR.Stop()

    end
)


------------------------------------------------------------
-- STATUS
------------------------------------------------------------

concommand.Add(
    "smh_kinect_status",
    function()

        MGR.PrintStatus()

    end
)


------------------------------------------------------------
-- LOADED
------------------------------------------------------------

print(
    "[SMH Kinect Recorder] " ..
    "Kinect Recorder manager loaded."
)
------------------------------------------------------------
-- KINECT RECORDER UI
------------------------------------------------------------

local function OpenKinectRecorderMenu()

    --------------------------------------------------------
    -- Don't create multiple windows.
    --------------------------------------------------------

    if IsValid(SMH_KinectRecorderMenu) then

        SMH_KinectRecorderMenu:SetVisible(true)
        SMH_KinectRecorderMenu:MakePopup()

        return
    end


    --------------------------------------------------------
    -- MAIN WINDOW
    --------------------------------------------------------

    local frame = vgui.Create("DFrame")

    SMH_KinectRecorderMenu = frame

    frame:SetTitle("SMH Kinect Recorder")
    frame:SetSize(360, 430)

    -- Start on the right side of the screen.
    frame:SetPos(
        ScrW() - frame:GetWide() - 15,
        (ScrH() - frame:GetTall()) / 2
    )

    frame:MakePopup()
    frame:SetDeleteOnClose(true)


    --------------------------------------------------------
    -- COLLAPSE BUTTON
    --------------------------------------------------------

    local collapsed = true

    local toggleButton = vgui.Create(
        "DButton",
        frame
    )

    toggleButton:SetText("Kinect Recorder  +")

    toggleButton:SetPos(
        10,
        28
    )

    toggleButton:SetSize(
        340,
        30
    )


    --------------------------------------------------------
    -- TARGET SECTION
    --------------------------------------------------------

    local targetLabel = vgui.Create(
        "DLabel",
        frame
    )

    targetLabel:SetText("Target")
    targetLabel:SetFont("DermaDefaultBold")

    targetLabel:SetPos(
        20,
        70
    )

    targetLabel:SizeToContents()


    --------------------------------------------------------
    -- TARGET DISPLAY
    --------------------------------------------------------

    local targetDisplay = vgui.Create(
        "DLabel",
        frame
    )

    targetDisplay:SetText(
        "No ragdoll selected"
    )

    targetDisplay:SetPos(
        20,
        92
    )

    targetDisplay:SetSize(
        320,
        25
    )


    --------------------------------------------------------
    -- USE CURRENT SMH ENTITY
    --------------------------------------------------------

    local targetButton = vgui.Create(
        "DButton",
        frame
    )

    targetButton:SetText(
        "Use Current SMH Entity"
    )

    targetButton:SetPos(
        20,
        122
    )

    targetButton:SetSize(
        320,
        28
    )


    targetButton.DoClick = function()

        if not SMH or not SMH.State then

            notification.AddLegacy(
                "Stop Motion Helper is not ready.",
                NOTIFY_ERROR,
                3
            )

            return
        end


        if not IsValid(SMH.State.Entity) then

            notification.AddLegacy(
                "SMH does not have an entity selected.",
                NOTIFY_ERROR,
                3
            )

            return
        end


        if MGR and MGR.SetCurrentTarget then

            if MGR.SetCurrentTarget() then

                local target = MGR.GetTarget()

                if IsValid(target) then

                    targetDisplay:SetText(
                        target:GetModel()
                    )

                end

            end

        end

    end


    --------------------------------------------------------
    -- SEPARATOR
    --------------------------------------------------------

    local separator = vgui.Create(
        "DPanel",
        frame
    )

    separator:SetPos(
        20,
        162
    )

    separator:SetSize(
        320,
        1
    )

    separator.Paint = function(self, w, h)

        surface.SetDrawColor(
            80,
            80,
            80,
            255
        )

        surface.DrawRect(
            0,
            0,
            w,
            h
        )

    end


    --------------------------------------------------------
    -- RECORD INTERVAL
    --------------------------------------------------------

    local intervalLabel = vgui.Create(
        "DLabel",
        frame
    )

    intervalLabel:SetText(
        "Record Interval"
    )

    intervalLabel:SetFont(
        "DermaDefaultBold"
    )

    intervalLabel:SetPos(
        20,
        180
    )

    intervalLabel:SizeToContents()


    local intervalSlider = vgui.Create(
        "DNumSlider",
        frame
    )

    intervalSlider:SetPos(
        20,
        202
    )

    intervalSlider:SetSize(
        320,
        35
    )

    intervalSlider:SetText(
        ""
    )

    intervalSlider:SetMin(
        0
    )

    intervalSlider:SetMax(
        5
    )

    intervalSlider:SetDecimals(
        0
    )

    intervalSlider:SetValue(
        MGR.RecordInterval
    )


    intervalSlider.OnValueChanged = function(
        self,
        value
    )

        value = math.floor(
            tonumber(value) or 0
        )

        MGR.SetRecordInterval(
            value
        )

    end


    local intervalInfo = vgui.Create(
        "DLabel",
        frame
    )

    intervalInfo:SetText(
        "0 = every frame"
    )

    intervalInfo:SetPos(
        20,
        235
    )

    intervalInfo:SetSize(
        320,
        18
    )


    --------------------------------------------------------
    -- FRAME COUNT
    --------------------------------------------------------

    local frameCountLabel = vgui.Create(
        "DLabel",
        frame
    )

    frameCountLabel:SetText(
        "Record Frames"
    )

    frameCountLabel:SetFont(
        "DermaDefaultBold"
    )

    frameCountLabel:SetPos(
        20,
        258
    )

    frameCountLabel:SizeToContents()


    local frameSlider = vgui.Create(
        "DNumSlider",
        frame
    )

    frameSlider:SetPos(
        20,
        280
    )

    frameSlider:SetSize(
        320,
        35
    )

    frameSlider:SetText(
        ""
    )

    frameSlider:SetMin(
        1
    )

    frameSlider:SetMax(
        1000
    )

    frameSlider:SetDecimals(
        0
    )

    frameSlider:SetValue(
        MGR.FrameCount
    )


    frameSlider.OnValueChanged = function(
        self,
        value
    )

        value = math.floor(
            tonumber(value) or 100
        )

        MGR.SetFrameCount(
            value
        )

    end


    --------------------------------------------------------
    -- COUNTDOWN
    --------------------------------------------------------

    local countdownLabel = vgui.Create(
        "DLabel",
        frame
    )

    countdownLabel:SetText(
        "Countdown"
    )

    countdownLabel:SetFont(
        "DermaDefaultBold"
    )

    countdownLabel:SetPos(
        20,
        330
    )

    countdownLabel:SizeToContents()


    local countdownSlider = vgui.Create(
        "DNumSlider",
        frame
    )

    countdownSlider:SetPos(
        20,
        352
    )

    countdownSlider:SetSize(
        320,
        35
    )

    countdownSlider:SetText(
        ""
    )

    countdownSlider:SetMin(
        0
    )

    countdownSlider:SetMax(
        50
    )

    countdownSlider:SetDecimals(
        0
    )

    countdownSlider:SetValue(
        MGR.StartDelay
    )


    countdownSlider.OnValueChanged = function(
        self,
        value
    )

        value = math.floor(
            tonumber(value) or 10
        )

        MGR.SetStartDelay(
            value
        )

    end


    --------------------------------------------------------
    -- BEGIN RECORDING
    --------------------------------------------------------

    local recordButton = vgui.Create(
        "DButton",
        frame
    )

    recordButton:SetText(
        "BEGIN RECORDING"
    )

    recordButton:SetPos(
        20,
        395
    )

    recordButton:SetSize(
        155,
        35
    )


    recordButton.DoClick = function()

        if MGR.Active or MGR.Waiting then

            notification.AddLegacy(
                "Kinect recording is already running.",
                NOTIFY_ERROR,
                3
            )

            return
        end


        if not IsValid(MGR.Target) then

            notification.AddLegacy(
                "Select a target ragdoll first.",
                NOTIFY_ERROR,
                3
            )

            return
        end


        MGR.Start()

    end


    --------------------------------------------------------
    -- STOP RECORDING
    --------------------------------------------------------

    local stopButton = vgui.Create(
        "DButton",
        frame
    )

    stopButton:SetText(
        "STOP"
    )

    stopButton:SetPos(
        185,
        395
    )

    stopButton:SetSize(
        155,
        35
    )


    stopButton.DoClick = function()

        MGR.Stop()

    end


    --------------------------------------------------------
    -- STATUS DISPLAY
    --------------------------------------------------------

    local statusLabel = vgui.Create(
        "DLabel",
        frame
    )

    statusLabel:SetText(
        "Ready"
    )

    statusLabel:SetPos(
        20,
        435
    )

    statusLabel:SetSize(
        320,
        20
    )

    statusLabel:SetContentAlignment(
        5
    )


    --------------------------------------------------------
    -- ALL CONTENT CONTROLS
    --------------------------------------------------------

    local contentControls = {

        targetLabel,
        targetDisplay,
        targetButton,
        separator,

        intervalLabel,
        intervalSlider,
        intervalInfo,

        frameCountLabel,
        frameSlider,

        countdownLabel,
        countdownSlider,

        recordButton,
        stopButton,
        statusLabel

    }


    --------------------------------------------------------
    -- COLLAPSE / EXPAND
    --------------------------------------------------------

    local function SetCollapsed(value)

        collapsed = value

        if collapsed then

            frame:SetSize(
                360,
                65
            )

            toggleButton:SetText(
                "Kinect Recorder  +"
            )

        else

            frame:SetSize(
                360,
                470
            )

            toggleButton:SetText(
                "Kinect Recorder  -"
            )

        end


        -- Keep it on the right side.
        frame:SetPos(
            ScrW() - frame:GetWide() - 15,
            (ScrH() - frame:GetTall()) / 2
        )


        for _, control in ipairs(contentControls) do

            if IsValid(control) then
                control:SetVisible(not collapsed)
            end

        end

    end


    toggleButton.DoClick = function()

        SetCollapsed(
            not collapsed
        )

    end


    --------------------------------------------------------
    -- UPDATE UI
    --------------------------------------------------------

    frame.Think = function(self)

        if IsValid(MGR.Target) then

            targetDisplay:SetText(
                MGR.Target:GetModel()
            )

        else

            targetDisplay:SetText(
                "No ragdoll selected"
            )

        end


        if MGR.Waiting then

            statusLabel:SetText(
                "Starting..."
            )

        elseif MGR.Active then

            statusLabel:SetText(
                "Recording: "
                .. tostring(MGR.FramesRecorded)
                .. " / "
                .. tostring(MGR.FrameCount)
            )

        else

            statusLabel:SetText(
                "Ready"
            )

        end

    end


    --------------------------------------------------------
    -- START COLLAPSED
    --------------------------------------------------------

    SetCollapsed(true)

end


------------------------------------------------------------
-- CONSOLE COMMAND TO OPEN UI
------------------------------------------------------------

concommand.Add(
    "smh_kinect_menu",
    function()

        OpenKinectRecorderMenu()

    end
)


------------------------------------------------------------
-- UI LOADED
------------------------------------------------------------

print(
    "[SMH Kinect Recorder] " ..
    "UI loaded. Type smh_kinect_menu to open it."
)
surface.CreateFont("SMH_KinectHuge", {
    font = "Arial",
    size = 120,
    weight = 1000
})
------------------------------------------------------------
-- KINECT RECORDING HUD
------------------------------------------------------------

local KinectHUDText = nil
local KinectHUDUntil = 0


------------------------------------------------------------
-- SHOW HUD MESSAGE
------------------------------------------------------------

local function KinectHUD(message, duration)

    KinectHUDText = tostring(message)

    KinectHUDUntil = CurTime() + (duration or 1)

end


------------------------------------------------------------
-- DRAW HUD
------------------------------------------------------------

hook.Add(
    "HUDPaint",
    "SMH_KinectRecorder_HUD",
    function()

        if not KinectHUDText then
            return
        end


        if CurTime() >= KinectHUDUntil then

            KinectHUDText = nil

            return
        end


        surface.SetFont(
            "SMH_KinectHuge"
        )


        local textWidth,
              textHeight =
            surface.GetTextSize(
                KinectHUDText
            )


        local x =
            (ScrW() - textWidth) / 2


        local y =
            (ScrH() - textHeight) / 2


        ----------------------------------------------------
        -- Black outline
        ----------------------------------------------------

        draw.SimpleText(
            KinectHUDText,
            "SMH_KinectHuge",
            x + 2,
            y + 2,
            Color(
                0,
                0,
                0,
                255
            ),
            TEXT_ALIGN_LEFT,
            TEXT_ALIGN_TOP
        )


        ----------------------------------------------------
        -- Red text
        ----------------------------------------------------

        draw.SimpleText(
            KinectHUDText,
            "SMH_KinectHuge",
            x,
            y,
            Color(
                255,
                0,
                0,
                255
            ),
            TEXT_ALIGN_LEFT,
            TEXT_ALIGN_TOP
        )

    end
)


------------------------------------------------------------
-- COUNTDOWN DISPLAY
------------------------------------------------------------

StartKinectHUDCountdown = function(seconds)

    seconds = math.max(
        0,
        math.floor(
            tonumber(seconds) or 0
        )
    )


    if seconds <= 0 then
        return
    end


    local remaining = seconds


    --------------------------------------------------------
    -- Show the first number immediately.
    --------------------------------------------------------

    KinectHUD(
        tostring(remaining),
        1.1
    )


    --------------------------------------------------------
    -- Update once every second.
    --------------------------------------------------------

    if seconds > 1 then
        timer.Create(
            "SMH_Kinect_HUD_Countdown",
            1,
            seconds - 1,
            function()

                remaining =
                    remaining - 1

                if remaining > 0 then

                    KinectHUD(
                        tostring(remaining),
                        1.1
                    )

                end

            end
        )
    end

end


------------------------------------------------------------
-- RECORDING STOPPED MESSAGE
------------------------------------------------------------

ShowKinectStopped = function()

    timer.Remove(
        "SMH_Kinect_HUD_Countdown"
    )

    KinectHUD(
        "STOPPED!",
        2
    )

end
-- ============================================================
-- SHOW RECORDER WHEN SMH OPENS
-- ============================================================

local smhWasOpen = false

hook.Add("Think", "SMH_KinectRecorder_FollowSMH", function()

    if not SMH or not SMH.UI then
        return
    end

    local smhOpen = SMH.UI.IsOpen()

    -- SMH just opened
    if smhOpen and not smhWasOpen then

        smhWasOpen = true

        if OpenKinectRecorderMenu then
            OpenKinectRecorderMenu()
        end

    -- SMH just closed
    elseif not smhOpen and smhWasOpen then

        smhWasOpen = false

        if IsValid(SMH_KinectRecorderMenu) then
            SMH_KinectRecorderMenu:Close()
        end

    end

end)
-- ============================================================
-- POSITION RECORDER ABOVE SMH
-- ============================================================

hook.Add("Think", "SMH_KinectRecorder_Position", function()

    if not IsValid(SMH_KinectRecorderMenu) then
        return
    end

    if not SMH or not SMH.UI or not SMH.UI.IsOpen() then
        return
    end

    local menu = SMH_KinectRecorderMenu

    local width = menu:GetWide()
    local height = menu:GetTall()

    -- Center the recorder horizontally.
    local x = (ScrW() - width) / 2

    -- Put it above the SMH timeline.
    local y = ScrH() - 90 - height - 10

    menu:SetPos(x, y)

end)