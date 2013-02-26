#! /bin/bash
#Flagrantly stolen from rpedde (http://www.github.com/rpedde)

set -e
set -u
set -x
export DEBIAN_FRONTEND=noninteractive
source "$OPENCENTER_BASH_DIR/opencenter.sh"

if ! [[ -e /etc/debian_version ]] ; then
    echo "Attempted to run debian derivative script on non-debian distribution" 1>&2
    exit 1
fi

CHEF_SERVER_VERSION=${CHEF_SERVER_VERSION:-11.0.4-1}

locale-gen en_US.UTF-8

apt-get install -y --force-yes pwgen wget lsb-release
cp /etc/resolv.conf /tmp/rc
apt-get remove --purge resolvconf -y --force-yes
cp /tmp/rc /etc/resolv.conf

PRIMARY_INTERFACE=$(ip route list match 0.0.0.0 | awk 'NR==1 {print $5}')
MY_IP=$(ip addr show dev ${PRIMARY_INTERFACE} | awk 'NR==3 {print $2}' | cut -d '/' -f1)
CHEF_UNIX_USER=${CHEF_UNIX_USER:-root}

if [ ! -e "/etc/chef-server/chef-server.rb" ]; then
  # defaults if not set
  CHEF_WEBUI_PASSWORD=${CHEF_WEBUI_PASSWORD:-$(pwgen -1)}
  CHEF_AMQP_PASSWORD=${CHEF_AMQP_PASSWORD:-$(pwgen -1)}
  CHEF_POSTGRESQL_PASSWORD=${CHEF_POSTGRESQL_PASSWORD:-$(pwgen -1)}
  CHEF_POSTGRESQL_RO_PASSWORD=${CHEF_POSTGRESQL_PASSWORD:-$(pwgen -1)}

  # due to http://tickets.opscode.com/browse/CHEF-3849 CHEF_FE_PORT is not used yet
  CHEF_FE_PORT=${CHEF_FE_PORT:-80}
  CHEF_FE_SSL_PORT=${CHEF_FE_SSL_PORT:-443}
  CHEF_URL=${CHEF_URL:-https://${MY_IP}:${CHEF_FE_SSL_PORT}}

  mkdir -p /etc/chef-server
  cat > /etc/chef-server/chef-server.rb <<EOF
node.override["chef_server"]["chef-server-webui"]["web_ui_admin_default_password"] = "${CHEF_WEBUI_PASSWORD}"
node.override["chef_server"]["rabbitmq"]["password"] = "${CHEF_AMQP_PASSWORD}"
node.override["chef_server"]["postgresql"]["sql_password"] = "${CHEF_POSTGRESQL_PASSWORD}"
node.override["chef_server"]["postgresql"]["sql_ro_password"] = "${CHEF_POSTGRESQL_RO_PASSWORD}"
node.override["chef_server"]["nginx"]["url"] = "${CHEF_URL}"
node.override["chef_server"]["nginx"]["ssl_port"] = ${CHEF_FE_SSL_PORT}
node.override["chef_server"]["nginx"]["non_ssl_port"] = ${CHEF_FE_PORT}
node.override["chef_server"]["nginx"]["enable_non_ssl"] = true
if (node['memory']['total'].to_i / 4) > ((node['chef_server']['postgresql']['shmmax'].to_i / 1024) - 2097152)
  # guard against setting shared_buffers > shmmax on hosts with installed RAM > 64GB
  # use 2GB less than shmmax as the default for these large memory machines
  node.override['chef_server']['postgresql']['shared_buffers'] = "14336MB"
else
  node.override['chef_server']['postgresql']['shared_buffers'] = "#{(node['memory']['total'].to_i / 4) / (1024)}MB"
end
EOF

    HOMEDIR=$(getent passwd ${CHEF_UNIX_USER} | cut -d: -f6)
    export HOME=${HOMEDIR}
    if ! dpkg -s chef-server &>/dev/null; then
        curl -L "http://www.opscode.com/chef/download-server?p=ubuntu&pv=12.04&m=x86_64&v=${CHEF_SERVER_VERSION}" > /tmp/chef-server.deb
        dpkg -i /tmp/chef-server.deb
        chef-server-ctl reconfigure
        rm -f /tmp/chef-server.deb
    fi

    mkdir -p ${HOMEDIR}/.chef
    cp /etc/chef-server/{chef-validator.pem,chef-webui.pem,admin.pem} ${HOMEDIR}/.chef
    chown -R ${CHEF_UNIX_USER}: ${HOMEDIR}/.chef

    if [[ ! -e ${HOMEDIR}/.chef/knife.rb ]]; then
       cat <<EOF | /opt/chef-server/bin/knife configure -i
${HOMEDIR}/.chef/knife.rb
${CHEF_URL}
admin
chef-webui
${HOMEDIR}/.chef/chef-webui.pem
chef-validator
${HOMEDIR}/.chef/chef-validator.pem

EOF
        # setup the path
        echo 'export PATH=${PATH}:/opt/chef-server/bin' >> ${HOMEDIR}/.profile
    fi

    # these are only returned on a run where we actually install chef-server
    return_fact "chef_server_client_name" "'admin'"
    return_fact "chef_server_client_pem" "'$(cat /root/.chef/admin.pem)'"
    return_fact "chef_server_uri" "'${CHEF_URL}'"
    return_fact "chef_server_pem" "'$(cat /etc/chef-server/chef-validator.pem)'"
    return_fact "chef_server_cookbook_channels" "'current'"
    return_attr "chef_webui_password" "'${CHEF_WEBUI_PASSWORD}'"
fi