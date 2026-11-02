/* MIT, QuranRecitationKit. Thread-scoped ALSA probing; no global stderr redirect. */
#include <stdarg.h>
#include <alsa/asoundlib.h>
#include <stdlib.h>

struct qrk_alsa_scope { snd_local_error_handler_t previous; };
static void quiet(const char *file, int line, const char *function, int error,
                  const char *format, va_list arguments) {
    (void)file; (void)line; (void)function; (void)error; (void)format; (void)arguments;
}
void *qrk_alsa_quiet_begin(void) {
    struct qrk_alsa_scope *scope = malloc(sizeof(*scope));
    if (scope) scope->previous = snd_lib_error_set_local(quiet);
    return scope;
}
void qrk_alsa_quiet_end(void *opaque) {
    struct qrk_alsa_scope *scope = opaque;
    if (scope) { snd_lib_error_set_local(scope->previous); free(scope); }
}
