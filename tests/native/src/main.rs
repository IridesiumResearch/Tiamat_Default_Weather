// SPDX-FileCopyrightText: Iridesium
// SPDX-License-Identifier: GPL-3.0-only
//
// The mod, run for real: the engine's script VM with a fake server around it.
//
// Nothing is mocked at the Lua level. The mod's files load through
// `EngineVm::load_mod`, its hooks fire through the trait the server calls,
// and the HUD script is drawn by the same `HudVm` a client runs. What is
// faked is the world: player bodies, a flat floor with blocks placed on it,
// sunlight above the highest block in a column, storage, and recorders for
// every edit, burst, loop and HUD value the mod sends.
//
// The Spindle is a STAND-IN that registers the blocks this mod looks up, so
// the Spindle adapter is chosen; a second rig loads without it.

use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::{Arc, Mutex},
};

use tiamat_core::{
    BlockPos, MaterialId,
    atmosphere::{self, CloudMap, Clouds, FlashRequest, Precipitation, SkyModifier},
    ent::{self, Entity, EntityId, Owner, Transform},
    fluid::{self, Fluid, FluidId},
    hud::{self, State, Value, Values},
    identity::PlayerUuid,
    light::{Light, LightSource},
    modload::WorldOptionValue,
    particle::{self, EmitRequest},
    script::{
        ChatEvent, EngineVm, FluidFlowEvent, HudLimits, HudVm, JoinEvent, LeaveEvent, RandomTickEvent, ScriptVm, VmLimits,
        WorldEdit,
    },
    sight::{self, Reading, Sighting, Skip, Surface},
    sound::{self, LoopRequest, PlayRequest, StopRequest},
    storage::{self, Access as _},
};

const MOD: &str = "tiamat_weather";
const ALICE: [u8; 32] = [7; 32];
const BOB: [u8; 32] = [9; 32];
const SEED: u64 = 20_260_916;

// The mirrored dome: world y of the base dome at u = r^2 / R^2.
fn dome_y(x: f64, z: f64) -> f64 {
    let u = (x * x + z * z) * 1e-6 / (59.0 * 59.0);
    11000.0 + (19.0 - u * (5.0 - 2.5 * u)) * 1000.0
}

// --- Fakes -------------------------------------------------------------------

#[derive(Default)]
struct Storage(Mutex<BTreeMap<(String, String), storage::Value>>);

impl storage::Access for Storage {
    fn get(&self, mod_id: &str, key: &str) -> Option<storage::Value> {
        self.0.lock().unwrap().get(&(mod_id.into(), key.into())).cloned()
    }
    fn set(&self, mod_id: &str, key: &str, value: Option<storage::Value>) {
        let mut map = self.0.lock().unwrap();
        match value {
            Some(v) => {
                map.insert((mod_id.into(), key.into()), v);
            }
            None => {
                map.remove(&(mod_id.into(), key.into()));
            }
        }
    }
    fn keys(&self, mod_id: &str) -> Vec<String> {
        self.0.lock().unwrap().keys().filter(|(m, _)| m == mod_id).map(|(_, k)| k.clone()).collect()
    }
}

#[derive(Clone)]
struct Entities(Arc<Mutex<HashMap<[u8; 32], Entity>>>);

impl Entities {
    fn put(&self, who: [u8; 32], x: f64, y: f64, z: f64) {
        let mut body = Entity::at(Transform::from_world(x, y, z), "engine:player");
        body.owner = Some(Owner(PlayerUuid::from_bytes(who)));
        body.on_ground = true;
        self.0.lock().unwrap().insert(who, body);
    }
    fn id_of(who: [u8; 32]) -> u64 {
        u64::from(who[0])
    }
}

impl ent::Access for Entities {
    fn spawn(&self, _: Entity) -> Option<EntityId> {
        None
    }
    fn despawn(&self, _: EntityId) -> bool {
        false
    }
    fn get(&self, id: EntityId) -> Option<Entity> {
        self.0.lock().unwrap().iter().find(|(who, _)| Self::id_of(**who) == id.0).map(|(_, e)| e.clone())
    }
    fn patch(&self, _: EntityId, _: &ent::Patch) -> bool {
        false
    }
    fn player(&self, uuid: [u8; 32]) -> Option<EntityId> {
        self.0.lock().unwrap().contains_key(&uuid).then(|| EntityId(Self::id_of(uuid)))
    }
    /// Every body within `radius` of a point: what a landed bolt asks for.
    fn within(&self, at: [f64; 3], radius: f64, _: Option<&str>) -> Vec<EntityId> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, e)| {
                let p = e.transform.to_world();
                let (dx, dy, dz) = (p[0] - at[0], p[1] - at[1], p[2] - at[2]);
                dx * dx + dy * dy + dz * dz <= radius * radius
            })
            .map(|(who, _)| EntityId(Self::id_of(*who)))
            .collect()
    }
    fn move_player(&self, _: [u8; 32], _: [f64; 3]) -> bool {
        false
    }
    fn select_slot(&self, _: [u8; 32], _: u16) -> bool {
        true
    }
    fn shove_player(&self, _: [u8; 32], _: [f32; 3]) -> bool {
        false
    }
    fn transfer(&self, _: EntityId, _: &str, _: [f64; 3]) -> bool {
        false
    }
}

#[derive(Default)]
struct Sounds {
    plays: Mutex<Vec<String>>,
    loops: Mutex<Vec<(String, String, f32)>>,
    stops: Mutex<Vec<String>>,
}

impl sound::Access for Sounds {
    fn play(&self, request: &PlayRequest) -> u32 {
        self.plays.lock().unwrap().push(request.sound.clone());
        1
    }
    fn start_loop(&self, request: &LoopRequest) -> u32 {
        self.loops.lock().unwrap().push((request.id.clone(), request.sound.clone(), request.gain));
        1
    }
    fn time_of_day(&self) -> f32 {
        0.5
    }
    fn stop_loop(&self, request: &StopRequest) -> u32 {
        self.stops.lock().unwrap().push(request.id.clone());
        1
    }
}

#[derive(Default)]
struct Particles {
    now: Mutex<u64>,
    bursts: Mutex<Vec<(u64, EmitRequest)>>,
}

impl particle::Access for Particles {
    fn emit(&self, request: &EmitRequest) -> u32 {
        let now = *self.now.lock().unwrap();
        self.bursts.lock().unwrap().push((now, request.clone()));
        1
    }
    // Weather hangs nothing over anybody; the engine's own tests cover it.
    fn show_over(&self, _: &particle::BadgeRequest) -> u32 {
        0
    }
}

/// What the client is told to draw the weather with: the sky, the rain and
/// the flashes. Each is the latest state per player, plus its whole history.
#[derive(Default)]
struct Atmosphere {
    now: Mutex<u64>,
    sky: Mutex<HashMap<[u8; 32], Option<SkyModifier>>>,
    rain: Mutex<HashMap<[u8; 32], Option<Precipitation>>>,
    sky_calls: Mutex<Vec<([u8; 32], Option<SkyModifier>)>>,
    rain_calls: Mutex<Vec<([u8; 32], Option<Precipitation>)>>,
    flashes: Mutex<Vec<(u64, FlashRequest)>>,
    clouds: Mutex<HashMap<[u8; 32], Option<Clouds>>>,
    cloud_calls: Mutex<usize>,
    maps: Mutex<HashMap<[u8; 32], Option<CloudMap>>>,
}

impl atmosphere::Access for Atmosphere {
    fn set_sky_modifier(&self, player: PlayerUuid, modifier: Option<SkyModifier>) -> bool {
        self.sky.lock().unwrap().insert(*player.as_bytes(), modifier.clone());
        self.sky_calls.lock().unwrap().push((*player.as_bytes(), modifier));
        true
    }
    fn flash(&self, request: &FlashRequest) -> u32 {
        self.flashes.lock().unwrap().push((*self.now.lock().unwrap(), request.clone()));
        1
    }
    fn set_clouds(&self, player: PlayerUuid, clouds: Option<Clouds>) -> bool {
        self.clouds.lock().unwrap().insert(*player.as_bytes(), clouds);
        *self.cloud_calls.lock().unwrap() += 1;
        true
    }
    fn set_cloud_map(&self, player: PlayerUuid, map: Option<CloudMap>) -> bool {
        self.maps.lock().unwrap().insert(*player.as_bytes(), map);
        true
    }
    fn set_precipitation(&self, player: PlayerUuid, precipitation: Option<Precipitation>) -> bool {
        self.rain.lock().unwrap().insert(*player.as_bytes(), precipitation.clone());
        self.rain_calls.lock().unwrap().push((*player.as_bytes(), precipitation));
        true
    }
}

#[derive(Default)]
struct Huds(Mutex<HashMap<[u8; 32], Values>>);

impl hud::Access for Huds {
    // Alice is an operator and Bob is not.
    fn is_operator(&self, player: [u8; 32]) -> bool {
        player == ALICE
    }

    fn set_hud(&self, mod_id: &str, player: [u8; 32], values: Values) -> bool {
        assert_eq!(mod_id, MOD);
        self.0.lock().unwrap().insert(player, values);
        true
    }
}

const FULL: u32 = 0x7FF_FFFF;

#[derive(Default)]
struct World {
    blocks: Mutex<HashMap<(i32, i32, i32), (MaterialId, u32)>>,
    /// Solid ground at and below this height, of one material.
    floor: Mutex<(i32, MaterialId)>,
    names: Mutex<HashMap<String, MaterialId>>,
    /// Every accepted edit: (tick, position, block, occupancy).
    edits: Mutex<Vec<(u64, BlockPos, String, u32)>>,
    refused: Mutex<u32>,
    refuse: Mutex<bool>,
    now: Mutex<u64>,
    /// Columns with a roof high above, as (x, z).
    roofs: Mutex<Vec<(i32, i32)>>,
    /// Columns under a canopy that dims the sun to 6 below it, as (x, z).
    canopies: Mutex<Vec<(i32, i32)>>,
    /// The fluid layer: position -> (fluid id, volume).
    fluids: Mutex<HashMap<(i32, i32, i32), (u8, u32)>>,
    /// Every fluid write: (tick, position, fluid id, volume).
    fluid_writes: Mutex<Vec<(u64, BlockPos, u8, u32)>>,
    /// Materials `surface_at` looks through when asked to skip passable ones.
    passable: Mutex<Vec<MaterialId>>,
    /// Positions lit by a lava glow: `light_at` answers a hot fluid's red
    /// there, which is how the fire code tells still lava from water.
    hot: Mutex<Vec<(i32, i32, i32)>>,
    /// Ground nobody has loaded, as (x, z) rectangles `((x0, z0), (x1, z1))`,
    /// inclusive: `block_at` answers `Absent` there, which is nil to a mod,
    /// as the engine does for a chunk that is not loaded.
    unloaded: Mutex<Vec<((i32, i32), (i32, i32))>>,
    /// The highest placed block in each column, kept by `put`, so `light_at`
    /// asks one map rather than walking every block: a 200-block canopy is
    /// forty thousand of them, and a burning wood asks for the light on every
    /// fire every turn.
    tops: Mutex<HashMap<(i32, i32), i32>>,
}

// Fluid ids in the fake: rainwater is 1, anything else registered is 2.
const RAIN_ID: u8 = 1;
const WATER_ID: u8 = 2;

impl World {
    fn put(&self, x: i32, y: i32, z: i32, material: MaterialId, occupancy: u32) {
        let mut blocks = self.blocks.lock().unwrap();
        let mut tops = self.tops.lock().unwrap();
        if occupancy == 0 {
            blocks.remove(&(x, y, z));
            // Taking the top block off a column is the one case that needs
            // the walk, and it is rare: a leaf burning away, a layer thawing.
            if tops.get(&(x, z)) == Some(&y) {
                let below = blocks.iter().filter(|((bx, _, bz), _)| *bx == x && *bz == z).map(|((_, by, _), _)| *by).max();
                match below {
                    Some(top) => {
                        tops.insert((x, z), top);
                    }
                    None => {
                        tops.remove(&(x, z));
                    }
                }
            }
        } else {
            blocks.insert((x, y, z), (material, occupancy));
            let top = tops.entry((x, z)).or_insert(y);
            *top = (*top).max(y);
        }
    }
    /// The same ground as another rig's world: what a server keeps across a
    /// restart, as distinct from what the mod keeps in storage.
    fn copy_from(&self, other: &World) {
        *self.blocks.lock().unwrap() = other.blocks.lock().unwrap().clone();
        *self.tops.lock().unwrap() = other.tops.lock().unwrap().clone();
        *self.floor.lock().unwrap() = *other.floor.lock().unwrap();
        *self.fluids.lock().unwrap() = other.fluids.lock().unwrap().clone();
    }
    fn at(&self, x: i32, y: i32, z: i32) -> (MaterialId, u32) {
        if let Some(found) = self.blocks.lock().unwrap().get(&(x, y, z)) {
            return *found;
        }
        let (top, material) = *self.floor.lock().unwrap();
        if y <= top { (material, FULL) } else { (MaterialId(0), 0) }
    }
    fn apply(&self, pos: BlockPos, block: &str, occupancy: u32) -> bool {
        if *self.refuse.lock().unwrap() {
            *self.refused.lock().unwrap() += 1;
            return false;
        }
        let material = if block == "engine:air" {
            MaterialId(0)
        } else {
            *self.names.lock().unwrap().get(block).unwrap_or_else(|| panic!("edit names an unknown block {block}"))
        };
        let occupancy = if block == "engine:air" { 0 } else { occupancy };
        self.put(pos.x, pos.y, pos.z, material, occupancy);
        let now = *self.now.lock().unwrap();
        self.edits.lock().unwrap().push((now, pos, block.to_owned(), occupancy));
        true
    }
}

impl sight::Access for World {
    fn line_of_sight(&self, _: &str, _: [f64; 3], _: [f64; 3]) -> Sighting {
        Sighting::Clear
    }
    fn block_at(&self, _: &str, pos: BlockPos) -> Reading {
        let away = self.unloaded.lock().unwrap();
        if away.iter().any(|((x0, z0), (x1, z1))| pos.x >= *x0 && pos.x <= *x1 && pos.z >= *z0 && pos.z <= *z1) {
            return Reading::Absent;
        }
        drop(away);
        let (material, occupancy) = self.at(pos.x, pos.y, pos.z);
        Reading::Single { material, occupancy }
    }
    fn surface_at(&self, _: &str, column: [i32; 2], from: i32, depth: u32, skip: Skip) -> Option<Surface> {
        let (x, z) = (column[0], column[1]);
        for step in 0..depth as i32 {
            let y = from - step;
            let (material, occupancy) = self.at(x, y, z);
            let fluid = self.fluids.lock().unwrap().get(&(x, y, z)).copied();
            if occupancy == 0 {
                if let Some((id, volume)) = fluid {
                    if !skip.fluid {
                        return Some(Surface {
                            y,
                            material: MaterialId(0),
                            occupancy: 0,
                            fluid: Some(Fluid::new(FluidId(id), volume)),
                        });
                    }
                }
                continue;
            }
            if skip.passable && self.passable.lock().unwrap().contains(&material) {
                continue;
            }
            return Some(Surface { y, material, occupancy, fluid: None });
        }
        None
    }
}

impl fluid::Access for World {
    fn fluid_at(&self, _: &str, pos: BlockPos) -> Fluid {
        match self.fluids.lock().unwrap().get(&(pos.x, pos.y, pos.z)) {
            Some((id, volume)) => Fluid::new(FluidId(*id), *volume),
            None => Fluid::EMPTY,
        }
    }
    fn set_fluid_at(&self, _: &str, pos: BlockPos, value: Fluid) -> bool {
        let now = *self.now.lock().unwrap();
        let (id, volume) = (value.fluid().0, value.volume());
        self.fluid_writes.lock().unwrap().push((now, pos, id, volume));
        let mut fluids = self.fluids.lock().unwrap();
        if value.is_empty() {
            fluids.remove(&(pos.x, pos.y, pos.z)).is_some()
        } else {
            fluids.insert((pos.x, pos.y, pos.z), (id, volume));
            true
        }
    }
    fn fluid_id(&self, name: &str) -> Option<FluidId> {
        Some(FluidId(if name == "tiamat_weather:rainwater" { RAIN_ID } else { WATER_ID }))
    }
}

impl LightSource for World {
    fn light_at(&self, _: &str, pos: BlockPos) -> Light {
        // A lava glow first: the Spindle's lava emits { 15, 8, 1 }, and that
        // red at a fluid surface is what tells the fire code it is hot.
        if self.hot.lock().unwrap().contains(&(pos.x, pos.y, pos.z)) {
            return Light::new(15, 15, 8, 1);
        }
        if self.roofs.lock().unwrap().contains(&(pos.x, pos.z)) {
            return Light::DARK;
        }
        if self.canopies.lock().unwrap().contains(&(pos.x, pos.z)) {
            return Light::new(6, 0, 0, 0);
        }
        let (top, _) = *self.floor.lock().unwrap();
        let covered = self.tops.lock().unwrap().get(&(pos.x, pos.z)).is_some_and(|highest| *highest > pos.y);
        if pos.y > top && !covered { Light::DAYLIGHT } else { Light::DARK }
    }
}

impl WorldEdit for World {
    fn set_block(&self, _: &str, pos: BlockPos, block: &str) -> bool {
        self.apply(pos, block, FULL)
    }
    fn set_partial(&self, _: &str, pos: BlockPos, block: &str, occupancy: u32) -> bool {
        self.apply(pos, block, occupancy)
    }
    fn merge_partial(&self, _: &str, pos: BlockPos, block: &str, occupancy: u32) -> bool {
        self.apply(pos, block, occupancy)
    }
}

// --- The rig -----------------------------------------------------------------

struct Rig {
    vm: EngineVm,
    now: u64,
    entities: Entities,
    sounds: Arc<Sounds>,
    particles: Arc<Particles>,
    huds: Arc<Huds>,
    atmosphere: Arc<Atmosphere>,
    world: Arc<World>,
    materials: HashMap<String, MaterialId>,
}

// The stand-in Spindle: every block the weather mod looks up by name. The
// fuel, the hot blocks and the scorchable turf are looked up the same way, so
// a plain `register_block{ id = id }` is enough for them too: weather reads
// their names, never their flags.
const SPINDLE_STANDIN: &str = "for _, id in ipairs({ 'dirt', 'packed_dirt', 'sand', 'snow', 'ice', 'clear_ice', \
    'permafrost', 'gravel', 'stone', 'mud', 'dried_mud', 'lava_rock', 'pumice', 'sulfur', 'obsidian', 'dark_sand', 'salt', 'oak_log', 'birch_log', 'grass', \
    'oak_leaves', 'tall_grass', 'fern', 'fir_needles', 'fir_log', 'dead_log', 'heather', 'mulch', 'magma', 'lava', 'gorse' }) \
    do game.register_block{ id = id } end";

// The stand-in Life (Life a1d016c): the three functions its exports.lua
// offers, recording what they are called with. `/life` reads the record back
// as `contact;heat;alight`.
const LIFE_STANDIN: &str = r#"
    life_calls = { contact = {}, heat = {}, alight = {} }
    game.export{
        version = 1,
        add_contact_fire = function(material, spec)
            life_calls.contact[#life_calls.contact + 1] = material .. ":" .. spec.damage .. "," .. spec.ticks .. "," .. spec.after
            return true
        end,
        add_heat_source = function(material, strength)
            life_calls.heat[#life_calls.heat + 1] = material .. ":" .. strength
            return true
        end,
        set_alight = function(target, ticks)
            life_calls.alight[#life_calls.alight + 1] = tostring(target) .. ":" .. ticks
            return true
        end,
    }
    game.register_on_chat(function(event)
        if event.text == "/life" then
            return table.concat(life_calls.contact, " ") .. ";" .. table.concat(life_calls.heat, " ") .. ";" .. table.concat(life_calls.alight, " ")
        end
    end)
"#;

impl Rig {
    fn new(spindle: bool, storage: Arc<Storage>) -> Self {
        Self::with(spindle, storage, "")
    }
    /// `prelude` runs before init.lua, in the mod's environment: `wx_overrides = { ... }`.
    fn with(spindle: bool, storage: Arc<Storage>, prelude: &str) -> Self {
        Self::custom(spindle.then_some(SPINDLE_STANDIN), storage, prelude, &[])
    }
    /// The whole rig: a Spindle stand-in's source (or none), and mods loaded
    /// AFTER weather as `(id, source, depends)`, for reading its exports.
    fn custom(spindle: Option<&str>, storage: Arc<Storage>, prelude: &str, after: &[(&str, &str, &[&str])]) -> Self {
        Self::build(spindle, false, storage, prelude, after, &[])
    }
    /// The Spindle and a stand-in Life, both loaded before weather, as the
    /// resolver orders them from mod.toml's optional_depends.
    fn beside_life(spindle: Option<&str>, storage: Arc<Storage>, prelude: &str) -> Self {
        Self::build(spindle, true, storage, prelude, &[], &[])
    }
    /// A rig whose world chose its options on the new-world screen, as
    /// `(qualified id, value)`. Installed before any mod runs, as the loader
    /// does, because `init.lua` reads them.
    fn options(spindle: Option<&str>, storage: Arc<Storage>, prelude: &str, options: &[(&str, WorldOptionValue)]) -> Self {
        Self::build(spindle, false, storage, prelude, &[], options)
    }
    fn build(
        spindle: Option<&str>, life: bool, storage: Arc<Storage>, prelude: &str, after: &[(&str, &str, &[&str])],
        options: &[(&str, WorldOptionValue)],
    ) -> Self {
        let spindle_id = "tiamat_default_world";
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../mods").join(MOD);
        let mut vm = EngineVm::create(VmLimits::default()).unwrap();
        let entities = Entities(Arc::new(Mutex::new(HashMap::new())));
        let sounds = Arc::new(Sounds::default());
        let particles = Arc::new(Particles::default());
        let huds = Arc::new(Huds::default());
        let atmosphere = Arc::new(Atmosphere::default());
        let world = Arc::new(World::default());
        vm.set_storage_access(storage.clone());
        vm.set_entity_access(Arc::new(entities.clone()));
        vm.set_sound_access(sounds.clone());
        vm.set_particle_access(particles.clone());
        vm.set_hud_access(huds.clone());
        vm.set_atmosphere_access(atmosphere.clone());
        vm.set_sight_access(world.clone());
        vm.set_fluid_access(world.clone());
        vm.set_light_source(world.clone());
        vm.set_world_edit(world.clone());
        // What the world chose, ahead of every init.lua: a mod may register
        // differently for one world than another, so this cannot come later.
        let chosen: Vec<(String, WorldOptionValue)> =
            options.iter().map(|(id, value)| ((*id).to_owned(), value.clone())).collect();
        vm.set_world_options(&chosen);
        let mut before: Vec<String> = Vec::new();
        if let Some(source) = spindle {
            vm.load_mod(spindle_id, source, &dir).unwrap();
            before.push(spindle_id.to_owned());
        } else {
            vm.load_mod("core", "game.register_block{ id = 'white' }", &dir).unwrap();
        }
        if life {
            vm.load_mod("tiamat_default_life", LIFE_STANDIN, &dir).unwrap();
            before.push("tiamat_default_life".to_owned());
        }
        // What the resolver tells the VM from mod.toml's optional_depends: it
        // is what lets weather read the Spindle's and Life's exports.
        vm.note_dependencies(MOD, &before);
        let init = format!("{prelude}
{}", std::fs::read_to_string(dir.join("init.lua")).unwrap());
        vm.load_mod(MOD, &init, &dir).expect("the mod loads");
        for (id, source, depends) in after {
            vm.note_dependencies(id, &depends.iter().map(|d| (*d).to_owned()).collect::<Vec<_>>());
            vm.load_mod(id, source, &dir).unwrap_or_else(|e| panic!("{id} loads: {e:?}"));
        }
        vm.freeze().unwrap();
        vm.set_world_seed(SEED);
        let materials: HashMap<String, MaterialId> = vm.registered_blocks().into_iter().collect();
        *world.names.lock().unwrap() = materials.clone();
        Rig { vm, now: 0, entities, sounds, particles, huds, atmosphere, world, materials }
    }
    /// Weather is still running. Another mod faulting is some checks' point.
    fn ours_ok(&self, when: &str) {
        let faulted = self.vm.faulted_mods();
        assert!(!faulted.iter().any(|m| m == MOD), "weather faulted after `{when}`: {faulted:?}");
    }
    fn material(&self, id: &str) -> MaterialId {
        *self.materials.get(id).unwrap_or_else(|| panic!("no material {id}"))
    }
    fn join(&mut self, who: [u8; 32], x: f64, y: f64, z: f64) {
        self.entities.put(who, x, y, z);
        self.vm.player_join(&JoinEvent { player: who, name: format!("p{}", who[0]) });
        self.ours_ok("join");
    }
    fn leave(&mut self, who: [u8; 32]) {
        self.entities.0.lock().unwrap().remove(&who);
        self.vm.player_leave(&LeaveEvent { player: who, name: format!("p{}", who[0]) });
    }
    /// Puts the floor under (x, z)'s dome, a block below the feet, and the player on it.
    fn stand(&mut self, who: [u8; 32], x: f64, z: f64, floor: &str) -> i32 {
        let top = dome_y(x, z).floor() as i32;
        *self.world.floor.lock().unwrap() = (top, self.material(floor));
        self.entities.put(who, x, f64::from(top + 1), z);
        top
    }
    fn tick(&mut self, n: u64) {
        for _ in 0..n {
            self.now += 1;
            *self.world.now.lock().unwrap() = self.now;
            *self.particles.now.lock().unwrap() = self.now;
            *self.atmosphere.now.lock().unwrap() = self.now;
            let faults = self.vm.tick(1).expect("the tick itself");
            assert!(!faults.iter().any(|(m, _)| m == MOD), "weather faulted in tick {}: {faults:?}", self.now);
        }
        self.ours_ok("tick");
    }
    fn say(&mut self, who: [u8; 32], text: &str) -> Option<String> {
        let outcome = self.vm.chat(&ChatEvent { player: who, text: text.into() });
        self.ours_ok(text);
        outcome.reason
    }
    fn reply(&mut self, who: [u8; 32], text: &str) -> String {
        self.say(who, text).unwrap_or_else(|| panic!("`{text}` got no reply"))
    }
    fn hud(&self, who: [u8; 32]) -> String {
        match self.huds.0.lock().unwrap().get(&who).and_then(|v| v.get("weather")) {
            Some(Value::Text(t)) => t.clone(),
            _ => String::new(),
        }
    }
    fn random_tick(&mut self, x: i32, y: i32, z: i32) {
        let (material, _) = self.world.at(x, y, z);
        self.vm.random_tick(&RandomTickEvent { pos: BlockPos::new(x, y, z), material });
        self.ours_ok("random tick");
    }
    fn rain_of(&self, who: [u8; 32]) -> Option<Precipitation> {
        self.atmosphere.rain.lock().unwrap().get(&who).cloned().flatten()
    }
    fn clouds_of(&self, who: [u8; 32]) -> Option<Clouds> {
        self.atmosphere.clouds.lock().unwrap().get(&who).copied().flatten()
    }
    fn sky_of(&self, who: [u8; 32]) -> Option<SkyModifier> {
        self.atmosphere.sky.lock().unwrap().get(&who).cloned().flatten()
    }
    fn edits_since(&self, from: u64) -> Vec<(u64, BlockPos, String, u32)> {
        self.world.edits.lock().unwrap().iter().filter(|e| e.0 > from).cloned().collect()
    }
    /// The edits since `from` that wrote one block, by its qualified id.
    fn edits_named(&self, from: u64, block: &str) -> Vec<(u64, BlockPos, String, u32)> {
        self.edits_since(from).into_iter().filter(|e| e.2 == block).collect()
    }
    /// The fire edits since `from`: one per block set alight.
    fn ignitions_since(&self, from: u64) -> Vec<(u64, BlockPos, String, u32)> {
        self.edits_named(from, FIRE)
    }
    /// Blocks of fire in the world right now, whatever the mod thinks.
    fn fires_in_world(&self) -> usize {
        let Some(fire) = self.materials.get(FIRE) else { return 0 };
        self.world.blocks.lock().unwrap().values().filter(|(material, occupancy)| material == fire && *occupancy != 0).count()
    }
    /// Ticks `n`, looking at the world every 200: the world-wide cap has to
    /// hold at every moment, not only once the fire is out. Answers the most
    /// blocks alight at any look.
    fn burn(&mut self, n: u64) -> usize {
        let mut peak = 0;
        let mut left = n;
        while left > 0 {
            let step = left.min(200);
            self.tick(step);
            left -= step;
            let alight = self.fires_in_world();
            assert!(alight <= FIRE_MAX_BURNING, "{alight} blocks alight at tick {}, over the world cap of {FIRE_MAX_BURNING}", self.now);
            peak = peak.max(alight);
        }
        peak
    }
}

// The number after `label` in a reply, e.g. "warmth 812".
fn number_after(text: &str, label: &str) -> f64 {
    let at = text.find(label).unwrap_or_else(|| panic!("no `{label}` in `{text}`")) + label.len();
    let rest: String = text[at..].chars().take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-').collect();
    rest.parse().unwrap_or_else(|_| panic!("`{label}` is not followed by a number in `{text}`"))
}

// The integer before `label` in a reply, e.g. "12 blocks burning".
fn number_before(text: &str, label: &str) -> usize {
    let at = text.find(label).unwrap_or_else(|| panic!("no `{label}` in `{text}`"));
    let digits: Vec<char> = text[..at].chars().rev().take_while(char::is_ascii_digit).collect();
    let number: String = digits.into_iter().rev().collect();
    number.parse().unwrap_or_else(|_| panic!("`{label}` is not preceded by a number in `{text}`"))
}

const ONE_LAYER: u32 = 0x1C0E07;
const TWO_LAYERS: u32 = 0xFC7E3F;

fn main() {
    climate_check();
    survey_check();
    let storage = Arc::new(Storage::default());
    let saved_front = weather_check(storage.clone());
    restart_check(storage, &saved_front);
    snow_check();
    thaw_check();
    queue_check();
    puddle_check();
    exports_check();
    mega_check();
    fire_forest_check();
    fire_field_check();
    fire_rain_check();
    fire_wet_check();
    fire_caps_check();
    fire_rest_check();
    fire_restart_check();
    fire_unloaded_check();
    fire_orphan_check();
    fire_off_check();
    lightning_check();
    fire_lava_check();
    life_check();
    player_strike_check();
    cloud_lift_check();
    plain_check();
    hud_check();
    println!("all weather checks passed");
}

// Warmth is the Spindle's 4t(1-t): cold at the axis and the rim, warmest at
// t = 0.5, and the same both sides of it.
fn climate_check() {
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    r.stand(ALICE, 100.0, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, 100.0, dome_y(100.0, 0.0) + 1.0, 0.0);
    r.tick(1);
    assert!(r.reply(ALICE, "/weather").contains("climate spindle"));

    let warmth = |r: &mut Rig, t: f64| {
        let x = t * 59000.0;
        r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
        let reply = r.reply(ALICE, "/weather");
        number_after(&reply, "warmth ")
    };
    let axis = warmth(&mut r, 0.002);
    let quarter = warmth(&mut r, 0.25);
    let half = warmth(&mut r, 0.5);
    let three_quarters = warmth(&mut r, 0.75);
    let rim = warmth(&mut r, 0.99);
    println!("ok  warmth at the dome: axis {axis}, t=.25 {quarter}, t=.5 {half}, t=.75 {three_quarters}, rim {rim}");
    // 1 point is the dome being a little higher or lower at the two radii
    // (the lapse term), not the curve.
    assert!(axis < 50.0 && rim < 60.0, "cold at the axis and the rim");
    assert!(half >= 995.0, "warmest at t = 0.5");
    assert!((quarter - 750.0).abs() <= 25.0, "4t(1-t) at t=.25 is 750, got {quarter}");
    assert!((quarter - three_quarters).abs() <= 25.0, "symmetric about t=.5: {quarter} vs {three_quarters}");
}

// How often it rains (2026-09-25: "it rains far too often"). The survey is
// the weather function over a year at five places round the player; the
// Verdant belt is this mod's wettest ground, the glass waste its driest.
fn survey_check() {
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    r.stand(ALICE, 100.0, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, 100.0, dome_y(100.0, 0.0) + 1.0, 0.0);
    r.tick(1);
    let (mut falling, mut storm, mut wettest, mut n) = (0.0, 0.0, 0.0f64, 0.0);
    for i in 0..12 {
        let t = 0.2 + 0.05 * f64::from(i);
        let z = 7000.0 * f64::from(i % 3) - 7000.0;
        r.stand(ALICE, t * 59000.0, z, "tiamat_default_world:dirt");
        let reply = r.reply(ALICE, "/weather survey");
        let f = number_after(&reply, "falling ");
        falling += f;
        storm += number_after(&reply, "storm ");
        wettest = wettest.max(f);
        n += 1.0;
    }
    let (falling, storm) = (falling / n, storm / n);
    println!("ok  survey: something falls {falling:.0}% of the year, a storm {storm:.0}%, {wettest:.0}% at the wettest place");
    assert!((10.0..=25.0).contains(&falling), "it rains {falling:.0}% of the year");
    assert!(storm <= 10.0, "it storms {storm:.0}% of the year");
    assert!(wettest <= 40.0, "somewhere is wet {wettest:.0}% of the year");
}

// A forced storm over a warm square: HUD, bursts under the budget, one loop
// that is not restarted every evaluation, thunder, and the chat ladder.
fn weather_check(storage: Arc<Storage>) -> String {
    let mut r = Rig::new(true, storage);
    let x = 0.5 * 59000.0;
    r.stand(ALICE, x, 100.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 100.0) + 1.0, 100.0);
    r.tick(41);

    // Plain chat and other mods' commands pass through untouched.
    assert_eq!(r.say(ALICE, "hello"), None);
    assert_eq!(r.say(ALICE, "/stats"), None);

    let set = r.reply(ALICE, "/weather set storm 5");
    assert!(set.starts_with("storm over square"), "{set}");
    // One evaluation in, the cover map's cell overhead already names the
    // storm: the map carries where the weather is GOING and the client eases
    // it there over the ticks the message names (engine 5056bb4, ask W18),
    // so the storm and the rain arrive together.
    r.tick(40);
    let sent = r.atmosphere.maps.lock().unwrap().get(&ALICE).cloned().flatten().expect("a cover map");
    let target = sent.darkness[8 * 16 + 8];
    assert!(target >= 225, "the cell overhead is sent at the storm's own darkness at once: {target}");
    assert!(r.clouds_of(ALICE).unwrap().ease_ticks >= 400, "and the client is told to take its time");
    r.tick(40 * 24);
    assert_eq!(r.hud(ALICE), "Storm");
    let reply = r.reply(ALICE, "/weather");
    assert!(reply.starts_with("storm at 1000"), "{reply}");
    println!("ok  forced storm eased in: `{reply}`");

    // The storm, as the client is told to draw it: rain it spawns itself, a
    // darker sky with the fog drawn in, one loop whose gain moves, and
    // lightning whose thunder is late by its distance.
    let feet = dome_y(x, 100.0) + 1.0;
    let alice = Some(PlayerUuid::from_bytes(ALICE));
    let rain = r.rain_of(ALICE).expect("a storm sets the rain");
    assert_eq!(rain.burst.size, 0.18, "the storm's drops");
    assert!(rain.burst.texture.is_some(), "a drop is the 1x2 streak picture, not the soft disc");
    let live = f64::from(rain.rate) * f64::from(rain.burst.lifetime);
    assert!(live <= 2801.0, "{live} live storm particles for one player");
    // Three times as hard to see through as the first storm table
    // (1,365 live x 0.07^2 x 0.6 = 4.01), by live x area x alpha, where a
    // drop's picture covers half its square.
    let size = f64::from(rain.burst.size);
    let alpha = f64::from(rain.burst.colour[3]) / 255.0;
    let opacity = live * size * size * 0.5 * alpha;
    assert!(opacity >= 3.0 * 4.01, "storm opacity {opacity:.2}, wanted at least {:.2}", 3.0 * 4.01);
    assert!(rain.burst.velocity[1] < -20.0, "it falls hard");

    let sky = r.sky_of(ALICE).expect("a storm sets the sky");
    assert!(sky.intensity < 0.5, "a storm darkens the day: {}", sky.intensity);
    assert!(sky.fog_distance < 0.4, "and draws the fog in: {}", sky.fog_distance);
    assert!(sky.sky_mix > 0.7 && sky.saturation < 0.7, "{sky:?}");
    assert!(sky.ease_ticks > 0, "eased on the client");

    // One rain loop for that player, its gain moved rather than restarted.
    let loops = r.sounds.loops.lock().unwrap().clone();
    assert!(!loops.is_empty());
    assert!(loops.iter().all(|l| l.1.ends_with("rain") && l.0.ends_with("weather")), "{loops:?}");
    let starts = loops.len();
    assert!(starts <= 5, "one call per quarter step of gain while it eased in: {starts}");
    r.tick(40 * 10);
    assert_eq!(r.sounds.loops.lock().unwrap().len(), starts, "a steady storm sends nothing more");

    // Lightning: a flash, and thunder that arrives later, never before.
    let flashes = r.atmosphere.flashes.lock().unwrap().clone();
    assert!(!flashes.is_empty(), "a storm strikes");
    let first = &flashes[0];
    assert!(first.1.radius >= 256.0 && first.1.flash.intensity > 0.0, "{:?}", first.1);
    assert!(first.1.flash.attack_ticks <= 2 && first.1.flash.decay_ticks >= 4, "a flash is quick: {:?}", first.1.flash);
    let claps = r.sounds.plays.lock().unwrap().iter().filter(|s| s.ends_with("thunder")).count();
    assert!(claps > 0 && claps <= flashes.len(), "{claps} claps for {} flashes", flashes.len());
    println!(
        "ok  storm: rain {:.0}/s at size {:.2} (opacity {opacity:.1}, 3x the first table is 12.0); sky {:.2} with fog {:.2}; {starts} loop calls; {} flashes, {claps} claps",
        rain.rate, rain.burst.size, sky.intensity, sky.fog_distance, flashes.len());

    // Rain is too gentle to sweep a plant away (engine 2f9b036, ask W14):
    // a puddle creeping into the grass beside it must not strip a meadow.
    let rainwater = r.vm.registered_fluids().into_iter()
        .find(|f| f.fluid == "tiamat_weather:rainwater").expect("rainwater is registered");
    assert!(!rainwater.washes, "rain does not wash plants away");
    println!("ok  rainwater is declared too gentle to sweep a plant away");

    // The cloud deck: registered once, shaped after the references, and
    // steered per player. Nothing is emitted as particles any more.
    let deck = r.vm.registered_clouds().expect("weather registers a cloud deck");
    assert_eq!((deck.cell, deck.detail), (24.0, 2), "cubes of 24 breaking into 12s on the surface");
    assert!(deck.thickness >= 128.0 && deck.towers > 0.0, "heaps with towers: {deck:?}");
    assert!((deck.drift[0] - 0.5).abs() < 1e-6 && deck.drift[1] == 0.0, "drifts with the fronts: {:?}", deck.drift);
    assert!(deck.shade[2] > deck.shade[0], "a blue-violet shade: {:?}", deck.shade);
    // The rain puffs are gone: the only bursts a storm emits are lightning's
    // sparks at the point of impact (spec 2026-09-23), quick and heavy.
    let bursts = r.particles.bursts.lock().unwrap().clone();
    assert!(bursts.iter().all(|(_, b)| b.burst.gravity >= 10.0 && b.burst.lifetime < 1.0),
        "no particles but lightning's sparks: the puffs are gone: {:?}", bursts.iter().map(|(_, b)| &b.burst).collect::<Vec<_>>());
    let storm_clouds = r.clouds_of(ALICE).expect("a storm sets the clouds");
    // Four genera (engine d587fb6, ask W13): a storm is a stratocumulus sheet
    // under cumulonimbus, dark to the base, with the cumulus heaps thinned.
    assert!(storm_clouds.darkness >= 0.85, "dark: {storm_clouds:?}");
    assert!((storm_clouds.cover - 0.40).abs() < 0.01, "the heaps thinned: {storm_clouds:?}");
    assert!((storm_clouds.stratocumulus - 0.70).abs() < 0.01 && (storm_clouds.cumulonimbus - 0.60).abs() < 0.01,
        "a sheet under towers: {storm_clouds:?}");
    assert_eq!(storm_clouds.altocumulus, 0.0, "no mackerel sky in a storm: {storm_clouds:?}");
    let floor = storm_clouds.base.expect("the floor is sent per player");
    let want = ((dome_y(x, 100.0) + 400.0) / 64.0).floor() * 64.0;
    assert_eq!(f64::from(floor), want, "400 over the dome under the player, in steps of 64");
    assert!(storm_clouds.ease_ticks > 0, "a change of weather is eased");
    let said = r.reply(ALICE, "/weather clouds");
    assert!(said.starts_with("cover 0.40, darkness 0.90"), "{said}");
    assert!(said.contains("stratocumulus 0.70, altocumulus 0.00, cumulonimbus 0.60"), "{said}");
    println!("ok  clouds: deck {deck:?}; storm `{said}`");

    // The cover map: sixteen squares a side round Alice's, her own in the
    // middle at the storm she is under, and the forced storm on her square
    // alone, so the squares round it are the weather's own.
    let map = r.atmosphere.maps.lock().unwrap().get(&ALICE).cloned().flatten().expect("a cover map is sent");
    assert_eq!((map.size, map.cell), (16, 256.0));
    let cx = (x as i32).div_euclid(256);
    assert_eq!(map.origin, [((cx - 8) * 256) as f32, ((100_i32.div_euclid(256) - 8) * 256) as f32]);
    assert_eq!((map.cover.len(), map.darkness.len()), (256, 256));
    let middle = 8 * 16 + 8;
    // The map carries all five shares (engine aa7ab21, ask W16), and its cell
    // overhead is the sky overhead: the storm's own heaps, sheet and towers.
    assert!((100..=104).contains(&map.cover[middle]) && map.darkness[middle] >= 225, "overhead is the storm: {} {}", map.cover[middle], map.darkness[middle]);
    assert_eq!((map.stratocumulus.len(), map.altocumulus.len(), map.cumulonimbus.len()), (256, 256, 256), "five shares a cell");
    assert!((176..=181).contains(&map.stratocumulus[middle]) && (151..=155).contains(&map.cumulonimbus[middle]) && map.altocumulus[middle] == 0,
        "the storm's sheet and towers overhead: {} {} {}", map.stratocumulus[middle], map.cumulonimbus[middle], map.altocumulus[middle]);
    assert!(map.cumulonimbus.iter().any(|c| *c == 0), "and no towers over the calm squares");
    let calmer = map.darkness.iter().filter(|d| **d < 128).count();
    assert!(calmer > 0, "the storm is not everywhere: every square's darkness is {:?}", &map.darkness[..16]);
    assert!(said.contains("of the 256 squares around you are stormy"), "{said}");
    println!("ok  cover map: 16 x 16 squares of 256, the storm overhead, {calmer} squares calmer");

    // A second player gets their own rain, sky and loop.
    r.join(BOB, x + 5.0, dome_y(x, 100.0) + 1.0, 100.0);
    r.tick(41);
    // Only an operator may force the weather, by the server's own list.
    assert_eq!(r.reply(BOB, "/weather set clear 5"), "only an operator can change the weather");
    assert_eq!(r.reply(BOB, "/weather clear"), "only an operator can change the weather");
    assert!(r.reply(BOB, "/weather").starts_with("storm"), "anybody may ask what it is doing");
    assert!(r.rain_of(BOB).is_some() && r.sky_of(BOB).is_some(), "the newcomer is under the storm too");
    assert!(r.sounds.loops.lock().unwrap().iter().any(|l| l.0.ends_with("weather")), "and hears it");
    let theirs = r.clouds_of(BOB).expect("and their clouds, from the first evaluation");
    assert_eq!(theirs.ease_ticks, 0, "a newcomer's sky is there at once, not eased in from clear");
    r.leave(BOB);

    // Underground the storm is neither seen nor heard: the engine pulls a sky
    // modifier's fog in wherever the player is, and an `everywhere` loop
    // plays at full storm, so both go with the sky. Back out, both return.
    let head = (x as i32, 100);
    r.world.roofs.lock().unwrap().push(head);
    let stops = r.sounds.stops.lock().unwrap().len();
    r.tick(41);
    assert!(r.rain_of(ALICE).is_none(), "no rain in a cave");
    assert!(r.sky_of(ALICE).is_none(), "nor the storm's fog: {:?}", r.sky_of(ALICE));
    assert!(r.sounds.stops.lock().unwrap().len() > stops, "nor its loop");
    assert!(r.clouds_of(ALICE).is_some(), "the clouds stay set for when they come out");
    r.world.roofs.lock().unwrap().retain(|c| *c != head);
    let loops = r.sounds.loops.lock().unwrap().len();
    r.tick(41);
    let back = r.sky_of(ALICE).expect("out of the cave, the storm's sky again");
    assert!(back.fog_distance < 0.4, "{back:?}");
    assert!(r.rain_of(ALICE).is_some(), "and its rain");
    assert!(r.sounds.loops.lock().unwrap().len() > loops, "and its loop");
    println!("ok  underground: no rain, fog or loop; back out, all three return");

    // The bottom of a shaft: daylight falls straight down it at full
    // strength, but the ground stands thirty blocks over the head on every
    // side, so it is underground, not out in the storm (2026-09-25: "light
    // fog at the bottom of long deep tunnels"). One low side is a valley.
    let stone = r.material("tiamat_default_world:stone");
    let feet = r.world.floor.lock().unwrap().0 + 1;
    let (ax, az) = (x as i32, 100);
    let sides = [(8, 0), (-8, 0), (0, 8), (0, -8)];
    let build = |r: &Rig, sides: &[(i32, i32)], material: MaterialId, occupancy: u32| {
        for (dx, dz) in sides {
            for y in feet..=feet + 32 {
                r.world.put(ax + dx, y, az + dz, material, occupancy);
            }
        }
    };
    build(&r, &sides[..3], stone, FULL);
    r.tick(41);
    assert!(r.sky_of(ALICE).is_some_and(|s| s.fog_distance < 0.4), "three walls and an open side is a valley: {:?}", r.sky_of(ALICE));
    build(&r, &sides[3..], stone, FULL);
    r.tick(41);
    assert!(r.rain_of(ALICE).is_none(), "no rain down a deep shaft");
    assert!(r.sky_of(ALICE).is_none(), "nor the storm's fog: {:?}", r.sky_of(ALICE));
    build(&r, &sides, MaterialId(0), 0);
    r.tick(41);
    assert!(r.sky_of(ALICE).is_some_and(|s| s.fog_distance < 0.4), "the walls gone, the storm is back");
    println!("ok  a deep shaft is underground though the sun reaches its floor; a valley is not");

    // Under a forest it is still storming: leaves dim the sun to 6, which
    // alone reads like a cave mouth, but a canopy overhead is outdoors.
    let crown_y = dome_y(x, 100.0) as i32 + 12;
    r.world.canopies.lock().unwrap().push(head);
    let leaves = r.material("tiamat_default_world:oak_leaves");
    r.world.put(head.0, crown_y, head.1, leaves, ONE_LAYER);
    r.tick(41);
    let forest = r.sky_of(ALICE).expect("the storm's sky under the trees");
    assert!(forest.fog_distance < 0.4, "the fog is not halved under leaves: {forest:?}");
    assert!(r.rain_of(ALICE).is_some(), "and it rains");
    // Rock in the same place is an overhang, and the storm fades by the sun.
    let rock = r.material("tiamat_default_world:stone");
    r.world.put(head.0, crown_y, head.1, rock, ONE_LAYER);
    r.tick(41);
    let overhang = r.sky_of(ALICE).expect("some of the storm's sky under an overhang");
    assert!(overhang.fog_distance > forest.fog_distance + 0.2, "less of it: {overhang:?}");
    r.world.canopies.lock().unwrap().clear();
    r.world.put(head.0, crown_y, head.1, rock, 0);
    r.tick(41);
    println!("ok  under a canopy the storm is whole (fog {:.2}); under an overhang it fades (fog {:.2})",
        forest.fog_distance, overhang.fog_distance);

    // Clearing: the storm fades out to Cloudy/clear and the loop stops.
    let stops = r.sounds.stops.lock().unwrap().len();
    assert!(r.reply(ALICE, "/weather clear").contains("back to its own weather"));
    r.say(ALICE, "/weather set clear 10");
    r.tick(40 * 25);
    assert_eq!(r.hud(ALICE), "");
    assert!(r.rain_of(ALICE).is_none(), "the rain is cleared");
    assert!(r.sky_of(ALICE).is_none(), "and the plain sky is back");
    assert!(r.sounds.stops.lock().unwrap().len() > stops, "the loop stopped");
    println!("ok  cleared: HUD empty, rain and sky cleared, loop stopped");

    // A clear sky keeps a few white clouds, and the floor has not moved.
    let fair = r.clouds_of(ALICE).expect("a clear sky still sends clouds");
    assert!(fair.cover > 0.0 && fair.cover < 0.3 && fair.darkness < 0.05, "fair-weather cloud: {fair:?}");
    assert!(fair.altocumulus > 0.2 && fair.stratocumulus == 0.0 && fair.cumulonimbus == 0.0, "a mackerel sky and nothing heavy: {fair:?}");
    assert_eq!(fair.base, Some(floor));
    // The square's own shares are still easing from the storm to the clear
    // sky, and every step of that is a re-send: let it finish before looking
    // at a sky that is steady overhead.
    r.tick(40 * 22);
    let calls = *r.atmosphere.cloud_calls.lock().unwrap();
    let before = r.atmosphere.maps.lock().unwrap().get(&ALICE).cloned().flatten().expect("a map");
    let plain = r.clouds_of(ALICE).unwrap();
    r.tick(400);
    // Ten evaluations: overhead nothing changes — the cell Alice is under and
    // her own shares are what they were — while the four kilometres of map
    // round her are asked again wherever a front is moving, at most one send
    // an evaluation. A steady sky over one square is never a still world.
    let after = r.atmosphere.maps.lock().unwrap().get(&ALICE).cloned().flatten().expect("a map");
    let middle = 8 * 16 + 8;
    assert_eq!(
        (before.cover[middle], before.darkness[middle], before.stratocumulus[middle], before.altocumulus[middle], before.cumulonimbus[middle]),
        (after.cover[middle], after.darkness[middle], after.stratocumulus[middle], after.altocumulus[middle], after.cumulonimbus[middle]),
        "the cell overhead is steady"
    );
    let still = r.clouds_of(ALICE).unwrap();
    assert_eq!((plain.cover, plain.darkness, plain.altocumulus, plain.base), (still.cover, still.darkness, still.altocumulus, still.base), "and so are her own shares");
    let sent = *r.atmosphere.cloud_calls.lock().unwrap() - calls;
    assert!(sent <= 10, "at most one send an evaluation while distant cells ease: {sent} in ten");
    println!("ok  clear sky: cover {:.2}, darkness {:.2}", fair.cover, fair.darkness);

    // The floor follows the dome: at the rim it is kilometres lower than at the axis.
    let rim = 0.9 * 59000.0;
    r.stand(ALICE, rim, 0.0, "tiamat_default_world:dirt");
    r.tick(41);
    let low = r.clouds_of(ALICE).unwrap().base.unwrap();
    let want = ((dome_y(rim, 0.0) + 400.0) / 64.0).floor() * 64.0;
    assert_eq!(f64::from(low), want, "the floor over the rim");
    assert!(floor - low > 1000.0, "the dome falls about 1.3 km from t=.5 to t=.9: {floor} to {low}");
    r.stand(ALICE, x, 100.0, "tiamat_default_world:dirt");
    r.tick(41);
    println!("ok  the cloud floor follows the dome: y {floor} at t=.5, y {low} at the rim");

    // Forecast answers, and survives.
    let forecast = r.reply(ALICE, "/weather forecast");
    assert!(forecast.starts_with("now: "), "{forecast}");

    // Run to a clock save and return the front string at the next tick.
    while r.now % 200 != 0 {
        r.tick(1);
    }
    r.tick(1);
    let reply = r.reply(ALICE, "/weather");
    let front = reply.split("front ").nth(1).unwrap().split(';').next().unwrap().to_owned();
    println!("ok  forecast `{forecast}`; front {front} at tick {}", r.now);
    front
}

// A restart resumes the clock: the same front at the same tick.
fn restart_check(storage: Arc<Storage>, front_before: &str) {
    let mut r = Rig::new(true, storage.clone());
    let x = 0.5 * 59000.0;
    r.stand(ALICE, x, 100.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 100.0) + 1.0, 100.0);
    r.tick(1);
    let reply = r.reply(ALICE, "/weather");
    let front = reply.split("front ").nth(1).unwrap().split(';').next().unwrap();
    assert_eq!(front, front_before, "the clock resumed where it was saved");
    assert!(storage.get(MOD, "tick").is_some());
    // The override set before the restart is still in force.
    assert!(reply.contains("forced for"), "{reply}");
    println!("ok  restart resumed the front {front} and the override");
}

// A blizzard on the Crown: layers grow to one block and no further; SNOW
// stops at two; nothing is ever the Spindle's snow; grass is left alone.
fn snow_check() {
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let (x, z) = (1500.0, 800.0);
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(1);
    let reply = r.reply(ALICE, "/weather");
    assert!(reply.contains("(freezing)"), "the Crown freezes: {reply}");

    // Some grass tufts, and one column already the Spindle's snow.
    let grass = r.material("tiamat_default_world:grass");
    let snow = r.material("tiamat_default_world:snow");
    for dx in -40..=40 {
        r.world.put(x as i32 + dx, top + 1, z as i32 + 3, grass, 1 << 4);
    }
    r.world.put(x as i32, top, z as i32 + 7, snow, FULL);

    r.say(ALICE, "/weather set blizzard 60");
    r.tick(20 * 60 * 6);
    let edits = r.edits_since(0);
    assert!(!edits.is_empty(), "six minutes of blizzard laid snow");
    for (_, pos, block, occ) in &edits {
        assert_eq!(block, "tiamat_weather:snow_layer", "only this mod's snow is written");
        assert!(pos.y == top + 1, "snow only ever sits directly on the ground, never on snow: y {}", pos.y);
        assert!([ONE_LAYER, TWO_LAYERS, FULL].contains(occ), "a stack of whole layers: {occ:#x}");
        assert!(!(pos.z == z as i32 + 3 && (pos.x - x as i32).abs() <= 40), "grass tufts are not supports");
        assert!(!(pos.x == x as i32 && pos.z == z as i32 + 7), "snow-covered ground gets nothing");
    }
    let full = edits.iter().filter(|e| e.3 == FULL).count();
    println!("ok  blizzard: {} snow edits, {full} columns at a full block, none above one block", edits.len());

    // Queue pacing: never two ticks in a row with edits, at most one batch
    // (six columns) a landing.
    let mut per_tick: BTreeMap<u64, usize> = BTreeMap::new();
    for e in &edits {
        *per_tick.entry(e.0).or_default() += 1;
    }
    for (tick, n) in &per_tick {
        assert!(*n <= 6, "{n} edits landed on tick {tick}");
        assert!(!per_tick.contains_key(&(tick + 1)), "edits on consecutive ticks {tick} and {}", tick + 1);
    }

    // SNOW caps at two layers: over a fresh floor, nothing reaches a full block.
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(1);
    r.say(ALICE, "/weather set snow 60");
    r.tick(20 * 60 * 6);
    let edits = r.edits_since(0);
    assert!(!edits.is_empty());
    assert!(edits.iter().all(|e| e.3 == ONE_LAYER || e.3 == TWO_LAYERS), "SNOW never passes two layers");
    let two = edits.iter().filter(|e| e.3 == TWO_LAYERS).count();
    println!("ok  snow: {} edits, {two} reached two layers, none more", edits.len());
}

// Warm and clear: sampled snow near the player thaws a layer at a time, and
// a random tick thaws snow nobody is near.
fn thaw_check() {
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let x = 0.5 * 59000.0;
    let z = 50.0;
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    r.join(ALICE, x, f64::from(top + 1), z);
    let snow = r.material("tiamat_weather:snow_layer");
    for dx in -40..=40 {
        for dz in -40..=40 {
            r.world.put(x as i32 + dx, top + 1, z as i32 + dz, snow, TWO_LAYERS);
        }
    }
    // A square only thaws near players if it snowed recently: force a brief
    // snow first, so the square remembers it, then clear it.
    r.tick(1);
    r.say(ALICE, "/weather set snow 1");
    r.tick(20 * 30);
    r.say(ALICE, "/weather set clear 30");
    let from = r.now;
    r.tick(20 * 60 * 2);
    let thaws: Vec<_> = r.edits_since(from).into_iter().filter(|e| e.3 == ONE_LAYER || e.2 == "engine:air").collect();
    assert!(!thaws.is_empty(), "warm clear weather thawed sampled snow");
    println!("ok  near-player thaw: {} layers melted in two minutes", thaws.len());

    // A random tick far from anyone, where it is warm and not snowing.
    let (fx, fz) = (x as i32 + 3000, z as i32);
    let far_top = dome_y(f64::from(fx), f64::from(fz)).floor() as i32;
    r.world.put(fx, far_top + 1, fz, snow, ONE_LAYER);
    let before = r.now;
    r.random_tick(fx, far_top + 1, fz);
    r.tick(3);
    let far: Vec<_> = r.edits_since(before).into_iter().filter(|e| e.1.x == fx && e.1.z == fz).collect();
    assert_eq!(far.len(), 1, "one thaw edit from the random tick");
    assert_eq!(far[0].2, "engine:air", "one layer melted to nothing");
    println!("ok  random-tick thaw far from players");
}

// The engine refusing an edit backs the queue off for 40 ticks.
fn queue_check() {
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let (x, z) = (1500.0, 800.0);
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(1);
    r.say(ALICE, "/weather set blizzard 60");
    r.tick(20 * 60);
    *r.world.refuse.lock().unwrap() = true;
    r.tick(200);
    let refused = *r.world.refused.lock().unwrap();
    // A landing every 2 ticks would try 100 times in 200 ticks; backing off
    // 40 ticks after each refusal tries about 5.
    assert!(refused >= 1 && refused <= 6, "refused {refused} times in 200 ticks");
    *r.world.refuse.lock().unwrap() = false;
    let from = r.now;
    r.tick(200);
    assert!(!r.edits_since(from).is_empty(), "the queue recovers");
    println!("ok  backoff: {refused} refusals in 200 ticks, then recovered");

    // Roofed columns get nothing: every column under a roof.
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    for dx in -60..=60 {
        for dz in -60..=60 {
            r.world.roofs.lock().unwrap().push((x as i32 + dx, z as i32 + dz));
        }
    }
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(1);
    r.say(ALICE, "/weather set blizzard 60");
    r.tick(20 * 60 * 2);
    assert!(r.edits_since(0).is_empty(), "no snow under a roof");
    println!("ok  nothing settles under a roof");
}

// Puddles: off by default, then on: rain leaves rainwater on open ground
// only, paced with the snow; rainwater meeting another fluid is let go, and
// against lava it goes as steam.
fn puddle_check() {
    let (x, z) = (0.5 * 59000.0, 60.0);
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(1);
    r.say(ALICE, "/weather set storm 30");
    r.tick(20 * 60 * 2);
    assert!(r.world.fluid_writes.lock().unwrap().is_empty(), "puddles are off by default");

    let mut r = Rig::with(true, Arc::new(Storage::default()), "wx_overrides = { puddles = true }");
    let top = r.stand(ALICE, x, z, "tiamat_default_world:dirt");
    // A band of logs: a whole block, but not ground, so never a puddle.
    let logs = r.material("tiamat_default_world:oak_log");
    for dx in -40..=40 {
        r.world.put(x as i32 + dx, top, z as i32 + 5, logs, FULL);
    }
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(1);
    r.say(ALICE, "/weather set rain 30");
    r.tick(20 * 60 * 2);
    // The one-cell write and clear over Alice's head is rainwater's id being
    // read off the world, once; everything else is a puddle.
    let all = r.world.fluid_writes.lock().unwrap().clone();
    let probes: Vec<_> = all.iter().filter(|w| w.1.y == top + 1 + 32).collect();
    assert_eq!(probes.len(), 2, "one probe, written and cleared: {probes:?}");
    assert!(!r.world.fluids.lock().unwrap().contains_key(&(probes[0].1.x, probes[0].1.y, probes[0].1.z)), "the probe left nothing");
    let writes: Vec<_> = all.iter().filter(|w| w.1.y != top + 1 + 32).cloned().collect();
    assert!(!writes.is_empty(), "two minutes of rain left puddles");
    for (_, pos, id, volume) in &writes {
        assert_eq!(*id, RAIN_ID, "only rainwater is written");
        assert!(*volume == 3 || *volume == 4, "a rain puddle is 3 cells, a storm's 4: {volume}");
        assert_eq!(pos.y, top + 1, "on the ground, in the open cell above it");
        assert!(!(pos.z == z as i32 + 5 && (pos.x - x as i32).abs() <= 40), "no puddle on a non-ground block");
    }
    let mut per_tick: BTreeMap<u64, usize> = BTreeMap::new();
    for e in &writes {
        *per_tick.entry(e.0).or_default() += 1;
    }
    for tick in per_tick.keys() {
        assert!(!per_tick.contains_key(&(tick + 1)), "puddles landed on consecutive ticks");
    }
    println!("ok  puddles: {} rainwater writes in two minutes of rain, none on logs, paced", writes.len());

    // The rain stops, and the puddles near Alice dry: a settled puddle is
    // never evaporated by the engine (ask W24), so the sampler clears it.
    let lying = r.world.fluids.lock().unwrap().values().filter(|(id, _)| *id == RAIN_ID).count();
    let river = (x as i32 + 3, top + 1, z as i32 - 3);
    r.world.fluids.lock().unwrap().insert(river, (WATER_ID, 5));
    r.say(ALICE, "/weather set clear 30");
    r.tick(20 * 60 * 4);
    let left = r.world.fluids.lock().unwrap().values().filter(|(id, _)| *id == RAIN_ID).count();
    assert!(lying > 0 && left * 2 <= lying, "{lying} puddles lying when the rain stopped, {left} four minutes later");
    assert!(r.world.fluids.lock().unwrap().contains_key(&river), "water that is not rainwater is left alone");
    r.world.fluids.lock().unwrap().remove(&river);
    println!("ok  puddles dry after the rain: {lying} lying, {left} four minutes later; other water untouched");

    // Rainwater pressing into a river: its block is cleared.
    let from = BlockPos::new(10, top + 1, 10);
    let into = BlockPos::new(11, top + 1, 10);
    r.world.fluids.lock().unwrap().insert((10, top + 1, 10), (RAIN_ID, 3));
    let before = r.particles.bursts.lock().unwrap().len();
    let flow = |fluid: &str, meets: &str, from: BlockPos, into: BlockPos| FluidFlowEvent {
        from, into, fluid: fluid.into(), volume: 3, blocked_by: MaterialId(0), occupancy: 0, meets: Some(meets.into()),
    };
    r.vm.fluid_flow(&flow("tiamat_weather:rainwater", "tiamat_default_world:water", from, into));
    assert!(r.vm.faulted_mods().is_empty());
    assert!(!r.world.fluids.lock().unwrap().contains_key(&(10, top + 1, 10)), "rainwater ran into the river");
    assert_eq!(r.particles.bursts.lock().unwrap().len(), before, "no steam from water");

    // Lava running into a puddle: the puddle goes, as steam.
    r.world.fluids.lock().unwrap().insert((11, top + 1, 10), (RAIN_ID, 3));
    r.vm.fluid_flow(&flow("tiamat_default_world:lava", "tiamat_weather:rainwater", from, into));
    assert!(!r.world.fluids.lock().unwrap().contains_key(&(11, top + 1, 10)), "the puddle boiled off");
    assert_eq!(r.particles.bursts.lock().unwrap().len(), before + 1, "steam");

    // Water meeting water, or terrain, is none of this mod's business.
    let writes_before = r.world.fluid_writes.lock().unwrap().len();
    r.vm.fluid_flow(&flow("tiamat_default_world:water", "tiamat_default_world:brine", from, into));
    r.vm.fluid_flow(&FluidFlowEvent { meets: None, ..flow("tiamat_weather:rainwater", "", from, into) });
    assert_eq!(r.world.fluid_writes.lock().unwrap().len(), writes_before, "other meetings untouched");
    println!("ok  rainwater let go into water, boiled off by lava, other meetings left alone");
}

// Exports, both ways, and the fault rules across the boundary.
fn exports_check() {
    let x = 0.25 * 59000.0;

    // 1. A Spindle that exports its climate and the two unlocks.
    let spindle = format!("{SPINDLE_STANDIN}\n{}", r#"
        aliases, harmless = {}, {}
        game.export{
            version = 1,
            humidity = game.density{ op = "const", value = 0.3 },
            HUMIDITY_SPLIT = -0.05,
            climate = function(x, z) return 0.5 end,
            biome_under = function(x, y, z) return "temperate_woodlands" end,
            add_soil_alias = function(block, dry) aliases[#aliases + 1] = block .. "=" .. dry; return true end,
            add_harmless_fluid = function(fluid) harmless[#harmless + 1] = fluid; return true end,
        }
        game.register_on_chat(function(event)
            if event.text == "/spindle" then
                table.sort(aliases)
                return table.concat(aliases, ",") .. ";" .. table.concat(harmless, ",")
            end
        end)
    "#);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 0.0) + 1.0, 0.0);
    r.tick(41);
    let reply = r.reply(ALICE, "/weather");
    assert!(reply.contains("humidity exported, warmth exported, biomes exported"), "{reply}");
    assert!(reply.contains("moisture 0.3"), "the exported humidity is read: {reply}");
    assert!((number_after(&reply, "warmth ") - 500.0).abs() <= 2.0, "the exported climate (0.5), less a block of lapse: {reply}");
    assert!(reply.contains("damp ground on, puddles on"), "both unlocked: {reply}");
    assert!(r.materials.contains_key("tiamat_weather:damp_dirt"));
    let told = r.reply(ALICE, "/spindle");
    // Fire (2026-09-23) asks for scorched ground to be soil too, so its grass grows back.
    assert_eq!(told, "tiamat_weather:damp_dirt=tiamat_default_world:dirt,tiamat_weather:damp_packed_dirt=tiamat_default_world:packed_dirt,tiamat_weather:damp_sand=tiamat_default_world:sand,tiamat_weather:scorched_ground=tiamat_default_world:dirt;tiamat_weather:rainwater");
    println!("ok  Spindle exports read: humidity, climate, biomes; damp ground, puddles and scorched ground unlocked by its answers");

    // 2. The Spindle's exported function errors: the SPINDLE is disabled, the
    // call answers nil, and weather carries on with its mirror.
    let broken = format!("{SPINDLE_STANDIN}\n{}", r#"
        game.export{ version = 1, climate = function(x, z) error("the ring table is gone") end }
    "#);
    let mut r = Rig::custom(Some(&broken), Arc::new(Storage::default()), "", &[]);
    r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 0.0) + 1.0, 0.0);
    r.tick(41);
    let reply = r.reply(ALICE, "/weather");
    assert!(r.vm.faulted_mods().iter().any(|m| m == "tiamat_default_world"), "the owner of the failing export is disabled");
    assert!((number_after(&reply, "warmth ") - 750.0).abs() <= 2.0, "weather fell back to its mirrored 4t(1-t): {reply}");
    r.tick(200);
    println!("ok  a faulting Spindle export disabled the Spindle, not weather; the mirror took over");

    // 3. No exports at all (the Spindle as it is today): the mirror, both off.
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 0.0) + 1.0, 0.0);
    r.tick(1);
    let reply = r.reply(ALICE, "/weather");
    assert!(reply.contains("humidity mirrored, warmth mirrored, biomes ground"), "{reply}");
    assert!(reply.contains("damp ground off, puddles off"), "{reply}");
    println!("ok  a Spindle with no exports: mirrored climate, damp ground and puddles stay off");

    // 4. The drift check, which with the fields exported compares them with
    // the mirror directly: the real Spindle publishes the same humidity
    // program and the same Newton climate, so every point must agree.
    let same = format!("{SPINDLE_STANDIN}\n{}", r#"
        game.export{
            version = 1,
            HUMIDITY_SPLIT = -0.05,
            humidity = game.density{
                op = "clamp", low = -0.5, high = 0.5,
                a = { op = "noise", stream = "humidity", frequency = 1 / 9000, octaves = 2,
                      amplitude = 1.0, stretch = { y = 1000 } },
            },
            climate = function(x, z)
                local u = (x * x + z * z) * 1e-6 / (59.0 * 59.0)
                if u < 1e-8 then return 0.0 end
                local g = 1.0
                for _ = 1, 20 do g = 0.5 * (g + u / g) end
                if g > 1.0 then g = 1.0 end
                return 4.0 * g * (1.0 - g)
            end,
        }
    "#);
    let mut r = Rig::custom(Some(&same), Arc::new(Storage::default()), "", &[]);
    r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 0.0) + 1.0, 0.0);
    r.tick(1);
    let drift = r.reply(ALICE, "/weather drift");
    assert!(drift.starts_with("the mirror matches the Spindle's exported fields at all 121 points"), "{drift}");
    assert!(drift.contains("worst gap 0.000000000"), "bit for bit: {drift}");
    println!("ok  drift: `{drift}`");

    // A humidity of a different frequency is caught at once.
    let stale = format!("{SPINDLE_STANDIN}\n{}", r#"
        game.export{
            version = 1,
            humidity = game.density{
                op = "clamp", low = -0.5, high = 0.5,
                a = { op = "noise", stream = "humidity", frequency = 1 / 4000, octaves = 2,
                      amplitude = 1.0, stretch = { y = 1000 } },
            },
        }
    "#);
    let mut r = Rig::custom(Some(&stale), Arc::new(Storage::default()), "", &[]);
    r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 0.0) + 1.0, 0.0);
    r.tick(1);
    let drift = r.reply(ALICE, "/weather drift");
    assert!(drift.starts_with("the mirror no longer matches"), "a retuned field is caught: {drift}");
    println!("ok  drift catches a retuned field: `{drift}`");

    // 5. Weather's own exports, read by a mod that optionally depends on it.
    let probe = r#"
        local wx = game.exports("tiamat_weather")
        game.register_on_chat(function(event)
            if event.text ~= "/probe" then return end
            if wx == nil then return "no exports" end
            local kind, intensity, label = wx.weather_for(event.player)
            local falling = wx.falling_on(event.player)
            local bad = wx.warmth("not a number", {}, nil)
            local wrote = pcall(function() wx.kinds.rain = "mine" end)
            local nobody = wx.weather_for("0000")
            return string.format("%s %s %s|%s|%s|%s|%s|%s|%s", tostring(kind), tostring(intensity), tostring(label),
                tostring(falling), tostring(bad), tostring(wrote), tostring(nobody), wx.kinds.storm.family, wx.climate)
        end)
    "#;
    let mut r = Rig::custom(Some(SPINDLE_STANDIN), Arc::new(Storage::default()), "",
        &[("tiamat_default_life", probe, &["tiamat_weather"])]);
    r.stand(ALICE, x, 0.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 0.0) + 1.0, 0.0);
    r.tick(1);
    r.say(ALICE, "/weather set storm 10");
    r.tick(40 * 25);
    let probed = r.reply(ALICE, "/probe");
    assert_eq!(probed, "storm 1000 Storm|rain|nil|false|nil|rain|spindle", "{probed}");
    assert!(!r.vm.faulted_mods().iter().any(|m| m == "tiamat_default_life"), "bad arguments cost the caller nothing");
    println!("ok  weather's exports: `{probed}` (bad arguments answer nil, writes are refused, nothing faulted)");
}

// Mega storms: everything a storm does, turned up to 11, about twice a year
// at any one place.
fn mega_check() {
    let x = 0.5 * 59000.0;
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    r.stand(ALICE, x, 100.0, "tiamat_default_world:dirt");
    r.join(ALICE, x, dome_y(x, 100.0) + 1.0, 100.0);
    r.tick(41);

    // A plain storm first, to measure the mega storm against.
    r.say(ALICE, "/weather set storm 10");
    r.tick(40 * 25);
    let storm_rain = r.rain_of(ALICE).expect("storm rain");
    let storm_sky = r.sky_of(ALICE).expect("storm sky");
    let storm_flashes = r.atmosphere.flashes.lock().unwrap().len();
    r.tick(40 * 100);
    let storm_strikes = r.atmosphere.flashes.lock().unwrap().len() - storm_flashes;

    let set = r.reply(ALICE, "/weather set mega 10");
    assert!(set.starts_with("mega over square"), "{set}");
    r.tick(40 * 25);
    assert_eq!(r.hud(ALICE), "Mega storm");
    let reply = r.reply(ALICE, "/weather");
    assert!(reply.contains("mega storm 1000"), "{reply}");
    let rain = r.rain_of(ALICE).expect("mega rain");
    let sky = r.sky_of(ALICE).expect("mega sky");
    assert!(f64::from(rain.rate) >= 1.8 * f64::from(storm_rain.rate), "rain {} against a storm's {}", rain.rate, storm_rain.rate);
    assert!(f64::from(rain.rate) <= 4000.0, "under the engine's cap: {}", rain.rate);
    assert!(rain.burst.size > storm_rain.burst.size && rain.burst.velocity[1] < storm_rain.burst.velocity[1], "bigger, harder: {:?}", rain.burst);
    assert!(sky.intensity < 0.8 * storm_sky.intensity, "darker: {} against {}", sky.intensity, storm_sky.intensity);
    assert!(sky.fog_distance < 0.8 * storm_sky.fog_distance, "closer fog: {} against {}", sky.fog_distance, storm_sky.fog_distance);
    let clouds = r.clouds_of(ALICE).expect("mega clouds");
    assert!(clouds.cumulonimbus >= 0.99 && clouds.darkness >= 0.99, "supercells, black to the base: {clouds:?}");
    assert!(clouds.cover < 0.5, "and not a full cumulus deck under them as well: {clouds:?}");
    let before = r.atmosphere.flashes.lock().unwrap().len();
    r.tick(40 * 100);
    let strikes = r.atmosphere.flashes.lock().unwrap().len() - before;
    assert!(strikes >= 2 * storm_strikes.max(1), "{strikes} strikes against a storm's {storm_strikes} in the same time");
    println!("ok  mega storm: rain {}/s against {}/s, sky {:.2} against {:.2}, fog {:.2} against {:.2}, {strikes} strikes against {storm_strikes}",
        rain.rate, storm_rain.rate, sky.intensity, storm_sky.intensity, sky.fog_distance, storm_sky.fog_distance);

    // In the cold it is a mega blizzard, with thundersnow.
    let rim = 0.99 * 59000.0;
    r.stand(ALICE, rim, 0.0, "tiamat_default_world:dirt");
    r.tick(41);
    r.say(ALICE, "/weather set mega 10");
    r.tick(40 * 25);
    assert_eq!(r.hud(ALICE), "Mega blizzard");
    println!("ok  a mega storm in the cold is a mega blizzard");
    r.say(ALICE, "/weather clear");

    // The schedule: about twice a year at any one place, counted over ten
    // years at forty places.
    let (mut any, mut strong) = (0.0, 0.0);
    let places = 40;
    for i in 0..places {
        let px = f64::from((i * 7919) % 50000 + 4000);
        let pz = f64::from((i * 104_729) % 40000 - 20000);
        r.stand(ALICE, px, pz, "tiamat_default_world:dirt");
        let said = r.reply(ALICE, "/weather mega 10");
        let head = said.split(" mega storms pass").next().unwrap_or_default();
        any += head.rsplit(|c: char| !c.is_ascii_digit()).next().and_then(|n| n.parse::<f64>().ok())
            .unwrap_or_else(|| panic!("no count in `{said}`"));
        strong += number_after(&said, "years, ");
    }
    let per_year = any / f64::from(places) / 10.0;
    let strong_per_year = strong / f64::from(places) / 10.0;
    assert!((1.4..=2.8).contains(&per_year), "{per_year:.2} mega storms a year at a place");
    assert!((1.4..=2.6).contains(&strong_per_year), "{strong_per_year:.2} strong ones a year");
    let said = r.reply(ALICE, "/weather mega");
    assert!(said.contains("the next in"), "{said}");
    println!("ok  mega storms: {per_year:.2} a year at a place, {strong_per_year:.2} strong; `{said}`");
}

// --- Fire --------------------------------------------------------------------
//
// The fire contract's names and numbers (config.lua's fire section, spec
// 2026-09-23), mirrored here so a retuned cap fails a check rather than
// passing quietly. "Not out of control" is the first requirement, so most of
// what follows is caps: how many blocks, how far, how many blazes, how long.

const FIRE_MAX_BLAZES: usize = 4;
const FIRE_MAX_BURNING: usize = 120;
const FIRE_FOREST_BLOCKS: usize = 60;
const FIRE_FOREST_RADIUS: i32 = 12;
const FIRE_FIELD_BLOCKS: usize = 90;
const FIRE_FIELD_RADIUS: i32 = 16;
const STRIKE_ABOVE: i32 = 40;
const FIRE: &str = "tiamat_weather:fire";
const CHARRED: &str = "tiamat_weather:charred_log";
const SCORCHED: &str = "tiamat_weather:scorched_ground";
const AIR: &str = "engine:air";
const DIRT: &str = "tiamat_default_world:dirt";
const GRASS: &str = "tiamat_default_world:grass";
const LEAVES: &str = "tiamat_default_world:oak_leaves";
const LOGS: &str = "tiamat_default_world:oak_log";
const TUFT: &str = "tiamat_default_world:tall_grass";
/// A two-cell tuft: the middle column of a block, two cells tall.
const TUFT_CELLS: u32 = (1 << 10) | (1 << 13);

/// Where the fire checks stand: the warm ring, off the weather_check's square.
const FIRE_X: f64 = 0.5 * 59000.0;
const FIRE_Z: f64 = 300.0;

// A stand-in Spindle whose climate is a constant, so a check can choose dry
// country or wet: `humidity` is the moisture the adapter reads, `climate` the
// warmth in 0..1.
fn spindle_exporting(humidity: f64, climate: f64) -> String {
    format!(
        "{SPINDLE_STANDIN}\ngame.export{{ version = 1, humidity = game.density{{ op = 'const', value = {humidity} }}, \
         climate = function(x, z) return {climate} end }}"
    )
}

// Alice on `floor` at (x, z), her square forced clear for an hour and given
// time to ease there: a check about fire must not have the natural weather
// raining on it.
fn clear_day(r: &mut Rig, x: f64, z: f64, floor: &str) -> i32 {
    let top = r.stand(ALICE, x, z, floor);
    r.join(ALICE, x, f64::from(top + 1), z);
    r.tick(41);
    let set = r.reply(ALICE, "/weather set clear 60");
    assert!(set.starts_with("clear over square"), "{set}");
    r.tick(40 * 25);
    top
}

// A small wood: a 7x7 canopy of oak leaves three deep at top+4..top+6 on four
// trunks at top+1..top+5, centred on (cx, cz). The trunks run up INTO the
// canopy, as the Spindle's do (an oak's crown clump is centred on its trunk
// top and its branch tips sit inside their clumps): a crown fire surrounds
// the wood. Trunks that stopped under the leaves got one attempt in
// twenty-six from the leaf above and none once the blaze hit its cap, and
// no trunk ever charred. Answers where the leaves are.
fn plant_wood(r: &Rig, cx: i32, top: i32, cz: i32) -> Vec<(i32, i32, i32)> {
    let leaves = r.material(LEAVES);
    let logs = r.material(LOGS);
    let mut crown = Vec::new();
    for dx in -3..=3 {
        for dz in -3..=3 {
            for y in top + 4..=top + 6 {
                r.world.put(cx + dx, y, cz + dz, leaves, FULL);
                crown.push((cx + dx, y, cz + dz));
            }
        }
    }
    for (dx, dz) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
        for y in top + 1..=top + 5 {
            r.world.put(cx + dx, y, cz + dz, logs, FULL);
        }
    }
    crown.retain(|(x, y, z)| r.world.at(*x, *y, *z).0 == leaves);
    crown
}

// A meadow: two-cell tufts on every block of a square of side 2 * half + 1
// at y, centred on (cx, cz). The floor under them is the rig's.
fn plant_meadow(r: &Rig, cx: i32, y: i32, cz: i32, half: i32) {
    let tufts = r.material(TUFT);
    for dx in -half..=half {
        for dz in -half..=half {
            r.world.put(cx + dx, y, cz + dz, tufts, TUFT_CELLS);
        }
    }
}

// Horizontal Chebyshev distance, which is the radius the blaze caps use.
fn across(a: &BlockPos, cx: i32, cz: i32) -> i32 {
    (a.x - cx).abs().max((a.z - cz).abs())
}

// A leaf of the wood that is still a leaf: what a second fire could start on.
fn fresh_leaf(r: &Rig, crown: &[(i32, i32, i32)]) -> (i32, i32, i32) {
    let leaves = r.material(LEAVES);
    *crown.iter().find(|(x, y, z)| r.world.at(*x, *y, *z).0 == leaves).expect("some of the wood is left")
}

// A dry wood set alight by command burns as ONE blaze: no further than the
// forest radius, no more blocks than the forest cap, never over the world
// cap, and out by itself, leaving charred trunks and air where leaves were.
// It is heard as a loop that starts and stops and seen as smoke that rises.
fn fire_forest_check() {
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    let crown = plant_wood(&r, cx, top, cz);
    let from = r.now;
    let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {cz}", top + 6));
    assert!(lit.starts_with("lit at"), "{lit}");
    let peak = r.burn(20 * 60 * 4);

    let fires = r.ignitions_since(from);
    assert!(fires.len() >= 10, "a dry wood catches: only {} blocks lit", fires.len());
    assert!(fires.len() <= FIRE_FOREST_BLOCKS, "one forest blaze lights at most {FIRE_FOREST_BLOCKS}: {}", fires.len());
    for (_, pos, _, _) in &fires {
        let far = across(pos, cx, cz);
        assert!(far <= FIRE_FOREST_RADIUS, "a fire {far} blocks from the origin, past {FIRE_FOREST_RADIUS}");
    }
    assert_eq!(r.fires_in_world(), 0, "burnt out on its own");
    let charred = r.edits_named(from, CHARRED).len();
    assert!(charred > 0, "a trunk burnt to charred wood");
    let cleared = r.edits_named(from, AIR).iter().filter(|e| crown.contains(&(e.1.x, e.1.y, e.1.z))).count();
    assert!(cleared > 0, "a leaf burnt to air");

    let loops = r.sounds.loops.lock().unwrap().clone();
    let crackle: Vec<_> = loops.iter().filter(|l| l.0.contains("fire_")).collect();
    assert!(!crackle.is_empty(), "the blaze is heard: {loops:?}");
    assert!(crackle.iter().all(|l| l.1.ends_with("fire")), "with the fire sound: {crackle:?}");
    assert!(r.sounds.stops.lock().unwrap().iter().any(|s| s.contains("fire_")), "and its loop stopped when it ended");
    let smoke = r.particles.bursts.lock().unwrap().iter().filter(|(_, b)| b.burst.count >= 6 && b.burst.gravity < 0.0).count();
    assert!(smoke > 0, "smoke rose from it");

    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with("0 blazes alight, 0 blocks burning"), "{said}");
    assert!(number_after(&said, "burnt ") > 0.0, "{said}");
    println!(
        "ok  forest fire: {} blocks lit (cap {FIRE_FOREST_BLOCKS}), {peak} alight at most, {charred} trunks charred, {cleared} leaves gone, {} loop calls, {smoke} smoke bursts; `{said}`",
        fires.len(), crackle.len());
}

// A meadow lit in the middle burns as a FIELD blaze: wider than a wood and
// with its own cap, and where a tuft burnt out over whole turf the turf is
// scorched. In dry, warm country it is a fire and not one tuft that went
// out — the tuft's burn time was tuned for exactly that (plan 5.12), and
// this is what holds the tuning — and it ends, and leaves a mark.
fn fire_field_check() {
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, GRASS);
    let (ax, az) = (FIRE_X as i32, FIRE_Z as i32);
    plant_meadow(&r, ax, top + 1, az, 12);
    let from = r.now;
    let lit = r.reply(ALICE, &format!("/weather fire at {ax} {} {az}", top + 1));
    assert!(lit.starts_with("lit at"), "{lit}");
    let peak = r.burn(20 * 60 * 4);

    let fires = r.ignitions_since(from);
    assert!(fires.len() >= 10, "a dry meadow carries a field fire: only {} tufts lit", fires.len());
    assert!(fires.len() <= FIRE_FIELD_BLOCKS, "a field blaze lights at most {FIRE_FIELD_BLOCKS}: {}", fires.len());
    let scorched = r.edits_named(from, SCORCHED);
    assert!(!scorched.is_empty(), "a field fire leaves a black patch");
    for (_, pos, block, _) in fires.iter().chain(scorched.iter()) {
        assert!(across(pos, ax, az) <= FIRE_FIELD_RADIUS, "{block} at {pos:?}, past the field radius {FIRE_FIELD_RADIUS}");
        let want = if block == FIRE { top + 1 } else { top };
        assert_eq!(pos.y, want, "{block} at {pos:?}: fire in the tufts, scorching in the turf under them");
    }
    assert_eq!(r.fires_in_world(), 0, "burnt out");
    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with("0 blazes alight, 0 blocks burning"), "{said}");
    assert!(number_after(&said, "scorched ") > 0.0, "{said}");
    println!("ok  field fire: {} tufts lit (cap {FIRE_FIELD_BLOCKS}), {peak} alight at most, {} blocks of turf scorched; `{said}`",
        fires.len(), scorched.len());
}

// Rain puts a fire out: a wood well alight when a storm is forced over it
// is out within a couple of minutes, some of it doused rather than burnt,
// and each dousing hisses.
fn fire_rain_check() {
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    plant_wood(&r, cx, top, cz);
    let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {cz}", top + 6));
    assert!(lit.starts_with("lit at"), "{lit}");
    // Well alight: thirty turns should do it; a slow start gets a little more.
    let mut waited = 300;
    r.tick(300);
    while r.fires_in_world() <= 3 && waited < 900 {
        r.tick(100);
        waited += 100;
    }
    let alight = r.fires_in_world();
    assert!(alight > 3, "well alight after {waited} ticks: {alight} blocks");

    let set = r.reply(ALICE, "/weather set storm 5");
    assert!(set.starts_with("storm over square"), "{set}");
    r.burn(20 * 60);
    let after_minute = r.fires_in_world();
    // The storm eases in over forty seconds and a trunk burns for forty-five,
    // so the last of it may outlast the minute; it must not outlast two more.
    let mut extra = 0;
    while r.fires_in_world() > 0 && extra < 20 * 60 * 2 {
        r.burn(200);
        extra += 200;
    }
    assert_eq!(r.fires_in_world(), 0, "the rain put it out ({extra} ticks past the first minute)");
    let said = r.reply(ALICE, "/weather fires");
    let doused = number_after(&said, "doused ");
    assert!(doused > 0.0, "some of it was doused, not burnt: {said}");
    // A dry wood burns out by itself inside this wait, so "nothing alight"
    // alone would not show the rain did it: most of it must have been doused.
    let burnt = number_after(&said, "burnt ");
    assert!(doused > burnt, "the rain, not the fuel, ended it: {said}");
    assert!(r.sounds.plays.lock().unwrap().iter().any(|s| s.ends_with("douse")), "the hiss of a fire put out");
    println!("ok  rain: {alight} alight when the storm came, {after_minute} a minute later, out {extra} ticks after that, {doused} doused; `{said}`");
}

// Wet country does not burn: the same wood under a humidity of 0.45 fizzles.
fn fire_wet_check() {
    let spindle = spindle_exporting(0.45, 0.6);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    plant_wood(&r, cx, top, cz);
    let from = r.now;
    let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {cz}", top + 6));
    assert!(lit.starts_with("lit at"), "a wet leaf still lights when forced: {lit}");
    r.burn(20 * 60 * 4);
    let fires = r.ignitions_since(from);
    assert!(fires.len() < 15, "a wet wood fizzles: {} blocks lit", fires.len());
    assert_eq!(r.fires_in_world(), 0);
    println!("ok  wet wood: {} blocks lit before it fizzled", fires.len());
}

// The caps, and the command's replies: four blazes at once and no fifth, a
// burning block is "burning", nothing under the crosshair is a message not
// an error, bad coordinates are the usage line, `out` puts everything out,
// and none of it for a player who is not an operator.
fn fire_caps_check() {
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (ax, az) = (FIRE_X as i32, FIRE_Z as i32);
    let mut replies = Vec::new();
    for i in 0..5 {
        let cx = ax - 120 + 60 * i;
        plant_wood(&r, cx, top, az);
        replies.push(r.reply(ALICE, &format!("/weather fire at {cx} {} {az}", top + 6)));
    }
    let lit = replies.iter().filter(|s| s.starts_with("lit at")).count();
    assert_eq!(lit, FIRE_MAX_BLAZES, "{replies:?}");
    assert!(replies[4].contains("cap"), "the fifth is refused by the cap: {replies:?}");
    let again = r.reply(ALICE, &format!("/weather fire at {} {} {az}", ax - 120, top + 6));
    assert!(again.starts_with("nothing lit at") && again.ends_with("burning"), "already alight: {again}");
    assert_eq!(r.reply(ALICE, "/weather fire"), "look at something to set it alight");
    assert_eq!(r.reply(ALICE, "/weather fire at here"), "usage: /weather fire [at <x> <y> <z> | out]");
    assert_eq!(r.reply(BOB, "/weather fire out"), "only an operator can change the weather");
    assert_eq!(r.reply(BOB, &format!("/weather fire at {ax} {} {az}", top + 6)), "only an operator can change the weather");

    r.tick(12);
    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with(&format!("{FIRE_MAX_BLAZES} blazes alight")), "{said}");
    let out = r.reply(ALICE, "/weather fire out");
    assert!(out.ends_with(" burning blocks put out"), "{out}");
    let put_out: usize = out.split(' ').next().and_then(|n| n.parse().ok()).unwrap_or_else(|| panic!("no count in `{out}`"));
    assert!(put_out >= FIRE_MAX_BLAZES, "{out}");
    r.tick(200);
    assert_eq!(r.fires_in_world(), 0, "all out");
    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with("0 blazes alight, 0 blocks burning"), "{said}");

    // The WORLD cap. Four fresh woods lit together would put some 230 blocks
    // alight between them; `burn` looks every 200 ticks and holds each look
    // under FIRE_MAX_BURNING, and more than one blaze's worth is alight at
    // the peak, so it is the world cap and not a blaze's that held it there.
    let from = r.now;
    for i in 0..4 {
        let cx = ax - 120 + 60 * i;
        plant_wood(&r, cx, top, az + 60);
        let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {}", top + 6, az + 60));
        assert!(lit.starts_with("lit at"), "the slots are free again: {lit}");
    }
    let peak = r.burn(600);
    assert!(peak > FIRE_FOREST_BLOCKS, "four woods together put more than one blaze's worth alight: {peak} at most");
    let together = r.ignitions_since(from).len();
    assert!(together > FIRE_FOREST_BLOCKS, "more than one blaze's cap lit across four: {together}");
    assert!(r.reply(ALICE, "/weather fire out").ends_with(" burning blocks put out"));
    r.tick(200);
    assert_eq!(r.fires_in_world(), 0, "all out again");
    println!("ok  caps: {lit} of 5 woods lit at once, the fifth `{}`; `{out}`; four together: {together} lit, {peak} alight at most under the world cap of {FIRE_MAX_BURNING}", replies[4]);
}

// A square that had a blaze rests: another mod's `ignite` lit the first one
// and is refused there afterwards, an operator's forced one is not, and once
// the rest is over (FIRE_REST_TICKS, a game day, a minute in this rig) the
// export lights there again. Also the exports round trip: `flammable`,
// `fire_at`, `fires`, `extinguish`, read by a mod loaded after weather.
fn fire_rest_check() {
    let reader = r#"
        local wx = game.exports("tiamat_weather")
        game.register_on_chat(function(event)
            local name, rest = string.match(event.text, "^%s*/(%S+)%s*(.-)%s*$")
            if wx == nil or name == nil then return nil end
            local args = {}
            for word in string.gmatch(rest, "%S+") do args[#args + 1] = word end
            local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
            if name == "lightit" then return tostring(wx.ignite(x, y, z)) end
            if name == "burning" then return tostring(wx.fire_at(x, y, z)) end
            if name == "flammable" then return tostring(wx.flammable(x, y, z)) end
            if name == "putout" then return tostring(wx.extinguish(x, y, z)) end
            if name == "fires" then
                local blocks, blazes = wx.fires()
                return tostring(blocks) .. "," .. tostring(blazes)
            end
            return nil
        end)
    "#;
    let spindle = spindle_exporting(-0.35, 0.6);
    let prelude = "wx_overrides = { FIRE_REST_TICKS = 1200 }";
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), prelude, &[("fire_reader", reader, &["tiamat_weather"])]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    let crown = plant_wood(&r, cx, top, cz);
    let leaf = format!("{cx} {} {cz}", top + 6);
    assert_eq!(r.reply(ALICE, &format!("/flammable {leaf}")), "true", "a leaf is fuel");
    assert_eq!(r.reply(ALICE, &format!("/flammable {} {top} {}", FIRE_X as i32, FIRE_Z as i32)), "false", "dirt is not");
    assert_eq!(r.reply(ALICE, &format!("/burning {leaf}")), "false");
    assert_eq!(r.reply(ALICE, "/fires"), "0,0");

    // Lit THROUGH the export, so its natural path is seen to succeed before
    // it is seen to refuse: a `false` below would otherwise prove nothing.
    assert_eq!(r.reply(ALICE, &format!("/lightit {leaf}")), "true", "a fresh square takes another mod's ignite");
    // Two turns: one for the edit to land, one for the fire to see it did.
    r.tick(25);
    assert_eq!(r.reply(ALICE, &format!("/burning {leaf}")), "true", "the lit leaf is burning");
    let counted = r.reply(ALICE, "/fires");
    assert!(counted.ends_with(",1") && !counted.starts_with("0,"), "one blaze, something alight: {counted}");
    // Until the blaze ends, not a fixed while: the rest is counted from its
    // end, and this rig's rest is short.
    let mut waited = 0;
    loop {
        r.burn(200);
        waited += 200;
        if r.reply(ALICE, "/weather fires").starts_with("0 blazes alight") || waited >= 20 * 60 * 5 {
            break;
        }
    }
    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with("0 blazes alight"), "the blaze has ended: {said}");
    assert!(!r.vm.faulted_mods().iter().any(|m| m == "fire_reader"), "the reader survived every call");

    // The square rests: natural ignition refused, forced allowed.
    let (fx, fy, fz) = fresh_leaf(&r, &crown);
    let fresh = format!("{fx} {fy} {fz}");
    assert_eq!(r.reply(ALICE, &format!("/lightit {fresh}")), "false", "a resting square refuses another mod's ignite");
    assert_eq!(r.fires_in_world(), 0);
    let forced = r.reply(ALICE, &format!("/weather fire at {fresh}"));
    assert!(forced.starts_with("lit at"), "an operator may still force one: {forced}");
    r.tick(25);
    assert_eq!(r.reply(ALICE, &format!("/burning {fresh}")), "true");
    let before = r.now;
    assert_eq!(r.reply(ALICE, &format!("/putout {fresh}")), "true", "another mod may put it out");
    r.tick(25);
    let gone = r.edits_since(before).iter().any(|e| e.2 == AIR && (e.1.x, e.1.y, e.1.z) == (fx, fy, fz));
    assert!(gone, "the put-out fire went to air");
    assert_eq!(r.reply(ALICE, &format!("/burning {fresh}")), "false");

    // And the rest ends: FIRE_REST_TICKS after the last blaze in the square
    // ended, the export lights there again.
    r.tick(1300);
    let (gx, gy, gz) = fresh_leaf(&r, &crown);
    assert_eq!(r.reply(ALICE, &format!("/lightit {gx} {gy} {gz}")), "true", "the rest is over");
    let counted = r.reply(ALICE, "/fires");
    assert!(counted.ends_with(",1"), "a new blaze by the export: {counted}");
    println!("ok  rest: the reader's ignite lit a wood; after the blaze the square refused it and took the operator's, and took it again once the rest was over; exports flammable/fire_at/fires/extinguish answered");
}

// A restart mid-blaze: the fire state is in storage, so a new rig on the
// same storage and the same ground carries the fire on to its end.
fn fire_restart_check() {
    let spindle = spindle_exporting(-0.35, 0.6);
    let storage = Arc::new(Storage::default());
    let mut r = Rig::custom(Some(&spindle), storage.clone(), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    plant_wood(&r, cx, top, cz);
    let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {cz}", top + 6));
    assert!(lit.starts_with("lit at"), "{lit}");
    r.tick(300);
    let alight = r.fires_in_world();
    assert!(alight > 0, "alight at the restart");
    let saved: Vec<String> = storage.keys(MOD).into_iter().filter(|k| k.starts_with("fire:")).collect();
    assert!(saved.iter().any(|k| k.starts_with("fire:blaze:")), "the blaze is in storage: {saved:?}");

    let mut again = Rig::custom(Some(&spindle), storage.clone(), "", &[]);
    again.world.copy_from(&r.world);
    again.stand(ALICE, FIRE_X, FIRE_Z, DIRT);
    again.join(ALICE, FIRE_X, f64::from(top + 1), FIRE_Z);
    assert_eq!(again.fires_in_world(), alight, "the same ground");
    // The load is the first tick's and a turn is ten ticks later, so this is
    // storage as saved, before anything could burn out of it. The save at the
    // restart ran after that tick's turn, so every fire block in the world
    // was pushed by a turn it covers: what is restored is at least the world.
    again.tick(1);
    let said = again.reply(ALICE, "/weather fires");
    assert!(said.starts_with("1 blazes alight"), "the blaze is back: {said}");
    let restored = number_before(&said, " blocks burning");
    assert!(restored >= alight, "every block in the world is in storage: {restored} restored, {alight} in the world");
    again.tick(40);
    again.burn(20 * 60 * 4);
    let went_on = again.ignitions_since(0).len() + again.edits_named(0, CHARRED).len() + again.edits_named(0, AIR).len();
    assert!(went_on > 0, "the fire went on after the restart");
    // For the same reason no block in the world was lit after the save, so
    // none is an orphan for the random tick: the restored blaze put every
    // one of them out itself.
    let fire = again.material(FIRE);
    let orphans: Vec<(i32, i32, i32)> =
        again.world.blocks.lock().unwrap().iter().filter(|(_, (m, _))| *m == fire).map(|(p, _)| *p).collect();
    assert!(orphans.is_empty(), "every block in the world was in storage: {orphans:?}");
    assert_eq!(again.fires_in_world(), 0, "the restored blaze burnt out");
    let said = again.reply(ALICE, "/weather fires");
    assert!(said.starts_with("0 blazes alight, 0 blocks burning"), "{said}");
    println!("ok  restart: {alight} alight at the restart, {restored} restored from storage, {went_on} edits after it, no orphans; `{said}`");
}

// A blaze whose chunk goes away under it: `get_block` answers nil there, so
// nothing is seen and nothing is edited, and once every fire would have
// burnt out had anyone been watching, the blaze ends by itself. Left as it
// was, a blaze in a chunk nobody revisits would hold a slot, its block count
// and FIRE_APART round its origin for ever, and four of them would end fire
// world-wide. The blocks left in the chunk are orphans for the random tick
// when it is loaded again.
fn fire_unloaded_check() {
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    plant_wood(&r, cx, top, cz);
    let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {cz}", top + 6));
    assert!(lit.starts_with("lit at"), "{lit}");
    r.tick(300);
    assert!(r.fires_in_world() > 3, "well alight");

    // The ground under the wood is unloaded. The queue's tail lands first.
    r.world.unloaded.lock().unwrap().push(((cx - 20, cz - 20), (cx + 20, cz + 20)));
    r.tick(20);
    let alight = r.fires_in_world();
    let from = r.now;
    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with("1 blazes alight"), "a blaze whose fires may yet be burning: {said}");
    // The longest fuel here is a log at 900 ticks, then the confirm time,
    // from the last block lit before the chunk went; a minute and a half
    // covers the lot.
    r.tick(20 * 60 + 200);
    assert!(r.edits_since(from).is_empty(), "nothing is edited in a chunk nobody has loaded");
    assert_eq!(r.fires_in_world(), alight, "the blocks sit in the saved chunk as they were");
    let said = r.reply(ALICE, "/weather fires");
    assert!(said.starts_with("0 blazes alight, 0 blocks burning"), "the blaze ended without its chunk: {said}");
    assert!(r.sounds.stops.lock().unwrap().iter().any(|s| s.contains("fire_")), "and its loop stopped");

    // Loaded again, the blocks are orphans: their random ticks put them out.
    r.world.unloaded.lock().unwrap().clear();
    let fire = r.material(FIRE);
    let orphans: Vec<(i32, i32, i32)> =
        r.world.blocks.lock().unwrap().iter().filter(|(_, (m, _))| *m == fire).map(|(p, _)| *p).collect();
    assert_eq!(orphans.len(), alight, "every block left is an orphan");
    for (x, y, z) in &orphans {
        r.random_tick(*x, *y, *z);
        r.tick(3);
    }
    assert_eq!(r.fires_in_world(), 0, "the orphans went out on their random ticks");
    println!("ok  unloaded: {alight} alight when the chunk went, the blaze ended with nothing edited, {} orphans put out on reload; `{said}`", orphans.len());
}

// A fire block that belongs to no blaze — placed by hand, or left by a lost
// storage — goes out on its random tick.
fn fire_orphan_check() {
    let mut r = Rig::new(true, Arc::new(Storage::default()));
    let top = r.stand(ALICE, FIRE_X, FIRE_Z, DIRT);
    r.join(ALICE, FIRE_X, f64::from(top + 1), FIRE_Z);
    r.tick(1);
    let (fx, fz) = (FIRE_X as i32 + 3000, FIRE_Z as i32);
    let far_top = dome_y(f64::from(fx), f64::from(fz)).floor() as i32;
    r.world.put(fx, far_top + 1, fz, r.material(FIRE), FULL);
    let before = r.now;
    r.random_tick(fx, far_top + 1, fz);
    r.tick(3);
    let there: Vec<_> = r.edits_since(before).into_iter().filter(|e| e.1.x == fx && e.1.z == fz).collect();
    assert_eq!(there.len(), 1, "one edit from the random tick: {there:?}");
    assert_eq!((there[0].2.as_str(), there[0].1.y), (AIR, far_top + 1), "the orphan went to air");
    assert_eq!(r.fires_in_world(), 0);
    println!("ok  an orphaned fire block goes out on its random tick");
}

// A world that chose no wildfires: the option is read at load, the command
// says so, the blocks are still registered (a fire from another world's
// save must still be a block here), and a storm over bare grass scorches
// nothing — the mark is under the same switch as the fire.
fn fire_off_check() {
    let prelude = "wx_overrides = { STRIKE_SCORCH_ODDS = 1 }";
    let mut r = Rig::options(Some(SPINDLE_STANDIN), Arc::new(Storage::default()), prelude,
        &[("tiamat_weather:fires", WorldOptionValue::Toggle(false))]);
    let top = r.stand(ALICE, FIRE_X, FIRE_Z, GRASS);
    r.join(ALICE, FIRE_X, f64::from(top + 1), FIRE_Z);
    r.tick(1);
    let (cx, cz) = (FIRE_X as i32 + 10, FIRE_Z as i32);
    plant_wood(&r, cx, top, cz);
    let lit = r.reply(ALICE, &format!("/weather fire at {cx} {} {cz}", top + 6));
    assert_eq!(lit, format!("nothing lit at {cx},{},{cz}: off", top + 6));
    assert_eq!(r.reply(ALICE, "/weather fires"), "fires are switched off in this world");
    for block in [FIRE, CHARRED, SCORCHED] {
        assert!(r.materials.contains_key(block), "{block} is registered whatever the world chose");
    }
    r.tick(200);
    assert!(r.ignitions_since(0).is_empty(), "nothing lit");

    // Five minutes of storm over grass, every grounded bolt on turf a scorch
    // if the switch allowed one: the bolts land and leave the turf alone.
    let set = r.reply(ALICE, "/weather set storm 10");
    assert!(set.starts_with("storm over square"), "{set}");
    r.tick(20 * 60 * 5);
    let flashes = r.atmosphere.flashes.lock().unwrap().len();
    assert!(flashes > 0, "the storm struck");
    assert!(r.edits_named(0, SCORCHED).is_empty(), "no scorch mark with wildfires off");
    assert!(r.ignitions_since(0).is_empty(), "and still nothing lit");
    println!("ok  wildfires off: `{lit}`; the fire blocks are still registered; {flashes} bolts on grass scorched nothing");
}

// Lightning lands: a bolt strikes the highest of a few ground points rather
// than the air over the player, sparks fly at the point of impact, a strike
// on leaves can light them, a strike on bare turf can scorch it, and an
// operator can call one down.
fn lightning_check() {
    let prelude = "wx_overrides = { FIRE_LIGHTNING_ODDS = 1, STRIKE_SCORCH_ODDS = 1 }";
    let spindle = spindle_exporting(-0.35, 0.6);

    // A canopy wider than a bolt's reach either way, so every strike lands on
    // leaves at top + 5, and the flash sits one over that — or, where a leaf
    // has already burnt to air, on the floor under it, one over top.
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), prelude, &[]);
    let top = r.stand(ALICE, FIRE_X, FIRE_Z, DIRT);
    let (ax, az) = (FIRE_X as i32, FIRE_Z as i32);
    let leaves = r.material(LEAVES);
    for dx in -100..=100 {
        for dz in -100..=100 {
            r.world.put(ax + dx, top + 5, az + dz, leaves, FULL);
        }
    }
    r.join(ALICE, FIRE_X, f64::from(top + 1), FIRE_Z);
    r.tick(41);
    let set = r.reply(ALICE, "/weather set storm 10");
    assert!(set.starts_with("storm over square"), "{set}");
    let peak = r.burn(20 * 60 * 5);

    let flashes = r.atmosphere.flashes.lock().unwrap().clone();
    assert!(!flashes.is_empty(), "a storm strikes");
    let on_canopy = f64::from(top + 6);
    let fallback = f64::from(top + 1 + STRIKE_ABOVE);
    let bare = f64::from(top + 1);
    let (mut landed, mut burnt_through, mut fell_back) = (0, 0, 0);
    for (_, flash) in &flashes {
        if flash.pos[1] == on_canopy {
            landed += 1;
        } else if flash.pos[1] == bare {
            // A bolt on ground a burnt leaf left bare: as legitimate a landing.
            burnt_through += 1;
        } else if flash.pos[1] == fallback {
            fell_back += 1;
        } else {
            panic!("a flash at y {} is neither on the canopy ({on_canopy}), on bared ground ({bare}) nor the fallback ({fallback})", flash.pos[1]);
        }
        assert!(across(&BlockPos::new(flash.pos[0] as i32, 0, flash.pos[2] as i32), ax, az) <= 100, "{flash:?} is off the canopy");
    }
    assert!(landed > 0, "every bolt fell back to the air: {flashes:?}");
    assert_eq!(fell_back, 0, "there is ground under every candidate, so every flash sits one over a surface");
    let sparks = r.particles.bursts.lock().unwrap().iter().filter(|(_, b)| b.burst.gravity >= 10.0 && b.burst.lifetime < 1.0).count();
    assert!(sparks > 0, "sparks at the point of impact");
    let said = r.reply(ALICE, "/weather fires");
    let by_lightning = number_after(&said, "by lightning ");
    assert!(by_lightning > 0.0, "a bolt on leaves lit them: {said}");
    println!("ok  lightning: {landed} bolts on the canopy, {burnt_through} on ground a fire had bared, none fell back, {sparks} spark bursts, {by_lightning} blazes by lightning, {peak} alight at most; `{said}`");

    // Over bare turf a bolt leaves a scorch mark, and an operator may call one.
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), prelude, &[]);
    let top = r.stand(ALICE, FIRE_X, FIRE_Z, GRASS);
    r.join(ALICE, FIRE_X, f64::from(top + 1), FIRE_Z);
    r.tick(41);
    r.say(ALICE, "/weather set storm 10");
    r.tick(20 * 60 * 5);
    let scorched = r.edits_named(0, SCORCHED);
    assert!(!scorched.is_empty(), "a bolt on bare grass scorched it");
    assert!(scorched.iter().all(|e| e.1.y == top), "the mark is in the turf itself: {scorched:?}");
    assert!(r.ignitions_since(0).is_empty(), "turf is never fuel");
    let flashes = r.atmosphere.flashes.lock().unwrap().len();
    let bolt = r.reply(ALICE, "/weather strike");
    assert!(bolt.starts_with("a bolt at"), "{bolt}");
    assert_eq!(r.atmosphere.flashes.lock().unwrap().len(), flashes + 1, "the called bolt flashed");
    assert_eq!(r.reply(BOB, "/weather strike"), "only an operator can change the weather");
    println!("ok  lightning on turf: {} scorch marks in five minutes of storm; `{bolt}`", scorched.len());
}

// Fire from lava, three ways: a hot block beside fuel, a still hot fluid
// told from water by its glow, and a flow pressing on a leaf.
fn fire_lava_check() {
    // Every hot surface the sampler finds lights the fuel beside it, and the
    // sampler looks often: it draws a few random columns within SAMPLE_RADIUS
    // of the player, so at its ordinary pace one bar of magma is found about
    // once in three runs.
    let prelude = "wx_overrides = { FIRE_LAVA_ODDS = 1, FIRE_FLOW_ODDS = 1, FIRE_SAMPLE_TICKS = 2, FIRE_SAMPLE_COLUMNS = 8 }";
    let spindle = spindle_exporting(-0.35, 0.6);
    let (ax, az) = (FIRE_X as i32, FIRE_Z as i32);

    // 1. Still lava as a block: a bar of magma through a meadow, two blocks
    // from Alice.
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), prelude, &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, GRASS);
    plant_meadow(&r, ax, top + 1, az, 14);
    let magma = r.material("tiamat_default_world:magma");
    for dx in -12..=12 {
        r.world.put(ax + dx, top + 1, az + 2, magma, FULL);
    }
    let from = r.now;
    r.burn(20 * 30);
    let said = r.reply(ALICE, "/weather fires");
    let by_magma = number_after(&said, "by lava ");
    assert!(by_magma > 0.0, "magma lit the grass beside it: {said}");
    let fires = r.ignitions_since(from);
    assert!(!fires.is_empty(), "{said}");
    for (_, pos, _, _) in &fires {
        assert_eq!(pos.y, top + 1, "fire in the tufts");
        assert!(!(pos.z == az + 2 && (pos.x - ax).abs() <= 12), "fire on the magma itself at {pos:?}");
    }
    println!("ok  magma: {by_magma} blazes by lava, {} tufts lit in thirty seconds", fires.len());

    // 2. Still lava as a fluid: the rig's water, glowing. The same fluid
    // without the glow is water and lights nothing.
    for glow in [true, false] {
        let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), prelude, &[]);
        let top = clear_day(&mut r, FIRE_X, FIRE_Z, GRASS);
        plant_meadow(&r, ax, top + 1, az, 14);
        for dx in -12..=12 {
            let at = (ax + dx, top + 1, az + 2);
            r.world.put(at.0, at.1, at.2, MaterialId(0), 0);
            r.world.fluids.lock().unwrap().insert(at, (WATER_ID, 27));
            if glow {
                r.world.hot.lock().unwrap().push(at);
            }
        }
        let from = r.now;
        r.burn(20 * 30);
        let said = r.reply(ALICE, "/weather fires");
        let by_lava = number_after(&said, "by lava ");
        if glow {
            assert!(by_lava > 0.0, "a glowing fluid is lava and lit the grass: {said}");
            println!("ok  still lava: {by_lava} blazes by lava from a fluid told apart by its glow, {} tufts lit", r.ignitions_since(from).len());
        } else {
            assert_eq!(by_lava, 0.0, "a fluid that does not glow is water: {said}");
            assert!(r.ignitions_since(from).is_empty(), "nothing lit by water");
            println!("ok  the same fluid without a glow lit nothing");
        }
    }

    // 3. Flowing lava pressing on a leaf, reported by the engine's fluid flow
    // hook; water pressing on another wood's leaf is nothing.
    let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), prelude, &[]);
    let top = clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let (cx, cz) = (ax + 10, az);
    plant_wood(&r, cx, top, cz);
    plant_wood(&r, cx + 60, top, cz);
    let leaves = r.material(LEAVES);
    let press = |fluid: &str, into: BlockPos| FluidFlowEvent {
        from: BlockPos::new(into.x - 1, into.y, into.z),
        into,
        fluid: fluid.into(),
        volume: 27,
        blocked_by: leaves,
        occupancy: FULL,
        meets: None,
    };
    let leaf = BlockPos::new(cx - 3, top + 5, cz);
    let other = BlockPos::new(cx + 60 - 3, top + 5, cz);
    let from = r.now;
    r.vm.fluid_flow(&press("tiamat_default_world:lava", leaf));
    r.vm.fluid_flow(&press("tiamat_default_world:water", other));
    r.ours_ok("fluid flow");
    r.tick(3);
    let lit = r.ignitions_since(from);
    assert!(lit.iter().any(|e| e.1 == leaf), "the leaf lava pressed on caught: {lit:?}");
    assert!(!lit.iter().any(|e| e.1 == other), "the leaf water pressed on did not: {lit:?}");
    let said = r.reply(ALICE, "/weather fires");
    assert_eq!(number_after(&said, "by lava "), 1.0, "{said}");
    println!("ok  a lava flow pressing on a leaf lit it; `{said}`");
}

// Beside Life (a1d016c): weather calls both unlocks at load for its fire
// block, with the contract's arguments, and a bolt beside Alice sets her
// alight through the third, by her UUID.
// Now and then the bolt is aimed at a player (2026-09-25). With the odds
// forced to one, a storm's bolt lands on Alice in the open and burns her for
// STRIKE_HIT_TICKS through Life; under a roof she is passed over.
fn player_strike_check() {
    let prelude = "wx_overrides = { PLAYER_STRIKE_ODDS = 1 }";
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::beside_life(Some(&spindle), Arc::new(Storage::default()), prelude);
    clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    r.say(ALICE, "/weather set storm 30");
    r.tick(40 * 25);
    let flashes = r.atmosphere.flashes.lock().unwrap().clone();
    assert!(!flashes.is_empty(), "the storm struck");
    let (ax, az) = (FIRE_X.floor(), FIRE_Z.floor());
    assert!(flashes.iter().all(|(_, f)| (f64::from(f.pos[0]) - ax).abs() < 1.0 && (f64::from(f.pos[2]) - az).abs() < 1.0),
        "every bolt on Alice: {:?}", flashes.iter().map(|f| (f.1.pos[0], f.1.pos[2])).collect::<Vec<_>>());
    let hex: String = ALICE.iter().map(|b| format!("{b:02x}")).collect();
    let told = r.reply(ALICE, "/life");
    assert!(told.contains(&format!("{hex}:200")), "Alice burns for ten seconds: {told}");
    // Under a roof the aimed bolt finds nobody and goes where bolts go.
    r.world.roofs.lock().unwrap().push((ax as i32, az as i32));
    let before = r.atmosphere.flashes.lock().unwrap().len();
    r.tick(40 * 25);
    let later = r.atmosphere.flashes.lock().unwrap()[before..].to_vec();
    assert!(!later.is_empty() && later.iter().all(|(_, f)| (f64::from(f.pos[0]) - ax).abs() >= 1.0 || (f64::from(f.pos[2]) - az).abs() >= 1.0),
        "no bolt on Alice under her roof");
    println!("ok  a bolt aimed at a player: {} on Alice in the open, burning her 200 ticks; none under a roof", flashes.len());
}

fn life_check() {
    // The bolt goes six blocks ahead of her; widen the reach so it counts.
    let prelude = "wx_overrides = { STRIKE_ALIGHT_RADIUS = 8 }";
    let spindle = spindle_exporting(-0.35, 0.6);
    let mut r = Rig::beside_life(Some(&spindle), Arc::new(Storage::default()), prelude);
    clear_day(&mut r, FIRE_X, FIRE_Z, DIRT);
    let told = r.reply(ALICE, "/life");
    assert_eq!(told, "tiamat_weather:fire:1,20,40;tiamat_weather:fire:1.0;", "the unlocks, once each, at load: {told}");
    let said = r.reply(ALICE, "/weather strike");
    assert!(said.starts_with("a bolt at"), "{said}");
    let hex: String = ALICE.iter().map(|b| format!("{b:02x}")).collect();
    let told = r.reply(ALICE, "/life");
    assert!(told.ends_with(&format!(";{hex}:100")), "Alice set alight by the bolt beside her, by UUID: {told}");
    assert_eq!(told.matches(&hex).count(), 1, "once: {told}");
    println!("ok  Life's unlocks: `{told}`");
}

// In the alpine highlands the cloud floor stands CLOUD_LIFT_ALPINE higher over
// the dome than elsewhere, by the Spindle's own biome; in the woodlands it
// does not move.
fn cloud_lift_check() {
    for (biome, lift) in [("alpine_highlands", 320.0), ("taiga", 160.0), ("temperate_woodlands", 0.0)] {
        let spindle = format!(
            "{SPINDLE_STANDIN}\ngame.export{{ version = 1, biome_under = function(x, y, z) return '{biome}' end }}"
        );
        let mut r = Rig::custom(Some(&spindle), Arc::new(Storage::default()), "", &[]);
        let (x, z) = (0.5 * 59000.0, 100.0);
        let top = r.stand(ALICE, x, z, DIRT);
        r.join(ALICE, x, f64::from(top + 1), z);
        r.tick(41);
        let base = r.clouds_of(ALICE).expect("clouds").base.expect("a floor");
        let want = ((dome_y(x, z) + 400.0 + lift) / 64.0).floor() * 64.0;
        assert_eq!(f64::from(base), want, "the floor over {biome}");
        println!("ok  the cloud floor over {biome}: y {base}, {lift} over the plain floor");
    }
}

// Without the Spindle: the plain adapter, no damp blocks, weather still works.
fn plain_check() {
    let mut r = Rig::new(false, Arc::new(Storage::default()));
    assert!(!r.materials.contains_key("tiamat_weather:damp_dirt"));
    *r.world.floor.lock().unwrap() = (63, r.material("core:white"));
    r.join(ALICE, 10.0, 64.0, 10.0);
    r.tick(41);
    let reply = r.reply(ALICE, "/weather");
    assert!(reply.contains("climate plain"), "{reply}");
    r.say(ALICE, "/weather set rain 5");
    r.tick(40 * 20);
    assert!(r.hud(ALICE).contains("Rain"), "hud {:?}", r.hud(ALICE));
    assert!(r.reply(ALICE, "/weather drift").contains("mirrors nothing"));
    println!("ok  plain world: `{reply}`");
}

fn hud_check() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../mods").join(MOD);
    let source = std::fs::read_to_string(dir.join("hud.lua")).unwrap();
    let cases: Vec<(&str, Values, usize)> = vec![
        ("nothing", Values::new(), 0),
        ("rain under the Spindle", Values::from([
            ("weather".into(), Value::Text("Light rain".into())), ("row".into(), Value::Number(78.0)),
        ]), 2),
        ("no row", Values::from([("weather".into(), Value::Text("Snow".into()))]), 2),
    ];
    for (name, values, expected) in cases {
        let mut hud = HudVm::new(HudLimits::default()).unwrap();
        hud.load(MOD, &source).expect("hud.lua loads");
        let mut state = State::default();
        state.values.insert(MOD.into(), values);
        let faults = hud.draw(&state);
        assert!(faults.is_empty(), "hud faults on `{name}`: {faults:?}");
        let commands = hud.with_frame(|f| f.commands().len()).unwrap();
        assert_eq!(commands, expected, "hud `{name}`");
        println!("ok  hud `{name}`: {commands} draw commands");
    }
}
