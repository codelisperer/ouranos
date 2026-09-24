/* ouranos_tls_config.h -- the build options aion/tls needs on top of mbedTLS 4.1.1's defaults (#125).
 *
 * build-mbedtls.lisp passes this as TF_PSA_CRYPTO_USER_CONFIG_FILE, so it is read after
 * tf-psa-crypto/include/psa/crypto_config.h and changes only what is written here.
 *
 * THREADING. The default configuration leaves MBEDTLS_THREADING_C off, and its documentation
 * says the PSA crypto subsystem is then not thread-safe unless every PSA call comes from one
 * thread. aion/tls calls it from the server's loop thread, from a certificate reload on
 * another thread, and from client streams on application threads, so it is switched on.
 * mbedTLS has a built-in implementation only for pthreads. On Windows the application
 * supplies one (MBEDTLS_THREADING_ALT); ours is in ouranos_tls.c, and threading_alt.h
 * declares its types. */

#ifndef OURANOS_TLS_CONFIG_H
#define OURANOS_TLS_CONFIG_H

#define MBEDTLS_THREADING_C

#if defined(_WIN32)
#define MBEDTLS_THREADING_ALT
#else
#define MBEDTLS_THREADING_PTHREAD
#endif

#endif
