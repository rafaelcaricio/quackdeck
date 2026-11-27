# Third-Party Notices

QuackDeck is licensed under the [Apache License, Version 2.0](LICENSE) (`Copyright 2026 Rafael Caricio`).

Compiled distributions of QuackDeck (`QuackDeckCore.xcframework` and the `QuackDeck` iOS application) link against third-party open-source components governed by their respective licenses below.

---

## 1. Pollen Robotics — Microduck Crates (Apache License 2.0)

- **Upstream repository:** https://github.com/pollen-robotics/microduck
- **Copyright:** Copyright Pollen Robotics
- **License:** Apache License, Version 2.0 ([LICENSE](LICENSE))
- **Linked crates:** `duck-auth`, `duck-ble`, `duck-ipc-proto`

### Compliance & Scope Notes

- **Apache-2.0 alignment:** Both QuackDeck and Pollen Robotics' linked Microduck crates are licensed under the Apache License, Version 2.0. The complete license text is provided in `LICENSE` and bundled inside the iOS application.
- **CoreBluetooth compatibility wrapper:** `rust/quackdeck-core/src/adv.rs` normalizes 9-byte Apple-joined BLE manufacturer payloads emitted by boards with BlueZ device privacy disabled before delegating parsing to upstream `duck-ble`.
- **No CC BY-NC-SA 4.0 3D model files:** Pollen Robotics separately licenses 3D `.stl` meshes in `pollen-robotics/microduck_rl` under CC BY-NC-SA 4.0. QuackDeck does **not** include any `.stl` meshes, 3D CAD assets, or trained policy files from Pollen Robotics.
- **Trademarks & non-affiliation (Apache-2.0 §6):** QuackDeck is an independent, unofficial project and is not affiliated with, endorsed by, or sponsored by Pollen Robotics. "Pollen Robotics" and "Microduck" are trademarks/product names of Pollen Robotics used solely to describe compatibility and upstream crate origin.

---

## 2. WebRTC (`stasel/WebRTC` & Google WebRTC — BSD 3-Clause)

- **Upstream repository:** https://github.com/stasel/WebRTC (packaging official Google WebRTC binaries)
- **License:** BSD 3-Clause License ([LICENSES/WebRTC-BSD-3-Clause.txt](LICENSES/WebRTC-BSD-3-Clause.txt))

---

## 3. Rust Dependencies Linked into `quackdeck-core` (`aarch64-apple-ios`)

### Special License & Attribution Notices

#### `curve25519-dalek` (BSD-3-Clause)
Upstream: https://github.com/dalek-cryptography/curve25519-dalek

```text
Copyright (c) 2016-2021 isis agora lovecruft. All rights reserved.
Copyright (c) 2016-2021 Henry de Valence. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Portions of curve25519-dalek were originally derived from Adam Langley's
Go ed25519 implementation, found at <https://github.com/agl/ed25519/>:

Copyright (c) 2012 The Go Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### `subtle` (BSD-3-Clause)
Upstream: https://github.com/dalek-cryptography/subtle

```text
Copyright (c) 2016-2017 Isis Agora Lovecruft, Henry de Valence. All rights reserved.
Copyright (c) 2016-2024 Isis Agora Lovecruft. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### `ring` (Apache-2.0 AND ISC)
Upstream: https://github.com/briansmith/ring

Parts of `ring` sourced from BoringSSL are licensed under Apache License 2.0 (see [LICENSE](LICENSE)) and/or ISC. Original `ring` code is licensed under the ISC license:

```text
Copyright 2015-2025 Brian Smith.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

#### `untrusted` (ISC)
Upstream: https://github.com/briansmith/untrusted

```text
Copyright 2015-2016 Brian Smith.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

### Other Permissively Licensed Rust Crates (MIT / Apache-2.0 / BSD-2-Clause / Unlicense)

| Crate | License |
|---|---|
| `aead`, `aes`, `aes-gcm`, `blake2`, `block-buffer`, `chacha20`, `chacha20poly1305`, `cipher`, `cpufeatures`, `crypto-common`, `ctr`, `digest`, `ghash`, `inout`, `opaque-debug`, `poly1305`, `polyval`, `sha1`, `sha2`, `universal-hash`, `zeroize` | MIT OR Apache-2.0 |
| `base64`, `cfg-if`, `futures-core`, `futures-sink`, `futures-task`, `futures-util`, `getrandom`, `http`, `httparse`, `itoa`, `libc`, `log`, `pin-project-lite`, `ppv-lite86`, `rand`, `rand_chacha`, `rand_core`, `semver`, `serde`, `serde_core`, `serde_json`, `snow`, `socket2`, `thiserror`, `tungstenite`, `typenum`, `utf-8`, `uuid` | MIT OR Apache-2.0 |
| `bytes`, `data-encoding`, `generic-array`, `mio`, `slab`, `tokio`, `tokio-tungstenite`, `zmij` | MIT |
| `memchr` | Unlicense OR MIT |
| `zerocopy` | BSD-2-Clause OR Apache-2.0 OR MIT |
