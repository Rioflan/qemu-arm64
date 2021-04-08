# What is this script ?

# How to use it ?

## Create from nothing

You can create an image from nothing using:
```
# ./script.sh --mac 52:54:00:00:00:00 --save-path <image_path> --resize 20G
```
This will download file system image as main.qcow2, resize it to 20G
and start the emulation with a mac of `52:54:00:00:00:00`.

The image uses data from `files/ubuntu/user-data` to setup cloud-init.
By default ubuntu:ubuntu is used.

The emulation starts on terminal so you connect from here or by ssh.
After setting-up you should poweroff the emulation to keep image on stable state.

## Run from image
### Default run
You have an image setup and you want to run it:
```
# ./script.sh <image_path>
```

### Options example
Options shown below can be used simultaneously. (There is some exceptions)

By default the image given as argument is not modified after the emulation,
If you want to write changes to image add `-s` flag
```
# ./script <image_path> -s
```
The change are writtent to the image only at the end.
If you are in an unstable state copy `<image_path>` before stopping emulation.

If you want to run qemu totally daemonized you can use `-d`
```
# ./script.sh -d --mac 52:54:00:00:00:00 <image_path>
```
Also note the --mac specification, to use with a DHCP server.

If you want to run qemu in a clean way, not totally daemonized, use `-dq`
-> ! unstable state on this branch, don't use it ! <-
```
# ./script.sh -dq <image_path>
```
This will output important informations, retreive the IP and show you how to ssh

# TODO

- Delete auto IP retreive ?
- Clean code
- Add other network managment
- Better image managment
Options:
- Help menu
- Don't copy image
