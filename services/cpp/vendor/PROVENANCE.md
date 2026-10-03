# Vendored dependency provenance

Pinned third-party sources for the Phase 4 C++ service. Every file is fetched
from its upstream release and hash-pinned here.

| file | bytes | sha256 |
| --- | --- | --- |
| vendor/PROVENANCE.md | 2212 | 12fd2d1accd33f4cc5d92605b2eb8db27ceb197a24aceff3d5511b64cd5bf9ad |
| vendor/argon2/LICENSE | 17879 | 220f8736a89ff51c92ef3d497f413b48e6cf1df3d6278bc909c6308c78e1718e |
| vendor/argon2/argon2.c | 14471 | 72a93deebc5fd76bec0c6d300a2d92b500fb354b26babbddbc6d8b88681e663d |
| vendor/argon2/argon2.h | 16767 | df20cb726a2fe6bccc736b81ea0d86219766a0d17f1794c19e048a34830ca1cc |
| vendor/argon2/bench.c | 3339 | c4a4e90ceca31b921be4c863c2457c38325ee67fd9e063cd61ce90f66a78e3f1 |
| vendor/argon2/blake2-impl.h | 4088 | 8ac91f1f57d94235f8de0069b7809be1deb365c3b37adb8e30423cd364aff09a |
| vendor/argon2/blake2.h | 2865 | 3c2de197dd23179f78c57deac7b73a6049778bf651c5db57e508b2cfce5e7559 |
| vendor/argon2/blake2b.c | 12510 | 52519ccbc1e48f489ff444091f630d05dadcc8f1ee61c5b7361e3a9618299c9a |
| vendor/argon2/core.c | 19800 | 0f53eb2370f8971f04fcf043b8083bf81d1530c48b2ead71c0b6c4e22a01aeec |
| vendor/argon2/core.h | 8453 | c9665623cb3d306f63b6a3effd87bcfab971c28253c77e111445e42c1523235e |
| vendor/argon2/encoding.c | 16267 | e20124ec0f780f88527e79cf00825e839624ed1f469c7e231596bf070f8c7b14 |
| vendor/argon2/encoding.h | 2089 | 42f283d12ec445cfb423ac2f1f5a5d1a7f152ce2b9363f6ec3e1d5b61cd4ee6d |
| vendor/argon2/genkat.c | 5795 | 1a92cbf87ba1390f562ffb2e945a1132130c6ea682beaaa817177618166bd3ab |
| vendor/argon2/genkat.h | 1677 | d3a2861d057d5cf19cbb11911d61724b2803fd997f2600bb17c9399f52a8fdf6 |
| vendor/argon2/opt.c | 10179 | cbebf3245500fd19461cbd475ba6d44b3145538866bdf74091114af471faef74 |
| vendor/argon2/ref.c | 7283 | 4ec47b080c22f4ee416b9dbcfae70ee6007fcfba427f870d7b84395846fa1bc7 |
| vendor/argon2/run.c | 10565 | 7d8101cb5a16b3ba7794b2c7472ba6936ca6e259dd13658ca16a385517bc5e65 |
| vendor/argon2/test.c | 13750 | 6a8eb32be02dcb8dc9651fd74e5bc2e0e3ce69cf11f7dc6cea78638aaffbeb05 |
| vendor/argon2/thread.c | 1556 | 1402085e2f54b021ea31b0d301f4b689a8b300832e2d11901502e62835185e3e |
| vendor/argon2/thread.h | 2376 | 9eab7f9ff356862a00a3075478dd0059344953ed79daab8b29185be2010efe78 |
| vendor/argon2/blake2/blake2-impl.h | 4088 | 8ac91f1f57d94235f8de0069b7809be1deb365c3b37adb8e30423cd364aff09a |
| vendor/argon2/blake2/blake2.h | 2865 | 3c2de197dd23179f78c57deac7b73a6049778bf651c5db57e508b2cfce5e7559 |
| vendor/argon2/blake2/blake2b.c | 12510 | 52519ccbc1e48f489ff444091f630d05dadcc8f1ee61c5b7361e3a9618299c9a |
| vendor/argon2/blake2/blamka-round-opt.h | 21361 | ba5a9c1fef492cc6ce8d5b5217d6e7cd7983de10f16762f84e284d0ed9972e3b |
| vendor/argon2/blake2/blamka-round-ref.h | 2730 | bcfdcf785218cf897f05b144e80b659e611188fee3887d533bdcb7a6aa4c336b |
| vendor/httplib/LICENSE | 1075 | 4b45cbe16d7b71b89ae6127e26e0d90a029198ca5e958ad8e3d0b8bbed364d8b |
| vendor/httplib/httplib.h | 357227 | f81548031db8543a46170431afac1d2d9b305fc52cfd356a672de6688c2bf697 |
| vendor/nlohmann/LICENSE.MIT | 1076 | 86b998c792894ccb911a1cb7994f7a9652894e7a094c0b5e45be2f553f45cf14 |
| vendor/nlohmann/json.hpp | 919975 | 9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6 |

Sources:
- cpp-httplib v0.22.0 - MIT - https://github.com/yhirose/cpp-httplib
- nlohmann/json v3.11.3 - MIT - https://github.com/nlohmann/json
- phc-winner-argon2 20190702 (full src/ + include/argon2.h) - CC0-1.0 / Apache-2.0 - https://github.com/P-H-C/phc-winner-argon2
- libpq comes from the PostgreSQL binaries (see deploy docs); not vendored.
