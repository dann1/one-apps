# ---------------------------------------------------------------------------- #
# Copyright 2018-2019, OpenNebula Project, OpenNebula Systems                  #
#                                                                              #
# Licensed under the Apache License, Version 2.0 (the "License"); you may      #
# not use this file except in compliance with the License. You may obtain      #
# a copy of the License at                                                     #
#                                                                              #
# http://www.apache.org/licenses/LICENSE-2.0                                   #
#                                                                              #
# Unless required by applicable law or agreed to in writing, software          #
# distributed under the License is distributed on an "AS IS" BASIS,            #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     #
# See the License for the specific language governing permissions and          #
# limitations under the License.                                               #
# ---------------------------------------------------------------------------- #

### Important notes ##################################################
#
# The contextualization variable 'ONEAPP_SITE_HOSTNAME' IS (!) mandatory and
# must be correct (resolveable, reachable) otherwise the web will be broken.
# It defaults to first non-loopback address it finds - if no address is found
# then the 'localhost' is used - and then wordpress will function correctly
# only from within the instance.
#
# 'ONEAPP_SITE_HOSTNAME' can be changed in the wordpress settings but it should
# be set to something sensible from the beginning so you can be able to login
# to the wordpress and change the settings...
#
### Important notes ##################################################


# List of contextualization parameters
ONE_SERVICE_PARAMS=(
    'ONEAPP_MARIADB_NAME'            'configure' 'Database name'                                     ''
    'ONEAPP_MARIADB_USER'            'configure' 'Database service user'                             ''
    'ONEAPP_MARIADB_PASSWORD'        'configure' 'Database service password'                         ''
    'ONEAPP_MARIADB_ROOT_PASSWORD'   'configure' 'Database password for root'                        ''

)


### Appliance metadata ###############################################

# Appliance metadata
ONE_SERVICE_NAME='Service MariaDB - KVM'
ONE_SERVICE_VERSION='0.1.0'
ONE_SERVICE_BUILD=$(date +%s)
ONE_SERVICE_SHORT_DESCRIPTION='Appliance with preinstalled MariaDB for KVM hosts'
ONE_SERVICE_DESCRIPTION=$(cat <<EOF
Example appliance build how to for the webinar
EOF
)


### Contextualization defaults #######################################

# should be set before any password is to be generated
ONEAPP_MARIADB_NAME="${ONEAPP_MARIADB_NAME:-mariadb}"


### Globals ##########################################################

MARIADB_CREDENTIALS=/root/.my.cnf
MARIADB_CONFIG=/etc/my.cnf.d/wordpress.cnf
DEP_PKGS="coreutils httpd mod_ssl mariadb mariadb-server php php-common php-mysqlnd php-json php-gd php-xml php-mbstring unzip wget curl openssl expect ca-certificates"


###############################################################################
###############################################################################
###############################################################################

#
# service implementation
#

service_cleanup()
{
    :
}

service_install()
{
    # ensuring that the setup directory exists
    #TODO: move to service
    mkdir -p "$ONE_SERVICE_SETUP_DIR"

    # packages
    install_pkgs ${DEP_PKGS}

    # service metadata
    create_one_service_metadata

    # cleanup
    postinstall_cleanup

    msg info "INSTALLATION FINISHED"

    return 0
}

service_configure()
{
    # preparation
    stop_services

    # mariadb
    setup_mariadb
    report_config

    # enable the services
    enable_services

    msg info "CONFIGURATION FINISHED"

    return 0
}

service_bootstrap()
{
    msg info "BOOTSTRAP FINISHED"

    return 0
}

###############################################################################
###############################################################################
###############################################################################

#
# functions
#


postinstall_cleanup()
{
    msg info "Delete cache and stored packages"
    yum clean all
    rm -rf /var/cache/yum
}

stop_services()
{
    msg info "Stopping services"
    systemctl stop mariadb
}

enable_services()
{
    msg info "Enable services"
    systemctl enable mariadb
}

install_pkgs()
{
    msg info "Enable EPEL repository"
    if ! yum install -y --setopt=skip_missing_names_on_install=False epel-release ; then
        msg error "Failed to enable EPEL repository"
        exit 1
    fi

    msg info "Install required packages"
    if ! yum install -y --setopt=skip_missing_names_on_install=False "${@}" ; then
        msg error "Package(s) installation failed"
        exit 1
    fi
}


report_config()
{
    msg info "Credentials and config values are saved in: ${ONE_SERVICE_REPORT}"

    cat > "$ONE_SERVICE_REPORT" <<EOF
[DB connection info]
host     = localhost
database = ${ONEAPP_MARIADB_NAME}
EOF

    chmod 600 "$ONE_SERVICE_REPORT"
}

db_reset_root_password()
{
    msg info "Reset root password"

    systemctl stop mariadb

    # waiting for shutdown
    msg info "Waiting for db to shutdown..."
    while is_mariadb_up ; do
        printf .
        sleep 1s
    done
    echo

    # start db in single-user mode
    msg info "Starting db in single-user mode"
    mysqld_safe --skip-grant-tables --skip-networking &

    # waiting for db to start
    msg info "Waiting for single-user db to start..."
    while ! is_mariadb_up ; do
        printf .
        sleep 1s
    done
    echo

    # reset root password
    mysql -u root <<EOF
FLUSH PRIVILEGES;
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${ONEAPP_MARIADB_ROOT_PASSWORD}');
FLUSH PRIVILEGES;
EOF

    msg info "Root password changed - stopping single-user mode"
    kill $(cat /var/run/mariadb/mariadb.pid)

    # waiting for shutdown
    msg info "Waiting for db to shutdown..."
    while is_mariadb_up ; do
        printf .
        sleep 1s
    done
    echo
}

setup_mariadb()
{
    msg info "Database setup"

    # start db
    systemctl start mariadb

    # check if db was initialized
    if [ "$(find /var/lib/mysql -mindepth 1 | wc -l)" -eq 0 ] ; then
        msg error "Database was not initialized: /var/lib/mysql"
        exit 1
    fi

    # setup root password
    if is_root_password_valid ; then
        msg info "Setup root password"

        mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${ONEAPP_MARIADB_ROOT_PASSWORD}');
FLUSH PRIVILEGES;
EOF
    else
        # reset root password
        db_reset_root_password
    fi

    # store root password
    msg info "Save root credentials into: ${MARIADB_CREDENTIALS}"
    cat > "$MARIADB_CREDENTIALS" <<EOF
[client]
password = "$ONEAPP_MARIADB_ROOT_PASSWORD"
EOF

    # config db
    msg info "Bind DB to localhost only"
    cat > "$MARIADB_CONFIG" <<EOF
[mysqld]
bind-address=127.0.0.1
EOF
    chmod 644 "$MARIADB_CONFIG"

    # restart db
    msg info "Starting db for the last time"
    systemctl restart mariadb

    # secure db
    msg info "Securing db"
    LANG=C expect -f - <<EOF
set timeout 10
spawn mysql_secure_installation

expect "Enter current password for root (enter for none):"
send "${ONEAPP_MARIADB_ROOT_PASSWORD}\n"

expect "Set root password?"
send "n\n"

expect "Remove anonymous users?"
send "Y\n"

expect "Disallow root login remotely?"
send "Y\n"

expect "Remove test database and access to it?"
send "Y\n"

expect "Reload privilege tables now?"
send "Y\n"

expect eof
EOF

    # prepare db for wordpress
    msg info "Preparing WordPress database and passwords"
    mysql -u root -p"${ONEAPP_MARIADB_ROOT_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS ${ONEAPP_MARIADB_NAME};
GRANT ALL PRIVILEGES on ${ONEAPP_MARIADB_NAME}.* to '${ONEAPP_MARIADB_USER}'@'localhost' identified by '${ONEAPP_MARIADB_PASSWORD}';
FLUSH PRIVILEGES;
EOF
}

is_mariadb_up()
{
    if [ -f /var/run/mariadb/mariadb.pid ] ; then
        if kill -0 $(cat /var/run/mariadb/mariadb.pid) ; then
            return 0
        fi
    fi
    return 1
}

is_root_password_valid()
{
    _check=$(mysql -u root -s -N -e 'select CURRENT_USER();')
    case "$_check" in
        root@*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac

    return 1
}
