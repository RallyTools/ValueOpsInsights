#!/bin/bash
#
# shift_dates on a VSMProductAnalyticsMetric or VSMOutcome's Measures and Targets forwards or backwards N days
#

days=""
id=""
workspaceOid=""
pagesize=20
defaulthost="https://rally1.rallydev.com"
host="$defaulthost"
instmessage="but it's either not installed or not on your PATH.  Please fix that and try again."
workspace=""
metricType="VSMProductAnalyticsMetric"
batchMode=false
pam=false

hash jq 2>/dev/null || { echo >&2 "\"jq\" is required to parse and create json values, ${instmessage}"; exit 1; }
hash curl 2>/dev/null || { echo >&2 "\"curl\" is required to make WSAPI requests to Rally, ${instmessage}"; exit 1; }

usage() {
   cat <<EOF

Usage: $0 -p|-o <oid|uuid> -k <key> -n <days> [-h <host>] [-w <workspaceOid> ] [ -b ]

Required:
    -p oid|uuid                      update a VSMProductAnalyticsMetric or
    -o oid|uuid                      update an VSMOutcome

    -k key                           using <key> API_KEY
    -n days                          move dates n days forward or backward (-days if backwards)

Optional:
    -w workspaceOid                  specify what workspace if it's not your default
    -s pageSize                      specify page size (20)
    -h host                          specify what Rally host if not http://rally1.rallydev.com
    -b                               update in batch mode - typically faster, but with less informational logging

For the given VSMProductAnalyticsMetric or VSMOutcome (-o and -p are mutually exclusive), find all their associated
Targets and Measures and add or subtract <days> to/from their respective TargetDates and ValueTimes 

ex:
forward 1 day, on VSMProductAnalyticsMetric/812185925567, using the given api key, in workspace 41529001 

    sh shift_dates.sh -n 1 -p 812185925567 -k _Pq0S7RwKSd65LZ6J8r2WILCDgg2x0hprcvyKvcakyU -w 41529001

in batch mode, backward 1 day, on VSMProductAnalyticsMetric/812185925567, using the given api key, in workspace 41529001 

    sh shift_dates.sh -b -n -1 -p 812185925567 -k _Pq0S7RwKSd65LZ6J8r2WILCDgg2x0hprcvyKvcakyU -w 41529001

forward 1 day, on VSMOutcome/818109360951, using the given api key, in the default workspace associated with the key

    sh shift_dates.sh -n 1 -o 818109360951 -k _Pq0S7RwKSd65LZ6J8r2WILCDgg2x0hprcvyKvcakyU

EOF
   exit 1
}

# Parse command-line arguments
while getopts ":h:n:p:o:k:w:s:b" opt; do
    case $opt in
        h)
            host="$OPTARG"
            ;;        
        k)
            key="$OPTARG"
            ;;
        n)
            days="$OPTARG"
            ;;
        o)
            metricType="VSMOutcome"
            id="$OPTARG"
            ;;
        p)
            pam=true 
            id="$OPTARG"
            ;;
        w)
            workspaceOid="$OPTARG"
            ;;
        s)
            pagesize="$OPTARG"
            ;;
        b)
            batchMode=true
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            ;;
    esac
done

# Check if required arguments are provided
if [ -z "$days" ] || [ -z "$id" ] || [ -z "$key" ]; then
    usage
fi

if [ "$pam" = "true" ] && [ "$metricType" = "VSMOutcome" ]; then
    echo "-p and -o are mutually exclusive"
    usage
fi

if [ ! -z "$workspaceOid" ]; then
    workspace="workspace=/workspace/${workspaceOid}&"
fi

# Check if days starts with + or -
if [[ ! "$days" =~ ^[-+]?[0-9]+$ ]]; then
    echo "Invalid value for n: $days. Must be a number prefixed with + or - [+]."
    exit 1
fi

# Base URL for the API
base_url="${host}/slm/webservice/v2.0"

#echo "Number of days: $days"
#echo "ID:   $id"
#echo "Host: $host"

if [ -z $(echo "$host" | grep "^http") ]; then
    echo "The host parameter should start with the protocol (http:// or https://).  The default is $defaulthost"
    usage
    #exit 1
fi

# Function to move a timestamp forward or backwards
update_time() {
    local value_time=$1
    local days=$2
    # Convert time to epoch seconds and add/subtract days
    if [[ "$OSTYPE" == "darwin"* ]]; then # macos
        new_epoch_seconds=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$value_time" +'%s')
    else # linux
        new_epoch_seconds=$(date -u -d    '%Y-%m-%dT%H:%M:%S' "$value_time" +'%s')
    fi

    if [[ -z "$new_epoch_seconds" ]]; then
        echo "Error converting date: $value_time"
        exit
    fi
    new_epoch_seconds=$((new_epoch_seconds + (days * 24 * 60 * 60)))

    # Format the new date back to ISO 8601
    if [[ "$OSTYPE" == "darwin"* ]]; then # macos
        new_value_time=$(date -u -r "$new_epoch_seconds" +"%Y-%m-%dT%H:%M:%SZ")
    else # linux
        new_value_time=$(date -u -d @$new_epoch_seconds  +"%Y-%m-%dT%H:%M:%SZ")
    fi
    echo $new_value_time
}

# Function to fetch and update measures and targets
update() {
    local id="$1"
    local days="$2"
    local collection="$3"
    local url="$base_url/${metricType}/$id/$collection"
    local page_size="$pagesize"
    local start_index=1
    local total_results=0
    export loop_count=1
    export batchMode

    case "$collection" in
        "Measures")
            type="VSMMeasure"
            value="ValueTime"
            ;;
        "Targets")
            type="VSMTarget"
            value="TargetDate"
            ;;
        *)
            echo "Invalid collection type $collection"
            exit 0
    esac

    if [[ "$days" < 0 ]]; then
        echo "\nSubtracting ${days#-} days from $value for ${base_url}/${metricType}/$id/$collection\n"
    else
        echo "\nAdding $days days to $value for ${base_url}/${metricType}/$id/$collection\n"
    fi

    while true; do
        echo "Fetching $page_size $collection..."
        response=$(curl --cookie "ZSESSIONID=$key" -s "$url?${workspace}pagesize=${page_size}&start=${start_index}&key=${key}")

        # Get total result count on first iteration
        if [ $start_index -eq 1 ]; then
            if [[ -z $(echo "$response" | grep TotalResultCount) ]]; then
                echo "Error: Could not retrieve total result count or invalid JSON response from\n\n$url\n\nis your key valid?"
                exit 1
            fi
            total_results=$(echo "$response" | jq '.QueryResult.TotalResultCount' 2> /dev/null)
            if [[ "$total_results" == "null" ]]; then
                echo "Error: Could not retrieve total result count or invalid JSON response."
                exit 1
            fi
            echo "Updating $total_results $collection"
        fi

        entries=$(echo "$response" | jq '.QueryResult.Results')

        # Check if collection is null or empty
        len=$(echo "$response" | jq '.QueryResult.Results' | jq 'length')

        if [[ $len -eq 0 ]]; then
            break # done
        fi

	batch_array=""

        # Iterate through each entry and update it
        batch=$(echo "$entries" | jq -c '.[]' | while read -r entry; do
            # Extract the time value
            value_time=$(echo "$entry" | jq --arg value "$value" -r '.[$value]' | sed 's/\..*//')

            # Check if it's null
            if [[ "$value_time" == "null" ]]; then
                echo "Skipping $type due to null $value." 1>&2 
                continue
            fi

            new_value_time=$(update_time $value_time $days)
            # if we got an error parsing a date, exit.  something's wrong
            if [[ "$new_value_time" == Error* ]]; then
                exit 1
            fi

            # Get the entry's OID and UUID for the update URL
            entry_uuid=$(echo "$entry" | jq -r '._refObjectUUID')
            entry_oid=$(echo "$entry" | jq -r '.ObjectID')
            update_url="$base_url/$type/${entry_uuid}?${workspace}key=$key"

            # Construct the updated measure JSON
            updated_entry=$(jq -n --arg type "$type" --arg value "$value" --arg new_value_time "$new_value_time" '{($type):{($value):$new_value_time}}')

            if [[ "$batchMode" == "true" ]]; then
                batch_entry=$(jq -n --arg path "$type/$entry_oid" --arg type "$type" --arg entry "$updated_entry" --arg value "$value" --arg new_value_time "$new_value_time" '{"Entry":{"Path":($path),"Method":"POST","Body":{($type):{($value):$new_value_time}}}}')
		echo "${comma}${batch_entry}"
		comma=","
            else
                # Update the measure and get the new updated time
                update_response=$(curl -s -X POST -H "Content-Type: application/json" --cookie "ZSESSIONID=$key" -d "$updated_entry" "$update_url")
                updated_time_value=$(echo "$update_response" | jq --arg value "$value" '.OperationResult.Object.[$value]')
    
                # Check for update errors
                errs=$(echo "$update_response" | jq '.OperationResult.Errors' | jq 'length')
                if [[ $errs -gt 0 ]]; then
                    echo "Error updating $type:" 1>&2 
                    echo "$update_response" | jq '.OperationResult.Errors[]' 1>&2 
                else
                    echo "$loop_count: $type $entry_oid (uuid: $entry_uuid) updated : old $value - \"${value_time}Z\", new $value - $updated_time_value" 1>&2
                fi
            fi
            loop_count=$(($loop_count + 1))    # local to this subshell
        done)

        if [[ ! "${batch}" == "" ]]; then
            echo "Performing batch update..."
            batch_update="{ \"Batch\": [ ${batch} ] }"
            update_url="${base_url}/batch?${workspace}key=$key"
            update_response=$(curl -s -X POST -H "Content-Type: application/json" --cookie "ZSESSIONID=$key" -d "$batch_update" "$update_url")
            # Check for update errors
            errs=$(echo "$update_response" | jq '.OperationResult.Errors' | jq 'length')
            if [[ $errs -gt 0 ]]; then
                echo "Error updating $type:" 1>&2 
                echo "$update_response" | jq '.OperationResult.Errors[]' 1>&2 
            fi
        fi

        # Check if we've processed all results
        start_index=$((start_index + page_size))
        if [[ $start_index -gt $total_results ]]; then
            break
        fi
        loop_count=$((loop_count + page_size))
    done
}

update "$id" "$days" "Measures"

update "$id" "$days" "Targets"

echo "Script finished."
