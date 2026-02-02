# Cosmo Crawler

Currently this is only an HTML stripping tool. It removes HTML tags and
other boilerplate to extract human readable content. But plan is to
make it a web crawler.

## Build

Currently only works with Zig 0.14.

``` shell
# An optimized build
zig build -Doptimize=ReleaseFast
```

## Usage

``` shell
# Stripped content will be in stdout
zig-out/bin/crawler <your_url>
```
