#include "hyperdr/app/export_memory.hpp"
#include "hyperdr/codec/avif_grid.hpp"
#include <limits>
#include <thread>

namespace hyperdr {
namespace {
constexpr std::uint64_t MiB = 1024 * 1024;
std::uint64_t sum(std::initializer_list<std::uint64_t> parts) {
  std::uint64_t total = 0;
  for (auto part : parts) {
    if (part > std::numeric_limits<std::uint64_t>::max() - total)
      return std::numeric_limits<std::uint64_t>::max();
    total += part;
  }
  return total;
}
std::uint64_t plane(std::uint64_t pixels, std::uint64_t bytes) {
  return pixels > std::numeric_limits<std::uint64_t>::max() / bytes
      ? std::numeric_limits<std::uint64_t>::max() : pixels * bytes;
}
}
ExportMemoryEstimate estimate_export_memory(std::uint32_t pw, std::uint32_t ph,
    std::uint32_t cw, std::uint32_t ch, OutputEncoding encoding, int depth,
    bool raw, std::uint32_t sw, std::uint32_t sh, unsigned workers, bool retained_renditions, std::uint64_t retained_resource_bytes,
    std::uint64_t external_gain_pixels) {
  const auto photo = std::uint64_t(pw) * ph, canvas = std::uint64_t(cw) * ch;
  const auto sensor = sw && sh ? std::uint64_t(sw) * sh : photo;
  const bool sdr = is_sdr_encoding(encoding), gain = is_gain_map_encoding(encoding);
  const bool framed = cw != pw || ch != ph;
  // Includes the RAW renderer's 150 MiB floor plus process/framework caches
  // observed across repeated exports (malloc's cache varies with host pressure).
  const auto overhead = raw ? 192 * MiB : 32 * MiB;
  // CIRAW keeps a GPU working set as well as the decoded float plane; its
  // block renderer adds one 512-row RGBA block. Raster decode uses 15 B/px.
  const auto resident = raw ? plane(sensor,16) : 0;
  ExportMemoryEstimate e;
  e.decode = raw ? sum({overhead,resident,plane(photo,12),plane(std::uint64_t(pw)*512,16)})
                 : sum({overhead,plane(photo,15)});
  // Imported dual renditions, LUT working renditions and model/external grids retain additional
  // bases, HDR samples and RGB gain planes while grading reconstructs a pair.
  // Measured with external grids: an SDR-only export of one holds about 48 B/px
  // above the grid, far below the 80 B/px that covers dual HDR renditions.
  const auto render_planes=retained_renditions ? (external_gain_pixels && sdr ? 56 : 80) : (sdr ? 24 : 44);
  e.render = sum({overhead,resident,plane(photo,render_planes)});
  // The sidecar grid has its own size, independent of the photo and the canvas.
  // Parsing and applying it hold, besides the snapshot counted in the retained
  // resources, the parsed grid, the canonical/code grid, the decoded stops and
  // the statistics copy: four float grids beside the photo's decoded and
  // base-rendered planes. Afterwards the grid, and the freed stops and copy
  // (malloc keeps large blocks), stay resident into compositing.
  const auto grid = plane(external_gain_pixels,sizeof(float));
  if (external_gain_pixels)
    e.render = std::max(sum({e.render,plane(grid,3)}),
                        sum({overhead,resident,plane(photo,36),plane(grid,4)}));
  e.composite = sum({overhead,resident,plane(photo,sdr ? 12 : 24),plane(canvas,13)});
  // ISO expansion overlaps SDR + RGB gain canvases, byte ROI codes, and a
  // byte mask. Apple packaging overlaps SDR + mono stops/quantization + mask.
  e.packaging = gain ? (encoding == OutputEncoding::IsoGainMapJpeg
      ? sum({overhead,resident,plane(photo,3),plane(canvas,25)})
      : sum({overhead,resident,plane(photo,12),plane(canvas,21)})) : 0;
  const auto auto_workers=std::clamp(std::thread::hardware_concurrency()/4U,1U,4U);
  const auto tile_count=((std::uint64_t(cw)+511)/512)*((std::uint64_t(ch)+511)/512);
  const auto count=std::min<std::uint64_t>(workers ? workers : auto_workers,tile_count);
  // Bounded converted YUV batch (one tile/worker), VT IOSurfaces/in-flight
  // frames, and accumulated compressed samples/container copies.
  const bool main10=depth==10 || encoding==OutputEncoding::Pq || encoding==OutputEncoding::Hlg;
  const auto vt=sum({plane(count*512*512,main10 ? 3 : 2),32*MiB,plane(canvas,4)});
  switch (encoding) {
    case OutputEncoding::IsoGainMapJpeg:
      e.encode=sum({overhead,resident,plane(canvas,27)});
      e.verify=sum({overhead,resident,plane(canvas,16)}); break;
    case OutputEncoding::Adaptive:
      e.encode=sum({overhead,resident,plane(canvas,16),vt});
      e.verify=sum({overhead,resident,plane(canvas,depth==10 ? 22 : 16)}); break;
    case OutputEncoding::Pq: case OutputEncoding::Hlg:
      e.encode=sum({overhead,resident,plane(canvas,12),vt});
      e.verify=sum({overhead,resident,plane(canvas,22)}); break;
    case OutputEncoding::AvifPq: case OutputEncoding::AvifHlg:
      if (const auto cells=avif_grid_layout(cw,ch); cells.is_grid()) {
        // A grid (E8) converts and codes one cell at a time. The canvas keeps its
        // HDR float image (12 B/px) and the finished YUV444 cells (6 B/px);
        // only the cell's RGB16 and libaom planes (about 42 B/px, as for one
        // item) are transient. Measured on a 185 MP story canvas: 4.3 GB
        // against 12.2 GB for one item. The verifying decode assembles the
        // cells into one set of planes beside the canvas.
        const auto cell=std::uint64_t(cells.cell_width)*cells.cell_height;
        e.encode=sum({overhead,resident,plane(canvas,18),plane(cell,42)});
        e.verify=sum({overhead,resident,plane(canvas,18),plane(cell,20)});
      } else {
        // HDR float + RGB16 + YUV444 + libaom reference/work planes.
        e.encode=sum({overhead,resident,plane(canvas,66)});
        e.verify=sum({overhead,resident,plane(canvas,20)});
      }
      break;
    case OutputEncoding::SdrJpeg: case OutputEncoding::SdrTiff:
      e.encode=sum({overhead,resident,plane(canvas,20)});
      e.verify=sum({overhead,resident,plane(canvas,16)}); break;
  }
  // With an external grid, its float base and the planes the render left behind
  // (measured about 24 B/px together) stay alive beside the framed pair until
  // the gain is released, and so does the grid.
  if (!framed) e.composite=0;
  else if (external_gain_pixels) e.composite=sum({e.composite,plane(photo,24),plane(grid,3)});
  // Framed and ISO exports repackage the pair and drop the grid before packaging;
  // an unframed Apple pair keeps it through packaging and encoding.
  const bool grid_kept=encoding==OutputEncoding::Adaptive && !framed;
  e.packaging=sum({e.packaging,plane(grid,2+(grid_kept?1:0))});
  e.encode=sum({e.encode,plane(grid,2+(grid_kept?1:0))});
  e.verify=sum({e.verify,plane(grid,2)});
  for(auto* stage : {&e.decode,&e.render,&e.composite,&e.packaging,&e.encode,&e.verify})
    *stage=sum({*stage,retained_resource_bytes});
  return e;
}
std::uint64_t export_resource_bytes(const ConvertOptions& options) {
  std::uint64_t retained=0;
  if(const auto& frame=options.frame_snapshot) retained=sum({retained,
      frame->specification_bytes.capacity(),frame->overlay_bytes.capacity(),
      plane(frame->overlay.rgba.capacity(),sizeof(float))});
  if(const auto& lut=options.color_lut.snapshot) retained=sum({retained,lut->bytes.capacity(),
      plane(lut->lut.values.capacity(),sizeof(std::array<float,3>))});
  if(const auto& external=options.external_gain_snapshot) retained=sum({retained,
      external->gain_bytes.capacity(),external->report_bytes.capacity()});
  return retained;
}
std::uint64_t export_memory_budget(std::uint64_t configured, std::uint64_t physical) noexcept {
  constexpr auto reserve=512*MiB;
  if (!physical) return configured;
  const auto host=physical>reserve ? physical-reserve : 0;
  return configured ? std::min(configured,host) : host;
}
}  // namespace hyperdr
