# ISO gain-map JPEG writer fixtures

Fixed 8 x 8 libjpeg-turbo primary and recovery streams. The primary retains its ICC/Exif APP segments; recovery inputs have no APP segments. `mono.jpg` and `rgb.jpg` are the byte-exact assembly goldens for the metadata in `gain_map_jpeg_test.cpp`. The RGB case has distinct per-channel ranges, gamma and offsets. JPEG ISO payloads omit the single HEIF ToneMapImage version byte.

Generated during E4 on 2026-10-18; the checked-in input bytes, rather than a fresh codec run or clock, define these container tests.

SHA-256:

- `mono-gain.jpg`: `81925c3e5486c72a1963a120948d87adb007b5856906157d5ca0765b9c9dc006`
- `mono.jpg`: `2cda2e905dc8de4295011a925d3d9088d1d56f014c38df251ba0d5326ce4772c`
- `primary.jpg`: `bed9492353c724dc6a3e7889c8a67a68f6c3edc591bb83f04374617558da0eea`
- `rgb-gain.jpg`: `e974c4f908187328a10b65a9570985a54e3455edf10d4c3a4f33e4ef48a8dd5d`
- `rgb.jpg`: `3db3df0851059d4320761b95f7ef01e312280a64adfec1f52443f960e69643b3`
