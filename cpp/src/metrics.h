/*
 * metrics.h — internal RSS polling interface
 */

#pragma once

namespace pocketlm {

/**
 * @brief Query the current resident-set size of this process.
 *
 * macOS/iOS: uses mach_task_basic_info via task_info() with MACH_TASK_BASIC_INFO flavor.
 * Linux:     parses VmRSS from /proc/self/status.
 *
 * @return RSS in bytes, or -1 on error.
 */
long rss_bytes() noexcept;

} // namespace pocketlm
