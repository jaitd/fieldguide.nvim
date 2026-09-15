// The path gate test table. The security-relevant test, and the one worth
// writing first — before any write tool is enabled, not after.
//
//   node --test tests/gate.test.ts
//
// Node 24 strips the types natively; there is no build step.

import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { after, before, test } from "node:test";

import { checkAccess, type Zones } from "../extension/gate.ts";

// A fixture that reproduces the two dotfile layouts the gate has to handle:
// the config dir is a symlink into a larger repo, and that repo holds files the
// agent must never reach.
//
//   root/
//     dotfiles/            <- a much larger repo the config sits inside
//       secrets.env        <- blocked: same repo, different subtree
//       nvim/.config/nvim/ <- the config tree (read/write)
//         init.lua
//         escape -> ../../../secrets.env   <- symlink out of the zone
//     xdg/nvim -> dotfiles/nvim/.config/nvim  <- what stdpath("config") reports
//     share/nvim/lazy/vim-fugitive/doc/fugitive.txt   <- doc zone (read-only)

let root: string;
let zones: Zones;

before(async () => {
  root = await realpath(await mkdtemp(path.join(tmpdir(), "fieldguide-gate-")));

  const configReal = path.join(root, "dotfiles/nvim/.config/nvim");
  await mkdir(configReal, { recursive: true });
  await writeFile(path.join(configReal, "init.lua"), "-- config\n");
  await writeFile(path.join(root, "dotfiles/secrets.env"), "TOKEN=hunter2\n");
  await symlink(path.join(root, "dotfiles/secrets.env"), path.join(configReal, "escape"));

  await mkdir(path.join(root, "xdg"), { recursive: true });
  await symlink(configReal, path.join(root, "xdg/nvim"));

  const docDir = path.join(root, "share/nvim/lazy/vim-fugitive/doc");
  await mkdir(docDir, { recursive: true });
  await writeFile(path.join(docDir, "fugitive.txt"), "*fugitive.txt*\n");

  zones = {
    // The agent starts in the *declared* (symlinked) directory, exactly as the
    // sidebar launches it.
    cwd: path.join(root, "xdg/nvim"),
    // ...and the gate compares against the *resolved* root.
    configRoot: configReal,
    docRoots: [await realpath(path.join(root, "share/nvim/lazy"))],
  };
});

after(async () => {
  await rm(root, { recursive: true, force: true });
});

type Case = {
  name: string;
  tool: string;
  input: Record<string, unknown>;
  allow: boolean;
};

const CASES: () => Case[] = () => [
  {
    name: "read inside the config tree",
    tool: "read",
    input: { path: "init.lua" },
    allow: true,
  },
  {
    name: "write inside the config tree",
    tool: "write",
    input: { path: "lua/config/options.lua", content: "" },
    allow: true,
  },
  {
    name: "write a new file in a new subdirectory of the config tree",
    tool: "write",
    input: { path: "lua/plugins/brand-new.lua", content: "" },
    allow: true,
  },
  {
    name: "cwd is the symlinked config dir, gate compares the resolved root",
    tool: "read",
    input: { path: path.join(root, "xdg/nvim/init.lua") },
    allow: true,
  },
  {
    name: "read an installed plugin's help text",
    tool: "read",
    input: { path: path.join(root, "share/nvim/lazy/vim-fugitive/doc/fugitive.txt") },
    allow: true,
  },
  {
    name: "grep the doc zone",
    tool: "grep",
    input: { pattern: "Gwrite", path: path.join(root, "share/nvim/lazy") },
    allow: true,
  },
  {
    name: "grep with no path defaults to cwd",
    tool: "grep",
    input: { pattern: "vim.keymap" },
    allow: true,
  },
  // --- blocked ------------------------------------------------------------
  {
    name: "../../ traversal out of the config tree",
    tool: "read",
    input: { path: "../../../secrets.env" },
    allow: false,
  },
  {
    name: "absolute path outside every zone",
    tool: "read",
    input: { path: "/etc/passwd" },
    allow: false,
  },
  {
    name: "symlink inside the config dir pointing out of it",
    tool: "read",
    input: { path: "escape" },
    allow: false,
  },
  {
    name: "write into the read-only doc zone",
    tool: "write",
    input: { path: path.join(root, "share/nvim/lazy/vim-fugitive/doc/fugitive.txt"), content: "pwn" },
    allow: false,
  },
  {
    name: "edit into the read-only doc zone",
    tool: "edit",
    input: { path: path.join(root, "share/nvim/lazy/vim-fugitive/doc/fugitive.txt"), edits: [] },
    allow: false,
  },
  {
    name: "the enclosing dotfiles repo is not the zone",
    tool: "read",
    input: { path: path.join(root, "dotfiles/secrets.env") },
    allow: false,
  },
  {
    name: "a sibling directory sharing the config root's prefix",
    tool: "read",
    input: { path: path.join(root, "dotfiles/nvim/.config/nvim-backup/init.lua") },
    allow: false,
  },
  {
    name: "leading @ does not smuggle a path past the gate",
    tool: "read",
    input: { path: "@/etc/passwd" },
    allow: false,
  },
  {
    name: "bash is refused even if it reaches the hook",
    tool: "bash",
    input: { command: "cat ~/.ssh/id_ed25519" },
    allow: false,
  },
  {
    name: "one bad path in a list blocks the call",
    tool: "read",
    input: { paths: ["init.lua", "/etc/passwd"] },
    allow: false,
  },
];

test("path gate", async (t) => {
  for (const c of CASES()) {
    await t.test(`${c.allow ? "allow" : "block"}: ${c.name}`, async () => {
      const decision = await checkAccess(c.tool, c.input, zones);
      assert.equal(
        decision.allow,
        c.allow,
        c.allow
          ? `expected allow, got block: ${"reason" in decision ? decision.reason : ""}`
          : "expected block, got allow",
      );
      if (!c.allow) {
        assert.ok("reason" in decision && decision.reason.length > 0, "a block must explain itself");
      }
    });
  }
});
