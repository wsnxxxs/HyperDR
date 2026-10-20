#pragma once
// Method: see the header of export_memory_measurements.hpp.
// Measured /usr/bin/time -l peak footprint of exports whose input is a HEIC
// read by our own HEIF reader (P3b-4), macOS 27 / M6, default look, quality 90,
// write-time verification on (the tile-wise path of the same reader).
// Photos are the user's read-only samples: IMG_3891 (ISO 21496-1 gain map,
// 5712x4284, authored SDR rendition retained), IMG_3250 (older Apple gain map,
// 4032x3024, same) and DSC01422 (Sony 4:2:2 HLG, single rendition, 6336x9504
// after orientation). Gallery is margins 0.06 + caption 0.13; story is the
// 9:16 card. The measured decode alone (decode_image, no export) peaks at
// 921 MB (37.6 B/px) for IMG_3891, 319 MB (26.1 B/px) for IMG_3250 and 776 MB
// (12.9 B/px) for DSC01422: the dual-rendition decode holds the HDR and the
// authored SDR float planes beside the gain map, the single rendition only
// its own float RGB.
struct HeicInputMeasurement {
  const char* name;
  unsigned pw,ph,cw,ch;
  hyperdr::OutputEncoding encoding;
  int depth;
  bool dual;  // authored SDR rendition present (Apple/ISO gain map HEIC)
  std::uint64_t footprint;
};
inline constexpr HeicInputMeasurement heic_input_measurements[] = {
  {"ios-iso:none:adaptive:8",5712,4284,5712,4284,hyperdr::OutputEncoding::Adaptive,8,true,1200227984ULL},
  {"ios-iso:none:adaptive:10",5712,4284,5712,4284,hyperdr::OutputEncoding::Adaptive,10,true,1200113320ULL},
  {"ios-iso:none:pq:10",5712,4284,5712,4284,hyperdr::OutputEncoding::Pq,10,true,1200326336ULL},
  {"ios-iso:none:iso-gainmap-jpeg:8",5712,4284,5712,4284,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,1199048192ULL},
  {"ios-iso:none:sdr-jpeg:8",5712,4284,5712,4284,hyperdr::OutputEncoding::SdrJpeg,8,true,931579224ULL},
  {"ios-iso:gallery:adaptive:8",5712,4284,6228,5356,hyperdr::OutputEncoding::Adaptive,8,true,1200080528ULL},
  {"ios-iso:gallery:pq:10",5712,4284,6228,5356,hyperdr::OutputEncoding::Pq,10,true,1200277184ULL},
  {"ios-iso:gallery:iso-gainmap-jpeg:8",5712,4284,6228,5356,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,1199146496ULL},
  {"ios-iso:gallery:sdr-jpeg:8",5712,4284,6228,5356,hyperdr::OutputEncoding::SdrJpeg,8,true,930694464ULL},
  {"ios-iso:story:adaptive:8",5712,4284,6184,10994,hyperdr::OutputEncoding::Adaptive,8,true,1475954584ULL},
  {"ios-iso:story:pq:10",5712,4284,6184,10994,hyperdr::OutputEncoding::Pq,10,true,1201833640ULL},
  {"ios-iso:story:iso-gainmap-jpeg:8",5712,4284,6184,10994,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,1429685952ULL},
  {"ios-iso:story:sdr-jpeg:8",5712,4284,6184,10994,hyperdr::OutputEncoding::SdrJpeg,8,true,1265698400ULL},
  {"ios-old:none:adaptive:8",4032,3024,4032,3024,hyperdr::OutputEncoding::Adaptive,8,true,608961808ULL},
  {"ios-old:none:adaptive:10",4032,3024,4032,3024,hyperdr::OutputEncoding::Adaptive,10,true,608634104ULL},
  {"ios-old:none:pq:10",4032,3024,4032,3024,hyperdr::OutputEncoding::Pq,10,true,608781536ULL},
  {"ios-old:none:iso-gainmap-jpeg:8",4032,3024,4032,3024,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,607716432ULL},
  {"ios-old:none:sdr-jpeg:8",4032,3024,4032,3024,hyperdr::OutputEncoding::SdrJpeg,8,true,461374400ULL},
  {"sony-hlg:none:adaptive:8",6336,9504,6336,9504,hyperdr::OutputEncoding::Adaptive,8,false,2286406056ULL},
  {"sony-hlg:none:adaptive:10",6336,9504,6336,9504,hyperdr::OutputEncoding::Adaptive,10,false,2286586280ULL},
  {"sony-hlg:none:pq:10",6336,9504,6336,9504,hyperdr::OutputEncoding::Pq,10,false,2286586304ULL},
  {"sony-hlg:none:iso-gainmap-jpeg:8",6336,9504,6336,9504,hyperdr::OutputEncoding::IsoGainMapJpeg,8,false,2288748848ULL},
  {"sony-hlg:none:sdr-jpeg:8",6336,9504,6336,9504,hyperdr::OutputEncoding::SdrJpeg,8,false,1505396464ULL},
  {"sony-hlg:gallery:adaptive:8",6336,9504,7096,11088,hyperdr::OutputEncoding::Adaptive,8,false,2509425232ULL},
  {"sony-hlg:gallery:pq:10",6336,9504,7096,11088,hyperdr::OutputEncoding::Pq,10,false,2287536600ULL},
  {"sony-hlg:gallery:iso-gainmap-jpeg:8",6336,9504,7096,11088,hyperdr::OutputEncoding::IsoGainMapJpeg,8,false,2525792776ULL},
  {"sony-hlg:gallery:sdr-jpeg:8",6336,9504,7096,11088,hyperdr::OutputEncoding::SdrJpeg,8,false,1724860312ULL},
  {"sony-hlg:story:adaptive:8",6336,9504,7032,12502,hyperdr::OutputEncoding::Adaptive,8,false,2619640496ULL},
  {"sony-hlg:story:pq:10",6336,9504,7032,12502,hyperdr::OutputEncoding::Pq,10,false,2288044480ULL},
  {"sony-hlg:story:iso-gainmap-jpeg:8",6336,9504,7032,12502,hyperdr::OutputEncoding::IsoGainMapJpeg,8,false,2646641184ULL},
  {"sony-hlg:story:sdr-jpeg:8",6336,9504,7032,12502,hyperdr::OutputEncoding::SdrJpeg,8,false,1834829744ULL},
  {"ios-iso:none:avif-pq:10",5712,4284,5712,4284,hyperdr::OutputEncoding::AvifPq,10,true,1729038400ULL},
  {"ios-iso:gallery:avif-pq:10",5712,4284,6228,5356,hyperdr::OutputEncoding::AvifPq,10,true,1830078696ULL},
  {"ios-iso:story:avif-pq:10",5712,4284,6184,10994,hyperdr::OutputEncoding::AvifPq,10,true,3861499648ULL},
  {"ios-old:none:avif-pq:10",4032,3024,4032,3024,hyperdr::OutputEncoding::AvifPq,10,true,879052192ULL},
  {"ios-old:gallery:avif-pq:10",4032,3024,4396,3782,hyperdr::OutputEncoding::AvifPq,10,true,936773096ULL},
  {"ios-old:story:avif-pq:10",4032,3024,4364,7758,hyperdr::OutputEncoding::AvifPq,10,true,1948813640ULL},
  {"sony-hlg:none:avif-pq:10",6336,9504,6336,9504,hyperdr::OutputEncoding::AvifPq,10,false,4228255752ULL},
  {"sony-hlg:gallery:avif-pq:10",6336,9504,7096,11088,hyperdr::OutputEncoding::AvifPq,10,false,4368749032ULL},
  {"sony-hlg:story:avif-pq:10",6336,9504,7032,12502,hyperdr::OutputEncoding::AvifPq,10,false,5076800336ULL},
  // R7-1301: the same two iPhone photos with a 17^3 colour LUT at strength 1. A LUT
  // adds nothing to an imported pair (footprints within 3% of the runs without it).
  {"ios-iso-lut:none:iso-gainmap-jpeg:8",5712,4284,5712,4284,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,1199736344ULL},
  {"ios-iso-lut:gallery:iso-gainmap-jpeg:8",5712,4284,6228,5356,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,1199982104ULL},
  {"ios-iso-lut:story:iso-gainmap-jpeg:8",5712,4284,6184,10994,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,1428801264ULL},
  {"ios-iso-lut:none:adaptive:8",5712,4284,5712,4284,hyperdr::OutputEncoding::Adaptive,8,true,1200916136ULL},
  {"ios-iso-lut:gallery:adaptive:8",5712,4284,6228,5356,hyperdr::OutputEncoding::Adaptive,8,true,1201342168ULL},
  {"ios-iso-lut:story:adaptive:8",5712,4284,6184,10994,hyperdr::OutputEncoding::Adaptive,8,true,1478035304ULL},
  {"ios-iso-lut:none:adaptive:10",5712,4284,5712,4284,hyperdr::OutputEncoding::Adaptive,10,true,1202407080ULL},
  {"ios-iso-lut:gallery:adaptive:10",5712,4284,6228,5356,hyperdr::OutputEncoding::Adaptive,10,true,1201047184ULL},
  {"ios-iso-lut:story:adaptive:10",5712,4284,6184,10994,hyperdr::OutputEncoding::Adaptive,10,true,1476216728ULL},
  {"ios-iso-lut:none:pq:10",5712,4284,5712,4284,hyperdr::OutputEncoding::Pq,10,true,1200834216ULL},
  {"ios-iso-lut:gallery:pq:10",5712,4284,6228,5356,hyperdr::OutputEncoding::Pq,10,true,1202636480ULL},
  {"ios-iso-lut:story:pq:10",5712,4284,6184,10994,hyperdr::OutputEncoding::Pq,10,true,1200768704ULL},
  {"ios-iso-lut:none:avif-pq:10",5712,4284,5712,4284,hyperdr::OutputEncoding::AvifPq,10,true,1729890392ULL},
  {"ios-iso-lut:gallery:avif-pq:10",5712,4284,6228,5356,hyperdr::OutputEncoding::AvifPq,10,true,1937066192ULL},
  {"ios-iso-lut:story:avif-pq:10",5712,4284,6184,10994,hyperdr::OutputEncoding::AvifPq,10,true,3862056728ULL},
  {"ios-iso-lut:none:sdr-jpeg:8",5712,4284,5712,4284,hyperdr::OutputEncoding::SdrJpeg,8,true,931595608ULL},
  {"ios-iso-lut:gallery:sdr-jpeg:8",5712,4284,6228,5356,hyperdr::OutputEncoding::SdrJpeg,8,true,930841944ULL},
  {"ios-iso-lut:story:sdr-jpeg:8",5712,4284,6184,10994,hyperdr::OutputEncoding::SdrJpeg,8,true,1263732296ULL},
  {"ios-apple-lut:none:iso-gainmap-jpeg:8",4032,3024,4032,3024,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,608765008ULL},
  {"ios-apple-lut:gallery:iso-gainmap-jpeg:8",4032,3024,4396,3782,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,608748648ULL},
  {"ios-apple-lut:story:iso-gainmap-jpeg:8",4032,3024,4364,7758,hyperdr::OutputEncoding::IsoGainMapJpeg,8,true,722601136ULL},
  {"ios-apple-lut:none:adaptive:8",4032,3024,4032,3024,hyperdr::OutputEncoding::Adaptive,8,true,609682680ULL},
  {"ios-apple-lut:gallery:adaptive:8",4032,3024,4396,3782,hyperdr::OutputEncoding::Adaptive,8,true,609666248ULL},
  {"ios-apple-lut:story:adaptive:8",4032,3024,4364,7758,hyperdr::OutputEncoding::Adaptive,8,true,746489176ULL},
  {"ios-apple-lut:none:adaptive:10",4032,3024,4032,3024,hyperdr::OutputEncoding::Adaptive,10,true,609813728ULL},
  {"ios-apple-lut:gallery:adaptive:10",4032,3024,4396,3782,hyperdr::OutputEncoding::Adaptive,10,true,609699064ULL},
  {"ios-apple-lut:story:adaptive:10",4032,3024,4364,7758,hyperdr::OutputEncoding::Adaptive,10,true,746571072ULL},
  {"ios-apple-lut:none:pq:10",4032,3024,4032,3024,hyperdr::OutputEncoding::Pq,10,true,609666248ULL},
  {"ios-apple-lut:gallery:pq:10",4032,3024,4396,3782,hyperdr::OutputEncoding::Pq,10,true,609912056ULL},
  {"ios-apple-lut:story:pq:10",4032,3024,4364,7758,hyperdr::OutputEncoding::Pq,10,true,609682632ULL},
  {"ios-apple-lut:none:avif-pq:10",4032,3024,4032,3024,hyperdr::OutputEncoding::AvifPq,10,true,879002992ULL},
  {"ios-apple-lut:gallery:avif-pq:10",4032,3024,4396,3782,hyperdr::OutputEncoding::AvifPq,10,true,983795200ULL},
  {"ios-apple-lut:story:avif-pq:10",4032,3024,4364,7758,hyperdr::OutputEncoding::AvifPq,10,true,1948502272ULL},
  {"ios-apple-lut:none:sdr-jpeg:8",4032,3024,4032,3024,hyperdr::OutputEncoding::SdrJpeg,8,true,462504896ULL},
  {"ios-apple-lut:gallery:sdr-jpeg:8",4032,3024,4396,3782,hyperdr::OutputEncoding::SdrJpeg,8,true,462423000ULL},
  {"ios-apple-lut:story:sdr-jpeg:8",4032,3024,4364,7758,hyperdr::OutputEncoding::SdrJpeg,8,true,635405440ULL},
};
