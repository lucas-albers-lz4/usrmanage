#!/usr/bin/env node
'use strict';
/**
 * Guard: user-visible LuCI strings use _() and appear in the POT template.
 */
const fs = require('fs');
const path = require('path');

const view = path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js');
const pot = path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/po/templates/luci-app-usrmanage.pot');

const src = fs.readFileSync(view, 'utf8');
const potText = fs.readFileSync(pot, 'utf8');

const re = /_\(\s*'((?:\\'|[^'])*)'\s*\)|_\(\s*"((?:\\"|[^"])*)"\s*\)/g;
const strings = new Set();
let m;
while ((m = re.exec(src)) !== null) {
	strings.add((m[1] !== undefined ? m[1] : m[2]).replace(/\\'/g, "'").replace(/\\"/g, '"'));
}

if (strings.size < 5) {
	console.error('expected more _() strings in view; found', strings.size);
	process.exit(1);
}

let missing = 0;
for (const s of strings) {
	const esc = s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
	if (!potText.includes(`msgid "${esc}"`) && !potText.includes(`msgid "${s}"`)) {
		console.error('missing from POT:', s);
		missing++;
	}
}

if (missing) {
	process.exit(1);
}

const dePo = path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/po/de/luci-app-usrmanage.po');
if (!fs.existsSync(dePo)) {
	console.error('missing locale scaffolding:', dePo);
	process.exit(1);
}

console.log('usrmanage i18n tests passed (%d strings)', strings.size);
