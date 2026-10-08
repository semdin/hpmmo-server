# HPMMO Network Protocol Contract

Generated from `world/addons/hpmmo_sim/net.gd` in the server repository (the client runs a
hash-pinned copy of the same package). Regenerate with
`client/tools/workspace/extract_protocol.py`.

Channels: 0 snapshots (unreliable), 1 events (reliable, authority only),
2 intents (reliable, client -> server), 3 input frames (unreliable, ordered).
A client's messages are intents: the server validates every one of them and answers with
its own state. `server_relay` is off, so clients cannot address each other.

| RPC | Flags | Parameters |
| --- | --- | --- |
| `sim_join` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | token: String, protocol_version: int, client_version: String |
| `sim_bind_character` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | character_id: int |
| `sim_input` | `any_peer, call_remote, unreliable_ordered, HPProtocol.CH_INPUT` | seq: int, move: Vector2, yaw: float, jump: bool, descend: bool |
| `sim_cast_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | spell_id: String, aim: Vector3, cast_seq: int |
| `sim_mount_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | mounted: bool |
| `sim_respawn_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | - |
| `sim_transfer_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | portal_id: String, to_map: String |
| `sim_transfer_ready` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | token: int |
| `sim_transfer_abort` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | token: int |
| `sim_pickup_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | loot_uid: int |
| `sim_chat_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | text: String |
| `sim_join_result` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | ok: bool, reason: String, uid: int, character: Dictionary, tick: int, world_seed: int |
| `sim_bind_result` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | ok: bool, reason: String, character: Dictionary |
| `sim_cast_result` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | cast_seq: int, cast_id: int, ok: bool, reason: String |
| `sim_cast_started` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int, cast_id: int, spell_id: String, aim: Vector3, release_tick: int |
| `sim_cast_released` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | cast_id: int, caster_uid: int, spell_id: String, origin: Vector3, dir: Vector3 |
| `sim_cast_landed` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | cast_id: int, caster_uid: int, spell_id: String, hits: Array |
| `sim_damage_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int, amount: int, hp: int, spell_id: String, attacker_uid: int |
| `sim_death_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int, killer_uid: int |
| `sim_respawn_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int |
| `sim_stats_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int, stats: Dictionary |
| `sim_loot_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int, item_id: String, amount: int, pos: Vector3 |
| `sim_loot_despawn` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int |
| `sim_reward_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | character_id: int, exp: int, galleons: int, items: Array, op_id: String |
| `sim_chat_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | text: String |
| `sim_notice` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | kind: String, detail: String |
| `sim_maintenance_event` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | state: String, reason: String, seconds_remaining: int |
| `sim_transfer_granted` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | token: int, map_id: String, spawn_id: String |
| `sim_transfer_committed` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | token: int, map_id: String, pos: Vector3, spawn_id: String |
| `sim_transfer_refused` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | reason: String |
| `sim_transfer_expired` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | token: int, map_id: String, pos: Vector3 |
| `sim_map_state` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | map_id: String, pos: Vector3, spawn_id: String |
| `sim_snapshot` | `authority, call_remote, unreliable, HPProtocol.CH_SNAPSHOT` | tick: int, chunk: int, chunks: int, data: PackedByteArray |
| `sim_despawn` | `authority, call_remote, reliable, HPProtocol.CH_SNAPSHOT` | uid: int |
| `sim_telegraph` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int, data: Dictionary |
| `sim_telegraph_end` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | uid: int |
| `sim_equipment_request` | `any_peer, call_remote, reliable, HPProtocol.CH_INTENT` | request_id: int, revision: int, operation: String, slot: String, item_id: String, tier: int |
| `sim_equipment_result` | `authority, call_remote, reliable, HPProtocol.CH_EVENT` | answer: Dictionary |

Surface entries: 38. Hash of this document is pinned in the workspace lock;
Canonical gameplay catalogs live in `world/addons/hpmmo_sim/data/`; client content schemas live in `contracts/schemas/`.

Surface hash: `6785ed74ff1eca99172c02b88ed8a269101f233efcf1b4477a9599f12b44cbdd`
