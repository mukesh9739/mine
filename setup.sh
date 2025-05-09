#!/bin/bash

# ------------------------------------------------------------------------------
# QLever Environment Setup Script
# ------------------------------------------------------------------------------
# This script helps you set up and build the QLever project in a Linux or WSL environment.
#
# ✔ Three modes of operation:
#   [1] Full setup: installs dependencies, installs CMake, clones and builds QLever.
#   [2] Rebuild only: reconfigures and rebuilds QLever from source.
#   [3] Quick make: just runs `make` assuming CMake config is already done.
#
# 📊 It also tracks:
#   - Build memory usage
#   - Disk space usage
#   - Total execution time
#
# ❗ Prevents build issues caused by MSYS2/MinGW path leaks in WSL or mixed environments.
# ------------------------------------------------------------------------------

# ===== SAFETY: CLEANUP MISLEADING WINDOWS ENV VARS (WSL/MSYS2 PROTECTION) =====
unset CPATH
unset C_INCLUDE_PATH
unset CPLUS_INCLUDE_PATH
unset LIBRARY_PATH
unset LD_LIBRARY_PATH
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/mnt/c/msys64' | paste -sd:)

# Exit immediately on error
set -e
trap 'echo "❌ Script failed on line $LINENO. Check the output above for the error." >&2' ERR

# ===== MEASURE: START TIMING & RESOURCE SNAPSHOT =====
start_time=$(date +%s)
initial_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
initial_disk_kb=$(df --output=avail "$HOME" | tail -1)

# ===== SAFETY CHECKS =====

# Don't run this script as root
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Please do NOT run this script as root. Run it as a regular user."
  exit 1
fi

# Ensure critical commands are available
for cmd in wget git sudo; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Required command '$cmd' is not installed. Remedy: run 'sudo apt install $cmd'."
    exit 1
  fi
done

# Internet access check
if ! ping -c 1 github.com &>/dev/null; then
  echo "❌ No internet connection. Remedy: check your network settings."
  exit 1
fi

# Check available disk space (needs ~5GB)
required_space_mb=5000
available_space_mb=$(df "$HOME" | awk 'NR==2 {print int($4/1024)}')
if (( available_space_mb < required_space_mb )); then
  echo "❌ Not enough disk space. At least ${required_space_mb}MB required in your home directory."
  exit 1
fi

# ===== INSTALL DEPENDENCIES AND CMAKE =====
install_dependencies_and_cmake() {
  echo "📦 Removing system CMake if found..."
  if dpkg -l | grep -q "^ii  cmake "; then
    sudo apt remove --purge -y cmake
  fi

  echo "🧹 Removing old QLever dependencies (clean install)..."
  packages=(
    build-essential g++ git
    libssl-dev zlib1g-dev libcurl4-openssl-dev libreadline-dev
    libboost-all-dev libbz2-dev libjemalloc-dev pkg-config
    libzstd-dev
  )

  for pkg in "${packages[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg "; then
      sudo apt remove --purge -y "$pkg"
    fi
  done

  sudo apt autoremove -y
  sudo apt update
  sudo apt install -y "${packages[@]}"

  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    echo "🧠 Detected ARM architecture: installing CMake via Kitware APT repo..."
    sudo apt install -y software-properties-common
    sudo apt-add-repository 'deb https://apt.kitware.com/ubuntu/ focal main'
    wget https://apt.kitware.com/keys/kitware-archive-latest.asc
    sudo apt-key add kitware-archive-latest.asc
    sudo apt update
    sudo apt install -y cmake
    echo "✅ Installed CMake via APT on ARM."
  else
    echo "⬇️ Downloading CMake 4.0.1 (x86_64)..."
    [ -d \"$HOME/cmake-4.0.1\" ] && rm -rf \"$HOME/cmake-4.0.1\"
    wget https://cmake.org/files/v4.0/cmake-4.0.1-linux-x86_64.sh
    chmod +x cmake-4.0.1-linux-x86_64.sh
    mkdir -p \"$HOME/cmake-4.0.1\"
    ./cmake-4.0.1-linux-x86_64.sh --prefix=$HOME/cmake-4.0.1 --skip-license
    rm -f cmake-4.0.1-linux-x86_64.sh

    export PATH=\"$HOME/cmake-4.0.1/bin:$PATH\"
    if ! grep -q 'cmake-4.0.1/bin' ~/.bashrc; then
      echo 'export PATH=$HOME/cmake-4.0.1/bin:$PATH' >> ~/.bashrc
    fi
  fi

  echo "✅ CMake installed:"
  cmake --version
}

# ===== CLONE QLEVER REPO =====
clone_qlever() {
  if [ -d \"qlever\" ]; then
    echo \"⚠️ Found existing 'qlever/' directory. Deleting...\"
    rm -rf qlever
  fi

  echo \"📁 Cloning QLever...\"
  git clone --recursive https://github.com/ad-freiburg/qlever.git
}

# ===== BUILD QLEVER =====
configure_and_build() {
  echo \"🏗️ Preparing QLever build...\"
  cd \"$QLEVER_DIR\"
  rm -rf build
  mkdir build && cd build

  if [[ \"$1\" == \"minimal\" ]]; then
    echo \"⚙️ Configuring minimal build (no tests)...\"
    cmake .. -DCMAKE_BUILD_TYPE=Developer -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_TESTING=OFF
  else
    echo \"⚙️ Configuring full build (with tests)...\"
    cmake .. -DCMAKE_BUILD_TYPE=Developer -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  fi

  echo \"🔨 Building with all cores...\"
  make -j$(nproc)
  cd ../..
}

# ===== USER INTERACTIVE MENU =====
while true; do
  echo \"❓ Choose setup mode:\"
  echo \"  [1] Full setup (deps, CMake, clone, build)\"
  echo \"  [2] Rebuild only (delete & rebuild QLever)\"
  echo \"  [3] Just build (run make in ./build)\"
  read -p \"Enter 1, 2 or 3: \" mode_choice

  build=\"(not applicable)\"
  build_type_flag=\"\"

  if [[ \"$mode_choice\" == \"1\" || \"$mode_choice\" == \"2\" ]]; then
    echo \"⚖️ Choose build type:\"
    echo \"  [1] Minimal build (QLeverServer only)\"
    echo \"  [2] Full build (with tests/benchmarks)\"
    read -p \"Enter 1 or 2: \" build_type_choice
    if [[ \"$build_type_choice\" == \"1\" ]]; then
      build=\"Minimal\"; build_type_flag=\"minimal\"
    elif [[ \"$build_type_choice\" == \"2\" ]]; then
      build=\"Full\"; build_type_flag=\"full\"
    else
      echo \"❌ Invalid build type. Try again.\"; continue
    fi
  fi

  if [[ \"$mode_choice\" == \"1\" ]]; then mode=\"Full setup\"
  elif [[ \"$mode_choice\" == \"2\" ]]; then mode=\"Rebuild only\"
  elif [[ \"$mode_choice\" == \"3\" ]]; then mode=\"Quick make\"
  else echo \"❌ Invalid mode. Try again.\"; continue; fi

  echo \"\"
  echo \"📝 You selected:\"
  echo \"  ➤ Mode:       $mode\"
  echo \"  ➤ Build type: $build\"
  echo \"\"
  read -p \"✅ Proceed with these settings? [y/n]: \" confirm
  if [[ \"$confirm\" == \"y\" || \"$confirm\" == \"Y\" ]]; then break; fi
done

# ===== FIND QLEVER DIRECTORY IF REBUILD OR QUICK BUILD =====
if [[ \"$mode_choice\" == \"2\" || \"$mode_choice\" == \"3\" ]]; then
  if [ -d \"qlever\" ]; then
    QLEVER_DIR=\"$PWD/qlever\"
  else
    read -p \"❓ Enter full path to QLever directory: \" QLEVER_DIR
    if [ ! -d \"$QLEVER_DIR\" ]; then
      echo \"❌ Path invalid. Exiting.\"; exit 1
    fi
  fi
fi

# ===== EXECUTE SELECTED OPERATION =====
if [[ \"$mode_choice\" == \"1\" ]]; then
  install_dependencies_and_cmake
  clone_qlever
  QLEVER_DIR=\"$PWD/qlever\"
  configure_and_build \"$build_type_flag\"
elif [[ \"$mode_choice\" == \"2\" ]]; then
  configure_and_build \"$build_type_flag\"
elif [[ \"$mode_choice\" == \"3\" ]]; then
  echo \"🔁 Running make in $QLEVER_DIR/build...\"
  cd \"$QLEVER_DIR/build\" || { echo \"❌ Build folder missing.\"; exit 1; }
  make -j$(nproc)
  echo \"✅ Build complete.\"
fi

# ===== PRINT SUMMARY AND METRICS =====
end_time=$(date +%s)
final_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
final_disk_kb=$(df --output=avail \"$HOME\" | tail -1)

mem_used_mb=$(( (initial_mem_kb - final_mem_kb) / 1024 ))
disk_used_mb=$(( (initial_disk_kb - final_disk_kb) / 1024 ))
duration=$(( end_time - start_time ))

echo \"\"
echo \"📝 Final selection: Mode = $mode, Build type = $build\"
echo \"🧠 Estimated RAM used: ${mem_used_mb} MB\"
echo \"💾 Estimated disk space used: ${disk_used_mb} MB\"
echo \"⏱️ Duration: $((duration / 60)) minutes $((duration % 60)) seconds\"
echo \"🎉 QLever environment is ready!\"
