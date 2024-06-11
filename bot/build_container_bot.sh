#!/bin/bash

SW_STACK_REPO=hpc.rug.nl
SW_STACK_OS=rocky8
SW_STACK_VERSION=2023.01
BUILD_CONTAINER=docker://ghcr.io/rug-cit-hpc/build-node:${SW_STACK_OS}
EB_CONFIG_FILE=/home1/f115372/easybuild/cit-hpc-easybuild/config/eb_configuration_habrok

function show_help() {
  echo "
Usage: $0 [OPTION]... <COMMAND>

  -a, --arch <ISA>/<VENDOR>/<uarch>      architecture to build for, e.g. x86_64/intel/haswell or x86_64/generic
  -b, --bind <DIR1[,DIR2,...,DIRN]>      bind the given host directory into the build container
  -g, --generic                          do a generic build and install to the generic stack
  -h, --help                             display this help and exit
  -k, --keep                             keep this run's temporary directory
  -n, --name <FILENAME>                  name of the resulting tarball
  -o, --output <DIRECTORY>               output directory for storing the produced tarball, no tarball is created when not set
  -r, --restricted                       install the given software to the restricted software stack
  -t, --tmpdir <DIRECTORY>               temporary directory to be used for CVMFS, fuse-overlayfs, and EasyBuild
  -v, --version <VERSION>                version number of the stack to build software for
"
}

function cleanup() {
  if [ -z "${NOCLEAN}" ]
  then
    echo "Cleaning up temporary directory ${MYTMPDIR} for this run..."
    rm -rf ${MYTMPDIR}
  else
    echo "Not cleaning up temporary directory ${MYTMPDIR} for this run."
  fi
}

function create_tarball() {
  # Make a tarball of the installed software if the overlay's upper dir is non-empty and an output directory is specified.
  if [ ! -z "${OUTDIR}" ]
  then
    OLDPWD=$PWD
    TOPDIR=${MYTMPDIR}/overlay/upper/versions
    if [ -z "${SW_GENERIC}" ]; then
      ARCHDIR=${SW_STACK_VERSION}/${SW_STACK_OS}/${SW_STACK_ARCH}
    else
      ARCHDIR=${SW_STACK_VERSION}/${SW_STACK_OS}/$(uname -m)/generic
    fi
    if [ -d "${TOPDIR}/${ARCHDIR}" ] && [ "$(ls -A ${TOPDIR}/${ARCHDIR})" ]
    then
      # Default tarball name: <version>-<architecture (/ replaced by -)>-<unix timestamp>.tar.gz
      TARBALL=${OUTDIR}/${TARBALL:-${SW_STACK_VERSION}-${SW_STACK_ARCH//\//-}-$(date +%s).tar.gz}
      FILES_LIST=${MYTMPDIR}/files.list.txt
      cd ${TOPDIR}

      # include the new Lmod cache
      # note that simultaneous builds could lead to race conditions
      #if [ -d ${ARCHDIR}/.lmod ]; then
        # include Lmod cache and configuration file (lmodrc.lua),
        # skip whiteout files and backup copies of Lmod cache (spiderT.old.*)
        # find ${ARCHDIR}/.lmod -type f | egrep -v '/\.wh\.|spiderT.old' > ${FILES_LIST}
      #fi
      if [ -d ${ARCHDIR}/modules ]; then
        # module files
        find ${ARCHDIR}/modules -type f > ${FILES_LIST}
        # module symlinks
        find ${ARCHDIR}/modules -type l >> ${FILES_LIST}
      fi
      if [ -d ${ARCHDIR}/software ]; then
        # find all installation directories with an easybuild subdirectory (which means they completed successfully)
        find ${ARCHDIR}/software/*/* -maxdepth 1 -name easybuild -type d | xargs -r dirname >> ${FILES_LIST}
      fi

      # create the tarball if new files were created
      if [ ! -s "${FILES_LIST}" ]; then
        echo "File list for tarball is empty, not creating a tarball."
      else
        echo "Creating tarball ${TARBALL} from ${TOPDIR}..."
        cd $OLDPWD
        tar --exclude=.cvmfscatalog --exclude=*.wh.* -C ${TOPDIR} -czf ${TARBALL} --files-from=${FILES_LIST}
        echo "${TARBALL} created!"
      fi
    else
      echo "Looks like no software has been installed, so not creating a tarball."
    fi
  else
    echo 'No tarball output directory specified, hence no tarball will be created.'
  fi
}

export -f create_tarball

# Parse command-line options

# Option strings
SHORT=g?h?k?r?a:b:n:o:t:v:
LONG=generic,help,keep,restricted,arch:bind:name:output:tmpdir:version:

# read the options
OPTS=$(getopt --options $SHORT --long $LONG --name "$0" -- "$@")

if [ $? != 0 ] ; then echo "Failed to parse options... exiting." >&2 ; exit 1 ; fi

eval set -- "$OPTS"

# extract options and their arguments into variables.
while true ; do
  case "$1" in
    -g | --generic )
      export SW_GENERIC=1
      shift
      ;;
    -h | --help )
      show_help
      exit 0
      ;;
    -k | --keep )
      NOCLEAN=1
      shift
      ;;
    -r | --restricted )
      export SW_STACK_RESTRICTED=1
      shift
      ;;
    -a | --arch )
      SW_STACK_ARCH="$2"
      shift 2
      ;;
    -b | --bind )
      BIND="$2"
      shift 2
      ;;
    -n | --name )
      TARBALL="$2"
      shift 2
      ;;
    -o | --outdir )
      OUTDIR="$2"
      shift 2
      ;;
    -t | --tmpdir )
      TMPDIR="$2"
      shift 2
      ;;
    -v | --version )
      SW_STACK_VERSION="$2"
      shift 2
      ;;
    -- )
      shift
      break
      ;;
    *)
      echo "Internal error!"
      exit 1
      ;;
  esac
done

# Always bind mount:
# $PWD
# /var/log (to prevent issues with CUDA installations)
# /apps (if available, for licensed apps)
# /var/lib/sss (if available), and /etc/nsswitch.conf, for ldap functionality
# all user-specified ones.
SINGBIND="-B $PWD -B /var/log"
if [ -d "/apps" ]
then
    SINGBIND="${SINGBIND} -B /apps"
fi
if [ -d "/var/lib/sss" ]
then
    SINGBIND="${SINGBIND} -B /var/lib/sss -B /etc/nsswitch.conf"
fi
for dir in ${BIND//,/ }
do
    SINGBIND="${SINGBIND} -B ${dir}"
done

if [ -z "${TMPDIR}" ]
then
  echo 'No temporary directory specified with $TMPDIR nor -t, so using /tmp as base temporary directory.'
  TMPDIR=/tmp
fi
mkdir -p ${TMPDIR}
MYTMPDIR=$(mktemp -p ${TMPDIR} -d eb_install.XXXXX)
[ -z ${MYTMPDIR} ] && echo "Failed to create temporary directory!" && exit 1
echo "Using ${MYTMPDIR} as temporary directory for this run."
export TMPDIR=${MYTMPDIR}
trap cleanup EXIT

if [ ! -z "${OUTDIR}" ]
then
  echo "Creating output directory ${OUTDIR}..."
  mkdir -p "${OUTDIR}"
fi

if [ -z ${SW_STACK_ARCH} ];
then
  # No architecture specified, so let's build for the current host.
  # Use archspec to determine the architecture name of this host.
  #ARCH=$(uname -m)/$(singularity exec ${BUILD_CONTAINER} archspec cpu)
  # Use EESSI's archdetect script to determine the architecture name of this host.
  SW_STACK_ARCH=$(singularity exec ${BUILD_CONTAINER} eessi_archdetect.sh cpupath)
  #SW_STACK_ARCH=x86_64/amd/zen2
elif [ ! -z "${SW_STACK_ARCH##*'/'*'/'*}" ]
then
  # Architecture was specified, but is invalid.
  echo "Error: invalid architecture. Please use <ISA>/<VENDOR>/<MICROARCHITECTURE>, e.g. x86_64/intel/haswell."
  exit 1
else
  # Architecture was specified correctly.
  # For cross-building: the Easybuild setting should only contain the last part,
  # e.g. "march=haswell" when "x86_64/intel/haswell" was specified.
  # But we currently disable cross-building, as it's usually quite dangerous.
  echo 'WARNING: custom architecture specified, but do note that this only affects the installation path (i.e. no cross-compiling)!'
  echo 'Only use this option if you are really sure what you are doing!'
  #export EASYBUILD_OPTARCH="march=${SW_STACK_ARCH#*/*/}"
fi

echo "Going to build for architecture ${SW_STACK_ARCH}."

mkdir -p ${MYTMPDIR}/cvmfs/{lib,run}
mkdir -p ${MYTMPDIR}/overlay/{upper,work}
mkdir -p ${MYTMPDIR}/pycache

# avoid that pyc files for EasyBuild are stored in EasyBuild installation directory
export PYTHONPYCACHEPREFIX=${MYTMPDIR}/pycache

CVMFS_LOCAL_DEFAULTS=${MYTMPDIR}/cvmfs/default.local
echo "SW_STACK_ARCH=${SW_STACK_ARCH}" > $CVMFS_LOCAL_DEFAULTS
echo "SW_STACK_OS=${SW_STACK_OS}" >> $CVMFS_LOCAL_DEFAULTS
echo "CVMFS_QUOTA_LIMIT=16384" >> $CVMFS_LOCAL_DEFAULTS
# Use host's proxy if it has one
if [ -f "/etc/cvmfs/default.local" ] && grep -q "^CVMFS_HTTP_PROXY=" /etc/cvmfs/default.local;
then
  # This doesn't always work too well, so for now it's disabled
  # grep "^CVMFS_HTTP_PROXY=" /etc/cvmfs/default.local >> ${CVMFS_LOCAL_DEFAULTS}
  echo 'CVMFS_HTTP_PROXY=DIRECT' >> ${CVMFS_LOCAL_DEFAULTS}
else
  echo 'CVMFS_HTTP_PROXY=DIRECT' >> ${CVMFS_LOCAL_DEFAULTS}
fi

# Configure EasyBuild
if [ ! -f "${EB_CONFIG_FILE}" ]
then
  echo "ERROR: cannot find ${EB_CONFIG_FILE}"
  exit 1
fi
source "${EB_CONFIG_FILE}"
# create and bind mount EasyBuild source paths
for dir in ${EASYBUILD_SOURCEPATH//:/ }
do
    SINGBIND="${SINGBIND} -B ${dir}"
done

# Generate the script that we need to actually build the software.
export COMMAND=$@
TMPSCRIPT=${MYTMPDIR}/eb_install.sh
cat << EOF > $TMPSCRIPT
#cd $HOME
# Source global definitions
[ -f /etc/bashrc ] && . /etc/bashrc
module use /cvmfs/${SW_STACK_REPO}/versions/${SW_STACK_VERSION}/${SW_STACK_OS}/${SW_STACK_ARCH}/modules/all
module purge

if ! module is-avail EasyBuild
then
  echo "No Easybuild installation found! Installing it for you..."
  pip3 install --prefix ${MYTMPDIR}/eb_tmp easybuild
  export PATH=${MYTMPDIR}/eb_tmp/bin:$PATH
  PYVER=\$(python3 -c 'import sys; print(str(sys.version_info[0])+"."+str(sys.version_info[1]))')
  echo "Found Python \${PYVER}, using this for Easybuild installation"
  export PYTHONPATH=${MYTMPDIR}/eb_tmp/lib/python\${PYVER}/site-packages:$PYTHONPATH
  #export PYTHONPATH=${MYTMPDIR}/eb_tmp/lib/python3.9/site-packages:$PYTHONPATH
  eb --install-latest-eb-release
fi
module load EasyBuild
$COMMAND

# Check for failures
ec=\$?
if [ \$ec -ne 0 ]
then
  # Copy the EasyBuild log from the temporary build directory to the job's directory
  eb_log_src=\$(eb --last-log)
  eb_log_dst="${PWD}/\$(basename \$eb_log_src)"
  echo "Software installation failed, copying EasyBuild log to \$eb_log_dst"
  cp "\$eb_log_src" "\$eb_log_dst"
fi

# Generate Lmod cache
DOT_LMOD="\${EASYBUILD_INSTALLPATH}/.lmod"
LMOD_RC="\${DOT_LMOD}/lmodrc.lua"
if [ ! -d "\${DOT_LMOD}" ]
then
  mkdir -p "\${DOT_LMOD}/cache"
fi

if [ ! -f "\${LMOD_RC}" ]
then
  cat > "\${LMOD_RC}" <<LMODRCEOF
propT = {
}
scDescriptT = {
    {
        ["dir"] = "\${DOT_LMOD}/cache",
        ["timestamp"] = "\${DOT_LMOD}/cache/timestamp",
    },
}
LMODRCEOF
fi
/bin/bash -l -c "/usr/share/lmod/lmod/libexec/update_lmod_system_cache_files -d \${DOT_LMOD}/cache -t \${DOT_LMOD}/cache/timestamp \${EASYBUILD_INSTALLPATH}/modules/all"
EOF

# Set up environment for the container: unset any Lmod settings from the host, pass the required variables for interactive use
unset MODULEPATH
if [ ! -z "${LMOD_DIR}" ];
then
  clearLmod
fi
export MYTMPDIR TARBALL OUTDIR SW_STACK_REPO SW_STACK_OS SW_STACK_VERSION SW_STACK_ARCH

# Determine if the host has a GPU, and make it available in the container
SING_GPU_FLAGS=""
if [ -c /dev/nvidia0 ];
then
    SING_GPU_FLAGS="--nv"
    SINGBIND="-B /etc/OpenCL/ ${SINGBIND}"
    export SW_BUILD_HOST_HAS_GPU=1
fi

# Launch the container. If a command was specified, we run the above script. Otherwise, we fire up an interactive shell.
SINGBIND="${SINGBIND} -B ${CVMFS_LOCAL_DEFAULTS}:/etc/cvmfs/default.local -B ${MYTMPDIR}/cvmfs/run:/var/run/cvmfs -B ${MYTMPDIR}/cvmfs/lib:/var/lib/cvmfs -B ${MYTMPDIR}"
if [ -z "${COMMAND}" ];
then
  singularity exec ${SING_GPU_FLAGS} ${SINGBIND} --fusemount "container:cvmfs2 ${SW_STACK_REPO} /cvmfs_ro/${SW_STACK_REPO}" --fusemount "container:fuse-overlayfs -o lowerdir=/cvmfs_ro/${SW_STACK_REPO} -o upperdir=${MYTMPDIR}/overlay/upper -o workdir=${MYTMPDIR}/overlay/work /cvmfs/${SW_STACK_REPO}" ${BUILD_CONTAINER} /bin/bash
else
  singularity shell ${SING_GPU_FLAGS} ${SINGBIND} --fusemount "container:cvmfs2 ${SW_STACK_REPO} /cvmfs_ro/${SW_STACK_REPO}" --fusemount "container:fuse-overlayfs -o lowerdir=/cvmfs_ro/${SW_STACK_REPO} -o upperdir=${MYTMPDIR}/overlay/upper -o workdir=${MYTMPDIR}/overlay/work /cvmfs/${SW_STACK_REPO}" ${BUILD_CONTAINER} < ${TMPSCRIPT}
fi

# Create a tarball of the installed software, if applicable
create_tarball
