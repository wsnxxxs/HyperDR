#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/heif_reader.hpp"

#include <stdexcept>

namespace hyperdr {

using Bytes = std::vector<std::uint8_t>;

Bytes extract_tmap_payload(const Bytes& bytes) {
  const auto file = read_heif(bytes);
  const auto references = file.tmap_references();
  if (!references) throw std::runtime_error("file has no tmap item with dimg references");
  return file.item_bytes(references->tmap_id, 4096);
}

TmapReferences find_tmap_references(const Bytes& bytes) {
  const auto references = read_heif(bytes).tmap_references();
  if (!references) throw std::runtime_error("file has no tmap item with dimg references");
  return *references;
}

}  // namespace hyperdr
