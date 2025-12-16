# FarHorizons

[![Zig](https://img.shields.io/badge/Zig-F7A41D?style=flat-square&logo=zig&logoColor=white)](#)
[![Vulkan](https://github.com/user-attachments/assets/bccb4d19-d6a0-4f9c-82eb-d0434ae82c6e.svg)&logoColor=white)](#)
[![Windows](https://custom-icon-badges.demolab.com/badge/Windows-0078D6?style=flat-square&logo=windows11&logoColor=white)](#)
[![Linux](https://img.shields.io/badge/Linux-1F1F1F?style=flat-square&logo=linux&logoColor=white)](#)

A voxel-based game/game-engine written in Zig with a Vulkan renderer. Inspired by [Minecraft](https://www.minecraft.net), FarHorizons features a client/server design with block-based world rendering, async chunk loading, and a modern graphics pipeline.

<img width="2560" height="1369" alt="Screenshot 2025-12-16 174834" src="https://github.com/user-attachments/assets/b0b08e6e-e975-41e0-bd52-e24cb37af5f5" />

## Current Features

- Vulkan rendering pipeline with dynamic shader compilation
- Block model system with variants and multipart definitions
- Async chunk loading and mesh generation
- Texture array management
- Player input and camera controls
- Entity system
- Voxel shape system for block geometry (Will be used for collisions later on)
- Cross-platform support (Windows, Linux)

## Planned Features

- Multiplayer support (server currently in early development)
- Physics and collision system
- World generation
- Custom block types and textures

## Requirements

- Zig 0.16.0-dev or higher (bundled in via the run.bat)
- Vulkan-capable GPU with up-to-date drivers

## Building from Source

### Windows

1. Clone the repository:

   ```
   git clone https://github.com/HTRMC/FarHorizonsZig.git
   cd FarHorizonsZig
   ```

2. Build and run using the provided script:

   ```
   run.bat
   ```

   The script will automatically download the Zig compiler if not present.

   Optional: Specify optimization mode:

   ```
   run.bat --om ReleaseFast
   ```

### Manual Build

1. Build with Zig:

   ```
   compiler/zig/zig build
   ```

2. Run the client:
   ```
   zig-out/bin/FarHorizons
   ```

## License

This project is licensed under All Rights Reserved.
