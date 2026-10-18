#include "hyperdr/image/frame.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include <limits>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
hyperdr::FrameSpec parse(std::string_view text) { return hyperdr::parse_frame_spec(hyperdr::json::parse(text)); }
const char* story = R"json({"schema":"hyperdr.frame/v1","background":"#E6E5E1","margins":{"top":0.055,"right":0.055,"bottom":0.04,"left":0.055},"caption":0.16,"reference":"short","aspect":{"width":9,"height":16,"topShare":0.42},"variants":{"wide":{"minRatio":2.5,"reference":"long","margins":{"top":0.02,"right":0.02,"bottom":0.02,"left":0.02},"caption":0.06,"aspect":null},"tall":{"maxRatio":0.125,"aspect":null}}})json";
void goldens() {
  struct Case { unsigned width, height; bool no_caption; const char* expected; };
  const Case cases[] = {
    {1000, 4000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":2393,"height":4254,"photo":{"x":696,"y":54,"width":1000,"height":4000},"caption":{"x":0,"y":4054,"width":2393,"height":200},"referenceEdge":1000})json"},
    {4000, 1000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":4160,"height":1400,"photo":{"x":80,"y":80,"width":4000,"height":1000},"caption":{"x":0,"y":1080,"width":4160,"height":320},"referenceEdge":4000,"variant":"wide"})json"},
    {10000, 1000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":10400,"height":2000,"photo":{"x":200,"y":200,"width":10000,"height":1000},"caption":{"x":0,"y":1200,"width":10400,"height":800},"referenceEdge":10000,"variant":"wide"})json"},
    {2500, 1000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":2608,"height":4636,"photo":{"x":54,"y":1474,"width":2500,"height":1000},"caption":{"x":0,"y":2474,"width":2608,"height":2162},"referenceEdge":1000})json"},
    {2600, 1000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":2704,"height":1260,"photo":{"x":52,"y":52,"width":2600,"height":1000},"caption":{"x":0,"y":1052,"width":2704,"height":208},"referenceEdge":2600,"variant":"wide"})json"},
    {1000, 8000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":4643,"height":8254,"photo":{"x":1822,"y":54,"width":1000,"height":8000},"caption":{"x":0,"y":8054,"width":4643,"height":200},"referenceEdge":1000})json"},
    {1000, 9000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":1108,"height":9254,"photo":{"x":54,"y":54,"width":1000,"height":9000},"caption":{"x":0,"y":9054,"width":1108,"height":200},"referenceEdge":1000,"variant":"tall"})json"},
    {6000, 4000, false, R"json({"schema":"hyperdr.frame-layout/v1","width":6440,"height":11449,"photo":{"x":220,"y":2920,"width":6000,"height":4000},"caption":{"x":0,"y":6920,"width":6440,"height":4529},"referenceEdge":4000})json"},
    {4000, 1000, true, R"json({"schema":"hyperdr.frame-layout/v1","width":4160,"height":1160,"photo":{"x":80,"y":80,"width":4000,"height":1000},"caption":{"x":0,"y":1080,"width":4160,"height":80},"referenceEdge":4000,"variant":"wide"})json"},
  };
  for (const auto& test : cases) {
    auto spec = parse(story);
    if (test.no_caption) {
      spec.caption = 0;
      for (auto& variant : spec.variants) if (variant.caption) variant.caption = 0;
    }
    const auto layout = hyperdr::layout_frame(spec, test.width, test.height);
    require(hyperdr::frame_layout_json(layout) == test.expected, "approved layout JSON differs");
  }
  const auto spec = parse(story);
  const auto canonical = hyperdr::frame_spec_json(spec);
  require(canonical == hyperdr::frame_spec_json(parse(canonical)), "variants must round-trip canonically");
  require(canonical.find("tall") < canonical.find("wide"), "canonical variants must sort by name");
  auto reordered = spec;
  std::reverse(reordered.variants.begin(), reordered.variants.end());
  require(canonical == hyperdr::frame_spec_json(reordered), "programmatic variant order must not affect canonical output");
}
void ratio_boundaries() {
  const auto precise = parse(R"({"variants":{"wide":{"minRatio":2.6}}})");
  require(hyperdr::layout_frame(precise,2600,1000).variant.empty(), "decimal threshold equality must not select");
  require(hyperdr::layout_frame(precise,2601,1000).variant == "wide", "one pixel above threshold must select");
  const auto tall = parse(R"({"variants":{"tall":{"maxRatio":0.1}}})");
  require(hyperdr::layout_frame(tall,1000,10000).variant.empty(), "upper decimal equality must not select");
  require(hyperdr::layout_frame(tall,999,10000).variant == "tall", "one pixel below threshold must select");
  const auto extreme = parse(R"({"variants":{"wide":{"minRatio":1e308},"tall":{"maxRatio":5e-324}}})");
  require(hyperdr::layout_frame(extreme,1000,1000).variant.empty(), "extreme positive thresholds must compare without overflow");
  const auto huge = parse(R"({"variants":{"wide":{"minRatio":2.5}}})");
  require(hyperdr::layout_frame(huge,4294967295U,1717986918U).variant.empty(), "large integer boundary must remain exact");
  require(hyperdr::layout_frame(huge,4294967294U,1717986917U).variant == "wide", "large products must not overflow");
  const auto tiny_delta = parse(R"({"variants":{"wide":{"minRatio":2.500000000000001}}})");
  require(hyperdr::frame_spec_json(tiny_delta) != hyperdr::frame_spec_json(huge), "canonical ratio must retain full precision");
}
void double_value_semantics() {
  struct Case { const char* literal; const char* rounded; unsigned width, height; };
  const Case cases[] = {
    {R"({"variants":{"wide":{"minRatio":2.5999999999999999}}})",
     R"({"variants":{"wide":{"minRatio":2.6}}})", 2600, 1000},
    {R"({"variants":{"tall":{"maxRatio":0.12500000000000001}}})",
     R"({"variants":{"tall":{"maxRatio":0.125}}})", 1000, 8000},
  };
  for (const auto& test : cases) {
    const auto literal = parse(test.literal), rounded = parse(test.rounded);
    require(hyperdr::frame_spec_json(literal) == hyperdr::frame_spec_json(rounded),
            "thresholds rounding to the same double must canonicalize identically");
    require(hyperdr::layout_frame(literal, test.width, test.height).variant.empty(),
            "rounded double equality must remain outside the open interval");
    for (const unsigned width : {test.width - 1, test.width, test.width + 1})
      require(hyperdr::layout_frame(literal, width, test.height) ==
                  hyperdr::layout_frame(rounded, width, test.height),
              "equivalent double thresholds must agree at equality and adjacent pixels");
  }
}
void rejected_documents() {
  const char* documents[] = {
    R"({"variants":[]})", R"({"variants":null})",
    R"({"variants":{"wide":{}}})",
    R"({"variants":{"wide":{"minRatio":2.5,"maxRatio":0.125}}})",
    R"({"variants":{"wide":{"minRatio":1}}})",
    R"({"variants":{"wide":{"minRatio":"2.5"}}})",
    R"({"variants":{"tall":{"maxRatio":1}}})",
    R"({"variants":{"tall":{"maxRatio":0}}})",
    R"({"variants":{"tall":{"maxRatio":-1}}})",
    R"({"variants":{"a":{"minRatio":2},"b":{"minRatio":3}}})",
    R"({"variants":{"a":{"maxRatio":0.1},"b":{"maxRatio":0.2}}})",
    R"({"variants":{"":{"minRatio":2}}})", R"({"variants":{"Wide":{"minRatio":2}}})",
    R"({"variants":{"a_b":{"minRatio":2}}})",
    R"({"variants":{"abcdefghijklmnopqrstuvwxyz1234567":{"minRatio":2}}})",
    R"({"variants":{"a":{},"b":{},"c":{},"d":{},"e":{}}})",
    R"({"variants":{"a":{"minRatio":2,"margins":0.6}}})",
    R"({"variants":{"a":{"minRatio":2,"caption":1.1}}})",
    R"({"variants":{"a":{"minRatio":2,"reference":"bad"}}})",
    R"({"variants":{"a":{"minRatio":2,"aspect":{"width":9}}}})"
  };
  const auto rejects = [](std::string_view text) {
    try { (void)parse(text); }
    catch (const std::invalid_argument& error) {
      require(std::string(error.what()).starts_with("frame:"), "invalid variants must identify the frame");
      return;
    }
    throw std::runtime_error("invalid variants accepted: " + std::string(text));
  };
  for (const auto* document : documents) rejects(document);
  for (const auto* key : {"background","shadow","overlay","schema","variants"})
    rejects("{\"variants\":{\"wide\":{\"minRatio\":2.5,\"" + std::string(key) + "\":null}}}");
}
void scan_ratios() {
  const auto spec = parse(story);
  for (unsigned short_edge : {1000U,4000U}) {
    for (double log_ratio = -std::log(40.0); log_ratio <= std::log(40.0); log_ratio += 0.05) {
      const double ratio = std::exp(log_ratio);
      const auto width = ratio >= 1 ? static_cast<unsigned>(std::llround(short_edge*ratio)) : short_edge;
      const auto height = ratio >= 1 ? short_edge : static_cast<unsigned>(std::llround(short_edge/ratio));
      const auto layout = hyperdr::layout_frame(spec,width,height);
      const double area = static_cast<double>(layout.width)*layout.height / (static_cast<double>(width)*height);
      if (layout.variant.empty()) require(area <= 4.9, "portrait card exceeds area budget");
      if (layout.variant == "wide" && ratio <= 20) require(area <= 3.2, "wide card exceeds 20:1 area budget");
      if (layout.variant == "wide") require(area <= 5.3, "wide card exceeds 40:1 area budget");
    }
    const auto layout = hyperdr::layout_frame(spec,40*short_edge,short_edge);
    require(static_cast<double>(layout.width)*layout.height/(40.0*short_edge*short_edge) <= 5.3,"40:1 endpoint");
    (void)hyperdr::layout_frame(spec,short_edge,40*short_edge);
  }
  try { (void)hyperdr::layout_frame(spec,60000,1000); }
  catch (const std::invalid_argument& error) {
    require(std::string(error.what()).find("six times") != std::string::npos, "sixfold guard changed"); return;
  }
  throw std::runtime_error("sixfold area guard was bypassed");
}
}
int main() {
  try { goldens(); ratio_boundaries(); double_value_semantics(); rejected_documents(); scan_ratios(); }
  catch (const std::exception& error) { std::cerr << "frame_variant_test: " << error.what() << '\n'; return 1; }
  std::cout << "frame_variant_test passed\n";
}
