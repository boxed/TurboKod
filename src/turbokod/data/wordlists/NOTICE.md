# Bundled wordlists

These `.txt` files are vendored from
[`streetsidesoftware/cspell-dicts`](https://github.com/streetsidesoftware/cspell-dicts)
to give the spell checker programmer-vocabulary coverage on top of the OS
`/usr/share/dict/words` list. Each line is a single word (`#`-prefixed lines are
comments). Some entries are camelCase (e.g. `baseAddress`); the editor only
spell-checks pure-letter runs so those are effectively dead weight, but we
preserve the upstream files unmodified.

## License

cspell-dicts is MIT-licensed:

> The MIT License (MIT)
>
> Copyright (c) 2017-2025 Street Side Software <support@streetsidesoftware.nl>
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

## Sources

| File                | Upstream path                                                          |
| ------------------- | ---------------------------------------------------------------------- |
| `software-terms.txt`| concat of `dictionaries/software-terms/dict/{softwareTerms,software-tools,computing-acronyms,networkingTerms,webServices,coding-compound-terms}.txt` |
| `python.txt`        | `dictionaries/python/dict/python-common.txt`                           |
| `rust.txt`          | `dictionaries/rust/dict/rust.txt`                                      |
| `go.txt`            | `dictionaries/golang/dict/go.txt`                                      |
| `typescript.txt`    | `dictionaries/typescript/dict/typescript.txt`                          |
| `cpp.txt`           | `dictionaries/cpp/dict/cpp-refined.txt`                                |
| `csharp.txt`        | `dictionaries/csharp/dict/csharp.txt`                                  |
| `ruby.txt`          | `dictionaries/ruby/dict/ruby.txt`                                      |
| `swift.txt`         | `dictionaries/swift/src/swift.txt`                                     |
| `kotlin.txt`        | `dictionaries/kotlin/dict/kotlin.txt`                                  |
| `bash.txt`          | `dictionaries/shell/dict/shell-all-words.txt`                          |
| `css.txt`           | `dictionaries/css/dict/css.txt`                                        |
| `html.txt`          | `dictionaries/html/dict/html.txt`                                      |
| `git.txt`           | `dictionaries/git/dict/git-terms.txt`                                  |
| `docker.txt`        | `dictionaries/docker/dict/docker-words.txt`                            |
| `k8s.txt`           | `dictionaries/k8s/dict/k8s.txt`                                        |
