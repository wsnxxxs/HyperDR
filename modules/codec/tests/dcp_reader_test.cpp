#include "hyperdr/codec/dcp_profile.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <bit>
#include <chrono>
#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}
struct Fixture {
  struct Field { unsigned tag, type, count; std::vector<std::uint8_t> data; };
  bool little;
  std::vector<Field> fields;
  void put(std::vector<std::uint8_t>& bytes, std::uint32_t value, unsigned size) const {
    for (unsigned i = 0; i < size; ++i)
      bytes.push_back(static_cast<std::uint8_t>(value >> (8*(little ? i : size-1-i))));
  }
  void string(unsigned tag, std::string text) {
    text.push_back('\0');
    fields.push_back({tag,2,static_cast<unsigned>(text.size()),{text.begin(),text.end()}});
  }
  void numbers(unsigned tag, unsigned type, std::initializer_list<double> values) {
    Field field{tag,type,static_cast<unsigned>(values.size()),{}};
    for (const auto value : values) {
      if (type == 10) {
        put(field.data, static_cast<std::uint32_t>(static_cast<std::int32_t>(std::lround(value*10000))),4);
        put(field.data,10000,4);
      } else if (type == 11) put(field.data,std::bit_cast<std::uint32_t>(static_cast<float>(value)),4);
      else put(field.data,static_cast<std::uint32_t>(value), type == 3 ? 2 : 4);
    }
    fields.push_back(std::move(field));
  }
  std::vector<std::uint8_t> bytes() const {
    std::vector<std::uint8_t> out{static_cast<std::uint8_t>(little?'I':'M'),static_cast<std::uint8_t>(little?'I':'M')};
    put(out,0x4352,2); put(out,8,4); put(out,static_cast<std::uint32_t>(fields.size()),2);
    std::vector<std::uint8_t> payload;
    for (const auto& f : fields) {
      put(out,f.tag,2); put(out,f.type,2); put(out,f.count,4);
      if(f.data.size()<=4) {
        out.insert(out.end(),f.data.begin(),f.data.end());
        out.insert(out.end(),4-f.data.size(),0);
      } else {
        put(out,static_cast<std::uint32_t>(14+fields.size()*12+payload.size()),4);
        payload.insert(payload.end(),f.data.begin(),f.data.end());
      }
    }
    put(out,0,4); out.insert(out.end(),payload.begin(),payload.end());
    return out;
  }
};
Fixture fixture(bool little) {
  Fixture f{little,{}};
  f.string(50708,"Sony ILCE-7RM5"); f.string(50936,"Synthetic");
  f.numbers(50721,10,{1,0,0,0,1,0,0,0,1}); f.numbers(50778,3,{21});
  f.numbers(50981,4,{1,2,1}); f.numbers(50982,11,{0,1,1,10,.9,1});
  f.numbers(51108,4,{1}); f.numbers(51109,10,{-.35});
  f.numbers(51110,4,{1}); f.numbers(50940,11,{0,0,.5,.6,1,1});
  return f;
}
}  // namespace
int main(int argc, char** argv) {
  const auto path = std::filesystem::temp_directory_path() / ("hyperdr-dcp-" +
      std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".dcp");
  try {
    for(bool little : {true,false}) {
      const auto f = fixture(little);
      hyperdr::write_binary_file_atomic(path,f.bytes(),true);
      const auto p = hyperdr::read_dcp_profile(path);
      require(p.name=="Synthetic" && p.sha256.size()==64,"profile identity");
      require(p.look_table.values.size()==2 && p.look_table.srgb_encoding,"table encoding");
      require(p.tone_curve.size()==3 && p.default_black_render_none,"tone and black rendering");
      require(std::abs(p.baseline_exposure_offset+.35F)<1e-6F,"signed exposure offset");
      require(hyperdr::dcp_matches_camera(p,"SONY","ILCE-7RM5"),"camera match");
      require(!hyperdr::dcp_matches_camera(p,"SONY","ILCE-7M5"),"different camera rejected");
    }
    for (unsigned tag : {52529U,52525U,52544U}) {
      auto f=fixture(true); f.numbers(tag,4,{1});
      hyperdr::write_binary_file_atomic(path,f.bytes(),true);
      bool rejected=false;
      try { (void)hyperdr::read_dcp_profile(path); } catch(const std::runtime_error&) { rejected=true; }
      require(rejected,"unsupported rendering tags rejected");
    }
    auto truncated=fixture(true).bytes(); truncated.pop_back();
    hyperdr::write_binary_file_atomic(path,truncated,true);
    bool rejected=false;
    try { (void)hyperdr::read_dcp_profile(path); } catch(const std::runtime_error&) { rejected=true; }
    require(rejected,"truncated payload rejected");
    std::filesystem::remove(path);
    // Optional local profiles are never checked into the test fixtures.
    for(int i=1;i<argc;++i) {
      const auto p=hyperdr::read_dcp_profile(argv[i]);
      std::cout << p.name << " " << p.sha256 << " LUT=" << p.look_table.values.size()
                << " curve=" << p.tone_curve.size() << '\n';
    }
    std::cout << "DCP reader tests passed\n";
    return 0;
  } catch(const std::exception& error) {
    std::filesystem::remove(path);
    std::cerr << error.what() << '\n'; return 1;
  }
}
