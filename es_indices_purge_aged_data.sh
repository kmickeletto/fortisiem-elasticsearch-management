#!/bin/bash

index_prefix=fortisiem-event-																	# Should be fortisiem-event- in almost all cases
shrunk_suffix=-shrunk																			# Suffix for shrunk indices
days_to_keep=400																				# Will ignore indices newer than 400 days
dry_run=true																					# Runs in test mode, nothing is deleted
safety_braking=true																				# Slows down deletion of indices to every 15 seconds
minimum_logging_level=DEBUG                                                                     # CRIT,ERROR,INFO,DEBUG,VERBOSE

if [ "$#" -gt 1 ]; then
    echo "Illegal number of parameters"
    echo "Usage: $(basename $0) [OPTIONAL:<days to keep>"
    exit 1
fi

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
    echo -e "$current_time  $msg_level  ${2//_/.}  $3" | tee -a $log_location/es_shrinktowarm.log
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

fetch_indices() {
  indices_list=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/_cat/indices/${index_prefix}*?h=i")
  if [[ $? -gt 0 ]]; then
    logit 1 "${FUNCNAME[0]}" "Unable to fetch the list of indices from ${es_coord_host}/_cat/indices/${index_prefix}*"
    return 1
  fi
  indices_list=$(grep -E "^${index_prefix}[0-9]{4}\.[0-1][0-9]\.[0-3][0-9](${shrunk_suffix}|)$" <<< "$indices_list" | sort  -t "." -k2)
  total_indices_count=$(grep -Ev '^$' <<< "$indices_list" | wc -l)
  logit 5 "${FUNCNAME[0]}" "Found $total_indices_count indices with pattern ${index_prefix} and date format yyyy.MM.dd"
  return 0
}

purge_index() {
  local index_name

  index_name=${1:-NULL}
  if ${safety_braking:-true}; then
    logit 4 "${FUNCNAME[0]}_braking" "Purging index $index_name in 15 seconds"
    sleep 15
  fi
  curl -u "$es_coord_auth" -s -XDELETE -o /dev/null "${es_coord_host}/${index:-NULL}"
  logit 4 "${FUNCNAME[0]}" "$index_name has been purged"
}

dry_run_purge_index() {
  local index_name

  index_name=${1:-NULL}
  if ${safety_braking:-true}; then
    logit 4 "${FUNCNAME[0]}_braking" "Purging index $index_name in 15 seconds, not really"
    sleep 15
  fi
  logit 4 "${FUNCNAME[0]}" "$index_name would have been purged"
}

get_minimum_date() {
  start_date=$(date +%Y%m%d -d@$(( $(date -d"$(date +%F)" +%s) - (${days_to_keep:-10000} * 86400) )))
  start_date_display=$(date +%F -d@$(( $(date -d"$(date +%F)" +%s) - (${days_to_keep:-10000} * 86400) )))
  logit 4 "${FUNCNAME[0]}" "Only processing indices with dates $start_date_display or older"
}

logit 4 script_identity "FortiSIEM es_indices_purge_aged_data version 1.0.0 ® Fortinet 2019 All Rights Reserved"

if ! fetch_fs_es_config; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

if ! locate_valid_coord; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

unset es_coord_hosts
unset es_coord_port
unset es_coord_user
unset es_coord_pw

get_minimum_date
if ! fetch_indices; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

while read index && [[ -n $index ]]; do
  index_date=$(perl -pe "s/${index_prefix}.*([0-9]{4})\.([0-9]{2})\.([0-9]{2})/\1\2\3/g" <<<"$index")
  if [[ $start_date -ge $index_date ]]; then
    if ! ${dry_run:-true}; then
      purge_index "$index"
      (( purged_indices_counter++ ))
    else
      dry_run_purge_index "$index"
      (( purged_indices_counter++ ))
    fi
  else
    logit 5 main_body "Skipping ${index}${index_suffix} because it is not beyond $days_to_keep days old"
    (( skipped_indices_counter++ ))
  fi
done <<< "$indices_list"

if ${dry_run:-true}; then
  logit 4 dry_purge_results "Would have purged ${purged_indices_counter:-0} indices"
else
  logit 4 purge_results "Purged ${purged_indices_counter:-0} indices"
fi
logit 4 purge_results_skipped "Skipped ${skipped_indices_counter:-0} indices because of age exclusion"
