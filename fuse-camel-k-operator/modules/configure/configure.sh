#!/bin/bash

set -o pipefail
set -eu

BASE_BUILD_URL=${BASE_BUILD_URL:-http://indy.psi.redhat.com/api/content/maven/group/redhat-builds/}
TEMP_BUILD_URL=${BASE_BUILD_URL:-http://indy.psi.redhat.com/api/content/maven/group/temporary-builds/}

display_usage() {
    cat <<EOT
Build script to start the docker build of camel-k.
Specify the redhat version and git tag for camel-k, the redhat version of
the camel-k-runtime and the redhat version of camel.
Usage: build-image.sh [options] -v <camel-k-version> -t <camel-k-tag> -r <runtime-version> -c <camel-version>
with options:
-d, --dry-run   Run without committing and changes or running in OSBS.
    --scratch   When running the build, do a scratch build (only applicable if NOT running in dry-run mode)
--help          This help message
EOT
}

cleanup() {
    sudo rm -f *.gz
    sudo rm -rf camel-k  2> /dev/null || true

    if [ -d "camel-k" ]
    then
        echo "Could not delete camel-k directory."
        echo "Please run the following command:"
        echo "sudo /usr/bin/rm -rf camel-k"
    fi
}

download() {
    local url=$1
    local filename=`basename $url`

    if [ -f $filename ]
    then
        echo "File $filename already exists. Skipping download."
        return 0
    fi

    echo "Downloading $url"
    wget -q $url
    if [ $? -ne 0 ]
    then
        echo "Error downloading file from $url."
        return 1
    fi

    # See if there is a md5 file
    if [ -f $filename.md5 ]
    then
        sudo /usr/bin/rm $filename.md5
    fi

    wget -q $url.md5
    if [ $? -ne 0 ]
    then
        echo "Error downloading file from $url.md5."
        return 1
    fi

    if ! md5sum $filename | cut -d ' ' -f 1 | tr -d '\n' | cmp - $filename.md5
    then
        echo "ERROR: md5sums do not match for $filename"
        return 1
    fi

    return 0
}

clone_repo() {
    local repo=$1
    local tag=$2

    local dir=`basename $repo`

    if [ ! -d $dir ]
    then
        if ! git clone $repo
        then
            echo "ERROR: Failed to clone $repo"
            return 1
        fi
    fi

    pushd $dir
    git fetch --tags
    if ! git checkout $tag
    then
        popd
        echo "ERROR: Failed to checkout $tag in $repo"
        return 1
    fi

    popd
    return 0
}

generate_camel_catalog() {
    local camel_k_tag=$1
    local runtime_version=$2
    local dry_run=$3

    echo "generate_camel_catalog()"

    if ! clone_repo https://code.engineering.redhat.com/gerrit/jboss-fuse/camel-k $camel_k_tag
    then
        echo "ERROR: Failed to checkout correct version of camel-k"
        return 1
    fi

    update_makefile

    MVN_EXTRA_OPTS=""

    pushd camel-k
    if ! mvn -s ../settings.xml $MVN_EXTRA_OPTS -f build/maven/pom-catalog.xml -Dcatalog.path=`pwd`/deploy -Druntime.version=$runtime_version
    then
        echo "ERROR: Failed to generate camel-catalog."
        popd
        return 1
    fi

    cp deploy/camel-catalog-$runtime_version.yaml ../camel-catalog-$runtime_version.yaml
    popd

    if [ "$dry_run" == "false" ]
    then
        git add camel-catalog-$runtime_version.yaml
    fi
}

update_source_repos() {
    local tag=$1
    local dryRun=$2

    echo "Updating source-repos"
    sed -i "/camel-k /{s/ [^ ]*/ $tag/1}" source-repos

    if [ "$dryRun" == "false" ]
    then
        git add source-repos
    fi
}

update_vendor_archive() {
    local dryRun=$1

    docker run --rm -v $PWD/camel-k:/usr/src/camel-k:z \
           -w /usr/src/camel-k/cmd golang:1.13.6 \
           /bin/bash -c "go mod vendor"

    pushd camel-k
    tar zcf vendor.tar.gz vendor
    popd

    mv camel-k/vendor.tar.gz .

    sed -i '/vendor.tar.gz$/d' sources

    # Add new vendor archive to lookaside cache
    if [ "$dryRun" == "false" ]
    then
        rhpkg new-sources vendor.tar.gz
    fi
}

update_makefile() {
    echo "== update_makefile() =="
    sed -i "s/-mod=vendor //g" camel-k/Makefile
    cat camel-k/Makefile
    sed -i "s/-mod=vendor //g" camel-k/script/Makefile
    cat camel-k/script/Makefile
    sed -i "s/-mod=vendor //g" camel-k/script/embed_resources.sh
    cat camel-k/script/embed_resources.sh
    sudo rm -rf camel-k/vendor
}

update_dockerfile() {
    local camel_k_version=$1
    local camel_k_tag=$2
    local runtime_version=$3
    local camel_version=$4
    local camel_quarkus_version=$5
    local dryRun=$=3

    echo "Updating Dockerfile"
    sed -i "/^ENV/,/^$/s/\(.*\)CAMEL_K_VERSION\([ =]\)[0-9a-zA-Z\.-]\+\(.*\)/\1CAMEL_K_VERSION\2$camel_k_version\3/" Dockerfile
    sed -i "/^ENV/,/^$/s/\(.*\)CAMEL_K_TAG\([ =]\)[0-9a-zA-Z\.-]\+\(.*\)/\1CAMEL_K_TAG\2$camel_k_tag\3/" Dockerfile
    sed -i "/^ENV/,/^$/s/\(.*\)CAMEL_K_RUNTIME_VERSION\([ =]\)[0-9a-zA-Z\.-]\+\(.*\)/\1CAMEL_K_RUNTIME_VERSION\2$runtime_version\3/" Dockerfile
    sed -i "/^ENV/,/^$/s/\(.*\)CAMEL_VERSION\([ =]\)[0-9a-zA-Z\.-]\+\(.*\)/\1CAMEL_VERSION\2$camel_version\3/" Dockerfile
    sed -i "/^ENV/,/^$/s/\(.*\)CAMEL_QUARKUS_VERSION\([ =]\)[0-9a-zA-Z\.-]\+\(.*\)/\1CAMEL_QUARKUS_VERSION\2$camel_quarkus_version\3/" Dockerfile

    if [ "$dryRun" == "false" ]
    then
        git add Dockerfile
    fi
}

osbs_build() {
    local version=$1
    local scratchBuild=$2

    num_files=$(git status --porcelain  | { egrep '^\s?[MADRC]' || true; } | wc -l)
    if ((num_files > 0)) ; then
        echo "Committing $num_files"
        git commit -m "Updated for build of camel-k $version" .
        git push
    else
        echo "There are no files to be committed. Skipping commit + push"
    fi

    if [ "$scratchBuild" == "false" ]
    then
        echo "Starting OSBS build"
        rhpkg container-build --repo-url http://git.engineering.redhat.com/git/users/ttomecek/osbs-signed-packages.git/plain/released.repo
    else
        local branch=$(git rev-parse --abbrev-ref HEAD)
        local build_options=""

        # If we are building on a private branch, then we need to use the correct target
        if [[ $branch == *"private"* ]] ; then
            # Remove the private part of the branch name: from private-opiske-fuse-7.4-openshift-rhel-7
            # to fuse-7.4-openshift-rhel-7 and we add the containers candidate to the options
            local target="${branch#*-*-}-containers-candidate"

            build_options="${build_options} --target ${target}"
            echo "Using target ${target} for the private container build"
        fi

        echo "Starting OSBS scratch build"
        rhpkg container-build --scratch ${build_options} --repo-url http://git.engineering.redhat.com/git/users/ttomecek/osbs-signed-packages.git/plain/released.repo
    fi
}

main() {
    CAMEL_VERSION=
    CAMEL_K_VERSION=
    CAMEL_K_TAG=
    RUNTIME_VERSION=
    DRY_RUN=false
    SCRATCH=false

    # Parse command line arguments
    while [ $# -gt 0 ]
    do
        arg="$1"

        case $arg in
          -h|--help)
            display_usage
            exit 0
            ;;
          -c|--camel-version)
            shift
            CAMEL_VERSION="$1"
            ;;
          -d|--dry-run)
            DRY_RUN=true
            ;;
          --scratch)
            SCRATCH=true
            ;;
          -q|--quarkus-version)
            shift
            CAMEL_QUARKUS_VERSION="$1"
            ;;
          -r|--runtime-version)
            shift
            RUNTIME_VERSION="$1"
            ;;
          -t|--tag)
            shift
            CAMEL_K_TAG="$1"
            ;;
          -v|--version)
            shift
            CAMEL_K_VERSION="$1"
            ;;
          *)
            echo "Unknown argument: $1"
            display_usage
            exit 1
            ;;
        esac
        shift
    done

    # Check that the camel-k version is specified
    if [ -z "$CAMEL_K_VERSION" ]
    then
        echo "ERROR: Camel-k version wasn't specified."
        exit 1
    fi

    # Check that the camel-k tag is specified
    if [ -z "$CAMEL_K_TAG" ]
    then
        echo "ERROR: Camel-k tag wasn't specified."
        exit 1
    fi

    # Check that the camel-k-runtime version is specified
    if [ -z "$RUNTIME_VERSION" ]
    then
        echo "ERROR: Camel-k-runtime version wasn't specified."
        exit 1
    fi

    # Check that the camel-k-runtime version is specified
    if [ -z "$CAMEL_VERSION" ]
    then
        echo "ERROR: Camel version wasn't specified."
        exit 1
    fi

    # Check that the camel-quarkus version is specified
    if [ -z "$CAMEL_QUARKUS_VERSION" ]
    then
        echo "ERROR: Camel Quarkus version wasn't specified."
        exit 1
    fi

    cleanup

    generate_camel_catalog $CAMEL_K_TAG $RUNTIME_VERSION $DRY_RUN

    update_source_repos $CAMEL_K_TAG $DRY_RUN

    update_vendor_archive $DRY_RUN

    update_dockerfile $CAMEL_K_VERSION $CAMEL_K_TAG $RUNTIME_VERSION $CAMEL_VERSION $CAMEL_QUARKUS_VERSION $DRY_RUN

    # Download java artifact from PNC
    if ! download ${BASE_BUILD_URL}/org/apache/camel/k/apache-camel-k-runtime/$RUNTIME_VERSION/apache-camel-k-runtime-$RUNTIME_VERSION-m2.zip
    then
        if ! download ${TEMP_BUILD_URL}/org/apache/camel/k/apache-camel-k-runtime/$RUNTIME_VERSION/apache-camel-k-runtime-$RUNTIME_VERSION-m2.zip
        then
            exit 1
        fi
    fi

    echo "Downloading apache-maven-3.6.3 ...."
    if [ -f apache-maven-3.6.3-bin.tar.gz ]
    then
        echo "File apache-maven-3.6.3-bin.tar.gz already exists. Skipping download."
    else
        wget https://archive.apache.org/dist/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz

        ls -ltr *.tar.gz
    fi

    # Upload maven artifact to lookaside cache
    if ! rhpkg upload apache-maven-3.6.3-bin.tar.gz
    then
        echo "Error uploading apache-maven-3.6.3-bin.tar.gz to lookaside cache"
        exit 1
    fi

    # Upload java artifact to lookaside cache
    if ! rhpkg upload apache-camel-k-runtime-$RUNTIME_VERSION-m2.zip
    then
        echo "Error uploading apache-camel-k-runtime-$RUNTIME_VERSION-m2.zip to lookaside cache"
        exit 1
    fi

    if [ "$DRY_RUN" == "false" ]
    then
        osbs_build $CAMEL_K_VERSION $SCRATCH
    fi
}

main $*