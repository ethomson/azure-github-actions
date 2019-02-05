#!/bin/bash

set -e 

if [ -z "$AZURE_BOARDS_ORGANIZATION" ]; then
    echo "AZURE_BOARDS_ORGANIZATION is not set." >&2
    exit 1
fi

if [ -z "$AZURE_BOARDS_PROJECT" ]; then
    echo "AZURE_BOARDS_PROJECT is not set." >&2
    exit 1
fi

if [ -z "$AZURE_BOARDS_TOKEN" ]; then
    echo "AZURE_BOARDS_TOKEN is not set." >&2
    exit 1
fi

if [ -z "$GITHUB_EVENT_PATH" ]; then
    echo "GITHUB_EVENT_PATH is not set." >&2
    exit 1
fi

function work_items_for_issue {
    vsts work item query --wiql "SELECT ID FROM workitems WHERE [System.Tags] CONTAINS 'GitHub' AND [System.Tags] CONTAINS 'Issue ${GITHUB_ISSUE_NUMBER}'" | jq '.[].id' | xargs
}

function check_github_label {
    for EXPECTED in $(sed 's/;/ /g' <<< "$ITEM_LABEL"); do
        for SET in $(jq --raw-output '.issue.labels[].name' "$GITHUB_EVENT_PATH" | xargs); do
            if [ "$EXPECTED" = "$SET" ]; then
                return 0
            fi
        done
    done

    return 1
}

function create_work_item {
    echo "Creating work item..."
    RESULTS=$(vsts work item create --type "${AZURE_BOARDS_TYPE}" \
        --title "${AZURE_BOARDS_TITLE}" \
        --description "${AZURE_BOARDS_DESCRIPTION}" \
        -f 80="GitHub; Issue ${GITHUB_ISSUE_NUMBER}" \
        --output json)
    AZURE_BOARDS_ID=$(echo "${RESULTS}" | jq --raw-output .id)

    echo "Created work item #${AZURE_BOARDS_ID}"
}

AZURE_BOARDS_TYPE="${AZURE_BOARDS_TYPE:-Feature}"
AZURE_BOARDS_CLOSED_STATE="${AZURE_BOARDS_CLOSED_STATE:-Done}"
AZURE_BOARDS_REOPENED_STATE="${AZURE_BOARDS_REOPENED_STATE:-New}"

AZURE_DEVOPS_URL="https://dev.azure.com/${AZURE_BOARDS_ORGANIZATION}/"
vsts configure --defaults instance="${AZURE_DEVOPS_URL}" project="${AZURE_BOARDS_PROJECT}"

vsts login --token "${AZURE_BOARDS_TOKEN}"

GITHUB_EVENT=$(jq --raw-output 'if .comment != null then "comment" else empty end' "$GITHUB_EVENT_PATH")
GITHUB_EVENT=${GITHUB_EVENT:-$(jq --raw-output 'if .issue != null then "issue" else empty end' "$GITHUB_EVENT_PATH")}

GITHUB_ACTION=$(jq --raw-output .action "$GITHUB_EVENT_PATH")
GITHUB_ISSUE_NUMBER=$(jq --raw-output .issue.number "$GITHUB_EVENT_PATH")
AZURE_BOARDS_TITLE=$(jq --raw-output .issue.title "$GITHUB_EVENT_PATH")
AZURE_BOARDS_DESCRIPTION=$(jq --raw-output .issue.body "$GITHUB_EVENT_PATH")

TRIGGER="${GITHUB_EVENT}/${GITHUB_ACTION}"

echo $TRIGGER
echo "labels: ${ITEM_LABEL}"
cat $GITHUB_EVENT_PATH

case "$TRIGGER" in
"issue/opened")
    # If we're limiting ourselves to GitHub issues that have a particular
    # label, ignore the 'opened' action; we'll get a subsequent 'labeled'
    # action.
    if [ ! -z "$ITEM_LABEL" ]; then
        exit
    fi

    create_work_item
    ;;

"issue/labeled")
    if [ -z "$ITEM_LABEL" ]; then
        exit
    fi

    if [ ! check_github_label ]; then
        echo "Issue ${GITHUB_ISSUE_NUMBER} does not have a label (${ITEM_LABEL}) set; ignoring."
        exit
    fi

    echo "Looking for existing work items with tag 'Issue ${GITHUB_ISSUE_NUMBER}'..."

    if [ "${IDS}" = "" ]; then
        create_work_item
    fi
    ;;

"issue/reopened"|"issue/closed")
    [[ "$GITHUB_ACTION" = "reopened" ]] && \
        NEW_STATE="$AZURE_BOARDS_REOPENED_STATE" || \
        NEW_STATE="$AZURE_BOARDS_CLOSED_STATE"

    echo "Looking for work items with tag 'Issue ${GITHUB_ISSUE_NUMBER}'..."
    IDS=$(work_items_for_issue)

    for ID in ${IDS}; do
        echo "Setting work item ${ID} to state ${NEW_STATE}..."
        RESULTS=$(vsts work item update --id "$ID" --state "$NEW_STATE")

        RESULT_STATE=$(echo "${RESULTS}" | jq --raw-output '.fields["System.State"]')
        echo "Work item ${ID} is now ${RESULT_STATE}"
    done
    ;;

"comment/created")
    echo "Looking for work items with tag 'Issue ${GITHUB_ISSUE_NUMBER}'..."
    IDS=$(work_items_for_issue)

    for ID in ${IDS}; do
        HEADER="Comment from @$(jq --raw-output .comment.user.login "$GITHUB_EVENT_PATH"): "
        BODY=$(jq --raw-output .comment.body "$GITHUB_EVENT_PATH")

        echo "Adding comment to work item ${ID}..."
        RESULTS=$(vsts work item update --id "$ID" --discussion "${HEADER}${BODY}")
    done
    ;;
esac

