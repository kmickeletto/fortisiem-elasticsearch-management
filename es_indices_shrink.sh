#!/bin/bash

max_days_in_hot=30                              # Will ignore indices newer than 30 days
index_prefix="fortisiem-event-"                 # Should be fortisiem-event- in almost all cases
index_suffix="-shrunk"                          # Determines what new indices should be appended with
shrink_node_name=                               # Leave blank to use opportunistic mode
purge_after_successful_shrink=true              # Leave false for testing
source_box_type=hot                             # box_type designator for source indices, usually hot
destination_box_type=warm                       # box_type designator for relocating shunken indices, usually warm
warm_replia_count=1                             # How many replicas to create on newly shrunken indices
dest_adaptive_shard_count=true                  # If true, uses least common multiple for shards, otherwise 1 will always be used
delay_seconds_between_indices=60                # How many seconds to wait before processing next index
wait_minutes_force_alloc_success=30             # How many minutes to wait for a retry allocation to succeed
minimum_logging_level=DEBUG                     # CRIT,ERROR,INFO,DEBUG,VERBOSE
log_location=/opt/phoenix/log

rotate_logs() {
echo "$log_location/es_shrinktowarm.log {
  dateext
  create 644 admin admin
  rotate 12
  monthly
  dateformat -%Y-%m
  compress
  missingok
  notifempty
}" > /etc/logrotate_es_shrinktowarm.conf
  logrotate /etc/logrotate_es_shrinktowarm.conf
}
rotate_logs

kill_myself() {
  local exit_status
  local script_name

  script_name=$(basename -- $0)
  exit_status=$1
  logit 4 "${FUNCNAME[0]}" "$script_name terminated with a status of $exit_status"
  exit $exit_status
}

logit() {
  test -f $log_location/es_shrinktowarm.log || (touch $log_location/es_shrinktowarm.log && chown admin:admin $log_location/es_shrinktowarm.log)
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
          logit 5 "${FUNCNAME[0]}" "Successfully connected to ${es_coord_prot}${es_coord_host}"
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
  logit 4 "${FUNCNAME[0]}" "Successfully connected to ${es_coord_prot}${es_coord_host}"
  if check_cluster_version; then
    return 0
  else
    exit 1
  fi
}

check_cluster_version() {
  local es_cluster_version

  es_cluster_version=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}" | jq -r '.version.number')
  if [[ $es_cluster_version =~ ^(6\.[48]\.)|(5\.6\.) ]]; then
    logit 4 "${FUNCNAME[0]}" "Cluster version is currently running version ${es_cluster_version}"
    return 0
  else
    logit 1 "${FUNCNAME[0]}" "Cluster is currently running an unsupported version of Elasticsearch, unable to continue"
    logit 1 "${FUNCNAME[0]}" "Supported variants are currently 5.6.x, 6.4.x, and 6.8.x"
    return 1
  fi
}

check_jq() {
  local jq_path
  local jq_version

  if which jq >/dev/null 2>&1; then
    jq_path=$(which jq)
    jq_version=$(jq -V | perl -pe 's/jq-(.*)$/\1/')
    logit 5 "${FUNCNAME[0]}" "jq version $jq_version has been located at $jq_path"
    return 0
  fi
  if rpm -ql jq | grep --quiet -E '\/jq$'; then
    jq_path=$(rpm -ql jq | grep -E '\/jq$')
    if $jq_path --version >/dev/null 2>&1; then
      jq_version=$(jq -V | perl -pe 's/jq-(.*)$/\1/')
      logit 5 "${FUNCNAME[0]}" "jq version $jq_version has been located at $jq_path"
     return 0
    else
      logit 1 "${FUNCNAME[0]}" "Unable to locate jq.  Please install and retry"
      return 1
    fi
  fi
}


element_exists() {
  local needle
  local haystack

  needle="$1"
  shift
  haystack=("$@")
  for i in "${haystack[@]}"; do
    if [[ $i == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

get_shard_lcm() {
  local index_name
  local index_shard_count

  index_name=$1
  index_shard_count=$2
  shard_lcm=$(factor <<< "$index_shard_count" | cut -f2 -d: | cut -f2 -d' ')
  if [[ -z $shard_lcm ]] || [[ $shard_lcm -eq $index_shard_count ]]; then
    shard_lcm=1
  fi
  logit 5 "${FUNCNAME[0]}" "$index_name least common multiplier is $shard_lcm"
}

index_health_status() {
  local index_status

  index_status=$(curl -u "$es_coord_auth" -s -XGET  -H 'Content-Type: application/json' "${es_coord_host}/_cluster/health/$1" | jq -r '.status')
echo "$index_status"
}

relocate_shards() {
  local index_name
  local shrink_node_name
  local valid_es_nodes
  local response
  local relocating_shards
  local shard_percent
  local average_shard_percent
  local primary_node
  local primary_node_shard_count
  local opp_shrink_node_name

  index_name=$1
  # determine optimal node used for shrink_node_name
  logit 4 "${FUNCNAME[0]}" "$index_name has been selected for shrinking"
  if [[ -z $shrink_node_name ]]; then
    logit 5 "${FUNCNAME[0]}" "No dedicated shrink node specified, opportunistically finding one"
    # Fetch current node for all shards and return the one with the highest number of shards
    primary_node=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/${index_name}/_shard_stores?status=green" | jq '.indices[].shards[].stores[]|to_entries[0].value' | jq -n 'def counter(stream): reduce stream as $s ({}; .[$s|tostring] += 1); [counter(inputs |.name) | to_entries[] | {name: (.key), count: .value}]' | jq -r 'max_by(.count) | [.name,.count|tostring] | join(" ")')
    primary_node_shard_count=$(cut -f2 -d' ' <<< "$primary_node")
    primary_node=$(cut -f1 -d' ' <<< "$primary_node")
    # If shard count returns 1, we would be better to find the least utilized host
    if [[ $primary_node_shard_count -ge 2 ]]; then
      logit 5 "${FUNCNAME[0]}" "$primary_node currently contains $primary_node_shard_count shards, selecting this node for shrinking"
      opp_shrink_node_name="$primary_node"
    else
      logit 5 "${FUNCNAME[0]}" "All nodes currently have the same amount of shards, checking nodes with the most free space and least load"
      opp_shrink_node_name=$(curl -u "$es_coord_auth" -s -XGET  "${es_coord_host}/_cat/nodes?h=name,load_5m,dup,heap.percent,cpu&s=dup,heap.percent,load_5m,cpu" | grep hot | head -n1 | awk '{print $1}')
      logit 5 "${FUNCNAME[0]}" "$opp_shrink_node_name has been selecting for shrinking"
    fi
  fi

  if [[ -z $opp_shrink_node_name ]]; then
    logit 5 "${FUNCNAME[0]}" "Validating shrink node $shrink_node_name"
    valid_es_nodes=($(curl -u "$es_coord_auth" -s -XGET  "${es_coord_host}/_cat/nodes?h=name"))
    if ! element_exists "$shrink_node_name" "${valid_es_nodes[@]}"; then
      logit 1 "${FUNCNAME[0]}" "Unable to locate specified shrink node $shrink_node_name"
      kill_myself 1
    else
      logit 5 "${FUNCNAME[0]}" "Specified shink node name $shrink_node_name has been validated"
    fi

    logit 4 "${FUNCNAME[0]}" "Using ${shrink_node_name} as the shrink node."
  else
    shrink_node_name="$opp_shrink_node_name"
  fi

  # prepare source index for shrinking by moving 1 copy of each shard to same host
  logit 4 "${FUNCNAME[0]}" "Relocating shards for $index_name --> ${shrink_node_name}"
  response=$(curl -u "$es_coord_auth" -s -XPUT -H 'Content-Type: application/json' "${es_coord_host}/${index_name}/_settings" -d'
  {
    "settings": {
      "index.routing.allocation.require._name": "'"${shrink_node_name}"'",
      "index.blocks.write": true
    }
  }'
  )

  if [[ $(echo "$response" | jq '.[]') != true ]]; then
    logit 2 "${FUNCNAME[0]}" "There was an error relocating shards to $shrink_node_name"
    kill_myself 1
  fi

  sleep 10
  relocating_shards=1
  while [[ $relocating_shards -gt 0 ]]; do
    sleep 10
    relocating_shards=$(curl -u "$es_coord_auth" -s -XGET  -H 'Content-Type: application/json' "${es_coord_host}/_cluster/health/${index_name}?wait_for_no_relocating_shards=true&timeout=50s" | jq '.relocating_shards')
    shard_percent=$(curl -u "$es_coord_auth" -s -XGET  -H 'Content-Type: application/json' "${es_coord_host}/_cat/recovery/${index_name}?format=json" | jq '.[]|select(.stage!="done")|.bytes_percent') 2>/dev/null
    average_shard_percent=$(awk 'match($0,/[0-9]+(\.[0-9+])?/){ sum += substr($0,RSTART,RLENGTH); n++ } END { if (n > 0) printf "%.0f\n",  sum / n; }' <<< "$shard_percent")
    test "$relocating_shards" -gt 0 && logit 5 "${FUNCNAME[0]}" "${index_name} shards relocating to $shrink_node_name, ${average_shard_percent}% complete"
  done
}

fetch_shard_count() {
  local index_name
  index_name=$1
  index_shard_count=$(curl -u "$es_coord_auth" -s -XGET -H 'Content-Type: application/json' "${es_coord_host}/${index_name}/_settings" | jq -r '.[].settings.index.number_of_shards')
  return 0
}

shrink_index() {
  local index_name
  local index_doc_count
  local index_shard_count
  local error_message
  local shrinking_index_shards
  local response

  index_name=$1
  index_doc_count=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/_cat/indices/${index_name}?format=json" | jq -r '.[]."docs.count"')
  index_shard_count=$(( ((${index_doc_count//\"/}/2147483519)+1)*$shard_lcm ))
  logit 5 "${FUNCNAME[0]}" "${index_name} currently has ${index_doc_count} documents, ${index_shard_count} shards will be configured for ${index_name}${index_suffix}"
  logit 4 "${FUNCNAME[0]}" "Starting shrink process, $index_name --> ${index_name}${index_suffix}"
  response=$(curl -u "$es_coord_auth" -s -XPOST -H 'Content-Type: application/json' "${es_coord_host}/${index_name}/_shrink/${index_name}${index_suffix}?copy_settings=true" -d'
  {
    "settings": {
      "index.routing.allocation.require._name": null,
      "index.blocks.write": null,
      "index.number_of_shards": '${index_shard_count}',
      "index.number_of_replicas": 0
    }
  }')

  if [[ $(echo "$response" | jq '.acknowledged') != true ]]; then
    error_message=$(echo "$response" | jq -r '[.error.type,.error.reason] | join(", ")')
    logit 2 "${FUNCNAME[0]}" "There was an error starting shrink process - $error_message"
    return
  fi

  sleep 10
  shrinking_index_shards=1
  while [[ $shrinking_index_shards -gt 0 ]]; do
    logit 4 "${FUNCNAME[0]}" "Waiting on $index_name --> ${index_name}${index_suffix}"
    sleep 10
    shrinking_index_shards=$(curl -u "$es_coord_auth" -s -XGET  -H 'Content-Type: application/json' "${es_coord_host}/_cluster/health/${index_name}${index_suffix}?wait_for_no_relocating_shards=true&timeout=50s" | jq '.relocating_shards')
  done
  logit 4 "${FUNCNAME[0]}" "Index ${index_name}${index_suffix} has been created"

  until [[ $(index_health_status "${index_name}${index_suffix}") = green ]]; do
    logit 3 "${FUNCNAME[0]}" "Waiting for ${index_name}${index_suffix} to return to green health status"
    sleep 60
  done
  logit 4 "${FUNCNAME[0]}" "${index_name}${index_suffix} is now green"
}

delete_index() {
  local index_name
  local response

  index_name="$1"
  if [[ -z $index_name ]]; then
    logit 1 "${FUNCNAME[0]}" "The delete_index function was called with a blank index name!  This is potenitally dangerous so all everything has been terminated."
    kill_myself 1
  fi
  logit 4 "${FUNCNAME[0]}" "Purging $index_name"
  response=$(curl -u "$es_coord_auth" -s -XDELETE "${es_coord_host}/${index_name}")
  if [[ $(jq .acknowledged <<< "$response") != true ]]; then
    logit 2 "${FUNCNAME[0]}" "There was an error attempting to delete $index_name"
    response=$(perl -pe "s/\\n/ /g" <<< "$response")
    logit 2 "${FUNCNAME[0]}" "Details - $response"
    return 1
  fi
  return 0
}

merge_index_segments() {
  local index_name
  local response

  index_name=$1
  logit 4 "${FUNCNAME[0]}" "Merging segments on new index ${index_name}"
  response=$(timeout 1 curl -u "$es_coord_auth" -s -XPOST "${es_coord_host}/${index_name}/_forcemerge?only_expunge_deletes=false&max_num_segments=1&flush=true")
  if [[ $(jq '.[].failed' <<< "$response") -ne 0 ]]; then
    logit 2 "${FUNCNAME[0]}" "There was an error merging segments - $response"
  fi

  sleep 60
  while [[ $(curl -u "$es_coord_auth" -sfq -XGET "${es_coord_host}/${index_name}/_stats" | jq .indices[].total.merges.current) -gt 0 ]]; do
    logit 5 "${FUNCNAME[0]}" "$index_name is still merging, waiting until it completes"
    sleep 60
  done
  logit 4 "${FUNCNAME[0]}" "$index_name has completed merging"
  return 0
}

change_routing_allocation() {
  local index_name
  local index_box_requirement
  local response
  local moving_shard_count
  local shards_remaining
  local average_shard_percent
  local wait_for_status_count
  local current_index_health

  index_name=$1
  logit 4 "${FUNCNAME[0]}" "Updating $index_name with $box_type routing requirement"
  index_box_requirement='{"index":{"routing":{"allocation":{"require":{"box_type":"'$box_type'"}}}}}'
  response=$(curl -u "$es_coord_auth" -s -XPUT -H 'Content-Type: application/json' "${es_coord_host}/${index_name}/_settings" -d"$index_box_requirement")
  if [[ $(echo "$response" | jq '.acknowledged') != true ]]; then
    logit 2 "${FUNCNAME[0]}" "There was an error moving the index to $box_type - $(echo "$response" | jq -r '.error.reason')"
    return
  fi

  # wait for status to update after changing box_type
  sleep 60

  # check index health status and monitor every 60 seconds
  wait_for_status_count=0
  while [[ ${current_index_health^^} != GREEN ]]; do
    current_index_health=$(index_health_status "${index_name}")
    (( wait_for_status_count++ ))
    case ${current_index_health^^} in
      RED)
        logit 2 "${FUNCNAME[0]}" "${index_name} is red which indicates a failure, it will be skipped for now"
        delete_index "${index_name}"
        return 1
        ;;
      YELLOW)
        moving_shard_count=$(curl -u "$es_coord_auth" -s "${es_coord_host}/_cat/recovery/${index_name}?format=json" | jq '.[]|select(.stage!="done")|select(.stage="peer")|.index' | wc -l)
        if [[ $moving_shard_count -gt 0 ]]; then
          shard_percent=$(curl -u "$es_coord_auth" -s -XGET  -H 'Content-Type: application/json' "${es_coord_host}/_cat/recovery/${index_name}?format=json" | jq '.[]|select(.stage!="done")|select(.stage="peer")|.bytes_percent')
          shards_remaining=$(wc -l <<< "shard_percent")
          average_shard_percent=$(awk 'match($0,/[0-9]+(\.[0-9+])?/){ sum += substr($0,RSTART,RLENGTH); n++ } END { if (n > 0) printf "%.0f\n", sum / n; }' <<< "$shard_percent")
          logit 5 "${FUNCNAME[0]}" "${index_name} is currently yellow with $shards_remaining remaining shards, ${average_shard_percent}% complete."
        else
          logit 2 "${FUNCNAME[0]}" "${index_name} appears to be stuck"
          if [[ $wait_for_status_count -gt 5 ]]; then
            logit 2 "${FUNCNAME[0]}" "Unable to determine why ${index_name} is not moving, skipping"
            delete_index "${index_name}"
            return 1
          fi
        fi
        sleep 60
        ;;
      GREEN)
        logit 5 "${FUNCNAME[0]}" "${index_name} is now $(index_health_status "${index_name}")"
        if [[ ${index_name} =~ ${index_suffix}$ ]]; then
          logit 4 "${FUNCNAME[0]}" "${index_name%$index_suffix} has successfully been shrunk to ${index_name}"
        fi
        return 0
        ;;
      *)
        ;;
    esac
  done
}

index_exists() {
  local index_name
  index_name="$1"
  if curl -u "$es_coord_auth" -sqfI -o /dev/null "${es_coord_host}/${index_name}"; then
    logit 5 "${FUNCNAME[0]}" "Located index named $index_name"
    return 0
  fi
  logit 5 "${FUNCNAME[0]}" "Unable to locate index name $index_name"
  return 1
}

update_index_replica_count() {
  local index_name
  local replica_count_payload
  local response

  index_name="$1"
  replica_count_payload='{"number_of_replicas": '${warm_replia_count}'}'
  response=$(curl -u "$es_coord_auth" -s -XPUT -H 'Content-Type: application/json' "${es_coord_host}/${index_name}/_settings" -d"${replica_count_payload}")
  if [[ $(echo "$response" | jq '.acknowledged') != true ]]; then
    logit 2 "${FUNCNAME[0]}" "There was an error updating the replica count for ${index_name}"
    logit 2 "${FUNCNAME[0]}" "$(echo "$response" | jq -r '.error.reason')"
    logit 2 "${FUNCNAME[0]}" "Deleting index ${index_name} and skipping"
    delete_index ${index_name}
    return 1
  else
    logit 4 "${FUNCNAME[0]}" "Updating replica count for ${index_name} to ${warm_replia_count}"
    return 0
  fi
}

create_index_alias() {
  local index_name
  local shrunk_index_name
  local index_alias
  local response

  index_name="$1"
  index_date="$(grep -Eo '[0-9]{4}\.[0-9]{2}\.[0-9]{2}' <<< $index_name)"
  index_cust=$(perl -pe 's/.*(-[0-9]{1,4})$|.*/\1/' <<< $index_name)
  shrunk_index_name="${index_prefix}${index_date}${index_cust}${index_suffix}"
  logit 4 "${FUNCNAME[0]}" "Creating alias ${index_name} --> ${shrunk_index_name}"
  index_alias='{"actions" : [{ "add" : { "index" : "'${shrunk_index_name}'", "alias" : "'${index_name}'" } }]}"'
  response=$(curl -u "$es_coord_auth" -s -XPOST "${es_coord_host}/_aliases" -H 'Content-Type: application/json' -d"$index_alias")
  if [[ $(echo "$response" | jq '.acknowledged') != true ]]; then
    logit 2 "${FUNCNAME[0]}" "There was an error creating the alias ${shrunk_index_name}"
    logit 2 "${FUNCNAME[0]}" "$(echo "$response" | jq -r '.error.reason')"
    return 1
  else
    logit 4 "${FUNCNAME[0]}" "Alias name ${index_name} has successfully been created and attached to ${shrunk_index_name}"
  fi
}

check_unassigned_shards() {
  local index_name
  local unassigned_shards
  logit 5 "${FUNCNAME[0]}" "Checking for unassigned shards"

  unassigned_shards=($(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/_cat/shards/${index_name}" | grep UNASSIGNED  | awk '{print $1}'))
  logit 4 "${FUNCNAME[0]}" "Found ${#unassigned_shards[@]} unassigned shards"
  for index in ${unassigned_shards[@]}; do
    logit 5 "${FUNCNAME[0]}" "$index has unassigned shards"
  done
  return ${#unassigned_shards[@]}
}

force_shard_allocation() {
  local unassigned_shards
  local unassigned_shards_counter

  until check_unassigned_shards; do
    unassigned_shards=$?
    (( unassigned_shards_counter++ ))
    logit 3 retry_failed_allocation "$unassigned_shards shards were found in an UNASSIGNED state, attempting to retry allocation"
    curl -u "$es_coord_auth" -s -XPOST -o /dev/null "${es_coord_host}/_cluster/reroute?retry_failed"
    sleep 60
    if [[ $unassigned_shards_counter -ge $wait_minutes_force_alloc_success ]]; then
      logit 1 shard_allocation "There are still $unassigned_shards unassigned shards remaining but they will not initialize,  please investigate"
      break
    fi
  done
}

compare_doc_counts() {
  local orig_index_name
  local shrunk_index_name
  local orig_doc_count
  local shrunk_doc_count

  orig_index_name=$1
  shrunk_index_name=$2
  orig_doc_count=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/${orig_index_name}/_stats" | jq '._all.primaries.docs.count')
  shrunk_doc_count=$(curl -u "$es_coord_auth" -s -XGET "${es_coord_host}/${shrunk_index_name}/_stats" | jq '._all.primaries.docs.count')
  if [[ $orig_doc_count -le $shrunk_doc_count ]]; then
    logit 5 "${FUNCNAME[0]}" "${orig_index_name} contains ${orig_doc_count} documents and ${shrunk_index_name} contains ${shrunk_doc_count} documents"
    return 0
  else
    logit 2 "${FUNCNAME[0]}" "${orig_index_name} contains ${orig_doc_count} documents and ${shrunk_index_name} contains ${shrunk_doc_count} documents"
    return 1
  fi
}

get_minimum_date() {
  start_date=$(date +%Y%m%d -d@$(( $(date -d"$(date +%F)" +%s) - (max_days_in_hot * 86400) )))
  logit 4 "${FUNCNAME[0]}" "Only processing indices with dates $(date +%Y-%m-%d -d@$(( $(date -d"$(date +%F)" +%s) - ((max_days_in_hot) * 86400) ))) or older"
}

fetch_indices() {
  local total_indices_count
  local eligible_indices_count
  local json_indices_list

  logit 5 "${FUNCNAME[0]}" "Executing query against ${es_coord_host}/${index_prefix}*/_settings for all matching incides"
  json_indices_list=$(curl -u "$es_coord_auth" -sf -XGET "${es_coord_host}/${index_prefix}*/_settings")
  if [[ $? -gt 0 ]]; then
    logit 1 "${FUNCNAME[0]}" "Unable to fetch the list of indices from ${es_coord_host}/${index_prefix}*/_settings"
    return 1
  fi
#  indices_list=$(grep -E "^${index_prefix}[0-9]{4}\.[0-1][0-9]\.[0-3][0-9]" <<< "$indices_list" | sort  -t "." -k2)
  total_indices_count=$(jq '[.|to_entries[]|.key]|length' <<< "$json_indices_list")
#  indices_list=$(grep -Ev -- "${index_suffix}" <<< "$indices_list" | sort -t "." -k2)
  eligible_indices_count=$(jq "[.|to_entries[]|select(.value.settings.index.routing.allocation.require.box_type==\"$source_box_type\")|.key]|length" <<< "$json_indices_list")
  indices_list=$(jq -r ".|to_entries[]|select(.value.settings.index.routing.allocation.require.box_type!=\"${destination_box_type}\")|.key" <<< "$json_indices_list" | sort -t "." -k2)
  logit 5 "${FUNCNAME[0]}" "Found $total_indices_count indices with pattern ${index_prefix}*"
  logit 4 "${FUNCNAME[0]}" "Found $eligible_indices_count indices with pattern ${index_prefix}* on ${source_box_type} nodes"
  return 0
}

logit 4 script_identity "FortiSIEM es_indices_shrink version 1.1.0 ® Fortinet 2019 All Rights Reserved"

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
unset es_coord_hosts
unset es_coord_port
unset es_coord_user
unset es_coord_pw

get_minimum_date
if ! fetch_indices; then
  logit 1 startup_init "A critical error occured, exiting"
  kill_myself 1
fi

if [[ $dest_adaptive_shard_count == "true" ]]; then
  logit 4 adaptive_shard_count "dest_adaptive_shard_count is set to true, using adaptive shard counts for new $index_suffix indices"
else
  logit 4 adaptive_shard_count "dest_adaptive_shard_count is not configured, all new shards will strictly be based on document counts"
fi

# Loop and feed index names to functions
main_loop_counter=0
indices_counter=0
while read -r index && [[ -n $index ]]; do
  index_shard_count=
  index_date=$(perl -pe "s/${index_prefix}.*([0-9]{4})\.([0-9]{2})\.([0-9]{2})/\1\2\3/g" <<<"$index")
  if [[ $start_date -ge $index_date ]]; then
    (( main_loop_counter++ ))
    if [[ main_loop_counter -gt 1 ]]; then
      logit 4 main_body "Waiting $delay_seconds_between_indices seconds for the system to quiescence before continuing"
      sleep $delay_seconds_between_indices
    fi
    logit 4 main_start_new_index "Beginning to process index $index"
    logit 5 main_preshrink_check "Checking to see if any other indices are using the name ${index}${index_suffix}"
    if index_exists "${index}${index_suffix}"; then
      logit 3 main_preshrink_check "Skipping index ${index} because there is already an existing index named ${index}${index_suffix}"
      continue
    else
      logit 4 main_preshrink_check "Successfully verified that ${index}${index_suffix} does not exist"
    fi
    fetch_shard_count "$index"
    if [[ $index_shard_count -le 1 ]]; then
      logit 4 check_shard_count "Index $index only has 1 shard, it cannot be shrunk further, simply relocating it to $destination_box_type"
      change_routing_allocation "${index}"
      logit 4 main_finish_new_index "Finished processing index $index"
      (( indices_counter++ ))
      continue
    fi
    relocate_shards "$index"
    if [[ $dest_adaptive_shard_count == "true" ]]; then
      get_shard_lcm "$index" "$index_shard_count"
    else
      shard_lcm=1
    fi
    shrink_index "$index"
    counter=0
    check_index_exists=1
    until [[ $check_index_exists ]] || [[ $counter -ge 10 ]]; do
      (( counter++ ))
      index_exists "${index}${index_suffix}" && check_index_exists=0 && break
      logit 3 main_shrunk_exists "Waiting 10 seconds for ${index}${index_suffix} to come online"
      sleep 10
    done
    counter=
    if ! index_exists "${index}${index_suffix}"; then
      logit 2 main_shrunk_exists "${index}${index_suffix} refuses to come online, skipping and continuing"
      continue
    fi
    merge_index_segments "${index}${index_suffix}"
    if [[ $purge_after_successful_shrink = true ]]; then
      if change_routing_allocation "${index}${index_suffix}"; then
        logit 4 "main_status" "$index has successfully been shrunk to ${index_name}${index_suffix}"
      else
        logit 3 "main_status" "$index failed to successfully shrink"
        logit 4 main_finish_new_index "Finished processing index $index"
        continue
      fi
      if ! update_index_replica_count "${index}${index_suffix}"; then
        logit 2 index_replia_count "Unable to set replica count on ${index}${index_suffix}"
        logit 4 main_finish_new_index "Finished processing index $index"
        continue
      fi
      if compare_doc_counts "${index}" "${index}${index_suffix}"; then
        delete_index "${index}"
      else
        logit 2 main_compare_indices "${index} and ${index}${index_suffix} indices do not have the same document count, purging shrunk index and skipping"
        delete_index "${index}${index_suffix}"
        logit 4 main_finish_new_index "Finished processing index $index"
        continue
      fi
      if ! create_index_alias "${index}"; then
        logit 1 index_alias "A critical error occured and the script will be terminated for safety reasons"
        kill_myself 1
      fi
      force_shard_allocation
      (( indices_counter++ ))
    else
      logit 3 main_body "purge_after_successful_shrink is not set to true, so not creating alias, creating additional replicas or purging ${index}"
    fi
  else
    logit 5 main_body "Skipping ${index} because it is not beyond $max_days_in_hot days old"
    (( skipped_indices_counter++ ))
    continue
  fi
  logit 4 main_finish_new_index "Finished processing index $index"
done <<< "$indices_list"

# Due to this bug, https://github.com/VenRaaS/elk/issues/8 it is possible that shards won't allocate properly after moving.
# As a workaround, the script will wait 5 minutes and then check one last time for unassigned shards and manually force a retry if any issues are found.
if [[ ${indices_counter:-0} -gt 0 ]]; then
  logit 4 completion_verification "Waiting 5 minutes and checking shard allocation one last time"
  Sleep 300
  force_shard_allocation
fi

logit 4 shrink_results_processed "Processed ${indices_counter:-0} indices"
logit 4 shrink_results_skipped "Skipped ${skipped_indices_counter:-0} indices because of age exclusion"
kill_myself 0
