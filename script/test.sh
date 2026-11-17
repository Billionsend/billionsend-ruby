#!/bin/sh
# Runs the checks in the pinned Ruby image (podman or docker), the same as CI.
set -eu
image=docker.io/library/ruby:3.4.7-slim
runtime=$(command -v podman || command -v docker)
exec "$runtime" run --rm -v "$PWD:/w:Z" -v billionsend-ruby-gems:/usr/local/bundle -w /w "$image" \
  sh -c 'bundle install --quiet && bundle exec rake'
