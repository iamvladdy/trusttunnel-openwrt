'use strict';
'require form';
'require network';

return network.registerProtocol('trusttunnel', {
	getI18n: function() {
		return _('TrustTunnel VPN');
	},

	getIfname: function() {
		return this._ubus('l3_device') || this.sid;
	},

	getPackageName: function() {
		return 'trusttunnel';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions: function(s) {
		var o;

		o = s.taboption('general', form.Value, 'config_file',
			_('Config File'),
			_('Path to the TrustTunnel client TOML configuration file.'));
		o.placeholder = '/opt/trusttunnel_client/trusttunnel_client.toml';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'mtu',
			_('MTU'),
			_('Optional. Maximum Transmission Unit of the tunnel interface.'));
		o.datatype = 'range(576,9000)';
		o.placeholder = '1280';
		o.optional = true;
	}
});
