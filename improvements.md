## Main:
The following improvement/bug fixes are required:
- [x] Add a parameter in config to either crop or preserve the aspect ratio of the image  
  - [x] If preserve: resize image to match either height or width, then add padding  
  - [x] Padding options: solid color or blurred background (modern padding technique)

- [ ] Add an option in the app for first-time setup with Google Drive

- [x] Add an option in the app to connect RPi to Wi-Fi using credentials entered in the app

- [ ] App setup/backend  
  - [x] Consider using auto-discovery (e.g., Zeroconf/mDNS)  
  - [ ] For initial rclone setup in onboarding/setup, rpi is not connected to any wifi. 
    - [ ] What are some ways device can connect to wifi using app? Is having rpi start in wireless access point
    - [ ] Wifi SSid drop down instead of asking user to write it.
    - [ ] password should have an eye icon which can reveal the password that has been typed
    - [ ] Set all the proper variables on rpi as well as the ip of the rpi in the app once it is connected to the wifi. 
    - [x] QR code based connection. Each device should have an associated QR code. On the app side use relavent QR code scanner.
    - [x] Through the App user should be able to view the existing images and videos on the rpi, so that user can see what is on rpi and can delete them if the memory is full.
      - [ ] Don't refresh or reload all the thumbnails when switching to photos tab. rather maintaina cache on disc, and only change when a photo has been added or deleted.
      - [x] Select button doesn't work
      - [x] Long pressing the photo does show 3 options but they dont have actions associated with them. Just dummy.
      - [ ] exclude/include needs to be wired in the python files
    - [x] Fix bug in storage viewer. it is all gray
    - [ ] Allow only short videos to be uploaded 20 to 30 second long.
    - [ ] Add low-storage warning  
      - [ ] Show warning in app and terminal (throttled once per day)  
      - [x] Visual storage bar: total vs. remaining space
    - [ ] Also suggest a better name instead of "settings" since setting is the gear menu on the top right.
    - [ ] Landscape or portrait.
    - [ ] Change Add photos button to add media, and have the capability to add vidoes as well.

# chat doubts
* /etc/NetworkManager/conf.d/50-wifi-regdom.conf, change country automatically somehow?


# Where I left
Gave up on gdrive auth, sticking to app server. Base UI ready with add photos backend (like old X-Auth) integrated. Need to add more features to app: cache of images to see what is on the frame, what images have been uploaded. Image selection behaviour backend logic needs to be in place.


### Sub corrections A
1. Add the "cover/contain with blur/solid padding" to fast_image_loader.py instead of utils.py
2. Instead of creating files under systemd/*.service update the create_systemd.sh script since the systemd directory no longer exists. Update create_sync_units.sh and install_deps.sh scripts accordingly if required; otherwise, change them as you see fit.
3. IF there is no need to create another user, i.e. no need for setup_sudoers.sh. However, if this is needed provide sudo permissions to "rpi" user. The create_systemd.sh already handles some aspect of creating user defined services and some system defined service, preferably handles things here instead of creating a sh file explicitly, however, the create_systemd.sh can internally wirite to other services or write to other .sh files if needed.
4. 