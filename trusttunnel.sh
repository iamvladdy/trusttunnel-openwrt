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

tt_log_tail() {
	local log_file="$1"
	[ -f "$log_file" ] || return 0
	tail -n 20 "$log_file" 2>/dev/null | while IFS= read -r line; do
		[ -n "$line" ] && logger -t "trusttunnel" "client: $line"
	done
}

# Locate the system CA bundle and point BoringSSL at it.
#
# The official client binary is statically linked against BoringSSL, which
# resolves the trust store from SSL_CERT_FILE / SSL_CERT_DIR, falling back to
# the compiled-in OPENSSLDIR (/etc/ssl/cert.pem). Vanilla OpenWRT ships no
# trust store at all; the ca-bundle package is what creates
# /etc/ssl/certs/ca-certificates.crt plus the /etc/ssl/cert.pem symlink.
tt_setup_trust_store() {
	local config_file="$1"

	# A pinned PEM or disabled verification means the store is not consulted.
	if grep -qE '^[[:space:]]*skip_verification[[:space:]]*=[[:space:]]*true' \
			"$config_file" 2>/dev/null; then
		return 0
	fi

	local cert_val
	cert_val=$(sed -n \
		's/^[[:space:]]*certificate[[:space:]]*=[[:space:]]*//p' \
		"$config_file" 2>/dev/null | head -n1)
	case "$cert_val" in
		''|'""'|"''"|'null') ;;   # empty → system store is used
		*) return 0 ;;            # pinned certificate present
	esac

	local ca_file=""
	local f
	for f in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do
		if [ -s "$f" ]; then
			ca_file="$f"
			break
		fi
	done

	if [ -z "$ca_file" ]; then
		logger -t "trusttunnel" \
			"error: no CA bundle found (/etc/ssl/cert.pem)."
		logger -t "trusttunnel" \
			"error: install it with 'apk add ca-bundle' (or 'opkg install ca-bundle'),"
		logger -t "trusttunnel" \
			"error: or pin the endpoint certificate in $config_file"
		return 1
	fi

	export SSL_CERT_FILE="$ca_file"
	[ -d /etc/ssl/certs ] && export SSL_CERT_DIR=/etc/ssl/certs
	return 0
}

# Certificate validity is checked against the system clock, so a router that
# has not yet synced NTP rejects every certificate as "not yet valid".
tt_wait_for_time() {
	local floor
	floor=$(date -r /lib/netifd/proto/trusttunnel.sh +%s 2>/dev/null)
	# Fall back to a static floor if the mtime is unavailable
	[ -n "$floor" ] || floor=1750000000

	local waited=0
	while [ "$(date +%s)" -lt "$floor" ] && [ "$waited" -lt 30 ]; do
		[ "$waited" -eq 0 ] && logger -t "trusttunnel" \
			"waiting for NTP time sync (clock is behind install time)"
		sleep 2
		waited=$((waited + 2))
	done

	if [ "$(date +%s)" -lt "$floor" ]; then
		logger -t "trusttunnel" \
			"warning: clock still unsynced — certificate validation may fail"
	fi
}

# The client needs working upstream routing before its first connect attempt.
# Without this it fails with "Number of connection attempts exceeded".
tt_wait_for_wan() {
	local waited=0
	while [ "$waited" -lt 30 ]; do
		if [ -n "$(ip route show default 2>/dev/null)" ]; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	logger -t "trusttunnel" "warning: no default route after 30s"
	return 1
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

	# Make sure TLS can actually succeed before spending 30s waiting on a
	# tunnel that will never come up.
	if ! tt_setup_trust_store "$config_file"; then
		proto_setup_failed "$config"
		exit 1
	fi

	# Wait for WAN to fully settle before starting the client, then let
	# routing quiesce. Without this the client starts before routing is
	# ready and fails to connect (Number of connection attempts exceeded).
	tt_wait_for_wan
	tt_wait_for_time
	sleep 3

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
		# Bail out as soon as the client dies instead of waiting the full
		# 30s — its own log holds the real reason (TLS, auth, config).
		if ! kill -0 "$client_pid" 2>/dev/null; then
			logger -t "trusttunnel" "error: client exited during startup"
			tt_log_tail "$TT_RUN_DIR/${config}.log"
			rm -f "$TT_RUN_DIR/${config}.pid"
			proto_setup_failed "$config"
			exit 1
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done

	if [ -z "$found" ]; then
		logger -t "trusttunnel" \
			"error: TUN interface did not appear within 30s"
		tt_log_tail "$TT_RUN_DIR/${config}.log"
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
