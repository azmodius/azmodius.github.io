#!/bin/bash 

bundle install && bundle update github-pages && bundle update && bundle exec jekyll serve --watch --incremental --config _config.yml --host 0.0.0.0
