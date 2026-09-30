/* VENDORED ADDITION (eCash.com Wallet): the two libsodium runtime symbols the vendored ristretto255
 * files reference, without pulling in sodium/core.c + the randombytes subsystem (which drag in the
 * whole library: AEADs, argon2, CPU-feature dispatch, ...).
 *
 * randombytes_buf is only reached by libsodium's *_random() helpers, which this wallet never calls —
 * signing nonces come from Swift's system CSPRNG. It is still implemented with the OS CSPRNG
 * (arc4random_buf exists on Apple platforms and Android bionic) rather than a stub, so an accidental
 * call is safe, not silently weak. */
#include <stdlib.h>
#include <stddef.h>

void sodium_misuse(void) { abort(); }

void randombytes_buf(void * const buf, const size_t size) { arc4random_buf(buf, size); }
