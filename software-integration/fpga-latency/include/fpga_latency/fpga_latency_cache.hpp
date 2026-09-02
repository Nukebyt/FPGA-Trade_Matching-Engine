#pragma once

#include <optional>
#include <string>

#include "redis_client/redis_transport.hpp"

namespace market {

// Analogous to TopOfBookCache (redis_client/top_of_book_cache.hpp) but
// for a single global value, not per-instrument: the FPGA vs. ARM
// rolling-window comparison has exactly one live stream, not one per
// symbol, so there's no key family, just one fixed key. Same two-part
// invalidation as TopOfBookCache: overwrite-on-publish plus a TTL, so a
// stalled forwarder (or an unreachable DE10 board) makes the key expire
// rather than serve arbitrarily old numbers forever.
class FpgaLatencyCache {
public:
    static constexpr const char* kKey = "fpga_latency:latest";

    explicit FpgaLatencyCache(RedisTransport& transport, int ttl_seconds = 5);

    // `json_snapshot` is published as-is - the forwarder relays the
    // exact JSON the DE10-side harness wrote, no re-serialization step,
    // so there's exactly one place (fpga_latency_harness.cpp) that
    // defines this schema's field names.
    bool publish(const std::string& json_snapshot);
    std::optional<std::string> read();
    bool is_connected() const { return transport_.is_connected(); }

private:
    RedisTransport& transport_;
    int ttl_seconds_;
};

} // namespace market
