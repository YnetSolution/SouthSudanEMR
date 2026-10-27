# syntax=docker/dockerfile:1.3
#--------------------------------------------
# Dev Stage - Assembles and Builds Frontend
#--------------------------------------------
FROM --platform=$BUILDPLATFORM node:22-alpine as dev

# Pinned to match the `@openmrs/esm-framework: 10.x` peer dependency of the modules in
# spa-assemble-config.json. Do NOT use `next` - it tracks unreleased core majors (11.x)
# which break the pinned apps (React error #130, duplicate workspace registrations).
ARG APP_SHELL_VERSION=10.0.0

RUN mkdir -p /app
WORKDIR /app

COPY spa-assemble-config.json .
COPY spa-build-config.json .
COPY /assets /app/assets
COPY proxy.js .

RUN echo "@ssemrapp:registry=http://127.0.0.1:4873/ynetsolutions/npm/" > .npmrc && \
    echo "//127.0.0.1:4873/ynetsolutions/npm/:_authToken=rdt-AYA2VhmQ6oI-ze6HiZzOHIdA7NdvqxAm9SaKEeQh0xI" >> .npmrc && \
    echo "registry=https://registry.npmjs.org/" >> .npmrc

ARG CACHE_BUST
RUN npm install -g npm@latest

RUN node proxy.js & PROXY_PID=$! ; \
    sleep 2 ; \
    npx --legacy-peer-deps openmrs@${APP_SHELL_VERSION:-next} assemble --manifest --mode config --config spa-assemble-config.json --target ./spa && \
    npx --legacy-peer-deps openmrs@${APP_SHELL_VERSION:-next} build --build-config spa-build-config.json --target ./spa && \
    kill $PROXY_PID

# Copying required files
RUN echo "Copying required files ..." && \
    cp ./assets/login-icon.png ./spa && \
    cp ./assets/careconnect-logo.png ./spa && \
    cp ./assets/login-background.jpg ./spa && \
    cp ./assets/primary-navigation.png ./spa && \
    cp ./assets/favicon.ico ./spa && \
    cp spa-build-config.json ./spa

# Check build result
RUN if [ ! -f ./spa/index.html ]; then echo 'Build failed. Please check the logs above for details. This may have happened because of an update to a library that OpenMRS depends on.'; exit 1; fi

# Modify page title
# NOTE: newer app-shell builds emit a minified, single-line index.html that also
# contains a <title> inside the loading spinner SVG. A greedy `.*` would match from
# the page <title> all the way to the SVG's </title>, deleting the openmrs.js
# <script>, stylesheets and <body> (blank SPA). `[^<]*` only replaces the first,
# real page title.
RUN sed -i 's/<title>[^<]*<\/title>/<title>SSEMR<\/title>/' ./spa/index.html && \
    grep -q 'openmrs\.[^"]*\.js' ./spa/index.html || { echo 'index.html is missing the app shell script'; exit 1; }

FROM nginx:1.23-alpine

RUN apk update && \
    apk upgrade && \
    # add more utils for sponge and envsubst
    apk add --no-cache moreutils

# clear any default files installed by nginx
RUN rm -rf /usr/share/nginx/html/*

COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

COPY nginx.conf /etc/nginx/nginx.conf

COPY --from=dev /app/spa /usr/share/nginx/html
COPY config.json /usr/share/nginx/html

CMD ["/usr/local/bin/startup.sh"]
