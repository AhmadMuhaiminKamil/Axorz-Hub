-- ============================================================
--  AXORZ HUB | v3.0 — CUSTOM GUI + ALL v2.2 FIXES
--  PERUBAHAN dari v2.1:
--  [FIX 1] Loop freeze tidak lagi anchor player saat GlobalPause=true
--  [FIX 2] EggWatcher cek telur yang SUDAH ADA di kandang
--  [FIX 3] Active polling tiap 5 detik untuk cek egg ready
--  [FIX 4] DoChickenRoutineForFarmAll un-anchor sebelum teleport
--  [FIX 5] ReleaseChickenLock selalu un-anchor di akhir
--  [FIX 6] FLOATING BUTTON fixed
--  [FIX 7] DoClaimEgg: un-anchor sebelum tiap teleport ke telur,
--          tunggu server acknowledge posisi (0.6s), re-anchor sesudah,
--          un-anchor lagi sebelum pindah ke telur berikutnya
--  [FIX 8] DoFeedChicken: sama — un-anchor tiap iterasi slot,
--          tunggu lebih lama setelah teleport (0.6s),
--          fireproximityprompt dipanggil SETELAH posisi stabil
--  [FIX 9] DoChickenRoutineForFarmAll: pastikan un-anchor total
--          sebelum panggil DoClaimEgg & DoFeedChicken, dan
--          tunggu keduanya selesai penuh sebelum release lock
-- ============================================================


local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser       = game:GetService("VirtualUser")
local LocalPlayer       = Players.LocalPlayer

-- ──────────────────────────────────────────────────────────
--  NOTIFY — forward declaration
--  Fungsi ini dipakai oleh engine (DoClaimEgg, DoFeedChicken, dll)
--  SEBELUM GUI dibuat. Implementasi penuh di bagian GUI nanti.
--  Selama GUI belum siap, notif masuk ke queue dan diproses
--  begitu GUI sudah terbentuk.
-- ──────────────────────────────────────────────────────────
local NotifyQueue  = {}
local NotifyActive = false
local NotifyImpl   = nil  -- diisi saat GUI sudah siap

local function Notify(title, content)
    table.insert(NotifyQueue, {title=tostring(title or ""), content=tostring(content or "")})
    if NotifyImpl then NotifyImpl() end
end

-- SetupEggWatcher forward declaration
-- Implementasi penuh ada di bawah setelah EggWatcherConns didefinisikan
-- DoClaimCoop memanggilnya via task.spawn, tapi Lua resolve nama saat parse
-- sehingga perlu forward declaration ini
local SetupEggWatcher  -- akan diisi implementasinya nanti

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
    -- GLOBAL PAUSE
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
local PlantBesarLock       = false
local ChickenBusyLock      = false
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

local LastPlantBesarTime = 0

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
    if sold > 0 then Notify("Auto Sell", ("✅ %d item terjual!"):format(sold)) end
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
    if sold > 0 then Notify("Auto Sell Crop", ("🌴 %d buah terjual!"):format(sold)) end
end

local function DoSellEgg()
    local ok, result = pcall(function() return RemoteSell:InvokeServer("SELL_ALL_EGG") end)
    if ok and type(result) == "table" then
        if result.Success then
            Notify("Auto Sell Egg", ("🥚 %s"):format(result.Message or "Telur terjual!"))
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

        Notify("Farm Gabungan", "🌴 Menuju lahan besar...")
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
            Notify("Farm Gabungan", ("✅ %d crop besar dipanen!"):format(harvested))
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
            Notify("Farm Gabungan", ("🌱 %d benih ditanam ulang!"):format(planted))
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
    local myId = tostring(LocalPlayer.UserId)
    local myName = LocalPlayer.Name:lower()

    local function checkObj(obj)
        local attrs = {
            obj:GetAttribute("OwnerUserId"),
            obj:GetAttribute("OwnerId"),
            obj:GetAttribute("OwnerUserID"),
            obj:GetAttribute("Owner"),
            obj:GetAttribute("PlayerId"),
        }
        for _, v in ipairs(attrs) do
            if v ~= nil and tostring(v) == myId then return true end
        end
        local n = obj.Name:lower()
        if n:find(myName) or n:find(myId) then return true end
        return false
    end

    -- Scan workspace langsung (kandang yang sudah di-claim: Coop_CoopPlot_X_username)
    for _, obj in pairs(workspace:GetChildren()) do
        if obj.Name:lower():find("coop") then
            if checkObj(obj) then return obj end
        end
    end

    -- Scan folder CoopPlots
    local coopFolder = workspace:FindFirstChild("CoopPlots")
    if coopFolder then
        for _, obj in pairs(coopFolder:GetChildren()) do
            if checkObj(obj) then return obj end
        end
    end

    -- Scan semua children workspace
    for _, obj in pairs(workspace:GetChildren()) do
        local n = obj.Name:lower()
        if (n:find("coop") or n:find("plot")) and checkObj(obj) then
            return obj
        end
    end

    return nil
end

-- ──────────────────────────────────────────────────────────
--  CLAIM COOP (kandang ayam kosong)
--  Dari spy:
--  - CoopPlots folder berisi CoopPlot_1, CoopPlot_2, dst. (Part)
--  - Prompt kosong: ActionText='Claim Coop', Enabled=true
--  - Prompt sudah dipakai: Enabled=false
-- ──────────────────────────────────────────────────────────
local function DoClaimCoop()
    -- Cek dulu apakah sudah punya kandang
    local existing = FindMyCoopPlot()
    if existing then
        Notify("Auto Chicken", "✅ Kandang sudah ada: "..existing.Name)
        Config.ChickenCoopName = existing.Name
        SetupEggWatcher(existing)
        return true, existing.Name
    end

    local coopFolder = workspace:FindFirstChild("CoopPlots")
    if not coopFolder then
        Notify("Auto Chicken", "❌ Folder CoopPlots tidak ditemukan!")
        return false, nil
    end

    -- Cari CoopPlot yang kosong (prompt Claim Coop Enabled=true)
    local emptyPlots = {}
    for _, plot in pairs(coopFolder:GetChildren()) do
        if plot:IsA("BasePart") or plot:IsA("Part") then
            for _, desc in pairs(plot:GetDescendants()) do
                if desc:IsA("ProximityPrompt") then
                    local action = desc.ActionText:lower()
                    if action:find("claim") and desc.Enabled then
                        table.insert(emptyPlots, {plot=plot, prompt=desc})
                        break
                    end
                end
            end
            -- Cek prompt langsung di plot
            local directPrompt = plot:FindFirstChildOfClass("ProximityPrompt")
            if directPrompt and directPrompt.ActionText:lower():find("claim") and directPrompt.Enabled then
                -- Cek belum ada di list
                local found = false
                for _, ep in pairs(emptyPlots) do
                    if ep.plot == plot then found=true; break end
                end
                if not found then
                    table.insert(emptyPlots, {plot=plot, prompt=directPrompt})
                end
            end
        end
    end

    if #emptyPlots == 0 then
        Notify("Auto Chicken", "❌ Tidak ada kandang kosong tersedia!")
        return false, nil
    end

    print(("[Axorz Hub] DoClaimCoop: %d kandang kosong ditemukan"):format(#emptyPlots))

    -- Ambil yang pertama tersedia
    local target = emptyPlots[1]
    local plotPos = target.plot.Position

    -- Teleport ke plot
    local hrp = GetHRP()
    if hrp then hrp.Anchored = false end
    task.wait(0.05)

    TeleportTo(CFrame.new(plotPos + Vector3.new(0, 4, 0)))
    task.wait(1.0) -- tunggu server acknowledge posisi

    -- Verifikasi jarak
    hrp = GetHRP()
    local dist = hrp and (hrp.Position - plotPos).Magnitude or 99
    print(("[Axorz Hub] DoClaimCoop: jarak ke plot = %.1f"):format(dist))

    if dist > 12 then
        -- Retry teleport
        TeleportTo(CFrame.new(plotPos + Vector3.new(0, 4, 0)))
        task.wait(1.2)
        hrp = GetHRP()
        dist = hrp and (hrp.Position - plotPos).Magnitude or 99
    end

    if dist > 12 then
        Notify("Auto Chicken", "❌ Gagal teleport ke kandang kosong!")
        return false, nil
    end

    -- Fire prompt claim
    pcall(function() fireproximityprompt(target.prompt) end)
    task.wait(1.5)

    -- Cek apakah sudah berhasil claim (kandang baru muncul di workspace)
    local newCoop = FindMyCoopPlot()
    if newCoop then
        Config.ChickenCoopName = newCoop.Name
        task.spawn(function()
            task.wait(0.5)
            SetupEggWatcher(newCoop)
        end)
        Notify("Auto Chicken", "✅ Kandang berhasil di-claim!\n"..newCoop.Name)
        print("[Axorz Hub] DoClaimCoop: berhasil! "..newCoop.Name)
        return true, newCoop.Name
    else
        -- Coba sekali lagi
        pcall(function() fireproximityprompt(target.prompt) end)
        task.wait(1.5)
        newCoop = FindMyCoopPlot()
        if newCoop then
            Config.ChickenCoopName = newCoop.Name
            task.spawn(function()
                task.wait(0.5)
                SetupEggWatcher(newCoop)
            end)
            Notify("Auto Chicken", "✅ Kandang berhasil di-claim!\n"..newCoop.Name)
            return true, newCoop.Name
        end
        Notify("Auto Chicken", "❌ Claim gagal. Coba dekati kandang dulu!")
        return false, nil
    end
end

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

local function HasEggInCoop(coop)
    if not coop then return false end
    for _, obj in pairs(coop:GetChildren()) do
        if obj.Name:lower():find("egg") then
            for _, desc in pairs(obj:GetDescendants()) do
                if desc:IsA("ProximityPrompt") and desc.Enabled then
                    return true
                end
            end
            -- Juga cek BasePart langsung
            if obj:IsA("BasePart") then
                local p = obj:FindFirstChildOfClass("ProximityPrompt")
                if p and p.Enabled then return true end
            end
        end
    end
    return false
end

-- ──────────────────────────────────────────────────────────
--  [FIX 7 & 8] HELPER: teleport ke posisi, tunggu server
--  acknowledge posisi baru, baru anchor.
--  Dipanggil oleh DoFeedChicken DAN DoClaimEgg.
--  Harus didefinisikan SEBELUM keduanya.
-- ──────────────────────────────────────────────────────────
local function TeleportToAndAnchor(targetPos)
    local hrp = GetHRP()
    if not hrp then return false end
    -- Un-anchor dulu agar CFrame bisa di-set
    hrp.Anchored = false
    task.wait(0.05)
    hrp = GetHRP()
    if not hrp then return false end
    hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 3, 0))
    -- Tunggu server acknowledge posisi baru sebelum fire prompt
    task.wait(0.6)
    hrp = GetHRP()
    if not hrp then return false end
    hrp.Anchored = true
    task.wait(0.1)
    return true
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
        if not coop then
            print("[Axorz Hub] DoFeedChicken: kandang tidak ditemukan")
            return
        end
        Config.ChickenCoopName = coop.Name

        if Config.FeedSeedName then
            pcall(function() EquipSeed(Config.FeedSeedName) end)
            task.wait(0.3)
        end

        -- Kumpulkan slot feed yang SIAP (Enabled=true)
        -- Dari spy: ActionText="Feed", Parent="SlotMarkers"
        -- SlotMarkers bukan BasePart, perlu cari BasePart parent dari SlotMarkers
        local feedSlots = {}
        for _, desc in pairs(coop:GetDescendants()) do
            if desc:IsA("ProximityPrompt") and desc.Enabled then
                local action = desc.ActionText:lower()
                local object = desc.ObjectText:lower()
                -- Exclude Upgrade prompt
                local isUpgrade = action:find("upgrade") or object:find("upgrade") or object:find("price")
                -- ActionText di game ini = "Feed" (dari spy result)
                local isFeed = action:find("feed") or action:find("eat")
                    or action:find("makan") or action:find("beri")
                    or action:find("hungry") or action:find("lapar")
                if isFeed and not isUpgrade then
                    -- Cari BasePart terdekat — naik dari parent ke parent
                    local targetPos = nil
                    local targetPart = nil
                    local p = desc.Parent
                    while p and p ~= coop do
                        if p:IsA("BasePart") then
                            targetPos  = p.Position
                            targetPart = p
                            break
                        end
                        p = p.Parent
                    end
                    -- Kalau tidak ada BasePart di atas, cari di bawah (GetDescendants)
                    if not targetPos then
                        for _, sibling in pairs(coop:GetDescendants()) do
                            if sibling:IsA("BasePart") and sibling ~= coop then
                                -- Ambil yang paling dekat dengan prompt parent
                                targetPos  = sibling.Position
                                targetPart = sibling
                                break
                            end
                        end
                    end
                    if targetPos then
                        table.insert(feedSlots, {
                            prompt = desc,
                            pos    = targetPos,
                            part   = targetPart,
                            name   = desc.Parent.Name
                        })
                    end
                end
            end
        end

        print(("[Axorz Hub] Feed: %d slot siap diberi makan"):format(#feedSlots))

        if #feedSlots == 0 then
            print("[Axorz Hub] AutoFeed: semua ayam sudah kenyang / belum lapar")
            return
        end

        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        local fedCount  = 0

        -- Un-anchor sebelum mulai
        local hrp = GetHRP()
        if hrp then hrp.Anchored = false end
        task.wait(0.05)

        for i, slot in ipairs(feedSlots) do
            -- Cek ulang prompt masih enabled (ayam belum diberi makan orang lain)
            if not slot.prompt or not slot.prompt.Enabled then
                print(("[Axorz Hub] Feed: slot %s sudah tidak enabled, skip"):format(slot.name))
                continue
            end

            -- Un-anchor sebelum tiap teleport
            hrp = GetHRP()
            if hrp then hrp.Anchored = false end
            task.wait(0.05)

            -- Teleport ke slot
            local ok2 = TeleportToAndAnchor(slot.pos)
            if not ok2 then
                print(("[Axorz Hub] Feed: gagal teleport ke slot %s"):format(slot.name))
                continue
            end

            -- Verifikasi jarak
            hrp = GetHRP()
            local dist = hrp and (hrp.Position - slot.pos).Magnitude or 99
            print(("[Axorz Hub] Feed: [%d/%d] %s jarak=%.1f"):format(i, #feedSlots, slot.name, dist))

            if dist > 10 then
                -- Retry sekali
                hrp = GetHRP()
                if hrp then hrp.Anchored = false end
                task.wait(0.05)
                TeleportToAndAnchor(slot.pos)
                hrp = GetHRP()
                dist = hrp and (hrp.Position - slot.pos).Magnitude or 99
            end

            if dist <= 10 then
                -- Fire prompt — coba holdproximityprompt dulu (lebih reliable),
                -- fallback ke fireproximityprompt
                local fired = false
                pcall(function()
                    holdproximityprompt(slot.prompt)
                    task.wait(0.1)
                    releaseproximityprompt(slot.prompt)
                    fired = true
                end)
                if not fired then
                    pcall(function() fireproximityprompt(slot.prompt) end)
                end

                -- Dari spy: feed langsung berhasil TANPA ConfirmGui
                -- SlotMarkers -> Eating... Enabled=false = sukses
                -- Tunggu sebentar lalu cek apakah prompt sudah disabled (tanda berhasil)
                task.wait(0.5)
                local success = false
                if not slot.prompt.Enabled then
                    -- Prompt disabled = feed berhasil
                    success = true
                    print(("[Axorz Hub] Feed: slot %s berhasil (prompt disabled)"):format(slot.name))
                else
                    -- Coba cek ConfirmGui sebagai fallback
                    local confirmGui = playerGui and playerGui:FindFirstChild("ConfirmGui")
                    if confirmGui and confirmGui.Enabled then
                        if ClickConfirmYes() then
                            task.wait(0.3)
                            success = true
                            print(("[Axorz Hub] Feed: slot %s berhasil via confirm"):format(slot.name))
                        end
                    end
                end

                if success then
                    fedCount = fedCount + 1
                else
                    print(("[Axorz Hub] Feed: slot %s tidak berhasil"):format(slot.name))
                end
            else
                print(("[Axorz Hub] Feed: jarak terlalu jauh %.1f, skip %s"):format(dist, slot.name))
            end

            task.wait(math.max(Config.FeedDelay, 0.3))
        end

        -- Un-anchor setelah selesai
        hrp = GetHRP()
        if hrp then hrp.Anchored = false end

        if fedCount > 0 then
            print(("[Axorz Hub] AutoFeed: %d / %d slot diberi makan!"):format(fedCount, #feedSlots))
            Notify("Auto Feed", ("🐔 %d slot diberi makan!"):format(fedCount))
        else
            print("[Axorz Hub] AutoFeed: tidak ada slot yang berhasil diberi makan")
        end
    end)
    if not ok then print("[Axorz Hub] DoFeedChicken error:", err) end
    local hrpFinal = GetHRP()
    if hrpFinal then hrpFinal.Anchored = false end
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

        -- [FIX 7] Pastikan awalnya un-anchor
        local hrp = GetHRP()
        if not hrp then return end
        hrp.Anchored = false
        task.wait(0.05)

        -- Kumpulkan semua egg + prompt lebih dulu, baru proses
        local eggList = {}
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

                if prompt and eggPos then
                    table.insert(eggList, {obj=obj, prompt=prompt, pos=eggPos})
                else
                    print(("[Axorz Hub] DoClaimEgg: skip %s (prompt=%s, pos=%s)"):format(
                        obj.Name, tostring(prompt), tostring(eggPos)))
                end
            end
        end

        print(("[Axorz Hub] DoClaimEgg: total %d telur ditemukan"):format(#eggList))

        local claimed = 0
        for i, entry in ipairs(eggList) do
            -- [FIX 7] Un-anchor SEBELUM tiap teleport (kritis untuk telur ke-2, 3, dst.)
            local hrpCur = GetHRP()
            if hrpCur then hrpCur.Anchored = false end
            task.wait(0.05)

            -- Cek ulang prompt masih valid
            if not entry.prompt or not entry.prompt.Enabled then
                print(("[Axorz Hub] DoClaimEgg: %s prompt sudah disabled, skip"):format(entry.obj.Name))
                continue
            end

            -- Teleport ke telur, tunggu server acknowledge
            local ok2 = TeleportToAndAnchor(entry.pos)
            if not ok2 then
                print("[Axorz Hub] DoClaimEgg: gagal teleport, skip")
                continue
            end

            -- Verifikasi jarak setelah teleport
            hrpCur = GetHRP()
            local dist = hrpCur and (hrpCur.Position - entry.pos).Magnitude or 99
            print(("[Axorz Hub] DoClaimEgg: [%d/%d] %s, jarak=%.1f"):format(
                i, #eggList, entry.obj.Name, dist))

            -- Fire prompt — server sudah tahu posisi kita
            if dist <= 10 then
                pcall(function() fireproximityprompt(entry.prompt) end)
                claimed = claimed + 1
                print(("[Axorz Hub] DoClaimEgg: fired prompt %s"):format(entry.obj.Name))
            else
                print(("[Axorz Hub] DoClaimEgg: jarak terlalu jauh (%.1f), retry teleport"):format(dist))
                -- Retry sekali lagi
                local hrpR = GetHRP()
                if hrpR then hrpR.Anchored = false end
                task.wait(0.05)
                TeleportToAndAnchor(entry.pos)
                hrpCur = GetHRP()
                dist = hrpCur and (hrpCur.Position - entry.pos).Magnitude or 99
                if dist <= 10 then
                    pcall(function() fireproximityprompt(entry.prompt) end)
                    claimed = claimed + 1
                    print(("[Axorz Hub] DoClaimEgg: retry berhasil %s"):format(entry.obj.Name))
                else
                    print(("[Axorz Hub] DoClaimEgg: retry gagal, skip %s"):format(entry.obj.Name))
                end
            end

            -- Delay antar telur
            task.wait(math.max(Config.ClaimDelay, 0.4))
        end

        -- [FIX 7] Un-anchor setelah semua selesai
        local hrpEnd = GetHRP()
        if hrpEnd then hrpEnd.Anchored = false end

        if claimed > 0 then
            print(("[Axorz Hub] AutoClaim: %d / %d telur diklaim!"):format(claimed, #eggList))
            Notify("Auto Claim Egg", ("🥚 %d telur diklaim!"):format(claimed))
            if Config.AutoSellEgg then task.wait(0.5); pcall(DoSellEgg) end
        else
            print("[Axorz Hub] AutoClaim: tidak ada telur yang berhasil diklaim")
        end
    end)
    if not ok then print("[Axorz Hub] DoClaimEgg error:", err) end
    -- Pastikan always un-anchor meski error
    local hrpFinal = GetHRP()
    if hrpFinal then hrpFinal.Anchored = false end
    ClaimEggDebounce = false
end

-- ──────────────────────────────────────────────────────────
--  CHICKEN ROUTINE UNTUK AUTO FARM ALL
-- ──────────────────────────────────────────────────────────
local function DoChickenRoutineForFarmAll()
    if not AcquireChickenLock() then return end

    local ok, err = pcall(function()
        print("[Axorz Hub] Chicken Routine: GlobalPause ON, urus kandang...")
        Notify("Auto Farm All", "🐔 Farm di-pause, urus kandang...")

        -- Reset flag di awal agar polling tidak trigger ulang saat routine jalan
        Config.EggReadyFlag = false

        -- Un-anchor penuh sebelum mulai
        local hrp = GetHRP()
        local hum = GetHumanoid()
        if hrp then hrp.Anchored = false end
        if hum then hum.WalkSpeed = Config.WalkSpeed; hum.JumpHeight = 7.2 end
        task.wait(0.3)

        -- 1. Claim semua telur
        ClaimEggDebounce = false
        print("[Axorz Hub] Chicken Routine: mulai DoClaimEgg...")
        DoClaimEgg()
        print("[Axorz Hub] Chicken Routine: DoClaimEgg selesai")

        -- Un-anchor bersih sebelum feed
        hrp = GetHRP()
        if hrp then hrp.Anchored = false end
        task.wait(0.3)

        -- 2. Feed setelah claim (ayam selesai bertelur = lapar lagi)
        if Config.AutoFeed then
            FeedDebounce = false
            print("[Axorz Hub] Chicken Routine: mulai DoFeedChicken...")
            DoFeedChicken()
            print("[Axorz Hub] Chicken Routine: DoFeedChicken selesai")
            hrp = GetHRP()
            if hrp then hrp.Anchored = false end
            task.wait(0.2)
        end

        -- 3. Jual telur kalau auto sell aktif
        if Config.AutoSellEgg then pcall(DoSellEgg); task.wait(0.2) end

        -- Kembali ke lahan biasa
        local posLahanBiasa = (Config.SelectedArea and AreaTanamData[Config.SelectedArea]
            and AreaTanamData[Config.SelectedArea].position)
            or (#PlotPositions > 0 and PlotPositions[1]) or nil
        if posLahanBiasa then
            hrp = GetHRP()
            if hrp then hrp.Anchored = false end
            task.wait(0.05)
            TeleportTo(CFrame.new(posLahanBiasa + Vector3.new(0, 4, 0)))
            task.wait(0.5)
            if Config.SelectedSeed then pcall(function() EquipSeed(Config.SelectedSeed) end) end
        end

        print("[Axorz Hub] Chicken Routine selesai, farm dilanjutkan.")
        Notify("Auto Farm All", "✅ Kandang selesai, farm dilanjutkan!")
    end)

    if not ok then print("[Axorz Hub] DoChickenRoutineForFarmAll error:", err) end
    ReleaseChickenLock()
end

-- ──────────────────────────────────────────────────────────
--  EGG WATCHER
-- ──────────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────
--  EGG WATCHER — multi-layer detection
--  Layer 1: ChildAdded (object telur baru muncul di kandang)
--  Layer 2: ProximityPrompt.Enabled berubah jadi true
--           (telur sudah ada tapi promptnya baru aktif)
--  Layer 3: AttributeChanged di child kandang
--           (game set attribute "IsReady", "HasEgg", dll.)
--  Layer 4: Polling aktif tiap 8 detik (backup)
-- ──────────────────────────────────────────────────────────
local EggWatcherConns = {} -- pakai tabel, bukan single conn

local function TriggerEggRoutine(source)
    if not Config.AutoClaimEgg then return end
    if Config.IsChickenBusy then return end
    if Config.EggReadyFlag then return end -- sudah ditangani

    Config.EggReadyFlag = true
    print("[Axorz Hub] Egg detected via:", source)

    if Config.AutoFeed and Config.AutoClaimEgg then
        task.spawn(function()
            task.wait(0.3)
            pcall(DoChickenRoutineForFarmAll)
        end)
    else
        task.spawn(function()
            task.wait(0.3)
            ClaimEggDebounce = false
            pcall(DoClaimEgg)
        end)
    end
end

SetupEggWatcher = function(coop)
    -- Disconnect semua koneksi lama
    for _, conn in pairs(EggWatcherConns) do
        pcall(function() conn:Disconnect() end)
    end
    EggWatcherConns = {}
    EggWatcherConn  = nil -- backward compat
    if not coop then return end

    -- ── Helper: pasang watcher pada 1 child ──
    local function WatchChild(child)
        -- Layer 2: monitor prompt Enabled berubah jadi true
        for _, desc in pairs(child:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                local c = desc:GetPropertyChangedSignal("Enabled"):Connect(function()
                    if desc.Enabled then
                        -- Cek apakah ini prompt telur (bukan upgrade)
                        local action = desc.ActionText:lower()
                        local object = desc.ObjectText:lower()
                        local isUpgrade = action:find("upgrade") or object:find("price")
                        if not isUpgrade then
                            print("[Axorz Hub] PromptEnabled:", child.Name, desc.ActionText)
                            TriggerEggRoutine("PromptEnabled:"..child.Name)
                        end
                    end
                end)
                table.insert(EggWatcherConns, c)
            end
        end

        -- Layer 3: monitor attribute changes
        local c = child.AttributeChanged:Connect(function(attr)
            local val = child:GetAttribute(attr)
            print("[Axorz Hub] AttrChange:", child.Name, attr, "=", tostring(val))
            -- Deteksi attribute yang menandakan telur siap
            local attrLow = attr:lower()
            if attrLow:find("ready") or attrLow:find("egg") or attrLow:find("hatch") then
                if val == true or val == 1 or tostring(val):lower() == "true" then
                    TriggerEggRoutine("AttrChange:"..attr)
                end
            end
        end)
        table.insert(EggWatcherConns, c)
    end

    -- Pasang watcher pada semua child yang sudah ada
    for _, child in pairs(coop:GetChildren()) do
        WatchChild(child)
    end

    -- Layer 1: ChildAdded — object telur baru muncul
    local c1 = coop.ChildAdded:Connect(function(child)
        -- Pasang watcher pada child baru ini juga
        WatchChild(child)

        local nameLow = child.Name:lower()
        local isEgg   = nameLow:find("egg") or nameLow:find("telur") or nameLow:find("hatch")

        if isEgg then
            print("[Axorz Hub] ChildAdded (egg):", child.Name, child.ClassName)
            TriggerEggRoutine("ChildAdded:"..child.Name)
            return
        end

        -- Bahkan kalau namanya tidak "egg", monitor promptnya — mungkin objek
        -- slot ayam yang dapat prompt baru saat telur ready
        task.delay(0.5, function()
            for _, desc in pairs(child:GetDescendants()) do
                if desc:IsA("ProximityPrompt") and desc.Enabled then
                    local action = desc.ActionText:lower()
                    local object = desc.ObjectText:lower()
                    local isUpgrade = action:find("upgrade") or object:find("price")
                    if not isUpgrade then
                        print("[Axorz Hub] ChildAdded prompt enabled:", child.Name, desc.ActionText)
                        TriggerEggRoutine("ChildPrompt:"..child.Name)
                        break
                    end
                end
            end
        end)
    end)
    table.insert(EggWatcherConns, c1)
    EggWatcherConn = c1 -- backward compat

    -- Cek langsung apakah sudah ada telur saat watcher dipasang
    task.defer(function()
        if HasEggInCoop(coop) then
            print("[Axorz Hub] EggWatcher init: telur sudah ada!")
            TriggerEggRoutine("InitCheck")
        end
    end)

    print(("[Axorz Hub] Egg watcher aktif (%d layer): %s"):format(4, coop.Name))
end

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

-- Feed loop dihapus — feed hanya dipanggil via egg watcher trigger,
-- bukan polling terus-menerus. Ayam diberi makan setelah telur diklaim.

task.spawn(function()
    while true do
        task.wait(8) -- lebih jarang, egg watcher yang utama
        if not Config.AutoClaimEgg then continue end
        if Config.IsChickenBusy then continue end
        -- Jangan trigger lagi kalau sudah ada flag aktif
        if Config.EggReadyFlag then continue end

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

        -- Simpan nama kandang dan setup watcher kalau belum
        if not Config.ChickenCoopName then
            Config.ChickenCoopName = coop.Name
            SetupEggWatcher(coop)
        end

        if HasEggInCoop(coop) then
            print("[Axorz Hub] Polling: deteksi telur!")
            Config.EggReadyFlag = true
            if not Config.IsChickenBusy then
                if Config.AutoFeed and Config.AutoClaimEgg then
                    task.spawn(function() pcall(DoChickenRoutineForFarmAll) end)
                else
                    task.spawn(function()
                        ClaimEggDebounce = false
                        pcall(DoClaimEgg)
                    end)
                end
            end
        end
        -- Kalau tidak ada telur, tidak print apapun — tidak perlu spam console
    end
end)

-- Loop khusus AutoFeed saja (tanpa AutoClaimEgg) — feed manual periodik
-- Interval jauh lebih lama, hanya backup kalau watcher miss
task.spawn(function()
    while true do
        task.wait(60) -- cek tiap 1 menit saja
        if not Config.AutoFeed then continue end
        if Config.AutoClaimEgg then continue end -- sudah dihandle routine
        if Config.IsChickenBusy then continue end
        if FeedDebounce then continue end
        pcall(DoFeedChicken)
    end
end)

task.spawn(function()
    while true do
        task.wait(8)
        if CanRun() and (Config.AutoSell or Config.AutoFarm) then pcall(DoSell) end
    end
end)

task.spawn(function()
    while true do
        task.wait(8)
        if CanRun() and (Config.AutoSellCrop or Config.AutoFarmBesar or Config.AutoFarm) then pcall(DoSellCrop) end
    end
end)

task.spawn(function()
    while true do
        task.wait(15)
        if Config.AutoSellEgg then pcall(DoSellEgg) end
    end
end)

task.spawn(function()
    while true do
        task.wait(Config.BuyDelay)
        if Config.AutoBuy then pcall(DoBuy) end
    end
end)

task.spawn(function()
    while true do
        task.wait(0.5)
        if Config.ESPEnabled then pcall(UpdateESP) end
    end
end)

-- [FIX 1] Loop Freeze — tidak anchor saat GlobalPause
task.spawn(function()
    while true do
        task.wait(0.1)
        local hrp = GetHRP()
        local hum = GetHumanoid()
        if hrp and hum then
            if Config.Freeze then
                hum.WalkSpeed = 0; hum.JumpHeight = 0; hrp.Anchored = true
            elseif Config.GlobalPause then
                -- Biarkan chicken routine yang atur anchor
            else
                hrp.Anchored = false
                hum.WalkSpeed = Config.WalkSpeed
                hum.JumpHeight = 7.2
            end
        end
    end
end)


-- ══════════════════════════════════════════════════════════
--  AXORZ HUB v3.0 — CUSTOM GUI
--  Sidebar kiri | Dark modern hijau | Draggable | Float btn
-- ══════════════════════════════════════════════════════════

local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")

-- ──────────────────────────────────────────────────────────
--  SEED HELPER
-- ──────────────────────────────────────────────────────────
local function BuildSeedList()
    local seeds = GetSeedsInBackpack()
    local names = {}
    for _, s in ipairs(seeds) do table.insert(names, s.baseName) end
    if #names == 0 then
        names = {"Bibit Padi","Bibit Jagung","Bibit Tomat","Bibit Terong","Bibit Strawberry","Bibit Palm","Bibit Durian"}
    end
    return names
end

task.wait(1)
local SeedNames = BuildSeedList()
Config.SelectedSeed = SeedNames[1]

-- ──────────────────────────────────────────────────────────
--  SCREEN SIZE
-- ──────────────────────────────────────────────────────────
local VP     = workspace.CurrentCamera.ViewportSize
local SW, SH = VP.X, VP.Y
local IS_MOBILE = (SW < 800 or SH < 500)

local GUI_W  = IS_MOBILE and math.min(math.floor(SW*0.92), 420) or math.min(math.floor(SW*0.40), 600)
local GUI_H  = IS_MOBILE and math.min(math.floor(SH*0.78), 480) or math.min(math.floor(SH*0.72), 560)
local SIDE_W = IS_MOBILE and 110 or 130
local FLOAT_SIZE = IS_MOBILE and 72 or 64

-- ──────────────────────────────────────────────────────────
--  COLOR CONSTANTS
-- ──────────────────────────────────────────────────────────
local C = {
    BG          = Color3.fromRGB(13,  13,  13),
    BG2         = Color3.fromRGB(17,  17,  17),
    BG3         = Color3.fromRGB(22,  22,  22),
    SIDEBAR     = Color3.fromRGB(10,  10,  10),
    BORDER      = Color3.fromRGB(30,  30,  30),
    BORDER2     = Color3.fromRGB(40,  40,  40),
    ACCENT      = Color3.fromRGB(74,  222, 128),
    ACCENT_DIM  = Color3.fromRGB(22,  101, 52),
    ACCENT_BG   = Color3.fromRGB(13,  26,  13),
    TEXT        = Color3.fromRGB(255, 255, 255),
    TEXT_DIM    = Color3.fromRGB(180, 180, 180),
    TEXT_FAINT  = Color3.fromRGB(140, 140, 140),
    TOGGLE_OFF  = Color3.fromRGB(35,  35,  35),
    TOGGLE_ON   = Color3.fromRGB(22,  101, 52),
    BTN         = Color3.fromRGB(22,  22,  22),
    BTN_HOVER   = Color3.fromRGB(30,  30,  30),
    RED         = Color3.fromRGB(185, 50,  50),
    WHITE       = Color3.fromRGB(255, 255, 255),
}

-- ──────────────────────────────────────────────────────────
--  ROOT SCREENGUI
-- ──────────────────────────────────────────────────────────
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "AxorzHubV3"
ScreenGui.ResetOnSpawn   = false
ScreenGui.DisplayOrder   = 999
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

-- ──────────────────────────────────────────────────────────
--  NOTIFY SYSTEM — implementasi penuh (GUI sudah siap)
--  NotifyImpl diset di sini, queue yang terkumpul sejak awal
--  langsung diproses.
-- ──────────────────────────────────────────────────────────
local function NotifyRun()
    if NotifyActive then return end
    NotifyActive = true
    task.spawn(function()
        while #NotifyQueue > 0 do
            local item = table.remove(NotifyQueue, 1)
            local nFrame = Instance.new("Frame")
            nFrame.Size              = UDim2.fromOffset(220, 52)
            nFrame.Position          = UDim2.new(1, 4, 1, -66)
            nFrame.BackgroundColor3  = C.ACCENT_BG
            nFrame.BorderSizePixel   = 0
            nFrame.ZIndex            = 50
            nFrame.Parent            = ScreenGui
            Instance.new("UICorner", nFrame).CornerRadius = UDim.new(0,8)
            local nStroke = Instance.new("UIStroke", nFrame)
            nStroke.Color = C.ACCENT_DIM; nStroke.Thickness = 1

            local nBar = Instance.new("Frame", nFrame)
            nBar.Size             = UDim2.new(0,3,1,0)
            nBar.BackgroundColor3 = C.ACCENT
            nBar.BorderSizePixel  = 0
            Instance.new("UICorner", nBar).CornerRadius = UDim.new(0,8)

            local nTitle = Instance.new("TextLabel", nFrame)
            nTitle.Position         = UDim2.fromOffset(10,6)
            nTitle.Size             = UDim2.new(1,-14,0,18)
            nTitle.BackgroundTransparency = 1
            nTitle.Text             = item.title
            nTitle.TextColor3       = C.ACCENT
            nTitle.TextSize         = 12
            nTitle.Font             = Enum.Font.GothamBold
            nTitle.TextXAlignment   = Enum.TextXAlignment.Left

            local nContent = Instance.new("TextLabel", nFrame)
            nContent.Position         = UDim2.fromOffset(10,24)
            nContent.Size             = UDim2.new(1,-14,0,22)
            nContent.BackgroundTransparency = 1
            nContent.Text             = item.content
            nContent.TextColor3       = C.TEXT_DIM
            nContent.TextSize         = 11
            nContent.Font             = Enum.Font.Gotham
            nContent.TextXAlignment   = Enum.TextXAlignment.Left
            nContent.TextWrapped      = true

            -- Slide in
            local tin = TweenService:Create(nFrame,TweenInfo.new(0.2),{Position=UDim2.new(1,-228,1,-66)})
            tin:Play()
            task.wait(2.5)
            -- Slide out
            local tout = TweenService:Create(nFrame,TweenInfo.new(0.2),{Position=UDim2.new(1,4,1,-66)})
            tout:Play()
            tout.Completed:Wait()
            nFrame:Destroy()
            task.wait(0.1)
        end
        NotifyActive = false
    end)
end

-- Aktifkan NotifyImpl dan proses queue yang sudah terkumpul sejak engine jalan
NotifyImpl = NotifyRun
if #NotifyQueue > 0 then NotifyRun() end

-- ──────────────────────────────────────────────────────────
--  GUI BUILDER HELPERS
-- ──────────────────────────────────────────────────────────
local function MakeFrame(parent, size, pos, bg, zindex)
    local f = Instance.new("Frame")
    f.Size = size; f.Position = pos or UDim2.new(0,0,0,0)
    f.BackgroundColor3 = bg or C.BG
    f.BorderSizePixel  = 0
    f.ZIndex           = zindex or 1
    f.Parent           = parent
    return f
end

local function MakeCorner(parent, radius)
    local c = Instance.new("UICorner", parent)
    c.CornerRadius = UDim.new(0, radius or 6)
    return c
end

local function MakeStroke(parent, color, thickness)
    local s = Instance.new("UIStroke", parent)
    s.Color = color or C.BORDER; s.Thickness = thickness or 1
    return s
end

local function MakeLabel(parent, text, size, color, font, pos, sizeUDim, xalign, zindex)
    local l = Instance.new("TextLabel")
    l.Text                = text
    l.TextSize            = size or 12
    l.TextColor3          = color or C.TEXT
    l.Font                = font or Enum.Font.Gotham
    l.BackgroundTransparency = 1
    l.Position            = pos or UDim2.new(0,0,0,0)
    l.Size                = sizeUDim or UDim2.new(1,0,1,0)
    l.TextXAlignment      = xalign or Enum.TextXAlignment.Left
    l.TextYAlignment      = Enum.TextYAlignment.Center
    l.ZIndex              = zindex or 2
    l.TextWrapped         = true
    l.Parent              = parent
    return l
end

local function MakeButton(parent, text, pos, size, callback)
    local btn = Instance.new("TextButton")
    btn.Text                = text
    btn.TextSize            = 11
    btn.TextColor3          = C.TEXT
    btn.Font                = Enum.Font.Gotham
    btn.BackgroundColor3    = C.BTN
    btn.BorderSizePixel     = 0
    btn.Position            = pos or UDim2.new(0,0,0,0)
    btn.Size                = size or UDim2.new(1,0,0,26)
    btn.ZIndex              = 3
    btn.TextXAlignment      = Enum.TextXAlignment.Center
    btn.AutoButtonColor     = false
    btn.Parent              = parent
    MakeCorner(btn, 5)
    MakeStroke(btn, C.BORDER2, 1)
    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = C.BTN_HOVER end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = C.BTN end)
    if callback then btn.MouseButton1Click:Connect(callback) end
    return btn
end

-- Toggle: returns setter function
local function MakeToggle(parent, yOffset, labelText, subText, configKey, onChanged)
    local ROW_H = subText and 40 or 30
    local row = MakeFrame(parent, UDim2.new(1,0,0,ROW_H), UDim2.fromOffset(0,yOffset), Color3.new(0,0,0))
    row.BackgroundTransparency = 1

    local sep = MakeFrame(row, UDim2.new(1,0,0,1), UDim2.new(0,0,1,-1), C.BORDER)
    sep.BackgroundTransparency = 0.6

    MakeLabel(row, labelText, 12, C.TEXT, Enum.Font.Gotham,
        UDim2.fromOffset(0,0), UDim2.new(1,-46,0,18), Enum.TextXAlignment.Left, 3)

    if subText then
        MakeLabel(row, subText, 10, C.TEXT_FAINT, Enum.Font.Gotham,
            UDim2.fromOffset(0,18), UDim2.new(1,-46,0,14), Enum.TextXAlignment.Left, 3)
    end

    -- Track
    local track = MakeFrame(row, UDim2.fromOffset(36,20), UDim2.new(1,-42,(ROW_H-20)/2/ROW_H,0), C.TOGGLE_OFF)
    MakeCorner(track, 10)
    MakeStroke(track, C.BORDER2, 1)

    -- Thumb
    local thumb = MakeFrame(track, UDim2.fromOffset(14,14), UDim2.fromOffset(3,3), Color3.fromRGB(80,80,80))
    MakeCorner(thumb, 7)

    local on = Config[configKey] or false

    local function setState(state)
        on = state
        Config[configKey] = state
        local targetX = state and 19 or 3
        local trackColor = state and C.TOGGLE_ON or C.TOGGLE_OFF
        local thumbColor = state and C.ACCENT or Color3.fromRGB(80,80,80)
        TweenService:Create(thumb, TweenInfo.new(0.15), {Position=UDim2.fromOffset(targetX,3), BackgroundColor3=thumbColor}):Play()
        TweenService:Create(track, TweenInfo.new(0.15), {BackgroundColor3=trackColor}):Play()
        if onChanged then onChanged(state) end
    end

    -- Init state
    setState(on)

    track.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            setState(not on)
        end
    end)

    return row, setState
end

-- Slider: returns setter
local function MakeSlider(parent, yOffset, labelText, minV, maxV, defaultV, step, suffix, configKey, onChanged)
    step = step or 1
    suffix = suffix or ""
    local row = MakeFrame(parent, UDim2.new(1,0,0,38), UDim2.fromOffset(0,yOffset), Color3.new(0,0,0))
    row.BackgroundTransparency = 1

    MakeLabel(row, labelText, 11, C.TEXT_DIM, Enum.Font.Gotham,
        UDim2.fromOffset(0,0), UDim2.new(1,-50,0,16), Enum.TextXAlignment.Left, 3)

    local valLabel = MakeLabel(row, tostring(defaultV)..suffix, 11, C.ACCENT, Enum.Font.GothamBold,
        UDim2.new(1,-48,0,0), UDim2.fromOffset(48,16), Enum.TextXAlignment.Right, 3)

    local sep = MakeFrame(row, UDim2.new(1,0,0,1), UDim2.new(0,0,1,-1), C.BORDER)
    sep.BackgroundTransparency = 0.6

    -- Track bar
    local trackBg = MakeFrame(row, UDim2.new(1,0,0,4), UDim2.new(0,0,0,22), C.BORDER2)
    MakeCorner(trackBg, 2)

    local fill = MakeFrame(trackBg, UDim2.fromScale(0,1), UDim2.new(0,0,0,0), C.ACCENT_DIM)
    MakeCorner(fill, 2)

    local thumb = MakeFrame(trackBg, UDim2.fromOffset(12,12), UDim2.new(0,-6,-1,0), C.ACCENT)
    MakeCorner(thumb, 6)

    local currentVal = defaultV
    if Config[configKey] ~= nil then currentVal = Config[configKey] end

    local function setValue(v)
        v = math.clamp(math.round(v / step) * step, minV, maxV)
        currentVal = v
        Config[configKey] = v
        local pct = (v - minV) / (maxV - minV)
        fill.Size     = UDim2.new(pct, 0, 1, 0)
        thumb.Position = UDim2.new(pct, -6, -1, 0)
        local display = (step < 1) and string.format("%.1f", v) or tostring(v)
        valLabel.Text = display .. suffix
        if onChanged then onChanged(v) end
    end

    setValue(currentVal)

    local draggingSlider = false
    local function onInput(input)
        local absX   = trackBg.AbsolutePosition.X
        local absW   = trackBg.AbsoluteSize.X
        local relX   = math.clamp(input.Position.X - absX, 0, absW)
        local pct    = relX / absW
        setValue(minV + (maxV - minV) * pct)
    end

    trackBg.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            draggingSlider = true; onInput(inp)
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if not draggingSlider then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement
        or inp.UserInputType == Enum.UserInputType.Touch then onInput(inp) end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then draggingSlider = false end
    end)

    return row, setValue
end

-- Dropdown
local function MakeDropdown(parent, yOffset, values, defaultVal, onChanged)
    local h = 28
    local row = MakeFrame(parent, UDim2.new(1,0,0,h), UDim2.fromOffset(0,yOffset), C.BTN)
    MakeCorner(row, 5); MakeStroke(row, C.BORDER2, 1)

    local label = MakeLabel(row, defaultVal or (values[1] or "—"), 11, C.TEXT, Enum.Font.Gotham,
        UDim2.fromOffset(8,0), UDim2.new(1,-28,1,0), Enum.TextXAlignment.Left, 3)

    local arrow = MakeLabel(row, "▾", 12, C.TEXT_DIM, Enum.Font.GothamBold,
        UDim2.new(1,-22,0,0), UDim2.fromOffset(20,h), Enum.TextXAlignment.Center, 3)

    local open = false
    local dropList = nil

    local function closeDropdown()
        if dropList then dropList:Destroy(); dropList = nil end
        open = false; arrow.Text = "▾"
    end

    local function openDropdown()
        open = true; arrow.Text = "▴"
        local itemH = 24
        dropList = MakeFrame(ScreenGui,
            UDim2.fromOffset(row.AbsoluteSize.X, math.min(#values,6)*itemH),
            UDim2.fromOffset(row.AbsolutePosition.X, row.AbsolutePosition.Y + h),
            C.BG2)
        dropList.ZIndex = 30
        MakeCorner(dropList, 5); MakeStroke(dropList, C.BORDER2, 1)

        local listLayout = Instance.new("UIListLayout", dropList)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder

        for i, v in ipairs(values) do
            local item = Instance.new("TextButton")
            item.Size               = UDim2.new(1,0,0,itemH)
            item.BackgroundColor3   = C.BG2
            item.BorderSizePixel    = 0
            item.Text               = v
            item.TextSize           = 11
            item.TextColor3         = C.TEXT
            item.Font               = Enum.Font.Gotham
            item.TextXAlignment     = Enum.TextXAlignment.Left
            item.ZIndex             = 31
            item.AutoButtonColor    = false
            item.LayoutOrder        = i
            item.Parent             = dropList
            local pad = Instance.new("UIPadding",item)
            pad.PaddingLeft = UDim.new(0,8)
            item.MouseEnter:Connect(function() item.BackgroundColor3 = C.BG3 end)
            item.MouseLeave:Connect(function() item.BackgroundColor3 = C.BG2 end)
            item.MouseButton1Click:Connect(function()
                label.Text = v
                closeDropdown()
                if onChanged then onChanged(v) end
            end)
        end
    end

    row.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            if open then closeDropdown() else openDropdown() end
        end
    end)

    UserInputService.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            if open and dropList and not dropList:IsDescendantOf(ScreenGui) then
                closeDropdown()
            end
        end
    end)

    return row, label, closeDropdown
end

-- Info box
local function MakeInfoBox(parent, yOffset, text)
    local box = MakeFrame(parent, UDim2.new(1,0,0,36), UDim2.fromOffset(0,yOffset), C.ACCENT_BG)
    MakeCorner(box, 5); MakeStroke(box, C.ACCENT_DIM, 1)
    local lbl = MakeLabel(box, text, 11, C.ACCENT, Enum.Font.Gotham,
        UDim2.fromOffset(8,0), UDim2.new(1,-16,1,0), Enum.TextXAlignment.Left, 3)
    lbl.TextWrapped = true
    return box, lbl
end

-- Section label
local function MakeSectionLabel(parent, yOffset, text)
    local lbl = MakeLabel(parent, text, 10, C.TEXT_FAINT, Enum.Font.GothamBold,
        UDim2.fromOffset(0, yOffset), UDim2.new(1,0,0,18), Enum.TextXAlignment.Left, 3)
    lbl.Text = string.upper(text)
    return lbl
end

-- ──────────────────────────────────────────────────────────
--  MAIN WINDOW
-- ──────────────────────────────────────────────────────────
local MainFrame = MakeFrame(ScreenGui,
    UDim2.fromOffset(GUI_W, GUI_H),
    UDim2.fromOffset(120, 80),
    C.BG)
MainFrame.ZIndex = 5
MakeCorner(MainFrame, 8)
MakeStroke(MainFrame, C.BORDER, 1)

-- ── TITLEBAR ──
local TB_H = IS_MOBILE and 40 or 32
local TitleBar = MakeFrame(MainFrame, UDim2.new(1,0,0,TB_H), UDim2.new(0,0,0,0), C.SIDEBAR)
TitleBar.ZIndex = 6
MakeCorner(TitleBar, 8)

local TitleBarFix = MakeFrame(TitleBar, UDim2.new(1,0,0.5,0), UDim2.new(0,0,0.5,0), C.SIDEBAR)
TitleBarFix.ZIndex = 6

local TitleLabel = MakeLabel(TitleBar,"Axorz Hub",13,C.ACCENT,Enum.Font.GothamBold,
    UDim2.fromOffset(12,0),UDim2.new(0,100,1,0),Enum.TextXAlignment.Left,7)
local SubLabel = MakeLabel(TitleBar,"Sawah Indo  |  v3.0",11,C.TEXT_FAINT,Enum.Font.Gotham,
    UDim2.fromOffset(115,0),UDim2.new(0,160,1,0),Enum.TextXAlignment.Left,7)

-- Close / Minimize buttons — lebih besar, ada jarak, mobile-friendly
local BTN_SIZE = IS_MOBILE and 22 or 16
local BTN_GAP  = IS_MOBILE and 10 or 7

local function MakeTitleBtn(color, rightOffset, callback)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
    btn.Position         = UDim2.new(1, rightOffset, 0.5, -BTN_SIZE/2)
    btn.BackgroundColor3 = color
    btn.BorderSizePixel  = 0
    btn.Text             = ""
    btn.ZIndex           = 8
    btn.AutoButtonColor  = false
    btn.Parent           = TitleBar
    MakeCorner(btn, BTN_SIZE/2)
    -- [FIX] Hover hanya ubah warna, TIDAK ubah Size/Position agar tidak bergeser
    local baseColor = color
    local hoverColor = Color3.new(
        math.min(color.R*1.25, 1),
        math.min(color.G*1.25, 1),
        math.min(color.B*1.25, 1))
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=hoverColor}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=baseColor}):Play()
    end)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

-- ── SIDEBAR ──
local SideBar = MakeFrame(MainFrame,
    UDim2.new(0,SIDE_W,1,-TB_H),
    UDim2.fromOffset(0,TB_H),
    C.SIDEBAR)
SideBar.ZIndex = 6
local sideStroke = MakeStroke(SideBar, C.BORDER, 1)

local SideLayout = Instance.new("UIListLayout", SideBar)
SideLayout.SortOrder    = Enum.SortOrder.LayoutOrder
SideLayout.Padding      = UDim.new(0,2)
local sidePad = Instance.new("UIPadding", SideBar)
sidePad.PaddingTop = UDim.new(0,6)
sidePad.PaddingLeft = UDim.new(0,4)
sidePad.PaddingRight = UDim.new(0,4)

-- ── CONTENT AREA ──
local ContentFrame = MakeFrame(MainFrame,
    UDim2.new(1,-SIDE_W,1,-TB_H),
    UDim2.fromOffset(SIDE_W,TB_H),
    C.BG)
ContentFrame.ZIndex        = 6
ContentFrame.ClipsDescendants = true

-- ──────────────────────────────────────────────────────────
--  TAB SYSTEM
-- ──────────────────────────────────────────────────────────
local Tabs     = {}
local TabBtns  = {}
local ActiveTab = nil

local function CreateTabBtn(name, icon, layoutOrder)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1,0,0, IS_MOBILE and 32 or 28)
    btn.BackgroundColor3 = Color3.new(0,0,0)
    btn.BackgroundTransparency = 1
    btn.BorderSizePixel  = 0
    btn.Text             = ""
    btn.ZIndex           = 7
    btn.AutoButtonColor  = false
    btn.LayoutOrder      = layoutOrder
    btn.Parent           = SideBar
    MakeCorner(btn, 5)

    local ic = MakeLabel(btn, icon, 13, C.TEXT_FAINT, Enum.Font.GothamBold,
        UDim2.fromOffset(4,0), UDim2.fromOffset(20, IS_MOBILE and 32 or 28),
        Enum.TextXAlignment.Center, 8)
    local lbl = MakeLabel(btn, name, 11, C.TEXT_FAINT, Enum.Font.Gotham,
        UDim2.fromOffset(24,0), UDim2.new(1,-26,1,0),
        Enum.TextXAlignment.Left, 8)

    TabBtns[name] = {btn=btn, ic=ic, lbl=lbl}
    return btn
end

local function CreateTabPanel(name)
    local panel = MakeFrame(ContentFrame,
        UDim2.new(1,0,1,0),
        UDim2.new(0,0,0,0),
        C.BG)
    panel.ZIndex  = 6
    panel.Visible = false
    panel.ClipsDescendants = true

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size              = UDim2.new(1,0,1,0)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel   = 0
    scroll.ScrollBarThickness = 3
    scroll.ScrollBarImageColor3 = C.BORDER2
    scroll.CanvasSize        = UDim2.new(0,0,0,0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.ZIndex            = 7
    scroll.Parent            = panel

    local inner = MakeFrame(scroll, UDim2.new(1,-8,0,0), UDim2.fromOffset(6,8), C.BG)
    inner.BackgroundTransparency = 1
    inner.ZIndex = 7
    inner.AutomaticSize = Enum.AutomaticSize.Y

    local layout = Instance.new("UIListLayout", inner)
    layout.SortOrder  = Enum.SortOrder.LayoutOrder
    layout.Padding    = UDim.new(0,4)

    Tabs[name] = {panel=panel, inner=inner, layout=layout, yOff=0}
    return panel
end

local function SwitchTab(name)
    if ActiveTab == name then return end
    ActiveTab = name
    for n, t in pairs(Tabs) do
        t.panel.Visible = (n == name)
    end
    for n, tb in pairs(TabBtns) do
        local isActive = (n == name)
        tb.btn.BackgroundTransparency = isActive and 0 or 1
        tb.btn.BackgroundColor3 = isActive and C.ACCENT_BG or Color3.new(0,0,0)
        tb.ic.TextColor3  = isActive and C.ACCENT or C.TEXT_FAINT
        tb.lbl.TextColor3 = isActive and C.ACCENT or C.TEXT_FAINT
        if isActive then
            MakeStroke(tb.btn, C.ACCENT_DIM, 1)
        else
            for _, s in pairs(tb.btn:GetChildren()) do
                if s:IsA("UIStroke") then s:Destroy() end
            end
        end
    end
end

-- Helper: add item to tab inner frame
local function AddToTab(tabName, instance, fixedH)
    local inner = Tabs[tabName].inner
    instance.Parent = inner
    if fixedH then
        instance.Size = UDim2.new(1,0,0,fixedH)
    end
    return instance
end

-- ──────────────────────────────────────────────────────────
--  BUILD TABS
-- ──────────────────────────────────────────────────────────
local tabDefs = {
    {"Auto Farm",      "🌾", 1},
    {"Sawit & Durian", "🌴", 2},
    {"Auto Chicken",   "🐔", 3},
    {"Auto Sell",      "💰", 4},
    {"Auto Buy",       "🛒", 5},
    {"Player",         "🏃", 6},
    {"ESP",            "👁", 7},
    {"Anti-AFK",       "🛡", 8},
}

for _, td in ipairs(tabDefs) do
    local name, icon, order = td[1], td[2], td[3]
    local btn = CreateTabBtn(name, icon, order)
    CreateTabPanel(name)
    btn.MouseButton1Click:Connect(function() SwitchTab(name) end)
end

-- ──────────────────────────────────────────────────────────
--  HELPER: add standard row elements to a tab
-- ──────────────────────────────────────────────────────────
local function TabSection(tabName, text)
    local lbl = Instance.new("TextLabel")
    lbl.Size             = UDim2.new(1,0,0,16)
    lbl.BackgroundTransparency = 1
    lbl.Text             = string.upper(text)
    lbl.TextSize         = 10
    lbl.TextColor3       = C.TEXT_FAINT
    lbl.Font             = Enum.Font.GothamBold
    lbl.TextXAlignment   = Enum.TextXAlignment.Left
    lbl.BorderSizePixel  = 0
    lbl.ZIndex           = 8
    AddToTab(tabName, lbl)
end

local function TabInfoBox(tabName, text)
    local box = MakeFrame(nil, UDim2.new(1,0,0,36), nil, C.ACCENT_BG)
    MakeCorner(box,5); MakeStroke(box, C.ACCENT_DIM,1)
    local lbl = MakeLabel(box,text,11,C.ACCENT,Enum.Font.Gotham,
        UDim2.fromOffset(8,0),UDim2.new(1,-16,1,0),Enum.TextXAlignment.Left,8)
    lbl.TextWrapped = true
    AddToTab(tabName, box)
    return lbl
end

-- Warning box — kuning/oranye, font tebal putih, multi-line
local function TabWarning(tabName, text)
    local lineCount = 1
    for _ in text:gmatch("\n") do lineCount = lineCount + 1 end
    local boxH = math.max(44, lineCount * 16 + 16)

    local box = Instance.new("Frame")
    box.Size             = UDim2.new(1,0,0,boxH)
    box.BackgroundColor3 = Color3.fromRGB(60, 40, 5)
    box.BorderSizePixel  = 0
    box.ZIndex           = 8
    MakeCorner(box, 6)
    local stroke = Instance.new("UIStroke", box)
    stroke.Color     = Color3.fromRGB(200, 140, 20)
    stroke.Thickness = 1

    -- Bar kuning di kiri
    local bar = Instance.new("Frame", box)
    bar.Size             = UDim2.new(0, 3, 1, 0)
    bar.BackgroundColor3 = Color3.fromRGB(250, 180, 20)
    bar.BorderSizePixel  = 0
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 6)

    local lbl = Instance.new("TextLabel", box)
    lbl.Position         = UDim2.fromOffset(12, 0)
    lbl.Size             = UDim2.new(1, -18, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text             = text
    lbl.TextColor3       = Color3.fromRGB(255, 255, 255)
    lbl.TextSize         = 11
    lbl.Font             = Enum.Font.GothamBold
    lbl.TextXAlignment   = Enum.TextXAlignment.Left
    lbl.TextYAlignment   = Enum.TextYAlignment.Center
    lbl.TextWrapped      = true
    lbl.ZIndex           = 9

    AddToTab(tabName, box)
    return lbl
end

local function TabButton(tabName, text, callback, green)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1,0,0,26)
    btn.BackgroundColor3 = green and C.ACCENT_BG or C.BTN
    btn.BorderSizePixel  = 0
    btn.Text             = text
    btn.TextSize         = 11
    btn.TextColor3       = green and C.ACCENT or C.TEXT
    btn.Font             = Enum.Font.Gotham
    btn.ZIndex           = 8
    btn.AutoButtonColor  = false
    btn.TextXAlignment   = Enum.TextXAlignment.Center
    MakeCorner(btn,5)
    MakeStroke(btn, green and C.ACCENT_DIM or C.BORDER2, 1)
    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = green and C.ACCENT_DIM or C.BTN_HOVER end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = green and C.ACCENT_BG or C.BTN end)
    if callback then btn.MouseButton1Click:Connect(callback) end
    AddToTab(tabName, btn)
    return btn
end

local function TabToggle(tabName, labelText, subText, configKey, onChanged)
    local ROW_H = subText and 40 or 30
    local row = Instance.new("Frame")
    row.Size             = UDim2.new(1,0,0,ROW_H)
    row.BackgroundTransparency = 1
    row.BorderSizePixel  = 0
    row.ZIndex           = 8

    local sep = MakeFrame(row, UDim2.new(1,0,0,1), UDim2.new(0,0,1,-1), C.BORDER)
    sep.BackgroundTransparency = 0.7

    MakeLabel(row, labelText, 12, C.TEXT, Enum.Font.Gotham,
        UDim2.fromOffset(0,2), UDim2.new(1,-46,0,18), Enum.TextXAlignment.Left, 9)
    if subText then
        MakeLabel(row, subText, 10, C.TEXT_FAINT, Enum.Font.Gotham,
            UDim2.fromOffset(0,20), UDim2.new(1,-46,0,14), Enum.TextXAlignment.Left, 9)
    end

    local track = MakeFrame(row, UDim2.fromOffset(36,20), UDim2.new(1,-40,(ROW_H-20)/2/ROW_H,0), C.TOGGLE_OFF)
    MakeCorner(track,10); MakeStroke(track,C.BORDER2,1)
    local thumb = MakeFrame(track, UDim2.fromOffset(14,14), UDim2.fromOffset(3,3), Color3.fromRGB(80,80,80))
    MakeCorner(thumb,7)

    local on = Config[configKey] or false

    local function setState(state, silent)
        on = state
        Config[configKey] = state
        TweenService:Create(thumb,TweenInfo.new(0.12),{Position=UDim2.fromOffset(state and 19 or 3,3),BackgroundColor3=state and C.ACCENT or Color3.fromRGB(80,80,80)}):Play()
        TweenService:Create(track,TweenInfo.new(0.12),{BackgroundColor3=state and C.TOGGLE_ON or C.TOGGLE_OFF}):Play()
        if not silent and onChanged then onChanged(state) end
    end

    setState(on, true)
    track.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then setState(not on) end
    end)

    AddToTab(tabName, row)
    return setState
end

local function TabSlider(tabName, labelText, minV, maxV, defaultV, step, suffix, configKey, onChanged)
    step = step or 1; suffix = suffix or ""
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1,0,0,42)
    row.BackgroundTransparency = 1
    row.BorderSizePixel = 0
    row.ZIndex = 8

    MakeLabel(row, labelText, 11, C.TEXT_DIM, Enum.Font.Gotham,
        UDim2.fromOffset(0,2), UDim2.new(1,-50,0,16), Enum.TextXAlignment.Left, 9)

    local valLabel = MakeLabel(row, "", 11, C.ACCENT, Enum.Font.GothamBold,
        UDim2.new(1,-48,0,2), UDim2.fromOffset(48,16), Enum.TextXAlignment.Right, 9)

    local sep = MakeFrame(row, UDim2.new(1,0,0,1), UDim2.new(0,0,1,-1), C.BORDER)
    sep.BackgroundTransparency = 0.7

    local trackBg = MakeFrame(row, UDim2.new(1,0,0,4), UDim2.new(0,0,0,24), C.BORDER2)
    MakeCorner(trackBg,2)
    local fill = MakeFrame(trackBg, UDim2.fromScale(0,1), UDim2.new(0,0,0,0), C.ACCENT_DIM)
    MakeCorner(fill,2)
    local sThumb = MakeFrame(trackBg, UDim2.fromOffset(12,12), UDim2.new(0,-6,-1,0), C.ACCENT)
    MakeCorner(sThumb,6)

    local curVal = (Config[configKey] ~= nil) and Config[configKey] or defaultV

    local function setValue(v)
        v = math.clamp(math.round(v/step)*step, minV, maxV)
        curVal = v; Config[configKey] = v
        local pct = (v - minV) / (maxV - minV)
        fill.Size      = UDim2.new(pct,0,1,0)
        sThumb.Position = UDim2.new(pct,-6,-1,0)
        valLabel.Text  = ((step<1) and string.format("%.1f",v) or tostring(math.floor(v))) .. suffix
        if onChanged then onChanged(v) end
    end

    setValue(curVal)

    local sdrag = false
    trackBg.InputBegan:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1
        or inp.UserInputType==Enum.UserInputType.Touch then
            sdrag=true
            local pct=math.clamp((inp.Position.X-trackBg.AbsolutePosition.X)/trackBg.AbsoluteSize.X,0,1)
            setValue(minV+(maxV-minV)*pct)
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if not sdrag then return end
        if inp.UserInputType==Enum.UserInputType.MouseMovement
        or inp.UserInputType==Enum.UserInputType.Touch then
            local pct=math.clamp((inp.Position.X-trackBg.AbsolutePosition.X)/trackBg.AbsoluteSize.X,0,1)
            setValue(minV+(maxV-minV)*pct)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1
        or inp.UserInputType==Enum.UserInputType.Touch then sdrag=false end
    end)

    AddToTab(tabName, row)
    return setValue
end

local function TabDropdown(tabName, values, defaultVal, onChanged)
    local H = 28
    local itemH = 24

    -- [FIX] Pakai TextButton bukan Frame agar bisa terima input
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1,0,0,H)
    btn.BackgroundColor3 = C.BTN
    btn.BorderSizePixel  = 0
    btn.Text             = ""
    btn.ZIndex           = 9
    btn.AutoButtonColor  = false
    MakeCorner(btn,5); MakeStroke(btn,C.BORDER2,1)

    local lbl = MakeLabel(btn, defaultVal or (values[1] or "—"), 11, C.TEXT, Enum.Font.Gotham,
        UDim2.fromOffset(8,0), UDim2.new(1,-28,1,0), Enum.TextXAlignment.Left, 10)

    local arrowLbl = MakeLabel(btn,"▾",12,C.TEXT_DIM,Enum.Font.GothamBold,
        UDim2.new(1,-22,0,0),UDim2.fromOffset(20,H),Enum.TextXAlignment.Center,10)

    local open = false
    local dropList = nil
    local closeConn = nil

    local function closeDD()
        if dropList then dropList:Destroy(); dropList=nil end
        if closeConn then closeConn:Disconnect(); closeConn=nil end
        open=false; arrowLbl.Text="▾"
    end

    local function openDD()
        if open then closeDD(); return end
        open = true; arrowLbl.Text="▴"

        -- [FIX] AbsolutePosition hanya valid setelah 1 frame render
        task.defer(function()
            if not open then return end
            local ax = btn.AbsolutePosition.X
            local ay = btn.AbsolutePosition.Y + H
            local aw = btn.AbsoluteSize.X

            dropList = Instance.new("Frame")
            dropList.Size             = UDim2.fromOffset(aw, math.min(#values,6)*itemH)
            dropList.Position         = UDim2.fromOffset(ax, ay)
            dropList.BackgroundColor3 = C.BG2
            dropList.BorderSizePixel  = 0
            dropList.ZIndex           = 50
            dropList.Parent           = ScreenGui
            MakeCorner(dropList,5); MakeStroke(dropList,C.BORDER2,1)

            local ll = Instance.new("UIListLayout",dropList)
            ll.SortOrder = Enum.SortOrder.LayoutOrder

            for i,v in ipairs(values) do
                local item = Instance.new("TextButton")
                item.Size             = UDim2.new(1,0,0,itemH)
                item.BackgroundColor3 = C.BG2
                item.BorderSizePixel  = 0
                item.Text             = v
                item.TextSize         = 11
                item.TextColor3       = C.TEXT
                item.Font             = Enum.Font.Gotham
                item.TextXAlignment   = Enum.TextXAlignment.Left
                item.ZIndex           = 51
                item.AutoButtonColor  = false
                item.LayoutOrder      = i
                item.Parent           = dropList
                local p = Instance.new("UIPadding",item)
                p.PaddingLeft = UDim.new(0,8)
                item.MouseEnter:Connect(function() item.BackgroundColor3=C.BG3 end)
                item.MouseLeave:Connect(function() item.BackgroundColor3=C.BG2 end)
                item.MouseButton1Click:Connect(function()
                    lbl.Text = v
                    closeDD()
                    if onChanged then onChanged(v) end
                end)
            end

            -- [FIX] Close saat klik di luar dropdown — cek via posisi klik vs area dropdown
            closeConn = UserInputService.InputBegan:Connect(function(inp)
                if inp.UserInputType ~= Enum.UserInputType.MouseButton1
                and inp.UserInputType ~= Enum.UserInputType.Touch then return end
                if not open or not dropList then return end
                -- Cek apakah klik di dalam dropList atau btn
                local px, py = inp.Position.X, inp.Position.Y
                local dlPos  = dropList.AbsolutePosition
                local dlSize = dropList.AbsoluteSize
                local inDrop = px>=dlPos.X and px<=dlPos.X+dlSize.X
                           and py>=dlPos.Y and py<=dlPos.Y+dlSize.Y
                local bPos   = btn.AbsolutePosition
                local bSize  = btn.AbsoluteSize
                local inBtn  = px>=bPos.X and px<=bPos.X+bSize.X
                           and py>=bPos.Y and py<=bPos.Y+bSize.Y
                if not inDrop and not inBtn then
                    task.defer(closeDD)
                end
            end)
        end)
    end

    btn.MouseButton1Click:Connect(openDD)
    btn.MouseEnter:Connect(function() btn.BackgroundColor3=C.BTN_HOVER end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3=C.BTN end)

    AddToTab(tabName, btn)
    return lbl
end

-- ══════════════════════════════════════════════════════════
--  TAB CONTENTS
-- ══════════════════════════════════════════════════════════

-- ── SCAN data ──
local areaList  = ScanAllAreaTanam()
local areaNames = {}
for _,e in ipairs(areaList) do table.insert(areaNames,e.name) end
if #areaNames==0 then areaNames={"AreaTanam","AreaTanam2","AreaTanam3","AreaTanam4","AreaTanam5"} end
Config.SelectedArea = areaNames[1]
if AreaTanamData[areaNames[1]] then PlotPositions={AreaTanamData[areaNames[1]].position} end

local areaListB  = ScanAllAreaTanamBesar()
local areaNamesB = {}
for _,e in ipairs(areaListB) do table.insert(areaNamesB,e.name) end
if #areaNamesB==0 then for i=1,32 do table.insert(areaNamesB,"AreaTanamBesar"..i) end end
Config.SelectedAreaBesar = areaNamesB[1]
if AreaTanamBesarData[areaNamesB[1]] then PlotPositionsBesar={AreaTanamBesarData[areaNamesB[1]].position} end

-- ── INFO LABELS (update tiap detik) ──
local InfoFarmLbl  = TabInfoBox("Auto Farm","Plot: 0  |  Crop: 0 / 13")
local InfoBesarLbl = TabInfoBox("Sawit & Durian","Sawit: 0  |  Durian: 0  |  Lahan: -")
local InfoCoopLbl  = TabInfoBox("Auto Chicken","Kandang: Belum terdeteksi")

task.spawn(function()
    while true do task.wait(1)
        pcall(function()
            InfoFarmLbl.Text = ("Plot: %d  |  Crop: %d / %d"):format(
                #PlotPositions, GetOurCropCount(), Config.MaxPlant)
        end)
        pcall(function()
            local si = GetBesarSeedInfo()
            local lahan = Config.ClaimedAreaBesar or "-"
            InfoBesarLbl.Text = ("Sawit: %d  |  Durian: %d  |  %s"):format(si.sawit,si.durian,lahan)
        end)
        pcall(function()
            if Config.IsChickenBusy then
                InfoCoopLbl.Text = "Sedang urus kandang (farm di-pause)..."
                InfoCoopLbl.TextColor3 = C.ACCENT
            else
                InfoCoopLbl.Text = Config.ChickenCoopName
                    and ("Kandang: %s"):format(Config.ChickenCoopName)
                    or "Kandang: Belum terdeteksi"
                InfoCoopLbl.TextColor3 = C.ACCENT
            end
        end)
    end
end)

-- ────────────────────────────────────────────
--  TAB: AUTO FARM
-- ────────────────────────────────────────────
TabSection("Auto Farm","Lahan")
TabDropdown("Auto Farm", areaNames, areaNames[1], function(v)
    Config.SelectedArea = v
    SavedCirclePositions = {}
    if AreaTanamData[v] then
        PlotPositions = {AreaTanamData[v].position}
        TeleportTo(CFrame.new(AreaTanamData[v].position+Vector3.new(0,4,0)))
        Notify("Axorz Hub", v.." dipilih!")
    else PlotPositions={}; Notify("Axorz Hub",v.." tidak ditemukan.") end
end)
TabButton("Auto Farm","Teleport ke Lahan",function()
    if Config.SelectedArea and AreaTanamData[Config.SelectedArea] then
        TeleportTo(CFrame.new(AreaTanamData[Config.SelectedArea].position+Vector3.new(0,4,0)))
        Notify("Axorz Hub","Teleport ke "..Config.SelectedArea)
    else Notify("Axorz Hub","Pilih lahan dulu!") end
end, true)
TabButton("Auto Farm","Clear Crop Data",function()
    OurCrops={}; PendingPlantPos={}; SavedCirclePositions={}
    Notify("Axorz Hub","Data crop dihapus.")
end)

TabSection("Auto Farm","Benih")
local SeedDDlbl = TabDropdown("Auto Farm", SeedNames, SeedNames[1], function(v)
    Config.SelectedSeed = v; Notify("Axorz Hub","Benih: "..v)
end)
TabButton("Auto Farm","Refresh List Benih",function()
    local nn = BuildSeedList()
    if #nn>0 then
        SeedNames = nn; Config.SelectedSeed = nn[1]
        SeedDDlbl.Text = nn[1]
        Notify("Axorz Hub","Benih diperbarui!")
    else Notify("Axorz Hub","Tidak ada benih di backpack.") end
end)

TabSection("Auto Farm","Toggle")
TabToggle("Auto Farm","Auto Farm All","Harvest + Plant + Sell","AutoFarm",function(v)
    if v then Config.AutoHarvest=false; Config.AutoPlant=false; Config.AutoSell=false
        if Config.AutoFarmBesar and Config.AutoFeed and Config.AutoClaimEgg then
            Notify("Auto Farm All","🌾 Auto Farm All aktif!")
        end
    end
end)
TabToggle("Auto Farm","Auto Harvest",nil,"AutoHarvest",function(v) if v then Config.AutoFarm=false end end)
TabToggle("Auto Farm","Auto Plant",nil,"AutoPlant",function(v) if v then Config.AutoFarm=false end end)

TabSection("Auto Farm","Pengaturan")
TabSlider("Auto Farm","Max Tanaman",0,25,13,1,"","MaxPlant")
TabSlider("Auto Farm","Plant Cycle Delay",0.3,5.0,2.0,0.1,"s","CycleDelay")
TabToggle("Auto Farm","Circle Plant Mode",nil,"UseCircle")
TabSlider("Auto Farm","Radius Lingkaran",2,20,5,1," studs","CircleRadius",function(v)
    SavedCirclePositions={}
end)

-- ────────────────────────────────────────────
--  TAB: SAWIT & DURIAN
-- ────────────────────────────────────────────
TabWarning("Sawit & Durian",
    "⚠ Claim lahan terlebih dahulu!\nDisarankan gunakan 'Claim Lahan Kosong'.\nJika sudah punya lahan, klik 'Detect Lahan Saya'.")

local ClaimStatusLbl = TabInfoBox("Sawit & Durian","Lahan: Belum di-claim")
task.spawn(function()
    while true do task.wait(1) pcall(function()
        ClaimStatusLbl.Text = Config.ClaimedAreaBesar
            and ("Lahan: %s ✓"):format(Config.ClaimedAreaBesar)
            or "Lahan: Belum di-claim"
    end) end
end)
TabButton("Sawit & Durian","Detect Lahan Saya",function()
    task.spawn(function()
        local found = DetectLahanSaya()
        if found then Notify("Axorz Hub","✅ "..found.." terdeteksi!")
        else Notify("Axorz Hub","❌ Berdiri di atas lahanmu!") end
    end)
end, true)
TabButton("Sawit & Durian","Claim Lahan Kosong",function()
    task.spawn(function() pcall(DoClaimLahan) end)
end)
TabButton("Sawit & Durian","Teleport ke Lahan Besar",function()
    if Config.ClaimedAreaBesar and AreaTanamBesarData[Config.ClaimedAreaBesar] then
        TeleportTo(CFrame.new(AreaTanamBesarData[Config.ClaimedAreaBesar].position+Vector3.new(0,4,0)))
    else Notify("Axorz Hub","Claim lahan dulu!") end
end)
TabButton("Sawit & Durian","Clear Crop Besar Data",function()
    OurCropsBesar={}; Notify("Axorz Hub","Data crop besar dihapus.")
end)

TabSection("Sawit & Durian","Toggle")
TabToggle("Sawit & Durian","Auto Farm Besar","Harvest + Plant","AutoFarmBesar",function(v)
    if v then Config.AutoHarvestBesar=false; Config.AutoPlantBesar=false
        if Config.AutoFarm and Config.AutoFeed and Config.AutoClaimEgg then
            Notify("Auto Farm All","🌾 Auto Farm All aktif!")
        end
    end
end)
TabToggle("Sawit & Durian","Auto Harvest Besar",nil,"AutoHarvestBesar",function(v)
    if v then Config.AutoFarmBesar=false end
end)
TabToggle("Sawit & Durian","Auto Plant Besar",nil,"AutoPlantBesar",function(v)
    if v then Config.AutoFarmBesar=false end
end)

-- ────────────────────────────────────────────
--  TAB: AUTO CHICKEN
-- ────────────────────────────────────────────
TabWarning("Auto Chicken",
    "⚠ Detect kandang terlebih dahulu!\nBelum punya kandang? Klik 'Claim Kandang Kosong'.\nSudah punya? Klik 'Detect Kandang'.")

TabButton("Auto Chicken","Detect Kandang",function()
    task.spawn(function()
        local coop=FindMyCoopPlot()
        if coop then
            Config.ChickenCoopName=coop.Name; SetupEggWatcher(coop)
            Notify("Chicken","✅ "..coop.Name)
        else Notify("Chicken","❌ Kandang tidak ditemukan!") end
    end)
end, true)
TabButton("Auto Chicken","Claim Kandang Kosong (Auto)",function()
    task.spawn(function()
        local ok, name = DoClaimCoop()
        if ok then
            Notify("Chicken","✅ Berhasil claim: "..(name or "?"))
        end
    end)
end)
TabButton("Auto Chicken","Teleport ke Kandang",function()
    local coop=Config.ChickenCoopName and workspace:FindFirstChild(Config.ChickenCoopName)
    if not coop then coop=FindMyCoopPlot() end
    if coop then
        local bp=coop:FindFirstChildWhichIsA("BasePart")
        if bp then TeleportTo(CFrame.new(bp.Position+Vector3.new(0,5,0))) end
        Notify("Chicken","Teleport ke kandang!")
    else Notify("Chicken","Kandang tidak ditemukan!") end
end)

TabSection("Auto Chicken","Feed")
TabButton("Auto Chicken","Feed Sekarang (Manual)",function()
    task.spawn(function() FeedDebounce=false; pcall(DoFeedChicken) end)
end)
TabToggle("Auto Chicken","Auto Feed Ayam",nil,"AutoFeed",function(v)
    if v then
        local coop=Config.ChickenCoopName and workspace:FindFirstChild(Config.ChickenCoopName)
        if not coop then coop=FindMyCoopPlot() end
        if coop then Config.ChickenCoopName=coop.Name; SetupEggWatcher(coop) end
        task.spawn(function() FeedDebounce=false; pcall(DoFeedChicken) end)
        Notify("Chicken","🐔 Auto Feed ON!")
        if Config.AutoFarm and Config.AutoFarmBesar and Config.AutoClaimEgg then
            Notify("Auto Farm All","🌾 Auto Farm All aktif!")
        end
    end
end)
TabSlider("Auto Chicken","Feed Delay",0.1,2.0,0.3,0.1,"s","FeedDelay")

TabSection("Auto Chicken","Telur")
TabButton("Auto Chicken","Claim Telur (Manual)",function()
    task.spawn(function() ClaimEggDebounce=false; pcall(DoClaimEgg) end)
end)
TabToggle("Auto Chicken","Auto Claim Telur",nil,"AutoClaimEgg",function(v)
    if v then
        local coop=Config.ChickenCoopName and workspace:FindFirstChild(Config.ChickenCoopName)
        if not coop then coop=FindMyCoopPlot() end
        if coop then Config.ChickenCoopName=coop.Name; SetupEggWatcher(coop) end
        task.spawn(function() task.wait(0.5); ClaimEggDebounce=false; if coop then SetupEggWatcher(coop) end end)
        Notify("Chicken","🥚 Auto Claim ON!")
        if Config.AutoFarm and Config.AutoFarmBesar and Config.AutoFeed then
            Notify("Auto Farm All","🌾 Auto Farm All aktif!")
            if not Config.ClaimedAreaBesar then task.spawn(function() pcall(DetectLahanSaya) end) end
        end
    else
        for _, conn in pairs(EggWatcherConns) do pcall(function() conn:Disconnect() end) end
        EggWatcherConns = {}; EggWatcherConn = nil
    end
end)
TabSlider("Auto Chicken","Claim Delay",0.1,2.0,0.3,0.1,"s","ClaimDelay")
TabToggle("Auto Chicken","Auto Sell Telur",nil,"AutoSellEgg",function(v)
    if v then task.spawn(function() pcall(DoSellEgg) end) end
end)

-- ────────────────────────────────────────────
--  TAB: AUTO SELL
-- ────────────────────────────────────────────
TabSection("Auto Sell","Tanaman Biasa")
TabButton("Auto Sell","Jual Sekarang (Tanaman)",function() task.spawn(function() pcall(DoSell) end) end)
TabToggle("Auto Sell","Auto Sell Tanaman",nil,"AutoSell",function(v)
    if v then Config.AutoFarm=false end
end)

TabSection("Auto Sell","Sawit & Durian")
TabButton("Auto Sell","Jual Sekarang (Sawit/Durian)",function() task.spawn(function() pcall(DoSellCrop) end) end)
TabToggle("Auto Sell","Auto Sell Crop Besar",nil,"AutoSellCrop")

TabSection("Auto Sell","Telur")
TabButton("Auto Sell","Jual Telur Sekarang",function() task.spawn(function() pcall(DoSellEgg) end) end)
TabToggle("Auto Sell","Auto Sell Telur",nil,"AutoSellEgg",function(v)
    if v then task.spawn(function() pcall(DoSellEgg) end) end
end)

-- ────────────────────────────────────────────
--  TAB: AUTO BUY
-- ────────────────────────────────────────────
local shopNames = {"Bibit Padi","Bibit Jagung","Bibit Tomat","Bibit Terong","Bibit Strawberry","Bibit Sawit","Bibit Durian"}
Config.SelectedBuy = shopNames[1]
task.spawn(function()
    local ok,result = pcall(function() return RemoteShop:InvokeServer("GET_LIST") end)
    if ok and type(result)=="table" then
        local nn={}; for _,item in pairs(result) do if type(item)=="table" and item.Name then table.insert(nn,item.Name) end end
        if #nn>0 then shopNames=nn; Config.SelectedBuy=shopNames[1] end
    end
end)
TabDropdown("Auto Buy", shopNames, shopNames[1], function(v) Config.SelectedBuy=v end)
TabSlider("Auto Buy","Jumlah per Cycle",1,100,10,1,"","BuyAmount")
TabSlider("Auto Buy","Buy Interval",5,60,10,1,"s","BuyDelay")
TabToggle("Auto Buy","Auto Buy",nil,"AutoBuy")
TabButton("Auto Buy","Beli Sekarang",function()
    if Config.SelectedBuy then task.spawn(pcall,DoBuy)
        Notify("Axorz Hub",Config.SelectedBuy.." x"..Config.BuyAmount)
    end
end, true)

-- ────────────────────────────────────────────
--  TAB: PLAYER
-- ────────────────────────────────────────────
TabSection("Player","Kecepatan")
TabSlider("Player","Walk Speed",0,100,16,1,"","WalkSpeed")
TabButton("Player","Reset Speed",function()
    Config.WalkSpeed=16
    local hum=GetHumanoid(); if hum then hum.WalkSpeed=16 end
end)

task.spawn(function() while true do task.wait(0.1)
    local hum=GetHumanoid()
    if hum and not Config.Freeze and not Config.GlobalPause then hum.WalkSpeed=Config.WalkSpeed end
end end)

UserInputService.JumpRequest:Connect(function()
    if Config.InfiniteJump then
        local hum=GetHumanoid(); if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

TabSection("Player","Kemampuan")
TabToggle("Player","Infinite Jump",nil,"InfiniteJump")
TabToggle("Player","Freeze Player",nil,"Freeze",function(v)
    if not v then
        local hrp=GetHRP(); local hum=GetHumanoid()
        if hrp then hrp.Anchored=false end
        if hum then hum.WalkSpeed=Config.WalkSpeed; hum.JumpHeight=7.2 end
    end
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    local hum=char:FindFirstChildOfClass("Humanoid")
    local hrp=char:FindFirstChild("HumanoidRootPart")
    if hum then hum.WalkSpeed=Config.Freeze and 0 or Config.WalkSpeed; hum.JumpHeight=Config.Freeze and 0 or 7.2 end
    if hrp then hrp.Anchored=Config.Freeze end
end)

-- ────────────────────────────────────────────
--  TAB: ESP
-- ────────────────────────────────────────────
TabSection("ESP","Crop ESP")
TabToggle("ESP","Enable ESP","Tampilkan progress tanaman","ESPEnabled",function(v)
    if not v then ClearAllESP() end
end)
TabToggle("ESP","Tampilkan Semua Player",nil,"ESPShowAll")
TabButton("ESP","Refresh ESP",function() ClearAllESP() end)

-- ────────────────────────────────────────────
--  TAB: ANTI-AFK
-- ────────────────────────────────────────────
local afkInfoLbl = TabInfoBox("Anti-AFK","Aktif — klik tiap 18 menit")
task.spawn(function() while true do task.wait(1) pcall(function()
    afkInfoLbl.Text = Config.AntiAFK
        and ("Aktif ✓  —  klik tiap %d menit"):format(Config.AntiAFKDelay)
        or "Nonaktif ✗"
end) end end)
TabToggle("Anti-AFK","Enable Anti-AFK",nil,"AntiAFK",function(v)
    if v then StartAntiAFK()
    else if AntiAFKThread then task.cancel(AntiAFKThread); AntiAFKThread=nil end end
end)
TabSlider("Anti-AFK","Interval (menit)",10,19,18,1," mnt","AntiAFKDelay",function(v)
    if Config.AntiAFK then StartAntiAFK() end
end)
TabButton("Anti-AFK","Test Klik AFK",function()
    VirtualUser:Button2Down(Vector2.new(0,0),workspace.CurrentCamera.CFrame)
    task.wait(1); VirtualUser:Button2Up(Vector2.new(0,0),workspace.CurrentCamera.CFrame)
    Notify("Axorz Hub","Test klik berhasil!")
end, true)

-- ──────────────────────────────────────────────────────────
--  FLOATING BUTTON
--  Hanya muncul saat di-minimize. Hidden saat GUI terbuka.
-- ──────────────────────────────────────────────────────────
local FloatFrame = Instance.new("Frame")
FloatFrame.Size                   = UDim2.fromOffset(FLOAT_SIZE, FLOAT_SIZE)
-- [FIX] Posisi awal pakai pure Offset agar drag tidak loncat
-- Tengah horizontal, ~25% dari atas layar
local floatInitX = math.floor(SW/2 - FLOAT_SIZE/2)
local floatInitY = math.floor(SH * 0.25)
FloatFrame.Position               = UDim2.fromOffset(floatInitX, floatInitY)
FloatFrame.BackgroundTransparency = 1
FloatFrame.BorderSizePixel        = 0
FloatFrame.ZIndex                 = 20
FloatFrame.Visible                = false
FloatFrame.Parent                 = ScreenGui

-- Logo mengisi penuh, pakai Stretch agar pas kotak
local logoImg = Instance.new("ImageLabel")
logoImg.Size                   = UDim2.fromOffset(FLOAT_SIZE, FLOAT_SIZE)
logoImg.Position               = UDim2.fromOffset(0, 0)
logoImg.BackgroundTransparency = 1
logoImg.Image                  = "rbxassetid://107722941347463"
logoImg.ScaleType              = Enum.ScaleType.Stretch
logoImg.ZIndex                 = 21
logoImg.Parent                 = FloatFrame
Instance.new("UICorner", logoImg).CornerRadius = UDim.new(0, 10)

-- TextButton transparan di atas logo untuk handle klik & drag
local floatClickBtn = Instance.new("TextButton")
floatClickBtn.Size                   = UDim2.fromOffset(FLOAT_SIZE, FLOAT_SIZE)
floatClickBtn.Position               = UDim2.fromOffset(0, 0)
floatClickBtn.BackgroundTransparency = 1
floatClickBtn.Text                   = ""
floatClickBtn.ZIndex                 = 22
floatClickBtn.AutoButtonColor        = false
floatClickBtn.Parent                 = FloatFrame

-- ──────────────────────────────────────────────────────────
--  MINIMIZE & CLOSE LOGIC
-- ──────────────────────────────────────────────────────────

local function DoMinimize()
    MainFrame.Visible  = false
    FloatFrame.Visible = true
end

local function DoRestore()
    MainFrame.Visible  = true
    FloatFrame.Visible = false
end

-- ── CONFIRM DIALOG (muncul sebelum close) ──
local function ShowConfirmClose()
    -- Overlay gelap
    local overlay = Instance.new("Frame")
    overlay.Size                   = UDim2.fromScale(1,1)
    overlay.Position               = UDim2.fromScale(0,0)
    overlay.BackgroundColor3       = Color3.fromRGB(0,0,0)
    overlay.BackgroundTransparency = 0.45
    overlay.BorderSizePixel        = 0
    overlay.ZIndex                 = 30
    overlay.Parent                 = MainFrame

    -- Dialog box
    local DW, DH = IS_MOBILE and 260 or 240, IS_MOBILE and 130 or 116
    local dialog = Instance.new("Frame")
    dialog.Size              = UDim2.fromOffset(DW, DH)
    dialog.Position          = UDim2.new(0.5,-DW/2, 0.5,-DH/2)
    dialog.BackgroundColor3  = C.BG2
    dialog.BorderSizePixel   = 0
    dialog.ZIndex            = 31
    dialog.Parent            = MainFrame
    MakeCorner(dialog, 8)
    MakeStroke(dialog, C.BORDER2, 1)

    -- Icon + judul
    MakeLabel(dialog,"Tutup Axorz Hub?", IS_MOBILE and 14 or 13, C.WHITE,
        Enum.Font.GothamBold,
        UDim2.fromOffset(0,16), UDim2.new(1,0,0,22),
        Enum.TextXAlignment.Center, 32)

    -- Sub text
    MakeLabel(dialog,"GUI akan di-unload sepenuhnya.", IS_MOBILE and 12 or 11, C.TEXT_DIM,
        Enum.Font.Gotham,
        UDim2.fromOffset(0,40), UDim2.new(1,0,0,18),
        Enum.TextXAlignment.Center, 32)

    -- Separator
    local sep = MakeFrame(dialog, UDim2.new(1,-24,0,1), UDim2.fromOffset(12,66), C.BORDER)
    sep.BackgroundTransparency = 0.5

    -- Tombol BATAL
    local btnBatal = Instance.new("TextButton")
    btnBatal.Size             = UDim2.fromOffset((DW-36)/2, IS_MOBILE and 34 or 28)
    btnBatal.Position         = UDim2.fromOffset(12, 74)
    btnBatal.BackgroundColor3 = C.BTN
    btnBatal.BorderSizePixel  = 0
    btnBatal.Text             = "Batal"
    btnBatal.TextSize         = IS_MOBILE and 13 or 12
    btnBatal.TextColor3       = C.TEXT
    btnBatal.Font             = Enum.Font.Gotham
    btnBatal.ZIndex           = 32
    btnBatal.AutoButtonColor  = false
    btnBatal.Parent           = dialog
    MakeCorner(btnBatal, 6)
    MakeStroke(btnBatal, C.BORDER2, 1)
    btnBatal.MouseEnter:Connect(function() btnBatal.BackgroundColor3=C.BTN_HOVER end)
    btnBatal.MouseLeave:Connect(function() btnBatal.BackgroundColor3=C.BTN end)
    btnBatal.MouseButton1Click:Connect(function()
        overlay:Destroy(); dialog:Destroy()
    end)

    -- Tombol TUTUP (merah)
    local btnClose = Instance.new("TextButton")
    btnClose.Size             = UDim2.fromOffset((DW-36)/2, IS_MOBILE and 34 or 28)
    btnClose.Position         = UDim2.fromOffset(DW/2+6, 74)
    btnClose.BackgroundColor3 = Color3.fromRGB(160,30,30)
    btnClose.BorderSizePixel  = 0
    btnClose.Text             = "Tutup"
    btnClose.TextSize         = IS_MOBILE and 13 or 12
    btnClose.TextColor3       = C.WHITE
    btnClose.Font             = Enum.Font.GothamBold
    btnClose.ZIndex           = 32
    btnClose.AutoButtonColor  = false
    btnClose.Parent           = dialog
    MakeCorner(btnClose, 6)
    btnClose.MouseEnter:Connect(function() btnClose.BackgroundColor3=Color3.fromRGB(200,40,40) end)
    btnClose.MouseLeave:Connect(function() btnClose.BackgroundColor3=Color3.fromRGB(160,30,30) end)
    btnClose.MouseButton1Click:Connect(function()
        pcall(function() ScreenGui:Destroy() end)
        print("[Axorz Hub v3.0] GUI di-unload.")
    end)

    -- Klik overlay = batal
    overlay.InputBegan:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1
        or inp.UserInputType==Enum.UserInputType.Touch then
            overlay:Destroy(); dialog:Destroy()
        end
    end)

    -- Animasi masuk
    dialog.Position = UDim2.new(0.5,-DW/2, 0.5,-DH/2+10)
    dialog.BackgroundTransparency = 1
    TweenService:Create(dialog,TweenInfo.new(0.18),{
        Position=UDim2.new(0.5,-DW/2,0.5,-DH/2),
        BackgroundTransparency=0
    }):Play()
end

-- Tombol kuning (minimize)
local minOff = -(BTN_SIZE + BTN_GAP + BTN_SIZE + BTN_GAP)
MakeTitleBtn(Color3.fromRGB(243,156,18), minOff, DoMinimize)
-- Tombol merah (close — buka confirm dulu)
MakeTitleBtn(Color3.fromRGB(231,76,60), -(BTN_SIZE + BTN_GAP), ShowConfirmClose)

-- Float button: klik restore, bisa drag
local fDrag, fDragStart, fFrameStart = false, nil, nil
local FDRAG_THRESH = 8

floatClickBtn.InputBegan:Connect(function(inp)
    if inp.UserInputType==Enum.UserInputType.MouseButton1
    or inp.UserInputType==Enum.UserInputType.Touch then
        fDrag      = true
        fDragStart = Vector2.new(inp.Position.X, inp.Position.Y)
        fFrameStart = FloatFrame.Position
    end
end)
UserInputService.InputChanged:Connect(function(inp)
    if not fDrag or not fDragStart then return end
    if inp.UserInputType==Enum.UserInputType.MouseMovement
    or inp.UserInputType==Enum.UserInputType.Touch then
        local d = Vector2.new(inp.Position.X,inp.Position.Y) - fDragStart
        FloatFrame.Position = UDim2.fromOffset(
            fFrameStart.X.Offset+d.X,
            fFrameStart.Y.Offset+d.Y)
    end
end)
floatClickBtn.InputEnded:Connect(function(inp)
    if not fDrag or not fDragStart then return end
    if inp.UserInputType==Enum.UserInputType.MouseButton1
    or inp.UserInputType==Enum.UserInputType.Touch then
        local moved = (Vector2.new(inp.Position.X,inp.Position.Y)-fDragStart).Magnitude
        fDrag=false; fDragStart=nil; fFrameStart=nil
        if moved < FDRAG_THRESH then
            DoRestore()
        end
    end
end)

-- ──────────────────────────────────────────────────────────
--  DRAG TITLEBAR
-- ──────────────────────────────────────────────────────────
local dragActive = false
local dragStart, frameStart

TitleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType==Enum.UserInputType.MouseButton1
    or inp.UserInputType==Enum.UserInputType.Touch then
        dragActive = true
        dragStart  = Vector2.new(inp.Position.X, inp.Position.Y)
        frameStart = MainFrame.Position
    end
end)
UserInputService.InputChanged:Connect(function(inp)
    if not dragActive then return end
    if inp.UserInputType==Enum.UserInputType.MouseMovement
    or inp.UserInputType==Enum.UserInputType.Touch then
        local delta = Vector2.new(inp.Position.X,inp.Position.Y) - dragStart
        MainFrame.Position = UDim2.fromOffset(
            frameStart.X.Offset + delta.X,
            frameStart.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType==Enum.UserInputType.MouseButton1
    or inp.UserInputType==Enum.UserInputType.Touch then dragActive=false end
end)

-- ── Set default tab ──
SwitchTab("Auto Farm")

-- ── Welcome notify ──
task.delay(0.5, function()
    Notify("Axorz Hub v3.0","✅ GUI aktif! Kuning = minimize, Merah = close.")
end)

print("[Axorz Hub v3.0] Custom GUI loaded. No Fluent dependency.")
