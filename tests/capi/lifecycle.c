#include "hyperdr/hyperdr.h"

#include <stdio.h>
#include <string.h>

#define REQUIRE(condition) do { \
  if (!(condition)) { fprintf(stderr, "failed: %s\n", #condition); return 1; } \
} while (0)

int main(void) {
  char* output = NULL;
  hyperdr_error* error = NULL;
  REQUIRE(hyperdr_abi_version() == HYPERDR_ABI_VERSION);
  REQUIRE(strlen(hyperdr_version()) > 0);
  for (int i = 0; i < 20; ++i) {
    REQUIRE(hyperdr_schema_json(&output, &error) == 0);
    REQUIRE(error == NULL && output != NULL && strstr(output, "settings") != NULL);
    hyperdr_string_free(output);
    REQUIRE(hyperdr_curve_json("{}", 33, &output, &error) == 0);
    REQUIRE(error == NULL && output != NULL && strstr(output, "gain_stops") != NULL);
    hyperdr_string_free(output);
    REQUIRE(hyperdr_curve_json("{\"contrast\":999}", 33, &output, &error) != 0);
    REQUIRE(output == NULL && error != NULL);
    REQUIRE(strcmp(error->code, "invalid_options") == 0 && strlen(error->message) > 0);
    hyperdr_error_free(error);
    REQUIRE(hyperdr_curve_json("{}", 1, &output, &error) != 0);
    REQUIRE(output == NULL && error != NULL);
    hyperdr_error_free(error);
  }
  REQUIRE(hyperdr_schema_json(NULL, &error) != 0 && error != NULL);
  hyperdr_error_free(error);
  REQUIRE(hyperdr_curve_json(NULL, 33, &output, NULL) != 0 && output == NULL);
  REQUIRE(hyperdr_curve_json("[]", 33, &output, &error) != 0 && error != NULL);
  hyperdr_error_free(error);
  hyperdr_string_free(NULL);
  hyperdr_error_free(NULL);
  return 0;
}
