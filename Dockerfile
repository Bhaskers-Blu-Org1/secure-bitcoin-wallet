##############################################################################
# Copyright 2020 IBM Corp. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
##############################################################################
FROM node:10.16.0-stretch-slim AS node

FROM python:3.7-slim-stretch

COPY --from=node /usr/local /usr/local

ARG GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=1

ARG NO_GRPC_BUILD

RUN apt-get update && \
# install python and other additional packages
    apt-get install -y --no-install-recommends ca-certificates curl && \
    apt-get install -y --no-install-recommends git python3-pip python3-dev build-essential python3-setuptools python3-wheel protobuf-compiler libssl-dev libffi-dev autoconf automake libtool && \
    apt-get install -y --no-install-recommends php apache2 xz-utils libedit2 vim && \
    apt-get install -y --no-install-recommends sqlite3 libsqlite3-dev libpng-dev libzip-dev python php-zip && \
    apt-get install -y --no-install-recommends php-mbstring php-xml php-sqlite3 unzip && \
    apt-get install -y --no-install-recommends supervisor && \
# clean up
    apt-get -y autoremove && apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/tmp/* /git/grpc

###################################################################################

ARG ELECTRUM_TAG="local-3.3.6-hpcs"

ENV NETWORK "--testnet"
# ENV ELECTRUM_USER electrum
# ENV ELECTRUM_HOME /home/$ELECTRUM_USER
ENV ELECTRUM_USER root
ENV ELECTRUM_HOME /$ELECTRUM_USER
ENV ELECTRUM_PASSWORD passw0rd
ENV ELECTRUM_DIR /git/electrum

# Add user electrum
# RUN adduser --home $ELECTRUM_HOME --uid 2000 --disabled-password --disabled-login $ELECTRUM_USER

WORKDIR /git
ADD pyep11 /git/pyep11
RUN git clone https://github.com/tnakaike/electrum.git && \
    cd /git/electrum && \
    git checkout ${ELECTRUM_TAG} && \
    pip3 uninstall -y enum34 && \
    pip3 install . && \
    protoc --proto_path=electrum --python_out=electrum electrum/paymentrequest.proto && \
    cd /git/pyep11 && \
    if [ -z "$NO_GRPC_BUILD" ]; then \
       pip3 install grpclib grpcio-tools; \
       python3 -m grpc_tools.protoc common/protos/*.proto generated/protos/*.proto \
              vendor/github.com/gogo/protobuf/gogoproto/*.proto \
              vendor/github.com/gogo/googleapis/google/api/*.proto \
              -Icommon/protos -Igenerated/protos \
	      -Ivendor/github.com/gogo/protobuf/gogoproto \
	      -Ivendor/github.com/gogo/googleapis \
              --python_out=/git/pyep11/generated/python_grpc --grpc_python_out=/git/pyep11/generated/python_grpc; \
       mv /git/pyep11/generated/python_grpc/* /git/electrum; \
       mv /git/pyep11/pyep11.py /git/electrum; \
       mv /git/pyep11/grep11consts.py /git/electrum; \
    fi && \
    mkdir -p /data && chown ${ELECTRUM_USER} /data

# Run Electrum as non privileged user
# USER $ELECTRUM_USER

WORKDIR ${ELECTRUM_DIR}

ENV ZHSM ${ZHSM}
ENV PYTHONPATH ${ELECTRUM_DIR}

###################################################################################
# Install Laravel

ENV DEBIAN_FRONTEND noninteractive

WORKDIR /root
ENV APP_ROOT /var/www/html/electrum
RUN curl -sS https://getcomposer.org/installer -o composer-setup.php && \
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer && \
    cd $APP_ROOT/.. && \
    git clone https://github.com/laravel/laravel.git && \
    mv laravel electrum && \
    cd $APP_ROOT && \
    git checkout v5.4.30

###################################################################################
# Install Laravel-Electrum, a web frontend for Electrum

ENV APP_ROOT /var/www/html/electrum

WORKDIR $APP_ROOT

ADD laravel-electrum/composer.json composer.json
ADD laravel-electrum/env.sh .

RUN chown -R www-data /var/www
USER www-data

ARG LARAVEL_ELECTRUM_BRANCH="local-c"
RUN sed --in-place "s|dev-local|dev-${LARAVEL_ELECTRUM_BRANCH}|" composer.json && \
    composer -vv install && \
    npm install && \
    mv .env.example .env && \
    php artisan key:generate && \
    ./env.sh && \
    php artisan make:auth && \
    php artisan make:migration create_user && \
    sed --in-place "s|App\\\Providers\\\RouteServiceProvider::class,|App\\\Providers\\\RouteServiceProvider::class,\n        AraneaDev\\\Electrum\\\ElectrumServiceProvider::class,|" config/app.php && \
    sed --in-place "s|Vue.component('example', require('./components/Example.vue'));|Vue.component('electrum-wallet', require('$APP_ROOT/vendor/araneadev/laravel-electrum/src/resources/assets/js/Electrum.vue'));|" $APP_ROOT/resources/assets/js/app.js && \
    sed --in-place "s/right/left/" resources/views/layouts/app.blade.php && \
    sed --in-place "s/\"nav navbar-nav\"/\"nav navbar-nav navbar-center\"/" resources/views/layouts/app.blade.php && \
# Change the redict root after login from home to electrum
    sed --in-place "s|/home|/electrum|" app/Http/Controllers/Auth/LoginController.php && \
    sed --in-place "s|/home|/electrum|" app/Http/Controllers/Auth/RegisterController.php && \
    sed --in-place "s|/home|/electrum|" app/Http/Controllers/Auth/ResetPasswordController.php && \
# Use the container hostname as the session key
    sed --in-place "s|'laravel_session',|env('HOSTNAME', 'laravel_session'),|" config/session.php && \
    npm install ajv && \
    npm install clipboard --save-dev && \
    npm install moment --save-dev && \
    npm install vue2-bootstrap-modal --save-dev && \
    npm install vue-qrcode-component --save-dev && \
    npm install --save-dev prettier@1.12.0 && \
    npm run dev && \
    composer -vv clearcache && \
    npm cache clear --force 

ARG ELECTRUM_DAEMON_HOST=localhost
ARG ELECTRUM_DAEMON_USER=electrum
ARG ELECTRUM_DAEMON_PASSWORD=passw0rd
RUN echo ELECTRUM_DAEMON_HOST=${ELECTRUM_DAEMON_HOST} >> .env && \
    echo ELECTRUM_DAEMON_USER=${ELECTRUM_DAEMON_USER} >> .env && \
    echo ELECTRUM_DAEMON_PASSWORD=${ELECTRUM_DAEMON_PASSWORD} >> .env

# set up apache
WORKDIR /etc/apache2/sites-available
ADD laravel-electrum/electrum.conf /etc/apache2/sites-available
ADD laravel-electrum/electrum-ssl.conf /etc/apache2/sites-available
ADD laravel-electrum/apache/apache2.conf /etc/apache2

WORKDIR $APP_ROOT
ADD laravel-electrum/entrypoint-frontend.sh .
ADD electrum/entrypoint-electrum.sh ${ELECTRUM_DIR}
ADD entrypoint.sh .

VOLUME /data

EXPOSE 443

# Setup Supervisord
USER root
ADD supervisord.conf /etc/supervisor/conf.d/supervisord.conf
ENV PYTHONUNBUFFERED=1

CMD ["/usr/bin/supervisord"]
