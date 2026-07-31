#!/bin/bash
set -e

# Declare variables here
lower_first_name=""
lower_last_name=""
system_model=""

# Start script
clear
echo "Configuring Recon Device"
echo "******************************************************"

HOSTNAME=$(hostname)
echo "Hostname set to: \"$HOSTNAME\""
echo ""
read -p "Is this correct(y/n)? " response
if [[ "$response" == "n" || "$response" == "N" ]]; then
  echo "Setting up a new hostname"
  echo "******************************************************"

  # Get the homeowner's first name
  while true; do
    read -p "Enter Homeowner's first and last name: " first_name last_name
    if [ -n "$first_name" ] && [ -n "$last_name" ]; then
      # Verify Homeowner's first name
      echo "Homeowner's first name: $first_name"
      echo "Homeowner's last name: $last_name"
      read -p "Is this correct(y/n)? " response
      if [[ "$response" == "y" || "$response" == "Y" ]]; then
        # Set the first and last name to all lower case
        lower_first_name=$(echo "$first_name" | tr '[:upper:]' '[:lower:]')
        lower_last_name=$(echo "$last_name" | tr '[:upper:]' '[:lower:]')
        break
      fi
    else
      echo ""
      echo "Homeowner's first/last name is invalid:"
    fi
  done

  # Change the host name (Trixie / Bookworm safe, failure-aware)
  HOSTNAME="${lower_first_name}-${lower_last_name}"

  # Update hosts FIRST
  {
      echo "127.0.1.1 $HOSTNAME"
      grep -v '^127\.0\.1\.1' /etc/hosts
  } | sudo tee /etc/hosts >/dev/null

  # Update persistent hostname
  echo "$HOSTNAME" | sudo tee /etc/hostname >/dev/null

  # Update runtime hostname
  sudo hostname "$HOSTNAME"

  # Verify changes
  echo "Hostname set to: "
  hostname

  echo "/etc/hosts file contents:"
  echo "***************************************************************"
  cat /etc/hosts

  echo "/etc/hostname file contents:"
  echo "***************************************************************"
  cat /etc/hostname

  echo ""
  echo "Configure networks"
  echo "***************************************************************"
  # Configure Networks
  echo ""

  # Loop until the network information is entered
  while true; do
    # If needed, setup the user's network info for the device and then delete the preconfigured.nmconnection
    # Preserve provisioning and USB gadget profiles
    sudo find /etc/NetworkManager/system-connections \
        -name "*.nmconnection" \
        ! -name "usb-gadget.nmconnection" \
        ! -name "recon-ap.nmconnection" \
        -delete
    echo ""
    read -p "Use nmtui to setup an existing network AND the homeowner's network.  Press Enter key to continue" anykey
    sudo nmtui
    clear
    echo "System rebooting to update hostname and activate network"
    echo "***************************************************************"
    read -p "Press Enter to continue..." anykey
    sudo reboot
    break
  done
fi

# Prompt for the type of system
while true; do
  echo ""
  echo "Enter the system type: "
  echo "1 - M1-Heatpump"
  echo "2 - M1-Furnace"
  echo "3 - Falcon"
  echo "4 - Jaguar"
  echo "5 - A2LJaguar"
  echo "6 - Grizzly"
  echo "7 - Resi-Pack Furnace"
  echo "8 - T-Rex"
  echo "9 - Hurricane"

  # Verify the system type
  read -p "Enter the number for the system type(1-9): " sys_type
  #echo "sys_type: $sys_type"
  if [[ "$sys_type" =~ ^[1-9]+$ ]] && [ "$sys_type" -ge 1 ] && [ "$sys_type" -le 9 ]; then
    # Get the system type and verify input with user
    echo ""
    if [ "$sys_type" -eq 1 ]; then
      echo "M1-Heatpump system was selected"
    elif [ "$sys_type" -eq 2 ]; then
      echo "M1-Furnace system was selected"
    elif [ "$sys_type" -eq 3 ]; then
      echo "Falcon system was selected"
    elif [ "$sys_type" -eq 4 ]; then
      echo "Jaguar system was selected"
    elif [ "$sys_type" -eq 5 ]; then
      echo "A2L Jaguar system was selected"
    elif [ "$sys_type" -eq 6 ]; then
      echo "Grizzly system was selected"
    elif [ "$sys_type" -eq 7 ]; then
      echo "Resi-Pack system Furnaace was selected"
    elif [ "$sys_type" -eq 8 ]; then
      echo "T-Rex system was selected"
    elif [ "$sys_type" -eq 9 ]; then
      echo "Hurricane system was selected"
    fi

    read -p "Is this correct(y/n)? " response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      if [ "$sys_type" -eq 1 ]; then
        # Copy the M1 Heatpump configuration
        system_model="M1-Heat-Pump"
        echo "Copying M1-Heat-Pump data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/m1-heat-pump.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, M1-Heat-Pump variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 2 ]; then
        # Copy the M1 Furnace configuration
        system_model="M1-Furnace"
        echo "Copying M1-Furnace data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/m1-furnace.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, M1-Furnace variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 3 ]; then
        # Copy the Falcon configuration
        system_model="Falcon"
        echo "Copying Falcon data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/falcon.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, Falcon variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 4 ]; then
        # Copy the Jaguar configuration
        system_model="Jaguar"
        echo "Copying Jaguar data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/jaguar.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, Jaguar variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 5 ]; then
        # Copy the A2L Jaguar configuration
        system_model="A2LJaguar"
        echo "Copying A2L Jaguar data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/jaguar-a2l.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, A2L Jaguar variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 6 ]; then
        # Copy the Grizzly configuration
        system_model="Grizzly"
        echo "Copying Grizzly data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/grizzly.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, Grizzly variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 7 ]; then
        # Copy the Resi-Pack Furnace configuration
        system_model="Resi-Pack-Furnace"
        echo "Copying Resi-Pack Furnace data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/resi-pack-furnace.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, Resi-Pack-Furnace variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 8 ]; then
        # Copy the T-Rex configuration
        system_model="T-Rex"
        echo "Copying T-Rex data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/trex.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, T-Rex variables are set"
          break
        else
          echo "Command failed"
        fi
      elif [ "$sys_type" -eq 9 ]; then
        # Copy the Hurricane configuration (same as Falcon)
        system_model="Hurricane"
        echo "Copying Hurricane data set to data_config.txt"
        copy_cmd="cp /data/laptopkiller/runtime/config/falcon.list /data/laptopkiller/runtime/config/data_config.txt"
        echo "$copy_cmd"
        if eval "$copy_cmd"; then
          echo "Command succeeded, T-Rex variables are set"
          break
        else
          echo "Command failed"
        fi
      fi
    else
      clear
    fi
  else
    echo "A number between 1 and 8 needs to be entered"
  fi
done

# Change the FTP remote path
echo ""
echo "Modifying the SFTP Remote path system type in the sys_config.txt file"
project_cmd="sed -i \"s/Testing/$system_model/g\" \"/data/laptopkiller/runtime/config/sys_config.txt\""
echo "Issuing command: $project_cmd"
if eval "$project_cmd"; then
  echo "Changing system type succeeded"
else
  echo "Changing system type failed"
fi

echo ""
echo "Modifying the SFTP Remote path homeowner's name in the sys_config.txt file"
homeowner_cmd="sed -i \"s/rpiz2w-dev/$lower_first_name-$lower_last_name/g\" \"/data/laptopkiller/runtime/config/sys_config.txt\""
echo "Issuing command: $homeowner_cmd"
if eval "$homeowner_cmd"; then
  echo "Changing home owner's name succeeded"
else
  echo "Changing home owner's name failed"
fi

echo ""
echo "Modifying the SYSTEM_MODEL in the sys_config.txt file"
sys_model_cmd="sed -i \"s/SYSTEM_MODEL=M1-Heat-Pump/SYSTEM_MODEL=$system_model/g\" \"/data/laptopkiller/runtime/config/sys_config.txt\""
echo "Issuing command: $sys_model_cmd"
if eval "$sys_model_cmd"; then
  echo "System Model change succeeded"
else
  echo "System Model change failed"
fi

# Clean up the logging directories
echo ""
echo "Cleaning up the logging directories. Press Enter key to continue"
rm_cmd="sudo rm -f /data/laptopkiller/runtime/logs/*.log"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /data/laptopkiller/runtime/logs/*.log*"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /data/laptopkiller/runtime/logs/*.csv"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /data/laptopkiller/runtime/logs/xfer/*"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /data/laptopkiller/runtime/logs/Archive/*"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/cron.txt"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi


# Setup Raspberry Pi Connect
echo ""
echo "================================================================="
echo "Raspberry Pi Connect Setup"
echo "================================================================="
echo ""
echo "Follow the instructions from rpi-connect to register this device."
read -p "Press Enter to continue..." anykey
# Allow rpi-connect to remain active after logout
sudo loginctl enable-linger rheemtest
#systemctl --user start rpi-connect.service
rpi-connect on
rpi-connect signout || true
rpi-connect signin


# Setup Tailscale hostname if connected
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    echo ""
    echo "Updating Tailscale hostname..."
    sudo tailscale set --hostname="$HOSTNAME" 2>/dev/null || true
  fi
fi


# Setup Tailscale
echo ""
echo "================================================================="
echo "Tailscale Setup"
echo "================================================================="
echo ""

echo "This device can optionally be joined to your Tailscale network."
read -p "Configure Tailscale now (y/n)? " response
if [[ "$response" == "y" || "$response" == "Y" ]]; then
  echo ""
  echo "Starting Tailscale enrollment..."
  sudo tailscale up --ssh
  echo ""
  echo "Current Tailscale status:"
  tailscale status
  echo ""
  read -p "Verify Tailscale enrollment completed. Press Enter to continue..." anykey
else
  echo "Skipping Tailscale setup"
fi


# System is configured, so halt
echo ""
read -p "System setup was successful. System will now be shutdown. Press Enter to continue..." anykey
sudo halt

