# README

To work on MacOS, install SDL3, SDL3_image, and SDL3_ttf via `homebrew` and do the following:

```shell
# Create symlinks to Homebrew versions
ln -s /opt/homebrew/lib/libSDL3.dylib modules/SDL3/macos/libSDL3.dylib
ln -s /opt/homebrew/lib/libSDL3_image.dylib modules/SDL3/image/macos/libSDL3_image.dylib
ln -s /opt/homebrew/lib/libSDL3_ttf.dylib modules/SDL3/ttf/macos/libSDL3_ttf.dylib
```

Compile the shaders:

```shell
shadercross assets/shaders/basic2d.vert.hlsl -o assets/shaders/basic2d.vert.msl
shadercross assets/shaders/basic2d.vert.hlsl -o assets/shaders/basic2d.vert.dxil
shadercross assets/shaders/basic2d.vert.hlsl -o assets/shaders/basic2d.vert.spv
shadercross assets/shaders/basic2d.frag.hlsl -o assets/shaders/basic2d.frag.msl
shadercross assets/shaders/basic2d.frag.hlsl -o assets/shaders/basic2d.frag.dxil
shadercross assets/shaders/basic2d.frag.hlsl -o assets/shaders/basic2d.frag.spv

shadercross assets/shaders/text.vert.hlsl -o assets/shaders/text.vert.msl
shadercross assets/shaders/text.vert.hlsl -o assets/shaders/text.vert.dxil
shadercross assets/shaders/text.vert.hlsl -o assets/shaders/text.vert.spv
shadercross assets/shaders/text.frag.hlsl -o assets/shaders/text.frag.msl
shadercross assets/shaders/text.frag.hlsl -o assets/shaders/text.frag.dxil
shadercross assets/shaders/text.frag.hlsl -o assets/shaders/text.frag.spv
```