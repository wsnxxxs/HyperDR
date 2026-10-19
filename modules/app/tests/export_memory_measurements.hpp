#pragma once
// Measured /usr/bin/time -l peak footprint on macOS 27 / M6, quality 90.
// E6 implementation, based on 5ae7e4b5; before binary: 8033bf09.
// Sources: public sony-ilce-7s.ARW and the read-only 61MP user RAW.
// Failed codec cases are recorded in batch3-report.md, not used to claim a
// completed encoding/verification peak. P3b-4: the HEIC rows were remeasured
// with write-time verification on our own reader (all within 2% of the libheif
// run: verification was never the peak) and the two large story Adaptive rows,
// which libheif could not verify (1445 items), were added. The standalone
// verification of the 61 MP file peaks at 40-78 MB (was 0.59-0.93 GB).
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
  {"large:story:adaptive:8",9504,6336,10200,18134,hyperdr::OutputEncoding::Adaptive,8,4922184552ULL},
  {"large:story:adaptive:10",9504,6336,10200,18134,hyperdr::OutputEncoding::Adaptive,10,4921611112ULL},
  {"large:story:pq:10",9504,6336,10200,18134,hyperdr::OutputEncoding::Pq,10,3915501288ULL},
  {"large:story:sdr-jpeg:8",9504,6336,10200,18134,hyperdr::OutputEncoding::SdrJpeg,8,3718090088ULL},
};

// R7-301: raster (JPEG/TIFF) sources, which have none of the RAW renderer's fixed
// 192 MiB overhead to hide an under-estimate. Measured /usr/bin/time -l peak
// footprint (largest of two runs), macOS 27 / M6, CLI convert, quality default,
// output verification on, E8 tree (7711c377 plus the follow-up). Inputs are
// generated gradient/checker photos: 24 MP (6000x4000) as TIFF (t24) and JPEG
// (j24), 12 MP (4000x3000) as TIFF (t12) and JPEG (j12). Gallery is a 0.06 mat
// with a 0.13 caption band; story is the 9:16 frame of the RAW matrix above.
// P3b-4: the Adaptive and PQ rows were measured again with the tile-wise HEIC
// verification, from regenerated photos of the same sizes and kinds (largest of
// two runs); none moved by more than 2.1%, verification was never their peak.
inline constexpr ExportMeasurement raster_export_measurements[] = {
  {"raster-t24:none:iso-gainmap-jpeg:8",6000,4000,6000,4000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1132578136ULL},
  {"raster-t24:gallery:iso-gainmap-jpeg:8",6000,4000,6480,5000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1241728440ULL},
  {"raster-t24:story:iso-gainmap-jpeg:8",6000,4000,6440,11450,hyperdr::OutputEncoding::IsoGainMapJpeg,8,2236041328ULL},
  {"raster-t24:none:adaptive:8",6000,4000,6000,4000,hyperdr::OutputEncoding::Adaptive,8,1159267984ULL},
  {"raster-t24:gallery:adaptive:8",6000,4000,6480,5000,hyperdr::OutputEncoding::Adaptive,8,1260521176ULL},
  {"raster-t24:story:adaptive:8",6000,4000,6440,11450,hyperdr::OutputEncoding::Adaptive,8,2108459312ULL},
  {"raster-t24:none:adaptive:10",6000,4000,6000,4000,hyperdr::OutputEncoding::Adaptive,10,1160234664ULL},
  {"raster-t24:gallery:adaptive:10",6000,4000,6480,5000,hyperdr::OutputEncoding::Adaptive,10,1260898008ULL},
  {"raster-t24:story:adaptive:10",6000,4000,6440,11450,hyperdr::OutputEncoding::Adaptive,10,2108705144ULL},
  {"raster-t24:none:pq:10",6000,4000,6000,4000,hyperdr::OutputEncoding::Pq,10,1160005288ULL},
  {"raster-t24:gallery:pq:10",6000,4000,6480,5000,hyperdr::OutputEncoding::Pq,10,1159284320ULL},
  {"raster-t24:story:pq:10",6000,4000,6440,11450,hyperdr::OutputEncoding::Pq,10,1468630912ULL},
  {"raster-t24:none:avif-pq:10",6000,4000,6000,4000,hyperdr::OutputEncoding::AvifPq,10,1849804792ULL},
  {"raster-t24:gallery:avif-pq:10",6000,4000,6480,5000,hyperdr::OutputEncoding::AvifPq,10,2075560024ULL},
  {"raster-t24:story:avif-pq:10",6000,4000,6440,11450,hyperdr::OutputEncoding::AvifPq,10,4404121584ULL},
  {"raster-t24:none:sdr-jpeg:8",6000,4000,6000,4000,hyperdr::OutputEncoding::SdrJpeg,8,594707416ULL},
  {"raster-t24:gallery:sdr-jpeg:8",6000,4000,6480,5000,hyperdr::OutputEncoding::SdrJpeg,8,695895048ULL},
  {"raster-t24:story:sdr-jpeg:8",6000,4000,6440,11450,hyperdr::OutputEncoding::SdrJpeg,8,1350485504ULL},
  {"raster-j24:none:iso-gainmap-jpeg:8",6000,4000,6000,4000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1154532696ULL},
  {"raster-j24:gallery:iso-gainmap-jpeg:8",6000,4000,6480,5000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1264125320ULL},
  {"raster-j24:story:iso-gainmap-jpeg:8",6000,4000,6440,11450,hyperdr::OutputEncoding::IsoGainMapJpeg,8,2258323544ULL},
  {"raster-j24:none:adaptive:8",6000,4000,6000,4000,hyperdr::OutputEncoding::Adaptive,8,1159710328ULL},
  {"raster-j24:gallery:adaptive:8",6000,4000,6480,5000,hyperdr::OutputEncoding::Adaptive,8,1260406488ULL},
  {"raster-j24:story:adaptive:8",6000,4000,6440,11450,hyperdr::OutputEncoding::Adaptive,8,2108524872ULL},
  {"raster-j24:none:adaptive:10",6000,4000,6000,4000,hyperdr::OutputEncoding::Adaptive,10,1159612024ULL},
  {"raster-j24:gallery:adaptive:10",6000,4000,6480,5000,hyperdr::OutputEncoding::Adaptive,10,1260324544ULL},
  {"raster-j24:story:adaptive:10",6000,4000,6440,11450,hyperdr::OutputEncoding::Adaptive,10,2108803400ULL},
  {"raster-j24:none:pq:10",6000,4000,6000,4000,hyperdr::OutputEncoding::Pq,10,1159775888ULL},
  {"raster-j24:gallery:pq:10",6000,4000,6480,5000,hyperdr::OutputEncoding::Pq,10,1159497336ULL},
  {"raster-j24:story:pq:10",6000,4000,6440,11450,hyperdr::OutputEncoding::Pq,10,1468581760ULL},
  {"raster-j24:none:avif-pq:10",6000,4000,6000,4000,hyperdr::OutputEncoding::AvifPq,10,1872365608ULL},
  {"raster-j24:gallery:avif-pq:10",6000,4000,6480,5000,hyperdr::OutputEncoding::AvifPq,10,2037565528ULL},
  {"raster-j24:story:avif-pq:10",6000,4000,6440,11450,hyperdr::OutputEncoding::AvifPq,10,4415098912ULL},
  {"raster-j24:none:sdr-jpeg:8",6000,4000,6000,4000,hyperdr::OutputEncoding::SdrJpeg,8,662422488ULL},
  {"raster-j24:gallery:sdr-jpeg:8",6000,4000,6480,5000,hyperdr::OutputEncoding::SdrJpeg,8,763659344ULL},
  {"raster-j24:story:sdr-jpeg:8",6000,4000,6440,11450,hyperdr::OutputEncoding::SdrJpeg,8,1381008896ULL},
  {"raster-t12:none:iso-gainmap-jpeg:8",4000,3000,4000,3000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,582681512ULL},
  {"raster-t12:gallery:iso-gainmap-jpeg:8",4000,3000,4360,3750,hyperdr::OutputEncoding::IsoGainMapJpeg,8,639403016ULL},
  {"raster-t12:story:iso-gainmap-jpeg:8",4000,3000,4328,7694,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1038320912ULL},
  {"raster-t12:none:adaptive:8",4000,3000,4000,3000,hyperdr::OutputEncoding::Adaptive,8,596575480ULL},
  {"raster-t12:gallery:adaptive:8",4000,3000,4360,3750,hyperdr::OutputEncoding::Adaptive,8,651298112ULL},
  {"raster-t12:story:adaptive:8",4000,3000,4328,7694,hyperdr::OutputEncoding::Adaptive,8,996394496ULL},
  {"raster-t12:none:adaptive:10",4000,3000,4000,3000,hyperdr::OutputEncoding::Adaptive,10,596657424ULL},
  {"raster-t12:gallery:adaptive:10",4000,3000,4360,3750,hyperdr::OutputEncoding::Adaptive,10,649676048ULL},
  {"raster-t12:story:adaptive:10",4000,3000,4328,7694,hyperdr::OutputEncoding::Adaptive,10,996361752ULL},
  {"raster-t12:none:pq:10",4000,3000,4000,3000,hyperdr::OutputEncoding::Pq,10,597132536ULL},
  {"raster-t12:gallery:pq:10",4000,3000,4360,3750,hyperdr::OutputEncoding::Pq,10,597968120ULL},
  {"raster-t12:story:pq:10",4000,3000,4328,7694,hyperdr::OutputEncoding::Pq,10,708511064ULL},
  {"raster-t12:none:avif-pq:10",4000,3000,4000,3000,hyperdr::OutputEncoding::AvifPq,10,943211840ULL},
  {"raster-t12:gallery:avif-pq:10",4000,3000,4360,3750,hyperdr::OutputEncoding::AvifPq,10,1074627928ULL},
  {"raster-t12:story:avif-pq:10",4000,3000,4328,7694,hyperdr::OutputEncoding::AvifPq,10,2020083848ULL},
  {"raster-t12:none:sdr-jpeg:8",4000,3000,4000,3000,hyperdr::OutputEncoding::SdrJpeg,8,304710376ULL},
  {"raster-t12:gallery:sdr-jpeg:8",4000,3000,4360,3750,hyperdr::OutputEncoding::SdrJpeg,8,357319472ULL},
  {"raster-t12:story:sdr-jpeg:8",4000,3000,4328,7694,hyperdr::OutputEncoding::SdrJpeg,8,618103792ULL},
  {"raster-j12:none:iso-gainmap-jpeg:8",4000,3000,4000,3000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,591823808ULL},
  {"raster-j12:gallery:iso-gainmap-jpeg:8",4000,3000,4360,3750,hyperdr::OutputEncoding::IsoGainMapJpeg,8,648594440ULL},
  {"raster-j12:story:iso-gainmap-jpeg:8",4000,3000,4328,7694,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1047430440ULL},
  {"raster-j12:none:adaptive:8",4000,3000,4000,3000,hyperdr::OutputEncoding::Adaptive,8,596739320ULL},
  {"raster-j12:gallery:adaptive:8",4000,3000,4360,3750,hyperdr::OutputEncoding::Adaptive,8,649118992ULL},
  {"raster-j12:story:adaptive:8",4000,3000,4328,7694,hyperdr::OutputEncoding::Adaptive,8,996361752ULL},
  {"raster-j12:none:adaptive:10",4000,3000,4000,3000,hyperdr::OutputEncoding::Adaptive,10,596821216ULL},
  {"raster-j12:gallery:adaptive:10",4000,3000,4360,3750,hyperdr::OutputEncoding::Adaptive,10,649971008ULL},
  {"raster-j12:story:adaptive:10",4000,3000,4328,7694,hyperdr::OutputEncoding::Adaptive,10,996394496ULL},
  {"raster-j12:none:pq:10",4000,3000,4000,3000,hyperdr::OutputEncoding::Pq,10,596952312ULL},
  {"raster-j12:gallery:pq:10",4000,3000,4360,3750,hyperdr::OutputEncoding::Pq,10,596935976ULL},
  {"raster-j12:story:pq:10",4000,3000,4328,7694,hyperdr::OutputEncoding::Pq,10,708625776ULL},
  {"raster-j12:none:avif-pq:10",4000,3000,4000,3000,hyperdr::OutputEncoding::AvifPq,10,958793024ULL},
  {"raster-j12:gallery:avif-pq:10",4000,3000,4360,3750,hyperdr::OutputEncoding::AvifPq,10,1050723672ULL},
  {"raster-j12:story:avif-pq:10",4000,3000,4328,7694,hyperdr::OutputEncoding::AvifPq,10,2045790392ULL},
  {"raster-j12:none:sdr-jpeg:8",4000,3000,4000,3000,hyperdr::OutputEncoding::SdrJpeg,8,337969896ULL},
  {"raster-j12:gallery:sdr-jpeg:8",4000,3000,4360,3750,hyperdr::OutputEncoding::SdrJpeg,8,390611760ULL},
  {"raster-j12:story:sdr-jpeg:8",4000,3000,4328,7694,hyperdr::OutputEncoding::SdrJpeg,8,653394952ULL},
  // R7-601: the same raster sources with a 17^3 colour LUT at strength 1. A LUT on
  // a raster photo adds no renditions (footprints match the runs without it), so
  // these use the plain raster coefficients, as rendition_retention() says.
  {"raster-lut-j24:none:iso-gainmap-jpeg:8",6000,4000,6000,4000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1155188056ULL},
  {"raster-lut-j24:story:iso-gainmap-jpeg:8",6000,4000,6440,11450,hyperdr::OutputEncoding::IsoGainMapJpeg,8,2259126408ULL},
  {"raster-lut-j24:none:adaptive:8",6000,4000,6000,4000,hyperdr::OutputEncoding::Adaptive,8,1161250448ULL},
  {"raster-lut-j24:story:adaptive:8",6000,4000,6440,11450,hyperdr::OutputEncoding::Adaptive,8,2109245840ULL},
  {"raster-lut-j24:none:pq:10",6000,4000,6000,4000,hyperdr::OutputEncoding::Pq,10,1160496808ULL},
  {"raster-lut-j24:story:pq:10",6000,4000,6440,11450,hyperdr::OutputEncoding::Pq,10,1469925296ULL},
  {"raster-lut-j24:none:avif-pq:10",6000,4000,6000,4000,hyperdr::OutputEncoding::AvifPq,10,1876052008ULL},
  {"raster-lut-j24:story:avif-pq:10",6000,4000,6440,11450,hyperdr::OutputEncoding::AvifPq,10,4415524872ULL},
  {"raster-lut-j24:none:sdr-jpeg:8",6000,4000,6000,4000,hyperdr::OutputEncoding::SdrJpeg,8,662930416ULL},
  {"raster-lut-j24:story:sdr-jpeg:8",6000,4000,6440,11450,hyperdr::OutputEncoding::SdrJpeg,8,1382041088ULL},
  {"raster-lut-j24:gallery:iso-gainmap-jpeg:8",6000,4000,6480,5000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1264485768ULL},
  {"raster-lut-j24:gallery:sdr-jpeg:8",6000,4000,6480,5000,hyperdr::OutputEncoding::SdrJpeg,8,764068944ULL},
  {"raster-lut-j12:story:iso-gainmap-jpeg:8",4000,3000,4328,7694,hyperdr::OutputEncoding::IsoGainMapJpeg,8,1048839464ULL},
  {"raster-lut-j12:story:adaptive:8",4000,3000,4328,7694,hyperdr::OutputEncoding::Adaptive,8,998475336ULL},
  {"raster-lut-j12:story:sdr-jpeg:8",4000,3000,4328,7694,hyperdr::OutputEncoding::SdrJpeg,8,653820912ULL},
  {"raster-lut-j12:none:avif-pq:10",4000,3000,4000,3000,hyperdr::OutputEncoding::AvifPq,10,960578880ULL},
  {"raster-lut-j8000:none:iso-gainmap-jpeg:8",8000,6000,8000,6000,hyperdr::OutputEncoding::IsoGainMapJpeg,8,2141456424ULL},
  {"raster-lut-j8000:story:iso-gainmap-jpeg:8",8000,6000,8660,15396,hyperdr::OutputEncoding::IsoGainMapJpeg,8,3967520080ULL},
  {"raster-lut-j8000:none:sdr-jpeg:8",8000,6000,8000,6000,hyperdr::OutputEncoding::SdrJpeg,8,1311802808ULL},
  {"raster-lut-j8000:story:sdr-jpeg:8",8000,6000,8660,15396,hyperdr::OutputEncoding::SdrJpeg,8,2568997192ULL},
  {"raster-lut-j8000:none:avif-pq:10",8000,6000,8000,6000,hyperdr::OutputEncoding::AvifPq,10,3547024768ULL},
  {"raster-lut-j8000:story:avif-pq:10",8000,6000,8660,15396,hyperdr::OutputEncoding::AvifPq,10,3203419040ULL},
  // R7-401: canvases past the single-frame AVIF limit are written as grids (E8).
  // 8000x6000 on story (8660x15396, 133 MP) and 9504x6336 on a story card with 0.15
  // margins (11404x20274, 231 MP); the HLG rows were measured the same way.
  {"raster-grid-t8000:story:avif-pq:10",8000,6000,8660,15396,hyperdr::OutputEncoding::AvifPq,10,3209104288ULL},
  {"raster-grid-t8000:story:avif-hlg:10",8000,6000,8660,15396,hyperdr::OutputEncoding::AvifHlg,10,3519696016ULL},
  {"raster-grid-j8000:story:avif-pq:10",8000,6000,8660,15396,hyperdr::OutputEncoding::AvifPq,10,3205483472ULL},
  {"raster-grid-t9504:story15:avif-pq:10",9504,6336,11404,20274,hyperdr::OutputEncoding::AvifPq,10,5245522288ULL},
  {"raster-grid-t9504:story15:avif-hlg:10",9504,6336,11404,20274,hyperdr::OutputEncoding::AvifHlg,10,5584229056ULL},
};
// R7-1301: RAW photos with a 17^3 colour LUT at strength 1 (sony-ilce-7s.ARW and the
// 61 MP user RAW; default look, quality 90, verification on, macOS 27 / M6, largest
// of two runs). A LUT adds no retained renditions to a RAW export either: the
// footprints match the runs without it, so these rows use the plain RAW coefficients.
inline constexpr ExportMeasurement raw_lut_measurements[] = {
  {"sony-lut:none:iso-gainmap-jpeg:8",2768,1848,2768,1848,hyperdr::OutputEncoding::IsoGainMapJpeg,8,425034904ULL},
  {"sony-lut:gallery:iso-gainmap-jpeg:8",2768,1848,2988,2308,hyperdr::OutputEncoding::IsoGainMapJpeg,8,444466304ULL},
  {"sony-lut:story:iso-gainmap-jpeg:8",2768,1848,2972,5284,hyperdr::OutputEncoding::IsoGainMapJpeg,8,656590168ULL},
  {"sony-lut:none:adaptive:8",2768,1848,2768,1848,hyperdr::OutputEncoding::Adaptive,8,423494904ULL},
  {"sony-lut:gallery:adaptive:8",2768,1848,2988,2308,hyperdr::OutputEncoding::Adaptive,8,445236520ULL},
  {"sony-lut:story:adaptive:8",2768,1848,2972,5284,hyperdr::OutputEncoding::Adaptive,8,624035256ULL},
  {"sony-lut:none:adaptive:10",2768,1848,2768,1848,hyperdr::OutputEncoding::Adaptive,10,423773384ULL},
  {"sony-lut:gallery:adaptive:10",2768,1848,2988,2308,hyperdr::OutputEncoding::Adaptive,10,442631464ULL},
  {"sony-lut:story:adaptive:10",2768,1848,2972,5284,hyperdr::OutputEncoding::Adaptive,10,624772512ULL},
  {"sony-lut:none:pq:10",2768,1848,2768,1848,hyperdr::OutputEncoding::Pq,10,423019768ULL},
  {"sony-lut:gallery:pq:10",2768,1848,2988,2308,hyperdr::OutputEncoding::Pq,10,422561016ULL},
  {"sony-lut:story:pq:10",2768,1848,2972,5284,hyperdr::OutputEncoding::Pq,10,486917464ULL},
  {"sony-lut:none:avif-pq:10",2768,1848,2768,1848,hyperdr::OutputEncoding::AvifPq,10,569689408ULL},
  {"sony-lut:gallery:avif-pq:10",2768,1848,2988,2308,hyperdr::OutputEncoding::AvifPq,10,622052720ULL},
  {"sony-lut:story:avif-pq:10",2768,1848,2972,5284,hyperdr::OutputEncoding::AvifPq,10,1062635200ULL},
  {"sony-lut:none:sdr-jpeg:8",2768,1848,2768,1848,hyperdr::OutputEncoding::SdrJpeg,8,281183192ULL},
  {"sony-lut:gallery:sdr-jpeg:8",2768,1848,2988,2308,hyperdr::OutputEncoding::SdrJpeg,8,303645776ULL},
  {"sony-lut:story:sdr-jpeg:8",2768,1848,2972,5284,hyperdr::OutputEncoding::SdrJpeg,8,442647752ULL},
  {"u61-lut:none:iso-gainmap-jpeg:8",9504,6336,9504,6336,hyperdr::OutputEncoding::IsoGainMapJpeg,8,3202944048ULL},
  {"u61-lut:story:iso-gainmap-jpeg:8",9504,6336,10200,18134,hyperdr::OutputEncoding::IsoGainMapJpeg,8,4165144800ULL},
  {"u61-lut:none:adaptive:8",9504,6336,9504,6336,hyperdr::OutputEncoding::Adaptive,8,3202993248ULL},
  {"u61-lut:story:adaptive:8",9504,6336,10200,18134,hyperdr::OutputEncoding::Adaptive,8,4923986816ULL},
  {"u61-lut:none:sdr-jpeg:8",9504,6336,9504,6336,hyperdr::OutputEncoding::SdrJpeg,8,2227833160ULL},
  {"u61-lut:story:sdr-jpeg:8",9504,6336,10200,18134,hyperdr::OutputEncoding::SdrJpeg,8,3463384736ULL},
};
