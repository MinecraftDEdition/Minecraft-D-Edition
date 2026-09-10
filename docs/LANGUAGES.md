# Language selection and resource packs

Open **Options → Language** to select a language. The list includes the bundled
language files and additional languages supplied by active packs; an asterisk
marks languages supplied by the highest-priority language pack. Done returns to
Options. Selecting a language reloads rendering resources, which can pause the
game briefly.

On first use, Windows reads the current user's locale. macOS reads the first
preferred language in AppleLanguages, with locale-environment fallback. Exact
language/region matches are preferred, followed by a matching language family,
then US English (or an available pack language). This uses OS settings, not IP
geolocation. A saved manual choice overrides automatic selection. Automatic
clears the manual choice for the current pack combination.

Choices are stored in `data/languages.json` under the normal user-data directory
and excluded from update packages. Default has its own choice. Each ordered pack
combination containing language files has a separate remembered choice. Enabling
a new combination prefers the base language if the top language pack supplies it,
otherwise its English translation or first available language. Players can select
any listed language afterward, including languages that pack does not supply.
Removing packs or returning to a previous combination restores that combination's
choice. Texture-only combinations use the Default language preference.

## Translation resolution

- Accept `assets/<namespace>/lang/<code>.json` and older `.lang` files.
- Read JSON string values and `.lang` key=value lines; comments start with `#`.
- Normalize language codes for matching (`en-US` / `en_US` → `en_us`).
- Load English fallback first, then the selected language, merging each key from
  lower-priority to higher-priority packs. Missing entries keep their fallback.
- Prefer JSON over `.lang` within a pack. Read language names from translation
  metadata and from the `language` section of `pack.mcmeta`.
- Respect resource filters when merging lower-priority language files. Individual
  language files are limited to 8 MiB; pack discovery lists up to 512 languages.
- Translate common legacy item/block keys, including material/tool and wood/color
  families, into the current key names. This is an adapter, not an exhaustive
  migration of every historical key.

Minecraft's use of translation keys and language files is documented by
[Fabric](https://docs.fabricmc.net/develop/text-and-translations); selected-language
fallback to US English is documented by
[NeoForge](https://github.com/neoforged/Documentation/blob/main/docs/resources/client/i18n.md).
The automatic selection of a pack language and separate remembered pack choices
are D Edition behavior requested for this implementation, not a claim about
Minecraft's default behavior.

## Rendering and coverage

Menu labels use translation keys. Inventory search, item tooltips and held-item
labels use localized display names without changing internal item IDs, texture
names, save data or multiplayer identifiers. Remaining D Edition-specific labels
and messages retain their English fallback; packs can override explicitly exposed
`minecraft_d.*` keys. Numeric/unit formatting and every game-specific message are
not yet fully localized.

Text is decoded as Unicode rather than individual UTF-8 bytes. A shared GPU atlas
combines the ASCII font with the existing Unicode bitmap pages needed for the
language and language list. This works with both renderers. Hebrew/Arabic ordering
and Arabic presentation forms use the OS ICU library when available; missing ICU
falls back to logical text. Windows ICU availability is documented by
[Microsoft](https://learn.microsoft.com/en-us/windows/win32/intl/international-components-for-unicode--icu-),
and the ordering/shaping operations by
[ICU](https://unicode-org.github.io/icu/userguide/transforms/bidi.html).

This is not a full implementation of Java's font-provider system. Glyphs outside
the loaded BMP bitmap coverage use a question-mark fallback; complex-script
ligatures/combining-mark positioning and fully bidirectional text editing still
need further work. Font-provider JSON, arbitrary TTF fonts and emoji are not added
by this change.

## Checks

`tests/languages_smoke.d` checks system-locale fallback, saved manual overrides,
pack auto-selection, restoration across combinations, JSON/legacy precedence and
legacy item keys. The resource-pack smoke scripts run it on Windows and macOS.
Font unit tests cover Unicode measurement/wrapping, and text-layout tests cover
Hebrew reordering on Windows. GPU menu checks cover real resource-pack loading;
the Mac script additionally renders Chinese and Arabic selections through MoltenVK.
