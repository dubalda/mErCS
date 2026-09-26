#!/usr/bin/env bash
# Checks the repository the way the editor does: formatting (StyLua), lints (selene) and types
# (luau-lsp with the new solver, the Roblox platform and the Roblox type definitions — the
# settings of the VS Code workspace). Prints nothing but tool summaries when everything is
# clean; exits with a non-zero code on the first failing step.
#
# luau-lsp: the server bundled with the VS Code extension when it is installed (the same
# version as the editor's diagnostics), otherwise `luau-lsp` from PATH (rokit.toml).
# Type definitions: the copy the extension downloaded, otherwise tmp/globalTypes.d.luau
# (downloaded once).
#
# jecs comes from the Wally packages: run `wally install` once before the check.
#
# Run from anywhere:
#     bash tools/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

extension_dir=$(ls -d "$HOME"/.vscode/extensions/johnnymorganz.luau-lsp-* 2>/dev/null | sort -V | tail -n 1 || true)
if [ -n "$extension_dir" ] && [ -x "$extension_dir/bin/server.exe" ]; then
    luau_lsp="$extension_dir/bin/server.exe"
elif [ -n "$extension_dir" ] && [ -x "$extension_dir/bin/server" ]; then
    luau_lsp="$extension_dir/bin/server"
else
    luau_lsp=luau-lsp
fi

storage="${APPDATA:-$HOME/.config}/Code/User/globalStorage/johnnymorganz.luau-lsp"
definitions="$storage/globalTypes.PluginSecurity.d.luau"
if [ ! -f "$definitions" ]; then
    definitions=tmp/globalTypes.d.luau
    if [ ! -f "$definitions" ]; then
        mkdir -p tmp
        curl -fsSL https://luau-lsp.pages.dev/type-definitions/globalTypes.PluginSecurity.d.luau -o "$definitions"
    fi
fi

stylua --check .
selene .
echo "luau-lsp: $("$luau_lsp" --version)"
# Wally packages are third-party code: their own diagnostics are not ours to fix
output=$("$luau_lsp" analyze --flag:LuauSolverV2=true --platform roblox --definitions:@roblox="$definitions" \
    --ignore "Packages/**" --ignore "DevPackages/**" \
    src/*.luau test/*.luau test/jecs_compat/*.luau bench/*.luau bench/visual/*.luau examples/*.luau studio/*.luau \
    2>&1 | grep -v '^\[INFO\]' || true)
if [ -n "$output" ]; then
    echo "$output"
    exit 1
fi
echo "luau-lsp: no errors"
