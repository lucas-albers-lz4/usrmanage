'use strict';

'require view';
'require rpc';
'require ui';

/* Keep in sync with openwrt-feed/luci-app-usrmanage/Makefile PKG_VERSION */
const APP_VERSION = '0.1.16';

const callHealth = rpc.declare({
	object: 'usrmanage',
	method: 'health',
	expect: { '': {
		ok: true,
		hostname: '',
		release: '',
		uptime_s: 0,
		load: [],
		wan: { up: false, ipv4: false, ipv6: false },
		lan: { up: false },
		wifi: { radios_up: 0, radios_total: 0, assoc_count: 0 },
		dhcp_lease_count: 0
	} }
});

function formatUptime(sec) {
	const s = Math.max(0, Math.floor(Number(sec) || 0));
	const d = Math.floor(s / 86400);
	const h = Math.floor((s % 86400) / 3600);
	const m = Math.floor((s % 3600) / 60);
	const parts = [];
	if (d > 0)
		parts.push(_('%d days').format(d));
	if (h > 0 || d > 0)
		parts.push(_('%d hours').format(h));
	parts.push(_('%d minutes').format(m));
	return parts.join(', ');
}

function formatLoad(load) {
	if (!Array.isArray(load) || load.length < 3)
		return '—';
	return load.slice(0, 3).map(function(n) {
		return Number(n).toFixed(2);
	}).join(', ');
}

function upDown(v) {
	return v ? _('Up') : _('Down');
}

function healthRow(label, value) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, String(value != null ? value : '—'))
	]);
}

function mountView(self, data) {
	const vp = document.getElementById('view');
	if (!vp)
		return;
	const node = self.render(data);
	const old = self.rootNode ||
		vp.querySelector('[data-testid^="usrmanage-health-"]');
	self.rootNode = node;
	if (old && old.parentNode)
		old.parentNode.replaceChild(node, old);
	else
		vp.appendChild(node);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callHealth();
	},

	render: function(data) {
		const self = this;
		const h = (data && typeof data === 'object') ? data : { ok: false };

		if (h.ok === false) {
			const err = (h.error != null) ? String(h.error) : 'health_unavailable';
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, _('Device health')),
				E('div', { 'class': 'alert-message error', 'data-testid': 'usrmanage-health-error' }, [
					E('p', {}, _('Health data is unavailable (%s).').format(err))
				]),
				E('div', { 'class': 'cbi-section-node' }, [
					E('button', {
						'class': 'btn cbi-button',
						'data-testid': 'usrmanage-health-refresh',
						'click': ui.createHandlerFn(self, 'handleRefresh')
					}, _('Refresh'))
				])
			]);
		}

		const wan = (h.wan && typeof h.wan === 'object') ? h.wan : {};
		const lan = (h.lan && typeof h.lan === 'object') ? h.lan : {};
		const wifi = (h.wifi && typeof h.wifi === 'object') ? h.wifi : {};

		return E('div', { 'class': 'cbi-map', 'data-testid': 'usrmanage-health-map' }, [
			E('h2', {}, _('Device health')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Redacted device status for observer logins. Wireless keys, user accounts, and configuration secrets are not shown here.')
			]),
			E('div', {
				'class': 'alert-message notice',
				'data-testid': 'usrmanage-health-readonly-banner'
			}, [
				E('p', {}, _('This LuCI login is for device health only, not account administration.'))
			]),
			E('div', { 'class': 'cbi-section' }, [
				healthRow(_('Hostname'), h.hostname || '—'),
				healthRow(_('OpenWrt release'), h.release || '—'),
				healthRow(_('Uptime'), formatUptime(h.uptime_s)),
				healthRow(_('Load (1 / 5 / 15 min)'), formatLoad(h.load)),
				healthRow(_('WAN link'), upDown(!!wan.up)),
				healthRow(_('WAN IPv4'), upDown(!!wan.ipv4)),
				healthRow(_('WAN IPv6'), upDown(!!wan.ipv6)),
				healthRow(_('LAN link'), upDown(!!lan.up)),
				healthRow(_('Wi-Fi radios up'), '%d / %d'.format(
					Number(wifi.radios_up) || 0,
					Number(wifi.radios_total) || 0
				)),
				healthRow(_('Wi-Fi associated stations'), String(Number(wifi.assoc_count) || 0)),
				healthRow(_('DHCP lease count'), String(Number(h.dhcp_lease_count) || 0))
			]),
			E('div', { 'class': 'cbi-section-node' }, [
				E('button', {
					'class': 'btn cbi-button',
					'data-testid': 'usrmanage-health-refresh',
					'click': ui.createHandlerFn(self, 'handleRefresh')
				}, _('Refresh'))
			]),
			E('div', {
				'class': 'cbi-value-description',
				'data-testid': 'usrmanage-health-build',
				'title': 'luci-app-usrmanage'
			}, 'v' + APP_VERSION)
		]);
	},

	handleRefresh: function(ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();
		const self = this;
		return this.load().then(function(data) {
			mountView(self, data);
		}).catch(function() {
			ui.addNotification(null, E('p', {}, _('Request failed')), 'danger');
		});
	}
});
