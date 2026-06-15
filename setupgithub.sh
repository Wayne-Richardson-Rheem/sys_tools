#!/bin/bash
# Setup the github account
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/github
