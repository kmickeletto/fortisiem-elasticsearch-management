#!/bin/bash

minimum_logging_level=DEBUG                     # CRIT,ERROR,INFO,DEBUG,VERBOSE

logit() {
  current_time=$(date '+%F %T')
  case $1 in
    6)
      msg_level=PHL_VERBOSE
      ;;
    5)
      msg_level=PHL_DEBUG
      ;;
    4)
      msg_level=PHL_INFO
      ;;
    3)
      msg_level=PHL_WARN
      ;;
    2)
      msg_level=PHL_ERROR
      ;;
    1)
      msg_level=PHL_CRIT
      ;;
  esac

  if [[ $1 -le $minimum_logging_level ]]; then
    echo -e "$current_time  $msg_level  ${2//_/.}  $3" | tee -a $log_location/es_merge_segs.log
  fi
}

kill_myself() {
  local exit_status
  local script_name

  script_name=$(basename -- $0)
  exit_status=$1
  logit 4 "${FUNCNAME[0]}" "$script_name terminated with a status of $exit_status"
  exit $exit_status
}

case $minimum_logging_level in
  VERBOSE)
    minimum_logging_level=6
    set -xv
    ;;
  DEBUG)
    minimum_logging_level=5
    ;;
  INFO)
    minimum_logging_level=4
    ;;
  WARN)
    minimum_logging_level=3
    ;;
  ERROR)
    minimum_logging_level=2
    ;;
  CRIT)
    minimum_logging_level=1
    ;;
  *)
    message=$minimum_logging_level
    minimum_logging_level=1
    logit 1 "${FUNCNAME[0]}" "Invalid configuration item detected, minimum_logging_level=$message"
    kill_myself 1
    ;;
esac

kill_myself() {
  local exit_status
  local script_name

  script_name=$(basename -- $0)
  exit_status=$1
  logit 4 "${FUNCNAME[0]}" "$script_name terminated with a status of $exit_status"
  exit $exit_status
}

if [[ "$#" -gt 1 ]]; then
    echo "Illegal number of parameters"
    echo "Usage: $(basename $0) <-h for human formated numbers>"
    exit 1
fi

check_jq() {
  local jq_path
  local jq_version

  if ! rpm -qa | grep --quiet jq; then
    logit 1 "${FUNCNAME[0]}" "Unable to locate jq.  Please install and retry"
    return 1
  else
    jq_path=$(which jq)
    jq_version=$(jq -V | perl -pe 's/jq-(.*)$/\1/')
    logit 5 "${FUNCNAME[0]}" "jq version $jq_version has been located at $jq_path"
    return 0
  fi
}

fetch_fs_es_config() {
  local phoenix_es_config
  local es_enabled
  local es_coord_user
  local es_coord_pw
  
  if [[ ! -f /opt/phoenix/config/phoenix_config.txt ]]; then
    logit 1 "${FUNCNAME[0]}" "Unable to locate /opt/phoenix/config/phoenix_config.txt"
    return 1
  fi

  phoenix_es_config=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt)
  es_coord_hosts=$(grep cluster_ip= <<<"$phoenix_es_config" | cut -f2 -d'=')
  es_coord_user=$(grep username= <<<"$phoenix_es_config" | cut -f2 -d'=')
  es_coord_pw=$(grep password= <<<"$phoenix_es_config" | cut -f2 -d'=')
  es_coord_port=$(grep http_port= <<<"$phoenix_es_config" | cut -f2 -d'=')
  es_enabled=$(grep enable= <<<"$phoenix_es_config" | cut -f2 -d'=')
  es_coord_auth="${es_coord_user}:${es_coord_pw}"
  box_type="$destination_box_type"
  
  if [[ $es_enabled != true ]]; then
    logit 1 "${FUNCNAME[0]}" "Elasticsearch is not enabled for this FortiSIEM instance"
    return 1
  fi
  return 0
}

locate_valid_coord() {
  local OIFS
  local IFS

  OIFS=$IFS
  IFS=","
  es_coord_hosts=($es_coord_hosts)
  logit 5 "${FUNCNAME[0]}" "Testing the following coordinator nodes ${es_coord_hosts[*]}"
  IFS=$OIFS
  for (( i=0; i<${#es_coord_hosts[@]}; i++ )); do
    es_coord_prot="https://"
    logit 5 "${FUNCNAME[0]}" "Testing ${es_coord_prot}${es_coord_hosts[$i]}:$es_coord_port"
    curl -u "$es_coord_auth" -q -s --connect-timeout 2 -XGET "${es_coord_prot}${coord_host_array[$i]}:$es_coord_port" -o /dev/null
    if [[ $? -eq 0 ]]; then
      es_coord_host="${coord_host_array[$i]}:${es_coord_port}"
          logit 5 "${FUNCNAME[0]}" "Successfully connected to ${es_coord_host}"
      break
    else
      logit 5 "${FUNCNAME[0]}" "Unable to connect to ${es_coord_prot}${es_coord_hosts[$i]}:$es_coord_port"
    fi
    es_coord_prot="http://"
    logit 5 "${FUNCNAME[0]}" "Testing ${es_coord_prot}${es_coord_hosts[$i]}:$es_coord_port"
    curl -u "$es_coord_auth" -q -s --connect-timeout 2 -XGET "${es_coord_prot}${es_coord_hosts[$i]}:$es_coord_port" -o /dev/null
    if [[ $? -gt 0 ]]; then
      logit 2 "${FUNCNAME[0]}" "Unable to connect to ${es_coord_hosts[$i]} on port $es_coord_port"
    else
      es_coord_host="${es_coord_hosts[$i]}:${es_coord_port}"
      break
    fi
    logit 1 "${FUNCNAME[0]}" "Unable to connect to any coordinator host!"
    return 1
  done
  logit 4 "${FUNCNAME[0]}" "Successfully connected to ${es_coord_host}"
  return 0
}

if [[ $1 != -h ]]; then
  non_human='bytes=m&'
fi

init_colors() {
DRED=$'\033[0;31m'
  LRED=$'\033[1;31m'
  DGREEN=$'\033[0;32m'
  LGREEN=$'\033[1;32m'
  DYELLOW=$'\033[0;33m'
  LYELLOW=$'\033[1;33m'
  DBLUE=$'\033[0;34m'
  LBLUE=$'\033[1;34m'
  MAGENTA=$'\033[1;35m'
  CYAN=$'\033[1;36m'
  NORMAL=$'\033[0;0m'
}

colorize() {
  sed -e "s/green/${DGREEN}green${NORMAL}/" -e "s/yellow/${DYELLOW}yellow${NORMAL}/" -e "s/red/${DRED}red${NORMAL}/"
}
  
init_colors

if ! check_jq; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

if ! fetch_fs_es_config; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

if ! locate_valid_coord; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

#curl -s http://coordinator-001.ord1.prod.isiem.rackspace.net:9200/_nodes | jq '.nodes[] | [.name, .roles[]] | join(" ")'

node_shards=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/_cat/allocation?h=ip,shards" | sort)
node_attrs=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/_cat/nodeattrs?h=ip,value" | grep -E 'hot|warm|cold' | sort)
node_stats=$(curl -u "$es_coord_auth" -q -s -XGET "${es_coord_host}/_cat/nodes?${non_human}h=ip,version,uptime,diskTotal,diskUsed,diskAvail,diskUsedPercent,heapMax,heapPercent,ramPercent,ramMax,cpu,load_1m,load_5m,nodeRole,segmentsCount,segmentsMemory" | sort)
node_stats_attrs=$(join -1 1 -2 1 -a1 -e- <(echo "$node_stats") -o 0 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12 1.13 1.14 1.15 1.16 1.17 2.2 <(echo "$node_attrs"))
node_stats_attrs_shards=$(join -1 1 -2 1 -a1 -e0 <(echo "$node_stats_attrs") -o 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12 1.13 1.14 1.15 1.16 1.17 2.2 1.18 <(echo "$node_shards"))
(echo "ip version uptime diskTotal diskUsed diskAvail diskPct heapMax heapPct ramPct ramMax cpu load_1m load_5m role segments segmentsMem shards boxType"; echo "$node_stats_attrs_shards") | column -t | colorize
echo
