#!/bin/bash

echo " *** EQUIPO ***"
hostnamectl
sudo lshw

echo
echo " *** ALMACENAMIENTO ***"
lsblk

echo
echo " *** MEMORIA ***"
free -h
