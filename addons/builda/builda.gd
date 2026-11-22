extends Node

const BUILDA_SDK_VERSION := "0.29.4"

signal sdk_result(request_id: int, result: Dictionary)
# Host/browser events (subscription callbacks, alongside the request/sdk_result model). sdk_event is the generic form
# (name + payload Dictionary); app_visibility_changed is a convenience signal for appVisibility:
# visible=false means the App is minimized/backgrounded/screen-locked (pause gameplay/timers/BGM); true means back in foreground (resume).
# source is "host" (pushed by the Builda App host, precise) or "browser" (WebView visibilitychange fallback).
# Fires only on state changes (deduplicated by the SDK); after the node enters the scene tree the current state is not replayed (initially treated as foreground).
# Events are dispatched via per-frame polling (same mechanism as sdk_result), not in a gesture context. This wrapper is designed as a single instance.
signal sdk_event(name: String, payload: Dictionary)
signal app_visibility_changed(visible: bool, source: String)
# The host's "Paused" panel (capsule ✕ / the same panel runtime_quit() pops up): visible=true when the panel pops up (pause gameplay/
# timers; the host stops/resumes BGM itself), false when the panel closes without quitting (resume); an actual quit does not fire. Orthogonal to foreground/background;
# handle as "pause if either is paused, resume only when all have resumed".
signal pause_panel_changed(visible: bool)

const _EVENT_NAMES := ["appVisibility", "pausePanel"]

var _next_request_id := 1
var _pending: Array[int] = []
var _events_bound := false

func _ready() -> void:
	# A common pattern on backgrounding is get_tree().paused = true; this node must not pause with the tree, otherwise polling stalls and
	# neither the foreground app_visibility_changed nor in-flight sdk_result can be dispatched.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__buildaResults = window.__buildaResults || {}; window.__buildaEvents = window.__buildaEvents || [];", true)
		_bind_events()
	set_process(true)

# Subscribes Builda.events.* into a JS-side queue that _process drains every frame. If the SDK script becomes ready after this node
# (rare), _process keeps retrying until binding succeeds.
func _bind_events() -> void:
	if _events_bound or not OS.has_feature("web"):
		return
	var bound = JavaScriptBridge.eval("(function(){if(!window.Builda||!window.Builda.events)return false;if(!window.__buildaEventsBound){window.__buildaEventsBound=true;window.__buildaEvents=window.__buildaEvents||[];" + JSON.stringify(_EVENT_NAMES) + ".forEach(function(n){window.Builda.events.on(n,function(p){window.__buildaEvents.push(JSON.stringify({name:n,payload:p}));});});}return true;})();", true)
	_events_bound = _eval_bool(bound)

# Godot 4.7 Web exports can return JS booleans from JavaScriptBridge.eval as TYPE_INT (1/0); avoid `== true`, which fails on int vs bool.
static func _is_eval_bool(value: Variant) -> bool:
	return typeof(value) == TYPE_BOOL or typeof(value) == TYPE_INT

static func _eval_bool(value: Variant) -> bool:
	return _is_eval_bool(value) and bool(value)

func whoami() -> int:
	return _call_js("return Builda.whoami();")

# Exchanges with the host for a game-scoped short-lived token (data = {token, expiresAt}, expiresAt in Unix seconds),
# for the game to call Builda services that require auth directly. Hold the token in memory only: never write it to privateKV, local files,
# URLs or saves; the Runtime SDK caches it in memory and lazily refreshes it near expiry.
func request_token() -> int:
	return _call_js("return Builda.requestToken();")

# Gets the server's current Unix time in milliseconds; result data = {serverTimeMs}.
func get_server_time() -> int:
	return _call_js("return Builda.getServerTime();")

# Batch-queries public profiles of Builda player roles. Result data is {roleId: {userName, userImg}};
# a roleId missing from the map means not found this time. The SDK aggregates internally over a fixed 50ms window, at most 32 per call.
func get_role_info(role_ids: PackedStringArray) -> int:
	return _call_js("return Builda.getRoleInfo(" + JSON.stringify(role_ids) + ");")

# Reads a dynamic config table by name; the result's data is the table. A table is fetched
# on its first read and rechecked at most once a minute. A failure is not an empty table.
# Each read copies the whole table across the bridge and answers on a later frame:
# read when a scene starts and keep the result; never read every frame.
func config_read(table: String) -> int:
	return _call_js("return Builda.config.read(" + JSON.stringify(table) + ");")

# Non-authoritative observation of this player's stored Player Data; may not include unsynced actions; revision/source do not prove freshness.
# Rewards, deductions, stealing, payments etc. are decided by Online game server actions; never write the whole save back over it; later stale reads must not
# overturn official action results or be used to replay them. Failure is not an empty save/zero balance. privateKV is independent storage.
# int64/revision stay strings, bytes are base64, schemaVersion is a uint32 number or null.
func player_data_get_many(keys: PackedStringArray) -> int:
	return _call_js("return Builda.playerData.getMany(" + JSON.stringify(keys) + ");")

# Directory in data.meta.keys, data.values is {}; likewise a possibly stale non-authoritative observation.
# revision/source do not prove freshness; do not decide rewards/deductions/stealing/payments, overwrite saves, or replay server actions from it.
func player_data_list_keys() -> int:
	return _call_js("return Builda.playerData.listKeys();")

# privateKV: private save (current game × current player); value is a PackedByteArray (var_to_bytes() to encode,
# bytes_to_var() to restore, recommended). Always base64 across the bridge: value in sdk_result results is a base64 string,
# restore it with private_kv_bytes(); get's data being null means the key does not exist (empty bytes are a valid value).
# Limits: single value ≤ 32KB, ≤ 32 keys per batch, ≤ 100 live keys per player per game; no aggregate byte quota.
# The SDK does not split batches automatically; more than 32 keys returns BATCH_TOO_LARGE.
func private_kv_get(key: String) -> int:
	return _call_js("return Builda.privateKV.get(" + JSON.stringify(key) + ", {encoding:\"base64\"});")

func private_kv_set(key: String, value: PackedByteArray) -> int:
	return _call_js("return Builda.privateKV.set(" + JSON.stringify(key) + ", " + JSON.stringify(Marshalls.raw_to_base64(value)) + ", {encoding:\"base64\"});")

func private_kv_remove(key: String) -> int:
	return _call_js("return Builda.privateKV.remove(" + JSON.stringify(key) + ");")

func private_kv_get_many(keys: PackedStringArray) -> int:
	return _call_js("return Builda.privateKV.getMany(" + JSON.stringify(keys) + ", {encoding:\"base64\"});")

# entries: Dictionary[String, PackedByteArray]; the whole batch is validated and rejected entirely on any violation, no partial writes
func private_kv_set_many(entries: Dictionary) -> int:
	var encoded := {}
	for key in entries:
		encoded[key] = Marshalls.raw_to_base64(entries[key])
	return _call_js("return Builda.privateKV.setMany(" + JSON.stringify(encoded) + ", {encoding:\"base64\"});")

func private_kv_remove_many(keys: PackedStringArray) -> int:
	return _call_js("return Builda.privateKV.removeMany(" + JSON.stringify(keys) + ");")

static func private_kv_bytes(value: Variant) -> PackedByteArray:
	if typeof(value) != TYPE_STRING:
		return PackedByteArray()
	return Marshalls.base64_to_raw(value)

# assets.zip has two subtrees: audio/** (host audio) and res/** (large assets the game fetches itself, e.g. 3D models —
# HTTPRequest fetches the URL from asset_url("res/…"), then GLTFDocument.append_from_buffer instantiates it).
# Never hard-code CDN URLs; assetsBaseUrl changes on every re-upload.
func asset_url(path: String) -> int:
	return _call_js("return {ok:true,data:Builda.assets.url(" + JSON.stringify(path) + ")};")

func audio_play_bgm(path: String, loop := true, volume := 1.0) -> int:
	return _call_js("return Builda.audio.playBGM(" + JSON.stringify(path) + ", {loop:" + JSON.stringify(loop) + ", volume:" + JSON.stringify(volume) + "});")

func audio_stop_bgm() -> int:
	return _call_js("return Builda.audio.stopBGM();")

func audio_play_sfx(path: String, session_id := "", volume := 1.0) -> int:
	return _call_js("return Builda.audio.playSFX(" + JSON.stringify(path) + ", {sessionId:" + JSON.stringify(session_id) + ", volume:" + JSON.stringify(volume) + "});")

func audio_set_muted(muted: bool, group := "bgm") -> int:
	return _call_js("return Builda.audio.setMuted(" + JSON.stringify(muted) + ", " + JSON.stringify(group) + ");")

func audio_vibrate(level := 2) -> int:
	return _call_js("return Builda.audio.vibrate(" + JSON.stringify(level) + ");")

# Microphone (docs/decisions/0012 L0+L1). The standard flow is **two gestures**: in the 1st tap callback,
# audio_request_microphone() requests permission (data.available == false means the user denied or there is no mic; the game
# just shows a clear blocking prompt and allows retry; a no-mic alternative gameplay is optional) → after sdk_result delivers the permission result,
# **do not call mic_start() directly** — signals are dispatched via per-frame
# polling, not in a gesture context, so the AudioContext would be blocked by the autoplay policy unrecoverably; stop at a "tap
# once more" UI prompt → in the 2nd tap callback call mic_start() → each frame mic_read() pulls PCM synchronously →
# mic_stop() when done. Concurrent/repeated mic_start() calls are deduplicated in flight by the SDK with merged results, never returning a transient BUSY.
# The SDK only provides raw PCM (mono float32); put pitch/volume feature analysis in the game's own Web Worker;
# do not run heavy DSP in GDScript (it competes with the engine for main-thread frame budget). PCM may only be analyzed locally in real time; never retain
# or upload recordings. After an interruption (incoming call/backgrounding) the SDK rebuilds automatically; when mic_read()'s data.state stays
# "interrupted", prompt the player to tap, then call mic_start() again (idempotent, re-entrant).
func audio_request_microphone() -> int:
	return _call_js("return Builda.audio.requestMicrophone();")

# sample_rate 0 means follow the AudioContext default (the actual value is data.sampleRate in sdk_result)
func mic_start(sample_rate := 0, buffer_ms := 1000) -> int:
	var opts := "{bufferMs:" + JSON.stringify(buffer_ms)
	if sample_rate > 0:
		opts += ", sampleRate:" + JSON.stringify(sample_rate)
	opts += "}"
	return _call_js("return Builda.mic.start(" + opts + ");")

# Synchronously pulls new PCM samples since the last read (once per frame is enough); returns a Dictionary directly instead of going through the
# sdk_result signal (real-time data must be available in the same frame). On success data = {samples(base64), sampleRate,
# dropped, state}; restore samples to PackedFloat32Array with mic_samples(); dropped > 0 means samples were
# overwritten because pulling was too slow (usually harmless for real-time control; do not treat it as a continuous stream for recording). max_samples 0 means all unread.
func mic_read(max_samples := 0) -> Dictionary:
	if not OS.has_feature("web"):
		return {"ok": false, "error": {"code": "UNSUPPORTED", "message": "Builda SDK requires Web export."}}
	var opts := "{encoding:\"base64\""
	if max_samples > 0:
		opts += ", maxSamples:" + JSON.stringify(max_samples)
	opts += "}"
	var raw = JavaScriptBridge.eval("JSON.stringify((function(){try{return Builda.mic.read(" + opts + ");}catch(e){return {ok:false,error:{code:'JS_ERROR',message:String(e)}};}})());", true)
	var parsed = JSON.parse_string(str(raw)) if raw != null else null
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": {"code": "BAD_RESULT", "message": "Invalid Builda SDK result."}}
	return parsed

func mic_stop() -> int:
	return _call_js("return Builda.mic.stop();")

# Restores the base64 samples from a mic_read() result to PackedFloat32Array (float32 little-endian)
static func mic_samples(value: Variant) -> PackedFloat32Array:
	if typeof(value) != TYPE_STRING:
		return PackedFloat32Array()
	return Marshalls.base64_to_raw(value).to_float32_array()

# legacy in-app purchase: auto-confirms fulfillment after payment and cannot recover orders whose fulfillment failed. New games use iap_*.
func pay_show_panel(sale_id: String) -> int:
	return _call_js("return Builda.pay.showPayPanel(" + JSON.stringify(sale_id) + ");")

# In-app purchase (no auto claim): result data = {success, orderId, grantBy}; success only means the payment succeeded, the order stays Paid.
# grant_by ("client" / "room") declares the grant path the game intends to use, for host pass-through and mismatch diagnostics.
# It does not override the order's frozen configuration nor guarantee order creation is rejected on mismatch; if empty, the host uses the price list declaration.
# For response grantBy=client orders, grant idempotently by orderId, then call iap_claim; for room orders hand orderId to Room doOrder and do not claim.
func iap_show_pay_panel(sale_id: String, grant_by := "") -> int:
	if grant_by == "":
		return _call_js("return Builda.iap.showPayPanel(" + JSON.stringify(sale_id) + ");")
	return _call_js("return Builda.iap.showPayPanel(" + JSON.stringify(sale_id) + ", {grantBy:" + JSON.stringify(grant_by) + "});")

# Claim confirmation Paid→Delivered (idempotent; repeat calls replay success). Only call it for grantBy=client orders already fully granted. Result data = {orderId, status}.
func iap_claim(order_id: String) -> int:
	return _call_js("return Builda.iap.claim(" + JSON.stringify(order_id) + ");")

# List of undelivered orderIds. Result data = {orderIds: Array}. Read-only, no payId/grantBy. When the granter is unknown, do not assume client-side granting.
func iap_get_pending_order_ids() -> int:
	return _call_js("return Builda.iap.getPendingOrderIds();")

# pos_id is a game-defined ad slot tracking identifier (any name, e.g. "revive"), only used to distinguish ad trigger points;
# it is not a platform-assigned ad slot ID — no application needed, no need to declare it in the manifest.
func ad_show_reward(pos_id: String) -> int:
	return _call_js("return Builda.ad.showRewardAd(" + JSON.stringify(pos_id) + ");")

# Leaderboards (boards must first be declared in rankBoards of builda.publish.json and published to take effect).
# submit's score is an integer; the host validates the range against the board config and keeps the best score per period by sortType.
# get_list result data = {rankId, list: [{rank, score, player}], self: {rank, score}|null}.
func rank_submit_score(rank_id: String, score: int) -> int:
	return _call_js("return Builda.rank.submitScore(" + JSON.stringify(rank_id) + ", " + JSON.stringify(score) + ");")

func rank_get_list(rank_id: String, limit := 50) -> int:
	return _call_js("return Builda.rank.getRankList(" + JSON.stringify(rank_id) + ", {limit:" + JSON.stringify(limit) + "});")

# Opens the platform input panel (input box + keyboard, no title bar). Result data = {confirmed, text}:
# on confirm text is the final text (moderation/truncation already done by the platform); on cancel confirmed=false, text="".
# Calling again while the panel is still open returns BUSY. max_length defaults to 64, max 256.
func input_show_panel(placeholder := "", default_value := "", max_length := 64) -> int:
	return _call_js("return Builda.input.showInputPanel({placeholder:" + JSON.stringify(placeholder) + ", defaultValue:" + JSON.stringify(default_value) + ", maxLength:" + JSON.stringify(max_length) + "});")

# Game liveness handshake: must be called at the very start of the game (first thing in Autoload/first scene _ready(); do not wait for assets to finish loading),
# and make sure every startup path reaches it — if the host does not receive ready within 30 seconds of page load, it force-closes the game.
func runtime_ready() -> int:
	return _call_js("return Builda.runtime.ready();")

func runtime_quit() -> int:
	return _call_js("return Builda.runtime.quit();")

# Keep-screen-on switch: true prevents the system from auto-sleeping the screen, false restores the system timeout. The result comes back via sdk_result;
# **minimum host version App 1.84.0**; older hosts reply UNSUPPORTED_CMD — just degrade as unsupported.
# data.enabled is the **actual effective state** (false when the host has not integrated this capability / the system refuses).
# Scope is this game session only: the host resets it when leaving the game page; the game need not turn it off in _exit_tree.
func runtime_set_keep_screen_on(enabled: bool) -> int:
	return _call_js("return Builda.runtime.setKeepScreenOn(%s);" % ("true" if enabled else "false"))

func runtime_safe_area() -> int:
	return _call_js("return {ok:true,data:Builda.runtime.safeArea()};")

func runtime_capsule_menu_rect() -> int:
	return _call_js("return {ok:true,data:Builda.runtime.capsuleMenuRect()};")

# Current language (BCP 47, e.g. "en", "zh", "es-419"), returned synchronously as a String (not via sdk_result);
# falls back to "en" on non-web exports or read errors. Suggested matching order: exact → language prefix (es-419 → es) → game default language.
func runtime_language() -> String:
	if not OS.has_feature("web"):
		return "en"
	var v = JavaScriptBridge.eval("(window.Builda && window.Builda.runtime.language()) || \"en\";", true)
	if typeof(v) != TYPE_STRING or String(v).strip_edges().is_empty():
		return "en"
	return String(v).strip_edges()

# Version of the host Builda App (like "1.84.0"), returned synchronously as a String (not via sdk_result).
# Injected by the host since App 1.84.0; when unavailable (older App / non-web export / read error) it always returns
# "1.83.0" — the last App version that does not provide this value, so "old host" and "no host" need not be distinguished.
# For feature detection use runtime_app_version_at_least(); do not compare strings directly.
const APP_VERSION_FALLBACK := "1.83.0"

func runtime_app_version() -> String:
	if not OS.has_feature("web"):
		return APP_VERSION_FALLBACK
	var v = JavaScriptBridge.eval("(window.Builda && window.Builda.runtime.appVersion()) || \"%s\";" % APP_VERSION_FALLBACK, true)
	if typeof(v) != TYPE_STRING or String(v).strip_edges().is_empty():
		return APP_VERSION_FALLBACK
	return String(v).strip_edges()

# Whether the host version >= target (e.g. "1.84.0") — use this method for feature detection of new capabilities; do not take
# runtime_app_version() and compare strings yourself (in string order "1.9.0" > "1.10.0" gives the wrong answer).
# On web exports it delegates directly to the SDK core's appVersionAtLeast(), guaranteeing results identical to HTML5/Unity;
# non-web exports have no host and the version is always the fallback, so it compares locally with the same rules.
# Other relations compose from it: less-than is not at_least(x), a range is at_least(a) and not at_least(b).
func runtime_app_version_at_least(target: String) -> bool:
	var want := target.strip_edges()
	if OS.has_feature("web"):
		# target only allows digits and dots, so quotes/backslashes cannot break the syntax when spliced into a JS literal.
		var safe := ""
		for c in want:
			if c == "." or (c >= "0" and c <= "9"):
				safe += c
		var v = JavaScriptBridge.eval("!!(window.Builda && window.Builda.runtime.appVersionAtLeast(\"%s\"));" % safe, true)
		if _is_eval_bool(v):
			return bool(v)
	return _version_at_least(runtime_app_version(), want)

# Compares segment by segment numerically (missing segments count as 0). Only for the non-web export / JS read error fallback path;
# with a host, the SDK core's implementation is authoritative.
func _version_at_least(cur: String, target: String) -> bool:
	var a := cur.split(".")
	var b := target.split(".")
	for i in range(max(a.size(), b.size())):
		var x := int(a[i]) if i < a.size() else 0
		var y := int(b[i]) if i < b.size() else 0
		if x != y:
			return x > y
	return true

func _call_js(js_expr: String) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	if not OS.has_feature("web"):
		call_deferred("_emit_result", request_id, {"ok": false, "error": {"code": "UNSUPPORTED", "message": "Builda SDK requires Web export."}})
		return request_id
	_pending.append(request_id)
    JavaScriptBridge.eval("Promise.resolve().then(function(){return (function(){" + js_expr + "})();}).then(function(r){window.__buildaResults[" + str(request_id) + "]=JSON.stringify(r);}).catch(function(e){window.__buildaResults[" + str(request_id) + "]=JSON.stringify({ok:false,error:{code:'JS_ERROR',message:String(e)}});});", true)
	return request_id

func _process(_delta: float) -> void:
	if not OS.has_feature("web"):
		return
	_bind_events()
	_drain_events()
	if _pending.is_empty():
		return
	var done: Array[int] = []
	for request_id in _pending:
		var raw = JavaScriptBridge.eval("window.__buildaResults && window.__buildaResults[" + str(request_id) + "] || null;", true)
		if raw == null:
			continue
		JavaScriptBridge.eval("delete window.__buildaResults[" + str(request_id) + "];", true)
		var parsed = JSON.parse_string(str(raw))
		if typeof(parsed) != TYPE_DICTIONARY:
			parsed = {"ok": false, "error": {"code": "BAD_RESULT", "message": "Invalid Builda SDK result."}}
		_emit_result(request_id, parsed)
		done.append(request_id)
	for request_id in done:
		_pending.erase(request_id)

func _emit_result(request_id: int, result: Dictionary) -> void:
	sdk_result.emit(request_id, result)

# Drains the whole JS-side event queue in one eval (order preserved) and dispatches signals one by one
func _drain_events() -> void:
	if not _events_bound:
		return
	var raw = JavaScriptBridge.eval("(function(){var q=window.__buildaEvents;if(!q||!q.length)return null;var out='['+q.join(',')+']';q.length=0;return out;})();", true)
	if raw == null:
		return
	var parsed = JSON.parse_string(str(raw))
	if typeof(parsed) != TYPE_ARRAY:
		return
	for item in parsed:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var name := String(item.get("name", ""))
		var payload = item.get("payload", {})
		if typeof(payload) != TYPE_DICTIONARY:
			payload = {}
		sdk_event.emit(name, payload)
		if name == "appVisibility":
			app_visibility_changed.emit(bool(payload.get("visible", true)), String(payload.get("source", "")))
		elif name == "pausePanel":
			pause_panel_changed.emit(bool(payload.get("visible", false)))

# Developer logs / behavior tracking. Requires Builda App v1.87.2 or later (v1.87.2 included).
# Older Apps resolve UNSUPPORTED_CMD (no upgrade prompt). Local acceptance only; no network wait in the game loop.
func log_event(event_name: String, message: String, attributes: Dictionary = {}, level: String = "info") -> int:
	return _call_js("return Builda.logEvent(" + JSON.stringify(event_name) + "," + JSON.stringify(message) + "," + JSON.stringify(attributes) + "," + JSON.stringify(level) + ");")

func track_event(event_name: String, attributes: Dictionary = {}) -> int:
	return _call_js("return Builda.trackEvent(" + JSON.stringify(event_name) + "," + JSON.stringify(attributes) + ");")
