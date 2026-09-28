# Third-party notices

## GPL factory decoder: xdripswift

The factory calculation, exact 1023-entry t1/t2 tables, and FRAM coefficient
extraction in this package are derived from xdripswift contributors:

- Repository: https://github.com/JohanDegraeve/xdripswift
- Pinned revision: `53b3d6bf1b550c99b19c3d5d2c2f80dd226465d8`
- Source: `xDrip/BluetoothTransmitter/CGM/Libre/Utilities/LibreMeasurement.swift`
  (Git blob `1b40a6f5d9ed8a674f186541cdc75c128263f02f`)
- Source: `xDrip/BluetoothTransmitter/CGM/Libre/Utilities/LibreCalibrationInfo.swift`
  (Git blob `ac982bfe60361fd4e0de12cbb931a0f748338a3a`)
- License: repository `LICENSE`, GNU General Public License version 3,
  Git blob `f288702d2fa16d3cdf0035b15a9fcbc552cd88e7`. The full license is
  included in this package's `LICENSE`.
- Neither source file has a separate per-file license or copyright notice at
  that revision. The original source text is preserved under
  `test/reference/` (trailing whitespace normalized).

This package is GPL-3.0-only. The port was made on 2026-09-05 by OpenGlucose
contributors. Changes: pure Dart types, checked encrypted input boundary,
closed error/quality states, lifecycle/age/domain rejection, no legacy default
slope, no smoothing, and synthetic tests. The exact factory formula and table
literals are retained. This work comes with NO WARRANTY, including no warranty
of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE.

The copied Swift reference files and reference harness are also GPL-covered.
The Dart test encryption helper uses the independently MIT-licensed Gen1
primitive from cgm_libre2; its upstream notices are retained below.

## OpenGlucose MIT helper source

The private analysis tool's descriptor-read and strict FRAM-schema helpers,
and the synthetic encryption helper, derive from separately MIT-licensed
OpenGlucose source. This notice remains applicable to those original portions.

MIT License

Copyright (c) 2026 OpenGlucose contributors

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

## Separate MIT origins

The BLE record layout, sparse sample minute offsets, sensor age/max-life byte
positions and quality-field handling follow the non-factory portions of
DiaBLE at the revision below, specifically `DiaBLE/Libre2.swift` parseBLEData
and `DiaBLE/Libre.swift` parseFRAM. The factory calculation is **not** treated
as MIT merely because DiaBLE's root license is MIT: DiaBLE's Glucose.swift
attributes that calculation to GPL xdripswift. This package instead uses the
GPL original with its license.

Dependency cgm_libre2 remains under its own MIT license. Existing repository
files are not relicensed by this package. A combined application that includes
this package requires a separate distribution/license compatibility review;
putting the code in a separate Dart package does not remove GPL obligations.
No closed-source SDK, manufacturer binary, private health fixture, or GPL code
has been inserted into cgm_libre2 by this change.

## LibreTools

Source revision:
`d54b0883959420e5941ed293ec6b9ef2474b7ed3`

MIT License

Copyright (c) 2020 Ivan Valkou

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

## Dart crypto

Package version: `3.0.7`

Copyright 2015, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of Google LLC nor the names of its contributors may be used
  to endorse or promote products derived from this software without specific
  prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Dart ffi

Package version: `2.2.0`

Copyright 2019, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
- Neither the name of Google LLC nor the names of its contributors may be used
  to endorse or promote products derived from this software without specific
  prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## DiaBLE

Source revision:
`e6a909c88faeada49f461d30834174cd95db4042`

MIT License

Copyright (c) 2026 Guido Soranzio

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
