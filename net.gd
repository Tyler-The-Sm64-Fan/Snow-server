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
signal chat_received(pname: String, text: String)
signal notice_received(text: String)
signal objects_trimmed(count: int)

## Optional: put your server address here, e.g. "wss://your-app.onrender.com"
const DEFAULT_URL := "wss://snow-server-1.onrender.com"
const DEFAULT_PORT := 8080
const CONNECT_TIMEOUT := 45.0   # free hosts can take ~30s to wake up
const PONG_TIMEOUT := 12.0
const MAX_OBJECTS := 200
const MAX_CHAT := 100
const MEM_LIMIT_FRACTION := 0.88                      # server: act when this share of RAM is used
const MEM_FALLBACK_LIMIT := 480.0 * 1024.0 * 1024.0   # bytes (Render free = 512 MB)
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
var _notice := ""
var _last_chat := {}
var _mem_t := 0.0
var _kick_cd := 0.0
var _exact: Array[RegEx] = []
var _strong: Array[RegEx] = []


func _ready() -> void:
	_setup_input()
	_build_filter()
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
		var t := _notice if _notice != "" else "Connection lost - single player"
		_notice = ""
		go_offline(t)


func _process(delta: float) -> void:
	if dedicated:
		_server_tick(delta)
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
		_last_chat.erase(id)
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
	if pname.is_empty() or censor(pname) != pname:
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
func send_chat(text: String) -> void:
	if not dedicated:
		return
	var id := multiplayer.get_remote_sender_id()
	if not names.has(id):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last_chat.get(id, -10.0)) < 0.8:
		return   # anti-spam
	_last_chat[id] = now
	var clean := censor(text)
	if clean.strip_edges().is_empty():
		return
	for other in names.keys():
		got_chat.rpc_id(other, names[id], clean)


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
func got_chat(pname: String, text: String) -> void:
	chat_received.emit(pname, text)


@rpc("authority", "call_remote", "reliable")
func notice(text: String) -> void:
	_notice = text
	notice_received.emit(text)


@rpc("authority", "call_remote", "reliable")
func trim_objects(count: int) -> void:
	objects_trimmed.emit(count)


@rpc("authority", "call_remote", "reliable")
func pong() -> void:
	_last_pong = Time.get_ticks_msec() / 1000.0


# ---------------------------------------------------------------- server memory guard

func _server_tick(delta: float) -> void:
	_kick_cd = maxf(0.0, _kick_cd - delta)
	_mem_t -= delta
	if _mem_t > 0.0:
		return
	_mem_t = 2.0
	var frac := memory_fraction()
	if frac < MEM_LIMIT_FRACTION or _kick_cd > 0.0:
		return
	_kick_cd = 5.0
	print("Memory high (%d%%): trimming objects and disconnecting a random player" % int(frac * 100.0))
	var count := int(_objects.size() * 0.5)
	if count > 0:
		_objects = _objects.slice(count)
		for other in names.keys():
			trim_objects.rpc_id(other, count)
	if not names.is_empty():
		var victim: int = names.keys().pick_random()
		notice.rpc_id(victim, "Server memory is almost full - you were disconnected. Playing single player.")
		get_tree().create_timer(0.4).timeout.connect(_kick.bind(victim))


func _kick(id: int) -> void:
	var mp := multiplayer.multiplayer_peer
	if mp != null and names.has(id):
		mp.disconnect_peer(id)


func memory_fraction() -> float:
	var used := _read_rss()
	if used <= 0.0:
		used = float(OS.get_static_memory_usage())
	var limit := MEM_FALLBACK_LIMIT
	var cg := _read_cgroup_limit()
	if cg > 0.0:
		limit = minf(cg, MEM_FALLBACK_LIMIT)
	return used / limit


func _read_rss() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return -1.0
	for line in f.get_as_text().split("\n"):
		if line.begins_with("VmRSS:"):
			var parts := line.replace("\t", " ").split(" ", false)
			if parts.size() >= 2:
				return float(parts[1]) * 1024.0
	return -1.0


func _read_cgroup_limit() -> float:
	for path in ["/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"]:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var s := f.get_as_text().strip_edges()
		if s.is_valid_float():
			var v := float(s)
			if v > 0.0 and v < 1.0e13:
				return v
	return -1.0


# ---------------------------------------------------------------- smart chat filter
# Catches leetspeak (sh1t, a$$), stretched letters (fuuuck), spaced letters (f u c k),
# inflections (fucking, shitty) and words glued together (fuckyou), but not innocent
# words that merely contain a short bad word (class, assume, Scunthorpe).

const BAD_WORDS := ["fuck", "shit", "bitch", "cunt", "dick", "cock", "pussy", "asshole", "ass", "arse",
	"bastard", "damn", "crap", "piss", "slut", "whore", "fag", "faggot", "nigger", "nigga", "retard",
	"twat", "wanker", "bollocks", "douche", "jackass", "dumbass", "dipshit", "bullshit", "motherfucker"]
const STRONG_WORDS := ["fuck", "shit", "bitch", "cunt", "nigger", "nigga", "faggot", "whore", "slut",
	"pussy", "asshole", "bastard", "wanker"]
const SAFE_WORDS := ["shiitake", "scunthorpe"]


func _pattern(word: String) -> String:
	# letters stay stretchable ("fuuuck"); doubled letters ("ss") must stay doubled
	var out := ""
	var i := 0
	while i < word.length():
		var c := word[i]
		var run := 1
		while i + run < word.length() and word[i + run] == c:
			run += 1
		out += c + ("+" if run == 1 else "{%d,}" % run)
		i += run
	return out


func _build_filter() -> void:
	for w in BAD_WORDS:
		var rx := RegEx.new()
		rx.compile("^" + _pattern(w) + "(s|es|ed|ing|in|er|ers|y)?$")
		_exact.append(rx)
	for w in STRONG_WORDS:
		var rs := RegEx.new()
		rs.compile(_pattern(w))
		_strong.append(rs)


func _leet(c: String) -> String:
	match c:
		"0": return "o"
		"1": return "i"
		"3": return "e"
		"4": return "a"
		"5": return "s"
		"7": return "t"
		"@": return "a"
		"$": return "s"
		"!": return "i"
		"+": return "t"
	return c


func _bad_range(norm: String) -> Vector2i:
	if norm.length() < 3:
		return Vector2i(-1, -1)
	for s in SAFE_WORDS:
		if norm.contains(s):
			return Vector2i(-1, -1)
	for rx in _exact:
		if rx.search(norm) != null:
			return Vector2i(0, norm.length())
	for rs in _strong:
		var m := rs.search(norm)
		if m != null:
			return Vector2i(m.get_start(), m.get_end())
	return Vector2i(-1, -1)


func _flush(tokens: Array, norm: String, raw: String, idx: Array) -> void:
	while raw.length() > 0 and (raw.ends_with("!") or raw.ends_with("+")):
		raw = raw.substr(0, raw.length() - 1)
		norm = norm.substr(0, norm.length() - 1)
		idx.pop_back()
	while raw.length() > 0 and (raw.begins_with("!") or raw.begins_with("+")):
		raw = raw.substr(1)
		norm = norm.substr(1)
		idx.pop_front()
	if norm.length() > 0:
		tokens.append({"norm": norm, "idx": idx})


func censor(text: String) -> String:
	var t := text.strip_edges()
	if t.length() > MAX_CHAT:
		t = t.substr(0, MAX_CHAT)
	var chars := t.split("")
	var tokens: Array = []
	var cur_norm := ""
	var cur_raw := ""
	var cur_idx: Array = []
	for ci in t.length():
		var raw := t[ci].to_lower()
		var m := _leet(raw)
		if m.length() == 1 and m >= "a" and m <= "z":
			cur_norm += m
			cur_raw += raw
			cur_idx.append(ci)
		else:
			_flush(tokens, cur_norm, cur_raw, cur_idx)
			cur_norm = ""
			cur_raw = ""
			cur_idx = []
	_flush(tokens, cur_norm, cur_raw, cur_idx)

	# 1) whole words
	for tok in tokens:
		var r := _bad_range(tok["norm"])
		if r.x >= 0:
			for k in range(r.x, r.y):
				chars[tok["idx"][k]] = "*"

	# 2) letters spread out: "f u c k", "f.u.c.k"
	var ti := 0
	while ti < tokens.size():
		if String(tokens[ti]["norm"]).length() == 1:
			var tj := ti
			var joined := ""
			var idxs: Array = []
			while tj < tokens.size() and String(tokens[tj]["norm"]).length() == 1:
				if tj > ti:
					var gap := int(tokens[tj]["idx"][0]) - int(tokens[tj - 1]["idx"][0]) - 1
					if gap > 2:
						break
				joined += String(tokens[tj]["norm"])
				idxs.append(tokens[tj]["idx"][0])
				tj += 1
			if tj - ti >= 3:
				var r2 := _bad_range(joined)
				if r2.x >= 0:
					for k in range(r2.x, r2.y):
						chars[idxs[k]] = "*"
			ti = maxi(tj, ti + 1)
		else:
			ti += 1
	return "".join(chars)


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
	_key("chat", KEY_T)
	_key("chat", KEY_ENTER)
	_key("view", KEY_V)
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
