# server-setup
This script helps to configure a fresh Debian 13 server.

> [!WARNING]
> #### Use this repository under your own responsability. I'm not a professional programmer, just an ammateur with AI and free time.

<br/>

#### Execute this script with the following command:
```
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/kami104/server-setup/refs/heads/main/server-setup.sh)"
```

<br/>

## What this [script](./server-setup.sh) can do:

   - Create a new normal or sudo user.
     - If the new user is sudo, it asks if you want to import the SSH keys from root. 
   - Add SSH inbound connection rules like:
     - Disable root login.
     - Disable password login.
     - MaxAuthTries 5 & MaxSessions 5
   - Install `ufw` and:
     - Automatically adds exception for SSH inbound connections.
     - Allows the user to add custom inbound exceptions (port and protocol).
     - After adding exceptions, it activates the firewall.
   - Install `fail2ban` for the SSH port.
   - Install docker-engine following with the official apt repository. See [official docs](https://docs.docker.com/engine/install/debian/).
     - It can add a user to the docker group (it's not necessary to logout and login to make the change effect).
    
     <br/>

> [!TIP]
> This script can be useful after create a Debian LXC container or after installing a Debian machine where the only user is root and you want to increase security against bad actors trying to gain access (see [this](https://unix.stackexchange.com/questions/82626/why-is-root-login-via-ssh-so-bad-that-everyone-advises-to-disable-it) and [that](https://www.howtogeek.com/124950/htg-explains-why-you-shouldnt-log-into-your-linux-system-as-root/) for more information). 


> [!TIP]
> #### If you have an RSA key in your ``~/.ssh/`` directory, you can use it to login without password. 
> Just execute the following command **before login via SSH**:
> ```bash
> ssh-copy-id <login_user>@<server_IP>
> ```
>Follow [this guide](https://raspibolt.org/guide/raspberry-pi/security.html#login-with-ssh-keys) for more information about how to create a RSA key.
