#pragma once

// Whether this build has the image codecs linked in.
//
// The dependency-free core build carries the renderer and all of its tests but
// no LibRaw, libheif, libavif or libultrahdr. That used to be expressed as
// `#if HYPERDR_WITH_CODECS` blocks inside conversion and CLI function bodies,
// which meant the two configurations were not the same program: whole branches
// existed only in one of them. Instead, the codec module always defines every
// entry point, and the codec-less build defines them as throwing stubs. The
// call graph is then identical and only the leaves differ.

namespace hyperdr {

#if HYPERDR_WITH_CODECS
inline constexpr bool kCodecsAvailable = true;
#else
inline constexpr bool kCodecsAvailable = false;
#endif

// Throws a uniform, actionable message. `capability` names what was attempted,
// for example "RAW decoding".
[[noreturn]] void fail_without_codecs(const char* capability);

}  // namespace hyperdr
