#!/usr/bin/env node
'use strict';
/**
 * Guard: LuCI views should prefer theme-friendly classes over hardcoded hex colors.
 */
const fs = require('fs');
const path = require('path');

const views = [
	'usrmanage.js',
	'usrmanage-health.js'
].map(function(name) {
	return path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system', name);
});

for (const view of views) {
	const base = path.basename(view);
	const src = fs.readFileSync(view, 'utf8');
	const hex = src.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
	if (hex.length) {
		console.error('forbidden hex colors in', base, '(use LuCI theme classes/variables):', hex);
		process.exit(1);
	}
	const required = base === 'usrmanage.js'
		? ['cbi-map', 'table', 'btn']
		: ['cbi-map', 'btn'];
	for (const cls of required) {
		if (!src.includes(cls)) {
			console.error(`expected stock LuCI class usage in ${base}: ${cls}`);
			process.exit(1);
		}
	}
}

console.log('usrmanage theme tests passed');
