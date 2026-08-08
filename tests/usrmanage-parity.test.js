#!/usr/bin/env node
'use strict';
/**
 * Parity gates for cross-copy mirrors (issue #51):
 * G1 actor sanitize whitelist/length, G2 preset tables, G3 APP_VERSION sync.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LIB = path.join(ROOT, 'openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh');
const RPCD = path.join(ROOT, 'openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage');
const VIEW = path.join(ROOT, 'openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js');
const MAKE_CLI = path.join(ROOT, 'openwrt-feed/usrmanage/Makefile');
const MAKE_LUCI = path.join(ROOT, 'openwrt-feed/luci-app-usrmanage/Makefile');

let failed = 0;
function ok(msg) { console.log('ok:', msg); }
function bad(msg) { console.error('FAIL:', msg); failed++; }

const lib = fs.readFileSync(LIB, 'utf8');
const rpcd = fs.readFileSync(RPCD, 'utf8');
const view = fs.readFileSync(VIEW, 'utf8');
const makeCli = fs.readFileSync(MAKE_CLI, 'utf8');
const makeLuci = fs.readFileSync(MAKE_LUCI, 'utf8');

/* --- G1: actor whitelist + length-64 --- */
const WHITELIST = '*[!A-Za-z0-9._@-]*';
const LENGTH_BOUND = '-gt 64';

function extractActorSanitize(src, label) {
	const hasWhitelist = src.includes(WHITELIST);
	const hasLen = src.includes(LENGTH_BOUND);
	if (!hasWhitelist)
		bad(`${label}: missing actor whitelist pattern ${WHITELIST}`);
	else
		ok(`${label}: actor whitelist present`);
	if (!hasLen)
		bad(`${label}: missing length bound ${LENGTH_BOUND}`);
	else
		ok(`${label}: actor length bound present`);
	return { hasWhitelist, hasLen };
}

const libActor = extractActorSanitize(lib, 'lib um_actor_resolve');
const rpcdActor = extractActorSanitize(rpcd, 'rpcd sanitize_actor');
if (libActor.hasWhitelist && rpcdActor.hasWhitelist && libActor.hasLen && rpcdActor.hasLen)
	ok('G1 actor sanitize parity (whitelist + length-64)');
else
	bad('G1 actor sanitize copies diverge');

/* --- G2: preset truth tables --- */
const EXPECTED = {
	openwrt: {
		min_length: 8,
		reject_username: true,
		require_lower: false,
		require_upper: false,
		require_digit: false,
		require_special: false
	},
	standard: {
		min_length: 10,
		reject_username: true,
		require_lower: true,
		require_upper: true,
		require_digit: true,
		require_special: false
	},
	strict: {
		min_length: 12,
		reject_username: true,
		require_lower: true,
		require_upper: true,
		require_digit: true,
		require_special: true
	}
};

function parseViewPresets(src) {
	const m = src.match(/const PRESET_VALUES = \{([\s\S]*?)\n\};/);
	if (!m)
		return null;
	const body = m[1];
	const out = {};
	for (const name of Object.keys(EXPECTED)) {
		const block = body.match(new RegExp(`${name}:\\s*\\{([\\s\\S]*?)\\}`, 'm'));
		if (!block)
			return null;
		const b = block[1];
		const num = (k) => {
			const r = b.match(new RegExp(`${k}:\\s*(\\d+)`));
			return r ? Number(r[1]) : null;
		};
		const bool = (k) => {
			const r = b.match(new RegExp(`${k}:\\s*(true|false)`));
			return r ? r[1] === 'true' : null;
		};
		out[name] = {
			min_length: num('min_length'),
			reject_username: bool('reject_username'),
			require_lower: bool('require_lower'),
			require_upper: bool('require_upper'),
			require_digit: bool('require_digit'),
			require_special: bool('require_special')
		};
	}
	return out;
}

function parseLibPresets(src) {
	const out = {};
	// openwrt via um_policy_defaults_openwrt
	const ow = src.match(/um_policy_defaults_openwrt\(\) \{([\s\S]*?)\n\}/);
	if (!ow)
		return null;
	const parseBlock = (block) => ({
		min_length: Number((block.match(/UM_POL_MIN_LENGTH=(\d+)/) || [])[1]),
		reject_username: (block.match(/UM_POL_REJECT_USERNAME=(\d+)/) || [])[1] === '1',
		require_lower: (block.match(/UM_POL_REQUIRE_LOWER=(\d+)/) || [])[1] === '1',
		require_upper: (block.match(/UM_POL_REQUIRE_UPPER=(\d+)/) || [])[1] === '1',
		require_digit: (block.match(/UM_POL_REQUIRE_DIGIT=(\d+)/) || [])[1] === '1',
		require_special: (block.match(/UM_POL_REQUIRE_SPECIAL=(\d+)/) || [])[1] === '1'
	});
	out.openwrt = parseBlock(ow[1]);

	const apply = src.match(/um_policy_apply_preset_values\(\) \{([\s\S]*?)\n\}/);
	if (!apply)
		return null;
	for (const name of ['standard', 'strict']) {
		const block = apply[1].match(new RegExp(`${name}\\)\\s*([\\s\\S]*?);;`, 'm'));
		if (!block)
			return null;
		out[name] = parseBlock(block[1]);
	}
	return out;
}

function samePreset(a, b) {
	return a && b
		&& a.min_length === b.min_length
		&& a.reject_username === b.reject_username
		&& a.require_lower === b.require_lower
		&& a.require_upper === b.require_upper
		&& a.require_digit === b.require_digit
		&& a.require_special === b.require_special;
}

const viewPresets = parseViewPresets(view);
const libPresets = parseLibPresets(lib);
if (!viewPresets) {
	bad('G2: could not parse view PRESET_VALUES');
} else if (!libPresets) {
	bad('G2: could not parse lib preset values');
} else {
	for (const name of Object.keys(EXPECTED)) {
		if (!samePreset(viewPresets[name], EXPECTED[name]))
			bad(`G2 view ${name} != expected: ${JSON.stringify(viewPresets[name])}`);
		else
			ok(`G2 view ${name} matches expected`);
		if (!samePreset(libPresets[name], EXPECTED[name]))
			bad(`G2 lib ${name} != expected: ${JSON.stringify(libPresets[name])}`);
		else
			ok(`G2 lib ${name} matches expected`);
		if (!samePreset(viewPresets[name], libPresets[name]))
			bad(`G2 view/lib ${name} diverge`);
		else
			ok(`G2 view/lib ${name} parity`);
	}
}

/* --- G3: APP_VERSION ↔ PKG_VERSION --- */
const appVer = (view.match(/const APP_VERSION = '([^']+)'/) || [])[1];
const pkgCli = (makeCli.match(/^PKG_VERSION:=(.+)$/m) || [])[1];
const pkgLuci = (makeLuci.match(/^PKG_VERSION:=(.+)$/m) || [])[1];
if (!appVer || !pkgCli || !pkgLuci) {
	bad(`G3: missing version literal (APP=${appVer} CLI=${pkgCli} LUCI=${pkgLuci})`);
} else if (appVer !== pkgCli || appVer !== pkgLuci) {
	bad(`G3: version drift APP_VERSION=${appVer} usrmanage=${pkgCli} luci-app=${pkgLuci}`);
} else {
	ok(`G3 APP_VERSION/PKG_VERSION sync (${appVer})`);
}

if (failed) {
	console.error(`usrmanage parity tests FAILED (${failed})`);
	process.exit(1);
}
console.log('usrmanage parity tests passed');
