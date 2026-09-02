// Phase 27 (fpga-roadmap.md) forwarder: relays the DE10 ARM board's
// locally-written FPGA-vs-software rolling-window latency snapshot
// (produced by the sibling, non-git-tracked
// d10_standard_golden_top/host/fpga_latency_harness/) into this
// project's real infrastructure - the `fpga-latency` Kafka topic (for
// durable history, consumed into Postgres by persistence_consumer) and
// the `fpga_latency:latest` Redis key (for live reads, same shape as
// TopOfBookCache).
//
// Why a forwarder instead of the ARM harness publishing directly: no
// ARM cross-compile of librdkafka exists in this project (only the
// plain C++ stdlib has been cross-compiled so far, for Phase 21/24's
// benchmarks - see fpga_docs/bugs.md #5). Building one would be new,
// unproven toolchain work; SSH-pulling a small JSON file (already a
// proven mechanism this project's history uses repeatedly) and
// republishing it through the existing, already-working KafkaProducer/
// RedisClient is much lower risk. This binary's only real jobs are:
// pull, dedupe (don't republish an unchanged snapshot), publish twice.
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>

#include "fpga_latency/fpga_latency_cache.hpp"
#include "kafka_client/json_reader.hpp"
#include "kafka_client/producer.hpp"
#include "kafka_client/topics.hpp"
#include "redis_client/redis_client.hpp"

namespace {

std::atomic<bool> g_stop{false};
void handle_signal(int) { g_stop.store(true); }

// Runs `ssh ... user@host "cat <path>"` and returns stdout. Empty
// string on any failure (unreachable board, no such file yet, etc.) -
// treated as "no new data this tick" by the caller, not a fatal error,
// since the board/harness may simply not be running right now.
// ControlMaster/ControlPersist reuse one real SSH connection across
// calls instead of paying a fresh handshake every poll - the same
// latency concern that made a tight polling loop impractical without it
// (a cold SSH handshake is typically hundreds of ms, more than this
// loop's whole interval).
std::string ssh_cat(const std::string& user, const std::string& host, const std::string& remote_path) {
    const std::string cmd = "ssh -o ControlMaster=auto -o ControlPersist=600 "
                             "-o ControlPath=/tmp/fpga_latency_forwarder_ssh_%C "
                             "-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes " +
                             user + "@" + host + " \"cat " + remote_path + "\" 2>/dev/null";
    std::unique_ptr<FILE, decltype(&pclose)> pipe(popen(cmd.c_str(), "r"), pclose);
    if (!pipe) return "";
    std::string result;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), pipe.get()) != nullptr) {
        result += buf;
    }
    return result;
}

struct Args {
    std::string board_user = "root";
    std::string board_host = "192.168.137.200";
    std::string snapshot_path = "/tmp/fpga_latency_snapshot.json";
    std::string brokers = "localhost:9092";
    std::string redis_host = "127.0.0.1";
    int redis_port = 6379;
    int cache_ttl_seconds = 5;
    int interval_ms = 500;
};

} // namespace

int main(int argc, char** argv) {
    Args args;
    for (int i = 1; i < argc; ++i) {
        const std::string flag = argv[i];
        if (flag == "--help") {
            std::cout << "fpga_latency_forwarder options:\n"
                      << "  --board-user USER        SSH user on the DE10 board (default root)\n"
                      << "  --board-host HOST        DE10 board address (default 192.168.137.200)\n"
                      << "  --snapshot-path PATH     remote snapshot file path\n"
                      << "  --brokers HOST:PORT      Kafka bootstrap servers (default localhost:9092)\n"
                      << "  --redis-host HOST        Redis host (default 127.0.0.1)\n"
                      << "  --redis-port N           Redis port (default 6379)\n"
                      << "  --cache-ttl-seconds N    fpga_latency:latest TTL (default 5)\n"
                      << "  --interval-ms N          poll interval (default 500, matches the harness's window)\n"
                      << "  --help                   show this message\n";
            return 0;
        } else if (flag == "--board-user" && i + 1 < argc) {
            args.board_user = argv[++i];
        } else if (flag == "--board-host" && i + 1 < argc) {
            args.board_host = argv[++i];
        } else if (flag == "--snapshot-path" && i + 1 < argc) {
            args.snapshot_path = argv[++i];
        } else if (flag == "--brokers" && i + 1 < argc) {
            args.brokers = argv[++i];
        } else if (flag == "--redis-host" && i + 1 < argc) {
            args.redis_host = argv[++i];
        } else if (flag == "--redis-port" && i + 1 < argc) {
            args.redis_port = std::stoi(argv[++i]);
        } else if (flag == "--cache-ttl-seconds" && i + 1 < argc) {
            args.cache_ttl_seconds = std::stoi(argv[++i]);
        } else if (flag == "--interval-ms" && i + 1 < argc) {
            args.interval_ms = std::stoi(argv[++i]);
        }
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    market::KafkaProducer producer(args.brokers, "fpga-latency-forwarder");
    market::RedisClient redis(args.redis_host, args.redis_port);
    market::FpgaLatencyCache cache(redis, args.cache_ttl_seconds);

    std::cout << "fpga_latency_forwarder: polling " << args.board_user << "@" << args.board_host << ":"
              << args.snapshot_path << " every " << args.interval_ms << "ms, publishing to Kafka topic '"
              << market::topics::kFpgaLatency << "' and Redis key '" << market::FpgaLatencyCache::kKey << "'\n";

    uint64_t last_window_end_ns = 0;
    uint64_t forwarded = 0, poll_failures = 0;

    while (!g_stop.load()) {
        const auto tick_start = std::chrono::steady_clock::now();

        const std::string json = ssh_cat(args.board_user, args.board_host, args.snapshot_path);
        const auto window_end = json.empty() ? std::nullopt : market::extract_uint64_field(json, "window_end_unix_ns");

        if (!window_end.has_value()) {
            ++poll_failures;
        } else if (*window_end != last_window_end_ns) {
            // New window since last poll - forward it. (An unchanged
            // window_end means the harness hasn't written a fresh
            // snapshot yet, e.g. it's not running right now; republishing
            // the same numbers would just be noise in both Kafka and
            // Postgres.)
            last_window_end_ns = *window_end;
            const bool kafka_ok = producer.publish(market::topics::kFpgaLatency, "latest", json);
            const bool redis_ok = cache.publish(json);
            ++forwarded;
            if (!kafka_ok || !redis_ok) {
                std::cout << "fpga_latency_forwarder: publish issue (kafka_ok=" << kafka_ok
                          << " redis_ok=" << redis_ok << ")\n";
            }
        }

        if ((forwarded + poll_failures) % 20 == 0) {
            const auto metrics = producer.metrics();
            std::cout << "fpga_latency_forwarder: forwarded=" << forwarded << " poll_failures=" << poll_failures
                      << " kafka_delivered=" << metrics.delivery_confirmed
                      << " kafka_failed=" << metrics.delivery_failed
                      << " redis_connected=" << cache.is_connected() << "\n";
        }

        const auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - tick_start);
        const auto remaining = std::chrono::milliseconds(args.interval_ms) - elapsed;
        if (remaining.count() > 0) {
            std::this_thread::sleep_for(remaining);
        }
    }

    std::cout << "fpga_latency_forwarder: stopping, flushing producer\n";
    producer.flush();
    return 0;
}
