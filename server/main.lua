-- carlift server: owns lift state, vehicle locking and platform movement. Clients only send intent.
local ESX = exports['es_extended']:getSharedObject()

-- lift = { id, x, y, z, heading, prop, maxHeight, entity, netId,
--          state = 'down'|'moving'|'up', height, vehicle (entity|nil), busy }
local Lifts = {}
local lastAction = {}

local function dbg(...)
    if Config.Debug then print('[carlift]', ...) end
end

local function logError(...)
    print('^1[carlift]^7', ...)
end

-- Permissions -------------------------------------------------------------------------

local function isAdmin(src)
    local A = Config.Admin
    if A.UseAce and A.Ace and A.Ace ~= '' and IsPlayerAceAllowed(src, A.Ace) then return true end
    if A.UseGroups then
        local xPlayer = ESX.GetPlayerFromId(src)
        if xPlayer then
            local group = xPlayer.getGroup()
            for _, g in ipairs(A.Groups) do
                if g == group then return true end
            end
        end
    end
    return false
end

local function hasJob(src)
    if not Config.JobRestriction or next(Config.AllowedJobs) == nil then return true end
    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return false end
    local job = xPlayer.getJob()
    local minGrade = job and Config.AllowedJobs[job.name]
    return minGrade ~= nil and (job.grade or 0) >= minGrade
end

local function onCooldown(src)
    local now = GetGameTimer()
    if lastAction[src] and now - lastAction[src] < Config.Cooldown then return true end
    lastAction[src] = now
    return false
end

-- lift-local (x across, y along) -> world position, using the placed heading
local function toWorld(lift, lx, ly)
    local h = math.rad(lift.heading)
    return lift.x + lx * math.cos(h) - ly * math.sin(h), lift.y + lx * math.sin(h) + ly * math.cos(h)
end

-- Players must be near one of the two control boxes (they sit outside the columns, above the platform)
local function nearLift(src, lift, extra)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local pc = GetEntityCoords(ped)
    local reach = Config.Target.Distance + (extra or Config.ProximityTolerance)
    for _, o in ipairs(Config.PanelOffsets) do
        local wx, wy = toWorld(lift, o.x, o.y)
        if #(pc - vec3(wx, wy, lift.z + o.z)) <= reach then return true end
    end
    return false
end

-- Lift entity / state ---------------------------------------------------------------------

local function liftObjects(lift)
    return { lift.entity, lift.entity2, lift.colEntity }
end

-- Every object of the lift carries the same state bags, so ox_target works on whichever one the player aims at
local function publish(lift)
    for _, e in ipairs(liftObjects(lift)) do
        if e and DoesEntityExist(e) then
            local st = Entity(e).state
            st:set('carliftId', lift.id, true)
            st:set('carliftState', lift.state, true)
            st:set('carliftLocked', lift.vehicle ~= nil, true)
            st:set('carliftCenter', vec3(lift.x, lift.y, lift.z), true)
        end
    end
end

-- Creates a networked, frozen object (nil on failure)
local function createFrozen(modelName, x, y, z, heading)
    local obj = CreateObjectNoOffset(joaat(modelName), x, y, z, true, true, false)
    local deadline = GetGameTimer() + 3000
    while (not obj or obj == 0 or not DoesEntityExist(obj)) and GetGameTimer() < deadline do Wait(0) end
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    SetEntityHeading(obj, heading + 0.0)
    FreezeEntityPosition(obj, true)
    return obj
end

local function deleteLiftEntities(lift)
    for _, e in ipairs(liftObjects(lift)) do
        if e and DoesEntityExist(e) then DeleteEntity(e) end
    end
end

-- A lift is THREE vanilla objects: two columns (never move) and the platform (lift.colEntity, moved by the server;
-- the vehicle is attached to it).
local function spawnLift(lift)
    lift.prop = Config.DefaultProp -- rows saved with an older prop are always spawned with the current one
    local lx, ly = toWorld(lift, -Config.ColumnX, 0.0)
    local rx, ry = toWorld(lift, Config.ColumnX, 0.0)
    local left = createFrozen(Config.DefaultProp, lx, ly, lift.z, lift.heading)
    local right = left and createFrozen(Config.DefaultProp, rx, ry, lift.z, lift.heading + 180.0)
    local plat = right and createFrozen(Config.ColProp, lift.x, lift.y, lift.z + Config.PlatformBaseZ, lift.heading)
    if not plat then
        deleteLiftEntities({ entity = left, entity2 = right })
        logError(('lift #%s: could not create "%s" / "%s" (invalid model?)'):format(lift.id, Config.DefaultProp, Config.ColProp))
        return false
    end
    lift.maxHeight = math.min(lift.maxHeight or Config.DefaultMaxHeight, Config.MaxHeightLimit)
    lift.entity, lift.entity2, lift.colEntity = left, right, plat
    lift.netId = NetworkGetNetworkIdFromEntity(left)
    lift.colNetId = NetworkGetNetworkIdFromEntity(plat)
    lift.state = 'down'
    lift.height = 0.0
    lift.vehicle = nil
    lift.busy = false
    publish(lift)
    Lifts[lift.id] = lift
    return true
end

-- Only the platform moves.
local function setLiftZ(lift)
    if lift.colEntity and DoesEntityExist(lift.colEntity) then
        -- server-side native: SetEntityCoordsNoOffset only exists on the client
        SetEntityCoords(lift.colEntity, lift.x, lift.y, lift.z + Config.PlatformBaseZ + lift.height, false, false, false, false)
    end
end

-- Sync to nearby players only -----------------------------------------------------------------------------------
local function playersNear(lift, radius)
    local list = {}
    for _, pid in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(pid)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            if #(vec3(c.x, c.y, c.z) - vec3(lift.x, lift.y, lift.z)) <= radius then list[#list + 1] = tonumber(pid) end
        end
    end
    return list
end

local function broadcastNear(lift, event, ...)
    for _, pid in ipairs(playersNear(lift, Config.SyncRadius)) do
        TriggerClientEvent(event, pid, ...)
    end
end

-- A client that streams a lift in asks for its current state (move in progress, or the exact resting height)
RegisterNetEvent('carlift:server:requestSync', function(id)
    local src = source
    local lift = type(id) == 'number' and Lifts[id]
    if not lift or not lift.colEntity or not DoesEntityExist(lift.colEntity) then return end
    local base = lift.z + Config.PlatformBaseZ
    local ped = GetPlayerPed(src)
    local c = ped and ped ~= 0 and GetEntityCoords(ped)
    local near = c and #(vec3(c.x, c.y, c.z) - vec3(lift.x, lift.y, lift.z)) <= Config.SyncRadius
    if lift.move and near then
        -- close enough: join the move in progress on the same curve
        local m = lift.move
        TriggerClientEvent('carlift:client:move', src, lift.colNetId, base + m.startH, base + m.target, m.duration, GetGameTimer() - m.t0)
    elseif lift.move then
        -- far away: no animation, just the resting position the move ends at (up or down)
        TriggerClientEvent('carlift:client:moveStop', src, lift.colNetId, base + lift.move.target)
    else
        TriggerClientEvent('carlift:client:moveStop', src, lift.colNetId, base + lift.height)
    end
end)

-- Is a player standing under the (raised) platform?
local function personUnder(lift)
    local topZ = lift.z + lift.height
    for _, pid in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(pid)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            local dx, dy = c.x - lift.x, c.y - lift.y
            if math.sqrt(dx * dx + dy * dy) <= Config.UnderCarRadius and c.z < topZ - 0.5 and c.z > lift.z - 1.5 then
                return true
            end
        end
    end
    return false
end

-- Smoothly moves the platform to `target` height. Server-only movement. Returns false if aborted.
local function moveLift(lift, target)
    lift.state = 'moving'
    publish(lift)
    local lowering = target < lift.height
    local startH = lift.height
    local dist = math.abs(target - startH)
    local duration = math.max(300, math.floor(Config.MoveDuration * dist / math.max(lift.maxHeight, 0.1)))
    local t0 = GetGameTimer()
    local completed = true
    local steps = 0
    dbg(('lift #%s move %.2f -> %.2f over %d ms, colEntity=%s exists=%s'):format(
        lift.id, startH, target, duration, tostring(lift.colEntity), tostring(lift.colEntity and DoesEntityExist(lift.colEntity))))

    -- Smoothness: the platform is NOT stepped over the network. Every client animates it locally, every frame, from
    -- (fromZ -> toZ, duration). The server only keeps the timing (lift.height, safety checks) and sets the final position.
    lift.move = { t0 = t0, startH = startH, target = target, duration = duration }
    broadcastNear(lift, 'carlift:client:move', lift.colNetId, lift.z + Config.PlatformBaseZ + startH, lift.z + Config.PlatformBaseZ + target, duration, 0)

    while true do
        if not DoesEntityExist(lift.colEntity) then completed = false break end
        local p = math.min(1.0, (GetGameTimer() - t0) / duration)
        local e = p * p * (3.0 - 2.0 * p) -- smoothstep (same curve as the client)
        lift.height = startH + (target - startH) * e
        steps = steps + 1
        if steps % 20 == 0 then dbg(('lift #%s h=%.2f'):format(lift.id, lift.height)) end
        if p >= 1.0 then break end
        Wait(Config.StepInterval)
    end

    if not completed then
        -- aborted part-way: freeze every client at the height the server reached
        broadcastNear(lift, 'carlift:client:moveStop', lift.colNetId, lift.z + Config.PlatformBaseZ + lift.height)
    end

    lift.move = nil
    if completed then lift.height = target end
    if DoesEntityExist(lift.colEntity) then setLiftZ(lift) end
    lift.state = lift.height <= 0.001 and 'down' or 'up'
    publish(lift)
    return completed
end

-- Vehicle helpers ---------------------------------------------------------------------------

local function vehicleOnAnotherLift(veh)
    for _, l in pairs(Lifts) do
        if l.vehicle == veh then return true end
    end
    return false
end

-- Nearest free vehicle around the lift centre. The vanilla platform has end walls, so cars cannot drive on:
-- Lock pulls a car standing near the lift onto the platform (attach snaps it to the centre).
local function findVehicleOnPlatform(lift)
    local best, bestDist
    for _, veh in ipairs(GetAllVehicles()) do
        local c = GetEntityCoords(veh)
        local dx, dy = c.x - lift.x, c.y - lift.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= Config.LockRadius and math.abs(c.z - lift.z) <= Config.PlatformZTolerance and not vehicleOnAnotherLift(veh) then
            if not bestDist or d < bestDist then best, bestDist = veh, d end
        end
    end
    return best
end

local function vehicleOccupied(veh)
    for seat = -1, 8 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped and ped ~= 0 then return true end
    end
    return false
end

-- Asks the vehicle's network owner to (de)attach it; the server waits for the result (5 s timeout).
local function askOwner(owner, event, ...)
    local p = promise.new()
    lib.callback(event, owner, function(res) if p.state == 0 then p:resolve(res) end end, ...)
    SetTimeout(5000, function() if p.state == 0 then p:resolve(false) end end)
    return Citizen.Await(p)
end

local function releaseVehicle(lift)
    local veh = lift.vehicle
    lift.vehicle = nil
    if veh and DoesEntityExist(veh) then
        SetVehicleDoorsLocked(veh, 1)
        local owner = NetworkGetEntityOwner(veh)
        if owner and owner > 0 then
            askOwner(owner, 'carlift:client:detach', NetworkGetNetworkIdFromEntity(veh))
        end
    end
    publish(lift)
end

-- Actions (all validated here) ----------------------------------------------------------------

local function doLock(src, lift)
    if lift.state ~= 'down' or lift.vehicle then return false, 'err_wrong_state' end
    local veh = findVehicleOnPlatform(lift)
    if not veh then return false, 'err_no_vehicle' end
    if vehicleOnAnotherLift(veh) then return false, 'err_in_use' end
    if vehicleOccupied(veh) then return false, 'err_occupied' end
    if GetEntitySpeed(veh) > Config.MaxVehicleSpeed then return false, 'err_moving' end

    local owner = NetworkGetEntityOwner(veh)
    if not owner or owner <= 0 then return false, 'err_no_owner' end

    -- measure the vehicle position in platform-local space (server-side, not client-supplied)
    local vc = GetEntityCoords(veh)
    local dx, dy = vc.x - lift.x, vc.y - lift.y
    local h = math.rad(lift.heading)
    local lx = dx * math.cos(h) + dy * math.sin(h)
    local ly = -dx * math.sin(h) + dy * math.cos(h)
    local off = Config.AttachOffset
    local rot = GetEntityHeading(veh) - lift.heading
    if Config.CenterVehicle then
        -- snap to the middle of the runways, aligned with the lift axis (keeps the facing direction)
        lx, ly = 0.0, 0.0
        rot = math.floor(((rot % 360.0) + 90.0) / 180.0) * 180.0
    end
    local offset = vec3(lx + off.x, ly + off.y, (vc.z - lift.z) + off.z)

    dbg(('lock lift #%s: measured offset x=%.2f y=%.2f z=%.2f (veh z %.2f, lift z %.2f)'):format(lift.id, offset.x, offset.y, offset.z, vc.z, lift.z))
    SetVehicleDoorsLocked(veh, 2)
    local ok = askOwner(owner, 'carlift:client:attach', NetworkGetNetworkIdFromEntity(veh), lift.colNetId, offset, rot)
    if not ok then
        SetVehicleDoorsLocked(veh, 1)
        return false, 'err_attach'
    end
    lift.vehicle = veh
    publish(lift)
    return true, 'locked'
end

local function doUnlock(src, lift)
    if lift.state ~= 'down' or not lift.vehicle then return false, 'err_wrong_state' end
    releaseVehicle(lift)
    return true, 'unlocked'
end

local function doRaise(src, lift)
    if not lift.vehicle or not DoesEntityExist(lift.vehicle) then return false, 'err_not_locked' end
    if lift.state ~= 'down' then return false, 'err_wrong_state' end
    CreateThread(function()
        moveLift(lift, lift.maxHeight)
        lift.busy = false
    end)
    return true, 'raising', true -- third value: busy flag stays set until the thread finishes
end

local function doLower(src, lift)
    if lift.state ~= 'up' then return false, 'err_wrong_state' end
    if personUnder(lift) then return false, 'err_person_under' end
    CreateThread(function()
        local done = moveLift(lift, 0.0)
        if not done and DoesEntityExist(lift.entity) and personUnder(lift) then
            -- stopped part-way because someone walked under: nothing else to do, state is 'up'
            dbg('lowering aborted, person under lift', lift.id)
        end
        lift.busy = false
    end)
    return true, 'lowering', true
end

local actions = { lock = doLock, unlock = doUnlock, raise = doRaise, lower = doLower }

lib.callback.register('carlift:action', function(src, action, id)
    local fn = type(action) == 'string' and actions[action]
    if not fn or type(id) ~= 'number' then return false, 'err_invalid' end
    if onCooldown(src) then return false, 'err_cooldown' end
    local lift = Lifts[id]
    if not lift or not DoesEntityExist(lift.entity) then return false, 'err_not_found' end
    if not hasJob(src) then return false, 'err_job' end
    if not nearLift(src, lift) then return false, 'err_too_far' end
    if lift.busy or lift.state == 'moving' then return false, 'err_busy' end

    lift.busy = true
    local ok, key, keepBusy = fn(src, lift)
    dbg(('action %s lift #%s by %s -> %s (%s)'):format(action, id, src, tostring(ok), tostring(key)))
    if not keepBusy then lift.busy = false end
    return ok, key
end)

-- Admin: place / delete / state -------------------------------------------------------------------

lib.callback.register('carlift:isAdmin', function(src) return isAdmin(src) end)

lib.callback.register('carlift:getProps', function()
    local set, list = {}, { Config.DefaultProp }
    set[Config.DefaultProp] = true
    for _, l in pairs(Lifts) do
        if not set[l.prop] then set[l.prop] = true list[#list + 1] = l.prop end
    end
    return list
end)

lib.callback.register('carlift:place', function(src, coords, heading)
    if not isAdmin(src) then return false, 'err_permission' end
    if onCooldown(src) then return false, 'err_cooldown' end
    if type(coords) ~= 'vector3' or type(heading) ~= 'number' or heading ~= heading then return false, 'err_invalid' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or #(GetEntityCoords(ped) - coords) > Config.Placement.MaxDistance then
        return false, 'err_too_far'
    end

    heading = heading % 360.0
    local xPlayer = ESX.GetPlayerFromId(src)
    local id = MySQL.insert.await(
        'INSERT INTO car_lifts (x, y, z, heading, prop, max_height, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { coords.x, coords.y, coords.z, heading, Config.DefaultProp, Config.DefaultMaxHeight, xPlayer and xPlayer.identifier or nil })
    if not id then return false, 'err_db' end

    local ok = spawnLift({
        id = id, x = coords.x, y = coords.y, z = coords.z, heading = heading,
        prop = Config.DefaultProp, maxHeight = Config.DefaultMaxHeight,
    })
    if not ok then
        MySQL.update.await('DELETE FROM car_lifts WHERE id = ?', { id })
        return false, 'err_invalid'
    end
    return true, 'placed', id
end)

lib.callback.register('carlift:delete', function(src, id)
    if not isAdmin(src) then return false, 'err_permission' end
    if type(id) ~= 'number' then return false, 'err_invalid' end
    if onCooldown(src) then return false, 'err_cooldown' end
    local lift = Lifts[id]
    if not lift then return false, 'err_not_found' end
    if not nearLift(src, lift) then return false, 'err_too_far' end
    if lift.busy or lift.state == 'moving' then return false, 'err_busy' end

    lift.busy = true
    MySQL.update.await('DELETE FROM car_lifts WHERE id = ?', { id })
    Lifts[id] = nil
    releaseVehicle(lift)
    deleteLiftEntities(lift)
    return true, 'deleted'
end)

local function pushAdminState(src)
    TriggerClientEvent('carlift:client:adminState', src, isAdmin(src))
end

AddEventHandler('esx:playerLoaded', function(src) pushAdminState(src) end)
AddEventHandler('esx:setGroup', function(src) pushAdminState(src) end)
AddEventHandler('playerDropped', function() lastAction[source] = nil end)

-- Vehicle deleted while locked: clear state and bring the platform down.
CreateThread(function()
    while true do
        Wait(1000)
        for _, lift in pairs(Lifts) do
            if lift.vehicle and not lift.busy and lift.state ~= 'moving' and not DoesEntityExist(lift.vehicle) then
                dbg('vehicle gone, resetting lift', lift.id)
                lift.vehicle = nil
                publish(lift)
                if lift.state == 'up' then
                    lift.busy = true
                    CreateThread(function()
                        moveLift(lift, 0.0)
                        lift.busy = false
                    end)
                end
            end
        end
    end
end)

-- Load from DB ----------------------------------------------------------------------------------

CreateThread(function()
    -- lifts placed with an older prop keep their position/heading and are switched to the current prop and travel
    MySQL.update.await('UPDATE car_lifts SET prop = ?, max_height = ? WHERE prop <> ?',
        { Config.DefaultProp, Config.DefaultMaxHeight, Config.DefaultProp })
    -- existing lifts follow the configured travel
    MySQL.update.await('UPDATE car_lifts SET max_height = ? WHERE max_height <> ?', { Config.DefaultMaxHeight, Config.DefaultMaxHeight })
    local rows = MySQL.query.await('SELECT id, x, y, z, heading, prop, max_height FROM car_lifts')
    if not rows then logError('could not load car_lifts (is sql.sql imported?)') return end
    local n = 0
    for _, r in ipairs(rows) do
        if spawnLift({
            id = r.id, x = r.x, y = r.y, z = r.z, heading = r.heading,
            prop = r.prop, maxHeight = r.max_height,
        }) then n = n + 1 end
    end
    print(('[carlift] spawned %d/%d lifts'):format(n, #rows))
    for _, pid in ipairs(GetPlayers()) do pushAdminState(tonumber(pid)) end
end)

-- Clean shutdown ----------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, lift in pairs(Lifts) do
        local veh = lift.vehicle
        if veh and DoesEntityExist(veh) then
            SetVehicleDoorsLocked(veh, 1)
            local owner = NetworkGetEntityOwner(veh)
            if owner and owner > 0 then
                TriggerClientEvent('carlift:client:release', owner, NetworkGetNetworkIdFromEntity(veh))
            end
        end
        deleteLiftEntities(lift)
    end
    Lifts = {}
end)
