# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a bash script `docker-images-download.sh` that provides an alternative to `docker pull` for downloading Docker images. The script uses `skopeo` and `aria2c` to enable resumable downloads of image layers, which is particularly useful for unreliable network connections.

## Key Commands

### Running the Script
```bash
# Basic usage
./docker-images-download.sh alpine:latest

# With custom output directory and verbose output
./docker-images-download.sh -d docker-layers -v -c 4 alpine:latest

# For specific architecture
./docker-images-download.sh -arch arm64 nginx:latest
```

### Loading Downloaded Images
After downloading, use skopeo to load the image into Docker:
```bash
skopeo copy dir:./docker-blobs docker-daemon:alpine:latest
```

## Architecture

### Main Components

1. **Authentication & Token Management** (`get_bearer_token` function):
   - Handles Docker Hub authentication using Bearer tokens
   - Supports both library and custom repositories
   - Implements token caching with configurable TTL

2. **Manifest Handling** (`get_manifest` function):
   - Uses `skopeo inspect` to fetch image manifests
   - Supports both regular and raw manifest formats
   - Implements JSON validation

3. **Layer Download** (`download_blob` function):
   - Downloads individual image layers using `aria2c`
   - Supports segmented downloading for improved performance
   - Handles HTTP redirects and authentication

4. **Caching System** (`cached_run` function):
   - Implements shell command caching with TTL
   - Reduces redundant API calls and network requests
   - Uses MD5 hashing for cache keys

### Dependencies

The script requires these external tools:
- `skopeo`: For container image operations
- `aria2c`: For segmented downloading
- `curl`: For HTTP requests and authentication
- `jq`: For JSON parsing
- `bash`: Shell execution (requires bash 4+)

### File Structure

```
.
├── docker-images-download.sh    # Main script
├── README.md                   # Usage documentation
├── LICENSE                     # MIT License
├── .gitignore                  # Git ignore rules
├── alpine-docker/              # Example downloaded image (sample output)
│   ├── manifest.json          # OCI manifest
│   ├── version                # Directory transport version
│   └── [blob files]           # Downloaded layer blobs
└── .mcp.json                  # MCP server configuration
```

## Key Features

- **Resumable Downloads**: Uses aria2c's continue functionality
- **Segmented Downloading**: Configurable number of connections for faster downloads
- **Authentication**: Proper Bearer token handling for Docker Hub
- **Architecture Support**: Can download images for different CPU architectures
- **Caching**: Reduces redundant API calls with smart caching
- **Error Handling**: Comprehensive error checking and logging
- **OCI Format**: Outputs images in standard OCI format for compatibility

## Script Configuration

The script accepts these command-line options:
- `-d, --dir`: Output directory for downloaded blobs (default: ./docker-blobs)
- `-v, --verbose`: Enable verbose output
- `-c, --connections`: Number of connections for segmented downloading (default: 1)
- `-arch, --architecture`: Select image architecture (default: amd64)
- `-h, --help`: Show help message

## Error Handling

The script implements strict error handling with `set -euo pipefail` and includes:
- Network timeout handling
- Authentication error detection
- JSON validation
- File existence checks
- Download failure recovery