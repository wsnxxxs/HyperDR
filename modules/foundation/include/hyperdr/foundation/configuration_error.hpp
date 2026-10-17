#pragma once

#include "hyperdr/foundation/cancel.hpp"
#include <new>
#include <stdexcept>

namespace hyperdr {

// A supplied rendering resource is unreadable or invalid, rather than the
// photograph. Kept distinct from source decode failures; C ABI invalid_options.
class ConfigurationError : public std::invalid_argument {
 public:
  using std::invalid_argument::invalid_argument;
};

// Call only at resource read/parse boundaries. Preserve diagnostics verbatim,
// as well as cancellation and allocation failures with their own ABI meanings.
template <class Function>
auto configuration_resource(Function function) {
  try {
    return function();
  } catch (const Cancelled&) {
    throw;
  } catch (const std::bad_alloc&) {
    throw;
  } catch (const std::exception& error) {
    throw ConfigurationError(error.what());
  }
}

} // namespace hyperdr
