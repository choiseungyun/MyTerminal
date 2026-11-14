# Third-Party Notices

MyTerminal includes or links the following third-party software. Each component is
used under its own license, reproduced or referenced below.

## Ghostty (libghostty)

- Source: https://github.com/ghostty-org/ghostty (git submodule `vendor/ghostty`, v1.4.0)
- License: MIT
- Used as the terminal engine (GhosttyKit). Parts of `Sources/GhosttyAdapter` follow the
  structure of Ghostty's macOS app and say so in their headers.
- "Ghostty" is a name of the Ghostty project. MyTerminal is not affiliated with or endorsed
  by the Ghostty project.

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

libghostty itself bundles further libraries and assets. The ones shipped inside the
MyTerminal app are listed below; for the complete list see the Ghostty source tree
(`vendor/ghostty`, including `src/font/res/README.md`).

### Fonts embedded in libghostty

| Font | License | Copyright |
| --- | --- | --- |
| JetBrains Mono | SIL Open Font License 1.1 | Copyright 2020 The JetBrains Mono Project Authors |
| Symbols Nerd Font | MIT (Nerd Fonts); glyphs come from icon sets under their own licenses, see https://github.com/ryanoasis/nerd-fonts/blob/master/LICENSE | Copyright (c) 2014 Ryan L McIntyre |
| Noto Color Emoji, Noto Emoji | SIL Open Font License 1.1 | Copyright 2013 Google LLC |
| Kawkab Mono | SIL Open Font License 1.1 | Copyright (c) 2015, Abdullah Arif; Copyright 2010, 2012, 2014 Adobe Systems Incorporated |

The full text of the SIL Open Font License 1.1 is in `vendor/ghostty/src/font/res/OFL.txt`
and at https://openfontlicense.org.

### Color themes

The theme files copied into the app (`Contents/Resources/ghostty/themes`) come from
iTerm2-Color-Schemes (https://github.com/mbadolato/iTerm2-Color-Schemes), MIT License,
Copyright (c) 2011 Mark Badolato, distributed through the Ghostty project.

## GRDB.swift

- Source: https://github.com/groue/GRDB.swift (Swift Package, 7.x)
- License: MIT, Copyright (C) 2015-2025 Gwendal Roué
- Used for the local SQLite database (hosts, connection history).

## Apple system components

MyTerminal uses the system OpenSSH client (`/usr/bin/ssh`) at run time. It is not
bundled with the app.
