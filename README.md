# ZigNES 🕹️

**NES emulator written in Zig**

Currently, only the NROM mapper is supported, and PPU scrolling has not yet been implemented (but should be implemented soon!). 

Games with static screen and limited scrolling, like Donkey Kong and PacMan, can be emulated pretty well.

## Build and Usage
Building with Zig is as simple as running `zig build` in the top project directory. The build file assumes that SDL2 is installed in the directory `"C:\lib\SDL2-2.26.4\"`.

To use the emulator, pass the path to a ROM to the built `ZigNES` executable.

### Controls
| Key | Action |
|-----|---------|
| **W,A,S,D** | D-Pad |
| **J** | A Button |
| **K** | B Button |
| **Space** | Select |
| **Return** | Start |

## CPU tests
To test the CPU, Tom Harte's [nes6502 tests](https://github.com/TomHarte/ProcessorTests/tree/main/nes6502) are used. This is a suite of 10,000 tests for each of the 256 opcodes, both legal and illegal, which describes the initial and final state of the CPU after running one instruction.

Currently, the `ZigNES` CPU passes all 1.5 million test cases for the set of legal opcodes, excluding cycle timings.

The test set itself is not included in this repository due to the size of download. If you would like to run the tests yourself, the test runner expects the test cases to exist at the path `.\test-files\tom_harte_nes6502\v1` relative to the root of this project. 