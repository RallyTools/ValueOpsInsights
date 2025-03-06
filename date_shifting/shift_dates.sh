#!/bin/bash
#
# shift_dates on a VSMProductAnalyticsMetric or VSMOutcome's Measures and Targets forwards or backwards N days
#
# Required params
# -n N                   N - a negative or positve number of days
# -k key                 key - API_KEY to use
# -o oid|uuid            oid or uuid of the VSMProductAnalyticsMetric or VSMOutcome of which to update the Targets and Measures
#
# Optional params
# -h host                host - what host to use (default = https://rally1.rallydev.com)
# -w workspaceOid        oid of the workspace (default = your default workspace)
# -O                     update an VSMOutcome (default VSMProductAnalyticsMetric)
# -B                     batch update (default one-at-a-time).  One-at-a-time has better feedback.
#
#ex:
#
# shift dates forward 1 day on the VSMProductAnalyticsMetric 812185925567 in workspace 41529001 
# sh shift_dates.sh -h https://joel.testn.f4tech.com -n 1 -o 812185925567 -k _Pq0S7RwKSd65LZ6J8r2WILCDgg2x0hprcvyKvcakyU -w 41529001
#
# shift dates backward 1 day in batch mode on the VSMProductAnalyticsMetric 812185925567 in workspace 41529001 
# sh shift_dates.sh -B -h https://joel.testn.f4tech.com -n -1 -o 812185925567 -k _Pq0S7RwKSd65LZ6J8r2WILCDgg2x0hprcvyKvcakyU -w 41529001
#
# shift dates forward 1 day on the VSMOutcome 818109360951 in workspace 41529001 
# sh shift_dates.sh -O -h https://joel.testn.f4tech.com -n 1 -o 818109360951 -k _Pq0S7RwKSd65LZ6J8r2WILCDgg2x0hprcvyKvcakyU -w 41529001

days=""
oid=""
workspaceOid=""
defaulthost="https://rally1.rallydev.com"
host="$defaulthost"
instmessage="but it's either not installed or not on your PATH.  Please fix that and try again."
workspace=""
metricType="VSMProductAnalyticsMetric"
batchMode=false

hash jq 2>/dev/null || { echo >&2 "\"jq\" is required to parse and create json values, ${instmessage}"; exit 1; }
hash curl 2>/dev/null || { echo >&2 "\"curl\" is required to make WSAPI requests to Rally, ${instmessage}"; exit 1; }

# Parse command-line arguments
while getopts ":h:n:o:k:w:OB" opt; do
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
            oid="$OPTARG"
            ;;
        w)
            workspaceOid="$OPTARG"
            ;;
        O)
            metricType="VsmOutcome"
            ;;
        B)
            batchMode=true
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done

# Check if required arguments are provided
if [ -z "$days" ] || [ -z "$oid" ] || [ -z "$key" ]; then
    echo "Usage: $0 -n <number_of_days> -o <object_id|object_uuid> -k <key> [ -w <workspaceOid> ] [ -h <host> ($host) ] [ -O ] [ -B ]"
    exit 1
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

echo "Number of days: $days"
echo "Object ID: $oid"
echo "Host: $host"

if [ -z $(echo "$host" | grep "^http") ]; then
    echo "The host parameter should start with the protocol (http:// or https://).  The default is $defaulthost"
    exit 1
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
    local oid="$1"
    local days="$2"
    local collection="$3"
    local url="$base_url/${metricType}/$oid/$collection"
    local page_size=20
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
        echo "\nSubtracting ${days#-} days from $value in $collection for /${metricType}/$oid"
    else
        echo "\nAdding $days days to $value in $collection for /${metricType}/$oid"
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

update "$oid" "$days" "Measures"

update "$oid" "$days" "Targets"

echo "Script finished."
