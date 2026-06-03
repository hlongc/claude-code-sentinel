#!/usr/bin/env node

"use strict";

const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");

const uninstall = process.argv.includes("--uninstall");
const binaryArg = process.argv.find((arg) => arg !== "--uninstall" && arg !== process.argv[0] && arg !== process.argv[1]);
const binaryPath = path.resolve(binaryArg || "release/claude-code-sentinel");
const targetDir = "/Library/Application Support/ClaudeCode";
const targetPath = path.join(targetDir, "managed-settings.json");

function hookSettings(bin) {
  const command = JSON.stringify(bin);
  return {
    PreToolUse: [
      {
        matcher: "AskUserQuestion",
        hooks: [
          {
            type: "command",
            command: `${command} pre-tool-use`,
          },
        ],
      },
    ],
    PermissionRequest: [
      {
        matcher: "*",
        hooks: [
          {
            type: "command",
            command: `${command} permission-request`,
          },
        ],
      },
    ],
    Notification: [
      {
        matcher: "permission_prompt",
        hooks: [
          {
            type: "command",
            command: `${command} notification`,
            async: true,
          },
        ],
      },
      {
        matcher: "idle_prompt",
        hooks: [
          {
            type: "command",
            command: `${command} notification`,
            async: true,
          },
        ],
      },
    ],
    Stop: [
      {
        hooks: [
          {
            type: "command",
            command: `${command} stop`,
            async: true,
          },
        ],
      },
    ],
    StopFailure: [
      {
        hooks: [
          {
            type: "command",
            command: `${command} notification`,
            async: true,
          },
        ],
      },
    ],
  };
}

function readExisting() {
  try {
    return JSON.parse(fs.readFileSync(targetPath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return {};
    throw error;
  }
}

function writeManagedSettings(settings) {
  fs.mkdirSync(targetDir, { recursive: true });
  fs.writeFileSync(targetPath, `${JSON.stringify(settings, null, 2)}\n`);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function writeWithAdmin(settings) {
  const tempPath = path.join(
    "/tmp",
    `claude-code-sentinel-managed-settings-${Date.now()}.json`
  );
  fs.writeFileSync(tempPath, `${JSON.stringify(settings, null, 2)}\n`);
  const steps = [
    ["sudo", ["mkdir", "-p", targetDir]],
    ["sudo", ["cp", tempPath, targetPath]],
    ["sudo", ["chmod", "644", targetPath]],
  ];

  for (const [command, args] of steps) {
    const result = childProcess.spawnSync(command, args, { stdio: "inherit" });
    if (result.status !== 0) {
      process.stderr.write(
        [
          "",
          `Unable to write ${targetPath}.`,
          "You can finish manually with:",
          "",
          [
            "sudo mkdir -p",
            shellQuote(targetDir),
            "&&",
            "sudo cp",
            shellQuote(tempPath),
            shellQuote(targetPath),
            "&&",
            "sudo chmod 644",
            shellQuote(targetPath),
          ].join(" "),
          "",
        ].join("\n")
      );
      process.exit(result.status || 1);
    }
  }

  fs.rmSync(tempPath, { force: true });
}

const existing = readExisting();
const next = { ...existing };
if (uninstall) {
  delete next.hooks;
} else {
  next.hooks = hookSettings(binaryPath);
}

try {
  writeManagedSettings(next);
} catch (error) {
  if (error.code !== "EACCES" && error.code !== "EPERM") {
    throw error;
  }
  writeWithAdmin(next);
}

console.log(`${uninstall ? "Removed" : "Installed"} managed Claude Code hooks at ${targetPath}`);
