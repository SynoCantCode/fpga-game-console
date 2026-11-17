# FPGA Game Console

A 32-bit 3D game console built on an FPGA. The GPU, display output and memory system are written in Verilog. It runs on a real board and draws to a TV over HDMI.

This repo only shows the hardware side and it is still in progress.

## Board

Sipeed Tang Mega 138K Dock

- FPGA: Gowin GW5AST-138
- CPU: Andes A25 RISC-V, built into the chip
- Memory: 1 GB DDR3
- Video: HDMI, 1280 x 720 at 60 Hz

## How it works

1. The CPU writes a list of drawing commands into memory and tells the GPU to start
2. The GPU reads the list and draws the frame into a frame buffer in DDR3
3. The display reads the finished frame and sends it to the TV

The CPU, GPU and display share the DDR3 through one arbiter.

## GPU

The GPU is tile based and split in two halves.

- Front half: reads the commands, projects and lights each corner, sets up each triangle and sorts the triangles into screen tiles
- Back half: draws one tile at a time with a depth test and writes it to the frame buffer

## What it has right now

- depth buffering
- 2x anti-aliasing
- smooth shading
- lighting
- fog
- about 30,000 triangles a frame at 60 fps

Textures are being worked on.

## Folders

- hardware/gpu
- hardware/display
- hardware/memory
- hardware/cpu
- hardware/io
- hardware/debug

Each one has a test folder with test benches. The language and controller folders are empty for now.

## Notes

Gowin's own files (the CPU, the DDR3 controller and the PLLs) are not included so it will not build straight from this repo.
