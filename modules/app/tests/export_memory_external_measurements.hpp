#pragma once
// Method: see the header of export_memory_measurements.hpp.
// Measured /usr/bin/time -l peak footprint (largest of two runs) of exports with
// an external gain grid, macOS 27 / M6, quality default, output verification on.
// R6-E6-1 implementation. Photos: the checked-in 128x128 JPEG and generated
// TIFFs; grids: synthetic float32 files, v2 signed_log2_gain. Story is the
// 9:16 frame with a 0.16 caption band. Retained resources are the sidecar
// snapshot (4 bytes per grid pixel plus the report).
struct ExternalGainMeasurement {
  const char* name;
  unsigned pw,ph,cw,ch;
  hyperdr::OutputEncoding encoding;
  int depth;
  std::uint64_t grid_pixels, report_bytes, footprint;
  bool raw{false};
};
inline constexpr ExternalGainMeasurement external_gain_measurements[] = {
  {"smoke128:story:iso",128,128,144,256,hyperdr::OutputEncoding::IsoGainMapJpeg,8,16777216ULL,861,350012160ULL},
  {"smoke128:none:iso",128,128,128,128,hyperdr::OutputEncoding::IsoGainMapJpeg,8,16777216ULL,861,349946648ULL},
  {"smoke128:none:sdr-jpeg",128,128,128,128,hyperdr::OutputEncoding::SdrJpeg,8,9000000ULL,861,194380424ULL},
  {"tif2400:story:iso",2400,1600,2576,4580,hyperdr::OutputEncoding::IsoGainMapJpeg,8,3840000ULL,861,402342752ULL},
  {"tif2400:none:adaptive8",2400,1600,2400,1600,hyperdr::OutputEncoding::Adaptive,8,3840000ULL,861,326665248ULL},
  {"tif2400:story:sdr-jpeg",2400,1600,2576,4580,hyperdr::OutputEncoding::SdrJpeg,8,3840000ULL,861,356189000ULL},
  {"tif2400:none:pq",2400,1600,2400,1600,hyperdr::OutputEncoding::Pq,10,960000ULL,858,261325808ULL},
  {"tif4000:story:adaptive8",4000,3000,4328,7694,hyperdr::OutputEncoding::Adaptive,8,3000000ULL,861,999622192ULL},
  {"tif4000:none:iso",4000,3000,4000,3000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,47000ULL,855,738837512ULL},
  // R7-302: the 56 B/px SDR render with an external grid (a large photo and a
  // small grid) and a RAW source with a grid.
  {"tif6000:none:sdr-jpeg:grid64",6000,4000,6000,4000,hyperdr::OutputEncoding::SdrJpeg,8,4096ULL,858,1156187504ULL},
  {"tif6000:story:sdr-jpeg:grid64",6000,4000,6440,11450,hyperdr::OutputEncoding::SdrJpeg,8,4096ULL,858,1729775392ULL},
  {"arw:none:iso:grid4096",2768,1848,2768,1848,hyperdr::OutputEncoding::IsoGainMapJpeg,8,16777216ULL,861,811320712ULL,true},
  {"arw:story:iso:grid4096",2768,1848,2972,5284,hyperdr::OutputEncoding::IsoGainMapJpeg,8,16777216ULL,861,871761432ULL,true},
  {"arw:none:sdr-jpeg:grid4096",2768,1848,2768,1848,hyperdr::OutputEncoding::SdrJpeg,8,16777216ULL,861,751125872ULL,true},
};
