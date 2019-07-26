#!/bin/bash

index_pattern=fortisiem-event-                  # Should be fortisiem-event- in almost all cases
exclude_pattern=                                # Regex compatible matching
skip_days=2                                     # Will ignore indices created in the last 2 days
max_indices_per_request=5                       # How many indices to send to merge API at once
minimum_logging_level=DEBUG                     # CRIT,ERROR,INFO,DEBUG,VERBOSE
log_location=/opt/phoenix/log

kill_myself() {
  local exit_status
  local script_name

  script_name=$(basename -- $0)
  exit_status=$1
  logit 4 "${FUNCNAME[0]}" "$script_name terminated with a status of $exit_status"
  exit $exit_status
}

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
  local coord_host_array

  OIFS=$IFS
  IFS=","
  coord_host_array=($es_coord_hosts)
  logit 5 "${FUNCNAME[0]}" "Testing the following coordinator nodes ${coord_host_array[*]}"
  IFS=$OIFS
  for (( i=0; i<${#coord_host_array[@]}; i++ )); do
    es_coord_prot="https://"
    logit 5 "${FUNCNAME[0]}" "Testing ${es_coord_prot}${coord_host_array[$i]}:$es_coord_port"
    curl -q -s -u "$es_coord_user:$es_coord_pw" --connect-timeout 2 -XGET "${es_coord_prot}${coord_host_array[$i]}:$es_coord_port" -o /dev/null
    if [[ $? -eq 0 ]]; then
      logit 5 "${FUNCNAME[0]}" "Successfully connected to ${es_coord_prot}${coord_host_array[$i]}:$es_coord_port"
      es_coord_host=${coord_host_array[$i]}
      break
    else
      logit 5 "${FUNCNAME[0]}" "Unable to connect to ${es_coord_prot}${coord_host_array[$i]}:$es_coord_port"
    fi
    es_coord_prot="http://"
    logit 5 "${FUNCNAME[0]}" "Testing ${es_coord_prot}${coord_host_array[$i]}:$es_coord_port"
    curl -q -s -u "$es_coord_user:$es_coord_pw" --connect-timeout 2 -XGET "${es_coord_prot}${coord_host_array[$i]}:$es_coord_port" -o /dev/null
    if [[ $? -gt 0 ]]; then
      logit 2 "${FUNCNAME[0]}" "Unable to connect to ${coord_host_array[$i]} on port $es_coord_port"
    else
      es_coord_host=${coord_host_array[$i]}
      break
    fi
    logit 1 "${FUNCNAME[0]}" "Unable to connect to any coordinator host!"
    return 1
  done
  logit 4 "${FUNCNAME[0]}" "Successfully connected to ${es_coord_prot}${es_coord_host}:${es_coord_port}"
  return 0
}

get_minimum_date() {
  start_date=$(date +%Y%m%d -d@$(( $(date -d"$(date +%F)" +%s) - (skip_days * 86400) )))
  logit 4 "${FUNCNAME[0]}" "Only processing indices before $(date +%Y-%m-%d -d@$(( $(date -d"$(date +%F)" +%s) - (skip_days * 86400) )))"
}

logit 4 script_identity "FortiSIEM es_seg_merge version 1.0.0 ® Fortinet 2019 All Rights Reserved"

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

get_minimum_date

fetch_indices() {
  found_indices=$(curl -s -XGET "${es_coord_prot}${es_coord_host}:${es_coord_port}/_cat/indices/$index_pattern*?bytes=k&h=index,pri,rep,sc" | sort -k2 -t.)
  if [[ $(wc -l <<<"$found_indices") -le 0 ]] || [[ -z $found_indices ]]; then
    logit 1 "${FUNCNAME[0]}" "No indices matched the name $index_pattern"
    return 1
  fi
}

if ! fetch_indices; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

index_count=0
while read index && [[ -n $index ]]; do
  index_name=$(awk '{print $1}' <<< $index)
  index_date=$(awk '{print $1}' <<<"$index" | perl -pe "s/${index_prefix}.*([0-9]{4})\.([0-9]{2})\.([0-9]{2})/\1\2\3/g")
  shards=$(awk '{print $2}' <<< $index)
  replicas=$(awk '{print $3}' <<< $index)
  actual_segments=$(awk '{print $4}' <<< $index)
  desired_segments=$(( ($replicas + 1)*$shards ))
  if [[ $desired_segments -ne $actual_segments ]]; then
    if [[ -n $exclude_pattern ]] && [[ $index_name =~ $exclude_pattern ]]; then
      logit 4 main_body "Skipping index $index_name because it matches exclude_pattern $exclude_pattern"
      continue
    fi
    if [[ $index_date -ge $start_date ]]; then
      logit 5 main_body "Skipping ${index_name} because it is not beyond $skip_days days old"
      continue
    fi
    indexes_to_merge[index_count]=$index_name
    (( index_count++ ))
  fi
done <<< "$found_indices"

begin_seq=0
if [[ ${#indexes_to_merge[@]} -gt 0 ]]; then
  logit 4 begin_merge "Found ${#indexes_to_merge[@]} indices that require merging"
  while [[ ${#indexes_to_merge[@]} -gt $begin_seq ]]; do
    for i in $(seq $begin_seq $(( begin_seq + max_indices_per_request - 1 ))); do
      if [[ -n ${indexes_to_merge[$i]} ]]; then
        csvindexes="$csvindexes,${indexes_to_merge[$i]}"
      fi
    done
    begin_seq=$(( begin_seq + max_indices_per_request))
    logit 4 merging_indices "Merging ${csvindexes##,}"
    timeout 1 curl -s -XPOST "${es_coord_prot}${es_coord_host}:${es_coord_port}/${csvindexes##,}/_forcemerge?only_expunge_deletes=false&max_num_segments=1&flush=true"
    csvindexes=
  done
else
  logit 4 indices_none_found "No indexes need merging at this time"
fi

logit 4 indices_shrinking_complete  "Processed ${#indexes_to_merge[@]} indices"
kill_myself 0
