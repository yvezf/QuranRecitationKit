#ifndef QRK_H
#define QRK_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct QrkRecognizer QrkRecognizer;

/**
 * Independent open-set session. Destroy with qrk_spotter_free, not qrk_free.
 */
typedef struct QrkSpotter QrkSpotter;

typedef int32_t qrk_status;

typedef void (*qrk_event_cb)(const char *json, void *user);

typedef void (*qrk_progress_cb)(double progress, void *user);

#define QRK_OK 0

#define QRK_INVALID_ARGUMENT 1

#define QRK_ERROR 2

#define QRK_PANIC 3

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Last error on this thread. Borrowed; never pass it to qrk_string_free.
 */
const char *qrk_last_error(void);

/**
 * Static UTF-8 version string; do not free.
 */
const char *qrk_version(void);

/**
 * Owned UTF-8 JSON describing the pinned model and configured release URL. Free with qrk_string_free.
 */
char *qrk_model_source_json(void);

/**
 * Owned UTF-8 platform cache directory. Free with qrk_string_free.
 */
char *qrk_cache_directory(void);

/**
 * Verbatim, attributed Arabic corpus for host display. No normalized index. Free with qrk_string_free.
 */
char *qrk_corpus_json(void);

/**
 * Create a handle. The caller owns it and calls qrk_free once.
 * # Safety
 * Non-null strings must be NUL-terminated UTF-8; out must point to writable pointer storage.
 */
qrk_status qrk_recognizer_new(const char *model_dir,
                              const char *corpus_path,
                              const char *config_json,
                              struct QrkRecognizer **out);

/**
 * # Safety
 * h must be a live handle; target_json must be NUL-terminated UTF-8.
 */
qrk_status qrk_set_expected(struct QrkRecognizer *h, const char *target_json);

/**
 * Callbacks run synchronously after releasing the session lock. Strings are borrowed until callback return.
 * # Safety
 * h must be live; pcm points to n readable f32 samples (null is permitted only for n=0).
 * The callback and user context must remain valid throughout the call. Do not free h concurrently.
 */
qrk_status qrk_feed(struct QrkRecognizer *h,
                    const float *pcm,
                    uintptr_t n,
                    qrk_event_cb callback,
                    void *user);

/**
 * Return the JSON summary, including final events; free the string with qrk_string_free.
 * # Safety
 * h is live; summary_json is writable pointer storage. Do not free h concurrently.
 */
qrk_status qrk_stop(struct QrkRecognizer *h, char **summary_json);

/**
 * # Safety
 * h must be a live handle, not concurrently freed.
 */
qrk_status qrk_reset(struct QrkRecognizer *h);

/**
 * Null is harmless. Free a live handle exactly once, after all calls finish.
 * # Safety
 * h is null or was returned by qrk_recognizer_new and has not been freed.
 */
void qrk_free(struct QrkRecognizer *h);

/**
 * # Safety
 * s is null or an owned string returned by this ABI, freed exactly once; never a borrowed version/error pointer.
 */
void qrk_string_free(char *s);

/**
 * Download and verify the configured release model. Optional progress callback runs on this thread.
 * # Safety
 * cache_dir is null or NUL-terminated UTF-8; callback/context remain valid through the call.
 */
qrk_status qrk_model_fetch(const char *cache_dir, qrk_progress_cb callback, void *user);

/**
 * # Safety
 * Strings are null or NUL-terminated UTF-8; out is writable pointer storage.
 */
qrk_status qrk_spotter_new(const char *model_dir,
                           const char *corpus_path,
                           const char *config_json,
                           struct QrkSpotter **out);

/**
 * Callbacks borrow UTF-8 and run after releasing the session lock.
 * # Safety
 * h is live; pcm has n samples (null only for zero); callback/context stay valid. Do not free concurrently.
 */
qrk_status qrk_spotter_feed(struct QrkSpotter *h,
                            const float *pcm,
                            uintptr_t n,
                            qrk_event_cb callback,
                            void *user);

/**
 * # Safety
 * h is live; out is writable pointer storage. Free returned JSON with qrk_string_free.
 */
qrk_status qrk_spotter_stop(struct QrkSpotter *h, char **out);

/**
 * # Safety
 * h is a live spotter, not concurrently freed.
 */
qrk_status qrk_spotter_reset(struct QrkSpotter *h);

/**
 * # Safety
 * h is null or a live spotter returned by qrk_spotter_new; free once after all calls finish.
 */
void qrk_spotter_free(struct QrkSpotter *h);

/**
 * Model-free retrieval. Result is ALWAYS verified:false; no acoustic model is loaded/downloaded.
 * # Safety
 * text is NUL-terminated UTF-8; out is writable. Free returned JSON with qrk_string_free.
 */
qrk_status qrk_match_text(const char *text, char **out);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* QRK_H */
