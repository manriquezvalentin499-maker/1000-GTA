extends Node

signal connection_status(message: String)
signal avatar_received(peer_id: int, state: Dictionary)
signal avatar_removed(peer_id: int)
signal passenger_changed(driver_id: int, message: String)

const MAX_PLAYERS := 8
const VERSION := 4
const CATALOG_LIMITS := {2: 107, 3: 109, 4: 111}
const WORLD_EDGE := 6400.0

var hosting := false
var connected := false
var approved: Dictionary = {}
var last_update: Dictionary = {}
var positions: Dictionary = {}
var passengers: Dictionary = {} # passenger -> driver
var seats: Dictionary = {} # driver -> passenger

func _ready() -> void:
	multiplayer.peer_disconnected.connect(peer_left)
	multiplayer.connected_to_server.connect(handshake)
	multiplayer.connection_failed.connect(func(): disconnect_game("No se pudo conectar al servidor."))
	multiplayer.server_disconnected.connect(func(): disconnect_game("Se perdió la conexión."))

func serve(port: int) -> Error:
	var socket := WebSocketMultiplayerPeer.new()
	socket.handshake_timeout = 10.0
	var result := socket.create_server(port, "0.0.0.0")
	if result == OK:
		hosting = true
		multiplayer.multiplayer_peer = socket
		print("Ciudad Aurora escuchando WebSocket en el puerto ", port)
		multiplayer.peer_connected.connect(check_handshake)
	return result

func connect_to(url: String) -> void:
	if multiplayer.has_multiplayer_peer():
		disconnect_game("")
	var endpoint := url.strip_edges()
	if endpoint.begins_with("https://"):
		endpoint = "wss://" + endpoint.trim_prefix("https://")
	if not endpoint.begins_with("wss://") and not endpoint.begins_with("ws://"):
		connection_status.emit("Introduce una dirección wss:// válida.")
		return
	var socket := WebSocketMultiplayerPeer.new()
	socket.handshake_timeout = 15.0
	var result := socket.create_client(endpoint)
	if result != OK:
		connection_status.emit("Error de conexión: " + error_string(result))
		return
	multiplayer.multiplayer_peer = socket
	connection_status.emit("Conectando…")

func disconnect_game(message := "Modo sin conexión.") -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	for id in approved.keys():
		avatar_removed.emit(id)
	approved.clear()
	connected = false
	passenger_changed.emit(0, "")
	if not message.is_empty():
		connection_status.emit(message)

func handshake() -> void:
	register_player.rpc_id(1, VERSION)

func check_handshake(peer_id: int) -> void:
	await get_tree().create_timer(10.0).timeout
	if multiplayer.get_peers().has(peer_id) and not approved.has(peer_id):
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)

@rpc("any_peer", "reliable")
func register_player(version: int) -> void:
	if not hosting:
		return
	var id := multiplayer.get_remote_sender_id()
	if approved.has(id):
		return
	if not CATALOG_LIMITS.has(version) or approved.size() >= MAX_PLAYERS:
		rejected.rpc_id(id, "Sala llena o versión incompatible.")
		return
	approved[id] = version
	welcome.rpc_id(id)

@rpc("authority", "reliable")
func welcome() -> void:
	connected = true
	connection_status.emit("En línea · Ciudad Aurora")

@rpc("authority", "reliable")
func rejected(message: String) -> void:
	disconnect_game(message)

func push(position: Vector3, heading: float, vehicle: int, mode: int, floor_number: int, color: Color) -> void:
	if connected:
		submit.rpc_id(1, position, heading, vehicle, mode, floor_number, color)

@rpc("any_peer", "reliable")
func submit(position: Vector3, heading: float, vehicle: int, mode: int, floor_number: int, color: Color) -> void:
	if not hosting:
		return
	var id := multiplayer.get_remote_sender_id()
	if not approved.has(id) or not position.is_finite() or not is_finite(heading) or not Vector3(color.r, color.g, color.b).is_finite() or not is_finite(color.a):
		return
	if absf(position.x) > WORLD_EDGE or absf(position.z) > WORLD_EDGE or position.y < -40 or position.y > 125:
		return
	if vehicle < -1 or vehicle >= int(CATALOG_LIMITS[approved[id]]) or mode < 0 or mode > 2 or floor_number < 0 or floor_number > 40:
		return
	var now := Time.get_ticks_msec()
	if now - int(last_update.get(id, -100)) < 60:
		return
	last_update[id] = now
	if passengers.has(id):
		return
	if seats.has(id) and (vehicle < 0 or int(positions.get(id, {}).get("floor", floor_number)) != floor_number):
		release_seat(seats[id], "El conductor dejó el vehículo.")
	positions[id] = {"position": position, "vehicle": vehicle, "floor": floor_number}
	for receiver in approved:
		if receiver != id:
			var visible_model := vehicle
			if vehicle >= int(CATALOG_LIMITS[approved[receiver]]):
				visible_model = 0
			snapshot.rpc_id(receiver, id, position, wrapf(heading, -PI, PI), visible_model, mode, floor_number, color.clamp())

@rpc("authority", "reliable")
func snapshot(id: int, position: Vector3, heading: float, vehicle: int, mode: int, floor_number: int, color: Color) -> void:
	if connected:
		approved[id] = true
		avatar_received.emit(id, {"position": position, "heading": heading, "ride": vehicle, "mode": mode, "floor": floor_number, "color": color})

func peer_left(id: int) -> void:
	if hosting:
		var known := approved.erase(id)
		last_update.erase(id)
		positions.erase(id)
		if passengers.has(id):
			release_seat(id, "", false)
		if seats.has(id):
			release_seat(seats[id], "El conductor se desconectó.")
		if known:
			for receiver in approved:
				remove_avatar.rpc_id(receiver, id)

@rpc("authority", "reliable")
func remove_avatar(id: int) -> void:
	approved.erase(id)
	avatar_removed.emit(id)

func request_passenger(driver_id: int) -> void:
	if connected:
		change_seat.rpc_id(1, driver_id)

@rpc("any_peer", "reliable")
func change_seat(driver_id: int) -> void:
	if not hosting:
		return
	var rider := multiplayer.get_remote_sender_id()
	if not approved.has(rider):
		return
	if driver_id == 0:
		release_seat(rider, "Bajaste del vehículo.")
		return
	if passengers.has(rider):
		return
	var source: Dictionary = positions.get(rider, {})
	var driver: Dictionary = positions.get(driver_id, {})
	var fresh := Time.get_ticks_msec() - int(last_update.get(driver_id, -10000)) < 1800
	if rider == driver_id or source.is_empty() or driver.is_empty() or not fresh:
		seat_result.rpc_id(rider, 0, "Vehículo no disponible.")
		return
	if seats.has(driver_id):
		seat_result.rpc_id(rider, 0, "El asiento ya está ocupado.")
		return
	var passenger_position: Vector3 = source.position
	if source.vehicle >= 0 or driver.vehicle < 0 or source.floor != driver.floor or passenger_position.distance_to(driver.position) > 8.0:
		seat_result.rpc_id(rider, 0, "Acércate al vehículo para subir.")
		return
	passengers[rider] = driver_id
	seats[driver_id] = rider
	for receiver in approved:
		if receiver != rider:
			remove_avatar.rpc_id(receiver, rider)
	seat_result.rpc_id(rider, driver_id, "Viajando como pasajero.")

func release_seat(rider: int, message: String, notify := true) -> void:
	if not passengers.has(rider):
		return
	seats.erase(passengers[rider])
	passengers.erase(rider)
	if notify and approved.has(rider):
		seat_result.rpc_id(rider, 0, message)

@rpc("authority", "reliable")
func seat_result(driver_id: int, message: String) -> void:
	if connected:
		passenger_changed.emit(driver_id, message)
