/* ICC profile headers contain LittleCMS's creation time. Freeze only time(2)
 * in the contract-test process and its CLI children; elapsed clocks still run.
 * This makes byte comparisons test the encoder, without editing image bytes. */
#include <time.h>
static time_t fixed_time(time_t* out) {
  const time_t value = 1792195200;
  if (out) *out = value;
  return value;
}
__attribute__((used)) static struct {
  const void* replacement;
  const void* original;
} interpose_time __attribute__((section("__DATA,__interpose"))) = {
  (const void*)fixed_time, (const void*)time
};
