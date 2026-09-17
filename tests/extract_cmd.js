// Extracts the exact bash -lc script shipped in Widget.qml's importConfig()
// actionProc.command, so the security harness tests the ACTUAL runtime code.
// Usage: node extract_cmd.js <path-to-Widget.qml>  -> prints the script on stdout.
"use strict";
const fs = require("fs");
const path = process.argv[2] || "Widget.qml";
const t = fs.readFileSync(path, "utf8");
const a = t.indexOf("actionProc.command = [");
if (a < 0) { process.stderr.write("no actionProc.command array\n"); process.exit(2); }
const endMarker = '", c, src, pk]';
const b = t.indexOf(endMarker, a);
if (b < 0) { process.stderr.write("no end marker\n"); process.exit(2); }
const arrText = t.slice(t.indexOf("[", a), b + endMarker.length);
const fn = new Function("c", "src", "pk", "return (" + arrText + ")");
const arr = fn("wg0", "/etc/wireguard/wg0.conf", "pkexec");
process.stdout.write(arr[2]);
