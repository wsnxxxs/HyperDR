#include "hyperdr/codec/lens_profile.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iterator>
#include <map>
#include <regex>
#include <stdexcept>
#include <tuple>

namespace hyperdr {
namespace {
// LCP is an XMP property tree. Both Adobe's attribute and element serializations
// are accepted. No DTD, external entity or processing instruction is evaluated.
struct Node {
  std::string name, text;
  std::map<std::string, std::string> attributes;
  std::vector<Node> children;
  const Node* child(const std::string& key) const {
    for (const auto& c : children) if (c.name == key) return &c;
    return nullptr;
  }
  std::string value(const std::string& key) const {
    if (const auto it = attributes.find(key); it != attributes.end()) return it->second;
    if (const auto* c = child(key)) return c->text;
    return {};
  }
};
std::string local_name(std::string name) {
  const auto colon = name.find(':');
  return colon == std::string::npos ? name : name.substr(colon + 1);
}
Node parse(const std::string& xml) {
  Node root;
  std::vector<Node*> stack{&root};
  const std::regex attr(R"re(([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'))re");
  std::size_t pos = 0;
  while (pos < xml.size()) {
    const auto start = xml.find('<', pos);
    if (start == std::string::npos) break;
    stack.back()->text.append(xml, pos, start - pos);
    if (xml.compare(start, 4, "<!--") == 0) {
      const auto end = xml.find("-->", start + 4);
      if (end == std::string::npos) throw std::invalid_argument("Malformed LCP XML comment");
      pos = end + 3;
      continue;
    }
    char quote = 0;
    auto end = start + 1;
    for (; end < xml.size(); ++end) {
      const char c = xml[end];
      if (quote) { if (c == quote) quote = 0; }
      else if (c == '\'' || c == '"') quote = c;
      else if (c == '>') break;
    }
    if (end == xml.size()) throw std::invalid_argument("Malformed LCP XML tag");
    auto tag = xml.substr(start + 1, end - start - 1);
    pos = end + 1;
    if (tag.empty()) throw std::invalid_argument("Empty LCP XML tag");
    if (tag[0] == '?') continue;
    if (tag[0] == '!') throw std::invalid_argument("Unsupported LCP XML declaration");
    const bool closing = tag[0] == '/';
    const auto begin = closing ? 1U : 0U;
    const auto name_end = tag.find_first_of(" \t\r\n/", begin);
    const auto name = local_name(tag.substr(begin, name_end - begin));
    if (closing) {
      if (stack.size() == 1 || stack.back()->name != name)
        throw std::invalid_argument("Mismatched LCP XML tag");
      stack.pop_back();
    } else {
      stack.back()->children.push_back({});
      auto* node = &stack.back()->children.back();
      node->name = name;
      for (std::sregex_iterator it(tag.begin(), tag.end(), attr), last; it != last; ++it)
        node->attributes[local_name((*it)[1])] = (*it)[2].matched ? (*it)[2].str() : (*it)[3].str();
      if (tag.back() != '/') stack.push_back(node);
    }
  }
  if (stack.size() != 1) throw std::invalid_argument("Unclosed LCP XML tag");
  return root;
}
double number(const Node& node, const std::string& key, double fallback = 0) {
  const auto text = node.value(key);
  if (text.empty()) return fallback;
  std::size_t used = 0;
  const double value = std::stod(text, &used);
  if (!std::isfinite(value) || text.find_first_not_of(" \t\r\n", used) != std::string::npos)
    throw std::invalid_argument("Invalid LCP number: " + key);
  return value;
}
LensModel model(const Node& node, bool vignette, double fallback) {
  LensModel m;
  m.fx = number(node, "FocalLengthX", fallback);
  m.fy = number(node, "FocalLengthY", fallback);
  m.cx = number(node, "ImageXCenter", 0.5);
  m.cy = number(node, "ImageYCenter", 0.5);
  m.residual_error = std::abs(number(node, "ResidualMeanError",
      std::numeric_limits<double>::infinity()));
  if (!(m.fx > 0 && m.fy > 0)) throw std::invalid_argument("LCP requires explicit positive focal scales");
  for (unsigned i = 0; i < 3; ++i)
    m.radial[i] = number(node, (vignette ? "VignetteModelParam" : "RadialDistortParam") + std::to_string(i + 1));
  for (unsigned i = 0; i < 2; ++i)
    m.tangential[i] = number(node, "TangentialDistortParam" + std::to_string(i + 1));
  return m;
}
void collect(const Node& node, LensProfile& profile, Node inherited = {}) {
  for (const auto& [key,value] : node.attributes) inherited.attributes[key] = value;
  for (const auto& child : node.children)
    if (child.children.empty() && child.attributes.empty()) inherited.attributes[child.name] = child.text;
  if (node.name == "FisheyeModel") throw std::invalid_argument("Fisheye LCP profiles are not supported");
  if (const auto* perspective = node.child("PerspectiveModel")) {
    if (const auto* description = perspective->child("Description")) perspective = description;
    auto raw = inherited.value("CameraRawProfile");
    raw.erase(0,raw.find_first_not_of(" \t\r\n"));
    raw.erase(raw.find_last_not_of(" \t\r\n")+1);
    if (raw != "True" && raw != "true") throw std::invalid_argument("LCP must be a RAW profile");
    if (number(*perspective, "Version") != 2) throw std::invalid_argument("Unsupported LCP perspective version");
    LensCalibration c;
    c.focal_length = number(inherited, "FocalLength");
    c.aperture_value = number(inherited, "ApertureValue");
    c.focus_distance = number(inherited, "FocusDistance");
    if (!(c.focal_length > 0)) throw std::invalid_argument("LCP calibration has no focal length");
    // LCP's normalized focal length uses a 35 mm reference long edge.
    const double fallback = c.focal_length * number(inherited, "SensorFormatFactor") / 35.0;
    c.distortion = model(*perspective, false, fallback);
    if (const auto* v = perspective->child("VignetteModel")) {
      if (const auto* description = v->child("Description")) v = description;
      c.vignette = model(*v, true, fallback);
    }
    profile.calibrations.push_back(c);
  }
  for (const auto& child : node.children) collect(child, profile, inherited);
}
LensModel mix(const LensModel& a, const LensModel& b, double t) {
  const auto lerp = [t](double x, double y) { return x + (y - x) * t; };
  LensModel out;
  out.fx = lerp(a.fx, b.fx); out.fy = lerp(a.fy, b.fy);
  out.cx = lerp(a.cx, b.cx); out.cy = lerp(a.cy, b.cy);
  for (unsigned i = 0; i < 3; ++i) out.radial[i] = lerp(a.radial[i], b.radial[i]);
  for (unsigned i = 0; i < 2; ++i) out.tangential[i] = lerp(a.tangential[i], b.tangential[i]);
  return out;
}
std::array<double, 4> cubic_weights(double t) {
  // Interpolating Catmull-Rom kernel: exact at integer sample locations.
  const double t2 = t*t, t3 = t2*t;
  return {-0.5*t + t2 - 0.5*t3, 1 - 2.5*t2 + 1.5*t3,
          0.5*t + 2*t2 - 1.5*t3, -0.5*t2 + 0.5*t3};
}
std::optional<LensModel> interpolate(const LensProfile& p, double focal, double av, bool vignette) {
  std::map<double, std::vector<const LensCalibration*>> groups;
  for (const auto& c : p.calibrations)
    if (!vignette || c.vignette) groups[c.focal_length].push_back(&c);
  if (groups.empty()) return std::nullopt;
  auto hi = groups.lower_bound(focal);
  if (hi == groups.end()) hi = std::prev(groups.end());
  auto lo = hi;
  if (hi->first > focal && hi != groups.begin()) --lo;
  const auto at_focal = [&](const auto& entries) {
    const auto get = [vignette](const LensCalibration* c) { return vignette ? *c->vignette : c->distortion; };
    const auto rank = [&](const LensCalibration* c) {
      const auto m = get(c);
      // Without a reliable capture focus distance, use the best measured fit
      // at this focal length/aperture. Equal fits prefer distant calibration,
      // then coefficients for a deterministic tie, never XML record order.
      return std::tuple{m.residual_error, -c->focus_distance, m.fx, m.fy, m.cx, m.cy,
                        m.radial, m.tangential};
    };
    std::map<double, const LensCalibration*> apertures;
    for (const auto* c : entries) {
      auto& best = apertures[c->aperture_value];
      if (!best || rank(c) < rank(best)) best = c;
    }
    auto upper = apertures.lower_bound(av);
    if (upper == apertures.end()) upper = std::prev(apertures.end());
    auto lower = upper;
    if (upper->first > av && upper != apertures.begin()) --lower;
    const double delta = upper->first - lower->first;
    return mix(get(lower->second), get(upper->second),
        delta > 0 ? std::clamp((av - lower->first) / delta, 0.0, 1.0) : 0);
  };
  const double t = lo == hi ? 0 : (std::log(focal) - std::log(lo->first)) / (std::log(hi->first) - std::log(lo->first));
  return mix(at_focal(lo->second), at_focal(hi->second), t);
}
}  // namespace

LensProfile read_lens_profile(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::invalid_argument("Cannot read LCP profile");
  const std::string xml{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
  LensProfile p;
  collect(parse(xml), p);
  if (p.calibrations.empty()) throw std::invalid_argument("LCP has no supported perspective calibration");
  return p;
}

std::string apply_lens_profile(FloatImage& image, const LensProfile& profile,
                               double focal, double aperture, int flip) {
  image.require_consistent();
  if (!(std::isfinite(focal) && focal > 0)) throw std::invalid_argument("LCP correction requires RAW focal length");
  const double av = aperture > 0 ? 2 * std::log2(aperture) : 0;
  const auto distortion = interpolate(profile, focal, av, false);
  const auto vignette = aperture > 0 ? interpolate(profile, focal, av, true) : std::nullopt;
  if (!distortion) throw std::invalid_argument("LCP has no distortion calibration");
  const auto& m = *distortion;
  const double width = (flip & 4) ? image.height : image.width;
  const double height = (flip & 4) ? image.width : image.height;
  const double dmax = std::max(width, height);
  const auto to_sensor = [&](double x, double y) {
    if (flip & 4) std::swap(x, y);
    if (flip & 1) x = width - 1 - x;
    if (flip & 2) y = height - 1 - y;
    return std::array<double, 2>{x, y};
  };
  const auto from_sensor = [&](double x, double y) {
    if (flip & 1) x = width - 1 - x;
    if (flip & 2) y = height - 1 - y;
    if (flip & 4) std::swap(x, y);
    return std::array<double, 2>{x, y};
  };
  const auto vignette_gain = [&](double sx, double sy) {
    if (!vignette) return 1.0;
    const auto& v = *vignette;
    const double vx = (sx-v.cx*width)/(v.fx*dmax);
    const double vy = (sy-v.cy*height)/(v.fy*dmax);
    const double r2 = vx*vx + vy*vy;
    const double attenuation = 1 + r2*(v.radial[0]+r2*(v.radial[1]+r2*v.radial[2]));
    return 1 / std::max(attenuation, 0.05);
  };
  const auto correction = vignette ? "distortion,vignette" : "distortion";
  const bool has_distortion = std::any_of(m.radial.begin(), m.radial.end(),
      [](double v) { return v != 0; }) ||
      std::any_of(m.tangential.begin(), m.tangential.end(),
      [](double v) { return v != 0; });
  // Vignetting alone needs no geometric resampling or second image buffer.
  // In particular, floating-point roundoff in an identity map must not cause
  // an unnecessary auto-fill zoom and interpolation of every pixel.
  if (!has_distortion) {
    if (vignette) parallel_for_rows(image.height, [&](std::uint32_t row) {
      for (std::uint32_t col = 0; col < image.width; ++col) {
        const auto p = to_sensor(col, row);
        const double gain = vignette_gain(p[0], p[1]);
        const auto i = (static_cast<std::size_t>(row)*image.width+col)*image.channels;
        for (unsigned c = 0; c < image.channels; ++c)
          image.pixels[i+c] = static_cast<float>(image.pixels[i+c]*gain);
      }
    });
    return correction;
  }
  const auto map_sensor = [&](double px, double py, double zoom) {
    auto p = to_sensor(px, py);
    p[0] = (p[0] - (width-1)*0.5) / zoom + (width-1)*0.5;
    p[1] = (p[1] - (height-1)*0.5) / zoom + (height-1)*0.5;
    const double x = (p[0] - m.cx * width) / (m.fx * dmax);
    const double y = (p[1] - m.cy * height) / (m.fy * dmax);
    const double r2 = x*x + y*y;
    const double radial = 1 + r2 * (m.radial[0] + r2 * (m.radial[1] + r2 * m.radial[2]));
    return std::array<double,2>{
      (x*radial + 2*m.tangential[0]*x*y + m.tangential[1]*(r2+2*x*x))*m.fx*dmax + m.cx*width,
      (y*radial + m.tangential[0]*(r2+2*y*y) + 2*m.tangential[1]*x*y)*m.fy*dmax + m.cy*height};
  };
  const auto fits = [&](double zoom) {
    const auto inside = [&](double x, double y) {
      const auto p = map_sensor(x,y,zoom);
      return std::isfinite(p[0]) && std::isfinite(p[1]) && p[0] >= 0 && p[1] >= 0 && p[0] <= width-1 && p[1] <= height-1;
    };
    for (unsigned x = 0; x < image.width; ++x)
      if (!inside(x,0) || !inside(x,image.height-1)) return false;
    for (unsigned y = 0; y < image.height; ++y)
      if (!inside(0,y) || !inside(image.width-1,y)) return false;
    return true;
  };
  // Preserve output dimensions with the smallest centred zoom that fills the
  // frame. Check every border pixel, including asymmetric/tangential models.
  double zoom = 1;
  if (!fits(zoom)) {
    double lower = 1;
    while (zoom < 16 && !fits(zoom)) zoom *= 2;
    if (!fits(zoom)) throw std::invalid_argument("LCP cannot map a valid image area");
    for (unsigned i = 0; i < 24; ++i) {
      const double mid = (lower+zoom)*0.5;
      if (fits(mid)) zoom = mid; else lower = mid;
    }
  }
  FloatImage output(image.width, image.height, image.channels);
  parallel_for_rows(image.height, [&](std::uint32_t row) {
    for (std::uint32_t col = 0; col < image.width; ++col) {
      auto p = map_sensor(col, row, zoom);
      const double sx = p[0], sy = p[1];
      const double gain = vignette_gain(sx, sy);
      p = from_sensor(sx, sy);
      if (!std::isfinite(p[0]) || !std::isfinite(p[1]) || p[0] < 0 || p[1] < 0 || p[0] > image.width-1 || p[1] > image.height-1) continue;
      const auto x0 = static_cast<int>(p[0]), y0 = static_cast<int>(p[1]);
      const auto wx = cubic_weights(p[0]-x0), wy = cubic_weights(p[1]-y0);
      std::array<std::size_t,4> columns{}, rows{};
      for (int k = 0; k < 4; ++k) {
        columns[k] = static_cast<std::size_t>(std::clamp(x0+k-1, 0, int(image.width)-1))*image.channels;
        rows[k] = static_cast<std::size_t>(std::clamp(y0+k-1, 0, int(image.height)-1))*image.width*image.channels;
      }
      const auto dest = (static_cast<std::size_t>(row)*image.width+col)*image.channels;
      for (unsigned c = 0; c < image.channels; ++c) {
        double value = 0;
        float low = image.pixels[rows[0]+columns[0]+c], high = low;
        for (unsigned y = 0; y < 4; ++y) {
          double horizontal = 0;
          for (unsigned x = 0; x < 4; ++x) {
            const float v = image.pixels[rows[y]+columns[x]+c];
            horizontal += wx[x]*v;
            low = std::min(low,v); high = std::max(high,v);
          }
          value += wy[y]*horizontal;
        }
        // Bound ringing by the source neighbourhood, not [0,1]: negative
        // matrix values and HDR highlights still belong to scene-linear RAW.
        output.pixels[dest+c] = static_cast<float>(gain*std::clamp(value,double(low),double(high)));
      }
    }
  });
  image = std::move(output);
  return correction;
}
}  // namespace hyperdr
