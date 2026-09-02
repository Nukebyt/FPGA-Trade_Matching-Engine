add_executable(fpga_latency_core_tests
    fpga_latency_cache_test.cpp
)
target_include_directories(fpga_latency_core_tests PRIVATE . ../../redis/tests)
target_link_libraries(fpga_latency_core_tests PRIVATE fpga_latency_core GTest::gtest GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(fpga_latency_core_tests)
