/*
 * metrics.cpp — RSS polling for macOS/iOS and Linux
 *
 * macOS/iOS: uses mach_task_basic_info via task_info()
 * Linux:     parses VmRSS from /proc/self/status
 */

#include "metrics.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>

#if defined(__APPLE__)
#  include <mach/mach.h>
#elif defined(__linux__)
#  include <cerrno>
#endif

namespace pocketlm {

long rss_bytes() noexcept {
#if defined(__APPLE__)
    mach_task_basic_info_data_t info{};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(
        mach_task_self(),
        MACH_TASK_BASIC_INFO,
        reinterpret_cast<task_info_t>(&info),
        &count
    );
    if (kr != KERN_SUCCESS) {
        return -1L;
    }
    return static_cast<long>(info.resident_size);

#elif defined(__linux__)
    FILE* fp = std::fopen("/proc/self/status", "r");
    if (!fp) {
        return -1L;
    }
    char line[256];
    long kb = -1L;
    while (std::fgets(line, sizeof(line), fp)) {
        if (std::strncmp(line, "VmRSS:", 6) == 0) {
            // format: "VmRSS:   12345 kB"
            if (std::sscanf(line + 6, " %ld", &kb) != 1) {
                kb = -1L;
            }
            break;
        }
    }
    std::fclose(fp);
    // VmRSS is in kibibytes; convert to bytes
    return (kb >= 0) ? (kb * 1024L) : -1L;

#else
    return -1L;
#endif
}

} // namespace pocketlm
