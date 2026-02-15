# xbrew

[![Downloads](https://img.shields.io/github/downloads/lebarsfa/xbrew/total?label=Downloads)](https://github.com/lebarsfa/xbrew/releases)

[![Latest Stable](https://img.shields.io/github/v/release/lebarsfa/xbrew?label=Latest%20Stable)](https://github.com/lebarsfa/xbrew/releases/latest)
[![Date](https://img.shields.io/github/release-date/lebarsfa/xbrew?label=Date)](https://github.com/lebarsfa/xbrew/releases/latest)

A small wrapper around `brew` to install or reinstall Homebrew formulas from specific commits or raw formula files, useful for installing older versions.

Prerequisites:
- `brew`, `git` commands.

Installation:
```bash
wget https://github.com/lebarsfa/xbrew/releases/latest/download/xbrew.sh
sudo mv xbrew.sh /usr/local/bin/xbrew
sudo chmod +x /usr/local/bin/xbrew
```

Usage help:
```bash
xbrew -h
```

Examples for a formula:
```bash
xbrew reinstall doxygen d2267b9f2ad247bc9c8273eb755b39566a474a70
# or
xbrew reinstall https://raw.githubusercontent.com/Homebrew/homebrew-core/d2267b9f2ad247bc9c8273eb755b39566a474a70/Formula/doxygen.rb
# or (but possibly slow and inaccurate)
xbrew reinstall doxygen 1.9.6
# Pin the formula to prevent it from being upgraded in the future
brew pin doxygen
```

Examples for a cask:
```bash
xbrew reinstall --cask cmake 06eed90d6268ed8c26e23b0458a43f8d3317f66c
# or
xbrew reinstall https://raw.githubusercontent.com/Homebrew/homebrew-cask/06eed90d6268ed8c26e23b0458a43f8d3317f66c/Casks/c/cmake.rb
# or (but possibly slow and inaccurate)
xbrew reinstall --cask cmake 3.31.6
# Pin the cask to prevent it from being upgraded in the future
brew pin cmake
```
