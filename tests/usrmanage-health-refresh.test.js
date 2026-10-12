#!/usr/bin/env node
'use strict';
// Structural guard for the health refresh root; this does not render DOM.
const fs = require('fs');
const path = require('path');
const file = path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage-health.js');
const src = fs.readFileSync(file, 'utf8');
const rootId = "data-testid': 'usrmanage-health-root'";
const roots = src.split(rootId).length - 1;
if (roots !== 2)
	throw new Error(`expected stable root on both success/error views, found ${roots}`);
if (!/querySelector\('\[data-testid="usrmanage-health-root"\]'\)/.test(src))
	throw new Error('refresh fallback must select the stable health root');
if (/querySelector\('\[data-testid\^="usrmanage-health-"\]'\)/.test(src))
	throw new Error('refresh fallback must not select a nested health element');
if (!/data-testid': 'usrmanage-health-map'/.test(src))
	throw new Error('success-view health map test selector was removed');
if (!/expect:\s*\{\s*'':\s*\{\s*\}\s*\}/.test(src) || !/if \(h\.ok !== true\)/.test(src))
	throw new Error('health reply failures must not default to a healthy device');
console.log('usrmanage health refresh structure tests passed (static only)');
