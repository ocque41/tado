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

const prebuiltDir = path.join(__dirname, "..", "prebuilt", target);
const override = process.env.TADO_BINARY;
const invokedName = path.basename(process.argv[1] || "tado");
const invoked = invokedName === "tado.js" ? "tado" : invokedName;
const requested = path.join(prebuiltDir, invoked);
const preferred = path.join(prebuiltDir, "tado");
let binary = override;

if (!binary) {
  if (fs.existsSync(requested)) {
    binary = requested;
  } else if (invoked === "tado" && fs.existsSync(preferred)) {
    binary = preferred;
  } else {
    binary = requested;
  }
}

if (!fs.existsSync(binary)) {
  fail(
    `missing prebuilt ${invoked} binary for ${target}. ` +
      "Build it with `cargo build --release -p tado-runtime --bin tadod -p tado-cli --bin tado --bin tado-tui --bin tado-list --bin tado-read --bin tado-send --bin tado-events --bin tado-deploy --bin tado-bootstrap --bin tado-kanban --bin tado-eternal --bin tado-dispatch -p tado-mcp --bin tado-mcp` " +
      "or the full release target documented in prebuilt/README.md, " +
      "and place the binaries under npm/tado/prebuilt/<target>/."
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
