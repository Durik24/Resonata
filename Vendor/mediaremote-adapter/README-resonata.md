# mediaremote-adapter (vendored)

Upstream: https://github.com/ungive/mediaremote-adapter — BSD 3-Clause, see LICENSE.
Commit: see UPSTREAM_COMMIT. Only `src/`, `include/` and `bin/` are kept.

build.sh compiles the framework with clang (no CMake needed) into
Resonata.app/Contents/Frameworks/MediaRemoteAdapter.framework and copies the
Perl script into Contents/Resources. The framework is never linked; it is
loaded by /usr/bin/perl, which is Apple-signed and therefore still allowed to
talk to MediaRemote on macOS 15.4 and later.
