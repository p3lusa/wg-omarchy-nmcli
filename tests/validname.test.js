// Unit test for the connection-name allowlist (mirror of Widget.qml's
// validConnName()). Run:  node tests/validname.test.js
"use strict";

function validConnName(connName) {
  var n = String(connName || "").trim()
  if (n.length === 0 || n.length > 128) return ""
  if (n.indexOf("/") >= 0) return ""
  if (n.indexOf("\\") >= 0) return ""
  if (n.indexOf("..") >= 0) return ""
  if (n.charAt(0) === ".") return ""
  if (!/^[A-Za-z0-9._-]+$/.test(n)) return ""
  return n
}

const cases = [
  ["wg0", "wg0"],
  ["my-conn_2.x", "my-conn_2.x"],
  ["wg0 ", "wg0"],
  ["wg", "wg"],
  ["../../etc/shadow", ""],
  ["a/b", ""],
  [".hidden", ""],
  ["..", ""],
  ["my conn", ""],
  ["wg0;rm -rf /", ""],
  ["$(touch pwned)", ""],
  ["a\\b", ""],
  ["", ""],
  ["a".repeat(128), "a".repeat(128)],
  ["a".repeat(129), ""],
]

let ok = 0, bad = 0
for (const [inp, exp] of cases) {
  const got = validConnName(inp)
  const pass = got === exp
  if (pass) ok++; else bad++
  console.log((pass ? "PASS" : "FAIL") + "  validConnName(" + JSON.stringify(String(inp)) +
    ") = " + JSON.stringify(got) + " (exp " + JSON.stringify(exp) + ")")
}
console.log("\nRESULT ok=" + ok + " bad=" + bad)
process.exit(bad === 0 ? 0 : 1)
