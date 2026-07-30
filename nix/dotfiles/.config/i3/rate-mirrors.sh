#!/bin/bash

sudo reflector --verbose --protocol https --country 'India' -l 20 --sort rate --save /etc/pacman.d/mirrorlist
