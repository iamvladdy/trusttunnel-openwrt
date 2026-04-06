#!/bin/sh
# TrustTunnel netifd protocol handler for OpenWRT
# Modeled after amneziawg.sh from awg-openwrt

TT_CLIENT=/opt/trusttunnel_client/trusttunnel_client
TT_RUN_DIR=/var/run/trusttunnel
TT_TABLE=880

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_trusttunnel_init_config() {
	proto_config_add_string "config_file"  # path to trusttunnel_client.toml
	proto_config_add_int    "mtu"          # MTU override (default: 1280)
	# shellcheck disable=SC2034
	available=1
	# shellcheck disable=SC2034
	no_proto_task=1
}

# Clean up all routing state that the binary leaves behind.
# The binary's teardown_routes() only removes ip rules but not routes
# from table 880. Stale routes cause EEXIST on next setup_routes() call.
tt_cleanup_routes() {
	# Remove ip rules
	ip    rule del prio 30801 lookup $TT_TABLE  2>/dev/null || true
	ip    rule del prio 30800 sport 1-1024 lookup main 2>/dev/null || true
	ip    rule del prio 30800 sport 5900-5920 lookup main 2>/dev/null || true
	ip -6 rule del prio 30801 lookup $TT_TABLE  2>/dev/null || true
	ip -6 rule del prio 30800 sport 1-1024 lookup main 2>/dev/null || true
	ip -6 rule del prio 30800 sport 5900-5920 lookup main 2>/dev/null || true
	# Flush all routes in table 880
	ip    route flush table $TT_TABLE 2>/dev/null || true
	ip -6 route flush table $TT_TABLE 2>/dev/null || true
}

proto_trusttunnel_setup() {
	local config="$1"  # UCI interface name, e.g. "tun0"

	local config_file mtu
	config_load network
	config_get config_file "$config" "config_file" \
		"/opt/trusttunnel_client/trusttunnel_client.toml"
	config_get mtu "$config" "mtu" "1280"

	# Sanity checks
	if [ ! -x "$TT_CLIENT" ]; then
		logger -t "trusttunnel" \
			"error: $TT_CLIENT not found or not executable"
		proto_setup_failed "$config"
		exit 1
	fi

	if [ ! -f "$config_file" ]; then
		logger -t "trusttunnel" \
			"error: config file $config_file not found"
		proto_setup_failed "$config"
		exit 1
	fi

	# Kill any stale instances
	mkdir -p "$TT_RUN_DIR"
	local old_pid
	old_pid=$(cat "$TT_RUN_DIR/${config}.pid" 2>/dev/null)
	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
		logger -t "trusttunnel" "killing stale instance (PID $old_pid)"
		kill "$old_pid" 2>/dev/null
		sleep 1
		kill -9 "$old_pid" 2>/dev/null || true
	fi

	# Remove stale interface and routing state
	ip link del dev "$config" 2>/dev/null || true
	tt_cleanup_routes

	# Wait for WAN to fully settle before starting the client.
	# Without this delay the client starts before routing is ready
	# and fails to connect (Number of connection attempts exceeded).
	sleep 5

	# Start the client — it creates tun0 and sets up routing itself
	logger -t "trusttunnel" "starting client for interface $config"
	</dev/null "$TT_CLIENT" -c "$config_file" \
		> "$TT_RUN_DIR/${config}.log" 2>&1 &
	local client_pid=$!
	echo "$client_pid" > "$TT_RUN_DIR/${config}.pid"

	# Wait for the interface to appear
	local elapsed=0
	local found=""
	while [ "$elapsed" -lt 30 ]; do
		if ip link show "$config" >/dev/null 2>&1; then
			found="$config"
			break
		fi
		if ip link show tun0 >/dev/null 2>&1; then
			found="tun0"
			break
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	if [ -z "$found" ]; then
		logger -t "trusttunnel" \
			"error: TUN interface did not appear within 30s"
		kill "$client_pid" 2>/dev/null
		rm -f "$TT_RUN_DIR/${config}.pid"
		proto_setup_failed "$config"
		exit 1
	fi

	# Rename tun0 → UCI interface name if needed.
	# Do NOT bring the interface down — binary holds an open TUN fd.
	# With included_routes the binary finishes setup_if() before we rename,
	# so all internal ip commands are already done.
	if [ "$found" != "$config" ]; then
		ip link set "$found" name "$config" 2>/dev/null || {
			logger -t "trusttunnel" \
				"error: failed to rename $found to $config"
			kill "$client_pid" 2>/dev/null
			rm -f "$TT_RUN_DIR/${config}.pid"
			proto_setup_failed "$config"
			exit 1
		}
		logger -t "trusttunnel" "renamed $found to $config"
	fi

	# Apply MTU — binary already brought interface up
	ip link set mtu "$mtu" dev "$config" 2>/dev/null || true

	# Read IP assigned by the binary and report to netifd
	local ipv4
	ipv4=$(ip -4 addr show dev "$config" \
		| awk '/inet /{print $2; exit}')
	local ipv6
	ipv6=$(ip -6 addr show dev "$config" \
		| awk '/inet6 /{print $2; exit}')

	proto_init_update "$config" 1

	if [ -n "$ipv4" ]; then
		proto_add_ipv4_address "${ipv4%%/*}" "${ipv4##*/}"
	fi
	if [ -n "$ipv6" ]; then
		proto_add_ipv6_address "${ipv6%%/*}" "${ipv6##*/}"
	fi

	proto_send_update "$config"

	logger -t "trusttunnel" \
		"interface $config is up (PID: $client_pid, addr: ${ipv4:-none})"
}

proto_trusttunnel_teardown() {
	local config="$1"

	local pid_file="$TT_RUN_DIR/${config}.pid"

	if [ -f "$pid_file" ]; then
		local pid
		pid=$(cat "$pid_file" 2>/dev/null)
		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
		fi
		rm -f "$pid_file"
	fi

	killall trusttunnel_client 2>/dev/null || true

	# Clean routing state BEFORE removing the interface,
	# so routes referencing it can be flushed properly
	tt_cleanup_routes

	ip link del dev "$config" 2>/dev/null || true

	logger -t "trusttunnel" "interface $config torn down"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol trusttunnel
}
