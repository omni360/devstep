#!/bin/bash
set -eo pipefail

project_root=${1:-/workspace}
cache_root=${2:-/.devstep/cache}
buildpack_root=/.devstep/buildpacks

mkdir -p $project_root
mkdir -p $cache_root
mkdir -p $buildpack_root
mkdir -p /.devstep/.profile.d

function output_redirect() {
	if [[ "$slug_file" == "-" ]]; then
		cat - 1>&2
	else
		cat -
	fi
}

function echo_title() {
  echo $'\e[1G----->' $* | output_redirect
}

function echo_normal() {
  echo $'\e[1G      ' $* | output_redirect
}

function ensure_indent() {
  while read line; do
    if [[ "$line" == --* ]]; then
      echo $'\e[1G'$line | output_redirect
    else
      echo $'\e[1G      ' "$line" | output_redirect
    fi
  done
}

# Centralize cache directories on a single place to simplify
# caching on the host

if ! [ -L /var/cache/apt/archives ]; then
  mkdir -p $cache_root/apt
  # TODO: Use a cache warm up approach similar to vagrant-cachier's
  sudo rm -rf /var/cache/apt/archives
  sudo ln -s $cache_root/apt /var/cache/apt/archives
fi

if ! [ -L /var/lib/apt/lists ]; then
  mkdir -p $cache_root/apt-lists
  # TODO: Use a cache warm up approach similar to vagrant-cachier's
  sudo rm -rf /var/lib/apt/lists
  sudo ln -s $cache_root/apt-lists /var/lib/apt/lists
fi

# In heroku, there are two separate directories, and some
# buildpacks expect that.
# TODO: Figure out if this is needed
# cp -r $project_dir/. $build_root

## Buildpack fixes

export REQUEST_ID=$(openssl rand -base64 32 2>/dev/null)
export APP_DIR="$project_root"
# export HOME="$project_root"

## Fix directory permissions

(cd $project_root && /usr/bin/fix-permissions)

## Buildpack detection

if [[ -z "$BUILDPACKS" ]]; then
  buildpacks=($buildpack_root/*)
  declare -a selected_buildpacks
  for buildpack in "${buildpacks[@]}"; do
    if $($buildpack/bin/detect "${project_root}" &>/dev/null); then
      selected_buildpacks=("${selected_buildpacks[@]}" $buildpack)
    fi
  done
else
  declare -a selected_buildpacks
  for buildpack in "${BUILDPACKS[@]}"; do
    selected_buildpacks=("${selected_buildpacks[@]}" ${buildpack_root}/${buildpack})
  done
fi

## Compile!

if [[ -n "$selected_buildpacks" ]]; then
  # TODO: This output is not needed if a single buildpack was detected
  echo_title "Building project at '${project_root}' with the folllowing buildpacks:"
  for bp in "${selected_buildpacks[@]}"; do
    echo "- $bp" | ensure_indent
  done
else
  echo_title "Unable to identify a buildpack for your project!"
  exit 0
fi

for bp in "${selected_buildpacks[@]}"; do
  echo_title "Building with $bp"
  $bp/bin/compile "$project_root" "$cache_root" | ensure_indent
done

echo_title "Build finished successfully!"

## Save on disk space if wanted

if [ "${CLEANUP}" = '1' ]; then
  echo_title 'Cleaning up...'

  # TODO: We can't do this yet because the golang buildpack stores things on this dir
  # echo_normal "Running 'rm -rf $cache_root/*'"
  # rm -rf $cache_root/*

  echo_normal "Running 'sudo rm -rf tmp/*'"
  sudo rm -rf /tmp/*
fi
