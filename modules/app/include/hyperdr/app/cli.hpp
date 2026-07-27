#pragma once

namespace hyperdr {

// Parses arguments and runs one command. Returns a process exit code and lets
// exceptions escape to main, which reports them uniformly.
[[nodiscard]] int run_cli(int argc, char** argv);

}  // namespace hyperdr
