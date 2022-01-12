#!/bin/bash

# Copyright (C) 2021 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# rel_path <to> <from>
# Generate relative directory path to reach directory <to> from <from>
function rel_path() {
  local to=$1
  local from=$2
  local path=
  local stem=
  local prevstem=
  [ -n "$to" ] || return 1
  [ -n "$from" ] || return 1
  to=$(readlink -e "$to")
  from=$(readlink -e "$from")
  [ -n "$to" ] || return 1
  [ -n "$from" ] || return 1
  stem=${from}/
  while [ "${to#$stem}" == "${to}" -a "${stem}" != "${prevstem}" ]; do
    prevstem=$stem
    stem=$(readlink -e "${stem}/..")
    [ "${stem%/}" == "${stem}" ] && stem=${stem}/
    path=${path}../
  done
  echo ${path}${to#$stem}
}

# $1 directory of kernel modules ($1/lib/modules/x.y)
# $2 flags to pass to depmod
# $3 kernel version
function run_depmod() {
  (
    local ramdisk_dir=$1
    local depmod_stdout
    local depmod_stderr=$(mktemp)

    cd ${ramdisk_dir}
    if ! depmod_stdout="$(depmod $2 -F ${DIST_DIR}/System.map -b . $3 \
        2>${depmod_stderr})"; then
      echo "$depmod_stdout"
      cat ${depmod_stderr} >&2
      rm -f ${depmod_stderr}
      exit 1
    fi
    [ -n "$depmod_stdout" ] && echo "$depmod_stdout"
    cat ${depmod_stderr} >&2
    if { grep -q "needs unknown symbol" ${depmod_stderr}; }; then
      echo "ERROR: kernel module(s) need unknown symbol(s)" >&2
      rm -f ${depmod_stderr}
      exit 1
    fi
    rm -f ${depmod_stderr}
  )
}

# $1 MODULES_LIST, <File contains the list of modules that should go in the ramdisk>
# $2 MODULES_STAGING_DIR    <The directory to look for all the compiled modules>
# $3 IMAGE_STAGING_DIR  <The destination directory in which MODULES_LIST is
#                        expected, and it's corresponding modules.* files>
# $4 MODULES_BLOCKLIST, <File contains the list of modules to prevent from loading>
# $5 flags to pass to depmod
function create_modules_staging() {
  local modules_list_file=$1
  local src_dir=$(echo $2/lib/modules/*)
  local version=$(basename "${src_dir}")
  local dest_dir=$3/lib/modules/${version}
  local dest_stage=$3
  local modules_blocklist_file=$4
  local depmod_flags=$5

  rm -rf ${dest_dir}
  mkdir -p ${dest_dir}/kernel
  find ${src_dir}/kernel/ -maxdepth 1 -mindepth 1 \
    -exec cp -r {} ${dest_dir}/kernel/ \;
  # The other modules.* files will be generated by depmod
  cp ${src_dir}/modules.order ${dest_dir}/modules.order
  cp ${src_dir}/modules.builtin ${dest_dir}/modules.builtin

  if [[ -n "${EXT_MODULES}" ]] || [[ -n "${EXT_MODULES_MAKEFILE}" ]]; then
    mkdir -p ${dest_dir}/extra/
    cp -r ${src_dir}/extra/* ${dest_dir}/extra/

    # Check if we have modules.order files for external modules. This is
    # supported in android-mainline since 5.16 and androidX-5.15
    FIND_OUT=$(find ${dest_dir}/extra -name modules.order.* -print -quit)
    if [[ -n "${EXT_MODULES}" ]] && [[ "${FIND_OUT}" =~ modules.order ]]; then
      # If EXT_MODULES is defined and we have modules.order.* files for
      # external modules, then we should follow this module load order:
      #   1) Load modules in order defined by EXT_MODULES.
      #   2) Within a given external module, load in order defined by
      #      modules.order.
      for EXT_MOD in ${EXT_MODULES}; do
        # Since we set INSTALL_MOD_DIR=extra/${EXTMOD}, we can directly use the
        # modules.order.* file at that path instead of tring to figure out the
        # full name of the modules.order file. This is complicated because we
        # set M=... to a relative path which can't easily be calculated here
        # when using kleaf due to sandboxing.
        modules_order_file=$(ls ${dest_dir}/extra/${EXT_MOD}/modules.order.*)
        if [[ -f "${modules_order_file}" ]]; then
          cat ${modules_order_file} >> ${dest_dir}/modules.order
        else
          # We need to fail here; otherwise, you risk the module(s) not getting
          # included in modules.load.
          echo "Failed to find ${modules_order_file}" >&2
          exit 1
        fi
      done
    else
      # TODO: can we retain modules.order when using EXT_MODULES_MAKEFILE? For
      # now leave this alone since EXT_MODULES_MAKEFILE isn't support in v5.13+.
      (cd ${dest_dir}/ && \
        find extra -type f -name "*.ko" | sort >> modules.order)
    fi
  fi

  if [ "${DO_NOT_STRIP_MODULES}" = "1" ]; then
    # strip debug symbols off initramfs modules
    find ${dest_dir} -type f -name "*.ko" \
      -exec ${OBJCOPY:-${CROSS_COMPILE}objcopy} --strip-debug {} \;
  fi

  if [ -n "${modules_list_file}" ]; then
    # Need to make sure we can find modules_list_file from the staging dir
    if [[ -f "${ROOT_DIR}/${modules_list_file}" ]]; then
      modules_list_file="${ROOT_DIR}/${modules_list_file}"
    elif [[ "${modules_list_file}" != /* ]]; then
      echo "modules list must be an absolute path or relative to ${ROOT_DIR}: ${modules_list_file}"
      exit 1
    elif [[ ! -f "${modules_list_file}" ]]; then
      echo "Failed to find modules list: ${modules_list_file}"
      exit 1
    fi

    local modules_list_filter=$(mktemp)
    local old_modules_list=$(mktemp)

    # Remove all lines starting with "#" (comments)
    # Exclamation point makes interpreter ignore the exit code under set -e
    ! grep -v "^\#" ${modules_list_file} > ${modules_list_filter}

    # grep the modules.order for any KOs in the modules list
    cp ${dest_dir}/modules.order ${old_modules_list}
    ! grep -w -f ${modules_list_filter} ${old_modules_list} > ${dest_dir}/modules.order
    rm -f ${modules_list_filter} ${old_modules_list}
  fi

  if [ -n "${modules_blocklist_file}" ]; then
    # Need to make sure we can find modules_blocklist_file from the staging dir
    if [[ -f "${ROOT_DIR}/${modules_blocklist_file}" ]]; then
      modules_blocklist_file="${ROOT_DIR}/${modules_blocklist_file}"
    elif [[ "${modules_blocklist_file}" != /* ]]; then
      echo "modules blocklist must be an absolute path or relative to ${ROOT_DIR}: ${modules_blocklist_file}"
      exit 1
    elif [[ ! -f "${modules_blocklist_file}" ]]; then
      echo "Failed to find modules blocklist: ${modules_blocklist_file}"
      exit 1
    fi

    cp ${modules_blocklist_file} ${dest_dir}/modules.blocklist
  fi

  if [ -n "${TRIM_UNUSED_MODULES}" ]; then
    echo "========================================================"
    echo " Trimming unused modules"
    local used_blocklist_modules=$(mktemp)
    if [ -f ${dest_dir}/modules.blocklist ]; then
      # TODO: the modules blocklist could contain module aliases instead of the filename
      sed -n -E -e 's/blocklist (.+)/\1/p' ${dest_dir}/modules.blocklist > $used_blocklist_modules
    fi

    # Trim modules from tree that aren't mentioned in modules.order
    (
      cd ${dest_dir}
      find * -type f -name "*.ko" | grep -v -w -f modules.order -f $used_blocklist_modules - | xargs -r rm
    )
    rm $used_blocklist_modules
  fi

  # Re-run depmod to detect any dependencies between in-kernel and external
  # modules. Then, create modules.order based on all the modules compiled.
  run_depmod ${dest_stage} "${depmod_flags}" "${version}"
  cp ${dest_dir}/modules.order ${dest_dir}/modules.load
}

function build_vendor_dlkm() {
  echo "========================================================"
  echo " Creating vendor_dlkm image"

  create_modules_staging "${VENDOR_DLKM_MODULES_LIST}" "${MODULES_STAGING_DIR}" \
    "${VENDOR_DLKM_STAGING_DIR}" "${VENDOR_DLKM_MODULES_BLOCKLIST}"

  local vendor_dlkm_modules_root_dir=$(echo ${VENDOR_DLKM_STAGING_DIR}/lib/modules/*)
  local vendor_dlkm_modules_load=${vendor_dlkm_modules_root_dir}/modules.load
  if [ -f ${vendor_dlkm_modules_root_dir}/modules.blocklist ]; then
    cp ${vendor_dlkm_modules_root_dir}/modules.blocklist ${DIST_DIR}/vendor_dlkm.modules.blocklist
  fi

  # Modules loaded in vendor_boot should not be loaded in vendor_dlkm.
  if [ -f ${DIST_DIR}/vendor_boot.modules.load ]; then
    local stripped_modules_load="$(mktemp)"
    ! grep -x -v -F -f ${DIST_DIR}/vendor_boot.modules.load \
      ${vendor_dlkm_modules_load} > ${stripped_modules_load}
    mv -f ${stripped_modules_load} ${vendor_dlkm_modules_load}
  fi

  cp ${vendor_dlkm_modules_load} ${DIST_DIR}/vendor_dlkm.modules.load
  local vendor_dlkm_props_file

  if [ -z "${VENDOR_DLKM_PROPS}" ]; then
    vendor_dlkm_props_file="$(mktemp)"
    echo -e "vendor_dlkm_fs_type=ext4\n" >> ${vendor_dlkm_props_file}
    echo -e "use_dynamic_partition_size=true\n" >> ${vendor_dlkm_props_file}
    echo -e "ext_mkuserimg=mkuserimg_mke2fs\n" >> ${vendor_dlkm_props_file}
    echo -e "ext4_share_dup_blocks=true\n" >> ${vendor_dlkm_props_file}
  else
    vendor_dlkm_props_file="${VENDOR_DLKM_PROPS}"
    if [[ -f "${ROOT_DIR}/${vendor_dlkm_props_file}" ]]; then
      vendor_dlkm_props_file="${ROOT_DIR}/${vendor_dlkm_props_file}"
    elif [[ "${vendor_dlkm_props_file}" != /* ]]; then
      echo "VENDOR_DLKM_PROPS must be an absolute path or relative to ${ROOT_DIR}: ${vendor_dlkm_props_file}"
      exit 1
    elif [[ ! -f "${vendor_dlkm_props_file}" ]]; then
      echo "Failed to find VENDOR_DLKM_PROPS: ${vendor_dlkm_props_file}"
      exit 1
    fi
  fi
  build_image "${VENDOR_DLKM_STAGING_DIR}" "${vendor_dlkm_props_file}" \
    "${DIST_DIR}/vendor_dlkm.img" /dev/null
}

function build_boot_images() {
  BOOT_IMAGE_HEADER_VERSION=${BOOT_IMAGE_HEADER_VERSION:-3}
  if [ -z "${MKBOOTIMG_PATH}" ]; then
    MKBOOTIMG_PATH="tools/mkbootimg/mkbootimg.py"
  fi
  if [ ! -f "${MKBOOTIMG_PATH}" ]; then
    echo "mkbootimg.py script not found. MKBOOTIMG_PATH = ${MKBOOTIMG_PATH}"
    exit 1
  fi

  MKBOOTIMG_ARGS=("--header_version" "${BOOT_IMAGE_HEADER_VERSION}")
  if [ -n  "${BASE_ADDRESS}" ]; then
    MKBOOTIMG_ARGS+=("--base" "${BASE_ADDRESS}")
  fi
  if [ -n  "${PAGE_SIZE}" ]; then
    MKBOOTIMG_ARGS+=("--pagesize" "${PAGE_SIZE}")
  fi
  if [ -n "${KERNEL_VENDOR_CMDLINE}" -a "${BOOT_IMAGE_HEADER_VERSION}" -lt "3" ]; then
    KERNEL_CMDLINE+=" ${KERNEL_VENDOR_CMDLINE}"
  fi
  if [ -n "${KERNEL_CMDLINE}" ]; then
    MKBOOTIMG_ARGS+=("--cmdline" "${KERNEL_CMDLINE}")
  fi
  if [ -n "${TAGS_OFFSET}" ]; then
    MKBOOTIMG_ARGS+=("--tags_offset" "${TAGS_OFFSET}")
  fi
  if [ -n "${RAMDISK_OFFSET}" ]; then
    MKBOOTIMG_ARGS+=("--ramdisk_offset" "${RAMDISK_OFFSET}")
  fi

  DTB_FILE_LIST=$(find ${DIST_DIR} -name "*.dtb" | sort)
  if [ -z "${DTB_FILE_LIST}" ]; then
    if [ -z "${SKIP_VENDOR_BOOT}" ]; then
      echo "No *.dtb files found in ${DIST_DIR}"
      exit 1
    fi
  else
    cat $DTB_FILE_LIST > ${DIST_DIR}/dtb.img
    MKBOOTIMG_ARGS+=("--dtb" "${DIST_DIR}/dtb.img")
  fi

  rm -rf "${MKBOOTIMG_STAGING_DIR}"
  MKBOOTIMG_RAMDISK_STAGING_DIR="${MKBOOTIMG_STAGING_DIR}/ramdisk_root"
  mkdir -p "${MKBOOTIMG_RAMDISK_STAGING_DIR}"

  if [ -z "${SKIP_UNPACKING_RAMDISK}" ]; then
    if [ -n "${VENDOR_RAMDISK_BINARY}" ]; then
      VENDOR_RAMDISK_CPIO="${MKBOOTIMG_STAGING_DIR}/vendor_ramdisk_binary.cpio"
      rm -f "${VENDOR_RAMDISK_CPIO}"
      for vendor_ramdisk_binary in ${VENDOR_RAMDISK_BINARY}; do
        if ! [ -f "${vendor_ramdisk_binary}" ]; then
          echo "Unable to locate vendor ramdisk ${vendor_ramdisk_binary}."
          exit 1
        fi
        if ${DECOMPRESS_GZIP} "${vendor_ramdisk_binary}" 2>/dev/null >> "${VENDOR_RAMDISK_CPIO}"; then
          echo "${vendor_ramdisk_binary} is GZIP compressed"
        elif ${DECOMPRESS_LZ4} "${vendor_ramdisk_binary}" 2>/dev/null >> "${VENDOR_RAMDISK_CPIO}"; then
          echo "${vendor_ramdisk_binary} is LZ4 compressed"
        elif cpio -t < "${vendor_ramdisk_binary}" &>/dev/null; then
          echo "${vendor_ramdisk_binary} is plain CPIO archive"
          cat "${vendor_ramdisk_binary}" >> "${VENDOR_RAMDISK_CPIO}"
        else
          echo "Unable to identify type of vendor ramdisk ${vendor_ramdisk_binary}"
          rm -f "${VENDOR_RAMDISK_CPIO}"
          exit 1
        fi
      done

      # Remove lib/modules from the vendor ramdisk binary
      # Also execute ${VENDOR_RAMDISK_CMDS} for further modifications
      ( cd "${MKBOOTIMG_RAMDISK_STAGING_DIR}"
        cpio -idu --quiet <"${VENDOR_RAMDISK_CPIO}"
        rm -rf lib/modules
        eval ${VENDOR_RAMDISK_CMDS}
      )
    fi

  fi

  if [ -f "${VENDOR_FSTAB}" ]; then
    mkdir -p "${MKBOOTIMG_RAMDISK_STAGING_DIR}/first_stage_ramdisk"
    cp "${VENDOR_FSTAB}" "${MKBOOTIMG_RAMDISK_STAGING_DIR}/first_stage_ramdisk/"
  fi

  HAS_RAMDISK=
  MKBOOTIMG_RAMDISK_DIRS=()
  if [ -n "${VENDOR_RAMDISK_BINARY}" ] || [ -f "${VENDOR_FSTAB}" ]; then
    HAS_RAMDISK="1"
    MKBOOTIMG_RAMDISK_DIRS+=("${MKBOOTIMG_RAMDISK_STAGING_DIR}")
  fi

  if [ "${BUILD_INITRAMFS}" = "1" ]; then
    HAS_RAMDISK="1"
    if [ -z "${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_NAME}" ]; then
      MKBOOTIMG_RAMDISK_DIRS+=("${INITRAMFS_STAGING_DIR}")
    fi
  fi

  if [ -z "${HAS_RAMDISK}" ] && [ -z "${SKIP_VENDOR_BOOT}" ]; then
    echo "No ramdisk found. Please provide a GKI and/or a vendor ramdisk."
    exit 1
  fi

  if [ -n "${SKIP_UNPACKING_RAMDISK}" ] && [ -e "${VENDOR_RAMDISK_BINARY}" ]; then
    cp "${VENDOR_RAMDISK_BINARY}" "${DIST_DIR}/ramdisk.${RAMDISK_EXT}"
  elif [ "${#MKBOOTIMG_RAMDISK_DIRS[@]}" -gt 0 ]; then
    MKBOOTIMG_RAMDISK_CPIO="${MKBOOTIMG_STAGING_DIR}/ramdisk.cpio"
    mkbootfs "${MKBOOTIMG_RAMDISK_DIRS[@]}" >"${MKBOOTIMG_RAMDISK_CPIO}"
    ${RAMDISK_COMPRESS} "${MKBOOTIMG_RAMDISK_CPIO}" >"${DIST_DIR}/ramdisk.${RAMDISK_EXT}"
  fi

  if [ -n "${BUILD_BOOT_IMG}" ]; then
    if [ ! -f "${DIST_DIR}/$KERNEL_BINARY" ]; then
      echo "kernel binary(KERNEL_BINARY = $KERNEL_BINARY) not present in ${DIST_DIR}"
      exit 1
    fi
    MKBOOTIMG_ARGS+=("--kernel" "${DIST_DIR}/${KERNEL_BINARY}")
  fi

  if [ "${BOOT_IMAGE_HEADER_VERSION}" -ge "4" ]; then
    if [ -n "${VENDOR_BOOTCONFIG}" ]; then
      for PARAM in ${VENDOR_BOOTCONFIG}; do
        echo "${PARAM}"
      done >"${DIST_DIR}/vendor-bootconfig.img"
      MKBOOTIMG_ARGS+=("--vendor_bootconfig" "${DIST_DIR}/vendor-bootconfig.img")
      KERNEL_VENDOR_CMDLINE+=" bootconfig"
    fi
  fi

  if [ "${BOOT_IMAGE_HEADER_VERSION}" -ge "3" ]; then
    if [ -f "${GKI_RAMDISK_PREBUILT_BINARY}" ]; then
      MKBOOTIMG_ARGS+=("--ramdisk" "${GKI_RAMDISK_PREBUILT_BINARY}")
    fi

    if [ -z "${SKIP_VENDOR_BOOT}" ]; then
      MKBOOTIMG_ARGS+=("--vendor_boot" "${DIST_DIR}/vendor_boot.img")
      if [ -n "${KERNEL_VENDOR_CMDLINE}" ]; then
        MKBOOTIMG_ARGS+=("--vendor_cmdline" "${KERNEL_VENDOR_CMDLINE}")
      fi
      if [ -f "${DIST_DIR}/ramdisk.${RAMDISK_EXT}" ]; then
        MKBOOTIMG_ARGS+=("--vendor_ramdisk" "${DIST_DIR}/ramdisk.${RAMDISK_EXT}")
      fi
      if [ "${BUILD_INITRAMFS}" = "1" ] \
          && [ -n "${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_NAME}" ]; then
        MKBOOTIMG_ARGS+=("--ramdisk_type" "DLKM")
        for MKBOOTIMG_ARG in ${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_MKBOOTIMG_ARGS}; do
          MKBOOTIMG_ARGS+=("${MKBOOTIMG_ARG}")
        done
        MKBOOTIMG_ARGS+=("--ramdisk_name" "${INITRAMFS_VENDOR_RAMDISK_FRAGMENT_NAME}")
        MKBOOTIMG_ARGS+=("--vendor_ramdisk_fragment" "${DIST_DIR}/initramfs.img")
      fi
    fi
  else
    if [ -f "${DIST_DIR}/ramdisk.${RAMDISK_EXT}" ]; then
      MKBOOTIMG_ARGS+=("--ramdisk" "${DIST_DIR}/ramdisk.${RAMDISK_EXT}")
    fi
  fi

  if [ -z "${BOOT_IMAGE_FILENAME}" ]; then
    BOOT_IMAGE_FILENAME="boot.img"
  fi
  if [ -n "${BUILD_BOOT_IMG}" ]; then
    MKBOOTIMG_ARGS+=("--output" "${DIST_DIR}/${BOOT_IMAGE_FILENAME}")
  fi

  for MKBOOTIMG_ARG in ${MKBOOTIMG_EXTRA_ARGS}; do
    MKBOOTIMG_ARGS+=("${MKBOOTIMG_ARG}")
  done

  "${MKBOOTIMG_PATH}" "${MKBOOTIMG_ARGS[@]}"

  if [ -n "${BUILD_BOOT_IMG}" -a -f "${DIST_DIR}/${BOOT_IMAGE_FILENAME}" ]; then
    echo "boot image created at ${DIST_DIR}/${BOOT_IMAGE_FILENAME}"

    if [ -n "${AVB_SIGN_BOOT_IMG}" ]; then
      if [ -n "${AVB_BOOT_PARTITION_SIZE}" ] \
          && [ -n "${AVB_BOOT_KEY}" ] \
          && [ -n "${AVB_BOOT_ALGORITHM}" ]; then
        echo "Signing ${BOOT_IMAGE_FILENAME}..."

        if [ -z "${AVB_BOOT_PARTITION_NAME}" ]; then
          AVB_BOOT_PARTITION_NAME=${BOOT_IMAGE_FILENAME%%.*}
        fi

        avbtool add_hash_footer \
            --partition_name ${AVB_BOOT_PARTITION_NAME} \
            --partition_size ${AVB_BOOT_PARTITION_SIZE} \
            --image "${DIST_DIR}/${BOOT_IMAGE_FILENAME}" \
            --algorithm ${AVB_BOOT_ALGORITHM} \
            --key ${AVB_BOOT_KEY}
      else
        echo "Missing the AVB_* flags. Failed to sign the boot image" 1>&2
        exit 1
      fi
    fi
  fi

  if [ -z "${SKIP_VENDOR_BOOT}" ] \
    && [ "${BOOT_IMAGE_HEADER_VERSION}" -ge "3" ] \
    && [ -f "${DIST_DIR}/vendor_boot.img" ]; then
      echo "vendor boot image created at ${DIST_DIR}/vendor_boot.img"
  fi
}

function make_dtbo() {
  echo "========================================================"
  echo " Creating dtbo image at ${DIST_DIR}/dtbo.img"
  (
    cd ${OUT_DIR}
    mkdtimg create "${DIST_DIR}"/dtbo.img ${MKDTIMG_FLAGS} ${MKDTIMG_DTBOS}
  )
}
