#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
AXIOM_PATH="$(dirname "$SCRIPT_DIR")" # Assumes gcp.sh is in interact/account-helpers/
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

check_and_create_firewall_rule() {
    firewall_rule_name="axiom-ssh"
    expected_target_tag="axiom-ssh"

    # Check if the firewall rule exists
    rule_exists=$(gcloud compute firewall-rules list --filter="name=$firewall_rule_name" --format="value(name)")

    if [[ -z "$rule_exists" ]]; then
        echo "Firewall rule '$firewall_rule_name' does not exist. Creating it now..."

        # Create the firewall rule to allow SSH (port 2266)
        gcloud compute firewall-rules create "$firewall_rule_name" \
            --allow tcp:2266 \
            --direction INGRESS \
            --priority 1000 \
            --target-tags "$expected_target_tag" \
            --description "Allow SSH traffic" \
            --quiet

        echo "Firewall rule '$firewall_rule_name' created successfully."
    else
        echo "Firewall rule '$firewall_rule_name' already exists."

        # Check the current target tags
        current_target_tag=$(gcloud compute firewall-rules describe "$firewall_rule_name" --format="value(targetTags)")

        if [[ "$current_target_tag" != *"$expected_target_tag"* ]]; then
            echo "Target tag is not set to '$expected_target_tag'. Updating the firewall rule..."

            # Update the firewall rule to set the correct target tag
            gcloud compute firewall-rules update "$firewall_rule_name" \
                --target-tags="$expected_target_tag" \
                --quiet

            echo "Firewall rule '$firewall_rule_name' updated with the correct target tag '$expected_target_tag'."
        else
            echo "Firewall rule '$firewall_rule_name' already has the correct target tag '$expected_target_tag'."
        fi
    fi
}

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

# Function to check billing and API enablement after authentication
function check_gcp_billing_and_apis() {
    project_id=$(gcloud config get-value project)

    echo "Checking if billing is enabled for project [$project_id]..."

    # Check if billing is enabled
    billing_info=$(gcloud beta billing projects describe "$project_id" --format="value(billingEnabled)")
    if [[ "$billing_info" != "True" ]]; then
        echo -e "${BRed}Billing is not enabled for project [$project_id]. Please enable billing to proceed.${Color_Off}"
        echo -e "Visit https://console.cloud.google.com/billing to enable billing."
        exit 1
    fi

    # Check if necessary APIs are enabled
    echo "Checking if Cloud Resource Manager, Compute and Storage APIs are enabled..."
    gcloud services enable storage-api.googleapis.com
    gcloud services enable cloudresourcemanager.googleapis.com
    gcloud services enable compute.googleapis.com

    echo "APIs have been enabled. This may take a few minutes to propagate."
}

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


function gcp_setup() {
    echo -e "${BGreen}Authenticating with Application Default Credentials (ADC)...${Color_Off}"
    gcloud auth application-default login

    # Set the project ID (ADC should handle this, but we'll keep the function for consistency)
    set_project_id

    # Check if billing is enabled and APIs are activated after authentication
    check_gcp_billing_and_apis

    # Proceed to region and zone setup
    echo -e -n "${Green}Listing available regions: \n${Color_Off}"
    gcloud compute regions list

    default_region="us-central1"
    echo -e -n "${Green}Please enter your default region (you can always change this later with axiom-region select \$region): Default '$default_region', press enter \n>> ${Color_Off}"
    read region
    if [[ "$region" == "" ]]; then
        echo -e "${Blue}Selected default option '$default_region'${Color_Off}"
        region="$default_region"
    fi

    echo -e -n "${Green}Listing available zones for region: $region \n${Color_Off}"

    zones=$(gcloud compute zones list | grep $region | cut -d ' ' -f 1 | sort)
    echo "$zones" | tr ' ' '\n'
    default_zone="$(echo $zones | tr ' ' '\n' | head -n 1)"
    echo -e -n "${Green}Please enter your default zone:  Default '$default_zone', press enter \n>> ${Color_Off}"
    read zone
    if [[ "$zone" == "" ]]; then
        echo -e "${Blue}Selected default option '${default_zone}'${Color_Off}"
        zone="${default_zone}"
    fi
    echo -e "${BGreen}Available GCP machine types for zone: $zone${Color_Off}"

    default_size_search=n1-standard-1
    # List available machine types in the selected zone
    gcloud compute machine-types list --zones $zone --format="table(name, description)" | tee /tmp/gcp-machine-types.txt

    echo -e -n "${Green}Please enter the machine type: Default '$default_size_search', press enter \n>> ${Color_Off}"
    read machine_type

    # Validate the machine type
    while ! grep -q "^$machine_type" /tmp/gcp-machine-types.txt; do
        echo -e "${BRed}Invalid machine type. Please select a valid machine type from the list.${Color_Off}"
        echo -e -n "${Green}Please enter the machine type (e.g. 'n1-standard-1'): ${Color_Off}"
        read machine_type
    done

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

    check_and_create_firewall_rule

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
