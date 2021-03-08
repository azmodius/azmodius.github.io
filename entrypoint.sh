#!/bin/bash 

echo "Running bundle install..."
bundle install

echo "Running bundle update github-pages"
bundle update github-pages

echo "Running bundle update..."
bundle update

echo "Starting jekyll..."
bundle exec jekyll serve --watch --incremental --config _config.yml --host 0.0.0.0