'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';

const callList = rpc.declare({
	object: 'usrmanage',
	method: 'list',
	params: [ 'all' ],
	expect: { users: [] }
});

const callAudit = rpc.declare({
	object: 'usrmanage',
	method: 'audit',
	params: [ 'last' ],
	expect: { events: [] }
});

const callDoctor = rpc.declare({
	object: 'usrmanage',
	method: 'doctor',
	expect: { ok: false, checks: [], incomplete: [] }
});

const callAdd = rpc.declare({
	object: 'usrmanage',
	method: 'add',
	params: [ 'name', 'role', 'password' ]
});

const callDel = rpc.declare({
	object: 'usrmanage',
	method: 'del',
	params: [ 'name', 'purge_home' ]
});

const callSetRole = rpc.declare({
	object: 'usrmanage',
	method: 'set_role',
	params: [ 'name', 'role' ]
});

const callPasswd = rpc.declare({
	object: 'usrmanage',
	method: 'passwd',
	params: [ 'name', 'password' ]
});

function hasWriteAcl() {
	/* Server ACL is authoritative; UI only hides controls when we can detect write. */
	try {
		if (typeof L.hasACLScope === 'function')
			return L.hasACLScope('luci-app-usrmanage', 'write');
	} catch (e) { /* ignore */ }
	try {
		const acls = L.env && L.env.acls;
		if (acls && acls['luci-app-usrmanage'] && acls['luci-app-usrmanage'].write)
			return true;
		if (acls && acls['luci-app-usrmanage'] && !acls['luci-app-usrmanage'].write)
			return false;
	} catch (e2) { /* ignore */ }
	/* Unknown ACL shape: show controls; write RPC still denied without write ACL. */
	return true;
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			callList(false),
			callAudit(50),
			callDoctor()
		]);
	},

	render: function(data) {
		const users = (data[0] && data[0].users) ? data[0].users : [];
		const events = (data[1] && data[1].events) ? data[1].events : [];
		const doctor = data[2] || { ok: true, checks: [], incomplete: [] };
		const manage = hasWriteAcl();
		const self = this;

		const doctorBanner = [];
		if (!doctor.ok) {
			doctorBanner.push(E('div', { 'class': 'alert-message warning' }, [
				_('User management self-check reported problems. Mutators may be fail-closed until sudo/wheel/registry are healthy.'),
				E('pre', {}, JSON.stringify(doctor, null, 2))
			]));
		}

		const rows = users.map(function(u) {
			const actions = [];
			if (manage && u.managed) {
				actions.push(E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleSetRole', u.name, u.role)
				}, _('Set role')));
				actions.push(' ');
				actions.push(E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handlePasswd', u.name)
				}, _('Password')));
				actions.push(' ');
				actions.push(E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(self, 'handleRemove', u.name)
				}, _('Remove')));
			}
			else if (!manage) {
				actions.push(E('em', {}, _('read only')));
			}
			else {
				actions.push(E('em', {}, _('unmanaged')));
			}

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, u.name || ''),
				E('td', { 'class': 'td' }, String(u.uid != null ? u.uid : '')),
				E('td', { 'class': 'td' }, u.role || ''),
				E('td', { 'class': 'td' }, u.shell || ''),
				E('td', { 'class': 'td' }, u.managed ? _('yes') : _('no')),
				E('td', { 'class': 'td' }, actions)
			]);
		});

		const eventNodes = events.map(function(ev) {
			const line = [
				ev.ts || '',
				ev.action || '',
				'user=' + (ev.user || ''),
				ev.role ? ('role=' + ev.role) : '',
				'actor=' + (ev.actor || ''),
				'src=' + (ev.src || ''),
				'result=' + (ev.result || ''),
				ev.reason ? ('reason=' + ev.reason) : ''
			].filter(Boolean).join(' ');
			return E('div', { 'class': 'cbi-value-description' }, line);
		});

		const toolbar = [];
		if (manage) {
			toolbar.push(E('button', {
				'class': 'btn cbi-button cbi-button-add',
				'click': ui.createHandlerFn(self, 'handleAdd')
			}, _('Add user')));
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('User Management')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Manage local UNIX/SSH accounts on this device. LuCI web logins are configured separately (Administration / ACL).'),
				E('br'),
				_('Admin role grants wheel + sudo (full root after password). Audit log is operational (local + syslog), not compliance-grade evidence.')
			]),
			doctorBanner,
			E('div', { 'class': 'cbi-section-node' }, toolbar),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Username')),
					E('th', { 'class': 'th' }, _('UID')),
					E('th', { 'class': 'th' }, _('Role')),
					E('th', { 'class': 'th' }, _('Shell')),
					E('th', { 'class': 'th' }, _('Managed')),
					E('th', { 'class': 'th' }, _('Actions'))
				])
			].concat(rows.length ? rows : [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'colspan': 6 }, _('No managed users yet.'))
				])
			])),
			E('h3', {}, _('Audit log')),
			E('div', { 'class': 'cbi-section-node' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleRefresh')
				}, _('Refresh'))
			]),
			E('div', { 'class': 'cbi-section' }, eventNodes.length ? eventNodes : [
				E('em', {}, _('No audit events yet.'))
			])
		]);
	},

	handleRefresh: function(ev) {
		return this.renderContents();
	},

	handleAdd: function(ev) {
		const self = this;
		const nameInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('username') });
		const roleSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'readonly' }, _('readonly')),
			E('option', { 'value': 'admin' }, _('admin'))
		]);
		const passInput = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'autocomplete': 'new-password' });
		const pass2Input = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'autocomplete': 'new-password' });

		ui.showModal(_('Add user'), [
			E('div', { 'class': 'cbi-map' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Username')),
					E('div', { 'class': 'cbi-value-field' }, nameInput)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Role')),
					E('div', { 'class': 'cbi-value-field' }, roleSelect)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Password')),
					E('div', { 'class': 'cbi-value-field' }, passInput)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Confirm')),
					E('div', { 'class': 'cbi-value-field' }, pass2Input)
				])
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn',
					'click': ui.hideModal
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': function() {
						const name = nameInput.value.trim();
						const role = roleSelect.value;
						const p1 = passInput.value;
						const p2 = pass2Input.value;
						if (!name) {
							ui.addNotification(null, E('p', {}, _('Username required')), 'danger');
							return;
						}
						if (p1 !== p2) {
							ui.addNotification(null, E('p', {}, _('Passwords do not match')), 'danger');
							return;
						}
						if (p1.length < 8 || p1 === name) {
							ui.addNotification(null, E('p', {}, _('Password must be at least 8 characters and not equal to the username')), 'danger');
							return;
						}
						return callAdd(name, role, p1).then(function(res) {
							passInput.value = '';
							pass2Input.value = '';
							ui.hideModal();
							if (res && res.ok === false) {
								ui.addNotification(null, E('p', {}, _('Failed: %s').format(res.error || 'error')), 'danger');
								return;
							}
							ui.addNotification(null, E('p', {}, _('User added')), 'info');
							return self.renderContents();
						}).catch(function(err) {
							ui.addNotification(null, E('p', {}, _('Request failed')), 'danger');
						});
					}
				}, _('Add'))
			])
		]);
	},

	handleSetRole: function(name, current, ev) {
		const self = this;
		const roleSelect = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'readonly', 'selected': current === 'readonly' ? 'selected' : null }, _('readonly')),
			E('option', { 'value': 'admin', 'selected': current === 'admin' ? 'selected' : null }, _('admin'))
		]);

		ui.showModal(_('Set role: %s').format(name), [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Role')),
				E('div', { 'class': 'cbi-value-field' }, roleSelect)
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': function() {
						return callSetRole(name, roleSelect.value).then(function(res) {
							ui.hideModal();
							if (res && res.ok === false) {
								ui.addNotification(null, E('p', {}, _('Failed: %s').format(res.error || 'error')), 'danger');
								return;
							}
							return self.renderContents();
						});
					}
				}, _('Apply'))
			])
		]);
	},

	handlePasswd: function(name, ev) {
		const self = this;
		const passInput = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'autocomplete': 'new-password' });
		const pass2Input = E('input', { 'type': 'password', 'class': 'cbi-input-text', 'autocomplete': 'new-password' });

		ui.showModal(_('Change password: %s').format(name), [
			E('p', {}, _('Use HTTPS in hardened deployments. The password is not written to the audit log.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Password')),
				E('div', { 'class': 'cbi-value-field' }, passInput)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Confirm')),
				E('div', { 'class': 'cbi-value-field' }, pass2Input)
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'click': function() {
						const p1 = passInput.value;
						const p2 = pass2Input.value;
						if (p1 !== p2) {
							ui.addNotification(null, E('p', {}, _('Passwords do not match')), 'danger');
							return;
						}
						if (p1.length < 8 || p1 === name) {
							ui.addNotification(null, E('p', {}, _('Password policy failed')), 'danger');
							return;
						}
						return callPasswd(name, p1).then(function(res) {
							passInput.value = '';
							pass2Input.value = '';
							ui.hideModal();
							if (res && res.ok === false) {
								ui.addNotification(null, E('p', {}, _('Failed: %s').format(res.error || 'error')), 'danger');
								return;
							}
							ui.addNotification(null, E('p', {}, _('Password updated')), 'info');
							return self.renderContents();
						});
					}
				}, _('Change'))
			])
		]);
	},

	handleRemove: function(name, ev) {
		const self = this;
		const purge = E('input', { 'type': 'checkbox' });

		ui.showModal(_('Remove user: %s').format(name), [
			E('p', {}, _('Locks the account, terminates sessions, then deletes the account. Home is kept unless purge is selected.')),
			E('label', {}, [ purge, ' ', _('Purge home directory') ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': function() {
						return callDel(name, purge.checked).then(function(res) {
							ui.hideModal();
							if (res && res.ok === false) {
								ui.addNotification(null, E('p', {}, _('Failed: %s').format(res.error || 'error')), 'danger');
								return;
							}
							ui.addNotification(null, E('p', {}, _('User removed')), 'info');
							return self.renderContents();
						});
					}
				}, _('Remove'))
			])
		]);
	}
});
