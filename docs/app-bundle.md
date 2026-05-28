# `.app` bundle layout

The macOS .app needs the Mojo shared library reachable from any launch CWD. Dock launches start at `/`, not the project root; an `install_name` that's CWD-relative crashes with `dyld: Library not loaded`.

`run_swift.sh` handles this with the standard macOS three-piece pattern. Get it right once and it never bites again.

## Layout

```
.build/TurboKod.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── TurboKod                 # Swift binary
│   ├── Frameworks/
│   │   └── libturbokod.dylib        # Mojo shared lib
│   └── Resources/
│       ├── icon.icns
│       ├── Px437_IBM_VGA_8x16.ttf
│       └── src/turbokod/
│           ├── grammars/            # TextMate grammars
│           └── data/                # dictionaries etc.
```

## Three pieces that make it portable

### 1. Dylib install_name

Set unconditionally on every `run_swift.sh` invocation (idempotent, cheap), *outside* the rebuild-if-stale guard:

```sh
install_name_tool -id "@rpath/libturbokod.dylib" "$dylib"
```

Why outside the rebuild guard: an interrupted earlier build (`mojo build` ran but the script was killed before `install_name_tool`) leaves the install_name as Mojo's default `.build/libturbokod.dylib`, and the cached-rebuild path would never go back to fix it. Self-heals on the next run this way.

### 2. Swift binary rpaths

```sh
-Xlinker -rpath -Xlinker "@executable_path/../Frameworks"   # for libturbokod
-Xlinker -rpath -Xlinker "${env_prefix}/lib"                # for Mojo runtime + libonig
```

The first rpath is bundle-relative so the .app is location-independent. The second is the pixi env, where the Mojo runtime + libonig live — those aren't bundle-relocatable, so an absolute rpath is correct.

### 3. Bundle assembly

```sh
cp "$dylib" "$contents/Frameworks/libturbokod.dylib"
```

Drops the dylib into the canonical macOS location. `@executable_path/../Frameworks/libturbokod.dylib` resolves there regardless of how the .app was launched or where it was moved to.

## Verifying

```sh
$ otool -L .build/TurboKod.app/Contents/MacOS/TurboKod | grep turbokod
	@rpath/libturbokod.dylib (compatibility version 0.0.0, current version 0.0.0)

$ otool -l .build/TurboKod.app/Contents/MacOS/TurboKod | grep -A 2 LC_RPATH
          cmd LC_RPATH
         path /usr/lib/swift
          cmd LC_RPATH
         path @executable_path/../Frameworks
          cmd LC_RPATH
         path /Users/boxed/Projects/turbokod/.pixi/envs/default/lib
```

If you see a CWD-relative path like `.build/libturbokod.dylib` instead of `@rpath/libturbokod.dylib`, the install_name didn't get stamped — re-run `run_swift.sh`.

## Resource resolution (the Mojo side)

`run_swift.sh` copies `src/turbokod/grammars/` + `src/turbokod/data/` into `Contents/Resources/src/turbokod/`. The app `chdir`s to `Resources/` on launch (`chdirToResourceRoot` in `TurboKod.swift`), so the Mojo side's relative paths (`src/turbokod/grammars/...`) resolve regardless of how the app was launched (Dock, moved .app, no repo present). Nothing else depends on cwd — git uses `git -C <root>`, LSP saves/restores cwd around its own chdir, file opens are absolute.

## What's not bundled

The pixi env dylibs (`libKGENCompilerRTShared`, `libonig`, etc.) are still loaded from absolute paths on this machine. The .app is portable across launch contexts but **not across machines** — fully self-contained distribution would mean bundling those too, which we don't do.
