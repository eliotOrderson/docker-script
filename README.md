# docker-script
docker pull may repeatedly download images due to network issues. Therefore, I wrote this script using skopeo and aria2c to enable resumable downloads of image layers, and then import them into Docker.


# Usage 
``` shell
Usage: ./docker-images-download.sh [OPTIONS] IMAGE_NAME
Download Docker images using skopeo and aria2c with segmented downloading

Options:
  -d, --dir               Output directory for downloaded blobs (default: ./docker-blobs)
  -v, --verbose           Enable verbose output
  -c, --connections       N  Number of connections for segmented downloading (default: 1)
  -arch, --architecture   select images architecture (default: amd64)
  -h, --help              Show this help message

Example: ./docker-images-download.sh -d docker-layers -v -c 4 alpine:latest
```
