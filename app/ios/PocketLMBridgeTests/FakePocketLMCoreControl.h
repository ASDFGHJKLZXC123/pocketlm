#ifndef FakePocketLMCoreControl_h
#define FakePocketLMCoreControl_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void pocketlm_fake_reset_counters(void);
void pocketlm_fake_release_held_requests(void);
int32_t pocketlm_fake_wait_for_all_requests_idle(int32_t timeout_ms);
int32_t pocketlm_fake_emit_interleaved_requests(void);
int32_t pocketlm_fake_begin_interleaved_fault_requests(void);
int32_t pocketlm_fake_finish_interleaved_fault_request(void);
void pocketlm_fake_set_destroy_blocked(int32_t blocked);
void pocketlm_fake_throw_next_cancel(void);
int32_t pocketlm_fake_wait_for_destroy_started(int32_t minimum_count,
                                               int32_t timeout_ms);
int32_t pocketlm_fake_destroy_started_count(void);
void pocketlm_fake_set_diagnostics_override(int32_t selected_accelerator,
                                            int32_t offloaded_layers);
void pocketlm_fake_set_diagnostics_requested(int32_t requested_accelerator);
void pocketlm_fake_set_diagnostics_kqv(int32_t kqv_offloaded);
void pocketlm_fake_set_diagnostics_peak_rss(int64_t peak_rss_bytes);
void pocketlm_fake_clear_diagnostics_override(void);
int32_t pocketlm_fake_create_count(void);
int32_t pocketlm_fake_destroy_count(void);
int32_t pocketlm_fake_callback_count(void);
int32_t pocketlm_fake_generate_call_count(void);
int32_t pocketlm_fake_cancel_call_count(void);
int32_t pocketlm_fake_diagnostics_call_count(void);

#ifdef __cplusplus
}
#endif

#endif
