#!/bin/bash

if [ "$#" -ne 1 ]; then
    echo "Illegal number of parameters"
    echo "Usage: $(basename $0) <index name>"
    exit 1
fi

if [[ ! -f /opt/phoenix/config/phoenix_config.txt ]]; then
  echo "Unable to locate /opt/phoenix/config/phoenix_config.txt"
  exit 1
fi

coord_host_array=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep cluster_ip= | cut -f2 -d'=' | cut -f1 -d',')
coord_user=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep username= | cut -f2 -d'=' | cut -f1 -d',')
coord_pw=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep password= | cut -f2 -d'=' | cut -f1 -d',')
coord_port=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep http_port= | cut -f2 -d'=' | cut -f1 -d',')
es_enabled=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep enable= | cut -f2 -d'=' | cut -f1 -d',')
index_name=$1

if [[ $es_enabled != true ]]; then
  echo "Elasticsearch is not enabled for this FortiSIEM instance"
  exit 1
fi

IFS=$IFS
IFS=","
coord_host_array=($coord_host_array)
IFS=$OIFS
for (( i=0; i<${#coord_host_array[@]}; i++ )); do
  curl -q -s -u "$coord_user:$coord_pw" --connect-timeout 2 -X GET "https://${coord_host_array[$i]}:$coord_port" -o /dev/null
  if [[ $? -eq 0 ]]; then
    coord_prot="https://"
    coord_host=${coord_host_array[$i]}
    break
  fi
  curl -q -s -u "$coord_user:$coord_pw" --connect-timeout 2 -X GET "http://${coord_host_array[$i]}:$coord_port" -o /dev/null
  if [[ $? -gt 0 ]]; then
    echo "Unable to connect to ${coord_host_array[$i]} on port $coord_port"
  else
    coord_prot="http://"
    coord_host=${coord_host_array[$i]}
    break
  fi
done

echo "Connecting to ${coord_prot}${coord_host} on port $coord_port"; echo
found_indices=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/indices/$index_name?h=index" | grep -v index_not_found_exception)
if [[ $(echo "$found_indices" | wc -l) -le 0 ]] || [[ -z $found_indices ]]; then
  echo "No indices matched the name $index_name"
  exit 1
fi
curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/indices/$index_name?v&h=index,health,tm,status,pri,rep,docs.count,store.size,pri.store.size,creation.date.string&s=index"

read -p "These are the list of indices that matched.  Are you sure you want to delete all of these indices? " -t 10 -n 1 -r
read_status=$?
if [[ $read_status -gt 0 ]]; then
  echo; echo "Timeout! Aborted."
  exit 1
elif [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo; echo "User aborted"
  exit 0
else
  echo
  curl -q -s -u "$coord_user:$coord_pw" -X DELETE "${coord_prot}${coord_host}:${coord_port}/$index_name"
  echo
  read -p "Do you want to recreate empty versions the deleted indices? " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
  else
    while read index; do
      curl -u "$coord_user:$coord_pw" -X PUT "${coord_prot}${coord_host}:${coord_port}/$index" -H 'Content-Type: application/json' -d'
{
    "settings" : {
        "index" : {
            "number_of_shards" : 5,
            "number_of_replicas" : 1
        }
    }
}
'
    echo
    done <<< "$(echo "$found_indices")"
  fi
fi
echo
