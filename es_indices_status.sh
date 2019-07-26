#!/bin/bash

if [ "$#" -gt 2 ]; then
    echo "Illegal number of parameters"
    echo "Usage: $(basename $0) [OPTIONAL:index pattern]>"
    exit 1
fi

non_human='bytes=k&'
while [ "$1" != "" ]; do
    PARAM=`echo $1 | awk -F= '{print $1}'`
    VALUE=`echo $1 | awk -F= '{print $2}'`
    case $PARAM in
        -h | --human)
            non_human=
            ;;
        *)
            index_pattern=$1"*"
            ;;
    esac
    shift
done

if [[ ! -f /opt/phoenix/config/phoenix_config.txt ]]; then
  echo "Unable to locate /opt/phoenix/config/phoenix_config.txt"
  exit 1
fi

coord_host_array=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep cluster_ip= | cut -f2 -d'=' | cut -f1 -d',')
coord_user=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep username= | cut -f2 -d'=' | cut -f1 -d',')
coord_pw=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep password= | cut -f2 -d'=' | cut -f1 -d',')
coord_port=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep http_port= | cut -f2 -d'=' | cut -f1 -d',')
es_enabled=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep enable= | cut -f2 -d'=' | cut -f1 -d',')
index_pattern=$1"*"

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

echo "Connecting to ${coord_prot}${coord_host} on port $coord_port"; echo
found_indices=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/indices/$index_pattern?h=index")
if [[ $(echo "$found_indices" | wc -l) -le 0 ]] || [[ -z $found_indices ]]; then
  echo "No indices matched the name $index_pattern"
  exit 1
fi
index_type=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/fortisiem-*/_settings/index.routing.allocation.require.box_type*/?pretty" | grep -Eo 'fortisiem-.*\s|hot|warm|cold' | perl -pe 's/".*\n/ /' | sort)
index_list=$(curl -q -s -u "$coord_user:$coord_pw" -X GET "${coord_prot}${coord_host}:${coord_port}/_cat/indices/$index_pattern?${non_human}&h=index,health,memoryTotal,status,pri,rep,docs.count,segments.count,merges.current,store.size,creation.date.string" | sort)
index_list_type=$(join -1 1 -2 1 -a1 -e- <(echo "$index_list") -o 1.1 2.2 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 <(echo "$index_type"))
(echo "index type health memTot status pri rep docs segs merges size created"; echo "$index_list_type" ) | column -t | colorize
echo
