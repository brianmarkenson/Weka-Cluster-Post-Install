#!/bin/bash
# Cleanup previous run if necessary

rm -rf ./post_install_tmp
#rm cluster_hosts* &>/dev/null
#rm aliases &>/dev/null
rm -r .dsh

mv ~/.ssh/known_hosts.orig ~/.ssh/known_hosts &>/dev/null
sudo mv /etc/hosts.orig /etc/hosts &>/dev/null
sudo mv /etc/genders.orig /etc/genders &>/dev/null

mkdir post_install_tmp

#Check for .ssh/id_rsa
if [ ! -e ~/.ssh/id_rsa ]; then
  echo "Need id_rsa!"
  exit 1
fi

# Determine OS type
if [ -e /etc/os-release ]; then
    # Source the file to get distribution information
    . /etc/os-release
    # Check the ID_LIKE field for distribution name
    if [[ "$ID_LIKE" == *debian* ]]; then
        os=debian
        DEBIAN=1
    elif [[ "$ID_LIKE" == *centos* ]]; then
        os=centos
        CENTOS=1
    else
        echo "Distribution is not centos / debian"
        exit 1
    fi
else
    echo "Unable to determine the distribution."
    exit 1
fi
echo "OS = $os"
#
# Generate list of Weka servers and clients
# Protocol servers will be duplicated in the backend list as well
# List of roles
echo "Generating list of Weka servers and clients..."
roles=("backend" "client" "nfs" "smb" "s3")

# Create or truncate the "cluster_hosts" file
> post_install_tmp/cluster_hosts
> post_install_tmp/aliases

# Initialize variables
declare -A counts
proto=0 # Initialize protocol variable

# Loop through roles, count lines, and append data to the file

mkdir -p .dsh/group; sudo mkdir -p /etc/dsh/group


for role in "${roles[@]}"; do
    counts["$role"]=$(weka cluster servers list --role "$role" -o ip,hostname --no-header | tee -a post_install_tmp/cluster_hosts | wc -l)

    # Determine prefix based on role
    case "$role" in
        "backend") prefix="b";;
        "client") prefix="c";;
        "nfs") prefix="n";;
        "smb") prefix="s";;
        "s3") prefix="o";;
    esac

    sudo cp /etc/genders /etc/genders.orig &> /dev/null
    # Generate shortnames and append to "aliases" file
    for ((i=0; i < ${counts["$role"]}; i++)); do
        if [ "$role" != "backend" ] && [ "$role" != "client" ]; then
            echo "${prefix}$i p$proto" >> post_install_tmp/aliases
            ((proto++))
        else
            echo "weka${prefix}$i ${prefix}$i" >> post_install_tmp/aliases
        fi
        echo -ne "${prefix}$i "
        echo "${prefix}$i" >> .dsh/group/$role
	echo "${prefix}$i $role" >> post_install_tmp/genders
    done
done
echo ""

# Update the /etc/hosts file with all the servers, as well as the new shortnames
sudo cp /etc/hosts /etc/hosts.orig
sudo bash -c 'paste post_install_tmp/cluster_hosts post_install_tmp/aliases >> /etc/hosts'
rm post_install_tmp/aliases post_install_tmp/cluster_hosts
echo "/etc/hosts file updated"
sudo mv .dsh/group/* /etc/dsh/group
sudo mv post_install_tmp/genders /etc/genders

# Create a known_hosts file with ssh-keyscan and copy the file to all hosts.
# Also copy /etc/hosts and id_rsa to all hosts
[ ! -e ~/.ssh/known_hosts ] && > ~/.ssh/known_hosts
echo "Adding nodes to .ssh/known_hosts and distributing data cluster"
# populate the .ssh/known_hosts file
echo "Scanning ssh keys..."
for i in $(grep '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' /etc/hosts); do
  # Don't process duplicates for ssh-keyscan
  if ! egrep -q "^$i " ~/.ssh/known_hosts; then
    echo -ne "\033[K"; echo -ne "Keyscan $i\r"
    ssh-keyscan $i >> ~/.ssh/known_hosts 2>/dev/null
  fi
done
echo -ne "\033[Kdone\n"
# Copy files once
echo "Copying files to all hosts"
for ip in $(grep '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' /etc/hosts | awk '{print $2}'); do
  echo -ne "\033[K"; echo -ne "$ip\r"
  scp ~/.ssh/known_hosts ~/.ssh/id_rsa $ip:~/.ssh/ &>/dev/null
  scp /etc/hosts $ip:~/ &>/dev/null
  ssh $ip "sudo mv hosts /etc/hosts" &>/dev/null
done
echo -ne "\033[Kdone\n"

# Install pdsh
HOSTNAME=$(hostname -a | awk '{print $1}')
echo "Configuring pdsh..."
# Create pdsh.sh profile that will use /etc/cluster.pdsh and run using ssh
echo "export WCOLL=/etc/cluster.pdsh export PDSH_RCMD_TYPE=ssh" > pdsh.sh; sudo mv pdsh.sh /etc/profile.d/pdsh.sh;
source /etc/profile.d/pdsh.sh

# Create cluster.pdsh for all backend and client systems
cat /etc/hosts | egrep -v 'localhost|\:\:' | awk '{print $4}' | egrep 'b|c' > post_install_tmp/cluster.pdsh; sudo mv post_install_tmp/cluster.pdsh /etc
case $os in
    debian)
        # For Debian-based systems
        sudo apt install pdsh -y &>/dev/null
        pdsh sudo apt install pdsh -y &>/dev/null
        pdsh sudo apt install git -y &>/dev/null
        ;;
    centos)
        # For CentOS systems
        echo "  Adding amazon-linux-extras..."
        sudo amazon-linux-extras install epel -y &> /dev/null
        echo "  Installing pdsh..."
        sudo yum install pdsh-rcmd-ssh.x86_64 pdsh-mod-dshgroup.x86_64 -y &>/dev/null
        pdsh "mkdir -p .dsh/group; scp $HOSTNAME:/etc/dsh/group/* .dsh/group; sudo mkdir -p /etc/dsh/group; sudo mv .dsh/group/* /etc/dsh/group"
        echo "  Adding amazon-linux-extras to remote systems..."
        pdsh sudo amazon-linux-extras install epel -y &>/dev/null
        echo "  Installing pdsh on remote systems..."
        pdsh sudo yum install pdsh-rcmd-ssh.x86_64 pdsh-mod-dshgroup.x86_64 -y &>/dev/null
        echo "Installing git on all systems..."
        pdsh sudo yum install git -y &>/dev/null
        ;;
    *)
        echo "Unsupported OS: $os"
        exit 1
        ;;
esac

# Distribute /etc/hosts, /etc/cluster.pdsh, /etc/profile.d/pdsh.sh to all servers
echo "Distribute /etc/hosts, /etc/cluster.pdsh, /etc/profile.d/pdsh.sh to all servers"
pdsh "scp $HOSTNAME:/etc/profile.d/pdsh.sh pdsh.sh; sudo mv pdsh.sh /etc/profile.d"
pdsh "scp $HOSTNAME:/etc/cluster.pdsh cluster.pdsh; sudo mv cluster.pdsh /etc"
pdsh "scp $HOSTNAME:/etc/genders genders; sudo mv genders /etc"

# Install GIT weka/tools on all servers
echo "Install GIT weka/tools on all servers"
pdsh git clone http://github.com/weka/tools &>/dev/null
pdsh sudo chmod 777 /mnt/weka

rm -rf post_install_tmp

echo "Post Installation completed."
