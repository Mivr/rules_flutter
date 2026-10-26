# Pub package assets

How a `flutter.pub` spoke turns a pub package's `flutter.assets` entries
into bundle inputs, matching `flutter_tools` (`asset.dart`, `flutter_manifest.dart`).

## What the bundle keeps

- A file entry (for example `img/logo.png`) bundles the main file plus
  every same-named file in a sibling resolution directory (`img/2.0x/logo.png`,
  `img/3.0x/logo.png`, any directory name flutter_tools accepts as a variant).
  Each variant inherits the entry's `platforms` and `flavors`, and the bundle
  groups the variants under the main key with their `dpr`, as for an app's
  own variants.
- An entry whose main file is absent is accepted as long as a variant exists.
  An entry with neither a main file nor a variant fails the fetch, naming the
  package and the entry.
- A directory entry (for example `assets/icons/`) bundles the directory's own
  files plus each one's variants. Files in deeper subdirectories are not
  bundled.
- Asset walks are bounded; a walk that reaches its bound fails the fetch,
  naming the package and the directory, instead of bundling part of the tree.

## Entry spellings and bundle keys

Every entry kind that names a file (assets in both forms, shaders, font
`asset:`) normalizes through one module (`flutter/private/asset_uri.bzl`),
mirroring flutter_tools 3.47.7: a string-form entry reads as `Uri.parse`
of the entry text, while a map-form (`path:`) asset or shader reads as
`Uri(pathSegments: path.split('/'))` — every byte literal, so a `\` never
separates and a `%XX` never decodes, while dot segments still resolve:

- String-form entries decode `%XX` escapes, resolve `.` and `x/..`, then
  re-encode: `./a.png` bundles `a.png`; `a b.png` bundles as `a%20b.png`,
  the key the engine asks for. Non-ASCII names encode as UTF-8 (`%C3%A9`
  in the key decodes to the file's accented letter). Trailing dot segments
  resolve per RFC 3986 §5.2.4: `assets/.`, `assets/%2E`, `assets/b/..`, `a//.`,
  `a//..`, `a/./.` preserve their directory trailing slash (`is_dir = True`,
  `decoded` and `key` end with `/`), while entries collapsing to no non-empty
  segment (`.`, `./`, `assets/..`, `%2E` in string form) refuse as naming no file,
  and `..` escaping root refuses.
- In string form (`is_map = False`), reserved character escapes (`! $ & ' ( ) * + , ; = @`)
  remain uppercase `%XX` in the bundle key (`norm.key`), while unreserved characters
  decode, matching `Uri.parse(entry).path`. When keyed as a package contribution
  (`packages/<pkg>/...`), bundle keys re-encode from decoded segments (`norm.pkg_key`),
  matching `flutter_tools` (`asset.dart:1428`, `998`).
- Map-form entries read literally: `- path: a%20b.png` bundles the
  `a%20b.png` file (manifest `a%20b.png`, copy `a%2520b.png`), and
  `- path: g/./h.png` bundles `g/h.png`. The entry's shape travels from
  the parser to the normalizer, never guessed from the text.
- Entries whose first segment is `packages` normalize like every other
  entry (`packages/d/./a.png` bundles as `packages/d/a.png`); a reference
  into another package normalizes to itself when plain, and plain entries
  keep exactly their old keys.
- The decoded path names the file (labels, directory walks, resolution
  variants); the encoded key names the copied file, while the manifest
  entry and its variant paths are `Uri.decodeFull` of that key
  (`a%20b.png` copies encoded but manifests as `a b.png`). FontManifest
  keeps the encoded asset, as flutter_tools does. The app's own assets
  key the same way.
- Each entry decodes once: the path-package link plan links the decoded
  files, and the expansion resolves them, carrying the intake key — so
  `pct%25.png` finds the `pct%.png` file keyed `pct%25.png`, never decoding
  twice down to `pct.png`.

Spellings no engine build reads fail the fetch as not supported, naming the
package, its pubspec.yaml and the entry (entry form, without a line number):
query (`?`) and fragment (`#`) parts, absolute paths, literal backslashes,
`..` escaping the package, entries naming no file, escapes decoding to `/`,
invalid UTF-8, and `:` (no Bazel target can name it). A raw backslash in a
string-form entry separates the way `Uri.parse` reads it. An empty segment
stays in the key (`a//b.png` keys with `//`) while the decoded file
collapses (`a/b.png`): the manifest entry is flutter_tools' own (the raw
key, the collapsed path, the collapsed directory's variants, each variant
with the dpr of its own parent directory), no key names an undeclared
file, and the copies read the collapsed file. Two entries giving one file
two bundle keys (`a/b.png` beside `a//b.png`) fail the same way, naming the
empty-segment entry: `pkg_assets` carries one key per file.

## Walk bounds

Every pub spoke directory walk shares one bound, `PUB_WALK_BOUND`
(1000000 directories): asset listing, plugin source detection, and
path-package linking. A walk that reaches it fails the fetch naming the
package, the directory, and the bound, instead of bundling or reporting
part of the tree. Overlay heredoc rewriting fails the same way, naming
the package, the template, and the bound.

## What the fetch refuses

Every refusal fails the spoke fetch with
`flutter.pub spoke for "<package>": pubspec.yaml line <N>: ...`, naming the
package and the 1-based line of the offending key or list entry, so the fix
is one editor jump away. A non-string key names its own line, and a leading
byte-order mark moves no line. Accepted pubspecs parse exactly as before.

- A `flutter:` section that is neither a map nor absent fails the fetch at
  the `flutter:` line, as flutter_tools does.
- A non-string pubspec root key, or a present `name` that is not a string
  (including an empty value), fails the fetch at the key's line, as
  flutter_tools does. Any other root key stays allowed.
- A `flutter.assets` or `flutter.shaders` section that is not a list (for
  example a string `assets: assets/logo.png`) fails the fetch, naming the
  package, the key and the expected list shape, as flutter_tools does.
- An asset or shader list item that is neither a string nor a map, a null
  or empty item, or a map whose `path` is not a string fails the fetch,
  naming the package, the key and the expected shape, as flutter_tools
  does. An empty map item is silently no entry, the way flutter_tools
  reads it.
- A `flutter.fonts` section that is not a list, a font entry that is not a
  map, a non-string `family`, a non-list per-family `fonts`, a font file
  entry that is not a map, or a non-string font file `asset` fails the
  fetch, naming the package, the key and the expected shape, as
  flutter_tools does. A missing `family` stays silently skipped; a file
  entry without an `asset` key stays silent only when its other keys are
  clean, the way flutter_tools only warns on it.
- A font `weight` outside 100..900 (for example `weight: 150`), a font
  `style` outside `italic`/`normal`, or any other key in a font file entry
  fails the fetch at the key's line, as flutter_tools does, whether or not
  the entry carries `asset`. A non-string
  key reports twice, the way flutter_tools reports both its checks. An
  absent `weight` or `style` stays valid and reads as unset.
- A whole-number float font `weight` (for example `weight: 400.0`) on an
  entry carrying `asset` fails
  the fetch at the key's line: it passes flutter_tools' validation, but
  no build can read it, so the refusal says flutter_tools 3.47.7 cannot
  read it instead of quoting a validation error flutter_tools never prints.
  Without `asset` the build skips the entry before any cast, so the weight
  stays silent there.
- An unexpected key in a font family entry fails the fetch at the key's
  line, as flutter_tools does.
- A `platforms` or `flavors` value that is not a list of strings (for example
  a scalar `platforms: web`), or a `platforms` value naming an unknown
  platform (for example `platforms: [tvos]`), fails the fetch, naming the package, the entry
  and the key, as flutter_tools does. The check is shared by `assets` and
  `shaders` entries, the way flutter_tools validates both with one function.
- An asset, shader, or deferred-component entry with `transformers` that is
  absent, `null`, or an empty list (`[]`) is accepted as a valid no-op, matching
  `flutter_tools`. A non-list `transformers` value, or a list containing any
  non-map element, fails the fetch with the `flutter_tools` section error. A
  non-empty list of transformer maps fails the fetch: asset transformers are not
  supported by rules_flutter.
- Any other unknown key in an entry mapping is ignored, the way flutter_tools
  ignores it.
- A `uses-material-design` value that is not a bool (for example the string
  `"yes"`, or an empty value) fails the fetch at its line instead of
  silently reading as false, as flutter_tools does.
- A `licenses` value that is not a list of file paths, a `default-flavor`
  value that is not a string, and the moved `disable-swift-package-manager`
  key at any value each fail the fetch at their line, as flutter_tools
  does.
- A `module` value that is not a map, or a non-bool `androidX`, a
  non-string `androidPackage`, or a non-string `iosBundleIdentifier` when
  set, fails the fetch at its line, as flutter_tools does.
- A `plugin` value that is not a map (including an empty map), legacy
  `androidPackage`/`iosPrefix`/`pluginClass` keys beside `platforms`, a
  `platforms` value that is not a map, or a platform entry flutter_tools
  rejects (for example an empty `android:` entry, or a non-identifier
  `pluginClass`) fails the fetch at the entry's line, as flutter_tools
  does. `web` entries, unknown platforms, and `default_package` entries are
  not validated, the way flutter_tools skips them.
- A `deferred-components` value that is not a list, an empty list
  (flutter_tools crashes reading one, so it cannot build), an element
  that is not a map, an element without a string `name`, a `libraries`
  key holding anything but a string list, or malformed element `assets`
  each fail the fetch at their line, as flutter_tools does. An absent or
  empty value stays valid.
- A non-string key directly under `flutter:` fails the fetch at the key's
  line, as flutter_tools does. Any other unknown key directly under
  `flutter:` fails the fetch at the key's line, as flutter_tools does.
  `generate` and `config` carry no checks and stay accepted at any value.
