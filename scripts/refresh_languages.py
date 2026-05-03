#!/usr/bin/env python3
"""Refresh src/turbokod/data/languages.json from Helix's languages.toml.

Helix's TOML defines servers in a top-level [language-server] table and
references them by name from each [[language]] block. We flatten that into
the LanguageSpec shape language_config.mojo expects: one record per
language with file extensions and a resolved list of (command, args)
candidates.

Mojo has no TOML parser, so we do the conversion in Python at refresh
time and ship the resulting JSON as a build resource.

Run via ``make update-lsp-list`` (or ``pixi run update-lsp-list``).
"""
from __future__ import annotations

import json
import sys
import tomllib
import urllib.request
from pathlib import Path

HELIX_URL = "https://raw.githubusercontent.com/helix-editor/helix/master/languages.toml"

# Install hints aren't in Helix's TOML. Keep our curated set keyed by
# language_id; languages not listed here get an empty hint, which the
# Mojo side treats as "don't prompt the user to install."
INSTALL_HINTS: dict[str, str] = {
    "python":     "pip install pyright",
    "rust":       "rustup component add rust-analyzer",
    "go":         "go install golang.org/x/tools/gopls@latest",
    "typescript": "npm install -g typescript-language-server typescript",
    "javascript": "npm install -g typescript-language-server typescript",
    "tsx":        "npm install -g typescript-language-server typescript",
    "jsx":        "npm install -g typescript-language-server typescript",
    "c":          "brew install llvm  # or apt install clangd",
    "cpp":        "brew install llvm  # or apt install clangd",
    "zig":        "brew install zls  # or see https://github.com/zigtools/zls",
    "ruby":       "gem install solargraph",
    "json":       "npm install -g vscode-langservers-extracted",
    "yaml":       "npm install -g yaml-language-server",
    "bash":       "npm install -g bash-language-server",
    "elm":        "npm install -g @elm-tooling/elm-language-server",
    "html":       "npm install -g vscode-langservers-extracted",
    "css":        "npm install -g vscode-langservers-extracted",
    "haskell":    "ghcup install hls",
    "lua":        "brew install lua-language-server",
    "elixir":     "mix escript.install hex elixir_ls  # or see github.com/elixir-lsp/elixir-ls",
    "ocaml":      "opam install ocaml-lsp-server",
    "swift":      "ships with the Swift toolchain (sourcekit-lsp)",
    "dart":       "ships with the Dart SDK",
    "kotlin":     "brew install kotlin-language-server",
    "scala":      "coursier install metals",
    "clojure":    "brew install clojure-lsp/brew/clojure-lsp-native",
    "erlang":     "see https://github.com/erlang-ls/erlang_ls",
    "nix":        "nix-env -iA nixpkgs.nil  # or nixd",
    "terraform":  "see https://github.com/hashicorp/terraform-ls",
    "dockerfile": "npm install -g dockerfile-language-server-nodejs",
    "toml":       "cargo install taplo-cli --features lsp",
    "markdown":   "npm install -g marksman  # or see github.com/artempyanykh/marksman",
    "vue":        "npm install -g @vue/language-server",
    "svelte":     "npm install -g svelte-language-server",
    "astro":      "npm install -g @astrojs/language-server",
    "graphql":    "npm install -g graphql-language-service-cli",
    "php":        "npm install -g intelephense",
    "java":       "see https://github.com/eclipse-jdtls/eclipse.jdt.ls",
    "csharp":     "dotnet tool install -g csharp-ls",
}


def fetch_languages_toml() -> bytes:
    print(f"fetching {HELIX_URL} ...", file=sys.stderr)
    with urllib.request.urlopen(HELIX_URL, timeout=30) as resp:
        return resp.read()


def normalize_server_name(entry) -> str | None:
    """``language-servers`` entries are either bare strings or tables
    with a ``name`` key (and optional feature-filter fields we ignore)."""
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        return entry.get("name")
    return None


def normalize_file_types(items) -> list[str]:
    """Helix's ``file-types`` mixes plain extension strings with
    ``{ glob = "..." }`` / ``{ path = "..." }`` tables for shebang-style
    matches. We only support the plain extension form for now."""
    out: list[str] = []
    for it in items or []:
        if isinstance(it, str):
            out.append(it)
    return out


def resolve_candidate(server_table: dict, name: str) -> list[str] | None:
    """Look up a server name in [language-server] and return its argv.

    Helix entries look like ``{ command = "x", args = [...] }``. ``args``
    is optional. Returns None if the server isn't defined (some entries
    in language-servers reference servers that no longer exist in the
    table, e.g. when Helix renames things mid-release)."""
    spec = server_table.get(name)
    if not isinstance(spec, dict):
        return None
    cmd = spec.get("command")
    if not isinstance(cmd, str):
        return None
    argv = [cmd]
    args = spec.get("args")
    if isinstance(args, list):
        for a in args:
            if isinstance(a, str):
                argv.append(a)
    return argv


def build_specs(toml_text: bytes) -> list[dict]:
    data = tomllib.loads(toml_text.decode("utf-8"))
    server_table = data.get("language-server", {})
    languages = data.get("language", [])

    out: list[dict] = []
    for lang in languages:
        lang_id = lang.get("name")
        if not isinstance(lang_id, str):
            continue
        file_types = normalize_file_types(lang.get("file-types"))
        if not file_types:
            continue  # nothing to route by extension — skip

        candidates: list[dict] = []
        for ls_entry in lang.get("language-servers") or []:
            name = normalize_server_name(ls_entry)
            if not name:
                continue
            argv = resolve_candidate(server_table, name)
            if argv is None:
                continue
            candidates.append({"argv": argv})

        if not candidates:
            continue  # no servers — nothing for our LSP layer to spawn

        out.append({
            "language_id": lang_id,
            "file_types": file_types,
            "candidates": candidates,
            "install_hint": INSTALL_HINTS.get(lang_id, ""),
        })

    out.sort(key=lambda s: s["language_id"])
    return out


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    out_path = repo_root / "src" / "turbokod" / "data" / "languages.json"

    if len(sys.argv) > 1 and sys.argv[1].startswith("--from="):
        toml_bytes = Path(sys.argv[1].removeprefix("--from=")).read_bytes()
    else:
        toml_bytes = fetch_languages_toml()

    specs = build_specs(toml_bytes)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(specs, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"wrote {len(specs)} languages → "
        f"{out_path.relative_to(repo_root)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
