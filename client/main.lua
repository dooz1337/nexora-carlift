-- carlift client: ox_target options, vehicle (de)attach on the server's request, admin placement preview.
-- No position authority here: the server decides locking, raising and lowering.
local ESX = exports['es_extended']:getSharedObject()

local isAdmin = false
local attached = {}          -- [vehicle netId] = true (vehicles this client attached for a lift)

local function notify(ok, key, ...)
    lib.notify({ type = ok and 'success' or 'error', description = L(key, ...) })
end

-- Targeting -------------------------------------------------------------------------------------

local function liftState(entity)
    local st = Entity(entity).state
    return st.carliftId, st.carliftState, st.carliftLocked
end

-- Client-side job check is only a UI hint; the server re-checks everything.
local function jobHint()
    if not Config.JobRestriction or next(Config.AllowedJobs) == nil then return true end
    local job = ESX.GetPlayerData().job
    local minGrade = job and Config.AllowedJobs[job.name]
    return minGrade ~= nil and (job.grade or 0) >= minGrade
end

local function vehicleOnPlatform(entity)
    local c = Entity(entity).state.carliftCenter or GetEntityCoords(entity)
    return lib.getClosestVehicle(c, Config.LockRadius, true) ~= nil
end

local function runAction(action, entity)
    local id = Entity(entity).state.carliftId
    if not id then return end
    local ok, key = lib.callback.await('carlift:action', false, action, id)
    notify(ok, key)
end

-- Model targets on the lift's vanilla objects (the column and the platform model); all three carry the
-- carliftId/state bags set by the server.
local function buildOptions()
    local dist = Config.Target.Distance
    local icons = Config.Target.Icons
    return {
        {
            name = 'carlift_lock', icon = icons.lock, label = L('target_lock'), distance = dist,
            canInteract = function(entity)
                local id, state, locked = liftState(entity)
                return id and state == 'down' and not locked and jobHint() and vehicleOnPlatform(entity)
            end,
            onSelect = function(data) runAction('lock', data.entity) end,
        },
        {
            name = 'carlift_unlock', icon = icons.unlock, label = L('target_unlock'), distance = dist,
            canInteract = function(entity)
                local id, state, locked = liftState(entity)
                return id and state == 'down' and locked and jobHint()
            end,
            onSelect = function(data) runAction('unlock', data.entity) end,
        },
        {
            name = 'carlift_raise', icon = icons.raise, label = L('target_raise'), distance = dist,
            canInteract = function(entity)
                local id, state, locked = liftState(entity)
                return id and state == 'down' and locked and jobHint()
            end,
            onSelect = function(data) runAction('raise', data.entity) end,
        },
        {
            name = 'carlift_lower', icon = icons.lower, label = L('target_lower'), distance = dist,
            canInteract = function(entity)
                local id, state = liftState(entity)
                return id and state == 'up' and jobHint()
            end,
            onSelect = function(data) runAction('lower', data.entity) end,
        },
        {
            name = 'carlift_delete', icon = icons.delete, label = L('target_delete'), distance = dist,
            canInteract = function(entity) return isAdmin and Entity(entity).state.carliftId ~= nil end,
            onSelect = function(data)
                local id = Entity(data.entity).state.carliftId
                if not id then return end
                local ok, key = lib.callback.await('carlift:delete', false, id)
                notify(ok, key)
            end,
        },
    }
end

local OPTION_NAMES = { 'carlift_lock', 'carlift_unlock', 'carlift_raise', 'carlift_lower', 'carlift_delete' }
local TARGET_MODELS = { Config.DefaultProp, Config.ColProp }

local function registerTargets()
    for _, model in ipairs(TARGET_MODELS) do
        exports.ox_target:addModel(model, buildOptions())
    end
end
registerTargets()

RegisterNetEvent('carlift:client:adminState', function(state) isAdmin = state == true end)

local function init()
    isAdmin = lib.callback.await('carlift:isAdmin', false) == true
end

CreateThread(function()
    if ESX.IsPlayerLoaded() then init() end
end)
RegisterNetEvent('esx:playerLoaded', function() init() end)

-- Smooth platform movement ---------------------------------------------------------------------------------------
-- The server does not step the platform over the network (that looked jerky). It tells every client the start/end
-- height and duration; each client moves the platform entity every frame with the same smoothstep curve.
local moves = {}   -- [platform netId] = token of the move currently running

local function platformEntity(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e ~= 0 and DoesEntityExist(e) then return e end
end

RegisterNetEvent('carlift:client:move', function(netId, fromZ, toZ, duration, elapsed)
    local token = {}
    moves[netId] = token
    local t0 = GetGameTimer() - (elapsed or 0)   -- elapsed > 0: joined mid-move, continue on the same curve
    CreateThread(function()
        while moves[netId] == token do
            local e = platformEntity(netId)
            if not e then break end
            local p = math.min(1.0, (GetGameTimer() - t0) / duration)
            local k = p * p * (3.0 - 2.0 * p)
            local c = GetEntityCoords(e)
            SetEntityCoordsNoOffset(e, c.x, c.y, fromZ + (toZ - fromZ) * k, false, false, false)
            if p >= 1.0 then break end
            Wait(0)
        end
        if moves[netId] == token then moves[netId] = nil end
    end)
end)

RegisterNetEvent('carlift:client:moveStop', function(netId, z)
    moves[netId] = nil
    local e = platformEntity(netId)
    if e then
        local c = GetEntityCoords(e)
        SetEntityCoordsNoOffset(e, c.x, c.y, z, false, false, false)
    end
end)

-- Arrival sync ------------------------------------------------------------------------------------------------
-- When a lift platform streams in for this player, ask the server for its current state: a move in progress (joined
-- mid-move) or the exact resting height.
local platHash = joaat(Config.ColProp)
local knownPlatforms = {}

CreateThread(function()
    while true do
        local seen = {}
        local pc = GetEntityCoords(cache.ped)
        for _, e in ipairs(GetGamePool('CObject')) do
            if GetEntityModel(e) == platHash and #(pc - GetEntityCoords(e)) < Config.SyncRadius + 100.0 then
                local id = Entity(e).state.carliftId
                if id then
                    seen[e] = true
                    if not knownPlatforms[e] then TriggerServerEvent('carlift:server:requestSync', id) end
                end
            end
        end
        knownPlatforms = seen
        Wait(1000)
    end
end)

-- Vehicle attach / detach (requested by the server, executed by the vehicle's network owner) ----------------

local function getEntity(netId, timeout)
    local deadline = GetGameTimer() + timeout
    while GetGameTimer() < deadline do
        if NetworkDoesNetworkIdExist(netId) then
            local e = NetworkGetEntityFromNetworkId(netId)
            if e ~= 0 and DoesEntityExist(e) then return e end
        end
        Wait(50)
    end
end

local function detach(veh)
    if not DoesEntityExist(veh) then return end
    if not NetworkHasControlOfEntity(veh) then NetworkRequestControlOfEntity(veh) end
    DetachEntity(veh, true, true)
    FreezeEntityPosition(veh, false)
    SetVehicleDoorsLocked(veh, 1)
end

lib.callback.register('carlift:client:attach', function(vehNet, liftNet, offset, rot)
    if type(offset) ~= 'vector3' then return false end
    local veh = getEntity(vehNet, 2500)
    local lift = getEntity(liftNet, 2500)
    if not veh or not lift then return false end

    local deadline = GetGameTimer() + 1500
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < deadline do
        NetworkRequestControlOfEntity(veh)
        Wait(50)
    end
    if not NetworkHasControlOfEntity(veh) then return false end

    -- Height from the deck and the car's own model, not from where the car stood when locked (that measurement put
    -- the tyres into the runways). Position/heading are untouched, collision stays on.
    local dmin = GetModelDimensions(GetEntityModel(veh))
    local z = Config.DeckZ - dmin.z + Config.DeckMargin
    if Config.Debug then
        print(('[carlift] attach: server z=%.2f, deck-based z=%.2f (model bottom %.2f)'):format(offset.z, z, dmin.z))
    end
    offset = vec3(offset.x, offset.y, z)

    SetVehicleEngineOn(veh, false, true, true)
    SetVehicleDoorsLocked(veh, 2)
    -- bone 0, collision ON (players can walk around it, interact with it and repair it), fixed rotation
    AttachEntityToEntity(veh, lift, 0, offset.x, offset.y, offset.z, 0.0, 0.0, rot + 0.0, false, false, true, false, 2, true)
    if Config.FreezeVehicle then FreezeEntityPosition(veh, true) end
    attached[vehNet] = true
    return true
end)

lib.callback.register('carlift:client:detach', function(vehNet)
    attached[vehNet] = nil
    local veh = getEntity(vehNet, 1500)
    if not veh then return false end
    detach(veh)
    return true
end)

RegisterNetEvent('carlift:client:release', function(vehNet)
    attached[vehNet] = nil
    if NetworkDoesNetworkIdExist(vehNet) then
        local veh = NetworkGetEntityFromNetworkId(vehNet)
        if veh ~= 0 then detach(veh) end
    end
end)

-- Admin placement ----------------------------------------------------------------------------------------

local placing = false
local preview, preview2, preview3

local function startPlacement()
    if placing then return end
    if not lib.callback.await('carlift:isAdmin', false) then notify(false, 'err_permission') return end
    placing = true

    local model = joaat(Config.DefaultProp)
    if not IsModelInCdimage(model) then
        placing = false
        notify(false, 'err_invalid')
        return
    end
    lib.requestModel(model)

    local pc = GetEntityCoords(cache.ped)
    local function ghost(m)
        if not IsModelInCdimage(m) or not lib.requestModel(m) then return nil end
        local e = CreateObject(m, pc.x, pc.y, pc.z, false, false, false)
        SetModelAsNoLongerNeeded(m)
        SetEntityAlpha(e, 160, false)
        SetEntityCollision(e, false, false)
        FreezeEntityPosition(e, true)
        return e
    end
    preview = ghost(model)                    -- left column (also the raycast reference)
    preview3 = ghost(model)                   -- right column
    preview2 = ghost(joaat(Config.ColProp))   -- platform
    if not preview then placing = false notify(false, 'err_invalid') return end

    local heading = GetEntityHeading(cache.ped)
    local lastHit
    local result

    lib.showTextUI(L('place_help'))

    -- raycast result arrives a frame later, so it runs in its own thread
    CreateThread(function()
        while placing do
            local hit, _, endCoords = lib.raycast.fromCamera(511, preview, Config.Placement.AimDistance)
            if hit and endCoords then lastHit = endCoords end
        end
    end)

    while placing do
        -- Esc must not open the pause menu, E/arrows belong to the tool
        DisableControlAction(0, 199, true)
        DisableControlAction(0, 200, true)
        DisableControlAction(0, 202, true)
        DisableControlAction(0, 38, true)
        DisableControlAction(0, 24, true)
        DisableControlAction(0, 25, true)
        DisableControlAction(0, 140, true)
        if IsPauseMenuActive() then SetPauseMenuActive(false) end

        local step = IsControlPressed(0, 21) and 0.5 or 2.5 -- SHIFT = fine
        if IsControlPressed(0, 174) then heading = (heading + step) % 360.0 end
        if IsControlPressed(0, 175) then heading = (heading - step) % 360.0 end

        if lastHit then
            local h = math.rad(heading)
            local ch, sh = math.cos(h), math.sin(h)
            local function put(e, lx, ly, z, hd)
                if not e then return end
                SetEntityCoordsNoOffset(e, lastHit.x + lx * ch - ly * sh, lastHit.y + lx * sh + ly * ch, z, false, false, false)
                SetEntityHeading(e, hd)
            end
            put(preview, -Config.ColumnX, 0.0, lastHit.z, heading)
            put(preview3, Config.ColumnX, 0.0, lastHit.z, heading + 180.0)
            put(preview2, 0.0, 0.0, lastHit.z + Config.PlatformBaseZ, heading)
        end

        if IsDisabledControlJustPressed(0, 38) and lastHit then
            result = vec3(lastHit.x, lastHit.y, lastHit.z)
            placing = false
        elseif IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 177) then
            placing = false
            notify(true, 'place_cancel')
        end
        Wait(0)
    end

    lib.hideTextUI()
    if preview and DoesEntityExist(preview) then DeleteEntity(preview) end
    if preview2 and DoesEntityExist(preview2) then DeleteEntity(preview2) end
    if preview3 and DoesEntityExist(preview3) then DeleteEntity(preview3) end
    preview, preview2, preview3 = nil, nil, nil

    -- keep pause controls blocked briefly so the closing Esc does not open the menu
    CreateThread(function()
        local untilTime = GetGameTimer() + 400
        while GetGameTimer() < untilTime do
            DisableControlAction(0, 199, true)
            DisableControlAction(0, 200, true)
            if IsPauseMenuActive() then SetPauseMenuActive(false) end
            Wait(0)
        end
    end)

    if result then
        local ok, key, id = lib.callback.await('carlift:place', false, result, heading)
        if ok then notify(true, key, id) else notify(false, key) end
    end
end

RegisterCommand(Config.PlaceCommand, function() CreateThread(startPlacement) end, false)

-- Cleanup ------------------------------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    placing = false
    if preview and DoesEntityExist(preview) then DeleteEntity(preview) end
    if preview2 and DoesEntityExist(preview2) then DeleteEntity(preview2) end
    if preview3 and DoesEntityExist(preview3) then DeleteEntity(preview3) end
    lib.hideTextUI()
    for netId in pairs(attached) do
        if NetworkDoesNetworkIdExist(netId) then
            local veh = NetworkGetEntityFromNetworkId(netId)
            if veh ~= 0 then detach(veh) end
        end
    end
    for _, model in ipairs(TARGET_MODELS) do exports.ox_target:removeModel(model, OPTION_NAMES) end
end)
