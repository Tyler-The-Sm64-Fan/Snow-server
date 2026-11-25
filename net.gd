extends Node
## Autoload "Net": input actions, settings and WebSocket multiplayer.
## The SAME file is used by the game and by the server (the RPC list must match).

signal status_changed(text: String)
signal online_changed(on: bool)
signal player_joined(id: int, pname: String)
signal player_left(id: int)
signal state_received(id: int, pos: Vector3, yaw: float, pitch: float, flags: int)
signal ball_thrown(id: int, origin: Vector3, vel: Vector3)
signal object_placed(kind: String, pos: Vector3, yaw: float)

## Optional: put your server address here, e.g. "wss://your-app.onrender.com"
const DEFAULT_URL := ""
const DEFAULT_PORT := 8080
const CONNECT_TIMEOUT := 45.0   # free hosts can take ~30s to wake up
const PONG_TIMEOUT := 12.0
const MAX_OBJECTS := 200
const SETTINGS_PATH := "user://snow_settings.cfg"

var online := false
var status_text := "Single player"
var player_name := ""
var server_url := DEFAULT_URL
var names := {}            # other players: peer id -> name (server: everybody)
var dedicated := false

var _objects: Array = []   # server only: placed angels / snowmen
var _connecting := false
var _conn_t := 0.0
var _last_pong := 0.0
var _ping_t := 0.0


func _ready() -> void:
	_setup_input()
	_load_settings()
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_failed)
	multiplayer.server_disconnected.connect(_on_server_lost)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if wants_server():
		start_server()


# ---------------------------------------------------------------- settings

func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) == OK:
		player_name = str(cf.get_value("player", "name", ""))
		server_url = str(cf.get_value("player", "url", DEFAULT_URL))
	if player_name.is_empty():
		player_name = "Player%d" % randi_range(100, 999)


func save_settings(pname: String, url: String) -> void:
	player_name = pname.strip_edges().substr(0, 14)
	if player_name.is_empty():
		player_name = "Player%d" % randi_range(100, 999)
	server_url = url.strip_edges()
	var cf := ConfigFile.new()
	cf.set_value("player", "name", player_name)
	cf.set_value("player", "url", server_url)
	cf.save(SETTINGS_PATH)


func _set_status(t: String) -> void:
	status_text = t
	status_changed.emit(t)


# ---------------------------------------------------------------- client

func try_connect() -> void:
	go_offline("")
	var url := server_url.strip_edges()
	if url.is_empty():
		go_offline("Single player (no server address)")
		return
	if not "://" in url:
		url = "wss://" + url
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		go_offline("Single player (bad server address)")
		return
	multiplayer.multiplayer_peer = peer
	_connecting = true
	_conn_t = 0.0
	_set_status("Connecting...")


func go_offline(text: String = "Single player") -> void:
	var was := online
	online = false
	_connecting = false
	names.clear()
	var mp := multiplayer.multiplayer_peer
	if mp != null and not (mp is OfflineMultiplayerPeer):
		mp.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_set_status(text)
	if was:
		online_changed.emit(false)


func _on_connected() -> void:
	if dedicated:
		return
	_connecting = false
	online = true
	_last_pong = Time.get_ticks_msec() / 1000.0
	_ping_t = 0.0
	_set_status("Online")
	online_changed.emit(true)
	register.rpc_id(1, player_name)


func _on_failed() -> void:
	if _connecting:
		go_offline("Single player (can't reach server)")


func _on_server_lost() -> void:
	if not dedicated:
		go_offline("Connection lost - single player")


func _process(delta: float) -> void:
	if dedicated:
		return
	if _connecting:
		_conn_t += delta
		if _conn_t > CONNECT_TIMEOUT:
			go_offline("Single player (can't reach server)")
	elif online:
		_ping_t -= delta
		if _ping_t <= 0.0:
			_ping_t = 2.0
			ping.rpc_id(1)
		if Time.get_ticks_msec() / 1000.0 - _last_pong > PONG_TIMEOUT:
			go_offline("Connection lost - single player")


# ---------------------------------------------------------------- server

func wants_server() -> bool:
	return DisplayServer.get_name() == "headless" or "--server" in OS.get_cmdline_user_args()


func start_server() -> void:
	var port := DEFAULT_PORT
	var env := OS.get_environment("PORT")
	if env != "":
		port = int(env)
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("Snow server could not start on port %d (error %d)" % [port, err])
		return
	multiplayer.multiplayer_peer = peer
	dedicated = true
	print("Snow server running on port %d" % port)


func _on_peer_disconnected(id: int) -> void:
	if not dedicated:
		return
	if names.has(id):
		names.erase(id)
		for other in names.keys():
			left.rpc_id(other, id)
		print("Player %d left (%d online)" % [id, names.size()])


# ---------------------------------------------------------------- RPCs (client -> server)

@rpc("any_peer", "call_remote", "reliable")
func register(pname: String) -> void:
	if not dedicated:
		return
	var id := multiplayer.get_remote_sender_id()
	pname = pname.strip_edges().substr(0, 14)
	if pname.is_empty():
		pname = "Player%d" % (id % 1000)
	for other in names.keys():
		joined.rpc_id(id, other, names[other])
		joined.rpc_id(other, id, pname)
	names[id] = pname
	for o in _objects:
		got_object.rpc_id(id, o[0], o[1], o[2])
	print("%s joined (%d online)" % [pname, names.size()])


@rpc("any_peer", "call_remote", "reliable")
func send_state(pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	if not dedicated:
		return
	var id := multiplayer.get_remote_sender_id()
	if not names.has(id):
		return
	for other in names.keys():
		if other != id:
			got_state.rpc_id(other, id, pos, yaw, pitch, flags)


@rpc("any_peer", "call_remote", "reliable")
func send_throw(origin: Vector3, vel: Vector3) -> void:
	if not dedicated:
		return
	var id := multiplayer.get_remote_sender_id()
	if not names.has(id):
		return
	for other in names.keys():
		if other != id:
			got_throw.rpc_id(other, id, origin, vel)


@rpc("any_peer", "call_remote", "reliable")
func send_object(kind: String, pos: Vector3, yaw: float) -> void:
	if not dedicated:
		return
	var id := multiplayer.get_remote_sender_id()
	if not names.has(id) or not (kind == "angel" or kind == "snowman"):
		return
	_objects.append([kind, pos, yaw])
	if _objects.size() > MAX_OBJECTS:
		_objects.pop_front()
	for other in names.keys():
		if other != id:
			got_object.rpc_id(other, kind, pos, yaw)


@rpc("any_peer", "call_remote", "reliable")
func ping() -> void:
	if dedicated:
		pong.rpc_id(multiplayer.get_remote_sender_id())


# ---------------------------------------------------------------- RPCs (server -> client)

@rpc("authority", "call_remote", "reliable")
func joined(id: int, pname: String) -> void:
	names[id] = pname
	player_joined.emit(id, pname)


@rpc("authority", "call_remote", "reliable")
func left(id: int) -> void:
	names.erase(id)
	player_left.emit(id)


@rpc("authority", "call_remote", "reliable")
func got_state(id: int, pos: Vector3, yaw: float, pitch: float, flags: int) -> void:
	state_received.emit(id, pos, yaw, pitch, flags)


@rpc("authority", "call_remote", "reliable")
func got_throw(id: int, origin: Vector3, vel: Vector3) -> void:
	ball_thrown.emit(id, origin, vel)


@rpc("authority", "call_remote", "reliable")
func got_object(kind: String, pos: Vector3, yaw: float) -> void:
	object_placed.emit(kind, pos, yaw)


@rpc("authority", "call_remote", "reliable")
func pong() -> void:
	_last_pong = Time.get_ticks_msec() / 1000.0


# ---------------------------------------------------------------- input actions

func _setup_input() -> void:
	_key("move_forward", KEY_W)
	_key("move_forward", KEY_UP)
	_key("move_back", KEY_S)
	_key("move_back", KEY_DOWN)
	_key("move_left", KEY_A)
	_key("move_left", KEY_LEFT)
	_key("move_right", KEY_D)
	_key("move_right", KEY_RIGHT)
	_key("jump", KEY_SPACE)
	_key("run", KEY_SHIFT)
	_key("gather", KEY_E)
	_key("throw", KEY_F)
	_key("angel", KEY_Q)
	_key("snowman", KEY_R)
	_key("pause", KEY_ESCAPE)
	if not InputMap.has_action("throw"):
		InputMap.add_action("throw")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("throw", mb)


func _key(action: String, keycode: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)
