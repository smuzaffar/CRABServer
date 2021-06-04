#!/bin/bash


{
  #set -x

  # load the logging functions
  if [ -f /lib/lsb/init-functions ]; then
    . /lib/lsb/init-functions
  elif [ -f /etc/init.d/functions ]; then
    . /etc/init.d/functions
    LSB_DISTRO="false"
  fi

  LSB_DISTRO="true"
  TMP_BUFFER=$(mktemp -dt )/client_validation.log
  STORAGE_SITE="T2_CH_CERN"
  PROXY=$(voms-proxy-info -path 2>&1)
  OUTPUTDIR="$PWD/logdir"
  WAIT_IF_NOT_RUNL=0
  RETRIES=3
  TASK_TO_SUBMIT="taskToSubmit.py"


  function logMsg() {
    local kind=$1
    local msg=$2
    case $kind in
    success)
      if [ "$LSB_DISTRO" == "true" ]; then
        log_success_msg "$msg"
      else
        printf "$msg %-80s"
        echo_success
      fi
      ;;
    warning)
      if [ "$LSB_DISTRO" == "true" ]; then
        log_warning_msg "$msg"
      else
        printf "$msg %-80s"
        echo_warning
      fi
      ;;
    failure)
      if [ "$LSB_DISTRO" == "true" ]; then
        log_failure_msg "$msg"
      else
        printf "$msg %-80s"
        echo_failure
      fi
      ;;
    esac
  }


  function checkThisCommand() {
    local cmd="$1"
    local parms="$2"
    echo -ne "TEST_COMMAND: crab $cmd $parms \n"
    crab $cmd $parms 2>&1 > $TMP_BUFFER
    if [ $? != 0 ]; then
      error=`cat $TMP_BUFFER`
      if [[ $error == *"Cannot retrieve the status_cache file"* ]]; then
        echo "TEST_RESULT: `logMsg warning`"
      else
        echo "TEST_RESULT: `logMsg failure`"
      fi
    else
      echo "TEST_RESULT: `logMsg success`"
    fi
    echo "TEST_MESSAGE:"
    cat $TMP_BUFFER
    echo -ne "\n\n\n"
  }



  # check for a valid proxy
  function checkProxy(){
    noProxy=`echo "$PROXY" | grep 'Proxy not found'`
    if [ "$noProxy" != "" ];then
      echo -ne "Fatal Proxy error: No proxy found..Please create one to proceed with the validation\n"
      exit
    fi

    # check also if the proxy is still valid
    isValid=`voms-proxy-info -timeleft`
    if [ $isValid == 0 ];then
      echo -ne "Fatal Proxy error: Proxy is expired..Please create a new one\n"
      exit
    fi
  }


  TMP_PARM1=("")
  function checkCmdParam() {
    cmdArgs=($(crab "$1" -h | sed -n '/--help/,$p' | grep '^  -' | awk '{print $1}' | xargs | sed 's/-h,//g'))
    TMP_PARM1="${cmdArgs[@]}"
  }

  USETHISPARMS=()
  INITPARMS=()
  function feedParms() {
    local parms=($INITPARMS)
    local values=($1)
    parmsToUse=""
    local idx=0
    for p in "${parms[@]}"; do
      vtp=''
      if [[ "$p" == *'|'* ]]; then
        vtp=$(echo $p | cut -d'|' -f${values[$idx]} | sed "s|'||g")
      else
        vtp=$(echo "$p=${values[$idx]} ")
      fi
      idx=$((idx + 1))
      parmsToUse="$parmsToUse $vtp"
    done
    #echo $parmsToUse
    USETHISPARMS+=("$parmsToUse")
  }

  checkProxy

  ##################################################
  # START CRABCLIENT VALIDATION
  ##################################################

  echo $REST_Instance
  echo $PROXY

  ### 1. test crab createmyproxy -h, --proxy=PROXY, --days=100
  USETHISPARMS=()
  INITPARMS="--proxy --days"
  feedParms "$PROXY 100"
  for parm in "${USETHISPARMS[@]}"; do
      checkThisCommand createmyproxy "$parm"
  done


  ### 2. test crab checkusername -h, --proxy=PROXY
  USETHISPARMS=()
  INITPARMS="--proxy"
  feedParms "$PROXY"
  checkThisCommand checkusername "${USETHISPARMS[@]}"


  ### 3. crab checkwrite --site=SITENAME --proxy=PROXY --checksum=CHECKSUM
  USETHISPARMS=()
  INITPARMS="--site --proxy"
  feedParms "$STORAGE_SITE $PROXY"
  INITPARMS="--site --proxy --checksum"
  feedParms "$STORAGE_SITE $PROXY yes"
  for parm in "${USETHISPARMS[@]}"; do
      checkThisCommand checkwrite "$parm"
  done


  ### 4. test crab tasks --days=3 --status=PARAMS --proxy=PROXY
  USETHISPARMS=()
  INITPARMS="--days --status --proxy --instance"
  PARAMS=(NEW HOLDING QUEUED SUBMITTED SUBMITFAILED KILLED KILLFAILED RESUBMITFAILED FAILED)
  for st in "${PARAMS[@]}"; do
    feedParms "1 $st $PROXY $REST_Instance"
  done
  for parm in "${USETHISPARMS[@]}"; do
    checkThisCommand tasks "$parm"
  done


  ##################################################
  # START CHECKING SUBMITTED TASK'S STATUS
  ##################################################

  TASKTOTRACK=`cat /artifacts/submitted_tasks`
  PROJDIR=`crab remake --task=$TASKTOTRACK --instance=$REST_Instance | grep 'Finished remaking project directory' | awk '{print $6}'`
  echo $PROJDIR


  ### 5. test crab preparelocal --proxy=PROXY --dir=PROJDIR
  USETHISPARMS=()
  INITPARMS="--proxy --dir"
  feedParms "$PROXY $PROJDIR"
  for param in "${USETHISPARMS[@]}"; do
    checkThisCommand preparelocal "$param"
  done


  ### 6. test crab status --proxy=PROXY --dir=PROJDIR --long --verboseErrors  --sort=SORTING
  USETHISPARMS=()
  INITPARMS="'--long|--verboseErrors|' --proxy --dir"
  for opt in 1 2 3 4; do
    feedParms "$opt $PROXY $PROJDIR"
  done
  INITPARMS="--sort  --proxy --dir"
  SORTING=('state' 'site' 'runtime' 'memory' 'cpu' 'retries' 'waste' 'exitcode')
  for st in "${SORTING[@]}"; do
    feedParms "$st $PROXY $PROJDIR"
  done
  for param in "${USETHISPARMS[@]}"; do
    checkThisCommand status "$param"

  done


  ### 7. test crab report --proxy=PROXY --dir=PROJDIR --outputdid=OUTPUTDIR
  USETHISPARMS=()
  INITPARMS="--outputdir --proxy --dir"
  feedParms "$OUTPUTDIR $PROXY $PROJDIR"
  for param in "${USETHISPARMS[@]}"; do
    checkThisCommand report "$param"
  done


  ### 8. test crab getlog --quantity=QUANTITY  --short --outputpath=URL --dump --xrootd
  # --jobids=JOBIDS --checksum=CHECKSUM --proxy=PROXY --dir=PROJDIR
  USETHISPARMS=()
  INITPARMS="--quantity '--short|' --outputpath '|--dump|--xrootd' --jobids --checksum  --proxy --dir"
  feedParms "2 1 $OUTPUTDIR 2 2,3 yes $PROXY $PROJDIR"
  feedParms "2 2 $OUTPUTDIR 2 2,3 no  $PROXY $PROJDIR"
  for param in "${USETHISPARMS[@]}";do
    checkThisCommand getlog "$param"
  done


  ### 9. test crab getoutput --quantity=QUANTITY --parallel=NPARALLEL --wait=WAITTIME --outputpath=URL
  # --dump --xrootd --jobids=JOBIDS --checksum=CHECKSUM --proxy=PROXY --dir=PROJDIR
  USETHISPARMS=()
  # use --jobids instead of --quantity
  INITPARMS="--parallel --wait --outputpath '|--dump|--xrootd' --jobids --checksum --dir"
  feedParms "10 4 $OUTPUTDIR 1 2,3 yes  $PROJDIR"
  feedParms "10 4 $OUTPUTDIR 1 2,3 no  $PROJDIR"
  feedParms "10 4 $OUTPUTDIR 2 2,3 yes  $PROJDIR"
  feedParms "10 4 $OUTPUTDIR 2 2,3 no  $PROJDIR"
  feedParms "10 4 $OUTPUTDIR 3 2,3 yes  $PROJDIR"
  feedParms "10 4 $OUTPUTDIR 3 2,3 no  $PROJDIR"
  # use --quantity instead of jobis
  INITPARMS="--quantity --parallel --wait --outputpath '|--dump|--xrootd' --checksum --dir"
  feedParms "1 10 4 $OUTPUTDIR 1 yes $PROJDIR"
  feedParms "3 10 4 $OUTPUTDIR 1 no  $PROJDIR"
  for param in "${USETHISPARMS[@]}";do
    checkThisCommand getoutput "$param"
  done

  #set +x
} 2>&1 | tee /artifacts/client-validation-$(date "+%s").log

