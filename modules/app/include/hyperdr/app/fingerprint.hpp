#pragma once

// A stable hash over every setting that can change the encoded bytes.
//
// This is what makes `--skip-existing` mean "already rendered this way" rather
// than "a file with that name exists". Modification times say nothing about how
// a file was rendered, so a re-run with a different look used to keep the old
// image. The signature is built by walking the settings table, so a new setting
// is fingerprinted the moment it is declared -- the previous hand-written list
// had already fallen behind twice.

#include "hyperdr/app/settings.hpp"

#include <string>

namespace hyperdr {

// Human-readable, and the exact input to the hash. Recorded in the sidecar so a
// stale skip can be diagnosed by reading it.
[[nodiscard]] std::string settings_signature(const ConvertOptions& options);
[[nodiscard]] std::string settings_fingerprint(const ConvertOptions& options);

}  // namespace hyperdr
