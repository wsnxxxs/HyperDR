#pragma once

#include <string>

namespace hyperdr {

// How input RGB samples were interpreted before entering the working space.
struct SourceColorInfo {
  std::string name;
  std::string primaries;
  std::string transfer;
  std::string source;
};

}  // namespace hyperdr
