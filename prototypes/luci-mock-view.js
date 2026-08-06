'use strict';
/*
 * Prototype / mock LuCI view for System → User Management.
 * Renders fixture JSON only — no ubus. Toggle view vs manage with ?mode=view|manage
 * (for design review; production view is view/system/usrmanage.js).
 */
'require view';

const FIXTURE_USERS = {
	users: [
		{ name: 'audit', uid: 1001, role: 'readonly', shell: '/bin/ash', managed: true, locked: false },
		{ name: 'ops', uid: 1002, role: 'admin', shell: '/bin/ash', managed: true, locked: false }
	]
};

const FIXTURE_EVENTS = {
	events: [
		{ ts: '2026-08-05T23:16:10Z', action: 'grant', user: 'audit', role: 'readonly', actor: 'jdoe', src: 'luci', result: 'ok' },
		{ ts: '2026-08-05T23:41:12Z', action: 'remove', user: 'audit', role: 'readonly', actor: 'jdoe', src: 'luci', result: 'ok' }
	]
};

function canManage() {
	try {
		return (location.search || '').indexOf('mode=view') < 0;
	} catch (e) {
		return true;
	}
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	render: function() {
		const manage = canManage();
		const rows = FIXTURE_USERS.users.map(function(u) {
			const actions = manage
				? E('span', {}, [
					E('button', { 'class': 'btn cbi-button', 'disabled': true }, _('Set role')),
					' ',
					E('button', { 'class': 'btn cbi-button', 'disabled': true }, _('Password')),
					' ',
					E('button', { 'class': 'btn cbi-button', 'disabled': true }, _('Remove'))
				])
				: E('em', {}, _('read only'));

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, u.name),
				E('td', { 'class': 'td' }, String(u.uid)),
				E('td', { 'class': 'td' }, u.role),
				E('td', { 'class': 'td' }, u.shell),
				E('td', { 'class': 'td' }, u.managed ? _('yes') : _('no')),
				E('td', { 'class': 'td' }, actions)
			]);
		});

		const eventRows = FIXTURE_EVENTS.events.map(function(ev) {
			const line = ev.ts + ' ' + ev.action + ' user=' + ev.user +
				' role=' + (ev.role || '') + ' actor=' + ev.actor +
				' src=' + ev.src + ' result=' + ev.result;
			return E('div', { 'class': 'cbi-value-description' }, line);
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('User Management')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('UNIX/SSH accounts on this device. LuCI web logins are configured separately.'),
				manage ? '' : E('p', {}, E('strong', {}, _('View-only mode (prototype ?mode=view).')))
			]),
			manage ? E('div', {}, E('button', { 'class': 'btn cbi-button cbi-button-add', 'disabled': true }, _('Add user'))) : E('div'),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Username')),
					E('th', { 'class': 'th' }, _('UID')),
					E('th', { 'class': 'th' }, _('Role')),
					E('th', { 'class': 'th' }, _('Shell')),
					E('th', { 'class': 'th' }, _('Managed')),
					E('th', { 'class': 'th' }, _('Actions'))
				])
			].concat(rows)),
			E('h3', {}, _('Audit log')),
			E('div', {}, eventRows)
		]);
	}
});
