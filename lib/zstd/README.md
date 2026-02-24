# ZSTD Amalgamation

Place the zstd single-file amalgamation here to enable ZSTD compression.

## Setup

1. Download the zstd source from https://github.com/facebook/zstd/releases
2. From the zstd source, copy these files into this directory:
   - `build/single_file_libs/zstd-in.c` → rename to `zstd.c`
   - `lib/zstd.h` → `zstd.h`

   Alternatively, use the amalgamation script:
   ```
   cd zstd-source/build/single_file_libs
   python combine.py -r ../../lib -o zstd.c zstd-in.c
   ```

3. Build with: `zig build -Dzstd=true`

Without these files, the build defaults to deflate compression (no extra deps needed).
