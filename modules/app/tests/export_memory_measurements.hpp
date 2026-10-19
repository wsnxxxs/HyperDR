#pragma once
// Measured /usr/bin/time -l peak footprint on macOS 27 / M6, quality 90.
// E6 implementation, based on 5ae7e4b5; before binary: 8033bf09.
// Sources: public sony-ilce-7s.ARW and the read-only 61MP user RAW.
// Failed codec cases are recorded in batch3-report.md, not used to claim a
// completed encoding/verification peak. HEIC verification: remeasure at P3b-4.
struct ExportMeasurement {
  const char* name;
  unsigned pw,ph,cw,ch;
  hyperdr::OutputEncoding encoding;
  int depth;
  std::uint64_t footprint;
};
inline constexpr ExportMeasurement export_measurements[] = {
  {"small:none:iso-gainmap-jpeg:8",2768,1848,2768,1848,hyperdr::OutputEncoding::IsoGainMapJpeg,8,421037160ULL},
  {"small:none:adaptive:8",2768,1848,2768,1848,hyperdr::OutputEncoding::Adaptive,8,420807928ULL},
  {"small:none:adaptive:10",2768,1848,2768,1848,hyperdr::OutputEncoding::Adaptive,10,422511840ULL},
  {"small:none:pq:10",2768,1848,2768,1848,hyperdr::OutputEncoding::Pq,10,420775136ULL},
  {"small:none:avif-pq:10",2768,1848,2768,1848,hyperdr::OutputEncoding::AvifPq,10,567248216ULL},
  {"small:none:sdr-jpeg:8",2768,1848,2768,1848,hyperdr::OutputEncoding::SdrJpeg,8,280675360ULL},
  {"small:gallery:iso-gainmap-jpeg:8",2768,1848,2988,2308,hyperdr::OutputEncoding::IsoGainMapJpeg,8,444777672ULL},
  {"small:gallery:adaptive:8",2768,1848,2988,2308,hyperdr::OutputEncoding::Adaptive,8,442369320ULL},
  {"small:gallery:adaptive:10",2768,1848,2988,2308,hyperdr::OutputEncoding::Adaptive,10,442467624ULL},
  {"small:gallery:pq:10",2768,1848,2988,2308,hyperdr::OutputEncoding::Pq,10,420873440ULL},
  {"small:gallery:avif-pq:10",2768,1848,2988,2308,hyperdr::OutputEncoding::AvifPq,10,618825096ULL},
  {"small:gallery:sdr-jpeg:8",2768,1848,2988,2308,hyperdr::OutputEncoding::SdrJpeg,8,300581968ULL},
  {"small:story:iso-gainmap-jpeg:8",2768,1848,2972,5284,hyperdr::OutputEncoding::IsoGainMapJpeg,8,654558552ULL},
  {"small:story:adaptive:8",2768,1848,2972,5284,hyperdr::OutputEncoding::Adaptive,8,624739768ULL},
  {"small:story:adaptive:10",2768,1848,2972,5284,hyperdr::OutputEncoding::Adaptive,10,624821640ULL},
  {"small:story:pq:10",2768,1848,2972,5284,hyperdr::OutputEncoding::Pq,10,486655344ULL},
  {"small:story:avif-pq:10",2768,1848,2972,5284,hyperdr::OutputEncoding::AvifPq,10,1131448144ULL},
  {"small:story:sdr-jpeg:8",2768,1848,2972,5284,hyperdr::OutputEncoding::SdrJpeg,8,444253336ULL},
  {"large:none:iso-gainmap-jpeg:8",9504,6336,9504,6336,hyperdr::OutputEncoding::IsoGainMapJpeg,8,3200093184ULL},
  {"large:none:adaptive:8",9504,6336,9504,6336,hyperdr::OutputEncoding::Adaptive,8,3201354848ULL},
  {"large:none:adaptive:10",9504,6336,9504,6336,hyperdr::OutputEncoding::Adaptive,10,3201404000ULL},
  {"large:none:pq:10",9504,6336,9504,6336,hyperdr::OutputEncoding::Pq,10,3201420384ULL},
  {"large:none:avif-pq:10",9504,6336,9504,6336,hyperdr::OutputEncoding::AvifPq,10,4451603208ULL},
  {"large:none:sdr-jpeg:8",9504,6336,9504,6336,hyperdr::OutputEncoding::SdrJpeg,8,2225015064ULL},
  {"large:gallery:iso-gainmap-jpeg:8",9504,6336,10264,7920,hyperdr::OutputEncoding::IsoGainMapJpeg,8,3414297864ULL},
  {"large:gallery:adaptive:8",9504,6336,10264,7920,hyperdr::OutputEncoding::Adaptive,8,3393752400ULL},
  {"large:gallery:adaptive:10",9504,6336,10264,7920,hyperdr::OutputEncoding::Adaptive,10,3454651680ULL},
  {"large:gallery:pq:10",9504,6336,10264,7920,hyperdr::OutputEncoding::Pq,10,3201404024ULL},
  {"large:gallery:avif-pq:10",9504,6336,10264,7920,hyperdr::OutputEncoding::AvifPq,10,4892759248ULL},
  {"large:gallery:sdr-jpeg:8",9504,6336,10264,7920,hyperdr::OutputEncoding::SdrJpeg,8,2473167344ULL},
  {"large:story:iso-gainmap-jpeg:8",9504,6336,10200,18134,hyperdr::OutputEncoding::IsoGainMapJpeg,8,4761964720ULL},
  // E8: 10200x18134 is written as a 3x5 AVIF grid (libaom cannot hold it as one frame).
  {"large:story:avif-pq:10",9504,6336,10200,18134,hyperdr::OutputEncoding::AvifPq,10,4321104240ULL},
  {"large:story:pq:10",9504,6336,10200,18134,hyperdr::OutputEncoding::Pq,10,3915501288ULL},
  {"large:story:sdr-jpeg:8",9504,6336,10200,18134,hyperdr::OutputEncoding::SdrJpeg,8,3718090088ULL},
};
