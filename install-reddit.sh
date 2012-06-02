#!/bin/bash -e
set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run with root privileges."
    exit 1
fi

# seriously! these checks aren't here for no reason. the packages from the
# reddit ppa aren't built for anything but natty (11.04) right now, so
# if you try and use this install script on another release you're gonna
# have a bad time.
source /etc/lsb-release
if [[ "$DISTRIB_ID" != "Ubuntu" -o "$DISTRIB_RELEASE" != "11.04" ]]; then
    echo "ERROR: Only Ubuntu 11.04 is supported."
    exit 1
fi

###############################################################################
# Configuration
###############################################################################
echo "Welcome to the reddit install script!"

# TODO
REDDIT_USER=reddit
REDDIT_OWNER=reddit
REDDIT_HOME=/home/$REDDIT_USER

echo "Beginning installation. This may take a while..."
echo

# create the user if non-existent
if ! id $REDDIT_USER > /dev/null; then
    adduser --system $REDDIT_USER
fi

###############################################################################
# Install prerequisites
###############################################################################
# aptitude configuration
APTITUDE_OPTIONS="-y" # limit bandwidth: -o Acquire::http::Dl-Limit=100"
export DEBIAN_FRONTEND=noninteractive

# add the reddit ppa for some custom packages
apt-get install $APTITUDE_OPTIONS aptitude python-software-properties
apt-add-repository ppa:reddit/ppa

# pin the ppa -- packages present in the ppa will take precedence over
# ones in other repositories (unless further pinning is done)
cat <<HERE > /etc/apt/preferences.d/reddit
Package: *
Pin: release o=LP-PPA-reddit
Pin-Priority: 600
HERE

# grab the new ppas' package listings
aptitude update

# install prerequisites
aptitude install $APTITUDE_OPTIONS python-dev python-setuptools cython gettext\
                 make optipng jpegoptim uwsgi uwsgi-core uwsgi-plugin-python  \
                 nginx git-core memcached postgresql postgresql-client curl   \
                 rabbitmq-server cassandra haproxy

###############################################################################
# Install the reddit source repositories
###############################################################################
if [ ! -d $REDDIT_HOME ]; then
    mkdir $REDDIT_HOME
    chown $REDDIT_OWNER $REDDIT_HOME
fi

cd $REDDIT_HOME

if [ ! -d $REDDIT_HOME/reddit ]; then
    sudo -u $REDDIT_OWNER git clone git://github.com/reddit/reddit.git
fi

if [ ! -d $REDDIT_HOME/reddit-i18n ]; then
    sudo -u $REDDIT_OWNER git clone git://github.com/reddit/reddit-i18n.git
fi

###############################################################################
# Configure Cassandra
###############################################################################
# wait a bit to make sure all the servers come up
sleep 30

if ! echo | cassandra-cli -h localhost -k reddit > /dev/null 2>&1; then
    echo "create keyspace reddit;" | cassandra-cli -h localhost -B
fi

cat <<CASS | cassandra-cli -B -h localhost -k reddit || true
create column family permacache with column_type = 'Standard' and
                                     comparator = 'BytesType';
CASS

###############################################################################
# Configure PostgreSQL
###############################################################################
SQL="SELECT COUNT(1) FROM pg_catalog.pg_database WHERE datname = 'reddit';"
IS_DATABASE_CREATED=$(sudo -u postgres psql -t -c "$SQL")

if [ $IS_DATABASE_CREATED -ne 1 ]; then
    cat <<PGSCRIPT | sudo -u postgres psql
CREATE DATABASE reddit WITH ENCODING = 'utf8';
CREATE USER reddit WITH PASSWORD 'password';
PGSCRIPT
fi

sudo -u postgres psql reddit < $REDDIT_HOME/reddit/sql/functions.sql

###############################################################################
# Configure RabbitMQ
###############################################################################
if ! rabbitmqctl list_vhosts | egrep "^/$"
then
    rabbitmqctl add_vhost /
fi

if ! rabbitmqctl list_users | egrep "^reddit"
then
    rabbitmqctl add_user reddit reddit
fi

rabbitmqctl set_permissions -p / reddit ".*" ".*" ".*"

###############################################################################
# Install and configure the reddit code
###############################################################################
cd $REDDIT_HOME/reddit/r2
sudo -u $REDDIT_OWNER make pyx # generate the .c files from .pyx
sudo -u $REDDIT_OWNER python setup.py build
python setup.py develop

cd $REDDIT_HOME/reddit-i18n/
sudo -u $REDDIT_OWNER python setup.py build
python setup.py develop
sudo -u $REDDIT_OWNER make

# this builds static files and should be run *after* languages are installed
# so that the proper language-specific static files can be generated.
cd $REDDIT_HOME/reddit/r2
sudo -u $REDDIT_OWNER make

cd $REDDIT_HOME/reddit/r2

if [ ! -f development.update ]; then
    cat > development.update <<DEVELOPMENT
# after editing this file, run "make ini" to
# generate a new development.ini

[DEFAULT]
debug = true

disable_ads = true
disable_captcha = true
disable_ratelimit = true

page_cache_time = 0

set debug = true

[server:main]
port = 8001
DEVELOPMENT
    chown $REDDIT_OWNER development.update
fi

if [ ! -f production.update ]; then
    cat > production.update <<PRODUCTION
# after editing this file, run "make ini" to
# generate a new production.ini

[DEFAULT]
debug = false
reload_templates = false
uncompressedJS = false

set debug = false

[server:main]
port = 8001
PRODUCTION
    chown $REDDIT_OWNER production.update
fi

sudo -u $REDDIT_OWNER make ini

if [ ! -L run.ini ]; then
    sudo -u $REDDIT_OWNER ln -s development.ini run.ini
fi

###############################################################################
# haproxy
###############################################################################
if [ -e /etc/haproxy/haproxy.cfg ]; then
    BACKUP_HAPROXY=$(mktemp /etc/haproxy/haproxy.cfg.XXX)
    echo "Backing up /etc/haproxy/haproxy.cfg to $BACKUP_HAPROXY"
    cat /etc/haproxy/haproxy.cfg > $BACKUP_HAPROXY
fi

cat > /etc/haproxy/haproxy.cfg <<HAPROXY
global
    maxconn 100

frontend frontend 0.0.0.0:80
    mode http
    timeout client 10000
    option forwardfor except 127.0.0.1
    option httpclose

    default_backend dynamic

backend dynamic
    mode http
    timeout connect 4000
    timeout server 30000
    timeout queue 60000
    balance roundrobin

    server app01-8001 localhost:8001 maxconn 1
HAPROXY

# this will start it even if currently stopped
service haproxy restart

###############################################################################
# Upstart Environment
###############################################################################
cp $REDDIT_HOME/reddit/upstart/* /etc/init/

if [ ! -f /etc/default/reddit ]; then
    cat > /etc/default/reddit <<DEFAULT
export REDDIT_ROOT=$REDDIT_HOME/reddit
export REDDIT_INI=$REDDIT_HOME/reddit/r2/run.ini
export REDDIT_USER=$REDDIT_USER
export REDDIT_CONSUMER_CONFIG=$REDDIT_HOME/consumer-counts
alias wrap-job=$REDDIT_HOME/reddit/scripts/wrap-job
alias manage-consumers=$REDDIT_HOME/reddit/scripts/manage-consumers
DEFAULT
fi

###############################################################################
# Queue Processors
###############################################################################
if [ ! -f $REDDIT_HOME/consumer-counts ]; then
    cat > $REDDIT_HOME/consumer-counts <<COUNTS
log_q           0
cloudsearch_q   1
scraper_q       1
commentstree_q  1
newcomments_q   1
vote_comment_q  1
vote_link_q     1
COUNTS
fi

initctl emit reddit-start

###############################################################################
# Cron Jobs
###############################################################################
if [ ! -f /etc/cron.d/reddit ]; then
    cat > /etc/cron.d/reddit <<CRON
0    3 * * * root /sbin/start --quiet reddit-job-update_sr_names
30  16 * * * root /sbin/start --quiet reddit-job-update_reddits
0    * * * * root /sbin/start --quiet reddit-job-update_promos
*/5  * * * * root /sbin/start --quiet reddit-job-clean_up_hardcache
*    * * * * root /sbin/start --quiet reddit-job-email
*/2  * * * * root /sbin/start --quiet reddit-job-broken_things
*/2  * * * * root /sbin/start --quiet reddit-job-rising

# disabled by default, uncomment if you need these jobs
#*/2  * * * * root /sbin/start --quiet reddit-job-google_checkout
#*/10 * * * * root /sbin/start --quiet reddit-job-solrsearch optimize=False
#0    0 * * * root /sbin/start --quiet reddit-job-solrsearch optimize=True
#0    0 * * * root /sbin/start --quiet reddit-job-update_gold_users
CRON

###############################################################################
# All done!
###############################################################################
cd $REDDIT_HOME
echo "Done installing reddit!"
