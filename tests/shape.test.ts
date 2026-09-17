// Plugin or config, by tree shape (tools/plugin-index/shape.ts). The trees are
// real ones, trimmed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { isConfig } from "../tools/plugin-index/shape.ts";

const shape = (nameWithOwner: string, top: string[] | null, hasLua = top?.includes("lua") ?? false) => ({
  nameWithOwner,
  top,
  hasLua,
});

test("a whole $HOME of tool directories is dotfiles", () => {
  assert.ok(isConfig(shape("xero/dotfiles", ["README.md", "bash", "bin", "git", "neovim", "zsh"])));
  assert.ok(isConfig(shape("numToStr/dotfiles", ["Makefile", "README.md", "alacritty", "kitty", "neovim", "scripts"])));
  assert.ok(isConfig(shape("mokevnin/dotfiles", [".gitconfig", "README.md", "mise.toml", "nvim", "starship.toml", "zsh"])));
});

test("an nvim directory at the root of a lua-less repo is a config one level down", () => {
  assert.ok(isConfig(shape("brainfucksec/neovim-lua", [".gitignore", "LICENSE", "README.md", "img", "nvim"])));
  assert.ok(isConfig(shape("hayyaoe/zenities", [".config", ".tmux.conf", "INSTALL.sh", "README.md"])));
});

test("an init.lua at the root is a config, whatever sits beside it", () => {
  assert.ok(isConfig(shape("optimizacija/neovim-config", [".gitignore", "README.md", "assets", "init.lua", "lua"])));
  assert.ok(isConfig(shape("rafi/vim-config", ["Makefile", "README.md", "after", "init.lua", "lazy-lock.json", "lua"])));
  assert.ok(isConfig(shape("theniceboy/nvim", ["README.md", "autoload", "ftplugin", "init.vim", "snippets"])));
  assert.ok(isConfig(shape("jdhao/nvim-config", ["README.md", "after", "autoload", "init.lua", "lua", "plugin"])));
});

test("names that only ever mean a config need no tree", () => {
  assert.ok(isConfig(shape("someone/dotfiles", null)));
  assert.ok(isConfig(shape("someone/.dotfiles", null)));
  assert.ok(isConfig(shape("figsoda/cfg", null)));
  assert.ok(isConfig(shape("budimanjojo/nix-config", null)));
  assert.ok(isConfig(shape("shaunsingh/nix-darwin-dotfiles", null)));
});

test("a plugin with any runtimepath directory is a plugin", () => {
  assert.ok(!isConfig(shape("rose-pine/neovim", [".github", "LICENSE", "README.md", "colors", "lua"])));
  assert.ok(!isConfig(shape("z4p5a9/blamer.nvim", ["LICENSE", "README.md", "autoload", "plugin"])));
  assert.ok(!isConfig(shape("numirias/semshi", ["README.md", "plugin", "rplugin", "setup.py"])));
  assert.ok(!isConfig(shape("alker0/chezmoi.vim", ["README.md", "after", "autoload", "syntax"])));
});

test("a lua-only plugin with no runtime directory is still a plugin", () => {
  assert.ok(!isConfig(shape("junnplus/lsp-setup.nvim", [".github", "LICENSE", "README.md", "lua"])));
  assert.ok(!isConfig(shape("NvChad/NvChad", [".stylua.toml", "LICENSE", "README.md", "lua"])));
});

test("a repository with nothing but a README is not a config", () => {
  assert.ok(!isConfig(shape("ggandor/leap.nvim", ["LICENSE.md", "README.md"])));
  assert.ok(!isConfig(shape("MordechaiHadad/bob", ["Cargo.toml", "README.md", "bin"])));
});

test("no tree means no verdict", () => {
  assert.ok(!isConfig(shape("someone/plugin.nvim", null)));
});

test("the nvim directory check does not fire on a repo that also has lua/", () => {
  assert.ok(!isConfig(shape("someone/thing.nvim", ["README.md", "lua", "nvim"], true)));
});
