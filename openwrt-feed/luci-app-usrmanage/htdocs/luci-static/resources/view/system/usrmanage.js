'use strict';

'require view';
'require rpc';
'require ui';
'require dom';
'require poll';

/* Keep in sync with openwrt-feed/luci-app-usrmanage/Makefile PKG_VERSION */
const APP_VERSION = '0.1.11';

const callList = rpc.declare({
	object: 'usrmanage',
	method: 'list',
	params: [ 'all' ],
	expect: { '': { users: [] } }
});

const callAudit = rpc.declare({
	object: 'usrmanage',
	method: 'audit',
	params: [ 'last' ],
	expect: { '': { events: [] } }
});

const callDoctor = rpc.declare({
	object: 'usrmanage',
	method: 'doctor',
	expect: { '': { ok: true, checks: [], incomplete: [] } }
});

const callPolicyName = rpc.declare({
	object: 'usrmanage',
	method: 'policy',
	expect: { '': { preset: 'openwrt', label: 'OpenWrt' } }
});

const callGetPolicy = rpc.declare({
	object: 'usrmanage',
	method: 'get_policy',
	expect: { '': {
		preset: 'openwrt',
		label: 'OpenWrt',
		min_length: 8,
		reject_username: true,
		require_lower: false,
		require_upper: false,
		require_digit: false,
		require_special: false
	} }
});

const callSetPolicy = rpc.declare({
	object: 'usrmanage',
	method: 'set_policy',
	params: [
		'preset', 'min_length', 'reject_username',
		'require_lower', 'require_upper', 'require_digit', 'require_special'
	],
	expect: { '': { ok: true } }
});

const callAdd = rpc.declare({
	object: 'usrmanage',
	method: 'add',
	params: [ 'name', 'role', 'password', 'luci_login' ],
	expect: { '': { ok: true } }
});

const callDel = rpc.declare({
	object: 'usrmanage',
	method: 'del',
	params: [ 'name', 'purge_home' ],
	expect: { '': { ok: true } }
});

const callSetRole = rpc.declare({
	object: 'usrmanage',
	method: 'set_role',
	params: [ 'name', 'role' ],
	expect: { '': { ok: true } }
});

const callSetLuciLogin = rpc.declare({
	object: 'usrmanage',
	method: 'set_luci_login',
	params: [ 'name', 'mode' ],
	expect: { '': { ok: true } }
});

const callPasswd = rpc.declare({
	object: 'usrmanage',
	method: 'passwd',
	params: [ 'name', 'password' ],
	expect: { '': { ok: true } }
});

const PRESET_VALUES = {
	openwrt: {
		preset: 'openwrt', label: 'OpenWrt', min_length: 8,
		reject_username: true, require_lower: false, require_upper: false,
		require_digit: false, require_special: false
	},
	standard: {
		preset: 'standard', label: 'Standard', min_length: 10,
		reject_username: true, require_lower: true, require_upper: true,
		require_digit: true, require_special: false
	},
	strict: {
		preset: 'strict', label: 'Strict', min_length: 12,
		reject_username: true, require_lower: true, require_upper: true,
		require_digit: true, require_special: true
	}
};

function buildReadonlyLuciBanner() {
	return E('div', {
		'class': 'alert-message notice',
		'data-testid': 'usrmanage-readonly-luci-banner'
	}, [
		E('p', {}, _('Readonly LuCI is diagnostic scope: Status (Overview, Routing, Realtime Graphs), Network (Interfaces, Diagnostics), Device health, and view-only User Management. No configuration writes or Full LuCI menus.'))
	]);
}

function buildAdminLuciBanner() {
	return E('div', {
		'class': 'alert-message warning',
		'data-testid': 'usrmanage-admin-luci-banner'
	}, [
		E('p', {}, _('Admin LuCI is Full LuCI (all menus), including configuration and wireless keys/backups. Prefer HTTPS and a management network.'))
	]);
}

function wireLuciRoleExtras(roleSelect, luciCheck, readonlyBanner, adminBanner) {
	const sync = function() {
		const role = roleSelect.value;
		const wantLuci = !!luciCheck.checked;
		if (wantLuci && role === 'readonly')
			readonlyBanner.removeAttribute('hidden');
		else
			readonlyBanner.setAttribute('hidden', 'hidden');
		if (wantLuci && role === 'admin')
			adminBanner.removeAttribute('hidden');
		else
			adminBanner.setAttribute('hidden', 'hidden');
	};
	roleSelect.addEventListener('change', sync);
	luciCheck.addEventListener('change', sync);
	sync();
}

function hasWriteAcl() {
	try {
		if (typeof L.hasACLScope === 'function') {
			const scoped = L.hasACLScope('luci-app-usrmanage', 'write');
			if (typeof scoped === 'boolean')
				return scoped;
		}
	} catch (e) { /* ignore */ }
	try {
		const acls = L.env && L.env.acls && L.env.acls['luci-app-usrmanage'];
		if (acls) {
			if (acls.write)
				return true;
			if (acls.read && !acls.write)
				return false;
		}
	} catch (e2) { /* ignore */ }
	/* Unknown client ACL shape — caller should fall back to get_policy success. */
	return null;
}

/* Omit null/undefined so E() does not stringify them as the text "null". */
function elChildren(kids) {
	return (kids || []).filter(function(n) { return n != null; });
}

/* Surface CLI/rpcd error tokens in notifications (issue #3 M8). */
function notifyMutatorFailure(res) {
	const detail = (res && res.error) ? String(res.error) : 'error';
	ui.addNotification(null, E('p', {}, _('Failed: %s').format(detail)), 'danger');
}

function notifyRequestFailed() {
	ui.addNotification(null, E('p', {}, _('Request failed')), 'danger');
}

/* Shared mutator result handling: close modal, surface failure, toast + refresh on success. */
function finishMutator(res, successMsg, view) {
	ui.hideModal();
	if (res && res.ok === false) {
		notifyMutatorFailure(res);
		return;
	}
	if (successMsg)
		ui.addNotification(null, E('p', {}, successMsg), 'info');
	return view.refreshView();
}

function detectPreset(p) {
	const keys = [ 'openwrt', 'standard', 'strict' ];
	for (let i = 0; i < keys.length; i++) {
		const ref = PRESET_VALUES[keys[i]];
		if (Number(p.min_length) === ref.min_length
			&& !!p.reject_username === ref.reject_username
			&& !!p.require_lower === ref.require_lower
			&& !!p.require_upper === ref.require_upper
			&& !!p.require_digit === ref.require_digit
			&& !!p.require_special === ref.require_special)
			return keys[i];
	}
	return 'custom';
}

/* Severity-aware doctor banner: no green OK strip; warn collapsed; error expanded. */
function buildDoctorBanner(doctor) {
	const checks = (doctor && Array.isArray(doctor.checks)) ? doctor.checks : [];
	const incomplete = (doctor && Array.isArray(doctor.incomplete)) ? doctor.incomplete : [];
	const errors = [];
	const warns = [];
	checks.forEach(function(c) {
		if (!c || c.ok !== false)
			return;
		if (c.severity === 'warn')
			warns.push(c);
		else
			errors.push(c);
	});
	if (!errors.length && !warns.length && !incomplete.length)
		return null;

	const issueRows = [];
	errors.forEach(function(c) {
		issueRows.push(E('li', {}, '%s: %s'.format(c.id || 'check', c.msg || '')));
	});
	incomplete.forEach(function(inc) {
		issueRows.push(E('li', {}, _('Incomplete operation: %s').format(String(inc))));
	});
	warns.forEach(function(c) {
		issueRows.push(E('li', {}, '%s: %s'.format(c.id || 'check', c.msg || '')));
	});

	const hasError = errors.length > 0 || incomplete.length > 0;
	const summary = hasError
		? _('User management self-check found problems that may block account changes.')
		: _('User management self-check notes (safe to continue; wheel is created when you add the first user).');
	const detailsAttrs = hasError
		? { 'open': 'open' }
		: {};
	const detailsKids = [
		E('summary', {}, _('Technical details')),
		E('pre', {}, JSON.stringify(doctor, null, 2))
	];

	return E('div', {
		'class': hasError ? 'alert-message error' : 'alert-message warning',
		'data-testid': 'usrmanage-doctor-banner'
	}, [
		E('p', {}, summary),
		E('ul', {}, issueRows),
		E('details', detailsAttrs, detailsKids)
	]);
}

function passwordChecks(policy, name, pass, pass2) {
	const minLen = Number(policy.min_length) || 8;
	const items = [];
	items.push({
		id: 'min_length',
		ok: pass.length >= minLen,
		label: _('At least %d characters').format(minLen)
	});
	if (policy.reject_username) {
		items.push({
			id: 'reject_username',
			ok: !name || pass !== name,
			label: _('Different from username')
		});
	}
	if (policy.require_lower) {
		items.push({
			id: 'require_lower',
			ok: /[a-z]/.test(pass),
			label: _('Contains a lowercase letter')
		});
	}
	if (policy.require_upper) {
		items.push({
			id: 'require_upper',
			ok: /[A-Z]/.test(pass),
			label: _('Contains an uppercase letter')
		});
	}
	if (policy.require_digit) {
		items.push({
			id: 'require_digit',
			ok: /[0-9]/.test(pass),
			label: _('Contains a digit')
		});
	}
	if (policy.require_special) {
		items.push({
			id: 'require_special',
			ok: /[^A-Za-z0-9]/.test(pass),
			label: _('Contains a special character')
		});
	}
	items.push({
		id: 'confirm',
		ok: pass.length > 0 && pass === pass2,
		label: _('Confirmation matches')
	});
	return items;
}

function passwordPolicyOk(policy, name, pass, pass2) {
	return passwordChecks(policy, name, pass, pass2).every(function(c) { return c.ok; });
}

var pwcheckCssLoaded = false;

function ensurePwcheckCss() {
	if (pwcheckCssLoaded)
		return;
	pwcheckCssLoaded = true;
	const href = (typeof L !== 'undefined' && L.resource)
		? L.resource('view/system/usrmanage.css')
		: '/luci-static/resources/view/system/usrmanage.css';
	document.head.appendChild(E('link', {
		'rel': 'stylesheet',
		'type': 'text/css',
		'href': href
	}));
}

function buildPasswordPolicyUI(policy, getNameFn, passInput, pass2Input, submitBtn) {
	ensurePwcheckCss();
	const label = policy.label || policy.preset || 'OpenWrt';
	const summary = E('p', { 'class': 'cbi-value-description' }, [
		_('Password policy: %s').format(label)
	]);
	const list = E('ul', {
		'class': 'usrmanage-pwcheck-list',
		'data-testid': 'usrmanage-pwcheck-list'
	});

	const refresh = function() {
		const name = getNameFn();
		const pass = passInput.value || '';
		const pass2 = pass2Input.value || '';
		const checks = passwordChecks(policy, name, pass, pass2);
		dom.content(list, checks.map(function(c) {
			return E('li', {
				'class': 'usrmanage-pwcheck ' + (c.ok ? 'usrmanage-pwcheck-ok' : 'usrmanage-pwcheck-bad'),
				'data-testid': 'usrmanage-pwcheck-' + c.id,
				'data-ok': c.ok ? '1' : '0'
			}, [
				E('span', {
					'class': 'usrmanage-pwcheck-mark',
					'aria-hidden': 'true'
				}, c.ok ? '✓' : '✗'),
				E('span', {}, c.label)
			]);
		}));
		const ok = checks.every(function(c) { return c.ok; });
		submitBtn.disabled = !ok;
		if (ok)
			submitBtn.classList.remove('cbi-button-disabled');
		else
			submitBtn.classList.add('cbi-button-disabled');
	};

	passInput.addEventListener('input', refresh);
	pass2Input.addEventListener('input', refresh);

	refresh();
	return E('div', { 'class': 'cbi-section' }, [ summary, list ]);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			callList(false),
			callAudit(50),
			callDoctor(),
			callPolicyName()
		]).then(function(base) {
			/* Prefer full policy when write ACL allows; never fail the page for read-only. */
			return callGetPolicy().then(function(full) {
				return base.concat([ full ]);
			}).catch(function() {
				return base.concat([ null ]);
			});
		});
	},

	render: function(data) {
		const users = (data[0] && data[0].users) ? data[0].users : [];
		const events = (data[1] && data[1].events) ? data[1].events : [];
		const doctor = (data[2] && typeof data[2] === 'object')
			? data[2]
			: { ok: true, checks: [], incomplete: [] };
		const policyName = (data[3] && typeof data[3] === 'object')
			? data[3]
			: { preset: 'openwrt', label: 'OpenWrt' };
		const policyFull = (data[4] && typeof data[4] === 'object' && data[4].min_length != null)
			? Object.assign({}, PRESET_VALUES.openwrt, data[4])
			: null;
		const writeAclHint = hasWriteAcl();
		/* Prefer get_policy success as write signal when client ACL APIs are inconclusive (issue #3 minor). */
		const writeAcl = (writeAclHint === true) || (writeAclHint !== false && !!policyFull);
		const manage = writeAcl;
		const self = this;
		/* Full policy for checklists; fall back to OpenWrt defaults if get_policy failed but write ACL is present. */
		const policyForForms = policyFull || (writeAcl
			? Object.assign({}, PRESET_VALUES.openwrt, {
				preset: policyName.preset || 'openwrt',
				label: policyName.label || 'OpenWrt'
			})
			: null);
		const policyIn = policyFull || policyName;

		const doctorBanner = buildDoctorBanner(doctor);

		const policyLabel = policyIn.label || 'OpenWrt';
		const editorWrap = E('div', { 'class': 'cbi-section', 'hidden': 'hidden' });
		const stripKids = [
			E('span', {}, _('Password policy: %s').format(policyLabel))
		];
		if (manage) {
			stripKids.push(' ');
			stripKids.push(E('button', {
				'class': 'btn cbi-button',
				'data-testid': 'usrmanage-configure-policy',
				'click': function(ev) {
					ev.preventDefault();
					self.togglePolicyEditor(editorWrap, policyForForms);
				}
			}, _('Configure')));
		}
		const policyStrip = E('div', { 'class': 'cbi-section-node' }, stripKids);

		const rows = users.map(function(u) {
			const actions = [];
			const luciState = u.luci_login || 'none';
			let luciLabel = _('Off');
			if (luciState === 'owned')
				luciLabel = _('On');
			else if (luciState === 'foreign')
				luciLabel = _('Elsewhere');
			else if (luciState === 'tampered')
				luciLabel = _('Tampered');
			else if (luciState === 'error')
				luciLabel = _('Error');

			if (manage && u.managed) {
				actions.push(E('button', {
					'class': 'btn cbi-button',
					'data-testid': 'usrmanage-set-role',
					'click': ui.createHandlerFn(self, 'handleSetRole', u.name, u.role)
				}, _('Set role')));
				actions.push(' ');
				actions.push(E('button', {
					'class': 'btn cbi-button',
					'data-testid': 'usrmanage-passwd',
					'click': ui.createHandlerFn(self, 'handlePasswd', u.name, policyForForms)
				}, _('Password')));
				actions.push(' ');
				if (luciState === 'none') {
					actions.push(E('button', {
						'class': 'btn cbi-button',
						'data-testid': 'usrmanage-luci-enable',
						'click': ui.createHandlerFn(self, 'handleLuciLogin', u.name, 'enable', u.role)
					}, _('Enable LuCI')));
					actions.push(' ');
				}
				else if (luciState === 'owned') {
					actions.push(E('button', {
						'class': 'btn cbi-button',
						'data-testid': 'usrmanage-luci-disable',
						'click': ui.createHandlerFn(self, 'handleLuciLogin', u.name, 'disable', u.role)
					}, _('Disable LuCI')));
					actions.push(' ');
				}
				else if (luciState === 'tampered') {
					actions.push(E('button', {
						'class': 'btn cbi-button',
						'data-testid': 'usrmanage-luci-reset',
						'click': ui.createHandlerFn(self, 'handleLuciLogin', u.name, 'reset', u.role)
					}, _('Reset LuCI')));
					actions.push(' ');
				}
				else if (luciState === 'foreign') {
					actions.push(E('span', {
						'class': 'cbi-value-description',
						'title': _('A login section managed by another application blocks LuCI login management.')
					}, _('Elsewhere')));
					actions.push(' ');
				}
				actions.push(E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'data-testid': 'usrmanage-remove',
					'click': ui.createHandlerFn(self, 'handleRemove', u.name)
				}, _('Remove')));
			}
			else if (!manage) {
				actions.push(E('em', {}, _('read only')));
			}
			else {
				actions.push(E('em', {}, _('unmanaged')));
			}

			return E('tr', { 'class': 'tr', 'data-testid': 'usrmanage-row-' + (u.name || '') }, [
				E('td', { 'class': 'td' }, u.name || ''),
				E('td', { 'class': 'td' }, String(u.uid != null ? u.uid : '')),
				E('td', { 'class': 'td' }, u.role || ''),
				E('td', { 'class': 'td' }, u.shell || ''),
				E('td', { 'class': 'td' }, u.managed ? _('yes') : _('no')),
				E('td', { 'class': 'td', 'data-testid': 'usrmanage-luci-state' }, luciLabel),
				E('td', { 'class': 'td' }, actions)
			]);
		});

		const eventRows = events.map(function(ev) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, ev.ts || ''),
				E('td', { 'class': 'td' }, ev.action || ''),
				E('td', { 'class': 'td' }, ev.user || ''),
				E('td', { 'class': 'td' }, ev.role || ''),
				E('td', { 'class': 'td' }, ev.actor || ''),
				E('td', { 'class': 'td' }, ev.src || ''),
				E('td', { 'class': 'td' }, ev.result || ''),
				E('td', { 'class': 'td' }, ev.reason || '')
			]);
		});

		const addBtn = manage ? E('button', {
			'class': 'btn cbi-button cbi-button-add',
			'data-testid': 'usrmanage-add-user',
			'click': ui.createHandlerFn(self, 'handleAdd', policyForForms)
		}, _('Add user')) : null;

		const tableBody = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Username')),
				E('th', { 'class': 'th' }, _('UID')),
				E('th', { 'class': 'th' }, _('Role')),
				E('th', { 'class': 'th' }, _('Shell')),
				E('th', { 'class': 'th' }, _('Managed')),
				E('th', { 'class': 'th' }, _('LuCI')),
				E('th', { 'class': 'th' }, _('Actions'))
			])
		].concat(rows.length ? rows : [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': 7 }, _('No managed users yet.'))
			])
		]);

		const auditBody = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Time')),
				E('th', { 'class': 'th' }, _('Action')),
				E('th', { 'class': 'th' }, _('Username')),
				E('th', { 'class': 'th' }, _('Role')),
				E('th', { 'class': 'th' }, _('Actor')),
				E('th', { 'class': 'th' }, _('Source')),
				E('th', { 'class': 'th' }, _('Result')),
				E('th', { 'class': 'th' }, _('Reason'))
			])
		].concat(eventRows.length ? eventRows : [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'colspan': 8 }, _('No audit events yet.'))
			])
		]);

		return E('div', { 'class': 'cbi-map' }, elChildren([
			E('h2', {}, _('User Management')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Manage local UNIX/SSH accounts on this device. LuCI web login is optional per user (same UNIX password via $p$).'),
				E('br'),
				_('LuCI menus follow UNIX role: admin → Full LuCI; readonly → diagnostic (Status/Network/health + view-only User Management).'),
				E('br'),
				_('Admin role grants wheel + sudo (full root after password). Write ACL on this app is root-equivalent. Audit log is operational (local + syslog), not compliance-grade evidence.')
			]),
			!manage ? E('div', {
				'class': 'alert-message notice',
				'data-testid': 'usrmanage-view-only-banner'
			}, [
				E('p', {}, _('View only — you can list users and audit events, but not add, change roles, passwords, policy, or LuCI login.'))
			]) : null,
			doctorBanner,
			policyStrip,
			editorWrap,
			addBtn ? E('div', { 'class': 'cbi-section-node' }, [ addBtn ]) : null,
			E('table', { 'class': 'table' }, tableBody),
			E('h3', {}, _('Audit log')),
			E('div', { 'class': 'cbi-section-node' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, 'handleRefresh')
				}, _('Refresh'))
			]),
			E('table', { 'class': 'table cbi-section-table' }, auditBody),
			E('div', {
				'class': 'cbi-value-description',
				'id': 'usrmanage-build',
				'data-testid': 'usrmanage-build',
				'title': 'luci-app-usrmanage'
			}, 'v' + APP_VERSION)
		]));
	},

	togglePolicyEditor: function(wrap, policy) {
		if (wrap.getAttribute('data-open') === '1') {
			dom.content(wrap, []);
			wrap.setAttribute('hidden', 'hidden');
			wrap.removeAttribute('data-open');
			return;
		}
		const self = this;
		const draft = Object.assign({}, policy);
		const presetSelect = E('select', {
			'class': 'cbi-input-select',
			'data-testid': 'usrmanage-policy-preset'
		}, [
			E('option', { 'value': 'openwrt' }, _('OpenWrt (default)')),
			E('option', { 'value': 'standard' }, _('Standard')),
			E('option', { 'value': 'strict' }, _('Strict')),
			E('option', { 'value': 'custom' }, _('Custom'))
		]);
		presetSelect.value = draft.preset || detectPreset(draft);

		const minSelect = E('select', { 'class': 'cbi-input-select' },
			[ 8, 10, 12, 14, 16 ].map(function(n) {
				return E('option', { 'value': String(n) }, String(n));
			})
		);
		minSelect.value = String(draft.min_length || 8);

		const mkCheck = function(key, title) {
			const input = E('input', { 'type': 'checkbox' });
			input.checked = !!draft[key];
			input.addEventListener('change', function() {
				draft[key] = input.checked;
				draft.preset = 'custom';
				presetSelect.value = 'custom';
			});
			return E('label', {}, [ input, ' ', title ]);
		};

		const rej = mkCheck('reject_username', _('Reject password equal to username'));
		const low = mkCheck('require_lower', _('Require lowercase'));
		const up = mkCheck('require_upper', _('Require uppercase'));
		const dig = mkCheck('require_digit', _('Require digit'));
		const spe = mkCheck('require_special', _('Require special character'));

		minSelect.addEventListener('change', function() {
			draft.min_length = Number(minSelect.value);
			draft.preset = 'custom';
			presetSelect.value = 'custom';
		});

		presetSelect.addEventListener('change', function() {
			const v = presetSelect.value;
			if (v !== 'custom' && PRESET_VALUES[v]) {
				Object.assign(draft, PRESET_VALUES[v]);
				minSelect.value = String(draft.min_length);
				rej.querySelector('input').checked = draft.reject_username;
				low.querySelector('input').checked = draft.require_lower;
				up.querySelector('input').checked = draft.require_upper;
				dig.querySelector('input').checked = draft.require_digit;
				spe.querySelector('input').checked = draft.require_special;
			}
			else {
				draft.preset = 'custom';
			}
		});

		dom.content(wrap, [
			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'class': 'cbi-value-description' },
					_('Defaults match OpenWrt. Choose a stricter preset or adjust toggles, then Save.')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Preset')),
					E('div', { 'class': 'cbi-value-field' }, presetSelect)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Minimum length')),
					E('div', { 'class': 'cbi-value-field' }, minSelect)
				]),
				E('div', { 'class': 'cbi-value' }, [ rej ]),
				E('div', { 'class': 'cbi-value' }, [ low ]),
				E('div', { 'class': 'cbi-value' }, [ up ]),
				E('div', { 'class': 'cbi-value' }, [ dig ]),
				E('div', { 'class': 'cbi-value' }, [ spe ]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button-save',
						'data-testid': 'usrmanage-policy-save',
						'click': function() {
							const preset = presetSelect.value;
							const payload = preset === 'custom'
								? {
									preset: 'custom',
									min_length: Number(minSelect.value),
									reject_username: rej.querySelector('input').checked,
									require_lower: low.querySelector('input').checked,
									require_upper: up.querySelector('input').checked,
									require_digit: dig.querySelector('input').checked,
									require_special: spe.querySelector('input').checked
								}
								: Object.assign({}, PRESET_VALUES[preset]);
							return callSetPolicy(
								payload.preset,
								payload.min_length,
								payload.reject_username,
								payload.require_lower,
								payload.require_upper,
								payload.require_digit,
								payload.require_special
							).then(function(res) {
								if (res && res.ok === false) {
									notifyMutatorFailure(res);
									return;
								}
								ui.addNotification(null, E('p', {}, _('Password policy saved')), 'info');
								return self.refreshView();
							}).catch(function() {
								ui.addNotification(null, E('p', {}, _('Request failed')), 'danger');
							});
						}
					}, _('Save')),
					' ',
					E('button', {
						'class': 'btn',
						'click': function() {
							dom.content(wrap, []);
							wrap.setAttribute('hidden', 'hidden');
							wrap.removeAttribute('data-open');
						}
					}, _('Cancel'))
				])
			])
		]);
		wrap.removeAttribute('hidden');
		wrap.setAttribute('data-open', '1');
	},

	handleRefresh: function(ev) {
		return this.refreshView();
	},

	/* LuCI 24.10 View has no renderContents(); re-run load→render into #view. */
	refreshView: function() {
		const self = this;
		return Promise.resolve(this.load()).then(function(data) {
			return self.render(data);
		}).then(function(nodes) {
			const vp = document.getElementById('view');
			if (!vp)
				return;
			dom.content(vp, nodes);
			if (typeof self.addFooter === 'function')
				dom.append(vp, self.addFooter());
		});
	},

	handleAdd: function(policy, ev) {
		const self = this;
		const nameInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': _('username'),
			'data-testid': 'usrmanage-add-username'
		});
		const roleSelect = E('select', {
			'class': 'cbi-input-select',
			'data-testid': 'usrmanage-add-role'
		}, [
			E('option', { 'value': 'readonly' }, _('readonly')),
			E('option', { 'value': 'admin' }, _('admin'))
		]);
		const passInput = E('input', {
			'type': 'password',
			'class': 'cbi-input-text',
			'autocomplete': 'new-password',
			'data-testid': 'usrmanage-add-password'
		});
		const pass2Input = E('input', {
			'type': 'password',
			'class': 'cbi-input-text',
			'autocomplete': 'new-password',
			'data-testid': 'usrmanage-add-password-confirm'
		});
		const luciCheck = E('input', {
			'type': 'checkbox',
			'data-testid': 'usrmanage-add-luci-login'
		});
		const readonlyBanner = buildReadonlyLuciBanner();
		readonlyBanner.setAttribute('hidden', 'hidden');
		const adminBanner = buildAdminLuciBanner();
		adminBanner.setAttribute('hidden', 'hidden');
		wireLuciRoleExtras(roleSelect, luciCheck, readonlyBanner, adminBanner);
		const addBtn = E('button', {
			'class': 'btn cbi-button-positive cbi-button-disabled',
			'disabled': 'disabled',
			'data-testid': 'usrmanage-add-submit'
		}, _('Add'));
		const policyBox = buildPasswordPolicyUI(policy, function() {
			return nameInput.value.trim();
		}, passInput, pass2Input, addBtn);

		nameInput.addEventListener('input', function() {
			passInput.dispatchEvent(new Event('input'));
		});

		addBtn.addEventListener('click', function() {
			const name = nameInput.value.trim();
			const role = roleSelect.value;
			const p1 = passInput.value;
			const p2 = pass2Input.value;
			const wantLuci = !!luciCheck.checked;
			if (!name) {
				ui.addNotification(null, E('p', {}, _('Username required')), 'danger');
				return;
			}
			if (!passwordPolicyOk(policy, name, p1, p2)) {
				ui.addNotification(null, E('p', {}, _('Password does not meet the current policy')), 'danger');
				return;
			}
			return callAdd(name, role, p1, wantLuci).then(function(res) {
				passInput.value = '';
				pass2Input.value = '';
				return finishMutator(res, _('User added'), self);
			}).catch(function(err) {
				notifyRequestFailed();
				if (window && window.console)
					console.error('usrmanage add', err);
			});
		});

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
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Allow LuCI web login')),
					E('div', { 'class': 'cbi-value-field' }, [
						luciCheck,
						E('div', { 'class': 'cbi-value-description' },
							_('Uses the same UNIX password. Off by default. Exposes this password to the web login path. LuCI menus follow the UNIX role (admin=Full, readonly=diagnostic).'))
					])
				]),
				readonlyBanner,
				adminBanner,
				policyBox
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				addBtn
			])
		]);
	},

	handleLuciLogin: function(name, mode, role, ev) {
		const self = this;
		const isEnable = (mode === 'enable');
		const isReset = (mode === 'reset');
		const title = isEnable
			? _('Enable LuCI login: %s').format(name)
			: isReset
				? _('Reset LuCI login: %s').format(name)
				: _('Disable LuCI login: %s').format(name);
		const body = isEnable
			? _('This reuses the UNIX password for web login ($p$). Prefer HTTPS and a management network.')
			: isReset
				? _('Removes the usrmanage-owned web login (even if tampered). Allows re-enabling with a fresh configuration.')
				: _('Removes the usrmanage-owned web login. SSH still works. If this is your current session, you will be logged out.');

		const modalKids = [ E('p', {}, body) ];
		if (isEnable && role === 'readonly')
			modalKids.push(buildReadonlyLuciBanner());
		if (isEnable && role === 'admin')
			modalKids.push(buildAdminLuciBanner());

		ui.showModal(title, modalKids.concat([
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': isEnable ? 'btn cbi-button-positive' : 'btn cbi-button-negative',
					'data-testid': isEnable ? 'usrmanage-luci-enable-confirm' : isReset ? 'usrmanage-luci-reset-confirm' : 'usrmanage-luci-disable-confirm',
					'click': ui.createHandlerFn(self, function() {
						return callSetLuciLogin(name, mode).then(function(res) {
							const successMsg = isEnable ? _('LuCI login enabled') : isReset ? _('LuCI login reset') : _('LuCI login disabled');
							return finishMutator(res, successMsg, self);
						}).catch(function(err) {
							notifyRequestFailed();
							if (window && window.console)
								console.error('usrmanage set_luci_login', err);
						});
					})
				}, isEnable ? _('Enable') : isReset ? _('Reset') : _('Disable'))
			])
		]));
	},

	handleSetRole: function(name, current, ev) {
		const self = this;
		const roleSelect = E('select', {
			'class': 'cbi-input-select',
			'data-testid': 'usrmanage-set-role-select'
		}, [
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
					'data-testid': 'usrmanage-set-role-apply',
					'click': function() {
						return callSetRole(name, roleSelect.value).then(function(res) {
							return finishMutator(res, null, self);
						}).catch(notifyRequestFailed);
					}
				}, _('Apply'))
			])
		]);
	},

	handlePasswd: function(name, policy, ev) {
		const self = this;
		const passInput = E('input', {
			'type': 'password',
			'class': 'cbi-input-text',
			'autocomplete': 'new-password',
			'data-testid': 'usrmanage-passwd-password'
		});
		const pass2Input = E('input', {
			'type': 'password',
			'class': 'cbi-input-text',
			'autocomplete': 'new-password',
			'data-testid': 'usrmanage-passwd-confirm'
		});
		const changeBtn = E('button', {
			'class': 'btn cbi-button-positive cbi-button-disabled',
			'disabled': 'disabled',
			'data-testid': 'usrmanage-passwd-submit'
		}, _('Change'));
		const policyBox = buildPasswordPolicyUI(policy, function() { return name; }, passInput, pass2Input, changeBtn);

		changeBtn.addEventListener('click', function() {
			const p1 = passInput.value;
			const p2 = pass2Input.value;
			if (!passwordPolicyOk(policy, name, p1, p2)) {
				ui.addNotification(null, E('p', {}, _('Password does not meet the current policy')), 'danger');
				return;
			}
			return callPasswd(name, p1).then(function(res) {
				passInput.value = '';
				pass2Input.value = '';
				return finishMutator(res, _('Password updated'), self);
			}).catch(notifyRequestFailed);
		});

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
			policyBox,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				changeBtn
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
					'data-testid': 'usrmanage-remove-confirm',
					'click': function() {
						return callDel(name, purge.checked).then(function(res) {
							return finishMutator(res, _('User removed'), self);
						}).catch(notifyRequestFailed);
					}
				}, _('Remove'))
			])
		]);
	}
});
