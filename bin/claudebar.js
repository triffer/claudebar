#!/usr/bin/env node
"use strict";

// Thin Node wrapper around the bundled install.sh so claudebar can be installed
// and driven via npm/npx. All the real work lives in ../install.sh — this file
// only maps subcommands to it and keeps the UX friendly.

const { spawnSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const ROOT = path.join(__dirname, "..");
const INSTALLER = path.join(ROOT, "install.sh");

const HELP = `claudebar — Claude Code session status in your macOS menu bar

Usage:
  claudebar install      Install / upgrade (registers hooks, launchd watcher, SwiftBar plugin)
  claudebar uninstall    Remove everything (keeps your notify.conf)
  claudebar version      Show this package's version and the installed one
  claudebar help         Show this help

Prerequisites (npm can't install these):
  brew install jq
  brew install --cask swiftbar   # then launch it and pick a plugin folder

Docs: https://github.com/triffer/claudebar
`;

function run(args) {
  const res = spawnSync("bash", [INSTALLER, ...args], { stdio: "inherit" });
  if (res.error) {
    console.error(`claudebar: failed to run installer: ${res.error.message}`);
    process.exit(1);
  }
  process.exit(res.status == null ? 1 : res.status);
}

function packageVersion() {
  try {
    return require(path.join(ROOT, "package.json")).version || "unknown";
  } catch {
    return "unknown";
  }
}

// Nothing on the installed side sits next to a package.json; install.sh stamps this file instead.
function installedVersion() {
  const home = process.env.CLAUDE_NOTIFY_HOME || path.join(require("os").homedir(), ".claude");
  try {
    const stamp = fs.readFileSync(path.join(home, "hooks/claudebar-lib/installed.sh"), "utf8");
    const m = stamp.match(/^CLAUDEBAR_VERSION="(.*)"$/m);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

function printVersion() {
  const pkg = packageVersion();
  const installed = installedVersion();
  console.log(`claudebar ${pkg}`);
  if (installed === null) {
    console.log("not installed yet — run: claudebar install");
  } else if (installed !== pkg) {
    console.log(`installed: ${installed} — run \`claudebar install\` to upgrade to ${pkg}`);
  } else {
    console.log("installed: up to date");
  }
}

function main() {
  const cmd = (process.argv[2] || "").toLowerCase();

  if (cmd === "help" || cmd === "--help" || cmd === "-h" || cmd === "") {
    process.stdout.write(HELP);
    process.exit(cmd === "" ? 1 : 0);
  }

  // Above the macOS guard on purpose: which version you have is worth answering anywhere.
  if (cmd === "version" || cmd === "--version" || cmd === "-v") {
    printVersion();
    process.exit(0);
  }

  if (process.platform !== "darwin") {
    console.error("claudebar only runs on macOS (it needs SwiftBar and launchd).");
    process.exit(1);
  }

  if (!fs.existsSync(INSTALLER)) {
    console.error(`claudebar: installer not found at ${INSTALLER}`);
    process.exit(1);
  }

  switch (cmd) {
    case "install":
    case "upgrade":
    case "update":
      run([]);
      break;
    case "uninstall":
    case "remove":
      run(["--uninstall"]);
      break;
    default:
      console.error(`claudebar: unknown command "${cmd}"\n`);
      process.stdout.write(HELP);
      process.exit(1);
  }
}

main();
