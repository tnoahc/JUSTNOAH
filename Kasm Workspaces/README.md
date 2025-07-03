## Kasm Workspaces is a docker container streaming platform for delivering browser-based access to desktops, applications, and web services.

This web application is used for:
- Remote Browser Isolation (RBI)
- Desktop as a Service (DaaS)
- Remote Access Services (RAS)
- Running applications and Linux distributions within a web browser

***
```bash
# Download the Kasm installer
curl -O https://kasm-static-content.s3.amazonaws.com/kasm_release_1.16.1.98d6fa.tar.gz

# Unzip the compressed file
tar -xf kasm_release_1.16.1.98d6fa.tar.gz

# install kasm worspaces
sudo bash kasm_release/install.sh --admin-password your-password-here
```