#!/bin/bash

/install-yang-modules.sh
/load-startup-config.sh
exec netopeer2-server -d -v3
