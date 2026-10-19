#pragma once
// ISO tmap declarations for the writer.
#include "internal/boxes.hpp"
#include <array>

namespace hyperdr::container {
// ISO gain maps need both this auxiliary type and gain -> base auxl.
// Gate T2 found that ImageIO exposes no ISO gain map without the auxC URN.
inline constexpr std::string_view kIsoGainMapAuxType = "urn:iso:std:iso:ts:21496:-1";
inline Bytes iso_gain_map_aux_property() {
  Bytes payload{0,0,0,0};
  payload.insert(payload.end(),kIsoGainMapAuxType.begin(),kIsoGainMapAuxType.end());
  payload.push_back(0);
  return make_box("auxC",payload);
}
inline Bytes tmap_reference(std::string_view type,std::uint32_t from,
    std::span<const std::uint32_t> targets,bool wide) {
  if (!from || targets.empty() || targets.size()>65535)
    throw std::invalid_argument("invalid tmap reference");
  Bytes payload;
  const auto id=[&](std::uint32_t value) {
    if (!value || (!wide && value>65535)) throw std::invalid_argument("tmap item ID overflow");
    if(wide)put32(payload,value);else put16(payload,static_cast<std::uint16_t>(value));
  };
  id(from);put16(payload,static_cast<std::uint16_t>(targets.size()));
  for(auto target:targets)id(target);
  return make_box(type,payload);
}
inline Bytes tmap_alternative_group(std::uint32_t group,std::uint32_t tmap,std::uint32_t base) {
  Bytes payload{0,0,0,0};
  put32(payload,group);put32(payload,2);put32(payload,tmap);put32(payload,base);
  return make_box("altr",payload);
}
} // namespace hyperdr::container
