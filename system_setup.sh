#!/bin/bash

#***********************************************************************************************************************
# Declare variables here
#***********************************************************************************************************************
lower_first_name=""
lower_last_name=""
system_model=""

#***********************************************************************************************************************
# Add network info.
#***********************************************************************************************************************
clear
echo ""
echo "Configuring Recon Device"

#***********************************************************************************************************************
# Get the homeowner's first name
#***********************************************************************************************************************
while true; do
  read -p "Enter Homeowner's first and last name: " first_name last_name
  if [ -n "$first_name" ] && [ -n "$last_name" ]; then
    #*********************************************************************************************************************
    # Verify Homeowner's first name
    #*********************************************************************************************************************
    echo "Homeowner's first name: $first_name"
    echo "Homeowner's last name: $last_name"
    read -p "Is this correct(y/n)? " response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      #***************************************************************************************************************
      # Set the first and last name to all lower case
      #***************************************************************************************************************
      lower_first_name=$(echo "$first_name" | tr '[:upper:]' '[:lower:]')
      lower_last_name=$(echo "$last_name" | tr '[:upper:]' '[:lower:]')
      break
    fi
  else
    echo ""
    echo "Homeowner's first/last name is invalid:"
  fi
done

#***********************************************************************************************************************
# Prompt for "Wi-Fi connected" Recon
#***********************************************************************************************************************
echo ""
read -p "Will this Recon Device be connected to a Wi-Fi router(y/n)? " response
if [[ "$response" == "y" || "$response" == "Y" ]]; then
  #*********************************************************************************************************************
  # Loop until the network information is entered
  #*********************************************************************************************************************
  while true; do
    #*******************************************************************************************************************
    # This device will have a Wi-Fi connection, so get a Wi-Fi SSID and Password
    #*******************************************************************************************************************
    read -p "Do you have the home owner's Network SSID and password(y/n)? " response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      #*****************************************************************************************************************
      # Setup the user's network info for the device and then delete the preconfigured.nmconnection
      #*****************************************************************************************************************
      sudo rm /etc/NetworkManager/system-connections/*.nmconnection
      echo ""
      read -p "Using nmtui to add the networking SSID and Password. Press Enter key to continue" anykey
      sudo nmtui
      clear
      break
    fi
  done
fi

#echo "lower_first_name: $lower_first_name"
#echo "lower_last_name: $lower_last_name"

#*************************************************************************************************************
# Settings common to both Wi-Fi and cellular Recons
#*************************************************************************************************************
# Prompt for the type of system
#*************************************************************************************************************
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
  
  #*************************************************************************************************************
  # Verify the system type
  #*************************************************************************************************************
  read -p "Enter the number for the system type(1-8): " sys_type
  #echo "sys_type: $sys_type"
  if [[ "$sys_type" =~ ^[1-8]+$ ]] && [ "$sys_type" -ge 1 ] && [ "$sys_type" -le 8 ]; then
    #***********************************************************************************************************
    # Get the system type and verify input with user
    #***********************************************************************************************************
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
    fi

    read -p "Is this correct(y/n)? " response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
      if [ "$sys_type" -eq 1 ]; then
        # Copy the M1 Heatpump configuration
        system_model="M1-Heat-Pump"
        echo "Copying M1-Heat-Pump data set to data_config.txt"
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/m1-heat-pump.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/m1-furnace.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/falcon.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/jaguar.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/jaguar-a2l.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/grizzly.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/resi-pack-furnace.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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
        copy_cmd="cp ~/Dev/LaptopKiller/runtime/config/trex.list ~/Dev/LaptopKiller/runtime/config/data_config.txt"
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

#*************************************************************************************************************
# Change the FTP remote path
#*************************************************************************************************************
echo ""
echo "Modifying the SFTP Remote path system type in the sys_config.txt file"
project_cmd="sed -i \"s/Testing/$system_model/g\" \"/home/rheemtest/Dev/LaptopKiller/runtime/config/sys_config.txt\""
echo "Issuing command: $project_cmd"
if eval "$project_cmd"; then
  echo "Changing system type succeeded"
else
  echo "Changing system type failed"
fi

echo ""
echo "Modifying the SFTP Remote path homeowner's name in the sys_config.txt file"
homeowner_cmd="sed -i \"s/rpiz2w-dev/$lower_first_name-$lower_last_name/g\" \"/home/rheemtest/Dev/LaptopKiller/runtime/config/sys_config.txt\""
echo "Issuing command: $homeowner_cmd"
if eval "$homeowner_cmd"; then
  echo "Changing home owner's name succeeded"
else
  echo "Changing home owner's name failed"
fi

echo ""
echo "Modifying the SYSTEM_MODEL in the sys_config.txt file"
sys_model_cmd="sed -i \"s/SYSTEM_MODEL=M1-Heat-Pump/SYSTEM_MODEL=$system_model/g\" \"/home/rheemtest/Dev/LaptopKiller/runtime/config/sys_config.txt\""
echo "Issuing command: $sys_model_cmd"
if eval "$sys_model_cmd"; then
  echo "System Model change succeeded"
else
  echo "System Model change failed"
fi

#*************************************************************************************************************
# Clean up the logging directories
#*************************************************************************************************************
echo ""
echo "Cleaning up the logging directories. Press Enter key to continue"
rm_cmd="sudo rm -f /home/rheemtest/Dev/LaptopKiller/runtime/logs/*.log"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/Dev/LaptopKiller/runtime/logs/*.log*"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/Dev/LaptopKiller/runtime/logs/*.csv"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/Dev/LaptopKiller/runtime/logs/xfer/*"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/Dev/LaptopKiller/runtime/logs/Archive/*"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/Dev/Python/LogFileXfr/*.txt"
if eval "$rm_cmd"; then
  echo "Command: $rm_cmd succeeded"
else
  echo "Command: $rm_cmd failed"
fi

rm_cmd="sudo rm -f /home/rheemtest/Dev/Python/LogFileXfr/*.txt*"
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


#*************************************************************************************************************
# Prevent cloud-init from overwriting hostname (Bookworm / Trixie)
#*************************************************************************************************************
echo ""
echo "Ensuring cloud-init will not override hostname"

if [ -f /etc/cloud/cloud.cfg ]; then
  if grep -q '^preserve_hostname:' /etc/cloud/cloud.cfg; then
    # Replace existing setting (true or false)
    sudo sed -i 's/^preserve_hostname:.*/preserve_hostname: true/' /etc/cloud/cloud.cfg
    echo "Updated preserve_hostname to true in /etc/cloud/cloud.cfg"
  else
    # Add setting if it does not exist
    echo "preserve_hostname: true" | sudo tee -a /etc/cloud/cloud.cfg > /dev/null
    echo "Added preserve_hostname: true to /etc/cloud/cloud.cfg"
  fi
else
  echo "cloud-init not installed; skipping hostname preservation"
fi


#*************************************************************************************************************
# Change the host name (Trixie / Bookworm safe, failure-aware)
#*************************************************************************************************************
NEW_HOSTNAME="$lower_first_name-$lower_last_name"
HOSTNAME_OK=true
echo ""
echo "Setting system hostname to: $NEW_HOSTNAME"

# 1) Set hostname via systemd
if sudo hostnamectl set-hostname "$NEW_HOSTNAME"; then
  echo "hostnamectl succeeded"
else
  echo "ERROR: hostnamectl failed"
  HOSTNAME_OK=false
fi

# 2) Fix /etc/hosts only if hostnamectl worked
if [ "$HOSTNAME_OK" = true ]; then
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    if sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts; then
      echo "/etc/hosts updated"
    else
      echo "ERROR: Failed to update /etc/hosts"
      HOSTNAME_OK=false
    fi
  else
    if echo -e "127.0.1.1\t$NEW_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null; then
      echo "/etc/hosts entry added"
    else
      echo "ERROR: Failed to add /etc/hosts entry"
      HOSTNAME_OK=false
    fi
  fi
fi


#*************************************************************************************************************
# Check to see if hostname was changed sucessfully before locking it
#*************************************************************************************************************
if [ "$(hostname)" != "$NEW_HOSTNAME" ]; then
  echo "ERROR: Runtime hostname mismatch — refusing to lock"
  HOSTNAME_OK=false
fi

#*************************************************************************************************************
# Lock hostname permanently (only if hostname change succeeded)
#*************************************************************************************************************
if [ "$HOSTNAME_OK" = true ]; then
  echo ""
  echo "Locking hostname by masking systemd-hostnamed"
  if sudo systemctl mask systemd-hostnamed; then
    echo "systemd-hostnamed masked successfully"
  else
    echo "WARNING: Failed to mask systemd-hostnamed"
  fi
else
  echo ""
  echo "WARNING: Hostname was not fully configured — systemd-hostnamed NOT masked"
fi


#*************************************************************************************************************
# Setup the RPI connect
#*************************************************************************************************************
echo ""
echo "Setting up Rpi Connect for remote connectivity. You will need to follow the instructions on the screen to register the device."
read -p "Press Enter key once device has been registered. " anykey
# Enable the linger option
loginctl enable-linger
systemctl --user start rpi-connect.service
rpi-connect signout
rpi-connect signin

#*********************************************************************************************************************
# System is configured, so halt
#*********************************************************************************************************************
echo ""
read -p "System setup was successful. System will now be shutdown.  Press Enter key to shut system down" anykey
sudo halt

