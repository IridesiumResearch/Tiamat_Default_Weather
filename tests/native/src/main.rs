// SPDX-License-Identifier: MIT
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
    fn within(&self, _: [f64; 3], _: f64, _: Option<&str>) -> Vec<EntityId> {
        Vec::new()
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
}

// Fluid ids in the fake: rainwater is 1, anything else registered is 2.
const RAIN_ID: u8 = 1;
const WATER_ID: u8 = 2;

impl World {
    fn put(&self, x: i32, y: i32, z: i32, material: MaterialId, occupancy: u32) {
        let mut blocks = self.blocks.lock().unwrap();
        if occupancy == 0 {
            blocks.remove(&(x, y, z));
        } else {
            blocks.insert((x, y, z), (material, occupancy));
        }
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
        if self.roofs.lock().unwrap().contains(&(pos.x, pos.z)) {
            return Light::DARK;
        }
        if self.canopies.lock().unwrap().contains(&(pos.x, pos.z)) {
            return Light::new(6, 0, 0, 0);
        }
        let (top, _) = *self.floor.lock().unwrap();
        let covered = self
            .blocks
            .lock()
            .unwrap()
            .iter()
            .any(|((x, y, z), (_, occ))| *x == pos.x && *z == pos.z && *y > pos.y && *occ != 0);
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

// The stand-in Spindle: every block the weather mod looks up by name.
const SPINDLE_STANDIN: &str = "for _, id in ipairs({ 'dirt', 'packed_dirt', 'sand', 'snow', 'ice', 'clear_ice', \
    'permafrost', 'gravel', 'stone', 'mud', 'dried_mud', 'lava_rock', 'pumice', 'sulfur', 'obsidian', 'dark_sand', 'salt', 'oak_log', 'birch_log', 'grass', \
    'oak_leaves' }) \
    do game.register_block{ id = id } end";

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
        if let Some(source) = spindle {
            vm.load_mod(spindle_id, source, &dir).unwrap();
            // What the resolver tells the VM from mod.toml's optional_depends:
            // it is what lets weather read the Spindle's exports.
            vm.note_dependencies(MOD, &[spindle_id.to_owned()]);
        } else {
            vm.load_mod("core", "game.register_block{ id = 'white' }", &dir).unwrap();
        }
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
}

// The number after `label` in a reply, e.g. "warmth 812".
fn number_after(text: &str, label: &str) -> f64 {
    let at = text.find(label).unwrap_or_else(|| panic!("no `{label}` in `{text}`")) + label.len();
    let rest: String = text[at..].chars().take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-').collect();
    rest.parse().unwrap_or_else(|_| panic!("`{label}` is not followed by a number in `{text}`"))
}

const ONE_LAYER: u32 = 0x1C0E07;
const TWO_LAYERS: u32 = 0xFC7E3F;

fn main() {
    climate_check();
    let storage = Arc::new(Storage::default());
    let saved_front = weather_check(storage.clone());
    restart_check(storage, &saved_front);
    snow_check();
    thaw_check();
    queue_check();
    puddle_check();
    exports_check();
    mega_check();
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
    r.tick(40 * 25);
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
    assert_eq!(rain.burst.size, 0.12, "the storm's drops");
    let live = f64::from(rain.rate) * f64::from(rain.burst.lifetime);
    assert!(live <= 2801.0, "{live} live storm particles for one player");
    // Three times as hard to see through as the first storm table
    // (1,365 live x 0.07^2 x 0.6 = 4.01), by live x size^2 x alpha.
    let size = f64::from(rain.burst.size);
    let alpha = f64::from(rain.burst.colour[3]) / 255.0;
    let opacity = live * size * size * alpha;
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
    assert_eq!((deck.cell, deck.detail), (16.0, 2), "cubes of 16 breaking into 8s on the surface");
    assert!(deck.thickness >= 128.0 && deck.towers > 0.0, "heaps with towers: {deck:?}");
    assert!((deck.drift[0] - 0.5).abs() < 1e-6 && deck.drift[1] == 0.0, "drifts with the fronts: {:?}", deck.drift);
    assert!(deck.shade[2] > deck.shade[0], "a blue-violet shade: {:?}", deck.shade);
    assert!(r.particles.bursts.lock().unwrap().is_empty(), "no particles at all: the puffs are gone");
    let storm_clouds = r.clouds_of(ALICE).expect("a storm sets the clouds");
    assert!(storm_clouds.cover >= 0.99 && storm_clouds.darkness >= 0.85, "overcast and dark: {storm_clouds:?}");
    let floor = storm_clouds.base.expect("the floor is sent per player");
    let want = ((dome_y(x, 100.0) + 400.0) / 64.0).floor() * 64.0;
    assert_eq!(f64::from(floor), want, "400 over the dome under the player, in steps of 64");
    assert!(storm_clouds.ease_ticks > 0, "a change of weather is eased");
    let said = r.reply(ALICE, "/weather clouds");
    assert!(said.starts_with("cover 1.00, darkness 0.90"), "{said}");
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
    assert!(map.cover[middle] >= 250 && map.darkness[middle] >= 225, "overhead is the storm: {} {}", map.cover[middle], map.darkness[middle]);
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
    assert_eq!(fair.base, Some(floor));
    let calls = *r.atmosphere.cloud_calls.lock().unwrap();
    r.tick(400);
    // Ten evaluations: overhead nothing changes, and the cover map around it
    // refreshes a square nobody is in at most every CLOUD_MAP_TICKS, as the
    // fronts move. So one send at most, not one an evaluation.
    let sent = *r.atmosphere.cloud_calls.lock().unwrap() - calls;
    assert!(sent <= 1, "a steady sky sends only the map's own refresh: {sent} in ten evaluations");
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
    let writes = r.world.fluid_writes.lock().unwrap().clone();
    assert!(!writes.is_empty(), "two minutes of rain left puddles");
    for (_, pos, id, volume) in &writes {
        assert_eq!(*id, RAIN_ID, "only rainwater is written");
        assert!(*volume == 3 || *volume == 6, "a rain puddle is 3 cells, a storm's 6: {volume}");
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
    assert_eq!(told, "tiamat_weather:damp_dirt=tiamat_default_world:dirt,tiamat_weather:damp_packed_dirt=tiamat_default_world:packed_dirt,tiamat_weather:damp_sand=tiamat_default_world:sand;tiamat_weather:rainwater");
    println!("ok  Spindle exports read: humidity, climate, biomes; damp ground and puddles unlocked by its answers");

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
    assert!(clouds.cover >= 0.99 && clouds.darkness >= 0.99, "{clouds:?}");
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
