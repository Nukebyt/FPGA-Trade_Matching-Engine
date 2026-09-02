# CMake toolchain file for cross-compiling to the DE10-Standard's HPS
# (dual-core ARM Cortex-A9, armhf/EABI hard-float). Use with:
#
#   cmake -B build-arm -DCMAKE_TOOLCHAIN_FILE=../toolchain-arm-cortex-a9.cmake ..
#   cmake --build build-arm
#
# Assumes arm-linux-gnueabihf-gcc/g++ are on PATH. This project installed
# them via WSL (`sudo apt install gcc-arm-linux-gnueabihf
# g++-arm-linux-gnueabihf`) rather than Intel's vendor-matched SoC EDS
# ARM toolchain - a deliberate speed-over-exact-match tradeoff (see
# fpga_docs/bugs.md and fpga-roadmap.md's Phase 21 entry for why: no ARM
# cross-compiler existed anywhere on this machine, nios2eds only ships a
# Nios II *soft-core* compiler, a different architecture entirely). The
# real risk this accepts is a possible glibc/ABI mismatch against
# whatever libc the DE10's actual Linux image ships (likely
# Yocto/Angstrom-based, not Ubuntu) - mitigated below by static linking
# rather than assuming compatibility.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)

# Matches Intel's own SoC EDS reference flags for this exact HPS: dual
# Cortex-A9, NEON, hardware FPU.
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard")

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
