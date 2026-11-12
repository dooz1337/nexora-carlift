Config = {}

Config.Debug  = false
Config.Locale = 'en' -- 'hu' | 'en'

-- Lift props (vanilla GTA, nothing streamed) -------------------------------------------------------------
-- A lift is THREE objects, all base-game models, spawned together at the placed position/heading:
--   DefaultProp = prop_spray_jackleg, twice: the two columns (left as modelled, right turned 180 deg, so the control
--                 boxes face outward and the legs point under the platform)
--   ColProp     = prop_spray_jackframe: the platform (frame with two tread-plate runways + its own collision).
--                 The server moves THIS entity up and down and the vehicle is attached to it.
Config.DefaultProp      = 'prop_spray_jackleg'
Config.ColProp          = 'prop_spray_jackframe'
Config.DefaultMaxHeight = 2.5     -- metres the platform rises (columns are 3.25 m tall)
Config.MaxHeightLimit   = 2.5     -- hard cap for a lift's max height (keep <= column height 3.25 m minus the platform's 0.5 m)

-- Layout in the lift's local space (x across, y along the platform, z up; origin = floor centre)
Config.ColumnX       = 1.65       -- column centres at x = -ColumnX / +ColumnX (legs end just outside the runway edge)
Config.PlatformSink  = 0.14       -- how far the lowered platform is sunk into the ground, so cars can roll onto the runways
Config.PlatformBaseZ = 0.232 - Config.PlatformSink   -- platform origin above the floor when lowered (0.232 = lowest edge on the floor)
Config.DeckZ         = -0.031     -- top of the runways relative to the PLATFORM origin
Config.DeckMargin    = 0.0        -- extra tyre clearance (m): raise if tyres clip, negative if they float
-- Control boxes (where players aim) in lift-local space; the server accepts any of them for the distance check
Config.PanelOffsets  = { vec3(-1.91, 0.0, 1.7), vec3(1.91, 0.0, 1.7) }

-- Movement ------------------------------------------------------------------
Config.MoveDuration = 4000        -- ms for a full raise/lower (shorter if starting part-way)
Config.StepInterval = 50          -- ms between server timing/safety checks
Config.SyncRadius   = 250.0       -- move events go only to players within this distance of the lift (others get synced when they arrive)

-- Vehicle attachment -----------------------------------------------------------
-- The vehicle's position relative to the platform is measured by the server when locking.
-- This offset is added on top of the measured one (x right, y forward, z up, platform local space).
Config.AttachOffset   = vec3(0.0, 0.0, 0.0)
Config.CenterVehicle  = true       -- on lock, move the car to the centre of the lift and align it with the lift axis (nearest of front/back)
Config.FreezeVehicle  = true      -- also FreezeEntityPosition the attached vehicle (set false if the car does not follow the platform)
Config.LockRadius     = 7.0       -- a car within this horizontal distance of the lift centre is pulled onto the platform on Lock
Config.PlatformZTolerance = 2.0   -- max vertical distance between vehicle origin and lift origin when locking
Config.MaxVehicleSpeed    = 1.0   -- vehicle must be (almost) stationary to lock

-- Safety ------------------------------------------------------------------------
Config.UnderCarRadius = 2.0       -- a player within this horizontal radius, below the raised platform, blocks lowering

-- Job restriction ----------------------------------------------------------------
Config.JobRestriction = false     -- false: everyone can use lifts. true: only Config.AllowedJobs
Config.AllowedJobs = {
    -- ['job_name'] = minimum_grade,
    ['mechanic'] = 0,
    ['bennys'] = 0,
}

-- Admin permission (place/delete lifts) ---------------------------------------------
Config.Admin = {
    UseAce    = true,
    Ace       = 'carlift.admin',          -- add_ace group.admin carlift.admin allow
    UseGroups = true,
    Groups    = { 'admin', 'superadmin' }, -- ESX groups
}

-- Placement ---------------------------------------------------------------------------
Config.PlaceCommand = 'placelift'
Config.Placement = {
    MaxDistance = 30.0,   -- server: placement point may be at most this far from the admin
    AimDistance = 20.0,   -- client: aim raycast range
}

-- Target (ox_target) -------------------------------------------------------------------
Config.Target = {
    Distance = 3.0,
    Icons = {
        lock   = 'fa-solid fa-lock',
        unlock = 'fa-solid fa-lock-open',
        raise  = 'fa-solid fa-arrow-up',
        lower  = 'fa-solid fa-arrow-down',
        delete = 'fa-solid fa-trash',
    },
}

-- Anti-spam: min ms between lift actions per player
Config.Cooldown = 700
-- Server-side extra reach on top of Target.Distance, measured to the nearest control box (Config.PanelOffsets)
Config.ProximityTolerance = 1.5
