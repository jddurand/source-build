#!/usr/bin/env bash
set -e
set -o pipefail

usage()
{
    echo "Builds a bootstrap CLI from sources"
    echo "Usage: $0 [BuildType] --rid <Rid> --seedcli <SeedCli> [--os <OS>] [--clang <Major.Minor>] [--corelib <CoreLib>]"
    echo ""
    echo "Options:"
    echo "  BuildType               Type of build (-debug, -release), default: -debug"
    echo "  -clang <Major.Minor>    Override of the version of clang compiler to use"
    echo "  -config <Configuration> Build configuration (debug, release), default: debug"
    echo "  -corelib <CoreLib>      Path to System.Private.CoreLib.dll, default: use the System.Private.CoreLib.dll from the seed CLI"
    echo "  -os <OS>                Operating system (used for corefx build), default: Linux"
    echo "  -rid <Rid>              Runtime identifier including the architecture part (e.g. rhel.6-x64)"
    echo "  -version <Version>      Force version number that must be in the format [0-9]+.[0-9]+.[0-9]+ - MUTUALLY EXCLUSE with -seedcli"
    echo "  -seedcli <SeedCli>      Seed CLI used to generate the target CLI - MUTUALLY EXCLUSE with -version"
    echo "  -outputpath <path>      Optional output directory to contain the generated cli and cloned repos, default: <Rid>"
    echo ""
    echo "When -version is used, then the latest commit of coreclr, corefx and core-setup default branches is checked out, and -version option value is used to fake the release number. This helps when there have been a fix that you want to have. One and only one of the -version or -seedcli options must be given."
    echo ""
    echo "For example, this will build latest core faking the version to be 2.0.99: $0 ... -version 2.0.99"
}

disable_pax_mprotect()
{
    if [[ $(command -v paxctl) ]]; then
        paxctl -c -m $1
    fi
}

get_max_version()
{
    local maxversionhi=0
    local maxversionmid=0
    local maxversionlo=0
    local maxversiontag
    local versionrest
    local versionhi
    local versionmid
    local versionlo
    local versiontag
    local foundmax

    for d in $1/*; do

        if [[ -d $d ]]; then
            versionrest=$(basename $d)
            versionhi=${versionrest%%.*}
            versionrest=${versionrest#*.}
            versionmid=${versionrest%%.*}
            versionrest=${versionrest#*.}
            versionlo=${versionrest%%-*}
            versiontag=${versionrest#*-}
            if [[ $versiontag == $versionrest ]]; then
                versiontag=""
            fi

            foundmax=0

            if [[ $versionhi -gt $maxversionhi ]]; then
                foundmax=1
            elif [[ $versionhi -eq $maxversionhi ]]; then
                if [[ $versionmid -gt $maxversionmid ]]; then
                    foundmax=1
                elif [[ $versionmid -eq $maxversionmid ]]; then
                    if [[ $versionlo -gt $maxversionlo ]]; then
                    foundmax=1
                    elif [[ $versionlo -eq $maxversionlo ]]; then
                        # tags are used to mark pre-release versions, so a version without a tag
                        # is newer than a version with one.
                        if [[ "$versiontag" == "" || $versiontag > $maxversiontag ]]; then
                            foundmax=1
                        fi
                    fi
                fi
            fi

            if [[ $foundmax != 0 ]]; then
                maxversionhi=$versionhi
                maxversionmid=$versionmid
                maxversionlo=$versionlo
                maxversiontag=$versiontag
            fi
        fi
    done

    echo $maxversionhi.$maxversionmid.$maxversionlo${maxversiontag:+-$maxversiontag}
}

getrealpath()
{
    if command -v realpath > /dev/null; then
        realpath $1
    else
        readlink -e $1
    fi
}

__build_os=Linux
__runtime_id=
__corelib=
__configuration=debug
__clangversion=
__outputpath=
__version=

while [[ "$1" != "" ]]; do
    lowerI="$(echo $1 | awk '{print tolower($0)}')"
    case $lowerI in
    -h|--help)
        usage
        exit 1
        ;;
    -rid)
        shift
        __runtime_id=$1
        ;;
    -os)
        shift
        __build_os=$1
        ;;
    -debug)
        __configuration=debug
        ;;
    -release)
        __configuration=release
        ;;
    -corelib)
        shift
        __corelib=$1
        ;;
    -seedcli)
        shift
        __seedclipath=`getrealpath $1`
        ;;
    -clang)
        shift
        __clangversion=clang$1
        ;;
    -outputpath)
        shift
        __outputpath=`getrealpath $1`
        ;;
    -version)
        shift
        __version=$1
        __majorversion=$(echo "$__version"|sed -e 's/^\([0-9]\+\)\.[0-9]\+\.[0-9]\+$/\1/')
        __minorversion=$(echo "$__version"|sed -e 's/^[0-9]\+\.\([0-9]\+\)\.[0-9]\+$/\1/')
        __patchversion=$(echo "$__version"|sed -e 's/^[0-9]\+\.[0-9]\+\.\([0-9]\+\)$/\1/')
        if [[ -z "$__majorversion" ]]; then
            echo "-version option value format must be digits.digits.digits"
            exit 2
        fi
        if [[ -z "$__minorversion" ]]; then
            echo "-version option value format must be digits.digits.digits"
            exit 2
        fi
        if [[ -z "$__patchversion" ]]; then
            echo "-version option value format must be digits.digits.digits"
            exit 2
        fi
        ;;
     *)
    echo "Unknown argument to build.sh $1"; exit 1
    esac
    shift
done

if [ -n "$__seedclipath" -a -n "$__version" ]; then
    echo "-seedcli and -version are mutually exclusive"
    exit 2
fi

if [ -z "$__seedclipath" -a -z "$__version" ]; then
    echo "One of -seedcli or -version is required"
    exit 2
fi

if [[ -z "$__runtime_id" ]]; then
    echo "Missing the required -rid argument"
    exit 2
fi

__build_arch=${__runtime_id#*-}

if [[ -z "$__outputpath" ]]; then
   __outputpath=`getrealpath $__runtime_id/dotnetcli`
fi

if [[ -d "$__outputpath" ]]; then
    /bin/rm -r $__outputpath
fi

mkdir -p $__runtime_id
mkdir -p $__outputpath

cd $__runtime_id

if [[ -n "$__seedclipath" ]]; then
    cp -r $__seedclipath/* $__outputpath

    __frameworkversion="2.0.0"
    __sdkversion="2.0.0"
    __fxrversion="2.0.0"

    echo "**** DETECTING VERSIONS IN SEED CLI ****"

    __frameworkversion=`get_max_version $__seedclipath/shared/Microsoft.NETCore.App`
    __sdkversion=`get_max_version $__seedclipath/sdk`
    __fxrversion=`get_max_version $__seedclipath/host/fxr`

else

    __frameworkversion=$__version
    __sdkversion=$__version
    __fxrversion=$__version

fi

echo "Framework version: $__frameworkversion"
echo "SDK version:       $__sdkversion"
echo "FXR version:       $__fxrversion"

__frameworkpath=$__outputpath/shared/Microsoft.NETCore.App/$__frameworkversion
mkdir -p "${__frameworkpath}"

if [[ -n "$__seedclipath" ]]; then
    echo "**** DETECTING GIT COMMIT HASHES ****"

    # Extract the git commit hashes representig the state of the three repos that
    # the seed cli package was built from
    __coreclrhash=`strings $__seedclipath/shared/Microsoft.NETCore.App/$__frameworkversion/libcoreclr.so | grep "@(#)" | grep -o "[a-f0-9]\{40\}"`
    __corefxhash=`strings $__seedclipath/shared/Microsoft.NETCore.App/$__frameworkversion/System.Native.so | grep "@(#)" | grep -o "[a-f0-9]\{40\}"`
    __coresetuphash=`strings $__seedclipath/dotnet | grep -o "[a-f0-9]\{40\}"`

else
    __coreclrhash=HEAD
    __corefxhash=HEAD
    __coresetuphash=HEAD
fi

echo "coreclr hash:    $__coreclrhash"
echo "corefx hash:     $__corefxhash"
echo "core-setup hash: $__coresetuphash"

# Clone the three repos if they were not cloned yet. If the folders already
# exist, leave them alone. This allows patching the cloned sources as needed

if [[ ! -d coreclr ]]; then
    echo "**** CLONING CORECLR REPOSITORY ****"
    git clone https://github.com/dotnet/coreclr.git
    if [[ -n "$__coreclrhash" ]]; then
        cd coreclr
        git checkout $__coreclrhash
        cd ..
    fi
fi

if [[ ! -d corefx ]]; then
    echo "**** CLONING COREFX REPOSITORY ****"
    git clone https://github.com/dotnet/corefx.git
    if [[ -n "$__corefxhash" ]]; then
        cd  corefx
        git checkout $__corefxhash
        cd ..
    fi
fi

if [[ ! -d core-setup ]]; then
    echo "**** CLONING CORE-SETUP REPOSITORY ****"
    git clone https://github.com/dotnet/core-setup.git
    if [[ -n "$__coresetuphash" ]]; then
        cd  core-setup
        git checkout $__coresetuphash
        cd ..
    fi
fi

echo "**** BUILDING CORE-SETUP NATIVE COMPONENTS ****"
cd core-setup
src/corehost/build.sh --arch "$__build_arch" --hostver "2.0.0" --apphostver "2.0.0" --fxrver "2.0.0" --policyver "2.0.0" --commithash `git rev-parse HEAD`
cd ..

echo "**** BUILDING CORECLR NATIVE COMPONENTS ****"
cd coreclr
./build.sh $__configuration $__build_arch $__clangversion -skipgenerateversion -skipmscorlib -skiprestore -skiprestoreoptdata -skipnuget -nopgooptimize 2>&1 | tee coreclr.log
export __coreclrbin=$(cat coreclr.log | sed -n -e 's/^.*Product binaries are available at //p')
cd ..
echo "CoreCLR binaries will be copied from $__coreclrbin"

echo "**** BUILDING COREFX NATIVE COMPONENTS ****"
corefx/src/Native/build-native.sh $__build_arch $__configuration $__clangversion $__build_os 2>&1 | tee corefx.log
export __corefxbin=$(cat corefx.log | sed -n -e 's/^.*Build files have been written to: //p')
echo "CoreFX binaries will be copied from $__corefxbin"

echo "**** Copying new binaries to dotnetcli/ ****"

# make sure some directories exists
mkdir -p $__frameworkpath
mkdir -p $__outputpath/sdk/$__sdkversion
mkdir -p $__outputpath/host/fxr

# First copy the coreclr repo binaries
cp $__coreclrbin/*so $__frameworkpath
cp $__coreclrbin/corerun $__frameworkpath
cp $__coreclrbin/crossgen $__frameworkpath

# Mark the coreclr executables as allowed to create executable memory mappings
disable_pax_mprotect $__frameworkpath/corerun
disable_pax_mprotect $__frameworkpath/crossgen

# Now copy the core-setup repo binaries
cp core-setup/cli/exe/dotnet/dotnet $__outputpath
cp core-setup/cli/exe/dotnet/dotnet $__frameworkpath/corehost

cp core-setup/cli/dll/libhostpolicy.so $__frameworkpath
cp core-setup/cli/dll/libhostpolicy.so $__outputpath/sdk/$__sdkversion

cp core-setup/cli/fxr/libhostfxr.so $__frameworkpath
cp core-setup/cli/fxr/libhostfxr.so $__outputpath/host/fxr/$__fxrversion
cp core-setup/cli/fxr/libhostfxr.so $__outputpath/sdk/$__sdkversion

# Mark the core-setup executables as allowed to create executable memory mappings
disable_pax_mprotect $__outputpath/dotnet
disable_pax_mprotect $__frameworkpath/corehost

# Finally copy the corefx repo binaries
cp $__corefxbin/**/System.* $__frameworkpath

# Copy System.Private.CoreLib.dll override from somewhere if requested
if [[ "$__corelib" != "" ]]; then
    cp "$__corelib" $__frameworkpath
fi

# Add the new RID to Microsoft.NETCore.App.deps.json
# Replace the linux-x64 RID in the target, runtimeTarget and runtimes by the new RID
# and add the new RID to the list of runtimes.
echo "**** Adding new rid to Microsoft.NETCore.App.deps.json ****"

#TODO: add parameter with the parent RID sequence
if [[ -n "$__seedclipath" ]]; then
    sed \
        -e 's/runtime\.linux-x64/runtime.'$__runtime_id'/g' \
        -e 's/runtimes\/linux-x64/runtimes\/'$__runtime_id'/g' \
        -e 's/Version=v\([0-9].[0-9]\)\/linux-x64/Version=v\1\/'$__runtime_id'/g' \
        -e 's/"runtimes": {/&\n    "'$__runtime_id'": [\n      "unix", "unix-x64", "any", "base"\n    ],/g' \
        $__seedclipath/shared/Microsoft.NETCore.App/$__frameworkversion/Microsoft.NETCore.App.deps.json \
        >$__frameworkpath/Microsoft.NETCore.App.deps.json
fi

echo "**** Bootstrap CLI was successfully built  ****"

