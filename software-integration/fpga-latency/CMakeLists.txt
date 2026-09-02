# fpga_latency_core: FpgaLatencyCache logic only, no hiredis/librdkafka
# dependency - same "core" split as kafka_client_core/redis_client_core,
# unit-testable against a fake RedisTransport.
add_library(fpga_latency_core STATIC
    src/fpga_latency_cache.cpp
)
target_include_directories(fpga_latency_core PUBLIC include)
target_link_libraries(fpga_latency_core PUBLIC redis_client_core)
target_compile_features(fpga_latency_core PUBLIC cxx_std_20)

# fpga_latency_forwarder: the actual SSH-pull -> Kafka+Redis relay (see
# src/main.cpp for why this is a forwarder rather than the DE10-side
# ARM harness publishing directly). Links the real kafka_client/
# redis_client (librdkafka/hiredis-backed), not just the core libs.
add_executable(fpga_latency_forwarder src/main.cpp)
target_link_libraries(fpga_latency_forwarder PRIVATE fpga_latency_core kafka_client redis_client)

add_subdirectory(tests)
