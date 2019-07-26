#!/bin/bash

coord_prot=https://
coord_host=supervisor-001.ord1.prod.isiem.rackspace.net
coord_port=443
coord_host_array=test

if [ "$#" -gt 0 ]; then
    echo "Illegal number of parameters"
    echo "Usage: $(basename $0)"
    exit 1
fi

if [[ -z $coord_host_array ]]; then
if [[ ! -f /opt/phoenix/config/phoenix_config.txt ]]; then
  echo "Unable to locate /opt/phoenix/config/phoenix_config.txt"
  exit 1
fi

coord_host_array=($(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep cluster_ip= | cut -f2 -d'='))
coord_user=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep username= | cut -f2 -d'=' | cut -f1 -d',')
coord_pw=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep password= | cut -f2 -d'=' | cut -f1 -d',')
coord_port=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep http_port= | cut -f2 -d'=' | cut -f1 -d',')
es_enabled=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep enable= | cut -f2 -d'=' | cut -f1 -d',')

if [[ $es_enabled != true ]]; then
  echo "Elasticsearch is not enabled for this FortiSIEM instance"
  exit 1
fi

OIFS=$IFS
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
fi

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
colorize() {
  sed -e "s/green/${DGREEN}green${NORMAL}/" -e "s/yellow/${DYELLOW}yellow${NORMAL}/" -e "s/red/${DRED}red${NORMAL}/"
}

>&2 echo "Connecting to ${coord_prot}${coord_host} on port $coord_port"; >&2 echo
found_clusters=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/health")
if [[ $(echo "$found_clusters" | wc -l) -le 0 ]]; then
  echo "Unable to locate any Elasticsearch clusters"
  exit 1
fi
index_type=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/fortisiem-*/_settings/index.routing.allocation.require.box_type*/?pretty" | grep -Eo 'fortisiem-.*\s|hot|warm|cold' | perl -pe 's/".*\n/ /' | sort)
index_list=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/indices/$index_pattern?bytes=k&h=index,store.size" | sort)
index_list_type=$(join -1 1 -2 1 -a1 -e- <(echo "$index_list") -o 1.1 1.2 2.2 <(echo "$index_type"))
hot_data=$(echo "$index_list_type" | grep hot | awk '{print $2}' | paste -sd+ | bc | awk '{print $1/1000/1000}')
warm_data=$(echo "$index_list_type" | grep warm | awk '{print $2}' | paste -sd+ | bc | awk '{print $1/1000/1000}')
hot_heap_used_gb=$(printf "$(/opt/phoenix/bin/es_node_status | grep 'hot$' | tr -s ' ' | cut -f8,9 -d' ' | awk '{printf "%0.2f\n",($2/100)*$1}' | paste -sd+ | bc)/1024\n"|bc)
hot_heap_total_gb=$(printf "$(/opt/phoenix/bin/es_node_status | grep 'hot$' | tr -s ' ' ' ' | cut -d' ' -f8 | paste -sd+ | bc)/1024\n"|bc)
hot_heap_pct=$(echo $hot_heap_used_gb $hot_heap_total_gb | awk '{printf "%0.2f\n",$1/$2*100}')
warm_heap_used_gb=$(printf "$(/opt/phoenix/bin/es_node_status | grep 'warm$' | tr -s ' ' | cut -f8,9 -d' ' | awk '{printf "%0.2f\n",($2/100)*$1}' | paste -sd+ | bc)/1024\n"|bc)
warm_heap_total_gb=$(printf "$(/opt/phoenix/bin/es_node_status | grep 'warm$' | tr -s ' ' ' ' | cut -d' ' -f8 | paste -sd+ | bc)/1024\n"|bc)
warm_heap_pct=$(echo $warm_heap_used_gb $warm_heap_total_gb | awk '{printf "%0.2f\n",$1/$2*100}')
cluster_stats=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/health?h=cluster,status,node.total,node.data,shards,pri,relo,init,unassign,pendingtasks,max_task_wait_time,active_shards_percent")


header="cluster status nodes dataNodes shards pri relo init unassign taskWait activeShards hotHeapPct hotHeap hotHeapMax wrmHeapPct wrmHeap wrmHeapMax hotData warmData"
payload="$header\n$cluster_stats $hot_heap_pct $hot_heap_used_gb $hot_heap_total_gb $warm_heap_pct $warm_heap_used_gb $warm_heap_total_gb ${hot_data:-0} ${warm_data:-0}\n"
echo -en "$payload" | column -t -s' ' | colorize
echo
