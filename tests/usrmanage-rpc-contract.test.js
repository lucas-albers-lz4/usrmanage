#!/usr/bin/env node
'use strict';
// Static contract guard only; it does not execute rpc.js or render LuCI.
const fs = require('fs');
const path = require('path');
const file = path.join(__dirname, '../openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js');
const src = fs.readFileSync(file, 'utf8');
const declarations = [...src.matchAll(/const\s+(call\w+)\s*=\s*rpc\.declare\(\{([\s\S]*?)\n\}\);/g)];

if (!declarations.length) {
	throw new Error('no rpc.declare calls found');
}
for (const [, name, body] of declarations) {
	if (!/\breject:\s*true\b/.test(body))
		throw new Error(`${name} must reject nonzero ubus status replies`);
	if (!/expect\s*:\s*\{\s*'':\s*\{\s*\}\s*\}/.test(body))
		throw new Error(`${name} must preserve the complete reply with a non-success fallback object`);
}

const finish = src.match(/function finishMutator\(res, successMsg, view\) \{([\s\S]*?)\n\}/);
if (!finish || !/res\.ok\s*!==\s*true/.test(finish[1]) || !/notifyMutatorFailure/.test(finish[1]))
	throw new Error('finishMutator must treat every non-ok:true reply as failure');
const policyStart = src.indexOf('return callSetPolicy(');
const policySuccess = src.indexOf("ui.addNotification(null, E('p', {}, _('Password policy saved'))", policyStart);
const policySave = policyStart >= 0 && policySuccess > policyStart
	? src.slice(policyStart, policySuccess)
	: '';
if (!/if\s*\(!res\s*\|\|\s*res\.ok\s*!==\s*true\)/.test(policySave)
	|| !/notifyMutatorFailure\(res\)/.test(policySave))
	throw new Error('policy save must treat every non-ok:true reply as failure');
if (!/return view\.refreshView\(\);/.test(finish[1]))
	throw new Error('finishMutator should refresh only after its failure guard');
if (!/function validBaseReplies\(data\)/.test(src)
	|| !/Array\.isArray\(data\[0\]\.users\)/.test(src)
	|| !/Array\.isArray\(data\[1\]\.events\)/.test(src))
	throw new Error('read replies must be validated instead of falling back to fake empty results');
if (!/const writeAcl = writeAclHint !== false && !!policyFull;/.test(src)
	|| !/const policyUnavailable = writeAclHint === true && !policyFull;/.test(src))
	throw new Error('mutations must be disabled when full policy data is unavailable');

console.log(`usrmanage RPC contract tests passed (${declarations.length} declarations; static only)`);
