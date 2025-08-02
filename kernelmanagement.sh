#!/bin/bash

# Configuration
KERNELS_TO_KEEP=2 
# If true, performs a trial run without making changes
DRY_RUN=false
# If true, enables debug output
DEBUG_ENABLED=false

# List of kernel packages to always keep, regardless of version
KERNELS_TO_ALWAYS_KEEP_LIST="linux-image-amd64 linux-headers-amd64"

# Function to print debug messages if DEBUG_ENABLED is true
debug_echo() {
  if "${DEBUG_ENABLED}"; then
    echo "DEBUG: ${1}"
  fi
}

# Get the currently running kernel version
CURRENT_KERNEL_FULL_VERSION=$(uname -r)
echo "Current running kernel: ${CURRENT_KERNEL_FULL_VERSION}"
echo ""

# Declare arrays and associative arrays
declare -a ALL_KERNEL_PACKAGES          # Stores all installed kernel packages
declare -a PACKAGES_TO_REMOVE          # Stores packages marked for removal
declare -A PACKAGES_TO_KEEP_LOOKUP     # Lookup table for packages to keep
declare -a PACKAGES_TO_KEEP_DISPLAY    # List of packages to keep, for display

# Populate ALL_KERNEL_PACKAGES with installed kernel image and header packages
# Packages are sorted from newest to oldest
while IFS= read -r pkg; do
  if [[ -n "${pkg}" ]]; then
    ALL_KERNEL_PACKAGES+=("${pkg}")
  fi
done < <(dpkg --list | \
          awk '
/linux-(image|headers)/ {
  pkg_name = $2;
  sub(/,.*/, "", pkg_name);
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", pkg_name);
  if (pkg_name != "") {
    print pkg_name;
  }
}
          ' | sort -Vr || true)

echo "All installed specific kernel packages (sorted newest to oldest):"
printf '%s\n' "${ALL_KERNEL_PACKAGES[@]}"
echo ""

echo "--- Deciding which kernels to keep ---"

# Function to add a package to the "keep" lists
add_to_keep_lists() {
    local pkg_name="${1}"
    local reason="${2}"
    debug_echo "add_to_keep_lists called for pkg: '${pkg_name}', reason: '${reason}'"
    # Add package to lookup table and display list if not already present
    if [[ -z "${PACKAGES_TO_KEEP_LOOKUP[${pkg_name}]}" ]]; then
        PACKAGES_TO_KEEP_LOOKUP["${pkg_name}"]=1
        PACKAGES_TO_KEEP_DISPLAY+=("${pkg_name}")
        echo "Keeping (${reason}): ${pkg_name}"
    else
        debug_echo "'${pkg_name}' already in PACKAGES_TO_KEEP_LOOKUP. Skipping add."
    fi
}

# Step 1: Mark the currently running kernel for keeping
debug_echo "--- Step 1: Running Kernel ---"
for pkg in "${ALL_KERNEL_PACKAGES[@]}"; do
  if [[ "${pkg}" == *"${CURRENT_KERNEL_FULL_VERSION}"* ]]; then
    add_to_keep_lists "${pkg}" "running kernel"
  fi
done

# Step 2: Mark user-specified kernel packages for keeping
debug_echo "--- Step 2: User Specified Kernels ---"
for desired_version_part in ${KERNELS_TO_ALWAYS_KEEP_LIST}; do
  for pkg in "${ALL_KERNEL_PACKAGES[@]}"; do
    if [[ "${pkg}" == *"${desired_version_part}"* ]]; then
      add_to_keep_lists "${pkg}" "user specified"
    fi
  done
done

debug_echo "--- State before Step 3 (Latest Distinct Versions) ---"
if "${DEBUG_ENABLED}"; then
  echo "DEBUG: PACKAGES_TO_KEEP_LOOKUP contents:"
  for k in "${!PACKAGES_TO_KEEP_LOOKUP[@]}"; do echo "  - ${k}"; done
fi
debug_echo "KERNELS_TO_KEEP = ${KERNELS_TO_KEEP}"
debug_echo "Starting LATEST_KEPT_COUNT for this step (should be 0): 0"

# Step 3: Keep the specified number of latest distinct kernel versions
declare -A UNIQUE_VERSIONS_KEPT_COUNT # Tracks unique kernel versions kept
LATEST_KEPT_COUNT=0                   # Counter for distinct kernel versions kept

for pkg in "${ALL_KERNEL_PACKAGES[@]}"; do
  debug_echo "Processing pkg in Step 3 loop: '${pkg}'"
  # Skip if the package is already marked for keeping
  if [[ -n "${PACKAGES_TO_KEEP_LOOKUP[${pkg}]}" ]]; then
    debug_echo "'${pkg}' already in PACKAGES_TO_KEEP_LOOKUP. Skipping for LATEST_KEPT_COUNT."
    continue
  fi

  # Extract the version string from the package name
  VERSION_STRING=""
  temp_pkg_name="${pkg}"

  if [[ "${temp_pkg_name}" == linux-image-* ]]; then
      temp_pkg_name="${temp_pkg_name#linux-image-}"
  elif [[ "${temp_pkg_name}" == linux-headers-* ]]; then
      temp_pkg_name="${temp_pkg_name#linux-headers-}"
  else
      debug_echo "'${pkg}' does not start with linux-image- or linux-headers-. Skipping for LATEST_KEPT_COUNT."
      continue
  fi

  # Remove architecture suffixes from the version string
  declare -a ARCH_SUFFIXES=("-amd64" "-common" "-generic" "-pae" "-rt" "-cloud" "-arm64" "-raspi")
  for suffix in "${ARCH_SUFFIXES[@]}"; do
    if [[ "${temp_pkg_name}" == *"${suffix}" ]]; then
      temp_pkg_name="${temp_pkg_name%"${suffix}"}"
      break
    fi
  done

  VERSION_STRING="${temp_pkg_name}"

  if [[ -n "${VERSION_STRING}" ]]; then
      debug_echo "Extracted VERSION_STRING for '${pkg}': '${VERSION_STRING}'"
  else
      debug_echo "Extracted VERSION_STRING for '${pkg}' is empty. Skipping for LATEST_KEPT_COUNT."
      continue
  fi

  debug_echo "Checking conditions for adding: UNIQUE_VERSIONS_KEPT_COUNT['${VERSION_STRING}']='${UNIQUE_VERSIONS_KEPT_COUNT[${VERSION_STRING}]}', LATEST_KEPT_COUNT=${LATEST_KEPT_COUNT}, KERNELS_TO_KEEP=${KERNELS_TO_KEEP}"

  # If this is a new distinct version and we haven't reached KERNELS_TO_KEEP
  if [[ -z "${UNIQUE_VERSIONS_KEPT_COUNT[${VERSION_STRING}]}" && "${LATEST_KEPT_COUNT}" -lt "${KERNELS_TO_KEEP}" ]]; then
    debug_echo "Conditions met for VERSION_STRING '${VERSION_STRING}'. Adding this distinct version."
    UNIQUE_VERSIONS_KEPT_COUNT["${VERSION_STRING}"]=1
    ((LATEST_KEPT_COUNT++))
    debug_echo "New LATEST_KEPT_COUNT: ${LATEST_KEPT_COUNT}"

    # Mark all packages belonging to this distinct version for keeping
    for other_pkg in "${ALL_KERNEL_PACKAGES[@]}"; do
      if [[ "${other_pkg}" == *"linux-image-${VERSION_STRING}"* || "${other_pkg}" == *"linux-headers-${VERSION_STRING}"* ]]; then
        add_to_keep_lists "${other_pkg}" "latest distinct version"
      fi
    done
  else
    debug_echo "Conditions NOT met for VERSION_STRING '${VERSION_STRING}'. Skipping this distinct version."
  fi
done

debug_echo "--- End of Step 3 ---"
if "${DEBUG_ENABLED}"; then
  echo "DEBUG: Final PACKAGES_TO_KEEP_LOOKUP contents:"
  for k in "${!PACKAGES_TO_KEEP_LOOKUP[@]}"; do echo "  - ${k}"; done
fi

# Determine which packages to remove
for pkg in "${ALL_KERNEL_PACKAGES[@]}"; do
  # If a package is not in the "keep" lookup, mark it for removal
  if [[ -z "${PACKAGES_TO_KEEP_LOOKUP[${pkg}]}" && -n "${pkg}" ]]; then
    PACKAGES_TO_REMOVE+=("${pkg}")
  fi
done

# Sort and clean the list of packages to remove
mapfile -t PACKAGES_TO_REMOVE < <(printf "%s\n" "${PACKAGES_TO_REMOVE[@]}" | sort || true)
unset IFS

declare -a TEMP_PACKAGES_TO_REMOVE_FILTERED
for pkg_item in "${PACKAGES_TO_REMOVE[@]}"; do
    if [[ -n "${pkg_item}" ]]; then
        TEMP_PACKAGES_TO_REMOVE_FILTERED+=("${pkg_item}")
    fi
done
PACKAGES_TO_REMOVE=("${TEMP_PACKAGES_TO_REMOVE_FILTERED[@]}")
unset TEMP_PACKAGES_TO_REMOVE_FILTERED

debug_echo "--- Debugging PACKAGES_TO_REMOVE ---"
debug_echo "Number of packages to remove: ${#PACKAGES_TO_REMOVE[@]}"
if "${DEBUG_ENABLED}"; then
    if [[ "${#PACKAGES_TO_REMOVE[@]}" -gt 0 ]]; then
        debug_echo "Contents of PACKAGES_TO_REMOVE:"
        printf 'DEBUG: - %s\n' "${PACKAGES_TO_REMOVE[@]}"
    else
        debug_echo "PACKAGES_TO_REMOVE is empty."
    fi
fi
debug_echo "--- End Debugging PACKAGES_TO_REMOVE ---"

echo ""

# Handle dry run or actual removal
if "${DRY_RUN}"; then
  echo "This is a DRY RUN (--simulate). No actual changes will be made."
  echo ""

  if [[ "${#PACKAGES_TO_REMOVE[@]}" -gt 0 ]]; then
    echo "Simulating removal of specific kernels:"
    printf '%s\n' "${PACKAGES_TO_REMOVE[@]}"
    echo ""
    printf "Simulating: sudo apt purge --simulate %s\n" "${PACKAGES_TO_REMOVE[@]}"

    # Run a simulated apt purge
    APT_PURGE_SIM_OUTPUT=$(sudo apt purge --simulate "${PACKAGES_TO_REMOVE[@]}" 2>&1)
    APT_PURGE_SIM_EXIT_CODE=$?
    echo "${APT_PURGE_SIM_OUTPUT}"
    echo "Simulating initial cleanup complete. Checking for discrepancies..."

    if [[ "${APT_PURGE_SIM_EXIT_CODE}" -ne 0 ]]; then
      echo "WARNING: 'sudo apt purge --simulate' returned a non-zero exit code: ${APT_PURGE_SIM_EXIT_CODE}" >&2
      echo "Output: ${APT_PURGE_SIM_OUTPUT}" >&2
      echo "Discrepancy check might be incomplete due to simulation error." >&2
    fi

    # Check for discrepancies between intended keeps and simulated purges
    DISCREPANCY_FOUND=false
    for kept_pkg in "${PACKAGES_TO_KEEP_DISPLAY[@]}"; do
      if echo "${APT_PURGE_SIM_OUTPUT}" | grep -qP "Purg\\s+\\b${kept_pkg}\\b"; then
        pkg_len="${#kept_pkg}"
        content_len_line1=$(( 42 + pkg_len ))
        content_len_line7=$(( 21 + pkg_len ))
        fixed_content_len=56
        max_content_len="${fixed_content_len}"
        if [[ "${content_len_line1}" -gt "${max_content_len}" ]]; then
            max_content_len="${content_len_line1}"
        fi
        if [[ "${content_len_line7}" -gt "${max_content_len}" ]]; then
            max_content_len="${content_len_line7}"
        fi
        box_total_width=$(( max_content_len + 4 ))
        top_bottom_border=""
        for (( i=0; i<box_total_width; i++ )); do
            top_bottom_border="${top_bottom_border}!"
        done

        echo ""
        echo "${top_bottom_border}"
        printf "!! %-*s !!\n" "${max_content_len}" "WARNING: APT Simulation suggests purging '${kept_pkg}' !"
        printf "!! %-*s !!\n" "${max_content_len}" "The script intended to KEEP this package."
        printf "!! %-*s !!\n" "${max_content_len}" "This might be due to APT's dependency resolution or"
        printf "!! %-*s !!\n" "${max_content_len}" "if it deems the package no longer 'needed' after other"
        printf "!! %-*s !!\n" "${max_content_len}" "removals. For critical packages, consider running:"
        printf "!! %-*s !!\n" "${max_content_len}" ""
        printf "!! %-*s !!\n" "${max_content_len}" "  sudo apt-mark hold ${kept_pkg}"
        printf "!! %-*s !!\n" "${max_content_len}" ""
        printf "!! %-*s !!\n" "${max_content_len}" "before running the script without --dry-run."
        echo "${top_bottom_border}"
        echo ""
        DISCREPANCY_FOUND=true
      fi
    done
    if "${DISCREPANCY_FOUND}"; then
      echo "IMPORTANT: Review the 'apt-mark hold' suggestion above for critical packages."
      echo "To view all currently held packages: apt-mark showhold"
      echo "To unhold a package: sudo apt-mark unhold <package_name>"
      echo ""
    fi
  else
    echo "No specific old kernel packages found by the script's logic to remove."
    echo ""
  fi

else # Actual removal
  ACTION_TAKEN=false

  if [[ "${#PACKAGES_TO_REMOVE[@]}" -gt 0 ]]; then
    echo "Kernels and headers to be removed (by script's logic):"
    printf '%s\n' "${PACKAGES_TO_REMOVE[@]}"
    echo ""
    read -p "Do you want to proceed with purging the listed kernels? (y/N) " -n 1 -r
    echo
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      echo "Purging old kernels..."
      # Execute apt purge
      if sudo apt purge "${PACKAGES_TO_REMOVE[@]}"; then
        ACTION_TAKEN=true
      else
        echo "ERROR: 'sudo apt purge' failed with exit code $?." >&2
      fi
    else
      echo "Aborted specific kernel purge by user."
    fi
  else
    echo "No specific old kernel packages found by the script's logic to remove."
  fi

  if ! "${ACTION_TAKEN}"; then
    echo "Script finished. No actions were performed."
    exit 0
  else
    echo "Kernel cleanup complete."
  fi
fi

exit 0