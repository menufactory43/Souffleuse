#ifndef SQLCIPHER_SHIM_H
#define SQLCIPHER_SHIM_H

/* Ensure the SQLCipher codec API (sqlite3_key / sqlite3_rekey) is visible to
 * Swift importers. The amalgamation guards these declarations behind
 * SQLITE_HAS_CODEC, which is a compile-time define for the C target but is not
 * propagated to consumers of the module map. Defining it here makes the
 * declarations available wherever this umbrella header is imported. */
#ifndef SQLITE_HAS_CODEC
#define SQLITE_HAS_CODEC 1
#endif

#include "sqlite3.h"

#endif /* SQLCIPHER_SHIM_H */
