// What does Apple's decoder actually see in a file?
//
// CoreImageT2.swift aborts when ImageIO does not expose an ISO gain map, which
// leaves two very different explanations open: the writer produced a container
// Apple will not accept, or this harness asks for the gain map the wrong way.
// Running the same queries against a file written by Apple's own pipeline
// separates them. This program only reports; it decides nothing.

import CoreImage
import Foundation
import ImageIO

let auxiliaryTypes: [(String, CFString)] = [
    ("ISOGainMap", kCGImageAuxiliaryDataTypeISOGainMap),
    ("HDRGainMap", kCGImageAuxiliaryDataTypeHDRGainMap),
]

func describeAuxiliary(_ source: CGImageSource, _ index: Int) {
    for (name, kind) in auxiliaryTypes {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kind)
            as? [String: Any] else {
            print("  [\(index)] \(name): absent")
            continue
        }
        print("  [\(index)] \(name): PRESENT keys=\(info.keys.sorted())")
        if let data = info[kCGImageAuxiliaryDataInfoData as String] as? Data {
            print("      data: \(data.count) bytes")
        }
        if let description = info[kCGImageAuxiliaryDataInfoDataDescription as String] {
            print("      description: \(description)")
        }
        if info[kCGImageAuxiliaryDataInfoMetadata as String] != nil {
            print("      metadata: present")
        }
    }
}

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    // The full path, not the last component: several probes deliberately share a
    // file name and differ only in which directory they came from.
    print("=== \(path)")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("  ImageIO rejected the file outright")
        continue
    }
    let count = CGImageSourceGetCount(source)
    print("  uti=\(String(describing: CGImageSourceGetType(source)))  images=\(count)")
    if let container = CGImageSourceCopyProperties(source, nil) as? [String: Any] {
        print("  container keys: \(container.keys.sorted())")
    }
    for index in 0..<count {
        describeAuxiliary(source, index)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [String: Any] {
            print("  [\(index)] property keys: \(properties.keys.sorted())")
        }
    }
    let base = CIImage(contentsOf: url)
    let expanded = CIImage(contentsOf: url, options: [.expandToHDR: true])
    let gainMap = CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true])
    print("  CIImage base extent:        \(String(describing: base?.extent))")
    print("  CIImage expandToHDR extent: \(String(describing: expanded?.extent))")
    print("  CIImage gain-map extent:    \(String(describing: gainMap?.extent))")
    if let properties = gainMap?.properties, !properties.isEmpty {
        print("  gain-map recipe keys: \(properties.keys.sorted())")
    }
}
