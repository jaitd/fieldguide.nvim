// Plugin or config? The topic sweep returns anyone's config tagged `nvim`.
// Decided by the shape of the tree: a plugin has runtimepath directories or a
// lua/ tree; a config has an init.lua at the root, or other tools' directories
// beside an nvim/ one. Curated repos are exempt (the distributions).

/** Any one of these makes a plugin. */
const RUNTIME_DIRS = new Set([
  "plugin", "doc", "colors", "autoload", "ftplugin", "ftdetect", "syntax", "indent",
  "after", "queries", "lsp", "compiler", "rplugin",
]);

/** Any one of these makes a config. */
const CONFIG_FILES = new Set(["init.lua", "init.vim", "lazy-lock.json", ".vimrc", "vimrc", ".nvimrc"]);

/** Two or more of these, with nothing plugin-shaped, is a dotfiles repo. */
const OTHER_TOOLS = new Set([
  ".config", "nvim", ".vim", "vim", "zsh", ".zshrc", "bash", ".bashrc", "fish", "tmux", ".tmux.conf",
  "kitty", "alacritty", "wezterm", "ghostty", "foot", "hypr", "hyprland", "i3", "sway", "waybar",
  "polybar", "bspwm", "sxhkd", "rofi", "dunst", "picom", "starship.toml", "git", ".gitconfig",
  "Brewfile", "flake.nix", "home.nix", "home-manager", "nixos", "nix", "chezmoi", ".chezmoi.toml",
  "stow", "install.sh", "bootstrap.sh", "setup.sh", "wallpapers", "fonts", "scripts",
]);

/** Names that mean a config regardless of tree. */
const CONFIG_NAMES = /^(\.?dot-?files?|\.?dots?|\.?config|cfg|rc|nix-?config|nix-?darwin.*|home-?manager.*|dotfiles[-_.].+|.+[-_.]dotfiles)$/i;

/** Distributions shaped like a config and not on awesome-neovim. */
const DISTRIBUTIONS = new Set(["nyoom-engineering/nyoom.nvim"]);

export type Shape = {
  nameWithOwner: string;
  /** Top-level tree entries, or null when GitHub did not return a tree. */
  top: string[] | null;
  /** Whether lua/ exists and has entries. */
  hasLua: boolean;
};

/** True for a config rather than a plugin. The caller exempts curated repos. */
export function isConfig(shape: Shape): boolean {
  if (DISTRIBUTIONS.has(shape.nameWithOwner)) return false;
  const name = shape.nameWithOwner.split("/")[1] ?? "";
  if (CONFIG_NAMES.test(name)) return true;
  if (shape.top === null) return false;

  const top = new Set(shape.top);
  let runtime = 0;
  let configFiles = 0;
  let tools = 0;
  for (const entry of top) {
    if (RUNTIME_DIRS.has(entry)) runtime++;
    if (CONFIG_FILES.has(entry)) configFiles++;
    if (OTHER_TOOLS.has(entry)) tools++;
  }

  // A root init.lua decides on its own: configs carry after/ and ftplugin/ too.
  if (configFiles > 0) return true;
  const pluginShaped = runtime > 0 || shape.hasLua;
  if (tools >= 2 && !pluginShaped) return true;
  // nvim/ or .config/ at the root: the editor config is one level down.
  if ((top.has("nvim") || top.has(".config")) && !pluginShaped) return true;
  return false;
}
