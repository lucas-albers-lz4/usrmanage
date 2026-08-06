#!/usr/bin/env node
'use strict';
/**
 * Guard: LuCI view should prefer theme-friendly classes over hardcoded hex colors.
 */
const fs = require('fs');
const path = require('path');

const view = path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js');
const src = fs.readFileSync(view, 'utf8');

const hex = src.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
if (hex.length) {
	console.error('forbidden hex colors in usrmanage.js (use LuCI theme classes/variables):', hex);
	process.exit(1);
}

// Prefer stock cbi/table/btn classes for structure
for (const cls of ['cbi-map', 'table', 'btn']) {
	if (!src.includes(cls)) {
		console.error(`expected stock LuCI class usage: ${cls}`);
		process.exit(1);
	}
}

console.log('usrmanage theme tests passed');
