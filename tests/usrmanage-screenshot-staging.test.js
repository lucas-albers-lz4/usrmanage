#!/usr/bin/env node
'use strict';
// Staging must share the destination filesystem for atomic rename publication.
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '../scripts/capture-usrmanage-screenshots.mjs'), 'utf8');

if (!/const outputDir = path\.resolve\('docs\/user\/assets'\);/.test(src)
	|| !/fs\.mkdirSync\(outputDir, \{ recursive: true \}\);/.test(src)
	|| !/const workDir = fs\.mkdtempSync\(path\.join\(outputDir, '\.usrmanage-gallery-'\)\);/.test(src))
	throw new Error('screenshot staging directory must be created inside outputDir');
if (/os\.tmpdir\(\)/.test(src))
	throw new Error('screenshot staging must not use the system temp filesystem');
if (!/fs\.renameSync\(image\.source, image\.destination\)/.test(src))
	throw new Error('screenshot publication should retain same-filesystem rename');

console.log('usrmanage screenshot staging tests passed (static only)');
