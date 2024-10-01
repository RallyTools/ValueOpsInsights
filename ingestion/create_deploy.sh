#!/bin/bash

VERSION=1
NAME=$(basename $0)
AUTHOR="Iron Will Beard"
set -x
SOURCE_SYSTEM_META_DATA="{ \\\"name\\\":\\\"${NAME}\\\",\\\"version\\\":${VERSION},\\\"author\\\":\\\"${AUTHOR}\\\" }"

echo "RALLY_API_URL: ${RALLY_API_URL}"
echo "RALLY_WORKSPACE_OID: ${RALLY_WORKSPACE_OID}"
echo "DEPLOY_COMPONENT_NAME: ${DEPLOY_COMPONENT_NAME}"
echo "DEPLOY_BUILD_ID: ${DEPLOY_BUILD_ID}"
echo "DEPLOY_START_TIME: ${DEPLOY_START_TIME}"
echo "DEPLOY_END_TIME: ${DEPLOY_END_TIME}"
echo "DEPLOY_IS_SUCCESSFUL: ${DEPLOY_IS_SUCCESSFUL}"
echo "PREVIOUS_SUCCESS_BUILD_COMMIT: ${PREVIOUS_SUCCESS_BUILD_COMMIT}"
echo "CURRENT_BUILD_COMMIT: ${CURRENT_BUILD_COMMIT}"
echo "GIT_REPO_LOC: ${GIT_REPO_LOC}"
echo "DEPLOY_BUILD_URL: ${DEPLOY_BUILD_URL}"
echo "COMMIT_OVERRIDE: ${COMMIT_OVERRIDE}"

if [ -z "$RALLY_API_KEY" ]; then
  echo "RALLY_API_KEY is not set"
  exit 1
fi

if [ -z "$RALLY_API_URL" ]; then
  echo "RALLY_API_URL is not set"
  exit 1
fi

if [ -z "$RALLY_WORKSPACE_OID" ]; then
  echo "RALLY_WORKSPACE_OID is not set"
  exit 1
fi

if [ -z "$DEPLOY_COMPONENT_NAME" ]; then
  echo "DEPLOY_COMPONENT_NAME is not set"
  exit 1
fi

if [ -z "$DEPLOY_BUILD_ID" ]; then
  echo "DEPLOY_BUILD_ID is not set"
  exit 1
fi

if [ -z "$DEPLOY_START_TIME" ]; then
  echo "DEPLOY_START_TIME is not set"
  exit 1
fi

if [ -z "$PREVIOUS_SUCCESS_BUILD_COMMIT" ]; then
  echo "PREVIOUS_SUCCESS_BUILD_COMMIT is not set"
fi

if [ -z "$CURRENT_BUILD_COMMIT" ]; then
  echo "CURRENT_BUILD_COMMIT is not set"
fi

if [ -z "$COMMIT_OVERRIDE" ]; then
  echo "COMMIT_OVERRIDE is not set"
fi

if [ -z "$GIT_REPO_LOC" ]; then
  echo "GIT_REPO_LOC is not set"
  exit 1
fi

if [ -z "$DEPLOY_BUILD_URL" ]; then
  echo "DEPLOY_BUILD_URL is not set"
fi

full_RALLY_api_url="$RALLY_API_URL/slm/webservice/v2.0"

parse_millis() {
    local ms=$1
    local seconds=$((ms / 1000))
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        date -r $seconds -u +"%Y-%m-%dT%H:%M:%SZ"
    else
        # Linux and other Unix-like systems
        date -u -d @$seconds +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

make_vsm_deploy() {
  echo "Creating VSMDeploy" >&2
  
  local deploy_is_successful=$1
  local formatted_start_date=$2
  local formatted_end_date=$3
  local current_build_commit=$4
  local deploy_component_oid=$5
  local deploy_build_id=$6
  local deploy_build_url=$7
  
  json="{"
  json+="\"VSMDeploy\": {"
  
  if [ ! -z "$deploy_is_successful" ] && [ "$deploy_is_successful" != "null" ]; then
    json+="\"IsSuccessful\": $deploy_is_successful,"
  fi
  
  if [ ! -z "$formatted_end_date" ]; then
    json+="\"TimeDeployed\": \"$formatted_end_date\","
  fi
  
  if [ ! -z "$deploy_build_url" ]; then
    json+="\"SourceUrl\": \"$deploy_build_url\","
  fi

  if [ ! -z "$deploy_build_id" ]; then
    json+="\"SourceId\": \"$deploy_build_id\","
  fi

  if [ ! -z "$SOURCE_SYSTEM_META_DATA" ]; then
    json+="\"SourceSystemMetaData\": \"$SOURCE_SYSTEM_META_DATA\","
  fi

  json+="\"TimeCreated\":  \"$formatted_start_date\","
  json+="\"MainRevision\": \"$current_build_commit\","
  json+="\"Component\":    \"vsmcomponent/$deploy_component_oid\","
  json+="\"BuildId\":      \"$deploy_build_id\""
  json+="}"
  json+="}"
  
  echo "Posting VSMDeploy to Insights" >&2
  echo "$json" >&2
  
  response=$(curl -s \
     -H "ZSESSIONID: $RALLY_API_KEY" \
     -H 'Content-Type: application/json' \
     -X POST \
     -d "$json" \
     "$full_RALLY_api_url/vsmdeploy/create?workspace=workspace/$RALLY_WORKSPACE_OID")
  if [ $? -ne 0 ]; then
    echo "Could not connect to $RALLY_API_URL" >&2
    exit 1
  fi
  
  echo "$response"
}

get_object_id_from_response() {
  local response="$1"
  
  local object_id
  object_id=$(echo "$response" | grep -o '"ObjectID":[^,}]*' | head -1 | sed 's/.*: //')
  
  echo "$object_id"
}

create_commit_log() {
  local git_repo_loc=$1
  local log_path=$2
  local from_commit=$3
  local to_commit=$4
  
  touch "$log_path"
  git --git-dir="$git_repo_loc/.git" log --pretty=format:'%H %at000' --date=iso "$from_commit".."$to_commit" > "$log_path"
  echo >> "$log_path"
}

make_vsm_change() {
  local commit_id=$1
  local formatted_date=$2
  local deploy_id=$3
  local deploy_build_id=$4
  local deploy_build_url=$5
  
  json="{
      \"VSMChange\": {
        \"Revision\":   \"$commit_id\",
        \"CommitTime\": \"$formatted_date\",
        \"Deploy\":     \"$deploy_id\""

  if [ ! -z "$deploy_build_url" ]; then
    json+=", \"SourceUrl\": \"$deploy_build_url\""
  fi

  if [ ! -z "$deploy_build_id" ]; then
    json+=", \"SourceId\": \"$deploy_build_id\""
  fi

  if [ ! -z "$SOURCE_SYSTEM_META_DATA" ]; then
    json+=", \"SourceSystemMetaData\": \"$SOURCE_SYSTEM_META_DATA\""
  fi

  json+="
      }
    }"
    
  echo "Posting VSMChange to Insights" >&2
  echo "$json" >&2
  
  response=$(curl -s -H "ZSESSIONID: $RALLY_API_KEY" -H 'Content-Type: application/json' -X POST -d "$json" "$full_RALLY_api_url/vsmchange/create?workspace=workspace/$RALLY_WORKSPACE_OID")
  
  if [ $? -ne 0 ]; then
    echo "Could not connect to $RALLY_API_URL" >&2
    exit 1
  fi
  
  echo "$response"
}

query_component() {
    local name=$1
    local response
    response=$(curl -s -H "ZSESSIONID: $RALLY_API_KEY" "$full_RALLY_api_url/vsmcomponent?query=(Name%20=%20$name)&workspace=workspace/$RALLY_WORKSPACE_OID&fetch=ObjectID")
    
    if [ $? -ne 0 ]; then
      echo "Could not connect to $RALLY_API_URL" >&2
      exit 1
    fi
    
    echo "$response"
}

get_last_successful_deploy_revision() {
  local component_id=$1
  local main_revision
  
  response=$(curl -s -H "ZSESSIONID: $RALLY_API_KEY" "$full_RALLY_api_url/vsmdeploy?order=TimeDeployed%20desc&query=((IsSuccessful%20=%20true)%20and%20(Component%20=%20vsmcomponent/$component_id))&workspace=workspace/$RALLY_WORKSPACE_OID&fetch=MainRevision")
  
  if [ $? -ne 0 ]; then
    echo "Could not connect to $RALLY_API_URL" >&2
    exit 1
  fi
  
  # Parse the MainRevisions out of the response and get the first one in the list
  main_revision=$(echo "$response" | grep -o '"MainRevision":[^,}]*' | head -1 | sed 's/.*: //')
  
  # Remove quotes
  main_revision="${main_revision%\"}"
  main_revision="${main_revision#\"}"
  
  echo $main_revision
}


formatted_start_date=$(parse_millis "$DEPLOY_START_TIME")
if [ $? -ne 0 ]; then
  echo "Could not parse start time: $DEPLOY_START_TIME"
  exit 1
fi

if [ -z "$DEPLOY_END_TIME" ] || [ "$DEPLOY_END_TIME" == "null" ]; then
  formatted_end_date=""
else
  formatted_end_date=$(parse_millis "$DEPLOY_END_TIME")
  if [ $? -ne 0 ]; then
    echo "Could not parse end time: $DEPLOY_END_TIME"
    exit 1
  fi
fi

### Script flow starts here

## Find the component by name
component_response=$(query_component "$DEPLOY_COMPONENT_NAME")

if [ $? -ne 0 ]; then
  echo "Failed to query component in Insights"
  exit 1
fi

component_id=$(get_object_id_from_response "$component_response")

if [ -z "$component_id" ]; then
  echo "Failed to find component in Insights, no component id found in response." >&2
  echo "$component_response"
  exit 1
fi

if [ -z "$COMMIT_OVERRIDE" ]; then
  ## Resolve the last successful deploy revision
  # Use what was passed in
  last_successful_deploy_revision=$PREVIOUS_SUCCESS_BUILD_COMMIT

  # If it was null, get the last successful deploy's revision
  if [ -z "$last_successful_deploy_revision" ]; then
    last_successful_deploy_revision=$(get_last_successful_deploy_revision "$component_id")
  fi

  # If _that_ was null (meaning no existing successful deploys), then set it to the commit before the current_build_commit
  # Or if the last successful deploy is the same as the current build commit, then set it to the commit before the current_build_commit
  if [ -z "$last_successful_deploy_revision" ] || [ "$last_successful_deploy_revision" == "$CURRENT_BUILD_COMMIT" ]; then
    last_successful_deploy_revision="$CURRENT_BUILD_COMMIT~1"
  fi
fi

## Make a Deploy
deploy_response=$(make_vsm_deploy "$DEPLOY_IS_SUCCESSFUL" "$formatted_start_date" "$formatted_end_date" "$CURRENT_BUILD_COMMIT" "$component_id" "$DEPLOY_BUILD_ID" "$DEPLOY_BUILD_URL")

## Exit if error
if [ $? -ne 0 ]; then
  echo "Failed to create deploy in Insights"
  exit 1
fi

## Get Deploy ID
deploy_id=$(get_object_id_from_response "$deploy_response")

## Exit if it we can't find the deploy id in the response (this could be for many reasons)
if [ -z "$deploy_id" ]; then
  echo "Failed to create deploy in Insights, no deploy id found in response." >&2
  echo "$deploy_response"
  exit 1
fi

echo "Deploy created successfully"
echo "VSMDeploy.ObjectId: $deploy_id"

echo "Last successful deploy revision: $last_successful_deploy_revision"

# ## Create the commit log we're going to loop over
log_file_path="$GIT_REPO_LOC/commit_log"
if [ -z "$COMMIT_OVERRIDE" ]; then
  create_commit_log "$GIT_REPO_LOC" "$log_file_path" "$last_successful_deploy_revision" "$CURRENT_BUILD_COMMIT"
else
  echo "$COMMIT_OVERRIDE" > $log_file_path
fi

## Loop over the commit log and make VSMChanges
while IFS= read -r line; do
    # Read the line
    read -r commit_id timestamp <<< "$line"
    
    # Exit if we can't parse the line
    if [ -z "$commit_id" ] || [ -z "$timestamp" ]; then
      echo "Failed to parse commit log line: $line" >&2
      exit 1
    fi

    # Parse the date
    formatted_date=$(parse_millis "$timestamp")
    
    # Make the VSMChange
    change_response=$(make_vsm_change "$commit_id" "$formatted_date" "$deploy_id" "$DEPLOY_BUILD_ID" "$DEPLOY_BUILD_URL")

    # Exit if error
    if [ $? -ne 0 ]; then
      echo "Failed to create VSMChange in Insights"
      exit 1
    fi
    
    # Try to extract the change id
    change_id=$(get_object_id_from_response "$change_response")
    
    # Exit if it we can't find the change id in the response (this could be for many reasons)
    if [ -z "$change_id" ]; then
      echo "Failed to create VSMChange in Insights, no change id found in response."
      echo "$change_response"
      exit 1
    fi
    
    echo "VSMChange created successfully"
    echo "VSMChange.ObjectId: $change_id"
done < "$log_file_path"