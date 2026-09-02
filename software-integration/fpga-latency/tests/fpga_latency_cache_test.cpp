#include <gtest/gtest.h>

#include "fake_redis_transport.hpp"
#include "fpga_latency/fpga_latency_cache.hpp"

using namespace market;

TEST(FpgaLatencyCacheTest, PublishThenReadRoundTrips) {
    FakeRedisTransport transport;
    FpgaLatencyCache cache(transport);

    const std::string snapshot = R"({"window_end_unix_ns":123,"row2_mean_ns":1800.0})";
    ASSERT_TRUE(cache.publish(snapshot));

    const auto read_back = cache.read();
    ASSERT_TRUE(read_back.has_value());
    EXPECT_EQ(*read_back, snapshot);
}

TEST(FpgaLatencyCacheTest, ReadingBeforeAnyPublishIsAMiss) {
    FakeRedisTransport transport;
    FpgaLatencyCache cache(transport);

    EXPECT_FALSE(cache.read().has_value());
}

TEST(FpgaLatencyCacheTest, LaterPublishOverwritesEarlierSnapshot) {
    FakeRedisTransport transport;
    FpgaLatencyCache cache(transport);

    cache.publish(R"({"window_end_unix_ns":1})");
    cache.publish(R"({"window_end_unix_ns":2})");

    const auto read_back = cache.read();
    ASSERT_TRUE(read_back.has_value());
    EXPECT_EQ(*read_back, R"({"window_end_unix_ns":2})");
}

TEST(FpgaLatencyCacheTest, PublishFailsGracefullyWhenRedisIsDown) {
    FakeRedisTransport transport;
    transport.simulate_down = true;
    FpgaLatencyCache cache(transport);

    EXPECT_FALSE(cache.publish(R"({"window_end_unix_ns":1})"));
}

TEST(FpgaLatencyCacheTest, KeyIsFixedAndGlobal) {
    EXPECT_STREQ(FpgaLatencyCache::kKey, "fpga_latency:latest");
}
