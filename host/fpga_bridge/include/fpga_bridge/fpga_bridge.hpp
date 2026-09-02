// fpga_bridge
//
// /dev/mem mmap harness for fpga_matching_core (see
// rtl/fpga_matching_core.sv's header comment for the authoritative
// register map - duplicated here only as address constants, not
// re-explained). Talks to the real HPS lightweight H2F bridge from Linux
// userspace on the DE10-Standard's Cortex-A9 cores - this is what turns
// the fpga_docs/bugs.md #10 devmem proof-of-concept into a reusable,
// benchmarkable harness (Phase 24).
//
// HPS-side physical address = LWH2F bridge base (0xFF200000, fixed on
// Cyclone V HPS) + fpga_matching_core_0's Qsys base within that bridge
// (0x7000, see soc_system.qsys) = 0xFF207000. That address is already
// page-aligned (0x7000 is a multiple of 0x1000), so a single 4KB mmap
// covers the whole register file.
#pragma once

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

namespace fpga_bridge {

enum class Side : uint32_t { kBuy = 0, kSell = 1 };

struct OrderResult {
    bool rejected = false;
    uint32_t trade_qty = 0;
    int32_t trade_price = 0;
    uint64_t trade_id = 0;
    uint32_t latency_cycles = 0; // fabric-internal, core_clk cycles, START accept -> DONE
};

// Not copyable/movable - owns a live mmap of physical device memory.
class FpgaMatchingCore {
public:
    static constexpr uintptr_t kPhysBase = 0xFF207000;
    static constexpr size_t kMapSize = 4096; // one page, covers the whole 12-word register file

    FpgaMatchingCore() {
        fd_ = ::open("/dev/mem", O_RDWR | O_SYNC);
        if (fd_ < 0) {
            throw std::runtime_error(std::string("open(/dev/mem) failed: ") + std::strerror(errno));
        }
        void* mapped = ::mmap(nullptr, kMapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd_,
                               static_cast<off_t>(kPhysBase));
        if (mapped == MAP_FAILED) {
            ::close(fd_);
            throw std::runtime_error(std::string("mmap(fpga_matching_core) failed: ") + std::strerror(errno));
        }
        regs_ = static_cast<volatile uint32_t*>(mapped);
    }

    ~FpgaMatchingCore() {
        if (regs_ != nullptr) ::munmap(const_cast<uint32_t*>(regs_), kMapSize);
        if (fd_ >= 0) ::close(fd_);
    }

    FpgaMatchingCore(const FpgaMatchingCore&) = delete;
    FpgaMatchingCore& operator=(const FpgaMatchingCore&) = delete;

    // Submits one order and blocks (busy-polls STATUS) until DONE. Not
    // thread-safe, and the core itself does not queue requests (see the
    // register map comment) - callers must not overlap submissions.
    OrderResult submit_limit_order(uint64_t order_id, Side side, int32_t price, uint32_t qty) {
        regs_[kAddrOrderIdLo] = static_cast<uint32_t>(order_id & 0xFFFFFFFFu);
        regs_[kAddrOrderIdHi] = static_cast<uint32_t>(order_id >> 32);
        regs_[kAddrSide] = static_cast<uint32_t>(side);
        regs_[kAddrPrice] = static_cast<uint32_t>(price);
        regs_[kAddrQty] = qty;
        regs_[kAddrControl] = 0x1; // pulse START; self-clears in RTL

        uint32_t status;
        do {
            status = regs_[kAddrStatus];
        } while (status & kStatusBusy);

        OrderResult result;
        result.rejected = (status & kStatusRejected) != 0;
        result.trade_qty = regs_[kAddrTradeQty];
        result.trade_price = static_cast<int32_t>(regs_[kAddrTradePrice]);
        result.trade_id = (static_cast<uint64_t>(regs_[kAddrTradeIdHi]) << 32) | regs_[kAddrTradeIdLo];
        result.latency_cycles = regs_[kAddrLatency];
        return result;
    }

private:
    static constexpr unsigned kAddrOrderIdLo = 0x0;
    static constexpr unsigned kAddrOrderIdHi = 0x1;
    static constexpr unsigned kAddrSide = 0x2;
    static constexpr unsigned kAddrPrice = 0x3;
    static constexpr unsigned kAddrQty = 0x4;
    static constexpr unsigned kAddrControl = 0x5;
    static constexpr unsigned kAddrStatus = 0x6;
    static constexpr unsigned kAddrTradeQty = 0x7;
    static constexpr unsigned kAddrTradePrice = 0x8;
    static constexpr unsigned kAddrTradeIdLo = 0x9;
    static constexpr unsigned kAddrTradeIdHi = 0xA;
    static constexpr unsigned kAddrLatency = 0xB;

    static constexpr uint32_t kStatusBusy = 0x1;
    static constexpr uint32_t kStatusDone = 0x2;
    static constexpr uint32_t kStatusRejected = 0x4;

    int fd_ = -1;
    volatile uint32_t* regs_ = nullptr;
};

} // namespace fpga_bridge
