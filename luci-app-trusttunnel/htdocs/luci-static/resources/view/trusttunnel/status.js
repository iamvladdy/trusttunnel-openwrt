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

function stateLabel(state) {
	var labels = {
		'connected':    [ 'label-success',  _('Connected')    ],
		'connecting':   [ 'label-warning',  _('Connecting…')  ],
		'disconnected': [ 'label-danger',   _('Disconnected') ],
		'stopped':      [ 'label-default',  _('Stopped')      ],
		'error':        [ 'label-danger',   _('Error')        ],
		'unknown':      [ 'label-default',  _('Unknown')      ]
	};

	var l = labels[state] || labels['unknown'];
	return E('span', { 'class': 'label ' + l[0] }, [ l[1] ]);
}

function renderIface(name, info) {
	var rows = [
		[ _('Status'),      stateLabel(info.state)                                          ],
		[ _('Interface'),   E('code', [ name ])                                             ],
		[ _('TUN IPv4'),    info.tun_ip  ? E('code', [ info.tun_ip  ]) : E('em', _('—'))   ],
		[ _('TUN IPv6'),    info.tun_ip6 ? E('code', [ info.tun_ip6 ]) : E('em', _('—'))   ],
		[ _('Endpoint'),    info.endpoint    || E('em', _('—'))                             ],
		[ _('Endpoint IP'), info.endpoint_ip || E('em', _('—'))                             ],
		[ _('PID'),         info.pid         || E('em', _('—'))                             ],
		[ _('Config'),      info.config_file ? E('code', [ info.config_file ])
		                                     : E('em', _('—'))                              ],
	];

	if (info.last_error) {
		rows.push([ _('Last Error'), E('span', { 'style': 'color:red' }, [ info.last_error ]) ]);
	}

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', [ _('Interface "%h"').format(name) ]),
		E('table', { 'class': 'table cbi-section-table' },
			rows.map(function(row) {
				return E('tr', { 'class': 'tr cbi-rowstyle-1' }, [
					E('td', { 'class': 'td', 'style': 'width:30%;font-weight:bold' }, [ row[0] ]),
					E('td', { 'class': 'td' }, [ row[1] ])
				]);
			})
		)
	]);
}

return view.extend({
	render: function() {
		var container = E('div', {});

		poll.add(L.bind(function() {
			return callGetStatus().then(L.bind(function(data) {
				var nodes = [ E('h2', [ _('TrustTunnel Status') ]) ];

				var keys = Object.keys(data || {});

				if (keys.length === 0) {
					nodes.push(E('p', { 'class': 'center', 'style': 'margin-top:3em' }, [
						E('em', [ _('No TrustTunnel interfaces configured.') ])
					]));
				} else {
					for (var i = 0; i < keys.length; i++) {
						nodes.push(renderIface(keys[i], data[keys[i]]));
					}
				}

				dom.content(container, nodes);
			}, this));
		}, this), 5);

		return E('div', {}, [
			E('h2', [ _('TrustTunnel Status') ]),
			E('p', { 'class': 'center', 'style': 'margin-top:3em' }, [
				E('em', [ _('Loading…') ])
			]),
			container
		]);
	},

	handleReset: null,
	handleSave: null,
	handleSaveApply: null
});
