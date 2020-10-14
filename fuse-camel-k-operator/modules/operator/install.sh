#!/bin/bash
set -e
SCRIPT_DIR=$(dirname $0)
SCRIPTS_DIR=${SCRIPT_DIR}/scripts
SOURCES_DIR=/tmp/artifacts

microdnf install -y java-openjdk-headless

curl $RH_INTERNAL_CERT_URL -o redhat-internal-cert-install-0.1-20.el7.csb.noarch.rpm
rpm -ivh redhat-internal-cert-install-0.1-20.el7.csb.noarch.rpm 

if ! git clone https://code.engineering.redhat.com/gerrit/jboss-fuse/camel-k $CAMEL_K_TAG
    then
        echo "ERROR: Failed to checkout correct version of camel-k"
        return 1
    fi
pushd camel-k
MVN_EXTRA_OPTS=""
if ! mvn -s ../settings.xml $MVN_EXTRA_OPTS -f build/maven/pom-catalog.xml -Dcatalog.path=`pwd`/deploy -Druntime.version=$CAMEL_K_RUNTIME_VERSION
    then
        echo "ERROR: Failed to generate camel-catalog."
        popd
        return 1
fi 
cp deploy/camel-catalog-$CAMEL_K_RUNTIME_VERSION.yaml ../camel-catalog-$CAMEL_K_RUNTIME_VERSION.yaml

popd
