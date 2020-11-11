#!/usr/bin/env bash

set -euo pipefail

MIRROR_REG=${MIRROR_REG:-}
PRODUCT_NAME=${PRODUCT_NAME:-pipeline}
INDEX=${INDEX:-}
BREW_IIB_PREFIX="brew.registry.redhat.io/rh-osbs/iib"
REGISTRY_IMAGE=$BREW_IIB_PREFIX:$INDEX
OUTPUT_IMAGE=$MIRROR_REG/rh-osbs/iib:$INDEX
ENVIRONMENT=${ENVIRONMENT:-"pre-stage"}

echo -e $REGISTRY_IMAGE

if [ -z $MIRROR_REG ]; then
  echo -e "Specify mirror registry as a parameter of this script \n"
  echo "Usage:"
  echo "  $0 [name]"
  exit 1
fi

if [ -z $INDEX ]; then
  echo -e "Specify Index tag for catalogsource as a parameter of this script \n"
  echo "Usage:"
  echo "  $0 [name]"
  exit 1
fi

if [ -z $USERNAME ]; then
  echo -e "Specify Brew registry Username \n"
  echo "Usage:"
  echo "  $0 [name]"
  exit 1
fi

if [ -z $PASSWORD ]; then
  echo -e "Specify Brew registry Password \n"
  echo "Usage:"
  echo "  $0 [name]"
  exit 1
fi


if [ -z $KBUSER ]; then
  echo -e "Specify kerbrose Username \n"
  echo "Usage:"
  echo "  $0 [name]"
  exit 1
fi

if [ -z $KBPASSWORD ]; then
  echo -e "Specify kerbrose Password \n"
  echo "Usage:"
  echo "  $0 [name]"
  exit 1
fi


function wait_run_in_parallel()
{
    local number_to_run_concurrently=$1
    if [ `jobs -np | wc -l` -gt $number_to_run_concurrently ]; then
        wait `jobs -np | head -1` # wait for the oldest one to finish
    fi
}

function mirror_images()
{
    local sleep_time=$(($RANDOM % 10))
    echo "mirroring $1 --> $2"
    sleep $sleep_time && skopeo copy --all docker://$1 docker://$2 --dest-tls-verify=false || exit 1
}


# Logging into registry.redhat.io && registry.access.redhat.com
oc registry login --registry registry.access.redhat.com --auth-basic="$KBUSER:$KBPASSWORD" --insecure=true || true
oc registry login --registry registry.redhat.io --auth-basic="$KBUSER:$KBPASSWORD" --insecure=true|| true

# Podman loggin into registry.redhat.io && registry.access.redhat.com
podman login -u $KBUSER -p $KBPASSWORD registry.access.redhat.com --tls-verify=false && \
podman login -u $KBUSER -p $KBPASSWORD registry.redhat.io --tls-verify=false


function reset() {
  rm -rf authfile
}

function reset_images_mapping() {
  echo "Restore image-config.yaml"
  cp ./iib-manifests/mapping.txt.bk ./iib-manifests/mapping.txt || true
  rm -rf ./iib-manifests/mapping.txt.bk
}


oc get secret/pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' |
base64 -d > authfile
trap reset ERR EXIT

# Logging into mirror registry
echo "Loggin to on mirror-registry"
oc registry login --registry $MIRROR_REG --auth-basic="dummy:dummy" --insecure=true
podman login -u dummy -p dummy $MIRROR_REG --tls-verify=false

sleep 3
echo -e "Add mirror-registry authtication details to default pull-secret"
oc registry login  --insecure=true --registry $MIRROR_REG --auth-basic="dummy:dummy" --to=authfile

sleep 3 

echo "set mirror-registry authtication details to default pull-secret"
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=authfile
sleep 3

# Loggin into brew registry 
podman login -u $USERNAME -p $PASSWORD brew.registry.redhat.io --tls-verify=true
oc registry login --registry brew.registry.redhat.io  --auth-basic="$USERNAME:$PASSWORD" --insecure=true


# Tag, build & push iib image
podman pull $REGISTRY_IMAGE

podman tag $REGISTRY_IMAGE $OUTPUT_IMAGE 

podman push $OUTPUT_IMAGE --tls-verify=false


# Generate Manifests required to configure operatorhub 
oc adm catalog mirror $OUTPUT_IMAGE $MIRROR_REG --insecure --filter-by-os=".*" --manifests-only

echo "Backup mapping.txt"
cp ./iib-manifests/mapping.txt ./iib-manifests/mapping.txt.bk
trap reset_images_mapping ERR EXIT

if [[ ${ENVIRONMENT} = "stage" ]]; then
   sed  -i -e "s|registry.redhat.io/openshift-pipelines-tech-preview/|brew.registry.redhat.io/rh-osbs/openshift-pipelines-tech-preview-|g" \
        -e "s|registry.stage.redhat.io/rh-osbs|brew.registry.redhat.io/rh-osbs|g" \
        -e "s|registry.stage.redhat.io|brew.registry.redhat.io|g" \
        -e "s|registry-proxy.engineering.redhat.com|brew.registry.redhat.io|g" \
        ./iib-manifests/mapping.txt
else
   sed  -i -e "s|registry.redhat.io/openshift-pipelines-tech-preview/|brew.registry.redhat.io/rh-osbs/openshift-pipelines-tech-preview-|g" \
        -e "s|registry-proxy.engineering.redhat.com/rh-osbs|brew.registry.redhat.io/rh-osbs|g" \
        -e "s|registry.stage.redhat.io|brew.registry.redhat.io|g" \
        -e "s|registry-proxy.engineering.redhat.com|brew.registry.redhat.io|g" \
        ./iib-manifests/mapping.txt
fi

sed -i -e 's/\(.*\)\(:.*$\)/\1/' ./iib-manifests/mapping.txt

find_list="\
registry.access.redhat.com/ubi8/ubi-minimal \
openshift-serverless-1/client-kn-rhel8 \
rhel8/skopeo \
rhel8/buildah \
ocp-tools-43-tech-preview/source-to-image-rhel8 \
pipelines \
"

for item in $find_list; do
   grep -E "$item" ./iib-manifests/mapping.txt >> final-mapping.txt
done

rm -rf ./iib-manifests/mapping.txt

echo -e ">> started mirroring!..."
cat final-mapping.txt | while read mapping
do
    for images in $mapping
    do
        image=($(echo $images | tr "=" "\n"))
        mirror_images ${image[0]} ${image[1]} &
        # now wait if there are more than N sub processes executing
        wait_run_in_parallel 1
    done
done
wait

sed -e "s/\$MIRROR_REG/$MIRROR_REG/" \
       "imagecontentsourcepolicy.yaml" | oc apply -f - || true

oc apply -f - << EOD
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: iib
spec:
  repositoryDigestMirrors:
  - mirrors:
      - $MIRROR_REG
    source: registry-proxy.engineering.redhat.com
  - mirrors:
      - $MIRROR_REG
    source: registry.access.redhat.com
  - mirrors:
      - $MIRROR_REG
    source: registry.redhat.io    
  - mirrors:
      - $MIRROR_REG
    source: registry.stage.redhat.io
  - mirrors:
      - $MIRROR_REG
    source: docker.io
  - mirrors:
      - $MIRROR_REG
    source: quay.io
  - mirrors:
      - $MIRROR_REG/openshift-release-dev/ocp-release
    source: quay.io/openshift-release-dev/ocp-release 
  - mirrors:
      - $MIRROR_REG/openshift-release-dev/ocp-release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
EOD

#DisableDefaultSources
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'


echo ">> waiting for nodes to get restarted.."
machines=$(oc get machineconfigpool -o=jsonpath='{.items[*].metadata.name}{" "}')

sleep 60

for machine in ${machines}; do
    echo ">> Waiting for machineconfigpool on node $machine to be in state Updated=true && Updating=false"
    while true; do
      sleep 3
      oc wait --for=condition=Updated=True -n openshift-operators machineconfigpool $machine --timeout=5m && oc wait --for=condition=Updating=False -n openshift-operators machineconfigpool $machine --timeout=5m > /dev/null 2>&1 && break
    done
done

# Create/apply catalog source
oc apply -f - << EOD
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $OUTPUT_IMAGE
  displayName: redhat-operators-stage
  updateStrategy:
    registryPoll:
      interval: 30m
EOD