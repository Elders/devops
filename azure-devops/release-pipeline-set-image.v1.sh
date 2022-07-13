set -e          ### make errors fatal

############# settings ###############

WAIT=20         ### how long to wait before result checks

############## stop edit here ##################

[ -z `expr match "$BUILD_BUILDNUMBER" '^\([0-9]\+\.[0-9]\+\.[0-9]\+\)$'` ] \
    && echo "##[error]BUILD_BUILDNUMBER=$BUILD_BUILDNUMBER is not in format M.m.p" >&2 \
    && exit 0

#[ ! -d "$RELEASE_PRIMARYARTIFACTSOURCEALIAS" ] \
#    && echo "##[error]primary artifact $RELEASE_PRIMARYARTIFACTSOURCEALIAS is not present -> no deployment" >&2 \
#    && exit 0

CONTAINER_REGISTRY=$1
[ -z "$CONTAINER_REGISTRY" ] && echo "##[error]need container registry as first argument to script" && exit 7
echo container registry=$CONTAINER_REGISTRY
shift

NS=$1    ### kubernetes namespace
[ -z "$NS" ] && echo "##[error]need namespace as second argument to script" && exit 9
echo namespace=$NS
shift

DPL=$1   ### deployment/app name
[ -z "$DPL" ] && echo "##[error]need deployment name as third argument to script" && exit 8
echo deployment=$DPL
shift

echo will deploy container=image :
declare -A IMGS
while [ "$*" ];do
    [ $# -eq 1 ] && echo "##[error]need couples of arguments : container_name image_name" >&2 && exit 6
    IMGS[$1]="$2"
    echo "  $1=$2"
    shift 2
done

[ -z "$_CONF_KUBECTLOUTPUT" ] && echo "##[error] need kubeconfig in \$_CONF_KUBECTLOUTPUT from previous step" >&2 && exit 2

echo "$_CONF_KUBECTLOUTPUT" > ~/.kube/config    ### $_CONF_KUBECTLOUTPUT variable from previous pipeline step "kubectl config view --raw"
IMAGE=`kubectl get deploy -n $NS $DPL -o jsonpath={.spec.template.spec.containers[].image}`     #get image
echo -e "\nCurrent deployment details :\nIMAGE=$IMAGE"

VERSION_DEPLOYED=${IMAGE##*:} && echo Version=$VERSION_DEPLOYED     #get version deployed

VERSION_DEPLOYED_SIGNIFICANT=${VERSION_DEPLOYED%.*}   #get version deployed significant
echo significant version=$VERSION_DEPLOYED_SIGNIFICANT

VERSION_NEW_SIGNIFICANT=${BUILD_BUILDNUMBER%.*}     #get version new significant
echo -e "\nNew deployment details :\nVersion=$BUILD_BUILDNUMBER\nsignificant version=$VERSION_NEW_SIGNIFICANT"

# compare significant versions and decide on strategy
STRAT=Recreate
[ $VERSION_DEPLOYED_SIGNIFICANT == $VERSION_NEW_SIGNIFICANT ] && STRAT=RollingUpdate
echo -e "\nDeployment strategy will be : $STRAT\n"

# patch deployment with determined strategy
kubectl patch -n $NS deploy $DPL --type merge -p "spec: {strategy: {type: $STRAT, rollingUpdate: null}}"

# set the new images
LIST=""
for CONTAINER in ${!IMGS[@]};do
    echo "##[debug] set image ${IMGS[$CONTAINER]}:$BUILD_BUILDNUMBER"
    LIST="$LIST $CONTAINER=$CONTAINER_REGISTRY/${IMGS[$CONTAINER]}:$BUILD_BUILDNUMBER"
done
kubectl set -n $NS image deployment/$DPL $LIST
kubectl rollout status --timeout=180s deployment -n $NS $DPL
kubectl wait --for=condition=ready --timeout=180s pod -n $NS -l app=$DPL

echo work is done, now waiting $WAIT sec for images to update and then check results ...
sleep $WAIT

#check if :
# new version == what we expect
# state==running
# restartCount==0
STATUS=`kubectl get po -n $NS -l app=$DPL -o jsonpath={.items[].status.containerStatuses}`

for i in `seq 0 $(( ${#IMGS[@]} - 1 ))`;do
    RESTART_COUNT=`echo "$STATUS"|jq -er .[$i].restartCount`
    IMAGE=`echo "$STATUS"|jq -r .[$i].image`
    VERSION_RUNNING=${IMAGE##*:}
    if [ $VERSION_RUNNING != $BUILD_BUILDNUMBER ];then
        echo "##[error]version has not updated (yet?)"
        exit 3
    fi
    if echo "$STATUS"|jq -er .[$i].state.running>/dev/null ; then
        if [ $RESTART_COUNT != 0 ];then
            echo "##[error]container for $IMAGE is restarting, restartCount=$RESTART_COUNT"
            exit 2
        fi
        echo "##[section]$IMAGE seems fine"
    else
        echo "##[error]bad state for container $IMAGE"
        echo "$STATUS"|jq -er .[$i].state
        exit 1
    fi
done
