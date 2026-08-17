'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

var callGetStatus = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'getTrustTunnelStatus'
});

var callCertInfo = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'getCertInfo',
	params: [ 'iface' ]
});

var callLatency = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'getLatency',
	params: [ 'iface' ]
});

var callSetState = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'setInterfaceState',
	params: [ 'iface', 'action' ]
});

var callClientLog = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'getClientLog',
	params: [ 'iface', 'lines' ]
});

/* Results of on-demand probes and previous counter samples, kept outside the
   render path so the 5s poll does not discard them. */
var probes = {};   /* iface -> { cert, latency, log, busy } */
var samples = {};  /* iface -> { t, rx, tx } */

var CSS = '' +
'.tt-wrap{display:flex;flex-direction:column;gap:1rem}' +
'.tt-card{border:1px solid rgba(127,127,127,.22);border-radius:8px;' +
	'background:rgba(127,127,127,.07);padding:1rem}' +
'.tt-head{display:flex;flex-wrap:wrap;align-items:center;gap:.75rem;' +
	'justify-content:space-between;margin-bottom:.25rem}' +
'.tt-title{display:flex;align-items:center;gap:.6rem;font-size:1.1rem;font-weight:600}' +
'.tt-badge{display:inline-block;padding:.16rem .6rem;border-radius:999px;' +
	'font-size:.75rem;font-weight:700;letter-spacing:.04em;color:#fff;white-space:nowrap}' +
'.tt-b-ok{background:#16a34a}.tt-b-warn{background:#d97706}' +
'.tt-b-err{background:#dc2626}.tt-b-idle{background:#6b7280}' +
'.tt-actions{display:flex;gap:.4rem;flex-wrap:wrap}' +
'.tt-grid{display:grid;gap:.6rem;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));' +
	'margin-top:.9rem}' +
'.tt-tile{border:1px solid rgba(127,127,127,.18);border-radius:6px;padding:.55rem .7rem;' +
	'background:rgba(127,127,127,.06)}' +
'.tt-tile-l{font-size:.7rem;text-transform:uppercase;letter-spacing:.05em;opacity:.65}' +
'.tt-tile-v{font-size:1.15rem;font-weight:600;margin-top:.15rem;' +
	'font-variant-numeric:tabular-nums;word-break:break-word}' +
'.tt-tile-s{font-size:.72rem;opacity:.6;margin-top:.1rem}' +
'.tt-rows{width:100%;margin-top:.9rem;border-collapse:collapse}' +
'.tt-rows td{padding:.38rem .5rem;border-top:1px solid rgba(127,127,127,.16);' +
	'vertical-align:top;font-size:.86rem}' +
'.tt-rows tr:first-child td{border-top:none}' +
'.tt-rows td:first-child{width:32%;opacity:.7;white-space:nowrap}' +
'.tt-mono{font-family:ui-monospace,monospace;font-size:.84rem;word-break:break-all}' +
'.tt-note{margin-top:.7rem;padding:.55rem .7rem;border-radius:6px;font-size:.84rem;' +
	'border-left:3px solid}' +
'.tt-n-err{border-color:#dc2626;background:rgba(220,38,38,.1)}' +
'.tt-n-warn{border-color:#d97706;background:rgba(217,119,6,.1)}' +
'.tt-n-info{border-color:#3b82f6;background:rgba(59,130,246,.1)}' +
'.tt-log{margin-top:.7rem;max-height:22rem;overflow:auto;padding:.6rem;border-radius:6px;' +
	'background:rgba(0,0,0,.28);border:1px solid rgba(127,127,127,.2)}' +
'.tt-log pre{margin:0;font-size:.76rem;line-height:1.45;white-space:pre-wrap;word-break:break-all}' +
'.tt-dim{opacity:.55}';

/* ---------- formatting helpers ---------- */

function fmtBytes(n) {
	n = Number(n) || 0;
	var u = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + ' ' + u[i];
}

function fmtRate(bps) {
	if (bps == null) return null;
	var n = bps * 8, u = [ 'bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s' ], i = 0;
	while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
	return (i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + u[i];
}

function fmtDuration(s) {
	s = Math.max(0, Math.floor(Number(s) || 0));
	var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
	    m = Math.floor(s % 3600 / 60), sec = s % 60;
	if (d) return d + 'd ' + h + 'h ' + m + 'm';
	if (h) return h + 'h ' + m + 'm';
	if (m) return m + 'm ' + sec + 's';
	return sec + 's';
}

function fmtNum(n) {
	return (Number(n) || 0).toLocaleString();
}

/* OpenSSL prints "May  6 19:09:50 2026 GMT" — collapse the padding so
   Date.parse accepts it. Returns days remaining, or null if unparsable. */
function certDaysLeft(notAfter) {
	if (!notAfter) return null;
	var t = Date.parse(String(notAfter).replace(/\s+/g, ' '));
	if (isNaN(t)) return null;
	return Math.floor((t - Date.now()) / 86400000);
}

/* ---------- state presentation ---------- */

function stateInfo(state) {
	var map = {
		connected:    [ 'tt-b-ok',   _('Connected')    ],
		connecting:   [ 'tt-b-warn', _('Connecting…')  ],
		disconnected: [ 'tt-b-err',  _('Disconnected') ],
		stopped:      [ 'tt-b-idle', _('Stopped')      ],
		error:        [ 'tt-b-err',  _('Error')        ],
		unknown:      [ 'tt-b-idle', _('Unknown')      ]
	};
	return map[state] || map.unknown;
}

function errorHint(err) {
	if (!err)
		return null;

	if (/OPENSSL_internal|invalid library|certificate verify failed|Handshake failed/.test(err))
		return _('The server certificate could not be verified. Check its expiry first (button above) — a wizard-issued Let\'s Encrypt certificate is not renewed automatically and dies after 90 days. Then check that ca-bundle is installed, that [endpoint] hostname matches the certificate, and that the router clock is correct.');

	if (/Authorization failed|401|Unauthorized/.test(err))
		return _('The endpoint rejected the credentials. Check username and password in the client config.');

	if (/Number of connection attempts exceeded/.test(err))
		return _('The endpoint could not be reached. Check the address, port and that the server firewall allows the port.');

	if (/Unable to setup routes/.test(err))
		return _('Route setup failed. With included_routes = [] the client should not touch routes at all — check that section of the config.');

	return null;
}

/* ---------- building blocks ---------- */

function tile(label, value, sub) {
	var kids = [
		E('div', { 'class': 'tt-tile-l' }, [ label ]),
		E('div', { 'class': 'tt-tile-v' }, [ value ])
	];
	if (sub)
		kids.push(E('div', { 'class': 'tt-tile-s' }, [ sub ]));
	return E('div', { 'class': 'tt-tile' }, kids);
}

function rows(list) {
	return E('table', { 'class': 'tt-rows' }, list.filter(Boolean).map(function(r) {
		return E('tr', {}, [
			E('td', {}, [ r[0] ]),
			E('td', {}, [ r[1] ])
		]);
	}));
}

function mono(text) {
	return E('span', { 'class': 'tt-mono' }, [ text ]);
}

function dash() {
	return E('em', { 'class': 'tt-dim' }, [ '—' ]);
}

/* ---------- actions ---------- */

/* Replaced in render() with a function that redraws immediately, so a button
   press shows its result at once instead of waiting up to 5s for the poll. */
var refreshNow = function() { return Promise.resolve(); };

function withBusy(iface, fn) {
	probes[iface] = probes[iface] || {};
	return fn().catch(function(e) {
		ui.addNotification(null, E('p', [ '' + e ]), 'danger');
	}).then(function() {
		return refreshNow();
	});
}

function handleCert(iface, ev) {
	ev.target.blur();
	return withBusy(iface, function() {
		return callCertInfo(iface).then(function(res) {
			probes[iface].cert = res || {};
		});
	});
}

function handleLatency(iface, ev) {
	ev.target.blur();
	return withBusy(iface, function() {
		return callLatency(iface).then(function(res) {
			probes[iface].latency = res || {};
		});
	});
}

function handleLog(iface, ev) {
	ev.target.blur();
	probes[iface] = probes[iface] || {};
	if (probes[iface].log) {
		probes[iface].log = null;
		// Redraw at once — without this the panel stays visible until the
		// next poll tick, which reads as a dead button.
		return refreshNow();
	}
	return withBusy(iface, function() {
		return callClientLog(iface, 50).then(function(res) {
			probes[iface].log = res || {};
		});
	});
}

function handleState(iface, action, ev) {
	ev.target.blur();
	var labels = { up: _('Starting…'), down: _('Stopping…'), restart: _('Restarting…') };
	ui.addNotification(null, E('p', [ labels[action] + ' ' + iface ]), 'info');
	return withBusy(iface, function() {
		return callSetState(iface, action).then(function(res) {
			if (res && res.success === false)
				ui.addNotification(null, E('p', [ res.error || _('Action failed') ]), 'danger');
		});
	});
}

function btn(label, style, handler) {
	return E('button', {
		'class': 'cbi-button cbi-button-' + style,
		'click': ui.createHandlerFn({ render: function() {} }, handler)
	}, [ label ]);
}

/* ---------- cert / latency panels ---------- */

function certPanel(info) {
	if (!info)
		return null;

	if (info.error)
		return E('div', { 'class': 'tt-note tt-n-warn' }, [ info.error ]);

	var days = certDaysLeft(info.not_after);
	var cls = 'tt-n-info', msg;

	if (days === null)
		msg = _('Expiry date could not be parsed: ') + (info.not_after || '?');
	else if (days < 0) {
		cls = 'tt-n-err';
		msg = _('Certificate EXPIRED %d days ago (%s). Renew it on the server — the tunnel cannot connect until you do.')
			.format(-days, info.not_after);
	}
	else if (days <= 14) {
		cls = 'tt-n-warn';
		msg = _('Certificate expires in %d days (%s). Check that automatic renewal works: certbot renew --dry-run')
			.format(days, info.not_after);
	}
	else
		msg = _('Certificate valid for %d more days (%s).').format(days, info.not_after);

	return E('div', { 'class': 'tt-note ' + cls }, [
		E('div', {}, [ msg ]),
		info.subject ? E('div', { 'class': 'tt-mono tt-dim', 'style': 'margin-top:.3rem' },
			[ info.subject ]) : '',
		info.issuer ? E('div', { 'class': 'tt-mono tt-dim' }, [ info.issuer ]) : ''
	]);
}

function latencyTiles(lat) {
	if (!lat || lat.error)
		return [];

	var out = [];

	function one(label, p, note) {
		if (!p) return;
		if (!p.ok) {
			out.push(tile(label,
				E('span', { 'class': 'tt-dim', 'style': 'font-size:.95rem' },
					[ _('failed') ]),
				p.reason || note));
			return;
		}
		out.push(tile(label, p.avg + ' ms',
			_('min %s / max %s · loss %d%%').format(p.min, p.max, p.loss)));
	}

	one(_('Endpoint RTT'), lat.endpoint, _('direct to server'));
	one(_('Tunnel RTT'), lat.tunnel, _('ICMP to 1.1.1.1 bound to the tun device'));

	return out;
}

/* ---------- interface card ---------- */

function renderIface(name, info) {
	var st = stateInfo(info.state);
	var p = probes[name] || {};

	/* throughput from the delta against the previous poll */
	var now = Date.now() / 1000, rxRate = null, txRate = null;
	var prev = samples[name];
	if (prev && now > prev.t) {
		var dt = now - prev.t;
		if (info.rx_bytes >= prev.rx && info.tx_bytes >= prev.tx) {
			rxRate = (info.rx_bytes - prev.rx) / dt;
			txRate = (info.tx_bytes - prev.tx) / dt;
		}
	}
	samples[name] = { t: now, rx: info.rx_bytes, tx: info.tx_bytes };

	var tiles = [
		tile(_('Download'), fmtBytes(info.rx_bytes),
			rxRate !== null ? fmtRate(rxRate) : _('%s packets').format(fmtNum(info.rx_packets))),
		tile(_('Upload'), fmtBytes(info.tx_bytes),
			txRate !== null ? fmtRate(txRate) : _('%s packets').format(fmtNum(info.tx_packets))),
		tile(_('Uptime'), info.running ? fmtDuration(info.uptime) : '—',
			info.pid ? _('PID %s').format(info.pid) : null),
		/* TUN devices report operstate "unknown", which is noise — only show
		   the value when it actually says something. */
		tile(_('MTU'), info.mtu ? String(info.mtu) : '—',
			(info.oper_state && info.oper_state != 'unknown') ? info.oper_state : null)
	];

	if (info.rx_errors || info.tx_errors)
		tiles.push(tile(_('Errors'), fmtNum(info.rx_errors + info.tx_errors),
			_('rx %s / tx %s').format(fmtNum(info.rx_errors), fmtNum(info.tx_errors))));

	tiles = tiles.concat(latencyTiles(p.latency));

	var addrList = (info.addresses && info.addresses.length)
		? mono(info.addresses.join(', ')) : dash();

	var detail = rows([
		[ _('TUN IPv4'),   info.tun_ip  ? mono(info.tun_ip)  : dash() ],
		[ _('TUN IPv6'),   info.tun_ip6 ? mono(info.tun_ip6) : dash() ],
		[ _('TLS hostname'), info.hostname ? mono(info.hostname) : dash() ],
		info.custom_sni ? [ _('Custom SNI'), mono(info.custom_sni) ] : null,
		[ _('Endpoint addresses'), addrList ],
		info.endpoint_ip ? [ _('Connected to'), mono(info.endpoint_ip) ] : null,
		[ _('Mode'), E('span', {}, [
			(info.vpn_mode || 'general') + ' · ' + (info.upstream || 'http2') +
			(info.killswitch ? ' · ' + _('killswitch on') : '')
		]) ],
		[ _('Config'), info.config_file ? mono(info.config_file) : dash() ]
	]);

	var notes = [];

	if (info.skip_verify)
		notes.push(E('div', { 'class': 'tt-note tt-n-err' }, [
			_('skip_verification = true — the server certificate is NOT checked and traffic can be intercepted. Set it back to false once the certificate is valid.')
		]));

	if (info.killswitch)
		notes.push(E('div', { 'class': 'tt-note tt-n-warn' }, [
			_('killswitch_enabled = true — if the tunnel drops, traffic is blocked. On a router where only selected domains are routed through the tunnel, this usually should be false.')
		]));

	var certNote = certPanel(p.cert);
	if (certNote)
		notes.push(certNote);

	/* A failed tunnel ping is expected in the podkop setup: with
	   included_routes = [] there is no route for arbitrary destinations via
	   the tun device, so binding to it cannot deliver the packet. Say so
	   instead of leaving a bare failure on screen. */
	if (p.latency && p.latency.tunnel && !p.latency.tunnel.ok)
		notes.push(E('div', { 'class': 'tt-note tt-n-info' }, [
			_('Tunnel RTT failing is normal with included_routes = [] — routing is podkop\'s job, so there is no route to 1.1.1.1 through the tun device and ICMP bound to it cannot be delivered. It does not mean the tunnel is broken: verify with a destination podkop actually routes, e.g. curl --interface %s https://ifconfig.me').format(name)
		]));

	if (info.last_error) {
		notes.push(E('div', { 'class': 'tt-note tt-n-err' }, [
			E('div', { 'class': 'tt-mono' }, [ info.last_error ])
		]));
		var hint = errorHint(info.last_error);
		if (hint)
			notes.push(E('div', { 'class': 'tt-note tt-n-info' }, [ hint ]));
	}

	var logPanel = null;
	if (p.log) {
		logPanel = E('div', { 'class': 'tt-log' }, [
			E('pre', {}, [ p.log.log || _('(log is empty)') ])
		]);
	}

	return E('div', { 'class': 'tt-card' }, [
		E('div', { 'class': 'tt-head' }, [
			E('div', { 'class': 'tt-title' }, [
				E('span', { 'class': 'tt-badge ' + st[0] }, [ st[1] ]),
				E('span', {}, [ name ]),
				info.endpoint ? E('span', { 'class': 'tt-dim',
					'style': 'font-weight:400;font-size:.9rem' },
					[ '→ ' + info.endpoint ]) : ''
			]),
			E('div', { 'class': 'tt-actions' }, [
				btn(_('Check certificate'), 'neutral', function(ev) { return handleCert(name, ev); }),
				btn(_('Measure latency'), 'neutral', function(ev) { return handleLatency(name, ev); }),
				btn(p.log ? _('Hide log') : _('Show log'), 'neutral',
					function(ev) { return handleLog(name, ev); }),
				btn(_('Restart'), 'apply', function(ev) { return handleState(name, 'restart', ev); }),
				info.running
					? btn(_('Stop'), 'reset', function(ev) { return handleState(name, 'down', ev); })
					: btn(_('Start'), 'save', function(ev) { return handleState(name, 'up', ev); })
			])
		]),
		E('div', { 'class': 'tt-grid' }, tiles),
		detail,
		E('div', {}, notes),
		logPanel || ''
	]);
}

function renderAll(data) {
	var keys = Object.keys(data || {}).sort();

	if (!keys.length)
		return [ E('div', { 'class': 'tt-card' }, [
			E('p', {}, [ E('em', [ _('No TrustTunnel interfaces configured.') ]) ]),
			E('p', { 'class': 'tt-dim' }, [
				_('Add one under Network → Interfaces → Add, with protocol "TrustTunnel VPN".')
			])
		]) ];

	return keys.map(function(k) { return renderIface(k, data[k]); });
}

return view.extend({
	load: function() {
		return callGetStatus();
	},

	render: function(data) {
		var container = E('div', { 'class': 'tt-wrap' }, renderAll(data));

		refreshNow = function() {
			return callGetStatus().then(function(d) {
				dom.content(container, renderAll(d));
			});
		};

		poll.add(refreshNow, 5);

		return E('div', {}, [
			E('style', { 'type': 'text/css' }, [ CSS ]),
			E('h2', [ _('TrustTunnel Status') ]),
			container
		]);
	},

	handleReset: null,
	handleSave: null,
	handleSaveApply: null
});
