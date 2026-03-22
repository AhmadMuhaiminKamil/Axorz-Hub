-- ============================================================
--  AXORZ HUB | v2.1 — FIX CHICKEN DETECTION + ANCHOR CONFLICT
--  PERUBAHAN dari v2.0:
--  [FIX 1] Loop freeze tidak lagi anchor player saat GlobalPause=true
--          (chicken routine yang handle anchor/unanchor sendiri)
--  [FIX 2] EggWatcher sekarang cek telur yang SUDAH ADA di kandang
--          (bukan hanya ChildAdded)
--  [FIX 3] Active polling tiap 5 detik untuk cek egg ready
--          (backup jika watcher miss)
--  [FIX 4] DoChickenRoutineForFarmAll un-anchor player dulu
--          sebelum mulai teleport ke egg/slot
--  [FIX 5] ReleaseChickenLock selalu un-anchor di akhir
-- ============================================================

local Fluent           = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
local SaveManager      = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua"))()
local InterfaceManager = loadstring(game:HttpGet("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/InterfaceManager.lua"))()

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser       = game:GetService("VirtualUser")
local LocalPlayer       = Players.LocalPlayer

local function GetHRP()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function GetHumanoid()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

-- ──────────────────────────────────────────────────────────
--  REMOTES
-- ──────────────────────────────────────────────────────────
local TutorialRemotes = ReplicatedStorage:WaitForChild("Remotes")
                          :WaitForChild("TutorialRemotes")

local RemotePlant      = TutorialRemotes:WaitForChild("PlantCrop")
local RemotePlantBesar = TutorialRemotes:WaitForChild("PlantLahanCrop")
local RemoteSell       = TutorialRemotes:WaitForChild("RequestSell")
local RemoteSellCrop   = TutorialRemotes:WaitForChild("SellCrop")
local RemoteShop       = TutorialRemotes:WaitForChild("RequestShop")

-- ──────────────────────────────────────────────────────────
--  CONFIG
-- ──────────────────────────────────────────────────────────
local Config = {
    -- Farm biasa
    AutoFarm          = false,
    AutoHarvest       = false,
    AutoPlant         = false,
    AutoSell          = false,
    AutoSellCrop      = false,
    AutoSellEgg       = false,
    AutoBuy           = false,
    HarvestDelay      = 0.05,
    PlantDelay        = 0.3,
    SellDelay         = 6,
    BuyDelay          = 10,
    BuyAmount         = 10,
    CycleDelay        = 2.0,
    MaxPlant          = 13,
    SelectedSeed      = nil,
    SelectedBuy       = nil,
    SelectedArea      = nil,
    CircleRadius      = 5,
    UseCircle         = false,
    -- Farm besar
    AutoFarmBesar     = false,
    AutoHarvestBesar  = false,
    AutoPlantBesar    = false,
    ClaimedAreaBesar  = nil,
    SelectedAreaBesar = nil,
    IsFarmingBesar    = false,
    -- Player
    WalkSpeed         = 16,
    InfiniteJump      = false,
    Freeze            = false,
    -- ESP
    ESPEnabled        = false,
    ESPShowAll        = false,
    -- AFK
    AntiAFK           = true,
    AntiAFKDelay      = 18,
    -- Chicken
    AutoFeed          = false,
    AutoClaimEgg      = false,
    FeedDelay         = 0.3,
    ClaimDelay        = 0.3,
    IsChickenBusy     = false,
    EggReadyFlag      = false,
    ChickenCoopName   = nil,
    FeedSeedName      = nil,
    -- ── GLOBAL PAUSE ──
    -- true = semua loop farm berhenti, chicken sedang jalan
    GlobalPause       = false,
}
_G.AxorzConfig = Config

-- ──────────────────────────────────────────────────────────
--  AUTO FARM ALL: aktif jika SEMUA 4 toggle ON
-- ──────────────────────────────────────────────────────────
local function IsAutoFarmAllActive()
    return Config.AutoFarm
        and Config.AutoFarmBesar
        and Config.AutoFeed
        and Config.AutoClaimEgg
end

-- ──────────────────────────────────────────────────────────
--  HELPER: loop boleh jalan?
-- ──────────────────────────────────────────────────────────
local function CanRun()
    return not Config.GlobalPause
end

-- ──────────────────────────────────────────────────────────
--  ANTI-AFK
-- ──────────────────────────────────────────────────────────
local AntiAFKThread = nil

local function StartAntiAFK()
    if AntiAFKThread then task.cancel(AntiAFKThread) AntiAFKThread = nil end
    AntiAFKThread = task.spawn(function()
        while Config.AntiAFK do
            task.wait(60 * Config.AntiAFKDelay)
            if Config.AntiAFK then
                VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
                task.wait(1)
                VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
            end
        end
    end)
end
StartAntiAFK()

-- ──────────────────────────────────────────────────────────
--  DATA
-- ──────────────────────────────────────────────────────────
local PlotPositions      = {}
local PlotPositionsBesar = {}
local OurCrops           = {}
local OurCropsBesar      = {}
local PendingPlantPos    = {}
local CLAIM_RADIUS       = 2.5
local MAX_BESAR          = 2
local SavedCirclePositions = {}

local ActiveCrops = workspace:WaitForChild("ActiveCrops", 10)

-- ──────────────────────────────────────────────────────────
--  MUTEX
-- ──────────────────────────────────────────────────────────
local PlantBesarLock     = false
local ChickenBusyLock    = false
local FarmGabunganDebounce = false

local function AcquireBesarLock()
    if PlantBesarLock then return false end
    PlantBesarLock        = true
    Config.IsFarmingBesar = true
    task.wait(0.5)
    return true
end

local function ReleaseBesarLock()
    Config.IsFarmingBesar = false
    PlantBesarLock        = false
end

-- ──────────────────────────────────────────────────────────
--  [FIX 4 & 5] CHICKEN LOCK — tidak anchor di sini,
--  routine yang handle sendiri sebelum teleport
-- ──────────────────────────────────────────────────────────
local function AcquireChickenLock()
    if ChickenBusyLock then return false end
    ChickenBusyLock      = true
    Config.IsChickenBusy = true
    Config.GlobalPause   = true
    print("[Axorz Hub] >>> GlobalPause ON — farm loop berhenti <<<")
    task.wait(0.3)
    return true
end

local function ReleaseChickenLock()
    Config.IsChickenBusy = false
    ChickenBusyLock      = false
    Config.GlobalPause   = false
    -- [FIX 5] Pastikan selalu un-anchor dan restore stats di akhir
    local hrp = GetHRP()
    local hum = GetHumanoid()
    if hrp then hrp.Anchored = false end
    if hum then hum.WalkSpeed = Config.WalkSpeed; hum.JumpHeight = 7.2 end
    print("[Axorz Hub] >>> GlobalPause OFF — farm loop lanjut <<<")
end

-- ──────────────────────────────────────────────────────────
--  SEED MANAGEMENT
-- ──────────────────────────────────────────────────────────
local function GetSeedsInBackpack()
    local seeds = {}
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local char = LocalPlayer.Character
    if not backpack then return seeds end
    local function processTool(tool)
        if tool:IsA("Tool") then
            local name = tool.Name
            if name:lower():find("bibit") then
                local baseName = name:match("^(.-)%s*x%d+$") or name
                local count = tonumber(name:match("x(%d+)$")) or 1
                local dup = false
                for _, s in ipairs(seeds) do if s.baseName == baseName then dup = true break end end
                if not dup then table.insert(seeds, {baseName=baseName, fullName=name, count=count, tool=tool}) end
            end
        end
    end
    for _, item in pairs(backpack:GetChildren()) do processTool(item) end
    if char then for _, item in pairs(char:GetChildren()) do processTool(item) end end
    return seeds
end

local function GetBesarSeedInfo()
    local info = {sawit=0, durian=0, sawitBase=nil, durianBase=nil}
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local char = LocalPlayer.Character
    local function scan(parent)
        if not parent then return end
        for _, item in pairs(parent:GetChildren()) do
            if item:IsA("Tool") then
                local name = item.Name:lower()
                if name:find("bibit") then
                local count = tonumber(item.Name:match("x(%d+)$")) or 1
                local baseName = item.Name:match("^(.-)%s*x%d+$") or item.Name
                if name:find("sawit") or name:find("palm") then
                    info.sawit = info.sawit + count; info.sawitBase = baseName
                elseif name:find("durian") then
                    info.durian = info.durian + count; info.durianBase = baseName
                end
                end
            end
        end
    end
    scan(backpack); scan(char)
    return info
end

local function FindSeedTool(baseName)
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local char = LocalPlayer.Character
    if not backpack then return nil end
    local function searchIn(parent)
        for _, item in pairs(parent:GetChildren()) do
            if item:IsA("Tool") then
                local itemBase = item.Name:match("^(.-)%s*x%d+$") or item.Name
                if itemBase == baseName then return item end
            end
        end
        return nil
    end
    return searchIn(backpack) or (char and searchIn(char))
end

local function EquipSeed(baseName)
    if not baseName then return false end
    local hum = GetHumanoid()
    if not hum then return false end
    local char = LocalPlayer.Character
    if char then
        for _, item in pairs(char:GetChildren()) do
            if item:IsA("Tool") then
                local itemBase = item.Name:match("^(.-)%s*x%d+$") or item.Name
                if itemBase == baseName then return true end
            end
        end
    end
    local tool = FindSeedTool(baseName)
    if tool then hum:EquipTool(tool) task.wait(0.3) return true end
    return false
end

-- ──────────────────────────────────────────────────────────
--  UTILITAS
-- ──────────────────────────────────────────────────────────
local AreaTanamData      = {}
local AreaTanamBesarData = {}

local function ScanAllAreaTanam()
    AreaTanamData = {}
    for _, obj in pairs(workspace:GetChildren()) do
        if obj:IsA("BasePart") and obj.Name:match("^AreaTanam%d*$") then
            if not AreaTanamData[obj.Name] then
                AreaTanamData[obj.Name] = {instance=obj, position=obj.Position}
            end
        end
    end
    local sorted = {}
    for name, data in pairs(AreaTanamData) do table.insert(sorted, {name=name, data=data}) end
    table.sort(sorted, function(a,b)
        return (tonumber(a.name:match("%d+$")) or 0) < (tonumber(b.name:match("%d+$")) or 0)
    end)
    return sorted
end

local function ScanAllAreaTanamBesar()
    AreaTanamBesarData = {}
    for _, obj in pairs(workspace:GetChildren()) do
        if obj:IsA("BasePart") and obj.Name:match("^AreaTanamBesar%d*$") then
            if not AreaTanamBesarData[obj.Name] then
                AreaTanamBesarData[obj.Name] = {instance=obj, position=obj.Position}
            end
        end
    end
    local sorted = {}
    for name, data in pairs(AreaTanamBesarData) do table.insert(sorted, {name=name, data=data}) end
    table.sort(sorted, function(a,b)
        return (tonumber(a.name:match("%d+$")) or 0) < (tonumber(b.name:match("%d+$")) or 0)
    end)
    return sorted
end

local function TeleportTo(cf)
    local hrp = GetHRP()
    if hrp then hrp.CFrame = cf end
end

local function TeleportAndVerify(center, maxRetry)
    maxRetry = maxRetry or 3
    for i = 1, maxRetry do
        TeleportTo(CFrame.new(center + Vector3.new(0, 4, 0)))
        task.wait(0.8)
        local hrp = GetHRP()
        if hrp and (hrp.Position - center).Magnitude <= 12 then return true end
        task.wait(0.3)
    end
    TeleportTo(CFrame.new(center + Vector3.new(0, 4, 0)))
    task.wait(1.5)
    local hrp = GetHRP()
    return hrp and (hrp.Position - center).Magnitude <= 20
end

local function GetOurCropCount()
    local n = 0; for _ in pairs(OurCrops) do n = n + 1 end; return n
end

local function GetOurCropBesarCount()
    local n = 0; for _ in pairs(OurCropsBesar) do n = n + 1 end; return n
end

local function RegisterPending(pos)
    local isOurPlot = false
    for _, plotPos in ipairs(PlotPositions) do
        if (Vector3.new(pos.X,0,pos.Z) - Vector3.new(plotPos.X,0,plotPos.Z)).Magnitude <= CLAIM_RADIUS then
            isOurPlot = true break
        end
    end
    if not isOurPlot then return end
    local entry = {pos=pos, expireAt=tick()+4}
    table.insert(PendingPlantPos, entry)
    task.delay(4, function()
        for i, e in ipairs(PendingPlantPos) do
            if e == entry then table.remove(PendingPlantPos, i) break end
        end
    end)
end

-- ──────────────────────────────────────────────────────────
--  CROP TRACKING
-- ──────────────────────────────────────────────────────────
local TrackDebounce      = {}
local TrackDebounceBesar = {}

local function IsOurCrop(crop)
    local owner = crop:GetAttribute("OwnerId")
    return owner ~= nil and tostring(owner) == tostring(LocalPlayer.UserId)
end

local function IsNearAreaBesar(pos)
    for _, data in pairs(AreaTanamBesarData) do
        if (Vector3.new(pos.X,0,pos.Z) - Vector3.new(data.position.X,0,data.position.Z)).Magnitude <= 6 then
            return true
        end
    end
    return false
end

local DoSell, DoSellCrop

local function DoHarvestSingle(crop)
    if not crop or not crop.Parent then return end
    pcall(function()
        for _, child in pairs(crop:GetDescendants()) do
            if child:IsA("ProximityPrompt") and child.Enabled then
                fireproximityprompt(child)
                task.delay(0.5, function()
                    local isBesar = OurCropsBesar[crop.Name] ~= nil
                    if isBesar then
                        if Config.AutoSellCrop or Config.AutoFarmBesar or Config.AutoFarm then pcall(DoSellCrop) end
                    else
                        if Config.AutoSell or Config.AutoFarm then pcall(DoSell) end
                    end
                end)
                break
            end
        end
    end)
end

local function WatchCropBiasa(crop)
    if crop:GetAttribute("IsReady") then
        task.defer(function()
            if Config.AutoHarvest or Config.AutoFarm then DoHarvestSingle(crop) end
        end)
    end
    crop:GetAttributeChangedSignal("IsReady"):Connect(function()
        if not crop:GetAttribute("IsReady") then return end
        if not (Config.AutoHarvest or Config.AutoFarm) then return end
        DoHarvestSingle(crop)
    end)
end

local function RegisterCrop(crop)
    if TrackDebounce[crop] then return end
    TrackDebounce[crop] = true
    OurCrops[crop.Name] = crop
    task.defer(function()
        if crop and crop.Parent then pcall(WatchCropBiasa, crop) end
    end)
end

local DoFarmGabungan

local function RegisterCropBesar(crop)
    if TrackDebounceBesar[crop] then return end
    TrackDebounceBesar[crop] = true
    OurCropsBesar[crop.Name] = crop
    task.defer(function()
        if not crop or not crop.Parent then return end
        pcall(function()
            if crop:GetAttribute("IsReady") then
                if Config.AutoHarvestBesar or Config.AutoFarmBesar then DoHarvestSingle(crop) end
                if Config.AutoFarm and Config.AutoFarmBesar and not FarmGabunganDebounce then
                    FarmGabunganDebounce = true
                    task.spawn(function() pcall(DoFarmGabungan) FarmGabunganDebounce = false end)
                end
            end
            crop:GetAttributeChangedSignal("IsReady"):Connect(function()
                if not crop:GetAttribute("IsReady") then return end
                if not OurCropsBesar[crop.Name] then return end
                if Config.AutoFarm and Config.AutoFarmBesar then
                    if not FarmGabunganDebounce and not Config.IsFarmingBesar and Config.ClaimedAreaBesar then
                        FarmGabunganDebounce = true
                        task.spawn(function() pcall(DoFarmGabungan) FarmGabunganDebounce=false end)
                    end
                elseif Config.AutoHarvestBesar or Config.AutoFarmBesar then
                    DoHarvestSingle(crop)
                end
            end)
        end)
    end)
end

if ActiveCrops then
    for _, crop in pairs(ActiveCrops:GetChildren()) do
        if IsOurCrop(crop) then
            local root = crop:FindFirstChild("Root") or crop:FindFirstChildWhichIsA("BasePart")
            if root and IsNearAreaBesar(root.Position) then RegisterCropBesar(crop) else RegisterCrop(crop) end
        end
    end
    ActiveCrops.ChildAdded:Connect(function(crop)
        task.wait(0.3)
        if IsOurCrop(crop) then
            local root = crop:FindFirstChild("Root") or crop:FindFirstChildWhichIsA("BasePart")
            if root and IsNearAreaBesar(root.Position) then RegisterCropBesar(crop) else RegisterCrop(crop) end
        end
    end)
    ActiveCrops.ChildRemoved:Connect(function(crop)
        OurCrops[crop.Name]=nil; OurCropsBesar[crop.Name]=nil
        TrackDebounce[crop]=nil; TrackDebounceBesar[crop]=nil
        if GetOurCropCount() == 0 then SavedCirclePositions = {} end
    end)
end

-- ──────────────────────────────────────────────────────────
--  CIRCLE POSITIONS
-- ──────────────────────────────────────────────────────────
local function GenerateCirclePositions(center, radius, amount)
    local positions = {}
    local minRadius = (amount * 2.5) / (2 * math.pi)
    local useRadius = math.max(radius, minRadius)
    for i = 1, amount do
        local angle = (2 * math.pi / amount) * (i - 1)
        table.insert(positions, Vector3.new(
            center.X + useRadius * math.cos(angle), center.Y,
            center.Z + useRadius * math.sin(angle)))
    end
    return positions
end

-- ──────────────────────────────────────────────────────────
--  ENGINE: PLANT BIASA
-- ──────────────────────────────────────────────────────────
local function DoPlantAll()
    if not CanRun() then return end
    if Config.IsFarmingBesar then return end
    local currentCount = GetOurCropCount()
    if Config.UseCircle and currentCount > 0 then return end
    if currentCount >= Config.MaxPlant then return end

    local center = nil
    if Config.SelectedArea and AreaTanamData[Config.SelectedArea] then
        center = AreaTanamData[Config.SelectedArea].position
    elseif #PlotPositions > 0 then
        center = PlotPositions[1]
    else return end

    local hrp = GetHRP()
    if hrp and (hrp.Position - center).Magnitude > 20 then
        if not CanRun() then return end
        TeleportTo(CFrame.new(center + Vector3.new(0, 4, 0)))
        task.wait(0.5)
    end

    if Config.UseCircle then hrp = GetHRP(); if hrp then center = hrp.Position end end

    local targetPositions = {}
    if Config.UseCircle then
        if #SavedCirclePositions ~= Config.MaxPlant then
            SavedCirclePositions = GenerateCirclePositions(center, Config.CircleRadius, Config.MaxPlant)
        end
        targetPositions = SavedCirclePositions
    else
        targetPositions = {center}
    end

    if Config.SelectedSeed then
        if not EquipSeed(Config.SelectedSeed) then return end
        task.wait(0.2)
    end

    local toPlant = Config.MaxPlant - currentCount
    local planted = 0

    for _, pos in ipairs(targetPositions) do
        if not CanRun() or Config.IsFarmingBesar then return end
        if not (Config.AutoPlant or Config.AutoFarm) then break end
        if planted >= toPlant then break end
        local beforeCount = GetOurCropCount()
        pcall(function() RegisterPending(pos) RemotePlant:FireServer(pos) end)
        task.wait(Config.PlantDelay + 0.1)
        if not CanRun() or Config.IsFarmingBesar then return end
        if GetOurCropCount() > beforeCount then
            planted = planted + 1
        else
            task.wait(0.15)
            if not CanRun() then return end
            pcall(function() RemotePlant:FireServer(pos) end)
            task.wait(0.25)
            if GetOurCropCount() > beforeCount then planted = planted + 1 end
        end
    end
end

-- ──────────────────────────────────────────────────────────
--  ENGINE: PLANT BESAR
-- ──────────────────────────────────────────────────────────
local function IsCropBesarReady()
    for _, crop in pairs(OurCropsBesar) do
        if crop and crop.Parent and crop:GetAttribute("IsReady") then return true end
    end
    return false
end

local function DoPlantAllBesar()
    if not CanRun() then return end
    if not AcquireBesarLock() then return end
    local ok, err = pcall(function()
        local currentCount = GetOurCropBesarCount()
        if currentCount >= MAX_BESAR then return end
        if not Config.ClaimedAreaBesar then return end
        local center = AreaTanamBesarData[Config.ClaimedAreaBesar] and AreaTanamBesarData[Config.ClaimedAreaBesar].position
            or (#PlotPositionsBesar > 0 and PlotPositionsBesar[1]) or nil
        if not center then return end
        if not TeleportAndVerify(center, 3) then return end
        local hasSawit, hasDurian = false, false
        for _, crop in pairs(OurCropsBesar) do
            local st = (crop:GetAttribute("SeedType") or crop.Name or ""):lower()
            if st:find("sawit") or st:find("palm") then hasSawit = true end
            if st:find("durian") then hasDurian = true end
        end
        local seedInfo = GetBesarSeedInfo()
        if not hasSawit and seedInfo.sawit > 0 and seedInfo.sawitBase then
            if (Config.AutoPlantBesar or Config.AutoFarmBesar) and EquipSeed(seedInfo.sawitBase) then
                task.wait(0.3)
                local hrp = GetHRP()
                if not hrp or (hrp.Position - center).Magnitude > 12 then TeleportAndVerify(center, 2) end
                local before = GetOurCropBesarCount()
                pcall(function() RemotePlantBesar:FireServer(center) end)
                task.wait(1.0)
                if GetOurCropBesarCount() <= before then
                    pcall(function() RemotePlantBesar:FireServer(center) end)
                    task.wait(0.8)
                end
            end
        end
        seedInfo = GetBesarSeedInfo(); hasDurian = false
        for _, crop in pairs(OurCropsBesar) do
            local st = (crop:GetAttribute("SeedType") or crop.Name or ""):lower()
            if st:find("durian") then hasDurian = true end
        end
        if not hasDurian and seedInfo.durian > 0 and seedInfo.durianBase then
            if (Config.AutoPlantBesar or Config.AutoFarmBesar) and EquipSeed(seedInfo.durianBase) then
                task.wait(0.3)
                local hrp = GetHRP()
                if not hrp or (hrp.Position - center).Magnitude > 12 then TeleportAndVerify(center, 2) end
                local before = GetOurCropBesarCount()
                pcall(function() RemotePlantBesar:FireServer(center) end)
                task.wait(1.0)
                if GetOurCropBesarCount() <= before then
                    pcall(function() RemotePlantBesar:FireServer(center) end)
                    task.wait(0.8)
                end
            end
        end
    end)
    if not ok then print("[Axorz Hub] DoPlantAllBesar error:", err) end
    if Config.AutoFarm or Config.AutoPlantBesar or Config.AutoFarmBesar then
        LastPlantBesarTime = tick()
        local posLahanBiasa = (Config.SelectedArea and AreaTanamData[Config.SelectedArea] and AreaTanamData[Config.SelectedArea].position)
            or (#PlotPositions > 0 and PlotPositions[1]) or nil
        if posLahanBiasa and CanRun() then
            TeleportTo(CFrame.new(posLahanBiasa + Vector3.new(0, 4, 0)))
            task.wait(0.5)
            if Config.SelectedSeed then pcall(function() EquipSeed(Config.SelectedSeed) end) end
        end
    end
    ReleaseBesarLock()
end

-- ──────────────────────────────────────────────────────────
--  ENGINE: SELL
-- ──────────────────────────────────────────────────────────
DoSell = function()
    local list = nil
    pcall(function() list = RemoteSell:InvokeServer("GET_LIST") end)
    if type(list) ~= "table" then return end
    local items = list["Items"] or list["items"]
    if type(items) ~= "table" then return end
    local sold = 0
    for _, item in pairs(items) do
        if type(item) == "table" then
            local name = item.Name or item.name
            local owned = item.Owned or item.owned or 0
            if name and owned > 0 then
                pcall(function() RemoteSell:InvokeServer("SELL", name, owned) end)
                sold = sold + 1; task.wait(0.05)
            end
        end
    end
    if sold > 0 then Fluent:Notify({Title="Auto Sell", Content=("✅ %d item terjual!"):format(sold), Duration=2}) end
end

local function DoSellCropByType(fruitType)
    local ok1, result = pcall(function() return RemoteSell:InvokeServer("GET_FRUIT_LIST", fruitType) end)
    if not ok1 or type(result) ~= "table" then return 0 end
    if result.Success == false then return 0 end
    local fruitList = result.FruitList or result.fruitList or result.Items or result.items
    if type(fruitList) ~= "table" then return 0 end
    local totalSold = 0
    for _, item in pairs(fruitList) do
        if type(item) == "table" then
        local itemId = item.Id or item.id
        if itemId then
        local ok2, sellResult = pcall(function() return RemoteSell:InvokeServer("SELL_FRUIT", itemId, fruitType) end)
        if ok2 and type(sellResult) == "table" then
            if sellResult.Success then totalSold = totalSold + 1
            elseif tostring(sellResult.Message):lower():find("wait") then
                task.wait(2)
                local ok3, retry = pcall(function() return RemoteSell:InvokeServer("SELL_FRUIT", itemId, fruitType) end)
                if ok3 and type(retry) == "table" and retry.Success then totalSold = totalSold + 1 end
            end
        end
        task.wait(1.2)
        end
        end
    end
    return totalSold
end

DoSellCrop = function()
    local fruitTypes = {}
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local char = LocalPlayer.Character
    local function scanFruit(parent)
        if not parent then return end
        for _, item in pairs(parent:GetChildren()) do
            if item:IsA("Tool") then
                local name = item.Name:lower()
                if not name:find("bibit") and not name:find("seed") then
                    if name:find("sawit") or name:find("palm") then fruitTypes["Sawit"] = true
                    elseif name:find("durian") then fruitTypes["Durian"] = true end
                end
            end
        end
    end
    scanFruit(backpack); scanFruit(char)
    if not next(fruitTypes) then fruitTypes["Sawit"]=true; fruitTypes["Durian"]=true end
    local sold = 0
    for fruitType in pairs(fruitTypes) do
        local s = DoSellCropByType(fruitType) or 0; sold = sold + s; task.wait(0.1)
    end
    if sold > 0 then Fluent:Notify({Title="Auto Sell Crop", Content=("🌴 %d buah terjual!"):format(sold), Duration=3}) end
end

local function DoSellEgg()
    local ok, result = pcall(function() return RemoteSell:InvokeServer("SELL_ALL_EGG") end)
    if ok and type(result) == "table" then
        if result.Success then
            Fluent:Notify({Title="Auto Sell Egg", Content=("🥚 %s"):format(result.Message or "Telur terjual!"), Duration=3})
        elseif tostring(result.Message):lower():find("wait") then
            task.wait(2); pcall(function() RemoteSell:InvokeServer("SELL_ALL_EGG") end)
        end
    end
end

-- ──────────────────────────────────────────────────────────
--  ENGINE: BUY
-- ──────────────────────────────────────────────────────────
local ShopList = {}
local function FetchShopList()
    local ok, result = pcall(function() return RemoteShop:InvokeServer("GET_LIST") end)
    if ok and type(result) == "table" then ShopList = result return result end
    return nil
end
local function DoBuy()
    if not Config.SelectedBuy then return end
    pcall(function() RemoteShop:InvokeServer("BUY", Config.SelectedBuy, Config.BuyAmount) end)
end

-- ──────────────────────────────────────────────────────────
--  FARM GABUNGAN (Sawit + Durian)
-- ──────────────────────────────────────────────────────────
DoFarmGabungan = function()
    if not CanRun() then return end
    if not ((Config.AutoFarm and Config.AutoFarmBesar) or IsAutoFarmAllActive()) then return end
    if not Config.ClaimedAreaBesar then return end
    if not IsCropBesarReady() then return end
    if not AcquireBesarLock() then return end

    local ok, err = pcall(function()
        local posLahanBiasa = (Config.SelectedArea and AreaTanamData[Config.SelectedArea] and AreaTanamData[Config.SelectedArea].position)
            or (#PlotPositions > 0 and PlotPositions[1]) or nil
        local centerBesar = (AreaTanamBesarData[Config.ClaimedAreaBesar] and AreaTanamBesarData[Config.ClaimedAreaBesar].position)
            or (#PlotPositionsBesar > 0 and PlotPositionsBesar[1]) or nil
        if not centerBesar then return end

        Fluent:Notify({Title="Farm Gabungan", Content="🌴 Menuju lahan besar...", Duration=3})
        if not TeleportAndVerify(centerBesar, 3) then return end

        local harvested = 0
        for cropName, crop in pairs(OurCropsBesar) do
            if not crop or not crop.Parent then OurCropsBesar[cropName]=nil
            elseif crop:GetAttribute("IsReady") then
            pcall(function()
                for _, child in pairs(crop:GetDescendants()) do
                    if child:IsA("ProximityPrompt") and child.Enabled then
                        fireproximityprompt(child); harvested=harvested+1; task.wait(Config.HarvestDelay); break
                    end
                end
            end)
            end
        end
        if harvested > 0 then
            Fluent:Notify({Title="Farm Gabungan", Content=("✅ %d crop besar dipanen!"):format(harvested), Duration=3})
            task.wait(0.5)
        end

        local hrp = GetHRP()
        if not hrp or (hrp.Position - centerBesar).Magnitude > 12 then TeleportAndVerify(centerBesar, 2) end

        local seedInfo = GetBesarSeedInfo()
        local planted = 0
        local hasSawit = false
        for _, crop in pairs(OurCropsBesar) do
            local st = (crop:GetAttribute("SeedType") or crop.Name or ""):lower()
            if st:find("sawit") or st:find("palm") then hasSawit = true end
        end
        if not hasSawit and seedInfo.sawit > 0 and seedInfo.sawitBase and EquipSeed(seedInfo.sawitBase) then
            task.wait(0.3)
            hrp = GetHRP()
            if not hrp or (hrp.Position - centerBesar).Magnitude > 12 then TeleportAndVerify(centerBesar, 2) end
            local before = GetOurCropBesarCount()
            pcall(function() RemotePlantBesar:FireServer(centerBesar) end)
            task.wait(1.0)
            if GetOurCropBesarCount() > before then planted = planted + 1 end
        end

        seedInfo = GetBesarSeedInfo()
        local hasDurian = false
        for _, crop in pairs(OurCropsBesar) do
            local st = (crop:GetAttribute("SeedType") or crop.Name or ""):lower()
            if st:find("durian") then hasDurian = true end
        end
        if not hasDurian and seedInfo.durian > 0 and seedInfo.durianBase and EquipSeed(seedInfo.durianBase) then
            task.wait(0.3)
            hrp = GetHRP()
            if not hrp or (hrp.Position - centerBesar).Magnitude > 12 then TeleportAndVerify(centerBesar, 2) end
            local before = GetOurCropBesarCount()
            pcall(function() RemotePlantBesar:FireServer(centerBesar) end)
            task.wait(1.0)
            if GetOurCropBesarCount() > before then planted = planted + 1 end
        end

        if planted > 0 then
            Fluent:Notify({Title="Farm Gabungan", Content=("🌱 %d benih ditanam ulang!"):format(planted), Duration=3})
        end

        if posLahanBiasa and CanRun() then
            TeleportTo(CFrame.new(posLahanBiasa + Vector3.new(0, 4, 0)))
            task.wait(0.6)
            if Config.SelectedSeed then pcall(function() EquipSeed(Config.SelectedSeed) end) end
        end
    end)

    if not ok then print("[Axorz Hub] DoFarmGabungan error:", err) end
    ReleaseBesarLock()
end

-- ──────────────────────────────────────────────────────────
--  DETECT LAHAN
-- ──────────────────────────────────────────────────────────
local function DetectLahanSaya()
    local sorted = ScanAllAreaTanamBesar()
    local myId = tostring(LocalPlayer.UserId)
    local myName = LocalPlayer.Name:lower()
    for _, entry in ipairs(sorted) do
        local areaObj = entry.data.instance
        if areaObj and areaObj.Parent then
        for attrName, attrVal in pairs(areaObj:GetAttributes()) do
            local valStr = tostring(attrVal):lower()
            if valStr == myId or valStr == myName then
                Config.ClaimedAreaBesar = entry.name; Config.SelectedAreaBesar = entry.name
                PlotPositionsBesar = {areaObj.Position}
                return entry.name, attrName
            end
        end
        end
    end
    local hrp = GetHRP()
    if hrp then
        local closest, closestDist = nil, math.huge
        for _, entry in ipairs(sorted) do
            local areaObj = entry.data.instance
            if areaObj and areaObj.Parent then
            local dist = (hrp.Position - areaObj.Position).Magnitude
            if dist < closestDist then closestDist = dist; closest = entry end
            end
        end
        if closest and closestDist < 10 then
            Config.ClaimedAreaBesar = closest.name; Config.SelectedAreaBesar = closest.name
            PlotPositionsBesar = {closest.data.instance.Position}
            return closest.name, "jarak"
        end
    end
    return nil, "tidak ditemukan"
end

local function DoClaimLahan()
    if Config.ClaimedAreaBesar and AreaTanamBesarData[Config.ClaimedAreaBesar] then return true end
    local sorted = ScanAllAreaTanamBesar()
    for _, entry in ipairs(sorted) do
        local areaObj = entry.data.instance
        if areaObj and areaObj.Parent then
        local owner = areaObj:GetAttribute("OwnerId") or areaObj:GetAttribute("Owner") or areaObj:GetAttribute("PlayerId")
        if owner ~= nil and tostring(owner) == tostring(LocalPlayer.UserId) then
            Config.ClaimedAreaBesar = entry.name; Config.SelectedAreaBesar = entry.name
            PlotPositionsBesar = {areaObj.Position}; return true
        end
        local isEmpty = (owner == nil or owner == 0 or owner == "" or owner == false)
        if isEmpty then
        local prompt = areaObj:FindFirstChildWhichIsA("ProximityPrompt")
        if prompt and prompt.Enabled then
        TeleportTo(CFrame.new(areaObj.Position + Vector3.new(0, 4, 0)))
        task.wait(1.0); fireproximityprompt(prompt); task.wait(1.5)
        Config.ClaimedAreaBesar = entry.name; Config.SelectedAreaBesar = entry.name
        PlotPositionsBesar = {areaObj.Position}; return true
        end
        end
        end
    end
    return false
end

-- ══════════════════════════════════════════════════════════
--  CHICKEN SYSTEM
-- ══════════════════════════════════════════════════════════

local function FindMyCoopPlot()
    local myName = LocalPlayer.Name:lower()
    local myId   = tostring(LocalPlayer.UserId)
    for _, obj in pairs(workspace:GetChildren()) do
        local n = obj.Name:lower()
        if n:find("coop") and (n:find(myName) or n:find(myId)) then return obj end
    end
    local coopFolder = workspace:FindFirstChild("CoopPlots")
    if coopFolder then
        for _, obj in pairs(coopFolder:GetChildren()) do
            local n = obj.Name:lower()
            if n:find(myName) or n:find(myId) then return obj end
        end
    end
    for _, obj in pairs(workspace:GetChildren()) do
        if obj.Name:lower():find("coop") then
            local ownerId = obj:GetAttribute("OwnerId") or obj:GetAttribute("OwnerUserId")
            if ownerId and tostring(ownerId) == myId then return obj end
        end
    end
    return nil
end

-- ── CONFIRM GUI HELPER ──
local function ClickConfirmYes()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return false end
    local confirmGui = playerGui:FindFirstChild("ConfirmGui")
    if not confirmGui or not confirmGui.Enabled then return false end
    local yesBtn = nil
    for _, desc in pairs(confirmGui:GetDescendants()) do
        if desc.Name == "YesButton" then yesBtn = desc break end
    end
    if not yesBtn then return false end
    local fired = false
    pcall(function()
        local conns = getconnections(yesBtn.MouseButton1Click)
        if #conns > 0 then
            for _, c in ipairs(conns) do pcall(function() c.Function() end) end
            fired = true
        end
    end)
    if not fired then
        pcall(function()
            local conns = getconnections(yesBtn.MouseButton1Down)
            if #conns > 0 then
                for _, c in ipairs(conns) do pcall(function() c.Function(0,0) end) end
                fired = true
            end
        end)
    end
    return fired
end

-- ──────────────────────────────────────────────────────────
--  [FIX 1] HELPER: Cek apakah ada telur di kandang
--  Dipanggil oleh polling loop dan watcher
-- ──────────────────────────────────────────────────────────
local function HasEggInCoop(coop)
    if not coop then return false end
    for _, obj in pairs(coop:GetChildren()) do
        if obj.Name:lower():find("egg") then
            -- cek ada prompt yang enabled
            local function findPrompt(parent)
                if parent:IsA("BasePart") then
                    local p = parent:FindFirstChildOfClass("ProximityPrompt")
                    if p then return p end
                end
                for _, desc in pairs(parent:GetDescendants()) do
                    if desc:IsA("ProximityPrompt") then return desc end
                end
                return nil
            end
            local prompt = findPrompt(obj)
            if prompt and prompt.Enabled then
                return true
            end
        end
    end
    return false
end

-- ── AUTO FEED ──
local FeedDebounce = false

local function DoFeedChicken()
    if FeedDebounce then return end
    FeedDebounce = true
    local ok, err = pcall(function()
        local coop = nil
        if Config.ChickenCoopName then
            coop = workspace:FindFirstChild(Config.ChickenCoopName)
            if not coop then
                local cf = workspace:FindFirstChild("CoopPlots")
                if cf then coop = cf:FindFirstChild(Config.ChickenCoopName) end
            end
        end
        if not coop then coop = FindMyCoopPlot() end
        if not coop then return end
        Config.ChickenCoopName = coop.Name

        if Config.FeedSeedName then pcall(function() EquipSeed(Config.FeedSeedName) end) task.wait(0.3) end

        local feedPrompts = {}
        for _, desc in pairs(coop:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                local action = desc.ActionText:lower()
                if desc.Enabled and (action:find("feed") or action:find("makan") or action:find("beri")) then
                    table.insert(feedPrompts, desc)
                end
            end
        end

        print(("[Axorz Hub] Feed: ditemukan %d slot"):format(#feedPrompts))
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        local confirmGui = playerGui and playerGui:FindFirstChild("ConfirmGui")
        local fedCount = 0
        local hrp = GetHRP()

        for _, prompt in ipairs(feedPrompts) do
            if prompt and prompt.Parent and prompt.Enabled then

            -- Teleport ke slot feed karena ada MaxActivationDistance
            if hrp then
                local targetPos = nil
                local slotPart = prompt.Parent
                if slotPart and slotPart:IsA("BasePart") then
                    targetPos = slotPart.Position
                else
                    local p = prompt.Parent
                    while p and p ~= coop do
                        if p:IsA("BasePart") then targetPos = p.Position; break end
                        p = p.Parent
                    end
                end
                if targetPos then
                    -- [FIX 4] Un-anchor dulu sebelum teleport
                    hrp.Anchored = false
                    task.wait(0.05)
                    hrp = GetHRP()
                    if hrp then
                        hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0))
                        hrp.Anchored = true
                    end
                    task.wait(0.5)
                    print(("[Axorz Hub] Feed: teleport ke slot %s"):format(prompt.Parent.Name))
                end
            end

            pcall(function() fireproximityprompt(prompt) end)
            local confirmed = false
            for _ = 1, 15 do
                task.wait(0.1)
                if confirmGui and confirmGui.Enabled then
                    confirmed = ClickConfirmYes()
                    if confirmed then break end
                end
            end
            if confirmed then
                fedCount = fedCount + 1
                for _ = 1, 15 do
                    task.wait(0.1)
                    if confirmGui and not confirmGui.Enabled then break end
                end
            else
                print(("[Axorz Hub] Feed: ConfirmGui tidak muncul untuk %s"):format(prompt.Parent.Name))
            end
            task.wait(Config.FeedDelay)
            end
        end

        if fedCount > 0 then
            print(("[Axorz Hub] AutoFeed: %d slot diberi makan!"):format(fedCount))
            Fluent:Notify({Title="Auto Feed", Content=("🐔 %d slot diberi makan!"):format(fedCount), Duration=2})
        end
    end)
    if not ok then print("[Axorz Hub] DoFeedChicken error:", err) end
    FeedDebounce = false
end

-- ── AUTO CLAIM EGG ──
local ClaimEggDebounce = false
local EggWatcherConn   = nil

local function DoClaimEgg()
    if ClaimEggDebounce then return end
    ClaimEggDebounce = true
    local ok, err = pcall(function()
        local coop = nil
        if Config.ChickenCoopName then
            coop = workspace:FindFirstChild(Config.ChickenCoopName)
            if not coop then
                local cf = workspace:FindFirstChild("CoopPlots")
                if cf then coop = cf:FindFirstChild(Config.ChickenCoopName) end
            end
        end
        if not coop then coop = FindMyCoopPlot() end
        if not coop then return end
        Config.ChickenCoopName = coop.Name

        local hrp = GetHRP()
        if not hrp then return end

        local claimed = 0
        for _, obj in pairs(coop:GetChildren()) do
            if obj.Name:lower():find("egg") then

            local prompt = nil
            local eggPos = nil

            if obj:IsA("BasePart") then
                eggPos = obj.Position
                prompt = obj:FindFirstChildOfClass("ProximityPrompt")
                if not prompt then
                    for _, desc in pairs(obj:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then prompt = desc; break end
                    end
                end
            else
                local bp = obj:FindFirstChildWhichIsA("BasePart")
                if bp then eggPos = bp.Position end
                for _, desc in pairs(obj:GetDescendants()) do
                    if desc:IsA("ProximityPrompt") then prompt = desc; break end
                end
            end

            if prompt and prompt.Enabled then
            if eggPos then
                -- [FIX 4] Un-anchor dulu sebelum teleport ke egg
                local hrpTemp = GetHRP()
                if hrpTemp then hrpTemp.Anchored = false end
                task.wait(0.05)
                hrp = GetHRP()
                if hrp then
                    hrp.CFrame = CFrame.new(eggPos + Vector3.new(0, 3, 0))
                    hrp.Anchored = true
                end
                task.wait(0.5)
                print(("[Axorz Hub] DoClaimEgg: teleport ke %s, jarak=%.1f"):format(
                    obj.Name, hrp and (hrp.Position - eggPos).Magnitude or 0))
            end

            pcall(function() fireproximityprompt(prompt) end)
            claimed = claimed + 1
            print(("[Axorz Hub] DoClaimEgg: fired prompt %s"):format(obj.Name))
            task.wait(Config.ClaimDelay)
            else
                print(("[Axorz Hub] DoClaimEgg: skip %s (prompt nil atau disabled)"):format(obj.Name))
            end
            end
        end

        if claimed > 0 then
            print(("[Axorz Hub] AutoClaim: %d telur diklaim!"):format(claimed))
            Fluent:Notify({Title="Auto Claim Egg", Content=("🥚 %d telur diklaim!"):format(claimed), Duration=2})
            if Config.AutoSellEgg then task.wait(0.5); pcall(DoSellEgg) end
        else
            print("[Axorz Hub] AutoClaim: tidak ada telur yang bisa diklaim")
        end
    end)
    if not ok then print("[Axorz Hub] DoClaimEgg error:", err) end
    ClaimEggDebounce = false
end

-- ──────────────────────────────────────────────────────────
--  CHICKEN ROUTINE UNTUK AUTO FARM ALL
--  [FIX 4] Un-anchor player SEBELUM mulai teleport ke kandang
-- ──────────────────────────────────────────────────────────
local function DoChickenRoutineForFarmAll()
    if not AcquireChickenLock() then return end

    local ok, err = pcall(function()
        print("[Axorz Hub] Chicken Routine: GlobalPause ON, urus kandang...")
        Fluent:Notify({Title="Auto Farm All", Content="🐔 Farm di-pause, urus kandang...", Duration=2})

        -- [FIX 4] Un-anchor player dulu agar bisa teleport
        local hrp = GetHRP()
        local hum = GetHumanoid()
        if hrp then hrp.Anchored = false end
        if hum then hum.WalkSpeed = Config.WalkSpeed; hum.JumpHeight = 7.2 end
        task.wait(0.1)

        -- Claim egg — DoClaimEgg sudah teleport ke tiap egg
        ClaimEggDebounce = false
        pcall(DoClaimEgg)

        task.wait(0.5)

        -- Feed
        FeedDebounce = false
        pcall(DoFeedChicken)

        task.wait(0.3)
        if Config.AutoSellEgg then pcall(DoSellEgg) end

        Config.EggReadyFlag = false

        -- Balik ke lahan biasa
        local posLahanBiasa = (Config.SelectedArea and AreaTanamData[Config.SelectedArea] and AreaTanamData[Config.SelectedArea].position)
            or (#PlotPositions > 0 and PlotPositions[1]) or nil
        if posLahanBiasa then
            local hrpReturn = GetHRP()
            if hrpReturn then hrpReturn.Anchored = false end
            task.wait(0.05)
            TeleportTo(CFrame.new(posLahanBiasa + Vector3.new(0, 4, 0)))
            task.wait(0.5)
            if Config.SelectedSeed then pcall(function() EquipSeed(Config.SelectedSeed) end) end
        end

        print("[Axorz Hub] Chicken Routine selesai, farm dilanjutkan.")
        Fluent:Notify({Title="Auto Farm All", Content="✅ Kandang selesai, farm dilanjutkan!", Duration=2})
    end)

    if not ok then print("[Axorz Hub] DoChickenRoutineForFarmAll error:", err) end
    ReleaseChickenLock()
end

-- ──────────────────────────────────────────────────────────
--  [FIX 2] EGG WATCHER: cek telur yang SUDAH ADA + ChildAdded
-- ──────────────────────────────────────────────────────────
local function SetupEggWatcher(coop)
    if EggWatcherConn then
        pcall(function() EggWatcherConn:Disconnect() end)
        EggWatcherConn = nil
    end
    if not coop then return end

    -- [FIX 2] Cek telur yang sudah ada di kandang saat watcher dipasang
    task.defer(function()
        if not Config.AutoClaimEgg then return end
        if HasEggInCoop(coop) then
            print("[Axorz Hub] EggWatcher: telur sudah ada di kandang saat init!")
            Config.EggReadyFlag = true
            if not Config.IsChickenBusy then
                if Config.AutoFeed and Config.AutoClaimEgg then
                    task.spawn(function()
                        task.wait(0.5)
                        pcall(DoChickenRoutineForFarmAll)
                    end)
                else
                    task.spawn(function()
                        ClaimEggDebounce = false
                        pcall(DoClaimEgg)
                    end)
                end
            end
        end
    end)

    -- ChildAdded untuk telur baru
    EggWatcherConn = coop.ChildAdded:Connect(function(child)
        if not child.Name:lower():find("egg") then return end

        Config.EggReadyFlag = true
        print("[Axorz Hub] EggVisual muncul:", child.Name, "[" .. child.ClassName .. "]")

        if not Config.AutoClaimEgg then return end
        if Config.IsChickenBusy then return end

        -- Jika AutoFeed + AutoClaimEgg keduanya ON → pakai routine (GlobalPause)
        if Config.AutoFeed and Config.AutoClaimEgg then
            if not Config.IsChickenBusy then
                task.spawn(function()
                    task.wait(0.5)
                    pcall(DoChickenRoutineForFarmAll)
                end)
            end
            return
        end

        -- Mode AutoClaimEgg saja — teleport ke egg lalu fire prompt
        task.spawn(function()
            local prompt = nil
            for i = 1, 20 do
                task.wait(0.15)
                if child:IsA("BasePart") then
                    prompt = child:FindFirstChildOfClass("ProximityPrompt")
                end
                if not prompt then
                    for _, desc in pairs(child:GetDescendants()) do
                        if desc:IsA("ProximityPrompt") then prompt = desc; break end
                    end
                end
                if prompt and prompt.Enabled then break end
                prompt = nil
            end

            if not prompt or not prompt.Enabled then
                print("[Axorz Hub] EggWatcher: prompt tidak siap, skip")
                return
            end

            -- Teleport ke egg
            local hrp = GetHRP()
            if hrp then
                local eggPos = child:IsA("BasePart") and child.Position
                    or (child:FindFirstChildWhichIsA("BasePart") and child:FindFirstChildWhichIsA("BasePart").Position)
                if eggPos then
                    hrp.Anchored = false
                    task.wait(0.05)
                    hrp = GetHRP()
                    if hrp then
                        hrp.CFrame = CFrame.new(eggPos + Vector3.new(0, 3, 0))
                        task.wait(0.4)
                    end
                end
            end

            pcall(function() fireproximityprompt(prompt) end)
            print(("[Axorz Hub] Instant claim: %s"):format(child.Name))
            Config.EggReadyFlag = false

            task.delay(0.5, function()
                Fluent:Notify({Title="Auto Claim Egg", Content="🥚 Telur baru diklaim!", Duration=2})
            end)
        end)
    end)

    print(("[Axorz Hub] Egg watcher aktif: %s"):format(coop.Name))
end

-- ── INIT CHICKEN SYSTEM ──
local function InitChickenSystem()
    local coop = FindMyCoopPlot()
    if coop then
        Config.ChickenCoopName = coop.Name
        SetupEggWatcher(coop)
        print(("[Axorz Hub] Chicken system ready: %s"):format(coop.Name))
        return coop
    end
    print("[Axorz Hub] Kandang belum ditemukan.")
    return nil
end

task.delay(3, function() pcall(InitChickenSystem) end)

-- ──────────────────────────────────────────────────────────
--  ESP
-- ──────────────────────────────────────────────────────────
local ESPLabels = {}

local function GetServerTime()
    local ok, t = pcall(function() return workspace:GetServerTimeNow() end)
    return ok and t or tick()
end

local function GetCropProgress(crop)
    local isReady = crop:GetAttribute("IsReady")
    local growthTime = crop:GetAttribute("GrowthTime") or 60
    local seedType = crop:GetAttribute("SeedType") or "?"
    local plantedAt = crop:GetAttribute("PlantedAt")
    local phaseAttr = crop:GetAttribute("Phase") or 1
    local phaseDur = crop:GetAttribute("PhaseDuration") or 18
    if isReady then return 100, seedType, phaseAttr, true end
    if plantedAt and plantedAt > 0 and growthTime > 0 then
        local elapsed = GetServerTime() - plantedAt
        if elapsed > 0 then
            local progress = math.clamp((elapsed/growthTime)*100, 0, 99)
            local phase = math.clamp(math.floor(elapsed/phaseDur)+1, 1, math.floor(growthTime/phaseDur))
            return math.floor(progress), seedType, phase, false
        end
    end
    return 0, seedType, 1, false
end

local function GetCropRootPart(crop)
    return crop:FindFirstChild("Root") or crop:FindFirstChildWhichIsA("BasePart")
end

local function ProgressColor(progress)
    if progress >= 100 then return Color3.fromRGB(255,215,0) end
    local t = progress/100
    if t < 0.5 then return Color3.fromRGB(255, math.floor(t*2*165), 0)
    else local u=(t-0.5)*2; return Color3.fromRGB(math.floor((1-u)*255), math.floor(100+u*155), 0) end
end

local function CreateESPLabel(crop)
    if ESPLabels[crop] then
        pcall(function() ESPLabels[crop].bill:Destroy() end)
        pcall(function() ESPLabels[crop].highlight:Destroy() end)
        ESPLabels[crop] = nil
    end
    local root = GetCropRootPart(crop)
    if not root then return end
    local bill = Instance.new("BillboardGui")
    bill.Name="CropESP"; bill.Adornee=root; bill.AlwaysOnTop=true
    bill.Size=UDim2.fromOffset(110,42); bill.StudsOffset=Vector3.new(0,3,0)
    bill.ResetOnSpawn=false; bill.Parent=root
    local frame = Instance.new("Frame")
    frame.Size=UDim2.fromScale(1,1); frame.BackgroundColor3=Color3.fromRGB(15,15,15)
    frame.BackgroundTransparency=0.35; frame.BorderSizePixel=0; frame.Parent=bill
    Instance.new("UICorner",frame).CornerRadius=UDim.new(0,6)
    local lblName = Instance.new("TextLabel")
    lblName.Size=UDim2.new(1,0,0.48,0); lblName.BackgroundTransparency=1
    lblName.TextColor3=Color3.fromRGB(255,255,255); lblName.TextScaled=true
    lblName.Font=Enum.Font.GothamBold; lblName.Text="..."; lblName.Parent=frame
    local lblProg = Instance.new("TextLabel")
    lblProg.Size=UDim2.new(1,0,0.52,0); lblProg.Position=UDim2.fromScale(0,0.48)
    lblProg.BackgroundTransparency=1; lblProg.TextColor3=Color3.fromRGB(100,255,100)
    lblProg.TextScaled=true; lblProg.Font=Enum.Font.Gotham; lblProg.Text="0%"; lblProg.Parent=frame
    local highlight = Instance.new("Highlight")
    highlight.Name="CropHL_"..crop.Name; highlight.Adornee=crop
    highlight.FillTransparency=1; highlight.OutlineColor=Color3.fromRGB(220,30,30)
    highlight.OutlineTransparency=0; highlight.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent=workspace
    ESPLabels[crop] = {bill=bill, lblName=lblName, lblProg=lblProg, frame=frame, highlight=highlight}
end

local function RemoveESPLabel(crop)
    local entry = ESPLabels[crop]
    if entry then
        pcall(function() entry.bill:Destroy() end)
        pcall(function() entry.highlight:Destroy() end)
        ESPLabels[crop] = nil
    end
end

local function ClearAllESP()
    for crop in pairs(ESPLabels) do RemoveESPLabel(crop) end
end

local function UpdateESP()
    if not ActiveCrops then return end
    for _, crop in pairs(ActiveCrops:GetChildren()) do
        if crop and crop.Parent then
        local isOurs = OurCrops[crop.Name]~=nil or OurCropsBesar[crop.Name]~=nil
        if not Config.ESPShowAll and not isOurs then
            RemoveESPLabel(crop)
        else
        if not ESPLabels[crop] then pcall(CreateESPLabel, crop) end
        local entry = ESPLabels[crop]
        if entry then
        local progress, seedType, phase, isReady = 0, "?", 1, false
        pcall(function() progress,seedType,phase,isReady = GetCropProgress(crop) end)
        pcall(function()
            if entry.highlight and entry.highlight.Parent then
                entry.highlight.OutlineColor = isReady and Color3.fromRGB(255,215,0) or Color3.fromRGB(220,30,30)
                entry.highlight.OutlineTransparency = isOurs and 0 or 0.5
                entry.highlight.FillTransparency = isReady and 0.85 or 1
                if isReady then entry.highlight.FillColor = Color3.fromRGB(255,215,0) end
            end
        end)
        entry.lblName.Text = (seedType or "?"):gsub("Bibit ","")
        if isReady then
            entry.lblProg.Text="SIAP PANEN!"; entry.lblProg.TextColor3=Color3.fromRGB(255,215,0)
            entry.frame.BackgroundColor3=Color3.fromRGB(30,60,0)
        else
            entry.lblProg.Text=progress.."%"; entry.lblProg.TextColor3=ProgressColor(progress)
            entry.frame.BackgroundColor3=Color3.fromRGB(15,15,15)
        end
        entry.bill.Size = isOurs and UDim2.fromOffset(110,42) or UDim2.fromOffset(90,34)
        entry.lblName.TextColor3 = isOurs and Color3.fromRGB(255,255,255) or Color3.fromRGB(180,180,180)
        end
        end
        end
    end
    for crop in pairs(ESPLabels) do if not crop.Parent then RemoveESPLabel(crop) end end
end

-- ══════════════════════════════════════════════════════════
--  LOOPS
-- ══════════════════════════════════════════════════════════

-- Loop Plant Biasa
task.spawn(function()
    while true do
        task.wait(Config.CycleDelay)
        if CanRun() and not Config.IsFarmingBesar then
            if (Config.AutoPlant or Config.AutoFarm) and #PlotPositions > 0 then
                pcall(DoPlantAll)
            end
        end
    end
end)

-- Loop Harvest Biasa
task.spawn(function()
    while true do
        task.wait(3)
        if CanRun() and (Config.AutoHarvest or Config.AutoFarm) and not Config.IsFarmingBesar then
            for cropName, crop in pairs(OurCrops) do
                if not CanRun() then break end
                if not crop or not crop.Parent then
                    OurCrops[cropName]=nil
                else
                    if crop:GetAttribute("IsReady") then
                        pcall(DoHarvestSingle, crop); task.wait(Config.HarvestDelay)
                    end
                end
            end
        end
    end
end)

-- Loop Harvest Besar
task.spawn(function()
    while true do
        task.wait(5)
        if CanRun() and (Config.AutoHarvestBesar or Config.AutoFarmBesar or Config.AutoFarm) then
            local anyReady = false
            for cropName, crop in pairs(OurCropsBesar) do
                if not crop or not crop.Parent then
                    OurCropsBesar[cropName]=nil
                elseif crop:GetAttribute("IsReady") then
                    anyReady=true; break
                end
            end
            if anyReady then
                if Config.AutoFarm and Config.AutoFarmBesar then
                    if not FarmGabunganDebounce and not Config.IsFarmingBesar and Config.ClaimedAreaBesar then
                        FarmGabunganDebounce = true
                        task.spawn(function() pcall(DoFarmGabungan) FarmGabunganDebounce=false end)
                    end
                elseif (Config.AutoHarvestBesar or Config.AutoFarmBesar) and not Config.IsFarmingBesar then
                    for cropName, crop in pairs(OurCropsBesar) do
                        if not CanRun() then break end
                        if crop and crop.Parent then
                            if crop:GetAttribute("IsReady") then
                                pcall(DoHarvestSingle, crop); task.wait(Config.HarvestDelay)
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- Loop Plant Besar
local LastPlantBesarTime = 0
local PLANT_BESAR_COOLDOWN = 30

task.spawn(function()
    while true do
        task.wait(5)
        if CanRun()
            and (Config.AutoPlantBesar or Config.AutoFarmBesar)
            and #PlotPositionsBesar > 0
            and GetOurCropBesarCount() < MAX_BESAR
            and tick() - LastPlantBesarTime >= PLANT_BESAR_COOLDOWN
        then
            local ok, err = pcall(DoPlantAllBesar)
            if ok then
                if GetOurCropBesarCount() > 0 then LastPlantBesarTime = tick() end
            else
                PlantBesarLock=false; Config.IsFarmingBesar=false
                print("[Axorz Hub] DoPlantAllBesar error:", err)
            end
        end
    end
end)

-- Loop Auto Feed (hanya jika AutoFeed ON dan IsChickenBusy OFF)
task.spawn(function()
    while true do
        task.wait(10)
        if Config.AutoFeed and not Config.IsChickenBusy then
            pcall(DoFeedChicken)
        end
    end
end)

-- ──────────────────────────────────────────────────────────
--  [FIX 3] ACTIVE POLLING — cek egg tiap 5 detik
--  Backup jika watcher miss (telur sudah ada sebelum toggle ON)
-- ──────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(5)
        if not Config.AutoClaimEgg then continue end
        if Config.IsChickenBusy then continue end

        local coop = nil
        if Config.ChickenCoopName then
            coop = workspace:FindFirstChild(Config.ChickenCoopName)
            if not coop then
                local cf = workspace:FindFirstChild("CoopPlots")
                if cf then coop = cf:FindFirstChild(Config.ChickenCoopName) end
            end
        end
        if not coop then coop = FindMyCoopPlot() end
        if not coop then continue end

        -- Update nama kandang jika baru ditemukan
        if not Config.ChickenCoopName then
            Config.ChickenCoopName = coop.Name
            SetupEggWatcher(coop)
        end

        if HasEggInCoop(coop) then
            if not Config.EggReadyFlag then
                print("[Axorz Hub] Polling: deteksi telur baru!")
            end
            Config.EggReadyFlag = true

            if not Config.IsChickenBusy then
                if Config.AutoFeed and Config.AutoClaimEgg then
                    -- Auto Farm All mode
                    task.spawn(function() pcall(DoChickenRoutineForFarmAll) end)
                else
                    -- Hanya claim saja
                    task.spawn(function()
                        ClaimEggDebounce = false
                        pcall(DoClaimEgg)
                    end)
                end
            end
        else
            -- Tidak ada telur, reset flag
            if Config.EggReadyFlag then
                print("[Axorz Hub] Polling: telur sudah diklaim/tidak ada")
            end
            Config.EggReadyFlag = false
        end
    end
end)

-- Loop Sell Biasa
task.spawn(function()
    while true do
        task.wait(8)
        if CanRun() and (Config.AutoSell or Config.AutoFarm) then pcall(DoSell) end
    end
end)

-- Loop Sell Crop Besar
task.spawn(function()
    while true do
        task.wait(8)
        if CanRun() and (Config.AutoSellCrop or Config.AutoFarmBesar or Config.AutoFarm) then pcall(DoSellCrop) end
    end
end)

-- Loop Sell Egg
task.spawn(function()
    while true do
        task.wait(15)
        if Config.AutoSellEgg then pcall(DoSellEgg) end
    end
end)

-- Loop Buy
task.spawn(function()
    while true do
        task.wait(Config.BuyDelay)
        if Config.AutoBuy then pcall(DoBuy) end
    end
end)

-- Loop ESP
task.spawn(function()
    while true do
        task.wait(0.5)
        if Config.ESPEnabled then pcall(UpdateESP) end
    end
end)

-- ──────────────────────────────────────────────────────────
--  [FIX 1] LOOP FREEZE — jangan anchor saat GlobalPause=true
--  (chicken routine yang handle anchor sendiri)
-- ──────────────────────────────────────────────────────────
task.spawn(function()
    while true do
        task.wait(0.1)
        local hrp = GetHRP()
        local hum = GetHumanoid()
        if hrp and hum then
            if Config.Freeze then
                -- Freeze manual: anchor player
                hum.WalkSpeed = 0; hum.JumpHeight = 0; hrp.Anchored = true
            elseif Config.GlobalPause then
                -- [FIX 1] GlobalPause ON tapi bukan freeze manual:
                -- JANGAN anchor di sini! Biarkan chicken routine yang atur
                -- (do nothing)
            else
                -- Normal: unanchor dan restore speed
                hrp.Anchored = false
                hum.WalkSpeed = Config.WalkSpeed
                hum.JumpHeight = 7.2
            end
        end
    end
end)

-- ══════════════════════════════════════════════════════════
--  GUI
-- ══════════════════════════════════════════════════════════
local function BuildSeedDropdown()
    local seeds = GetSeedsInBackpack()
    local names = {}
    for _, s in ipairs(seeds) do table.insert(names, s.baseName) end
    if #names == 0 then
        names = {"Bibit Padi","Bibit Jagung","Bibit Tomat","Bibit Terong","Bibit Strawberry","Bibit Palm","Bibit Durian"}
    end
    return names
end

task.wait(1)
local SeedNames = BuildSeedDropdown()
Config.SelectedSeed = SeedNames[1]

-- ── Responsive Size ──
local ScreenGui   = Instance.new("ScreenGui")
ScreenGui.Parent  = game:GetService("RunService"):IsStudio()
    and game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    or game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local screenSize  = workspace.CurrentCamera.ViewportSize
local isPhone     = screenSize.X < 600 or screenSize.Y < 600

local guiWidth, guiHeight, tabWidth
if isPhone then
    -- HP: pakai 88% lebar layar, max 420px, tinggi 72% layar
    guiWidth  = math.min(math.floor(screenSize.X * 0.88), 420)
    guiHeight = math.min(math.floor(screenSize.Y * 0.72), 520)
    tabWidth  = math.floor(guiWidth * 0.28)
else
    -- PC / tablet: ukuran normal
    guiWidth  = 580
    guiHeight = 650
    tabWidth  = 160
end

local Window = Fluent:CreateWindow({
    Title       = "Axorz Hub",
    SubTitle    = "Sawah Indo | v2.1",
    TabWidth    = tabWidth,
    Size        = UDim2.fromOffset(guiWidth, guiHeight),
    Theme       = "Emerald",
    MinimizeKey = Enum.KeyCode.RightControl,
})

local Tabs = {
    Farm      = Window:AddTab({ Title="Auto Farm",           Icon="shovel"        }),
    FarmBesar = Window:AddTab({ Title="Auto Sawit & Durian", Icon="tree-pine"     }),
    Chicken   = Window:AddTab({ Title="Auto Chicken",        Icon="egg"           }),
    Sell      = Window:AddTab({ Title="Auto Sell",           Icon="tag"           }),
    Buy       = Window:AddTab({ Title="Auto Buy",            Icon="shopping-cart" }),
    Player    = Window:AddTab({ Title="Player",              Icon="user"          }),
    ESP       = Window:AddTab({ Title="ESP",                 Icon="eye"           }),
    AntiAFK   = Window:AddTab({ Title="Anti-AFK",            Icon="shield"        }),
    Settings  = Window:AddTab({ Title="Settings",            Icon="settings"      }),
}

local PlotLabel      = Tabs.Farm:AddParagraph({Title="Plot Tersimpan",  Content="0 plot"})
local CropLabel      = Tabs.Farm:AddParagraph({Title="Crop Milik Kita", Content="0 / 0 crop"})
local BesarInfoLabel = Tabs.FarmBesar:AddParagraph({Title="Stok Benih",    Content="Memuat..."})
local BesarCropLabel = Tabs.FarmBesar:AddParagraph({Title="Crop di Lahan", Content="Memuat..."})

local function SetParagraphContent(paragraph, title, content)
    local ok = pcall(function() paragraph:Set(title, content) end)
    if ok then return end
    pcall(function()
        local inst = rawget(paragraph,"Frame") or rawget(paragraph,"Instance") or rawget(paragraph,"Object")
        if not inst then
            for _, v in pairs(paragraph) do
                if typeof(v)=="Instance" and v:IsA("Frame") then inst=v; break end
            end
        end
        if not inst then return end
        local labels = {}
        for _, l in pairs(inst:GetDescendants()) do
            if l:IsA("TextLabel") then table.insert(labels, l) end
        end
        if #labels >= 2 then labels[2].Text=content
        elseif #labels == 1 then labels[1].Text=content end
    end)
end

local function UpdatePlotLabel()
    SetParagraphContent(PlotLabel, "Plot Tersimpan", #PlotPositions.." plot tersimpan")
end

local function UpdateCropLabel()
    SetParagraphContent(CropLabel, "Crop Milik Kita", GetOurCropCount().." / "..Config.MaxPlant.." crop")
end

local function UpdateBesarLabels()
    local seedInfo = GetBesarSeedInfo()
    SetParagraphContent(BesarInfoLabel, "Stok Benih",
        ("Sawit: %d  |  Durian: %d"):format(seedInfo.sawit, seedInfo.durian))
    local sawitCount, durianCount = 0, 0
    for _, crop in pairs(OurCropsBesar) do
        local st = (crop:GetAttribute("SeedType") or crop.Name or ""):lower()
        if st:find("sawit") or st:find("palm") then sawitCount=sawitCount+1 end
        if st:find("durian") then durianCount=durianCount+1 end
    end
    SetParagraphContent(BesarCropLabel, "Crop di Lahan",
        ("%d / 2  (Sawit: %d | Durian: %d)"):format(GetOurCropBesarCount(), sawitCount, durianCount))
end

task.spawn(function()
    while true do task.wait(0.5) UpdateCropLabel() UpdateBesarLabels() end
end)

local areaList = ScanAllAreaTanam()
local areaNames = {}
for _, entry in ipairs(areaList) do table.insert(areaNames, entry.name) end
if #areaNames == 0 then
    areaNames = {"AreaTanam","AreaTanam2","AreaTanam3","AreaTanam4","AreaTanam5","AreaTanam6","AreaTanam7"}
end
Config.SelectedArea = areaNames[1]
if AreaTanamData[areaNames[1]] then PlotPositions = {AreaTanamData[areaNames[1]].position} end
task.defer(UpdatePlotLabel)

local areaListBesar = ScanAllAreaTanamBesar()
local areaNamsBesar = {}
for _, entry in ipairs(areaListBesar) do table.insert(areaNamsBesar, entry.name) end
if #areaNamsBesar == 0 then
    for i = 1, 32 do table.insert(areaNamsBesar, "AreaTanamBesar"..i) end
end
Config.SelectedAreaBesar = areaNamsBesar[1]
if AreaTanamBesarData[areaNamsBesar[1]] then PlotPositionsBesar={AreaTanamBesarData[areaNamsBesar[1]].position} end

OurCrops={} OurCropsBesar={} TrackDebounce={} TrackDebounceBesar={}
if ActiveCrops then
    for _, crop in pairs(ActiveCrops:GetChildren()) do
        if IsOurCrop(crop) then
            local root = crop:FindFirstChild("Root") or crop:FindFirstChildWhichIsA("BasePart")
            if root and IsNearAreaBesar(root.Position) then RegisterCropBesar(crop) else RegisterCrop(crop) end
        end
    end
end

local function UpdateClaimLabel() end

task.delay(2, function()
    if not Config.ClaimedAreaBesar then
        local found = DetectLahanSaya()
        if found then pcall(UpdateClaimLabel) end
    end
end)

-- ══════════════════════════════════════════════════════════
--  TAB: FARM BIASA
-- ══════════════════════════════════════════════════════════
Tabs.Farm:AddDropdown("DropdownArea", {
    Title="Pilih Lahan (AreaTanam)", Values=areaNames, Default=areaNames[1],
    Callback=function(v)
        Config.SelectedArea=v; SavedCirclePositions={}
        if AreaTanamData[v] then
            PlotPositions={AreaTanamData[v].position}; UpdatePlotLabel()
            TeleportTo(CFrame.new(AreaTanamData[v].position+Vector3.new(0,4,0)))
            Fluent:Notify({Title="Axorz Hub", Content=v.." dipilih!", Duration=2})
        else
            PlotPositions={}; UpdatePlotLabel()
            Fluent:Notify({Title="Axorz Hub", Content=v.." tidak ditemukan.", Duration=3})
        end
    end,
})

Tabs.Farm:AddButton({Title="Teleport ke Lahan Dipilih", Callback=function()
    if Config.SelectedArea and AreaTanamData[Config.SelectedArea] then
        TeleportTo(CFrame.new(AreaTanamData[Config.SelectedArea].position+Vector3.new(0,4,0)))
        Fluent:Notify({Title="Axorz Hub", Content="Teleport ke "..Config.SelectedArea, Duration=2})
    else Fluent:Notify({Title="Axorz Hub", Content="Pilih lahan dulu!", Duration=3}) end
end})

Tabs.Farm:AddButton({Title="Clear Crop Data", Callback=function()
    OurCrops={}; PendingPlantPos={}; SavedCirclePositions={}; UpdateCropLabel()
    Fluent:Notify({Title="Axorz Hub", Content="Data crop dihapus.", Duration=2})
end})

local SeedDropdown = Tabs.Farm:AddDropdown("DropdownSeed", {
    Title="Pilih Benih", Values=SeedNames, Default=SeedNames[1],
    Callback=function(v) Config.SelectedSeed=v
        Fluent:Notify({Title="Axorz Hub", Content="Benih: "..v, Duration=2}) end,
})

Tabs.Farm:AddButton({Title="Refresh List Benih", Callback=function()
    local newNames = BuildSeedDropdown()
    if #newNames > 0 then
        pcall(function() SeedDropdown:SetValues(newNames) SeedDropdown:SetValue(newNames[1]) end)
        Config.SelectedSeed=newNames[1]
        Fluent:Notify({Title="Axorz Hub", Content="Benih diperbarui!", Duration=3})
    else Fluent:Notify({Title="Axorz Hub", Content="Tidak ada benih di backpack.", Duration=3}) end
end})

Tabs.Farm:AddParagraph({
    Title="Auto Farm All",
    Content="Aktifkan SEMUA 4 toggle berikut sekaligus:\n✅ Auto Farm (tab ini)\n✅ Auto Farm Besar (tab Sawit)\n✅ Auto Feed (tab Auto Chicken)\n✅ Auto Claim Telur (tab Auto Chicken)\n\nSaat semua ON → farm besar + chicken berjalan otomatis.\nSaat ada telur/feed → farm di-PAUSE dulu.",
})

Tabs.Farm:AddToggle("TogAutoFarm", {Title="Auto Farm (Harvest + Plant + Sell)", Default=false,
    Callback=function(v)
        Config.AutoFarm=v
        if v then Config.AutoHarvest=false; Config.AutoPlant=false; Config.AutoSell=false
            if Config.AutoFarmBesar and Config.AutoFeed and Config.AutoClaimEgg then
                Fluent:Notify({Title="Auto Farm All", Content="🌾 Auto Farm All aktif!", Duration=4})
            end
        end
    end})

Tabs.Farm:AddToggle("TogAutoHarvest", {Title="Auto Harvest", Default=false,
    Callback=function(v) Config.AutoHarvest=v; if v then Config.AutoFarm=false end end})

Tabs.Farm:AddToggle("TogAutoPlant", {Title="Auto Plant", Default=false,
    Callback=function(v) Config.AutoPlant=v; if v then Config.AutoFarm=false end end})

Tabs.Farm:AddSlider("SliderMaxPlant", {Title="Max Tanaman", Min=0, Max=25, Default=13, Rounding=0,
    Callback=function(v) Config.MaxPlant=v; SavedCirclePositions={} end})

Tabs.Farm:AddSlider("SliderCycle", {Title="Plant Cycle Delay (detik)", Min=0.3, Max=5.0, Default=0.3, Rounding=1,
    Callback=function(v) Config.CycleDelay=v end})

Tabs.Farm:AddToggle("TogCirclePlant", {Title="Circle Plant Mode", Default=false,
    Callback=function(v) Config.UseCircle=v end})

Tabs.Farm:AddSlider("SliderCircleRadius", {Title="Radius Lingkaran (studs)", Min=2, Max=20, Default=5, Rounding=0,
    Callback=function(v) Config.CircleRadius=v; SavedCirclePositions={} end})

-- ══════════════════════════════════════════════════════════
--  TAB: FARM BESAR
-- ══════════════════════════════════════════════════════════
Tabs.FarmBesar:AddParagraph({Title="Info Farm Besar", Content="Max tanam: 2 crop (1 Sawit + 1 Durian)"})

local ClaimStatusLabel = Tabs.FarmBesar:AddParagraph({Title="Status Lahan", Content="Belum di-claim"})

UpdateClaimLabel = function()
    local text = Config.ClaimedAreaBesar
        and ("Lahan: %s ✓"):format(Config.ClaimedAreaBesar) or "Belum di-claim"
    SetParagraphContent(ClaimStatusLabel, "Status Lahan", text)
end

task.spawn(function() while true do task.wait(1) pcall(UpdateClaimLabel) end end)

Tabs.FarmBesar:AddButton({Title="Claim Lahan Kosong (Auto Cari)", Callback=function()
    task.spawn(function() pcall(DoClaimLahan); pcall(UpdateClaimLabel) end)
end})

Tabs.FarmBesar:AddButton({Title="Detect Lahan Saya", Callback=function()
    task.spawn(function()
        local found = DetectLahanSaya(); pcall(UpdateClaimLabel)
        if found then Fluent:Notify({Title="Axorz Hub", Content=("✅ %s terdeteksi!"):format(found), Duration=5})
        else Fluent:Notify({Title="Axorz Hub", Content="❌ Berdiri di atas lahan kamu!", Duration=6}) end
    end)
end})

Tabs.FarmBesar:AddButton({Title="Teleport ke Lahan Besar", Callback=function()
    if Config.ClaimedAreaBesar and AreaTanamBesarData[Config.ClaimedAreaBesar] then
        TeleportTo(CFrame.new(AreaTanamBesarData[Config.ClaimedAreaBesar].position+Vector3.new(0,4,0)))
    else Fluent:Notify({Title="Axorz Hub", Content="Claim lahan dulu!", Duration=3}) end
end})

Tabs.FarmBesar:AddButton({Title="Clear Crop Besar Data", Callback=function()
    OurCropsBesar={}; pcall(UpdateBesarLabels)
    Fluent:Notify({Title="Axorz Hub", Content="Data crop besar dihapus.", Duration=2})
end})

Tabs.FarmBesar:AddToggle("TogAutoFarmBesar", {Title="Auto Farm Besar (Harvest + Plant)", Default=false,
    Callback=function(v)
        Config.AutoFarmBesar=v
        if v then Config.AutoHarvestBesar=false; Config.AutoPlantBesar=false
            if Config.AutoFarm and Config.AutoFeed and Config.AutoClaimEgg then
                Fluent:Notify({Title="Auto Farm All", Content="🌾 Auto Farm All aktif!", Duration=4})
            end
        end
    end})

Tabs.FarmBesar:AddToggle("TogAutoHarvestBesar", {Title="Auto Harvest Besar", Default=false,
    Callback=function(v) Config.AutoHarvestBesar=v; if v then Config.AutoFarmBesar=false end end})

Tabs.FarmBesar:AddToggle("TogAutoPlantBesar", {Title="Auto Plant Besar", Default=false,
    Callback=function(v) Config.AutoPlantBesar=v; if v then Config.AutoFarmBesar=false end end})

-- ══════════════════════════════════════════════════════════
--  TAB: CHICKEN
-- ══════════════════════════════════════════════════════════
Tabs.Chicken:AddParagraph({
    Title="Info Sistem Ayam v2.1",
    Content="[FIX] Deteksi telur via polling aktif tiap 5 detik.\nPlayer tidak lagi ter-freeze saat chicken routine berjalan.\nSaat Auto Feed + Auto Claim ON → saat ada telur,\nfarm di-PAUSE, claim+feed, baru resume.\nGunakan kedua toggle bersamaan untuk Auto Farm All.",
})

local ChickenStatusLabel = Tabs.Chicken:AddParagraph({Title="Status Kandang", Content="Mendeteksi..."})

local function UpdateChickenStatusLabel()
    local text
    if Config.IsChickenBusy then
        text = "🔄 Sedang urus kandang (farm di-pause)..."
    else
        text = Config.ChickenCoopName
            and ("Kandang: %s ✓"):format(Config.ChickenCoopName)
            or "Kandang belum terdeteksi"
    end
    SetParagraphContent(ChickenStatusLabel, "Status Kandang", text)
end

task.spawn(function() while true do task.wait(1) pcall(UpdateChickenStatusLabel) end end)

Tabs.Chicken:AddButton({Title="Detect Kandang Saya", Callback=function()
    task.spawn(function()
        local coop = FindMyCoopPlot()
        if coop then
            Config.ChickenCoopName=coop.Name; SetupEggWatcher(coop); pcall(UpdateChickenStatusLabel)
            Fluent:Notify({Title="Chicken", Content=("✅ %s"):format(coop.Name), Duration=3})
        else
            Fluent:Notify({Title="Chicken", Content="❌ Kandang tidak ditemukan!", Duration=4})
        end
    end)
end})

Tabs.Chicken:AddButton({Title="Teleport ke Kandang", Callback=function()
    local coop = Config.ChickenCoopName and workspace:FindFirstChild(Config.ChickenCoopName)
    if not coop then coop=FindMyCoopPlot() end
    if coop then
        local bp = coop:FindFirstChildWhichIsA("BasePart")
        if bp then TeleportTo(CFrame.new(bp.Position+Vector3.new(0,5,0))) end
        Fluent:Notify({Title="Chicken", Content="Teleport ke kandang!", Duration=2})
    else Fluent:Notify({Title="Chicken", Content="Kandang tidak ditemukan!", Duration=3}) end
end})

Tabs.Chicken:AddButton({Title="Feed Sekarang (Manual)", Callback=function()
    task.spawn(function() FeedDebounce=false; pcall(DoFeedChicken) end)
end})

Tabs.Chicken:AddToggle("TogAutoFeed", {Title="Auto Feed Ayam", Default=false,
    Callback=function(v)
        Config.AutoFeed=v
        if v then
            local coop = Config.ChickenCoopName and workspace:FindFirstChild(Config.ChickenCoopName)
            if not coop then coop=FindMyCoopPlot() end
            if coop then Config.ChickenCoopName=coop.Name; SetupEggWatcher(coop) end
            task.spawn(function() FeedDebounce=false; pcall(DoFeedChicken) end)
            Fluent:Notify({Title="Chicken", Content="🐔 Auto Feed ON!", Duration=2})
            if Config.AutoFarm and Config.AutoFarmBesar and Config.AutoClaimEgg then
                Fluent:Notify({Title="Auto Farm All", Content="🌾 Auto Farm All aktif!", Duration=4})
            end
        end
    end})

Tabs.Chicken:AddSlider("SliderFeedDelay", {Title="Feed Delay antar Slot (detik)", Min=0.1, Max=2.0, Default=0.3, Rounding=1,
    Callback=function(v) Config.FeedDelay=v end})

Tabs.Chicken:AddButton({Title="Claim Telur Sekarang (Manual)", Callback=function()
    task.spawn(function() ClaimEggDebounce=false; pcall(DoClaimEgg) end)
end})

Tabs.Chicken:AddToggle("TogAutoClaimEgg", {Title="Auto Claim Telur", Default=false,
    Callback=function(v)
        Config.AutoClaimEgg=v
        if v then
            local coop = Config.ChickenCoopName and workspace:FindFirstChild(Config.ChickenCoopName)
            if not coop then coop=FindMyCoopPlot() end
            if coop then Config.ChickenCoopName=coop.Name; SetupEggWatcher(coop) end
            -- Langsung cek telur yang sudah ada
            task.spawn(function()
                task.wait(0.5)
                ClaimEggDebounce=false
                -- Re-setup watcher agar cek telur yang sudah ada
                if coop then SetupEggWatcher(coop) end
            end)
            Fluent:Notify({Title="Chicken", Content="🥚 Auto Claim ON!", Duration=2})
            if Config.AutoFarm and Config.AutoFarmBesar and Config.AutoFeed then
                Fluent:Notify({Title="Auto Farm All", Content="🌾 Auto Farm All aktif!", Duration=4})
                if not Config.ClaimedAreaBesar then
                    task.spawn(function() pcall(DetectLahanSaya) end)
                end
            end
        else
            if EggWatcherConn then pcall(function() EggWatcherConn:Disconnect() end); EggWatcherConn=nil end
        end
    end})

Tabs.Chicken:AddSlider("SliderClaimDelay", {Title="Claim Delay antar Telur (detik)", Min=0.1, Max=2.0, Default=0.3, Rounding=1,
    Callback=function(v) Config.ClaimDelay=v end})

Tabs.Chicken:AddParagraph({
    Title="Tips v2.1",
    Content="• [FIX] Polling aktif tiap 5 detik — telur tidak akan terlewat\n• [FIX] Player tidak freeze saat routine chicken berjalan\n• Aktifkan Auto Feed + Auto Claim bersamaan untuk koordinasi optimal\n• Saat keduanya ON → ada telur = farm di-pause, urus kandang dulu\n• Detect kandang dulu sebelum aktifkan toggle",
})

-- ══════════════════════════════════════════════════════════
--  TAB: SELL
-- ══════════════════════════════════════════════════════════
Tabs.Sell:AddParagraph({Title="Sell Tanaman Biasa", Content="Jual hasil panen padi, jagung, tomat, dll."})
Tabs.Sell:AddButton({Title="Jual Sekarang (Tanaman Biasa)", Callback=function() task.spawn(function() pcall(DoSell) end) end})
Tabs.Sell:AddToggle("TogAutoSell", {Title="Auto Sell Tanaman Biasa", Default=false,
    Callback=function(v) Config.AutoSell=v; if v then Config.AutoFarm=false end end})

Tabs.Sell:AddParagraph({Title="Sell Sawit & Durian", Content="Jual hasil panen sawit dan durian."})
Tabs.Sell:AddButton({Title="Jual Sekarang (Sawit/Durian)", Callback=function() task.spawn(function() pcall(DoSellCrop) end) end})
Tabs.Sell:AddToggle("TogAutoSellCrop", {Title="Auto Sell Sawit/Durian", Default=false,
    Callback=function(v) Config.AutoSellCrop=v end})

Tabs.Sell:AddParagraph({Title="Sell Telur Ayam", Content="Jual semua telur (SELL_ALL_EGG)."})
Tabs.Sell:AddButton({Title="Jual Telur Sekarang", Callback=function() task.spawn(function() pcall(DoSellEgg) end) end})
Tabs.Sell:AddToggle("TogAutoSellEgg", {Title="Auto Sell Telur Ayam", Default=false,
    Callback=function(v) Config.AutoSellEgg=v
        if v then task.spawn(function() pcall(DoSellEgg) end) end
    end})

-- ══════════════════════════════════════════════════════════
--  TAB: BUY
-- ══════════════════════════════════════════════════════════
Tabs.Buy:AddParagraph({Title="Auto Buy", Content="Beli benih dari shop otomatis."})
local shopNames = {"Bibit Padi","Bibit Jagung","Bibit Tomat","Bibit Terong","Bibit Strawberry","Bibit Sawit","Bibit Durian"}
Config.SelectedBuy = shopNames[1]
task.spawn(function()
    local result = FetchShopList()
    if type(result)=="table" then
        local newShop = {}
        for _, item in pairs(result) do if type(item)=="table" and item.Name then table.insert(newShop, item.Name) end end
        if #newShop > 0 then shopNames=newShop; Config.SelectedBuy=shopNames[1] end
    end
end)
Tabs.Buy:AddDropdown("DropdownBuy", {Title="Pilih Benih", Values=shopNames, Default=shopNames[1],
    Callback=function(v) Config.SelectedBuy=v end})
Tabs.Buy:AddSlider("SliderBuyAmount", {Title="Jumlah per Cycle", Min=1, Max=100, Default=10, Rounding=0,
    Callback=function(v) Config.BuyAmount=v end})
Tabs.Buy:AddSlider("SliderBuyDelay", {Title="Buy Interval (detik)", Min=5, Max=60, Default=10, Rounding=0,
    Callback=function(v) Config.BuyDelay=v end})
Tabs.Buy:AddToggle("TogAutoBuy", {Title="Auto Buy", Default=false, Callback=function(v) Config.AutoBuy=v end})
Tabs.Buy:AddButton({Title="Beli Sekarang", Callback=function()
    if not Config.SelectedBuy then return end
    task.spawn(pcall, DoBuy)
    Fluent:Notify({Title="Axorz Hub", Content=Config.SelectedBuy.." x"..Config.BuyAmount, Duration=2})
end})

-- ══════════════════════════════════════════════════════════
--  TAB: PLAYER
-- ══════════════════════════════════════════════════════════
local UserInputService = game:GetService("UserInputService")

task.spawn(function() while true do task.wait(0.1)
    local hum=GetHumanoid()
    if hum and not Config.Freeze and not Config.GlobalPause then hum.WalkSpeed=Config.WalkSpeed end
end end)

UserInputService.JumpRequest:Connect(function()
    if Config.InfiniteJump then
        local hum=GetHumanoid()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

Tabs.Player:AddSlider("SliderSpeed", {Title="Walk Speed", Min=0, Max=100, Default=16, Rounding=0,
    Callback=function(v) Config.WalkSpeed=v end})
Tabs.Player:AddButton({Title="Reset Speed", Callback=function()
    Config.WalkSpeed=16; local hum=GetHumanoid(); if hum then hum.WalkSpeed=16 end end})
Tabs.Player:AddToggle("TogInfiniteJump", {Title="Infinite Jump", Default=false,
    Callback=function(v) Config.InfiniteJump=v end})
Tabs.Player:AddToggle("TogFreeze", {Title="Freeze", Default=false,
    Callback=function(v) Config.Freeze=v
        if not v then
            local hrp=GetHRP(); local hum=GetHumanoid()
            if hrp then hrp.Anchored=false end
            if hum then hum.WalkSpeed=Config.WalkSpeed; hum.JumpHeight=7.2 end
        end end})

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    local hum=char:FindFirstChildOfClass("Humanoid")
    local hrp=char:FindFirstChild("HumanoidRootPart")
    if hum then hum.WalkSpeed=Config.Freeze and 0 or Config.WalkSpeed; hum.JumpHeight=Config.Freeze and 0 or 7.2 end
    if hrp then hrp.Anchored=Config.Freeze end
end)

-- ══════════════════════════════════════════════════════════
--  TAB: ESP
-- ══════════════════════════════════════════════════════════
Tabs.ESP:AddParagraph({Title="Crop ESP", Content="Tampilkan progress tanaman."})
Tabs.ESP:AddToggle("TogESP", {Title="Enable ESP", Default=false,
    Callback=function(v) Config.ESPEnabled=v; if not v then ClearAllESP() end end})
Tabs.ESP:AddToggle("TogESPAll", {Title="Tampilkan Semua Player", Default=false,
    Callback=function(v) Config.ESPShowAll=v end})
Tabs.ESP:AddButton({Title="Refresh ESP", Callback=function() ClearAllESP() end})

-- ══════════════════════════════════════════════════════════
--  TAB: ANTI-AFK
-- ══════════════════════════════════════════════════════════
Tabs.AntiAFK:AddParagraph({Title="Anti-AFK", Content="Mencegah kick otomatis Roblox."})
local AFKStatusLabel = Tabs.AntiAFK:AddParagraph({
    Title="Status", Content="Aktif ✓ | Klik tiap "..Config.AntiAFKDelay.." menit"})
local function UpdateAFKLabel()
    local status = Config.AntiAFK
        and ("Aktif ✓ | Klik tiap %d menit"):format(Config.AntiAFKDelay) or "Nonaktif ✗"
    pcall(function() AFKStatusLabel:Set("Status", status) end)
end
Tabs.AntiAFK:AddToggle("TogAntiAFK", {Title="Enable Anti-AFK", Default=true,
    Callback=function(v) Config.AntiAFK=v
        if v then StartAntiAFK()
        else if AntiAFKThread then task.cancel(AntiAFKThread); AntiAFKThread=nil end end
        UpdateAFKLabel() end})
Tabs.AntiAFK:AddSlider("SliderAFKDelay", {Title="Klik pada Menit ke-", Min=10, Max=19, Default=18, Rounding=0,
    Callback=function(v) Config.AntiAFKDelay=v; if Config.AntiAFK then StartAntiAFK() end; UpdateAFKLabel() end})
Tabs.AntiAFK:AddButton({Title="Test Klik", Callback=function()
    VirtualUser:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
    task.wait(1); VirtualUser:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
    Fluent:Notify({Title="Axorz Hub", Content="Test klik berhasil!", Duration=2}) end})

-- ══════════════════════════════════════════════════════════
--  SETTINGS
-- ══════════════════════════════════════════════════════════
InterfaceManager:SetLibrary(Fluent)
SaveManager:SetLibrary(Fluent)
InterfaceManager:BuildInterfaceSection(Tabs.Settings)
SaveManager:BuildConfigSection(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
Window:SelectTab(1)

Fluent:Notify({
    Title   = "Axorz Hub v2.1",
    Content = "✅ Fix: polling egg aktif + anchor conflict resolved!\nAktifkan 4 toggle untuk Auto Farm All.",
    Duration = 5,
})
