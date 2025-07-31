#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
AXIOM_PATH="$(dirname "$(dirname "$SCRIPT_DIR")")" # Assumes gcp.sh is in interact/account-helpers/
source "$AXIOM_PATH/interact/includes/vars.sh"

region=""
zone=""
provider="gcp"

BASEOS="$(uname)"
case $BASEOS in
'Linux')
    BASEOS='Linux'
    ;;
'FreeBSD')
    BASEOS='FreeBSD'
    alias ls='ls -G'
    ;;
'WindowsNT')
    BASEOS='Windows'
    ;;
'Darwin')
    BASEOS='Mac'
    ;;
'SunOS')
    BASEOS='Solaris'
    ;;
'AIX') ;;
*) ;;
esac


# Function to clean up duplicate repository entries
function clean_gcloud_repos() {
    # Remove duplicate entries from google-cloud-sdk.list
    if [[ -f /etc/apt/sources.list.d/google-cloud-sdk.list ]]; then
        echo "Cleaning up duplicate entries in google-cloud-sdk.list..."
        sudo awk '!seen[$0]++' /etc/apt/sources.list.d/google-cloud-sdk.list > /tmp/google-cloud-sdk.list
        sudo mv /tmp/google-cloud-sdk.list /etc/apt/sources.list.d/google-cloud-sdk.list
    fi
}

# Check if gcloud CLI is installed and up to date
installed_version=$(gcloud version 2>/dev/null | grep 'Google Cloud SDK' | cut -d ' ' -f 4)
if [[ "$(printf '%s\n' "$installed_version" "$GCloudCliVersion" | sort -V | head -n 1)" != "$GCloudCliVersion" ]]; then
    echo -e "${Yellow}gcloud CLI is either not installed or version is lower than the recommended version in ~/.axiom/interact/includes/vars.sh${Color_Off}"
    echo "Installing/updating gcloud CLI to version $GCloudCliVersion..."

    sudo apt update && sudo apt-get install apt-transport-https ca-certificates gnupg curl -qq -y
    # Add the Google Cloud GPG key and fix missing GPG key issue
    echo "Adding the Google Cloud public key..."
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

    # Add the correct repository entry for Google Cloud SDK
    echo "Adding Google Cloud SDK to sources list..."
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

    # Clean up duplicate entries
    clean_gcloud_repos

    # Update package list and install Google Cloud SDK
    sudo apt-get update -qq
    sudo apt-get install google-cloud-sdk -y -qq
    echo "Installing Packer Plugin..."
    packer plugins install github.com/hashicorp/googlecompute
fi

# Function to check and set project ID
function set_project_id() {
    echo -e -n "${Green}Please enter your GCP Project ID (required): \n>> ${Color_Off}"
    read -p "Enter Project ID: " project_id

    while [[ -z "$project_id" ]]; do
        echo -e "${BRed}Project ID cannot be empty. Please enter your GCP Project ID:${Color_Off}"
        read -p "Enter Project ID: " project_id
    done

    # Set the project ID using gcloud
    if [[ -n "$project_id" ]]; then
        echo "Setting project ID to [$project_id]..."
        gcloud config set project "$project_id"
    else
        echo -e "${BRed}No valid project ID provided. Exiting.${Color_Off}"
        exit 1
    fi
}


# Function to detect if running on a GCP Compute Engine VM
is_gcp_vm() {
    # Cache the result of the metadata server check
    if [[ -z "$_IS_GCP_VM_CACHED" ]]; then
        curl -s -f -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/id &> /dev/null
        _IS_GCP_VM_RESULT=$?
        _IS_GCP_VM_CACHED="true"
    fi
    return $_IS_GCP_VM_RESULT
}

# Set IS_GCP_VM globally based on the result of is_gcp_vm
if is_gcp_vm; then
    IS_GCP_VM="true"
else
    IS_GCP_VM="false"
fi

function gcp_setup() {
    if [[ "$IS_GCP_VM" == "true" ]]; then
        echo -e "${BGreen}Running on a GCP Compute Engine VM. Using VM's service account for ADC.${Color_Off}"
        # No need to run gcloud auth application-default login
    else
        echo -e "${BGreen}Authenticating with Application Default Credentials (ADC)...${Color_Off}"
        gcloud auth application-default login
    fi

    # Set the project ID (ADC should handle this, but we'll keep the function for consistency)
    if [[ "$IS_GCP_VM" == "true" ]]; then
        # If on a GCP VM, try to get project ID from metadata server
        project_id=$(curl -s -f -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
        echo -e "${BGreen}Got [$project_id] from metadata.${Color_Off}"
    else
        set_project_id # Always prompt if not on a GCP VM
    fi

    # Proceed to region and zone setup
    echo -e -n "${Green}Please enter your default region (e.g., us-central1, us-east1, europe-west1): Default 'us-central1', press enter \n>> ${Color_Off}"
    read region
    if [[ "$region" == "" ]]; then
        echo -e "${Blue}Selected default option 'us-central1'${Color_Off}"
        region="us-central1"
    fi

    default_zone="us-central1-a"
    echo -e -n "${Green}Please enter your default zone (e.g., us-central1-a, us-east1-b, europe-west1-c): Default '$default_zone', press enter \n>> ${Color_Off}"
    read zone
    if [[ "$zone" == "" ]]; then
        echo -e "${Blue}Selected default option '${default_zone}'${Color_Off}"
        zone="${default_zone}"
    fi
    default_size_search="n1-standard-1"
    echo -e -n "${Green}Please enter the machine type (e.g., n1-standard-1, e2-medium, c2-standard-4): Default '$default_size_search', press enter \n>> ${Color_Off}"
    read machine_type

    # Save the selected machine type in axiom.json
    if [[ "$machine_type" == "" ]]; then
        echo -e "${Blue}Selected default option 'n1-standard-1'${Color_Off}"
        machine_type="$default_size_search"
    else
        echo -e "${BGreen}Selected machine type: $machine_type${Color_Off}"
    fi

    # Prompt for default disk size
    echo -e -n "${Green}Please enter your default disk size in GB (10–65536) (you can always change this later with axiom-disks select \$size): Default '20', press enter \n>> ${Color_Off}"
    read disk_size

    # Validate or set default
    if [[ -z "$disk_size" ]]; then
        disk_size="20"
        echo -e "${Blue}Selected default option '20GB'${Color_Off}"
    fi

    # Check if disk_size is a valid number and in range
    while ! [[ "$disk_size" =~ ^[0-9]+$ ]] || (( disk_size < 10 || disk_size > 65536 )); do
        echo -e "${BRed}Invalid disk size. Please enter a number between 10 and 65536.${Color_Off}"
        echo -e -n "${Green}Please enter your default disk size in GB:\n>> ${Color_Off}"
        read disk_size
    done

    # IMPORTANT: Firewall rules (e.g., for SSH on port 2266) must be configured manually
    # in your GCP project. This script no longer attempts to create or manage them
    # due to minimal service account permissions. Ensure appropriate firewall rules
    # are in place for Axiom to function correctly.

    # Generate the profile data with the correct keys
    data="$(echo "{\"project\":\"$project_id\",\"physical_region\":\"$region\",\"default_size\":\"$machine_type\",\"region\":\"$zone\",\"provider\":\"gcp\",\"default_disk_size\":\"$disk_size\"}")"

    echo -e "${BGreen}Profile settings below: ${Color_Off}"
    echo "$data" | jq
    echo -e "${BWhite}Press enter if you want to save these to a new profile, type 'r' if you wish to start again.${Color_Off}"
    read ans

    if [[ "$ans" == "r" ]]; then
        $0
        exit
    fi

    echo -e -n "${BWhite}Please enter your profile name (e.g. 'gcp', must be all lowercase/no specials)\n>> ${Color_Off}"
    read title

    if [[ "$title" == "" ]]; then
        title="gcp"
        echo -e "${BGreen}Named profile 'gcp'${Color_Off}"
    fi

    # Save the profile data in axiom.json
    echo "$data" | jq > "$AXIOM_PATH/accounts/$title.json"
    echo -e "${BGreen}Saved profile '$title' successfully!${Color_Off}"
    $AXIOM_PATH/interact/axiom-account $title
}

gcp_setup
