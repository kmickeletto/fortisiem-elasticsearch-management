#!/bin/bash

if [[ ! -f /opt/phoenix/config/phoenix_config.txt ]]; then
	  echo "Unable to locate /opt/phoenix/config/phoenix_config.txt"
	    exit 1
    fi

    read -p "Please enter the org Id you want to purge: " purge_org
    if [[ -z $purge_org ]]; then
	      echo "You Must specify a customer orgId"
	        exit 1
	fi

	read -p "Enter the oldest date to delete MM/dd/yyyy or ALL for all indices: " max_date
	if [[ -z $max_date ]]; then
		  echo "You must specify a valid date"
		    exit 1
	    fi

	    read -p "Enter the most recent date to delete MM/dd/yyyy or leave blank to delete all indices through $(date '+%m/%d/%Y'): " max_recent_date
	    if [[ -z $max_recent_date ]]; then
		      max_recent_date=$(date '+%m/%d/%Y')
	      fi

	      if date -d "$max_recent_date" >/dev/null 2>&1; then
		        max_recent_date=$(perl -pe "s/([0-9]{2})\/([0-9]{2})\/([0-9]{4})/\3\1\2/g" <<< $max_recent_date)
		else
  echo "Invalid date specified: $max_recent_date"
  exit 1
fi

if [[ $max_date == "ALL" ]]; then
  max_date=19700101
else
  if date -d "$max_date" >/dev/null 2>&1; then
    max_date=$(perl -pe "s/([0-9]{2})\/([0-9]{2})\/([0-9]{4})/\3\1\2/g" <<< $max_date)
  else
    echo "Invalid date specified: $max_date"
    exit 1
  fi
fi

coord_host_array=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep cluster_ip= | cut -f2 -d'=' | cut -f1 -d',')
coord_user=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep username= | cut -f2 -d'=' | cut -f1 -d',')
coord_pw=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep password= | cut -f2 -d'=' | cut -f1 -d',')
coord_port=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep http_port= | cut -f2 -d'=' | cut -f1 -d',')
es_enabled=$(awk '/\[BEGIN Elasticsearch\]/,/\[END\]/' /opt/phoenix/config/phoenix_config.txt | grep enable= | cut -f2 -d'=' | cut -f1 -d',')

if [[ $es_enabled != true ]]; then
  echo "Elasticsearch is not enabled for this FortiSIEM instance"
  exit 1
fi

IFS=","
coord_host_array=($coord_host_array)
unset IFS
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
echo "Searching for indices between the dates $max_date and $max_recent_date"
indices=($(curl -s -u $coord_user:$coord_pw "${coord_prot}${coord_host}:${coord_port}/*/_settings" | jq -r '.[]|select(.settings.index.provided_name|test("fortisiem-event-.*-'${purge_org:-blank}'(?:-shrunk)?$")) | [.settings.index.provided_name,.settings.index.provided_name] | join(" ")' | perl -pe "s/fortisiem-event-.*([0-9]{4})\.([0-9]{2})\.([0-9]{2}).* (.*)/\1\2\3 \4/g" | sort | awk '{print $2}'))
for index in ${!indices[@]}; do
  index_date=$(perl -pe "s/fortisiem-event-.*([0-9]{4})\.([0-9]{2})\.([0-9]{2}).*/\1\2\3/g" <<<"${indices[$index]}")
  if [[ $index_date -lt $max_date ]] || [[ $index_date -gt $max_recent_date ]]; then
    unset indices[$index]
  fi
done
pr -ts" " --columns 3 <<< "$(printf '%s\n' "${indices[@]}")" | column -t
echo
echo "Found ${#indices[@]} matching indices"

if [[ ${#indices[@]} -eq 0 ]]; then
 exit
fi

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
  for index in ${indices[@]}; do
    echo "Deleting index $index"
    curl -q -s -u $coord_user:$coord_pw -X DELETE "${coord_prot}${coord_host}:${coord_port}/${index:-blank}"
    echo
  done
fi

