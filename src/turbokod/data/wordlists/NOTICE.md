# Bundled wordlists

`english.txt` is a general English dictionary (see "English" below). The other
`.txt` files are vendored from
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

## English

`english.txt` is [SCOWL](http://wordlist.aspell.net/) 2020.12.07, American
English at size 60 (the size Hunspell's `en_US` is built from), with possessive
`'s` forms dropped because the spell checker strips `'s` itself. It exists
because macOS's `/usr/share/dict/words` is Webster's 2nd International (1934):
no inflected forms (`applies`, `queries`, `planned`, `held`, `paid`) and no
modern vocabulary (`downtime`, `checklist`, `standalone`, `troubleshooting`).
Regenerate with:

```sh
curl -fsSLO https://downloads.sourceforge.net/wordlist/scowl-2020.12.07.tar.gz
tar xzf scowl-2020.12.07.tar.gz && cd scowl-2020.12.07
./mk-list english american 60 | iconv -f iso-8859-1 -t utf-8 \
    | grep -v "'s$" | LC_ALL=C sort -u
```

SCOWL's license:

> Copyright 2000-2018 by Kevin Atkinson
>
> Permission to use, copy, modify, distribute and sell these word lists, the
> associated scripts, the output created from the scripts, and its
> documentation for any purpose is hereby granted without fee, provided that
> the above copyright notice appears in all copies and that both that
> copyright notice and this permission notice appear in supporting
> documentation. Kevin Atkinson makes no representations about the
> suitability of this array for any purpose. It is provided "as is" without
> express or implied warranty.

The full SCOWL `Copyright` file credits further public-domain and
permissively-licensed sources (Moby Words, 12Dicts, ENABLE, and others).
