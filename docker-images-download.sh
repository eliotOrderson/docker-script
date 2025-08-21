#!/bin/bash

# docker-download.sh - Download Docker images using skopeo and aria2c with segmented downloading

set -euo pipefail

# Default values
ARCH=amd64
VERBOSE=false
CACHE_TIME=300
OUTPUT_DIR="./docker-blobs"
CONNECTIONS=1

# Function to print usage
usage() {
    echo "Usage: $0 [OPTIONS] IMAGE_NAME"
    echo "Download Docker images using skopeo and aria2c with segmented downloading"
    echo ""
    echo "Options:"
    echo "  -d, --dir               Output directory for downloaded blobs (default: $OUTPUT_DIR)"
    echo "  -v, --verbose           Enable verbose output"
    echo "  -c, --connections       N  Number of connections for segmented downloading (default: $CONNECTIONS)"
    echo "  -arch, --architecture   select images architecture (default: $ARCH)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Example: $0 -d docker-layers -v -c 4 alpine:latest"
    exit 1
}

check_args() {
    if [[ -z "$1" ]]; then
        echo "Error: $2 requires a argument."
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    -d | --dir)
        check_args "$2" "-d | --dir"
        OUTPUT_DIR="$2"
        shift 2
        ;;
    -arch | --architecture)
        check_args "$2" "-arch | --architecture"
        ARCH="$2"
        shift 2
        ;;
    -c | --connections)
        check_args "$2" "-c | --connections"
        CONNECTIONS="$2"
        shift 2
        ;;
    -v | --verbose)
        VERBOSE=true
        shift
        ;;
    -h | --help)
        usage
        ;;
    --)
        shift
        break
        ;;
    *)
        break
        ;;
    esac
done

# Check if image name is provided
if [ -z "${1:-}" ]; then
    echo "Error: Image name is required" >&2
    usage
fi

IMAGE_NAME="$1"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to log messages
log() {
    if [ "$VERBOSE" = true ]; then
        echo "[INFO] $*" >&2
    fi
}

err() {
    if [ "$VERBOSE" = true ]; then
        echo "[ERRO] $*" >&2
    fi
}

cached_run() {
    local key="$1"
    local ttl="$2"
    shift 2
    local cmd=("$@")

    local cache_dir="/tmp/shell_cache"
    mkdir -p "$cache_dir"
    local cache_file="$cache_dir/$(echo "$key" | md5sum | cut -d' ' -f1)"

    # check cache whether has useful
    if [ -f "$cache_file" ] && [ $(date +%s) -lt $(($(stat -c %Y "$cache_file") + ttl)) ]; then
        log "Using cache get $key"
        cat "$cache_file"
        return 0
    fi

    result=$("${cmd[@]}")
    if [ $? -ne 0 ]; then
        rm -f "$cache_file.tmp"
        err "Run the cmd error: ${cmd[@]}"
        exit 1
    else
        echo $result >$cache_file.tmp
        log "Cache the $key"
        mv "$cache_file.tmp" "$cache_file"
        cat "$cache_file"
    fi
}

# Function to get Bearer token for Docker registry
get_bearer_token() {
    local image_name="$1"
    local registry="registry-1.docker.io"

    # Extract repository and image from full name
    if [[ "$image_name" == */* ]]; then
        repo_image="$image_name"
    else
        repo_image="library/$image_name"
    fi

    # Get token from Docker auth service
    log "Fetching Bearer token for $repo_image"

    # Extract repository name without tag for scope
    local repo_name=$(echo "$repo_image" | sed 's/:.*//' | sed 's/@.*//')

    # Build the scope parameter
    local scope="repository:$repo_name:pull"

    # Get token from Docker auth service
    local token_response
    token_response=$(
        curl -s \
            --connect-timeout 30 \
            --max-time 60 \
            "https://auth.docker.io/token?service=registry.docker.io&scope=$scope"
    )
    if [ -z "$token_response" ]; then
        err "Get token response with curl, please check network connection"
        return 1
    fi

    # Check if response contains error
    if echo "$token_response" | grep -q "error"; then
        err "Error from auth service: $token_response"
        return 1
    fi

    # Extract token from response (try both 'token' and 'access_token' fields)
    local token=""
    token=$(echo "$token_response" | jq -r '.token // .access_token')
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        err "Failed to extract token from response"
        err "$token_response"
        return 1
    fi

    summary_token=$(echo $token | head --bytes=20)
    log "Got token: $summary_token..."

    echo "$token"
}

# Function to get image manifest
get_manifest() {
    local image_name="$1"
    shift 1
    local skopeo_args=($@)

    log "Fetching manifest for $image_name"

    # Use skopeo to get the manifest
    local manifest
    manifest=$(skopeo inspect "docker://$image_name" ${skopeo_args[@]})
    if [ -z "$manifest" ]; then
        err "Get manifest for $image_name error, please check network connection"
        return 1
    fi

    # Validate that we have valid JSON
    if ! echo "$manifest" | jq -e . >/dev/null 2>&1; then
        err "Invalid JSON response from skopeo"
        return 1
    fi

    echo "$manifest"
}

# Function to download blob using aria2c
download_blob() {
    local registry="$1"
    local repository="$2"
    local digest="$3"
    local output_file="$4"
    local token="$5"

    local blob_url="https://$registry/v2/$repository/blobs/$digest"

    log "Downloading blob $digest to $output_file"

    # First, get the redirect URL using curl with the Bearer token
    log "Getting redirect URL for blob $digest"

    set +e
    response=$(curl -s -f -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -I "$blob_url")
    if [ $? -ne 0 ]; then
        err "Get redirect URL for blob $digest, please check network connection"
        return 1
    fi
    set -e

    redirect_url=$(echo "$response" | grep "^location:" | sed -E 's/^location: ([^\r]+).*/\1/')
    log "Following redirect to $redirect_url"

    # Use aria2c to download from the redirect URL without Authorization header
    aria2c \
        --header="User-Agent: docker-download-script/1.0" \
        --continue=true \
        --split=$CONNECTIONS \
        --max-connection-per-server=8 \
        --min-split-size=1M \
        --dir="$(dirname "$output_file")" \
        --out="$(basename "$output_file")" \
        "$redirect_url"

    if [ $? -ne 0 ]; then
        err "Download blob $digest, network connection error"
        return 1
    fi
}

# Main execution
main() {
    log "Starting download of $IMAGE_NAME"

    # Get Bearer token
    token=$(cached_run "get_bearer_token" $CACHE_TIME get_bearer_token "$IMAGE_NAME")

    # Get manifest
    manifest=$(cached_run "get_manifest" $CACHE_TIME get_manifest $IMAGE_NAME)

    # Extract repository name (without tag)
    local repository
    local image_with_tag="$IMAGE_NAME"

    # Remove tag if present (everything after : or @)
    local image_without_tag
    image_without_tag=$(echo "$image_with_tag" | sed 's/:.*//' | sed 's/@.*//')

    # Handle repository format
    if [[ "$image_without_tag" == */* ]]; then
        repository="$image_without_tag"
    else
        repository="library/$image_without_tag"
    fi

    # Extract the registry (default to docker.io)
    local registry="registry-1.docker.io"

    # Parse manifest to get layers
    local layers
    layers=$(echo "$manifest" | jq -r '.Layers[]')

    if [ -z "$layers" ]; then
        err "No layers found in manifest"
        exit 1
    fi

    # Download each layer (blob)
    local layer_count=0
    for digest in $layers; do
        layer_count=$((layer_count + 1))
        local output_file="$OUTPUT_DIR/$(echo "$digest" | sed 's/sha256://')"

        download_blob "$registry" "$repository" "$digest" "$output_file" "$token"
        if [ $? -ne 0 ]; then
            err "Download layer $layer_count error"
            exit 1
        fi
    done
    log "Successfully downloaded $layer_count layers"

}

# Run main function with all arguments
main "$@"

manifests_raw=$(cached_run "raw-manifests" $CACHE_TIME get_manifest $IMAGE_NAME --raw)
digest=$(echo $manifests_raw | jq -r '.manifests[] | select(.platform.architecture =='\"$ARCH\"' and .platform.os == "linux") | .digest')

log "skopeo oci manifest hash name: ${digest##*:}"

image_pkg_name="${IMAGE_NAME%%:*}"
image_pkg_version="${IMAGE_NAME##*:}"

skopeo_oci_manifest=$(cached_run "skopeo-oci-manifest" $CACHE_TIME get_manifest "$image_pkg_name@$digest" --raw)
echo $skopeo_oci_manifest >$OUTPUT_DIR/manifest.json
echo "Directory Transport Version: 1.1" >$OUTPUT_DIR/version

skopeo_oci_config=$(cached_run "skopeo-oci-config" $CACHE_TIME get_manifest $IMAGE_NAME --raw --config)
skopeo_oci_config_name=$(echo $skopeo_oci_manifest | jq -r '.config .digest | sub("^sha256:"; "")')
echo -n $skopeo_oci_config >$OUTPUT_DIR/$skopeo_oci_config_name

log "skopeo oci format generate complete"
log 'Use the cmd load to docker: skopeo copy' dir:$OUTPUT_DIR docker-daemon:$IMAGE_NAME
