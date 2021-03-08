azmodius.github.io
---

Instructions for setting up Jekyll with a docker container for dev here!
- https://medium.com/@sebagomez/setting-up-a-github-page-with-jekyll-and-a-docker-container-c712e448649b
- https://takacsmark.com/how-to-set-up-docker-container-for-your-github-pages-jekyll-site/#making-it-work
- https://ddewaele.github.io/running-jekyll-in-docker/
- https://docs.github.com/en/github/working-with-github-pages/testing-your-github-pages-site-locally-with-jekyll
- https://www.moncefbelyamani.com/the-beginner-s-guide-to-bundler-and-gemfiles/

Run
--
create new jekyll to start with
- ```docker run --rm --volume="${pwd}:/srv/jekyll" -it jekyll/jekyll jekyll new .```
- delete all other files generated but keep the `Gemfile`
- ```docker-compose up -d```

