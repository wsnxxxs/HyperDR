#ifndef HYPERDR_H
#define HYPERDR_H

#include <stdint.h>

#if defined(_WIN32) && defined(HYPERDR_SHARED)
#  ifdef HYPERDR_CAPI_BUILD
#    define HYPERDR_API __declspec(dllexport)
#  else
#    define HYPERDR_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__)
#  define HYPERDR_API __attribute__((visibility("default")))
#else
#  define HYPERDR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define HYPERDR_ABI_VERSION 1

typedef struct hyperdr_error {
  const char* code;
  const char* message;
} hyperdr_error;

/* Version strings have static lifetime and must not be freed. */
HYPERDR_API uint32_t hyperdr_abi_version(void);
HYPERDR_API const char* hyperdr_version(void);

/* All strings are UTF-8. Calls return 0 on success, nonzero on error.
 * Output strings and errors belong to the library; use the matching free.
 * On failure *out is NULL; *err is set when supplied (may be NULL on OOM).
 * Independent calls may run concurrently. No exceptions cross this boundary.
 */
HYPERDR_API int hyperdr_schema_json(char** out, hyperdr_error** err);
/* settings_json is a strict settings object using the schema's keys.
 * samples has the same [2,4096] range as CLI --samples. Both JSON functions
 * include the CLI's trailing newline for byte-for-byte stream comparison.
 */
HYPERDR_API int hyperdr_curve_json(const char* settings_json, unsigned samples,
                                 char** out, hyperdr_error** err);
HYPERDR_API void hyperdr_string_free(char* string);
HYPERDR_API void hyperdr_error_free(hyperdr_error* error);

#ifdef __cplusplus
}
#endif

#endif
