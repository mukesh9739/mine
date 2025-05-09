#!/bin/bash

# ------------------------------------------------------------------------------
# QLever Environment Setup Script with Resource Usage Tracking
# ------------------------------------------------------------------------------
# 📦 Automates:
#   1. Dependency installation (with disk estimate)
#   2. CMake installation (ARM-aware or local)
#   3. QLever cloning
#   4. Full or minimal build with RAM/disk tracking
#
# 📊 Reports:
#   - Peak RAM during make
#   - Disk used after each step
#   - Total execution time
# ------------------------------------------------------------------------------

unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/mnt/c/msys64' | paste -sd:)

set -e
trap 'echo "❌ Script failed on line $LINENO" >&2' ERR

start_time=$(date +%s)

# -------- Resource Tracking Setup --------
report_disk_usage() {
  local label="$1"
  local usage_gb
  usage_gb=$(du -s --block-size=1G "$QLEVER_DIR" 2>/dev/null | awk '{print $1}')
  echo "💾 [$label] Disk used by QLever folder: ${usage_gb:-0} GB"
}

disk_before_deps=$(df "$HOME" --output=avail | tail -1)

# -------- Sanity Checks --------
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Do not run this script as root."
  exit 1
fi

for cmd in wget git sudo du df awk grep make; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ '$cmd' not installed. Run: sudo apt install $cmd"
    exit 1
  fi
done

if ! ping -c 1 github.com &>/dev/null; then
  echo "❌ No internet connection."
  exit 1
fi

available_space_mb=$(df "$HOME" | awk 'NR==2 {print int($4/1024)}')
if (( available_space_mb < 5000 )); then
  echo "❌ At least 5 GB free disk space required."
  exit 1
fi

# -------- Install Dependencies & CMake --------
install_dependencies_and_cmake() {
  echo "📦 Installing dependencies..."
  sudo apt update
  sudo apt install -y build-essential g++ git libssl-dev zlib1g-dev \
    libcurl4-openssl-dev libreadline-dev libboost-all-dev \
    libbz2-dev libjemalloc-dev pkg-config libzstd-dev time

  disk_after_deps=$(df "$HOME" --output=avail | tail -1)
  disk_used_deps_mb=$(( (disk_before_deps - disk_after_deps) / 1024 ))
  echo "💽 Disk used by dependencies: ~$((disk_used_deps_mb / 1024)) GB"

  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    echo "🧠 ARM detected: installing CMake via Kitware repo..."
    sudo apt install -y software-properties-common
    sudo apt-add-repository -y 'deb https://apt.kitware.com/ubuntu/ focal main'
    wget -q https://apt.kitware.com/keys/kitware-archive-latest.asc
    sudo apt-key add kitware-archive-latest.asc
    sudo apt update
    sudo apt install -y cmake
  else
    echo "⬇️ Installing CMake 4.0.1 (x86_64)..."
    rm -rf "$HOME/cmake-4.0.1"
    wget https://cmake.org/files/v4.0/cmake-4.0.1-linux-x86_64.sh
    chmod +x cmake-4.0.1-linux-x86_64.sh
    mkdir -p "$HOME/cmake-4.0.1"
    ./cmake-4.0.1-linux-x86_64.sh --prefix="$HOME/cmake-4.0.1" --skip-license
    rm cmake-4.0.1-linux-x86_64.sh
    export PATH="$HOME/cmake-4.0.1/bin:$PATH"
    grep -q 'cmake-4.0.1' ~/.bashrc || echo 'export PATH=$HOME/cmake-4.0.1/bin:$PATH' >> ~/.bashrc
  fi
  echo "✅ CMake version: $(cmake --version | head -n1)"
}

# -------- Clone QLever Repo --------
clone_qlever() {
  [ -d "qlever" ] && echo "⚠️ Removing existing qlever/..." && rm -rf qlever
  echo "📁 Cloning QLever..."
  git clone --recursive https://github.com/ad-freiburg/qlever.git
  QLEVER_DIR="$PWD/qlever"
  report_disk_usage "After Clone"
}

# -------- Configure + Build with RAM Tracking --------
configure_and_build() {
  cd "$QLEVER_DIR"
  rm -rf build
  mkdir build && cd build

  echo "⚙️ Configuring build ($1)..."
  if [[ "$1" == "minimal" ]]; then
    cmake .. -DCMAKE_BUILD_TYPE=Developer -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_TESTING=OFF
  else
    cmake .. -DCMAKE_BUILD_TYPE=Developer -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  fi

  echo "🔨 Building with memory profiling..."
  /usr/bin/time -v make -j$(nproc) 2> peak_mem.txt

  peak_mem_kb=$(grep "Maximum resident set size" peak_mem.txt | awk '{print $6}')
  peak_mem_mb=$((peak_mem_kb / 1024))
  echo "🧠 Peak RAM during build: ${peak_mem_mb} MB"

  cd ../..
  report_disk_usage "After Build"
}

# -------- User Prompt --------
while true; do
  echo "❓ Choose setup mode:"
  echo "  [1] Full setup (deps, cmake, clone, build)"
  echo "  [2] Rebuild only"
  echo "  [3] Quick make"
  read -p "Enter 1, 2 or 3: " mode_choice

  build="(not applicable)"
  build_type_flag=""

  if [[ "$mode_choice" == "1" || "$mode_choice" == "2" ]]; then
    echo "⚖️ Build type:"
    echo "  [1] Minimal (no tests)"
    echo "  [2] Full (tests + benches)"
    read -p "Enter 1 or 2: " build_type_choice
    if [[ "$build_type_choice" == "1" ]]; then
      build="Minimal"; build_type_flag="minimal"
    elif [[ "$build_type_choice" == "2" ]]; then
      build="Full"; build_type_flag="full"
    else
      echo "❌ Invalid build type."; continue
    fi
  fi

  if [[ "$mode_choice" == "1" ]]; then mode="Full setup"
  elif [[ "$mode_choice" == "2" ]]; then mode="Rebuild only"
  elif [[ "$mode_choice" == "3" ]]; then mode="Quick make"
  else echo "❌ Invalid mode."; continue; fi

  echo ""
  echo "📝 You selected: ➤ Mode: $mode | ➤ Build type: $build"
  read -p "✅ Proceed? [y/n]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] && break
done

# -------- Setup Based on Mode --------
if [[ "$mode_choice" == "1" ]]; then
  install_dependencies_and_cmake
  clone_qlever
  configure_and_build "$build_type_flag"
elif [[ "$mode_choice" == "2" ]]; then
  if [ ! -d qlever ]; then read -p "Path to QLever: " QLEVER_DIR; else QLEVER_DIR="$PWD/qlever"; fi
  configure_and_build "$build_type_flag"
elif [[ "$mode_choice" == "3" ]]; then
  [ ! -d qlever ] && read -p "Path to QLever: " QLEVER_DIR || QLEVER_DIR="$PWD/qlever"
  cd "$QLEVER_DIR/build" || { echo "❌ Missing build folder."; exit 1; }
  make -j$(nproc)
  report_disk_usage "Quick Make"
fi

# -------- Summary --------
end_time=$(date +%s)
duration=$((end_time - start_time))
duration_min=$((duration / 60))
duration_sec=$((duration % 60))

echo ""
echo "📝 Final Summary:"
echo "  ➤ Mode:       $mode"
echo "  ➤ Build type: $build"
echo "  🧠 Peak RAM:  ${peak_mem_mb:-unknown} MB"
echo "  💽 Disk used: $(du -s --block-size=1G "$QLEVER_DIR" | awk '{print $1}') GB"
echo "  ⏱️ Time:       ${duration_min}m ${duration_sec}s"
echo "🎉 QLever environment is ready!"
