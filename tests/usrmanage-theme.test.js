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

const cssFiles = [
	'usrmanage.css'
].map(function(name) {
	return path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system', name);
});

function assertNoHex(filePath) {
	const base = path.basename(filePath);
	const src = fs.readFileSync(filePath, 'utf8');
	const hex = src.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
	if (hex.length) {
		console.error('forbidden hex colors in', base, '(use LuCI theme classes/variables):', hex);
		process.exit(1);
	}
}

for (const view of views) {
	const base = path.basename(view);
	assertNoHex(view);
	const src = fs.readFileSync(view, 'utf8');
	try {
		require('child_process').execFileSync('node', ['--check', view], { stdio: 'pipe' });
	} catch (e) {
		console.error('syntax error in', base, (e.stderr && e.stderr.toString()) || e.message);
		process.exit(1);
	}
	// JS loads theme vars via CSS file; require checklist markup + CSS href in view.
	const requiredJs = base === 'usrmanage.js'
		? ['cbi-map', 'table', 'btn', 'usrmanage-pwcheck', 'usrmanage.css']
		: ['cbi-map', 'btn'];
	for (const cls of requiredJs) {
		if (!src.includes(cls)) {
			console.error(`expected stock LuCI / checklist usage in ${base}: ${cls}`);
			process.exit(1);
		}
	}
}

for (const css of cssFiles) {
	assertNoHex(css);
	const src = fs.readFileSync(css, 'utf8');
	for (const token of ['--success-color-high', '--error-color-high', '--on-success-color', 'usrmanage-pwcheck']) {
		if (!src.includes(token)) {
			console.error('expected theme token / class in', path.basename(css) + ':', token);
			process.exit(1);
		}
	}
}

console.log('usrmanage theme tests passed');
