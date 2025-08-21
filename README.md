# docker-script
docker pull may repeatedly download images due to network issues. Therefore, I wrote this script using skopeo and aria2c to enable resumable downloads of image layers, and then import them into Docker.
