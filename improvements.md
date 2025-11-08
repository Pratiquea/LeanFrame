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
    - [x] Have the rpi start with Acess point for initial connection.
    - [x] Wifi SSid drop down instead of asking user to write it.
    - [x] password should have an eye icon which can reveal the password that has been typed
    - [x] Set all the proper variables on rpi as well as the ip of the rpi in the app once it is connected to the wifi. 
    - [x] QR code based connection. Each device should have an associated QR code. On the app side use relavent QR code scanner.
  - [x] Through the App user should be able to view the existing images and videos on the rpi, so that user can see what is on rpi and can delete them if the memory is full.
    - [ ] Don't refresh or reload all the thumbnails when switching to photos tab. rather maintaina cache on disc, and only change when a photo has been added or deleted.
    - [x] Select button doesn't work
    - [x] Long pressing the photo does show 3 options but they dont have actions associated with them. Just dummy.
    - [ ] exclude/include needs to be wired in the python files
  - [x] Fix bug in storage viewer. it is all gray
  - [ ] Allow only short videos to be uploaded 20 to 30 second long.
  - [ ] Add low-storage warning  
    - [ ] Show warning in app and terminal (throttled once per day). There should be a dismiss button that when pressed should throttle the warning to once a week if the disc is still low. 
  - [ ] Landscape or portrait.
  - [ ] Change Add photos button to have the capability to add vidoes as well.
  - [ ] Change country for wifi radio automatically.

- [ ] UI enchancements
  - [x] Visual storage bar: total vs. remaining space
  - [x] Rename Photos to media
  - [x] Rename frame settings to either Preferences or something better.
  - [ ] The storage bar needs to be either moved or visually improved to attract less attention. It kind of looks out of place