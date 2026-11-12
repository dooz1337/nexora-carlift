# Nexora Carlift

<img width="1260" height="973" alt="image" src="https://github.com/user-attachments/assets/f4a8e0ba-ab7b-40d1-8e2a-4b82585193af" />

Car lifts for FiveM (ESX). Admins place lifts in the world, mechanics lock a vehicle onto one and raise or lower it, and every nearby player sees the same thing. The lift is built entirely from **base-game GTA V props**, so nothing has to be streamed and no custom models or textures are needed.

- Admin placement with a live preview (`/placelift`)
- Lock / unlock / raise / lower through **ox_target**, optionally limited to jobs
- The locked car keeps its collision, so players can walk around it, open the hood and repair it
- Smooth movement for every nearby player, with sync for players who arrive later
- Lifts are saved in the database and respawn on restart
- English and Hungarian included, easy to add more

## How it looks and works

A lift is three vanilla objects spawned together at the placed position and heading:

| Object | Model | Role |
|---|---|---|
| left column | `prop_spray_jackleg` | static, control box faces outward |
| right column | `prop_spray_jackleg` (turned 180°) | static, control box faces outward |
| platform | `prop_spray_jackframe` | moves up and down; the vehicle is attached to it |

The server owns all state. When someone raises or lowers a lift the server validates the request, sends **one** event to players within `Config.SyncRadius` (default 250 m) and each of those players' game animates the platform locally every frame. The server then sets the final position, which syncs normally. A player who streams a lift in later asks the server for its current state: close players join a move in progress on the same curve, far players just get the resting position.

The vanilla platform has a wall at each end, so a car cannot be driven straight on. **Lock** therefore takes the nearest free vehicle within `Config.LockRadius` and places it on the platform, centred and aligned with the runways. The platform is sunk into the ground by `Config.PlatformSink` so cars can also roll on from the side.

## Requirements

- [es_extended](https://github.com/esx-framework/esx_core)
- [oxmysql](https://github.com/overextended/oxmysql)
- [ox_lib](https://github.com/overextended/ox_lib)
- [ox_target](https://github.com/overextended/ox_target)
- OneSync enabled (lifts are server-created networked objects)

## Installation

1. Copy the `carlift` folder into your `resources` folder.
2. Import `sql.sql` into your database (it is safe to import more than once).
3. Add to `server.cfg`, after the dependencies:
   ```cfg
   ensure carlift
   add_ace group.admin carlift.admin allow
   ```
   The ACE is optional if you rely on ESX groups (see `Config.Admin`).
4. Restart the server and run `/placelift` as an admin.

## Usage

**Placing a lift (admin)**

`/placelift`, then aim at the ground. `E` places it, `←` / `→` rotate it (hold `Shift` for fine steps), `Esc` cancels. The lift is saved immediately.

**Using a lift**

Park a car near a lift and aim at a column or the platform with ox_target:

| Option | When |
|---|---|
| Lock vehicle | lift is down, no car locked, a car is within `Config.LockRadius` |
| Unlock vehicle | lift is down with a locked car |
| Raise lift | lift is down with a locked car |
| Lower lift | lift is up |
| Delete lift | admins only |

A car must be empty and (almost) stationary to be locked. Doors of a locked car are locked, but the car keeps its collision, so it can still be worked on from outside. Before lowering, the server checks that nobody is standing under the lift. After that it lowers without further checks.

**Command**

`/placelift` (admin) places a new lift.

## Configuration

Everything is in [`config.lua`](config.lua).

| Setting | Default | Description |
|---|---|---|
| `Debug` | `false` | print debug lines to the server console |
| `Locale` | `'en'` | `'en'` or `'hu'` |
| `DefaultProp` / `ColProp` | jackleg / jackframe | the column and platform models |
| `DefaultMaxHeight` | `2.5` | metres the platform rises |
| `MaxHeightLimit` | `2.5` | hard cap for a lift's height (columns are 3.25 m tall) |
| `ColumnX` | `1.65` | distance of each column from the lift centre |
| `PlatformSink` | `0.14` | how far the lowered platform is sunk into the ground |
| `DeckMargin` | `0.0` | extra clearance between tyres and deck (m); raise if tyres clip, go negative if they float |
| `PanelOffsets` | two boxes | where the control boxes are; used for the server's distance check |
| `MoveDuration` | `4000` | ms for a full raise or lower |
| `StepInterval` | `50` | ms between the server's timing steps |
| `SyncRadius` | `250.0` | move events only go to players within this distance |
| `CenterVehicle` | `true` | centre and straighten the car on lock |
| `FreezeVehicle` | `true` | freeze the attached car |
| `LockRadius` | `7.0` | cars within this distance of the lift centre can be locked |
| `MaxVehicleSpeed` | `1.0` | car must be (almost) stationary |
| `UnderCarRadius` | `2.0` | someone this close under the platform blocks lowering |
| `JobRestriction` / `AllowedJobs` | `false` / mechanic, bennys | limit use to jobs and minimum grades |
| `Admin` | ACE + ESX groups | who may place or delete lifts |
| `Placement` | 30 m / 20 m | server reach and aim range for `/placelift` |
| `Target` | 3 m, icons | ox_target distance and icons |
| `Cooldown` | `700` | minimum ms between actions per player |
| `ProximityTolerance` | `1.5` | server-side extra reach to the control boxes |

### Adding a language

Copy `locales/en.lua` to `locales/<code>.lua`, translate the values, change `Locales.en` to `Locales.<code>`, add the file to `shared_scripts` in `fxmanifest.lua` and set `Config.Locale = '<code>'`.

## Performance

A lift is three frozen networked objects and costs nothing while it sits still. A move sends one event to nearby players and nothing continuous. The server's own timing loop runs every `StepInterval` ms while a lift moves and does not send anything.

## Limitations

- The state of a lift (its height and any locked car) is not saved. After a restart every lift is down and no car is locked.
- ESX only.
- Trucks and buses longer than about 5.5 m will collide with the platform's end walls.
- Locking needs the car's network owner to be reachable. If the owner leaves at the wrong moment the lock fails and can be repeated.
- The sunk part of the platform can be hidden by the road surface, depending on the ground where the lift is placed.

## Troubleshooting

| Problem | What to check |
|---|---|
| Nothing spawns, `[carlift] spawned 0/0 lifts` | no lifts placed yet; use `/placelift` |
| `could not load car_lifts` | import `sql.sql` |
| Cannot place or delete | ACE `carlift.admin` or ESX group in `Config.Admin` |
| No ox_target options | `ox_target` must start before `carlift`; look at the column or the platform |
| Tyres clip into or hover over the deck | adjust `Config.DeckMargin` |
| Car is too high or too low on the lift | adjust `Config.PlatformSink` |
| Platform does not follow smoothly for others | check `Config.SyncRadius` and enable `Config.Debug` |

## Assets

The lift uses the Rockstar models `prop_spray_jackleg` and `prop_spray_jackframe` by name only. No game files are included or redistributed in this repository.

## License

[MIT](LICENSE). See the file for details.
