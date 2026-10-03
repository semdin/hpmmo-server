# HPMMO Network Protocol Contract

Generated from `scripts/autoload/network_manager.gd` (client revision pinned in workspace.lock.json).
Server owns this contract; regenerate with `client/tools/workspace/extract_protocol.py`.

| RPC | Flags | Parameters |
| --- | --- | --- |
| `rpc_broadcast_state` | `any_peer, unreliable` | pos: Vector3, rot_y: float, mounted: bool, hp: int, level: int |
| `rpc_relay_state` | `authority, unreliable` | peer_id: int, pos: Vector3, rot_y: float, mounted: bool, hp: int, level: int |
| `rpc_broadcast_spell` | `any_peer, reliable` | spell_id: String, from_pos: Vector3, dir: Vector3 |
| `rpc_relay_spell` | `authority, reliable` | caster_id: int, spell_id: String, from_pos: Vector3, dir: Vector3 |
| `_register_my_info` | `any_peer, reliable` | info: Dictionary |
| `_sync_player_info` | `authority, reliable` | id: int, info: Dictionary |
| `rpc_send_chat` | `any_peer, call_local, reliable` | sender_name: String, sender_house: String, message: String |
| `rpc_request_register` | `any_peer, reliable` | username: String, password: String |
| `rpc_register_result` | `authority, reliable` | success: bool, message: String |
| `rpc_request_login` | `any_peer, reliable` | username: String, password: String |
| `rpc_login_result` | `authority, reliable` | success: bool, message: String, characters: Array |
| `rpc_request_create_character` | `any_peer, reliable` | char_name: String, house: String |
| `rpc_create_character_result` | `authority, reliable` | success: bool, message: String, char_data: Dictionary |
| `rpc_request_select_character` | `any_peer, reliable` | char_id: int |
| `rpc_character_select_result` | `authority, reliable` | success: bool, message: String, char_data: Dictionary |

Surface entries: 15. Hash of this document is pinned in the workspace lock;
payload schemas for gameplay data live in `contracts/schemas/`.

Surface hash: `ce1583bff0d92ef394a7139a5b75276122a6e3a0c331a9ae69c2be6aff25730c`
