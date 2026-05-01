# Bundled TextMate grammars

These `.tmLanguage.json` files drive the syntax-highlighting runtime in
`tm_grammar.mojo` + `tm_tokenizer.mojo`. Each grammar is data — the
runtime is in `src/turbokod/`. Adding a new language is one entry in
`_grammar_path_for_ext` (in `highlight.mojo`) plus a JSON drop here.

## Sources and licenses

All grammars in this directory are derivatives of upstream TextMate
grammars maintained under permissive licenses (MIT, Apache-2.0, or
similar). The `information_for_contributors` field at the top of each
JSON file points at the canonical upstream — fixes should land there
first.

| File                    | Upstream                                                                 | License                |
| ----------------------- | ------------------------------------------------------------------------ | ---------------------- |
| `cpp.tmLanguage.json`   | `microsoft/vscode/extensions/cpp` (in turn `jeff-hykin/cpp-textmate-...`) | MIT                    |
| `css.tmLanguage.json`   | `microsoft/vscode/extensions/css`                                        | MIT                    |
| `go.tmLanguage.json`    | `microsoft/vscode/extensions/go` (originally `worlpaker/go-syntax`)       | MIT                    |
| `html.tmLanguage.json`  | `microsoft/vscode/extensions/html`                                       | MIT                    |
| `javascript.tmLanguage.json` | `microsoft/vscode/extensions/javascript`                            | MIT                    |
| `json.tmLanguage.json`  | `microsoft/vscode-JSON.tmLanguage`                                       | MIT                    |
| `markdown.tmLanguage.json` | `microsoft/vscode/extensions/markdown-basics`                         | MIT                    |
| `ruby.tmLanguage.json`  | `microsoft/vscode/extensions/ruby`                                       | MIT                    |
| `rust.tmLanguage.json`  | `dustypomerleau/rust-syntax` (via `microsoft/vscode/extensions/rust`)    | MIT                    |
| `shell.tmLanguage.json` | `microsoft/vscode/extensions/shellscript`                                | MIT                    |
| `typescript.tmLanguage.json` | `microsoft/vscode/extensions/typescript-basics`                     | MIT                    |
| `yaml.tmLanguage.json`  | `microsoft/vscode/extensions/yaml`                                       | MIT                    |

## Runtime caveats

The bundled tokenizer covers the common case but isn't a drop-in for
`vscode-textmate`. Notable gaps that may degrade coloring on some
grammars (always to "less colored", never to "broken"):

* **Injections** (`injectionSelector` / `injections`) are not
  consulted.
* **No per-instance `OnigRegex.__del__`** — handles aren't freed
  when the wrapping struct goes out of scope. Cleanup batches at
  process exit via the C shim (`onig_shim.c` + the
  `__attribute__((destructor))` it carries), so leak detectors
  stay quiet but the in-session footprint is bounded by
  `HighlightCache`'s grammar reuse rather than by RAII.

What *is* supported:

* `match` / `begin` / `end` / `patterns` / `include` (`#name`,
  `$self`, *and* external-scope refs like `source.css`).
* `begin` / `while` rules — the line-start regex must match for
  the scope to remain open. Used by Markdown blockquotes, fenced
  code blocks, YAML's block scalars.
* Repository-entry "groups" — bare `{ "patterns": [...] }`
  containers with no top-level `match`/`begin`/`include`.
* Capture-group → scope mapping via `captures`, `beginCaptures`,
  `endCaptures`, `whileCaptures`. Each group's bytes get a
  refining scope overlay on top of the outer match's color.
* Capture-group **`patterns`** — re-tokenize the captured byte
  range against a list of patterns ("mini-tokenize inside the
  group").
* Embedded grammar references via external-scope `include`
  targets. The loader recursively pulls in known scope-name
  grammars (mapped in `_path_for_scope`), prefix-namespaces
  their repo entries as `"<scope>#<name>"` to avoid host
  collisions, and rewrites embedded `#name` / `$self` refs at
  compile time so they resolve through the namespaced keys. The
  tokenizer routes through `external_scopes` at match time.
* `\G` anchor handling — `(?!\G)`-gated state-transition begins
  fire correctly on fresh lines (HTML's `<style>` / `<script>`
  embeds rely on this). Tracked per-line via `g_pos` and
  `ONIG_OPTION_NOT_BEGIN_POSITION`.
* Defensive regex compile — patterns whose regex libonig won't
  accept get downgraded to no-ops instead of crashing the whole
  grammar load.
