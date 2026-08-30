#!/usr/bin/env bash
# Debian build dependencies for compiling Erlang/OTP via asdf (kerl).
# Required: build-essential autoconf m4 libncurses-dev libssl-dev
# The rest are optional: wx/mesa/libpng for the :observer GUI, unixodbc for
# :odbc, libssh (unused by OTP, harmless), xsltproc/fop/libxml2-utils/default-jdk
# only if building HTML docs (KERL_BUILD_DOCS=yes).
set -euo pipefail

sudo apt install build-essential autoconf m4 libncurses-dev libssl-dev \
  libwxgtk3.2-dev libwxgtk-webview3.2-dev libgl1-mesa-dev libglu1-mesa-dev \
  libpng-dev unixodbc-dev libssh-dev xsltproc fop libxml2-utils
