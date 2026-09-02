#include "fpga_latency/fpga_latency_cache.hpp"

namespace market {

FpgaLatencyCache::FpgaLatencyCache(RedisTransport& transport, int ttl_seconds)
    : transport_(transport), ttl_seconds_(ttl_seconds) {}

bool FpgaLatencyCache::publish(const std::string& json_snapshot) {
    return transport_.set(kKey, json_snapshot, ttl_seconds_);
}

std::optional<std::string> FpgaLatencyCache::read() { return transport_.get(kKey); }

} // namespace market
