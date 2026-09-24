/* threading_alt.h -- the mutex and condition-variable types for mbedTLS's MBEDTLS_THREADING_ALT
 * on Windows (#125). mbedtls/threading.h includes this by name when THREADING_ALT is on.
 *
 * The functions over these types are in ouranos_tls.c, and use SRWLOCK and CONDITION_VARIABLE.
 * Both of those are a struct holding one pointer. The types here have the same shape, so that
 * this header, which every mbedTLS source includes, does not have to include <windows.h>.
 * ouranos_tls.c checks at compile time that the sizes agree. */

#ifndef OURANOS_TLS_THREADING_ALT_H
#define OURANOS_TLS_THREADING_ALT_H

typedef struct { void *ptr; } mbedtls_platform_mutex_t;
typedef struct { void *ptr; } mbedtls_platform_condition_variable_t;

#endif
