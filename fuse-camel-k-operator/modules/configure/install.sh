
#!/bin/sh

set -x

SCRIPT_DIR=$(dirname $0)

generate_camel_catalog() {
    local camel_k_tag=$1
    local runtime_version=$2
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
