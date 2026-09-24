#include "hyperdr/codec/dcp_profile.hpp"
#include <zlib.h>
#include <algorithm>
#include <array>
#include <bit>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
void append_u32(std::vector<std::uint8_t>& bytes, std::uint32_t value) {
  for (unsigned i=0; i<4; ++i) bytes.push_back(static_cast<std::uint8_t>(value >> (i*8)));
}
std::string base85(const std::vector<std::uint8_t>& bytes) {
  constexpr char alphabet[] =
      "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#";
  std::string out;
  for (std::size_t i=0; i<bytes.size(); i+=4) {
    std::uint32_t value=0;
    const auto count=std::min<std::size_t>(4,bytes.size()-i);
    for (std::size_t j=0; j<count; ++j) value|=std::uint32_t(bytes[i+j]) << (j*8);
    for (std::size_t j=0; j<count+1; ++j) {
      out+=alphabet[value%85];
      value/=85;
    }
  }
  return out;
}
std::string encoded_table() {
  std::vector<std::uint8_t> raw;
  for (auto value:{0U,1U,4U,2U,1U}) append_u32(raw,value);
  for (unsigned i=0; i<8; ++i) {
    for (float value:{0.0F,1.0F,0.8F}) append_u32(raw,std::bit_cast<std::uint32_t>(value));
  }
  append_u32(raw,0);
  uLongf size=compressBound(static_cast<uLong>(raw.size()));
  std::vector<std::uint8_t> compressed(size);
  require(compress2(compressed.data(),&size,raw.data(),static_cast<uLong>(raw.size()),Z_BEST_COMPRESSION)==Z_OK,
      "cannot compress synthetic look table");
  compressed.resize(size);
  std::vector<std::uint8_t> packed;
  append_u32(packed,static_cast<std::uint32_t>(raw.size()));
  packed.insert(packed.end(),compressed.begin(),compressed.end());
  return base85(packed);
}
std::filesystem::path fixture(const std::string& attributes, const std::string& children,
    const std::string& file, const std::string& camera="Camera ST") {
  const auto path=std::filesystem::temp_directory_path()/file;
  std::ofstream out(path,std::ios::binary);
  out << "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"rdf\">"
      << "<rdf:Description xmlns:crs=\"crs\" crs:PresetType=\"Look\" "
      << "crs:CameraProfile=\"" << camera << "\" crs:CameraModelRestriction=\"Sony Test\" "
      << "crs:LookTable=\"fixture\" " << attributes << ">"
      << "<crs:Table_fixture>" << encoded_table() << "</crs:Table_fixture>"
      << "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0,0</rdf:li>"
      << "<rdf:li>128,160</rdf:li><rdf:li>255,255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>"
      << "<crs:Name><rdf:Alt><rdf:li>Fixture Look</rdf:li></rdf:Alt></crs:Name>"
      << children
      << "</rdf:Description></rdf:RDF></x:xmpmeta>";
  return path;
}
hyperdr::DcpProfile profile() {
  hyperdr::DcpProfile result;
  result.name="Camera ST";
  result.camera_model="Sony Test";
  return result;
}
void rejected(const std::string& attributes, const std::string& children,
    const char* file, const std::string& camera="Camera ST") {
  const auto path=fixture(attributes,children,file,camera);
  auto value=profile();
  bool threw=false;
  try { hyperdr::apply_xmp_look(value,path); }
  catch (const std::invalid_argument&) { threw=true; }
  std::filesystem::remove(path);
  require(threw,"unsupported or mismatched XMP look was accepted");
}
}
int main() {
  try {
    const auto path=fixture("","","hyperdr-xmp-look-valid.xmp");
    auto value=profile();
    hyperdr::apply_xmp_look(value,path);
    std::filesystem::remove(path);
    require(value.xmp_look_table.dims==std::array<std::uint32_t,3>{4,2,1},"look dimensions were lost");
    require(value.xmp_look_table.values.size()==8,"look samples were lost");
    require(value.xmp_look_table.values[0][2] > 0.79F &&
        value.xmp_look_table.values[0][2] < 0.81F,"look value was decoded incorrectly");
    require(value.xmp_tone_curve.size()==3 && value.xmp_tone_curve[1][1] > 0.62,
        "tone curve was not decoded");
    require(value.xmp_look_name=="Fixture Look" && value.xmp_look_sha256.size()==64,
        "look identity was not retained");
    rejected("","","hyperdr-xmp-look-mismatch.xmp","Different Camera");
    rejected("crs:ProfileGainTableMap=\"adaptive\"","","hyperdr-xmp-look-adaptive.xmp");
    rejected("","<crs:ToneCurvePV2012Red><rdf:Seq><rdf:li>0,0</rdf:li>"
        "<rdf:li>255,254</rdf:li></rdf:Seq></crs:ToneCurvePV2012Red>",
        "hyperdr-xmp-look-channel.xmp");
    rejected("crs:Exposure2012=\"1\"","","hyperdr-xmp-look-edit.xmp");
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
