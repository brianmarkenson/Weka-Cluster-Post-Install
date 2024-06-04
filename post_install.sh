#!/bin/bash
# Cleanup previous run if necessary

TMP=post_install_tmp
rm -rf $TMP

mv ~/.ssh/known_hosts.orig ~/.ssh/known_hosts &>/dev/null
sudo mv /etc/hosts.orig /etc/hosts &>/dev/null
sudo mv /etc/genders.orig /etc/genders &>/dev/null

mkdir $TMP

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

echo -ne "Generating list of Weka servers and clients..."
declare -A counts

# Initialize counters
BACKEND=0; CLIENT=0; NFS=0; SMB=0; S3=0

# Check for Weka auth token
if [ ! -e ~/.weka/auth-token.json ]; then
    # Login to Weka
    weka user login
    if [ ! -e ~/.weka/auth-token.json ]; then
        echo "Unable to login to Weka"
        exit 1
    fi
fi

# Process the output of the Weka command
weka cluster servers list -o ip,hostname,roles --no-header -s up_since | while read -r line; do
    ip=$(echo $line | awk '{print $1}')
    hostname=$(echo $line | awk '{print $2}')
    roles=$(echo $line | awk '{print substr($0, index($0, $3))}')
    shortname=$(echo $hostname | cut -d '.' -f 1)
    
    # Add short names to aliases file
    echo -ne "$ip " >> $TMP/aliases
    echo -ne "$hostname " >> $TMP/aliases
    echo -ne "$shortname " >> $TMP/aliases

    echo -ne "$shortname " >> $TMP/genders.1
    echo $shortname >> $TMP/cluster.pdsh
    
    for role in $roles; do
        case $role in
            BACKEND*) echo -ne "b$BACKEND " >> $TMP/aliases; echo -ne "backend," >> $TMP/genders.1; ((BACKEND++));;
            CLIENT*) echo -ne "c$CLIENT " >> $TMP/aliases; echo -ne "client," >> $TMP/genders.1; ((CLIENT++));;
            NFS*) echo -ne "n$NFS " >> $TMP/aliases; echo -ne "nfs," >> $TMP/genders.1; ((NFS++));;
            SMB*) echo -ne "s$SMB " >> $TMP/aliases; echo -ne "smb," >> $TMP/genders.1; ((SMB++));;
            S3*) echo -ne "o$S3 "; >> $TMP/aliases; echo -ne "s3" >> $TMP/genders.1;  ((S3++));;
        esac
    done
    echo "" >> $TMP/genders.1
    cat $TMP/genders.1 | sed 's/\,$//' >> $TMP/genders; rm $TMP/genders.1

    echo "" >> $TMP/aliases
done

echo "done"

# Update the /etc/hosts file with all the servers, as well as the new shortnames
sudo cp /etc/hosts /etc/hosts.orig
sudo bash -c "cat $TMP/aliases >> /etc/hosts"
sudo mv $TMP/genders /etc/genders
sudo mv $TMP/cluster.pdsh /etc/cluster.pdsh


# PDSH configuration
HOSTNAME=$(hostname -a | awk '{print $1}')
# Create pdsh.sh profile that will use /etc/cluster.pdsh and run using ssh
sudo bash -c 'echo "export WCOLL=/etc/cluster.pdsh PDSH_RCMD_TYPE=ssh" > /etc/profile.d/pdsh.sh'
export WCOLL=/etc/cluster.pdsh PDSH_RCMD_TYPE=ssh
source /etc/profile.d/pdsh.sh
echo "/etc/hosts /etc/genders /etc/cluster.pdsh /etc/profile.d/pdsh.sh files updated"

# Create a known_hosts file with ssh-keyscan and copy the file to all hosts.
# Also copy /etc/hosts and id_rsa to all hosts
[ ! -e ~/.ssh/known_hosts ] && > ~/.ssh/known_hosts
  echo "Adding nodes to .ssh/known_hosts and distributing data to cluster"
# populate the .ssh/known_hosts file
echo -ne "  Scanning ssh keys..."
for i in $(cat /etc/hosts); do
  # Don't process duplicates for ssh-keyscan
  if ! grep -Eq "$i( |$)" ~/.ssh/known_hosts; then
    echo -ne "\r\e[22CKeyscan $i\e[K\r"
    ssh-keyscan $i >> ~/.ssh/known_hosts 2>/dev/null
  fi
done
echo -ne "\e[22Cdone\e[K\n"
# Copy files once
echo "Copying files to all hosts..."
for ip in $(cat /etc/hosts | grep -v localhost | awk '{print $2}'); do
  echo -ne "\r\e[30$ip\e[K\r"
  scp ~/.ssh/known_hosts ~/.ssh/id_rsa $ip:~/.ssh/ &>/dev/null
  scp /etc/hosts /etc/genders /etc/cluster.pdsh /etc/profile.d/pdsh.sh $ip:~/ &>/dev/null
  ssh $ip "sudo mv hosts /etc/hosts; sudo mv genders /etc/genders; sudo mv pdsh.sh /etc/profile.d/pdsh.sh; sudo mv cluster.pdsh /etc/cluster.pdsh" &>/dev/null
done
echo -ne "\e[30Cdone\e[K\n"

case $os in
    debian)
        # For Debian-based systems
	echo -ne "  Installing pdsh on local node..."
	if ! rpm -q pdsh >&/dev/null; then sudo apt install pdsh -y &>/dev/null; echo "done"; fi
	echo -ne "  Installing pdsh on all nodes..."
        pdsh "if ! rpm -q pdsh >&/dev/null; then sudo apt install pdsh -y &>/dev/null; fi"; echo "done"
	echo -ne "  Installing git on all nodes..."
        pdsh "if ! rpm -q git >&/dev/null; then sudo apt install git -y &>/dev/null; fi"; echo "done"
        ;;
    centos)
        # For CentOS systems
        echo -ne "  Installing amazon-linux-extras on local node..."
        if ! rpm -q epel-release >&/dev/null; then sudo amazon-linux-extras install epel -y &> /dev/null; fi; echo "done"
        echo -ne "  Installing pdsh on local node..."
        if ! rpm -q pdsh-rcmd-ssh.x86_64 >&/dev/null; then sudo yum install pdsh-rcmd-ssh.x86_64 pdsh-mod-genders -y &> /dev/null; fi ; echo "done"
        echo -ne "  Installing amazon-linux-extras on all nodes..."
        pdsh "if ! rpm -q epel-release >&/dev/null; then sudo amazon-linux-extras install epel -y &> /dev/null; fi"; echo "done"
        echo -ne "  Installing pdsh on all nodes..."
        pdsh "if ! rpm -q pdsh-rcmd-ssh.x86_64 >&/dev/null; then sudo yum install pdsh-rcmd-ssh.x86_64 pdsh-mod-genders -y &> /dev/null; fi"; echo "done"
        echo -ne "Installing git on all nodes..."
        pdsh "if ! rpm -q git >&/dev/null; then sudo yum install git -y &> /dev/null; fi"; echo "done"
        ;;
    *)
        echo "Unsupported OS: $os"
        exit 1
        ;;
esac

# Install GIT weka/tools on all servers
echo -ne "Installing GIT weka/tools on all nodes..."
pdsh git clone http://github.com/weka/tools &>/dev/null; echo "done"
echo -ne "Mounting Weka on clients..."
pdsh "sudo mkdir /mnt/weka" &>/dev/null
pdsh -g client "sudo mount -t wekafs b0/default /mnt/weka" &>/dev/null
pdsh -g client "sudo chmod 777 /mnt/weka" &>/dev/null  
echo "done"

rm -rf post_install_tmp &>/dev/null

echo "Post Installation completed."
