#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const targetByArch = {
  arm64: "darwin-arm64",
  x64: "darwin-x64",
};

function fail(message) {
  process.stderr.write(`tado: ${message}\n`);
  process.exit(1);
}

if (process.platform !== "darwin") {
  fail("this package currently supports macOS only.");
}

const target = targetByArch[process.arch];
if (!target) {
  fail(`unsupported macOS architecture: ${process.arch}`);
}

const override = process.env.TADO_TUI_BINARY;
const binary = override || path.join(__dirname, "..", "prebuilt", target, "tado-tui");

if (!fs.existsSync(binary)) {
  fail(
    `missing prebuilt tado-tui for ${target}. ` +
      "Build it with `cargo build --release -p tado-cli --bin tado-tui` " +
      "and place the binary under npm/tado/prebuilt/<target>/tado-tui."
  );
}

const child = spawn(binary, process.argv.slice(2), {
  stdio: "inherit",
});

child.on("error", (error) => fail(error.message));
child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});
