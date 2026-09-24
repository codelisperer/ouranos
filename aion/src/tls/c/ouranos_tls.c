/* ouranos_tls.c -- the functions aion/tls needs from mbedTLS and cannot reach through CFFI (#125).
 *
 * build-mbedtls.lisp compiles this into the same library as mbedTLS's 110 sources, with the
 * same compiler, so nothing needs a C compiler when the Lisp system loads. It is kept to what
 * the binding needs. Each function exists for one of three reasons:
 *
 *   1. ALLOCATION. mbedTLS contexts are allocated by the caller and initialised in place, and
 *      their sizes depend on the build configuration. The library exports no size, so these
 *      functions allocate with the size the compiler knows, then call the matching init.
 *   2. INLINE FUNCTIONS. Some of ssl.h's configuration functions are `static inline', so they
 *      are not in the library's export table. These wrappers export the ones the binding uses.
 *   3. THREADING ON WINDOWS. mbedTLS has a built-in threading implementation only for pthreads.
 *      On Windows it calls the functions registered with mbedtls_threading_set_alt; ours are
 *      over SRWLOCK and CONDITION_VARIABLE.
 *
 * Every name starts with ouranos_tls_. build-mbedtls.lisp exports that prefix alongside
 * mbedtls_ and psa_ when it writes the Windows .def, and checks for these symbols after every
 * build. */

#include <stdlib.h>

#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/pk.h"
#include "mbedtls/threading.h"

/* Raised whenever a function here is added, removed or changes meaning, so the binding can
 * refuse a library built from a different version of this file. */
int ouranos_tls_shim_version(void)
{
    return 1;
}

/* Which threading implementation this library was built with: 1 for pthreads, 2 for the
 * Windows implementation below, 0 for none. The binding checks it is not 0, so a library
 * built without ouranos_tls_config.h is refused rather than used unsafely from two threads. */
int ouranos_tls_threading_kind(void)
{
#if defined(MBEDTLS_THREADING_PTHREAD)
    return 1;
#elif defined(MBEDTLS_THREADING_ALT)
    return 2;
#else
    return 0;
#endif
}

/* --- 1. allocation ---------------------------------------------------------------- */

mbedtls_ssl_context *ouranos_tls_ssl_new(void)
{
    mbedtls_ssl_context *p = malloc(sizeof *p);
    if (p != NULL) mbedtls_ssl_init(p);
    return p;
}

void ouranos_tls_ssl_free(mbedtls_ssl_context *p)
{
    if (p != NULL) { mbedtls_ssl_free(p); free(p); }
}

mbedtls_ssl_config *ouranos_tls_config_new(void)
{
    mbedtls_ssl_config *p = malloc(sizeof *p);
    if (p != NULL) mbedtls_ssl_config_init(p);
    return p;
}

void ouranos_tls_config_free(mbedtls_ssl_config *p)
{
    if (p != NULL) { mbedtls_ssl_config_free(p); free(p); }
}

mbedtls_x509_crt *ouranos_tls_crt_new(void)
{
    mbedtls_x509_crt *p = malloc(sizeof *p);
    if (p != NULL) mbedtls_x509_crt_init(p);
    return p;
}

void ouranos_tls_crt_free(mbedtls_x509_crt *p)
{
    if (p != NULL) { mbedtls_x509_crt_free(p); free(p); }
}

mbedtls_pk_context *ouranos_tls_pk_new(void)
{
    mbedtls_pk_context *p = malloc(sizeof *p);
    if (p != NULL) mbedtls_pk_init(p);
    return p;
}

void ouranos_tls_pk_free(mbedtls_pk_context *p)
{
    if (p != NULL) { mbedtls_pk_free(p); free(p); }
}

/* --- 2. inline functions ----------------------------------------------------------- */

/* The protocol range, as mbedtls_ssl_protocol_version values (0x0303 for TLS 1.2, 0x0304
 * for TLS 1.3). Both setters are static inline in ssl.h. */
void ouranos_tls_conf_version_range(mbedtls_ssl_config *conf, int min, int max)
{
    mbedtls_ssl_conf_min_tls_version(conf, (mbedtls_ssl_protocol_version) min);
    mbedtls_ssl_conf_max_tls_version(conf, (mbedtls_ssl_protocol_version) max);
}

/* The version a finished handshake agreed, in the same encoding. Inline in ssl.h. */
int ouranos_tls_version_number(const mbedtls_ssl_context *ssl)
{
    return (int) mbedtls_ssl_get_version_number(ssl);
}

/* Whether the handshake has finished. Inline in ssl.h. */
int ouranos_tls_handshake_over(mbedtls_ssl_context *ssl)
{
    return mbedtls_ssl_is_handshake_over(ssl);
}

/* --- 3. threading on Windows ------------------------------------------------------- */

#if defined(MBEDTLS_THREADING_ALT)

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* threading_alt.h declares these types as one pointer each, to keep <windows.h> out of every
 * mbedTLS source. A negative array size fails the compile if the shapes ever disagree. */
typedef char ouranos_tls_mutex_size_check[sizeof(SRWLOCK) == sizeof(mbedtls_platform_mutex_t) ? 1 : -1];
typedef char ouranos_tls_cond_size_check[
    sizeof(CONDITION_VARIABLE) == sizeof(mbedtls_platform_condition_variable_t) ? 1 : -1];

static int win_mutex_init(mbedtls_platform_mutex_t *m)
{
    InitializeSRWLock((PSRWLOCK) m);
    return 0;
}

/* An SRWLOCK holds no resources, so there is nothing to release. */
static void win_mutex_destroy(mbedtls_platform_mutex_t *m)
{
    (void) m;
}

static int win_mutex_lock(mbedtls_platform_mutex_t *m)
{
    AcquireSRWLockExclusive((PSRWLOCK) m);
    return 0;
}

static int win_mutex_unlock(mbedtls_platform_mutex_t *m)
{
    ReleaseSRWLockExclusive((PSRWLOCK) m);
    return 0;
}

static int win_cond_init(mbedtls_platform_condition_variable_t *c)
{
    InitializeConditionVariable((PCONDITION_VARIABLE) c);
    return 0;
}

/* A CONDITION_VARIABLE holds no resources either. */
static void win_cond_destroy(mbedtls_platform_condition_variable_t *c)
{
    (void) c;
}

static int win_cond_signal(mbedtls_platform_condition_variable_t *c)
{
    WakeConditionVariable((PCONDITION_VARIABLE) c);
    return 0;
}

static int win_cond_broadcast(mbedtls_platform_condition_variable_t *c)
{
    WakeAllConditionVariable((PCONDITION_VARIABLE) c);
    return 0;
}

static int win_cond_wait(mbedtls_platform_condition_variable_t *c, mbedtls_platform_mutex_t *m)
{
    return SleepConditionVariableSRW((PCONDITION_VARIABLE) c, (PSRWLOCK) m, INFINITE, 0)
           ? 0 : MBEDTLS_ERR_THREADING_USAGE_ERROR;
}

#endif

/* Must be called once, before any other mbedTLS function, including psa_crypto_init. On
 * Windows it registers the functions above; mbedTLS's documentation requires that to happen
 * on the main thread before anything else. With pthreads there is nothing to register. Safe
 * to call more than once: only the first call registers. Returns 0. */
int ouranos_tls_setup(void)
{
#if defined(MBEDTLS_THREADING_ALT)
    static int registered = 0;
    if (!registered) {
        mbedtls_threading_set_alt(win_mutex_init, win_mutex_destroy,
                                  win_mutex_lock, win_mutex_unlock,
                                  win_cond_init, win_cond_destroy,
                                  win_cond_signal, win_cond_broadcast, win_cond_wait);
        registered = 1;
    }
#endif
    return 0;
}
