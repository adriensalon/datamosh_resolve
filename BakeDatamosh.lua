-- Invoked by the Datamosh Inspector.
local composition = comp or composition or (fusion and fusion:GetCurrentComp())

local function inputsOf(node)
    local inputs = {}
    for key, input in pairs(node:GetInputList() or {}) do
        local id = input:GetAttrs().INPS_ID
        if id then inputs[id] = input end
        if type(key) == "string" then inputs[key] = input end
    end
    return inputs
end

local function datamoshInputs(node)
    if not node then return nil end
    local inputs = inputsOf(node)
    if inputs.CodecSize and (inputs.BakeKey or (inputs.CacheImage and inputs.CacheFirst and inputs.CacheLast)) then
        return inputs
    end
end

local function findDatamosh(comp)
    local request = comp:GetData("ResolveDatamosh.ButtonRequest")
    if type(request) == "table" then
        comp:SetData("ResolveDatamosh.ButtonRequest", false)
        local target = request.Name and comp:FindTool(request.Name)
        local inputs = datamoshInputs(target)
        if inputs and inputs.CacheFirst and inputs.MainInput1 then return target, inputs end
        local named, namedInputs
        local prefix = request.Mode == "Transition" and "^DatamoshCut" or "^DatamoshBloom"
        for _, candidate in pairs(comp:GetToolList(false) or {}) do
            local name = candidate:GetAttrs().TOOLS_Name or ""
            local candidateInputs = name:match(prefix) and datamoshInputs(candidate)
            if candidateInputs and candidateInputs.CacheFirst and candidateInputs.MainInput1 then
                assert(not named, "Resolve did not identify which Datamosh Inspector sent the bake.")
                named, namedInputs = candidate, candidateInputs
            end
        end
        return assert(named, "Could not find the Datamosh effect in this composition."), namedInputs
    end
    local active = comp.ActiveTool
    local activeInputs = datamoshInputs(active)
    if activeInputs then return active, activeInputs end

    for _, onlySelected in ipairs({ true, false }) do
        local found, foundInputs
        for _, candidate in pairs(comp:GetToolList(onlySelected) or {}) do
            local inputs = datamoshInputs(candidate)
            if inputs then
                assert(not found, "Select the Datamosh group you want to bake in the Fusion node graph.")
                found, foundInputs = candidate, inputs
            end
        end
        if found then return found, foundInputs end
    end
    error("Open the clip or transition in Fusion and select its Datamosh group or node.")
end

local function connectedOutput(input)
    return input and input:GetConnectedOutput()
end

local function integer(value, label)
    local number = assert(tonumber(value), "Could not read " .. label .. " from Fusion.")
    return math.floor(number + 0.5)
end

local function trace(job, phase)
    local log = io.open(job .. "\\trace.txt", "a")
    if log then
        log:write(os.date("!%Y-%m-%dT%H:%M:%SZ "), phase, "\n")
        log:close()
    end
end

local function capture(comp, output, first, last, job, pass)
    trace(job, pass .. ": add Saver")
    local saver = assert(comp:AddTool("Saver", -32768, -32768), "Could not add a temporary Saver.")
    local ok, errorMessage = pcall(function()
        saver:ConnectInput("Input", output)
        saver.Clip = job .. "\\" .. pass .. "\\" .. pass .. "_.exr"
        trace(job, ("%s: render frames %d to %d"):format(pass, first, last))
        local rendered = comp:Render({
            Start = first, End = last, Wait = true, Tool = saver, HiQ = true, Proxy = false,
        })
        trace(job, pass .. ": render returned " .. tostring(rendered))
        assert(rendered, "Fusion could not render the capture. Check the frame range and clip handles.")
    end)
    trace(job, pass .. ": remove Saver")
    saver:Delete()
    trace(job, pass .. ": Saver removed")
    assert(ok, errorMessage)
end

local function createJob()
    local appData = assert(os.getenv("LOCALAPPDATA"), "LOCALAPPDATA is unavailable.")
    local root = appData .. "\\ResolveDatamosh\\Jobs\\"
    local prefix = tostring(os.time()) .. "-"
    local jobID, folder
    for attempt = 1, 1000 do
        jobID = prefix .. attempt
        folder = root .. jobID
        if not bmd.direxists(folder) then break end
        folder = nil
    end
    assert(folder, "Could not reserve a cache folder.")
    bmd.createdir(folder)
    bmd.createdir(folder .. "\\anchor")
    bmd.createdir(folder .. "\\motion")
    return jobID, folder
end

local function mainOutput(tool)
    return tool and tool:FindMainOutput(1)
end

local function readJob(jobID)
    if not jobID or not jobID:match("^%d+%-%d+$") then return nil end
    local job = assert(os.getenv("LOCALAPPDATA")) .. "\\ResolveDatamosh\\Jobs\\" .. jobID
    local status = io.open(job .. "\\status.txt", "r")
    if not status then return nil end
    local count = tonumber(status:read("*a"):match("^OK (%d+)"))
    status:close()
    local config = io.open(job .. "\\job.txt", "r")
    if not config or not count then
        if config then config:close() end
        return nil
    end
    local settings = {}
    for key, value in config:read("*a"):gmatch("(%w+)=([^\r\n]+)") do settings[key] = value end
    config:close()
    local first = job .. "\\frames\\mosh000000.png"
    if not bmd.fileexists(first) then return nil end
    return { id = jobID, folder = job, path = first, count = count, settings = settings }
end

local function validateBakedFrames(bake)
    for index = 0, bake.count - 1 do
        local filename = ("mosh%06d.png"):format(index)
        assert(bmd.fileexists(bake.folder .. "\\frames\\" .. filename), "The Datamosh cache is missing " .. filename .. ".")
    end
end

local function retryInspectorBake(node, settings)
    local bake = readJob(node:GetData("ResolveDatamosh.PendingJob"))
    if not bake or bake.count ~= settings.Count then return nil end
    for key, value in pairs(settings) do
        if type(value) == "number" then
            if tonumber(bake.settings[key]) ~= value then return nil end
        elseif bake.settings[key] ~= value then
            return nil
        end
    end

    local report = io.open(bake.folder .. "\\playback.txt", "r")
    if not report then return nil end
    local message = report:read("*a")
    report:close()
    if message:match("^ERROR ") and (
        message:find("Could not create the Datamosh cache Loader.", 1, true)
        or message:find("Resolve could not render the baked window or the final frame.", 1, true)
    ) then
        return bake
    end
end

local function playbackSettings(name, bake, mode, start, first, last, renderStart, renderEnd, width, height)
    local before, after = math.max(0, start - renderStart), math.max(0, renderEnd - (start + bake.count - 1))
    local path = ("%q"):format((bake.path:gsub("\\", "/")))
    local clean, inputs, background = "", "", ""
    if mode == "Transition" then
        inputs = [[
            MainInput1 = InstanceInput { SourceOp = "CleanCut", Source = "Background" },
            MainInput2 = InstanceInput { SourceOp = "CleanCut", Source = "Foreground" },
        ]]
        clean = ([[
            CleanCut = Dissolve {
                Transitions = { [0] = "DFTDissolve" },
                Inputs = { Mix = Input { Expression = "iif(time >= %d, 1, 0)" } },
            },
        ]]):format(last + 1)
        background = [[Background = Input { SourceOp = "CleanCut", Source = "Output" },]]
    else
        inputs = [[MainInput1 = InstanceInput { SourceOp = "ShowBake", Source = "Background" },]]
    end
    return ([[{
        Tools = ordered() {
            %s = GroupOperator {
                Inputs = ordered() { %s },
                Outputs = { MainOutput1 = InstanceOutput { SourceOp = "ShowBake", Source = "Output" } },
                ViewInfo = GroupInfo { Pos = { 4, 1 } },
                Tools = ordered() {
                    %s
                    Cache = Loader {
                        Clips = { Clip {
                            ID = "Clip1", Filename = %s, FormatID = "PNGFormat",
                            StartFrame = 0, Length = %d, LengthSetManually = true,
                            TrimIn = 0, TrimOut = %d, ExtendFirst = %d, ExtendLast = %d,
                            GlobalStart = %d, GlobalEnd = %d,
                        } },
                    },
                    ScaleCache = BetterResize {
                        Inputs = {
                            Input = Input { SourceOp = "Cache", Source = "Output" },
                            Width = Input { Value = %d }, Height = Input { Value = %d },
                        },
                    },
                    ShowBake = Dissolve {
                        Transitions = { [0] = "DFTDissolve" },
                        Inputs = {
                            %s
                            Foreground = Input { SourceOp = "ScaleCache", Source = "Output" },
                            Mix = Input { Expression = "iif(time >= %d, iif(time <= %d, 1, 0), 0)" },
                        },
                    },
                },
            },
        },
    }]]):format(name, inputs, clean, path, bake.count, bake.count - 1, before, after,
        start - before, start + bake.count - 1 + after, width, height, background, first, last)
end

local function feedsMediaOut(comp, node, mediaout, input, connected)
    if not connected then return true end

    local controlsName = node:GetAttrs().TOOLS_Name
    local owner = connected:GetTool()
    local ownerAttrs = owner and owner:GetAttrs() or {}
    if owner == node or ownerAttrs.TOOLS_Name == controlsName then return true end

    -- A GroupOperator can expose its inner Output to script callers. Copy the
    -- two tools without touching the system clipboard to resolve the published link.
    local ok, settings = pcall(function() return comp:CopySettings({ node, mediaout }) end)
    local tools = ok and settings and settings.Tools
    local group = tools and tools[controlsName]
    local sink = tools and tools[mediaout:GetAttrs().TOOLS_Name]
    local id = input:GetAttrs().INPS_ID
    local link = sink and sink.Inputs and sink.Inputs[id or "Input"]
    if link and link.SourceOp == controlsName then return true end

    local published = group and group.Outputs and group.Outputs.MainOutput1
    return ownerAttrs.TOOLS_RegID == "Fuse.CodecDatamosh" and published
        and published.SourceOp == ownerAttrs.TOOLS_Name
        and group.Tools and group.Tools[published.SourceOp] ~= nil
end

local function attachPlayback(comp, node, sources, bake, start, renderStart, renderEnd, anchorOffset)
    local mode = bake.settings.Mode
    local first = start + (anchorOffset == 0 and 1 or 0)
    local last = math.min(start + bake.count - 1, renderEnd - (mode == "Transition" and 1 or 0))
    assert(first <= last, "The cached frames do not overlap the current render range.")
    validateBakedFrames(bake)
    local width = integer(comp:GetPrefs("Comp.FrameFormat.Width"), "the timeline width")
    local height = integer(comp:GetPrefs("Comp.FrameFormat.Height"), "the timeline height")
    local controls = assert(node:GetAttrs().TOOLS_Name, "Could not identify the Datamosh group.")
    local previous, targets, seen = {}, {}, {}
    local function addTarget(input)
        if input and not seen[input] then
            seen[input] = true
            targets[#targets + 1] = {input = input, output = connectedOutput(input)}
        end
    end
    local function collect(output)
        if output then
            for _, input in pairs(output:GetConnectedInputs() or {}) do addTarget(input) end
        end
    end
    collect(mainOutput(node))
    for _, tool in pairs(comp:GetToolList(false) or {}) do
        if tool:GetData("ResolveDatamosh.Controls") == controls then
            previous[#previous + 1] = tool
            collect(mainOutput(tool))
        end
    end
    if #targets == 0 then
        local mediaout = comp:FindTool("MediaOut1")
        local input = mediaout and mediaout:FindMainInput(1)
        local connected = connectedOutput(input)
        assert(input and feedsMediaOut(comp, node, mediaout, input, connected),
            "MediaOut is connected to a different branch. Select the Datamosh group that feeds it.")
        addTarget(input)
    end
    assert(#targets > 0, "Could not find the Datamosh output connection.")

    local baseName = "DatamoshPlayback" .. bake.id:gsub("%-", "_")
    local name, suffix = baseName, 1
    while comp:FindTool(name) do
        suffix = suffix + 1
        name = baseName .. "_" .. suffix
    end
    local settings = assert(bmd.readstring(playbackSettings(name, bake, mode, start, first, last,
        renderStart, renderEnd, width, height)), "Could not parse the Datamosh playback graph.")

    local wasLocked = comp:IsLocked()
    local playback, rewired = nil, 0
    trace(bake.folder, "playback: attach native group")
    comp:StartUndo("Attach Datamosh Playback")
    if not wasLocked then comp:Lock() end
    local ok, message = pcall(function()
        assert(comp:Paste(settings), "Could not create the Datamosh playback graph.")
        playback = assert(comp:FindTool(name), "Could not find the Datamosh playback group.")
        playback:SetData("ResolveDatamosh.Controls", controls)
        playback:SetData("ResolveDatamosh.Job", bake.id)
        playback:SetData("ResolveDatamosh.Start", start)
        assert(playback:ConnectInput("MainInput1", sources.a), "Could not connect the source clip.")
        if mode == "Transition" then
            assert(playback:ConnectInput("MainInput2", sources.b), "Could not connect the incoming clip.")
        end
        local output = assert(mainOutput(playback), "Datamosh playback has no output.")
        for index, target in ipairs(targets) do
            assert(target.input:ConnectTo(output), "Could not reconnect the image output.")
            rewired = index
        end
    end)
    if not wasLocked then
        trace(bake.folder, "playback: unlock composition")
        comp:Unlock()
        trace(bake.folder, "playback: composition unlocked")
    end
    if not ok then
        for index = 1, rewired do pcall(function() targets[index].input:ConnectTo(targets[index].output) end) end
        if playback then pcall(function() playback:Delete() end) end
    else
        for _, tool in ipairs(previous) do
            local output = mainOutput(tool)
            if not output or not next(output:GetConnectedInputs() or {}) then tool:Delete() end
        end
    end
    comp:EndUndo(ok)
    comp:SetActiveTool(node)
    local report = io.open(bake.folder .. "\\playback.txt", "w")
    if report then
        report:write(ok and "OK Native Datamosh graph attached." or ("ERROR " .. tostring(message)))
        report:close()
    end
    trace(bake.folder, ok and "playback: attached" or ("playback: " .. tostring(message)))
    assert(ok, message)
    print(("Datamosh playback attached on frames %d to %d using bake %s."):format(first, last, bake.id))
end

local function attachInspectorPlayback(comp, node, inputs, bake, start, renderStart, renderEnd, anchorOffset)
    local first = start + (anchorOffset == 0 and 1 or 0)
    local last = math.min(start + bake.count - 1, renderEnd - (bake.settings.Mode == "Transition" and 1 or 0))
    assert(first <= last, "The bake does not overlap the current render range.")
    validateBakedFrames(bake)
    local before = math.max(0, start - renderStart)
    local after = math.max(0, renderEnd - (start + bake.count - 1))
    local baseName = "DatamoshCache" .. bake.id:gsub("%-", "_")
    local name, suffix = baseName, 1
    while comp:FindTool(name) do
        suffix = suffix + 1
        name = baseName .. "_" .. suffix
    end

    local clipPath = ("%q"):format((bake.path:gsub("\\", "/")))
    local settings = assert(bmd.readstring(([[{
        Tools = ordered() {
            %s = Loader {
                Clips = { Clip {
                    ID = "Clip1", Filename = %s, FormatID = "PNGFormat",
                    StartFrame = 0, Length = %d, LengthSetManually = true,
                    TrimIn = 0, TrimOut = %d, ExtendFirst = %d, ExtendLast = %d,
                    GlobalStart = %d, GlobalEnd = %d,
                } },
            },
        },
    }]]):format(name, clipPath, bake.count, bake.count - 1, before, after,
        start - before, start + bake.count - 1 + after)), "Could not create the Datamosh Loader settings.")

    local previous = connectedOutput(inputs.CacheImage)
    local previousFirst = node:GetInput("CacheFirst", start) or 1
    local previousLast = node:GetInput("CacheLast", start) or 0
    local wasLocked = comp:IsLocked()
    local active = comp.ActiveTool
    local loader
    trace(bake.folder, "playback: attach Loader")
    comp:StartUndo("Bake Datamosh")
    if not wasLocked then comp:Lock() end
    local ok, message = pcall(function()
        -- Add the Loader directly so the Edit Inspector does not need a Fusion flow view.
        comp:SetActiveTool(nil)
        loader = assert(comp:AddTool("Loader", -32768, -32768), "Could not create the Datamosh cache Loader.")
        loader:SetAttrs({ TOOLS_Name = name, TOOLB_NameSet = true })
        trace(bake.folder, "playback: load sequence settings")
        assert(loader:LoadSettings(settings), "Could not load the baked sequence into the Datamosh cache Loader.")
        loader:SetData("ResolveDatamosh.Cache", true)
        loader:SetData("ResolveDatamosh.Job", bake.id)
        trace(bake.folder, "playback: connect sequence and set frame window")
        assert(node:ConnectInput("CacheImage", loader.Output), "Could not connect the baked sequence to Datamosh.")
        node:SetInput("CacheFirst", first)
        node:SetInput("CacheLast", last)
    end)
    if not wasLocked then
        trace(bake.folder, "playback: unlock composition")
        comp:Unlock()
        trace(bake.folder, "playback: composition unlocked")
    end

    if ok and not wasLocked then
        ok, message = pcall(function()
            -- Inspect the numeric inputs without requesting an image from the Edit-page render thread.
            trace(bake.folder, "playback: verify frame window")
            assert(tonumber(node:GetInput("CacheFirst", first)) == first
                and tonumber(node:GetInput("CacheLast", first)) == last,
                "Resolve did not apply the baked frame window.")
        end)
    end

    if not ok and loader then
        pcall(function() node:ConnectInput("CacheImage", previous) end)
        pcall(function() node:SetInput("CacheFirst", previousFirst) end)
        pcall(function() node:SetInput("CacheLast", previousLast) end)
        pcall(function() loader:Delete() end)
    elseif ok and previous then
        local old = previous:GetTool()
        if old and old:GetData("ResolveDatamosh.Cache") == true
            and not next(previous:GetConnectedInputs() or {}) then
            old:Delete()
        end
    end
    comp:SetActiveTool(active)
    comp:EndUndo(ok)

    local report = io.open(bake.folder .. "\\playback.txt", "w")
    if report then
        report:write(ok and ("OK Inspector bake attached for frames %d to %d."):format(first, last)
            or ("ERROR " .. tostring(message)))
        report:close()
    end
    trace(bake.folder, ok and "playback: attached" or ("playback: " .. tostring(message)))
    assert(ok, message)
    print(("Datamosh baked %d frames from frame %d."):format(bake.count, start))
end

local function run()
    assert(composition, "Open a Fusion composition first.")
    local node, inputs = findDatamosh(composition)
    local grouped = node:GetAttrs().TOOLS_RegID ~= "Fuse.CodecDatamosh"
    local a = connectedOutput(inputs.MainInput1 or inputs.Outgoing or node:FindMainInput(1))
    local incoming = inputs.MainInput2 or inputs.Incoming
    local b = connectedOutput(incoming)
    local name = node:GetAttrs().TOOLS_Name or ""
    assert(a, "Connect the outgoing clip or single source to the Datamosh node.")
    local attrs = composition:GetAttrs()
    local renderStart = integer(attrs.COMPN_RenderStart or attrs.COMPN_GlobalStart, "the render start")
    local renderEnd = integer(attrs.COMPN_RenderEnd or attrs.COMPN_GlobalEnd, "the render end")
    local time = integer(attrs.COMPN_CurrentTime or composition.CurrentTime or renderStart, "the playhead position")
    local function number(id)
        return integer(node:GetInput(id, time), id)
    end
    local transition
    if grouped then
        transition = incoming ~= nil or name:match("^DatamoshCut") ~= nil
    else
        transition = number("Transition") == 1
    end
    assert(not transition or b, "Connect the incoming clip to the Datamosh transition.")


    local start = transition and renderStart or time
    assert(start >= renderStart and start <= renderEnd, "Move the playhead inside the composition render range.")
    local anchorOffset, motionOffset = number("AnchorOffset"), number("MotionOffset")
    local length = transition and 0 or number("MoshLength")
    local quantizer, size = number("Quantizer"), number("CodecSize")
    local count = transition and renderEnd - renderStart or math.min(length, renderEnd - start + 1)
    assert(count >= 2 and count <= 120,
        "Use a transition of 3 to 121 frames or leave at least 2 frames after the bloom start.")
    local anchorFrame = start + anchorOffset
    local motionFrame = start + motionOffset
    local donorCount = transition and math.min(count, renderEnd - motionFrame + 1) or 2
    assert(anchorFrame >= renderStart and anchorFrame <= renderEnd and
        motionFrame >= renderStart and donorCount >= 2 and motionFrame + donorCount - 1 <= renderEnd,
        "Offsets exceed the Fusion render range. Adjust the offsets or extend the available handles.")

    local rate = composition:GetPrefs("Comp.FrameFormat.Rate") or 24
    assert(type(rate) == "number" and rate > 0, "Could not get the composition frame rate.")
    local settings = {
        Mode = transition and "Transition" or "Bloom",
        Count = count, Rate = tonumber(("%.9g"):format(rate)), Quantizer = quantizer, Width = size,
        StartFrame = start, AnchorFrame = anchorFrame, MotionFrame = motionFrame, DonorCount = donorCount,
    }
    if inputs.CacheFirst then
        local retry = retryInspectorBake(node, settings)
        if retry then
            attachInspectorPlayback(composition, node, inputs, retry, start, renderStart, renderEnd, anchorOffset)
            return
        end
    end

    local jobID, job = createJob()
    local config = assert(io.open(job .. "\\job.txt", "w"))
    config:write(("Mode=%s\nCount=%d\nRate=%.9g\nQuantizer=%d\nWidth=%d\nStartFrame=%d\nAnchorFrame=%d\nMotionFrame=%d\nDonorCount=%d\n")
        :format(settings.Mode, count, settings.Rate, quantizer, size, start, anchorFrame, motionFrame, donorCount))
    config:close()

    local captured, captureError = pcall(function()
        capture(composition, a, anchorFrame, anchorFrame, job, "anchor")
        capture(composition, transition and b or a, motionFrame, motionFrame + donorCount - 1, job, "motion")
    end)
    trace(job, "capture: restore render range")
    composition:SetAttrs({ COMPN_RenderStart = renderStart, COMPN_RenderEnd = renderEnd })
    trace(job, "capture: restore active tool")
    composition:SetActiveTool(node)
    assert(captured, captureError)
    trace(job, "capture: complete")

    -- The hidden shell receives a fixed command and a generated numeric job ID.
    local systemRoot = assert(os.getenv("SystemRoot"), "SystemRoot is unavailable.")
    local command = '"' .. systemRoot .. [[\System32\cmd.exe" /d /c powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "]] ..
        [[$engine = Join-Path $env:LOCALAPPDATA 'ResolveDatamosh/InvokeDatamosh.ps1'; & $engine -JobId ']] ..
        jobID .. [['"]]
    trace(job, "codec: launch")
    assert(bmd.executebg(command, true), "Could not start the Datamosh codec helper.")
    trace(job, "codec: returned")
    local status = io.open(job .. "\\status.txt", "r")
    assert(status, "The codec helper did not finish. Check " .. job)
    local message = status:read("*a")
    status:close()
    assert(message == "OK " .. count, message .. "\nJob folder: " .. job)

    local bake = assert(readJob(jobID), "Could not read the baked sequence.")
    node:SetData("ResolveDatamosh.PendingJob", jobID)
    if inputs.CacheFirst then
        attachInspectorPlayback(composition, node, inputs, bake, start, renderStart, renderEnd, anchorOffset)
    else
        attachPlayback(composition, node, { a = a, b = b }, bake, start, renderStart, renderEnd, anchorOffset)
    end
end

local ok, message = pcall(run)
if not ok then
    print("Datamosh: " .. tostring(message))
    if composition then
        composition:AskUser("Datamosh", {
            { "Message", "Text", Name = "Error", Default = tostring(message), ReadOnly = true, Lines = 4 },
        })
    end
end



