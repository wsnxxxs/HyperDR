"""E5 frame gates, sharing the ImageIO ring tool for HEIC and ISO JPEG."""
import json
import math
import os
from pathlib import Path
import subprocess


def invoke(*args, env=None):
    return subprocess.check_output(list(map(str, args)), text=True, env=env)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_gain_frame(path, report, probe, reader, work, shadow):
    photo = report["files"][0]["frame"]["photo"]
    rect = ",".join(str(photo[k]) for k in ("x", "y", "width", "height"))
    # One replaceable product reader. ImageIO Data takes precedence for JPEG;
    # absent Data uses this raw plane with independent ImageIO metadata/L2.
    plane_info = json.loads(invoke(reader, "--gain-plane", path, work / "gain.f32"))
    extra = ["--gain-plane", work / "gain.f32", "--gain-bits", plane_info["bits"],
             "--gain-backend", "bundled-heif-reader" if path.suffix == ".heic" else "iso-gainmap-jpeg-libjpeg"]
    if path.suffix == ".heic":
        extra += ["--chroma-support", plane_info["chroma_support"]]
    control = work / ("zero-control"+path.suffix)
    invoke(reader,"--zero-gain-control",path,control)
    result = json.loads(invoke(probe, path, "--photo", rect, "--control", control, *extra))
    original = result["gain_maps"]["iso"]
    replacement = result["control_gain_maps"]["iso"]
    require(original["metadata"] == replacement["metadata"] and
            original["description"] == replacement["description"], "control changed ISO metadata or dimensions")
    ring = result["frame_rings"]
    if plane_info:
        iso = result["gain_maps"]["iso"]
        require(iso is not None, "ImageIO ISO auxiliary missing")
        for c, fields in enumerate(plane_info["metadata"]):
            for field, value in zip(("GainMapMin", "GainMapMax", "Gamma"), fields):
                actual = float(iso["metadata"][f"HDRToneMap:ChannelMetadata[{c}].{field}"])
                require(abs(actual-value) <= 1e-6, f"ImageIO/native metadata mismatch: {field}")
    for name, limit in (("l1_near8", .02), ("l1_far8", .01)):
        layer = ring[name]
        require(layer["valid"] and math.isfinite(layer["max_abs_stops"]), f"empty/nonfinite {name}")
        require(layer["max_abs_stops"] <= limit, f"L1 {name}: {layer}")
    require(ring["l1_far8"]["zero_fraction"] >= .999, f"L1 far zero fraction: {ring}")
    depth = result["image"]["bit_depth"]
    ring["l2_reference"] = "zero-gain-hdr" if shadow else "sdr"
    for channel in ring["rings"][-1]["control_l2" if shadow else "l2"]:
        require(channel["bright_pixels"] + channel["dark_pixels"] > 0, "empty L2 interior")
        if channel["bright_pixels"]:
            require(channel["max_abs_log2"] <= (.05 if depth == 8 else .03), f"L2 interior: {channel}")
        if channel["dark_pixels"]:
            require(channel["dark_max_abs_diff"] <= 1 / (255 if depth == 8 else 1023), f"L2 dark: {channel}")
    return result


def check_frames(cli, reader, probe, directory, export, source):
    root = Path(__file__).resolve().parents[2]
    hdr_jpeg = root / "tests/fixtures/gain-map-jpeg/iso-mono.jpg"
    hdr_heic, _ = export(cli, hdr_jpeg, directory / "frame-hdr-source", "adaptive", 10)
    sdr_jpeg, _ = export(cli, source, directory / "frame-sdr-source", "sdr-jpeg")
    signed = directory / "signed-source.heic"
    subprocess.run([str(reader), "--signed-fixture", str(signed)], check=True)
    formats = [("iso-gainmap-jpeg", 8), ("adaptive", 8), ("adaptive", 10),
               ("pq", 10), ("hlg", 10), ("avif-pq", 10), ("avif-hlg", 10)]
    colors = {"neutral":"#F4F2EC", "white":"#FFFFFF", "red":"#FF0000", "green":"#00FF00",
              "blue":"#0000FF", "black":"#000000", "gallery":"#F5F3EE", "saturated":"#ED30D0"}
    cases = [(color, "hdr-jpeg", hdr_jpeg, []) for color in colors]
    cases += [("gallery", "sdr", sdr_jpeg, []), ("gallery", "hdr-heic", hdr_heic, []),
              ("gallery", "model", sdr_jpeg, ["--ai-model", "research-cnn-v1"]),
              ("white", "signed", signed, [])]
    cases += [("neutral", "no-shadow", hdr_jpeg, []), ("gallery", "v3", hdr_jpeg, []), ("saturated", "v3", hdr_jpeg, []),
              ("gallery", "v3-model", sdr_jpeg, ["--ai-model", "research-cnn-v1"])]
    # Lead-approved E5 gate quality; product default remains 90.
    quality = ["--quality", "95"]
    baseline = json.loads(Path(__file__).with_name("frame_photo_baseline.json").read_text())
    baseline_seen = set()
    plain_cache = {}
    summaries = []
    for color, kind, input_path, extra in cases:
        spec = directory / f"frame-{color}-{kind}.json"
        body = {"schema":"hyperdr.frame/v1", "background":colors[color],
                "margins":.25,"caption":.2,"shadow":{"opacity":.1,"blur":.02,"offset":.006}}
        if kind == "no-shadow": body.pop("shadow")
        if color == "white": body = {"margins":.5,"caption":1}
        if color == "red": body = {"margins":.1,"background":"#FF0000","shadow":{"opacity":1,"blur":.1,"offset":.1}}
        if kind.startswith("v3"): body.update(margins=.06,caption=.13,shadow={"opacity":.1,"blur":.012,"offset":.004})
        spec.write_text(json.dumps(body))
        selected = [("adaptive",8)] if kind=="v3-model" else [("adaptive",8),("adaptive",10)] if kind=="v3" else formats
        for encoding, depth in selected:
            name = f"frame-{color}-{kind}-{encoding}{depth}"
            work = directory / name
            path, report = export(cli, input_path, work, encoding, depth, ["--frame", str(spec), *quality, *extra])
            frame = report["files"][0]["frame"]; photo = frame["photo"]
            gain = encoding in ("adaptive", "iso-gainmap-jpeg")
            mode = "pq" if "pq" in encoding else "hlg" if "hlg" in encoding else "linear"
            env = dict(os.environ, **{("HYPERDR_PROBE_DUMP_HDR" if gain else "HYPERDR_PROBE_DUMP_HDR_SIGNAL"):str(work/"hdr.f32")})
            if gain:
                result = check_gain_frame(path, report, probe, reader, work, body.get("shadow",{}).get("opacity",0)>0)
                ring = result["frame_rings"]; k = ring["k"]
                if kind=="signed":
                    require(float(result["gain_maps"]["iso"]["metadata"]["HDRToneMap:ChannelMetadata[0].GainMapMin"]) < 0,
                            "signed encoded fixture did not exercise negative gain")
                summary = {"name":name,"frame_rings":ring}
            else:
                k = 3
                summary = {"name":name}
            invoke(probe, path, env=env)
            if not gain:
                metrics = json.loads(invoke(reader,"--compare-frame",work/"hdr.f32",spec,photo["width"],photo["height"],mode))
                require(metrics["delta_e_itp_p99"] <= 3, f"single HDR mat colour: {name}: {metrics}")
                if metrics["white_pixels"]:
                    require( .98 <= metrics["white_mean"] <= 1.02, f"SDR white !=203 nit: {name}: {metrics}")
                summary["mat"] = metrics
            key = (kind,encoding,depth)
            if key not in plain_cache:
                plain, _ = export(cli,input_path,directory/f"plain-{kind}-{encoding}{depth}",encoding,depth,[*quality,*extra])
                dump = plain.parent/"hdr.f32"
                invoke(probe,plain,env=dict(os.environ,**{("HYPERDR_PROBE_DUMP_HDR" if gain else "HYPERDR_PROBE_DUMP_HDR_SIGNAL"):str(dump)}))
                plain_cache[key] = dump
            metrics = json.loads(invoke(reader,"--compare-photo",work/"hdr.f32",plain_cache[key],photo["x"],photo["y"],k,mode))
            if name in baseline["cases"]:
                # Seven pre-E5 codec errors: Lead approved a non-regression
                # gate, preserving the original limits for every other case.
                pre = baseline["cases"][name]
                require(metrics["mean_abs_log2"] - pre["mean_abs_log2"] <= baseline["max_mean_increase_stops"] and
                        metrics["peak_relative_error"] - pre["peak_relative_error"] <= baseline["max_peak_increase_fraction"],
                        f"pre-existing photo error regressed: {name}: pre={pre}, post={metrics}")
                baseline_seen.add(name)
                summary["photo_gate"] = {"policy":"pre-existing; P3a-2", "pre":pre,
                                         "source_commit":baseline["source_commit"]}
            else:
                require(metrics["mean_abs_log2"] <= .02 and metrics["peak_relative_error"] <= .01,
                        f"photo preservation: {name}: {metrics}")
            summary["photo"] = metrics
            summaries.append(summary)
            print("E5 "+json.dumps(summary,sort_keys=True),flush=True)
    require(baseline_seen == set(baseline["cases"]), "frozen photo cases were not all exercised")
    destination = os.environ.get("HYPERDR_FRAME_REPORT")
    if destination:
        Path(destination).write_text(json.dumps(summaries,indent=2,sort_keys=True))


def check_q90_nonregression(cli, baseline, reader, probe, directory, export):
    """Same-build audit against the retained pre-E5 binary, not a new limit."""
    source = Path(__file__).resolve().parents[2] / "tests/fixtures/gain-map-jpeg/iso-mono.jpg"
    for color in ("neutral", "white"):
        spec = directory / f"q90-{color}.json"
        spec.write_text(json.dumps({"margins":.25,"caption":.2,
            "background":"#F4F2EC" if color=="neutral" else "#FFFFFF",
            "shadow":{"opacity":.1,"blur":.02,"offset":.006}}))
        for encoding in ("pq", "avif-pq"):
            results = []
            planes = []
            for tag, executable in (("before", baseline), ("after", cli)):
                dumps = []
                for framed in (False, True):
                    work = directory / f"q90-{color}-{encoding}-{tag}-{framed}"
                    path, report = export(executable,source,work,encoding,10,
                        ["--quality","90"]+(["--frame",str(spec)] if framed else []))
                    dump = work / "hdr.f32"
                    invoke(probe,path,env=dict(os.environ,HYPERDR_PROBE_DUMP_HDR_SIGNAL=str(dump)))
                    dumps.append(dump)
                    if framed:
                        photo = report["files"][0]["frame"]["photo"]
                metrics = json.loads(invoke(reader,"--compare-photo",dumps[1],dumps[0],photo["x"],photo["y"],3,"pq"))
                results.append(metrics)
                planes.append([dump.read_bytes() for dump in dumps])
            require(results[0] == results[1] and planes[0] == planes[1],
                    f"q90 regressed: {color}/{encoding}: {results}")
            print(f"E5 q90 no regression {color}/{encoding}: {json.dumps(results[1],sort_keys=True)}",flush=True)
