cmake_minimum_required(VERSION 3.16)
project(bounded_matching_engine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
add_compile_options(-Wall -Wextra -Wpedantic)

# Header-only - no .cpp to build into a library, see the header's own
# comment for why (parameterized on N_LEVELS/M_ORDERS, matching
# bounded_order_book.sv's parameterization).
add_library(bounded_matching_engine_lib INTERFACE)
target_include_directories(bounded_matching_engine_lib INTERFACE include)

add_executable(bounded_matching_engine_test tests/bounded_matching_engine_test.cpp)
target_link_libraries(bounded_matching_engine_test PRIVATE bounded_matching_engine_lib)

add_executable(bounded_matching_engine_bench bench/bounded_matching_engine_bench.cpp)
target_link_libraries(bounded_matching_engine_bench PRIVATE bounded_matching_engine_lib)

# Static-link when cross-compiling for the HPS, to reduce the real
# glibc/ABI mismatch risk noted in toolchain-arm-cortex-a9.cmake and
# fpga_docs/bugs.md - the WSL-apt cross-compiler wasn't built to match
# the DE10's actual Linux image.
if(CMAKE_CROSSCOMPILING)
    target_link_options(bounded_matching_engine_test PRIVATE -static)
    target_link_options(bounded_matching_engine_bench PRIVATE -static)
endif()
